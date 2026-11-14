//
//  OutboxSendTests.swift
//  MailConnectivityTests
//
//  Plan v4 V4-10 acceptance rows T35–T40: hardened SMTP against an
//  in-process scripted server on 127.0.0.1, Gmail / Graph send through
//  injected HTTP transports, the durable outbox across restarts, uncertain
//  outcomes, Sent reconciliation and Undo Send. No external network; every
//  connection is asked of the NetworkPermission closure.
//

import XCTest
import Foundation
import CryptoKit
@testable import MailConnectivity
@testable import ArchiveCore

// MARK: - Doubles

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = start }
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

final class PermissionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _asks: [NetworkAsk] = []
    var refuse = false
    var asks: [NetworkAsk] { lock.withLock { _asks } }
    var permission: NetworkPermission {
        { [self] ask in
            lock.withLock { _asks.append(ask) }
            if refuse { throw NSError(domain: "policy", code: 1, userInfo: [NSLocalizedDescriptionKey: "online mail is off"]) }
        }
    }
}

actor FakeTokens: AccessTokenSource {
    private(set) var refreshes = 0
    private(set) var current = "token-1"
    func accessToken(for account: UUID, audience: String) async throws -> String { current }
    func refreshAfterRejection(account: UUID, audience: String) async throws -> String {
        refreshes += 1; current = "token-\(refreshes + 1)"; return current
    }
}

final class FakeHTTP: SendHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [SendHTTPRequest] = []
    private var responses: [Result<SendHTTPResponse, Error>]
    init(_ responses: [Result<SendHTTPResponse, Error>]) { self.responses = responses }
    var requests: [SendHTTPRequest] { lock.withLock { _requests } }
    func perform(_ request: SendHTTPRequest) async throws -> SendHTTPResponse {
        let next: Result<SendHTTPResponse, Error> = lock.withLock {
            _requests.append(request)
            return responses.count > 1 ? responses.removeFirst() : responses[0]
        }
        return try next.get()
    }
}

final class SpyAppender: SentFolderAppender, @unchecked Sendable {
    let host = "imap.test"
    private let lock = NSLock()
    private var failures: Int
    private var _appended: [Data] = []
    private(set) var calls = 0
    init(failFirst: Int = 0) { failures = failFirst }
    var appended: [Data] { lock.withLock { _appended } }
    var callCount: Int { lock.withLock { calls } }
    func appendToSent(_ bytes: Data, messageID: String, accountID: UUID) async throws {
        try lock.withLock {
            calls += 1
            if failures > 0 { failures -= 1; throw NSError(domain: "imap", code: 1, userInfo: [NSLocalizedDescriptionKey: "APPEND failed: connection reset"]) }
            _appended.append(bytes)
        }
    }
}

struct FakeLookup: SentMessageLookup {
    let host = "lookup.test"
    let find: @Sendable (String) throws -> SentLookupResult
    func findSent(messageID: String, accountID: UUID) async throws -> SentLookupResult { try find(messageID) }
}

/// Blocks inside `submit` until released — a submission in progress.
final class GateSubmitter: MessageSubmitter, @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    func submit(_ message: OutboundMessage, checkpoint: @escaping SubmissionCheckpoint) async -> SubmissionOutcome {
        try? await checkpoint(.mayHaveReachedProvider)
        started.signal()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { self.release.wait(); c.resume() }
        }
        return .accepted(response: "250 OK", providerReference: nil, savedToSent: false)
    }
}

// MARK: - Tests

final class OutboxSendTests: XCTestCase {
    private var dir: URL!
    private var servers: [ScriptedSMTPServer] = []
    let password = "s3cret-P@ss"

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        servers.forEach { $0.stop() }
        servers = []
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    // MARK: Helpers

    func server(_ behavior: @escaping (Int) -> SMTPServerBehavior) throws -> ScriptedSMTPServer {
        let s = try ScriptedSMTPServer(behavior)
        servers.append(s)
        return s
    }

    func account() -> MailAccount {
        MailAccount(provider: .imap, host: "mail.test", port: 993, loginName: "me@alpha.example", displayIdentity: "me@alpha.example",
                    enabledModes: [.capture, .send], connectionState: .connected)
    }

    struct Prepared { var draft: Draft; var composed: ComposedMessage; var account: MailAccount; var attachment: Data }

    /// A saved draft (To, Cc, Bcc, attachment) composed once.
    func prepare(body: String = "Hello", subject: String = "Hello", filename: String = "report.pdf",
                 bcc: [String] = ["hidden@secret.example"]) async throws -> Prepared {
        let acct = account()
        let me = SendingIdentity(accountID: acct.id, address: try MailAddress(parsing: "Me <me@alpha.example>"))
        let store = try DraftStore(storeDirectory: dir)
        var draft = Draft(accountID: acct.id, senderIdentityID: me.id,
                          to: [try MailAddress(parsing: "Ann <ann@example.net>")], cc: [try MailAddress(parsing: "bob@example.org")],
                          bcc: try bcc.map { try MailAddress(parsing: $0) }, subject: subject, plainBody: body)
        draft = try await store.save(draft)
        let bytes = Data((0..<3000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        draft = try await store.addAttachment(DraftAttachmentPayload(filename: filename, mimeType: "application/pdf", data: bytes), to: draft)
        let composed = try await store.compose(draft.id, account: acct, identities: [me], date: Date(timeIntervalSince1970: 1_800_000_000))
        return Prepared(draft: draft, composed: composed, account: acct, attachment: bytes)
    }

    func credentials(_ acct: MailAccount) throws -> SMTPCredentialSource {
        let store = InMemoryCredentialStore()
        try store.write(Data(password.utf8), kind: .password, account: acct.id)
        return .password(username: "me@alpha.example", store: store)
    }

    func smtp(_ server: ScriptedSMTPServer, _ acct: MailAccount, connector: any SMTPConnector = SimulatedTLSConnector(),
              permission: PermissionLog, commandTimeout: TimeInterval = 5, dataTimeout: TimeInterval = 5) throws -> SMTPSubmitter {
        SMTPSubmitter(settings: SMTPServerSettings(host: "127.0.0.1", port: Int(server.port), security: .startTLS,
                                                   commandTimeout: commandTimeout, dataTerminationTimeout: dataTimeout),
                      credentials: try credentials(acct), connector: connector, permission: permission.permission)
    }

    func outbox(_ clock: TestClock, _ permission: PermissionLog) throws -> (Outbox, OutboxStore) {
        let store = try OutboxStore(storeDirectory: dir)
        return (Outbox(store: store, permission: permission.permission, now: { clock.now }), store)
    }

    func noCredentialsSent(_ server: ScriptedSMTPServer, file: StaticString = #filePath, line: UInt = #line) {
        let raw = String(decoding: server.allRaw, as: UTF8.self)
        XCTAssertFalse(raw.uppercased().contains("AUTH"), "no AUTH command", file: file, line: line)
        XCTAssertFalse(raw.contains(password), file: file, line: line)
        XCTAssertFalse(raw.contains(Data("\0me@alpha.example\0\(password)".utf8).base64EncodedString()), file: file, line: line)
        XCTAssertFalse(raw.contains(Data(password.utf8).base64EncodedString()), file: file, line: line)
    }

    func headerSection(_ data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self)
        return text.components(separatedBy: "\r\n\r\n").first ?? ""
    }

    // MARK: T35 — no STARTTLS / bad certificate / split EHLO

    func testT35_noSTARTTLS_badCertificate_realFailedHandshake_permissionRefused_neverSendCredentials() async throws {
        let p = try await prepare()
        let perm = PermissionLog()

        // 1. No STARTTLS offered: stop before AUTH, no downgrade.
        let plain = try server { _ in var b = SMTPServerBehavior(); b.offerSTARTTLS = false; return b }
        let outcome1 = try await smtp(plain, p.account, permission: perm).submit(
            OutboundMessage(operationID: UUID(), accountID: p.account.id, messageID: p.composed.messageID, envelopeFrom: p.composed.envelopeFrom,
                            envelopeRecipients: p.composed.envelopeRecipients, requiresSMTPUTF8: false, bytes: p.composed.bytes)) { _ in }
        guard case .retry(let why, _, _, let automatic) = outcome1 else { return XCTFail("\(outcome1)") }
        XCTAssertFalse(automatic, "the user must fix the server settings; no silent retry loop")
        XCTAssertTrue(why.contains("did not offer a secure connection") && why.contains("not sent"), why)
        noCredentialsSent(plain)
        XCTAssertFalse(plain.allLines.contains { $0.hasPrefix("MAIL") }, "nothing of the message was sent")

        // 2. Certificate refused during the upgrade.
        let badCert = try server { _ in SMTPServerBehavior() }
        let refusing = SimulatedTLSConnector(certificateFailure: SMTPStreamError.tlsHandshakeFailed("certificate is not valid for 127.0.0.1"))
        let outcome2 = try await smtp(badCert, p.account, connector: refusing, permission: perm).submit(
            OutboundMessage(operationID: UUID(), accountID: p.account.id, messageID: p.composed.messageID, envelopeFrom: p.composed.envelopeFrom,
                            envelopeRecipients: p.composed.envelopeRecipients, requiresSMTPUTF8: false, bytes: p.composed.bytes)) { _ in }
        guard case .retry(let why2, _, _, false) = outcome2 else { return XCTFail("\(outcome2)") }
        XCTAssertTrue(why2.contains("secure connection") && why2.contains("not sent"), why2)
        XCTAssertEqual(refusing.streams.count, 1)
        XCTAssertEqual(refusing.streams[0].startTLSCalls, 1)
        noCredentialsSent(badCert)
        XCTAssertEqual(badCert.lines(0).filter { $0.hasPrefix("EHLO") }.count, 1, "no EHLO after the failed upgrade")

        // 3. REAL URLSession stream: STARTTLS accepted, then the "TLS" peer is junk → real handshake failure.
        let junk = try server { _ in var b = SMTPServerBehavior(); b.junkAfterSTARTTLS = true; return b }
        let outcome3 = try await smtp(junk, p.account, connector: URLSessionSMTPConnector(), permission: perm, commandTimeout: 5).submit(
            OutboundMessage(operationID: UUID(), accountID: p.account.id, messageID: p.composed.messageID, envelopeFrom: p.composed.envelopeFrom,
                            envelopeRecipients: p.composed.envelopeRecipients, requiresSMTPUTF8: false, bytes: p.composed.bytes)) { _ in }
        guard case .retry(let why3, _, _, false) = outcome3 else { return XCTFail("\(outcome3)") }
        XCTAssertTrue(why3.contains("secure connection") && why3.contains("not sent"), why3)
        XCTAssertEqual(junk.connections, 1, "the upgrade happened on the same connection; no second connection")
        let raw = junk.allRaw
        let afterSTARTTLS = raw.range(of: Data("STARTTLS\r\n".utf8)).map { Data(raw[$0.upperBound...]) } ?? Data()
        XCTAssertEqual(afterSTARTTLS.first, 0x16, "the next bytes on the same socket are a TLS handshake record, not plaintext")
        noCredentialsSent(junk)

        // 4. The network policy refuses: no connection at all.
        let never = try server { _ in SMTPServerBehavior() }
        let deny = PermissionLog(); deny.refuse = true
        let outcome4 = try await smtp(never, p.account, permission: deny).submit(
            OutboundMessage(operationID: UUID(), accountID: p.account.id, messageID: p.composed.messageID, envelopeFrom: p.composed.envelopeFrom,
                            envelopeRecipients: p.composed.envelopeRecipients, requiresSMTPUTF8: false, bytes: p.composed.bytes)) { _ in }
        guard case .retry(_, _, _, false) = outcome4 else { return XCTFail("\(outcome4)") }
        XCTAssertEqual(deny.asks.count, 1)
        XCTAssertEqual(deny.asks[0].host, "127.0.0.1")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(never.connections, 0)

        // Through the outbox: the no-STARTTLS failure parks the item for the user, never a resend loop.
        let clock = TestClock()
        let (box, _) = try outbox(clock, perm)
        await box.register(account: p.account.id, submitter: try smtp(plain, p.account, permission: perm))
        let op = try await box.enqueue(p.composed, draft: p.draft, route: .smtp(appendToSent: false))
        try await box.runDue()
        clock.advance(7200)
        try await box.runDue()
        let after = try await box.operation(op.id)
        guard case .retryWaiting(_, _, false, false) = after.state else { return XCTFail("\(after.state)") }
        XCTAssertEqual(after.submissionAttempts, 1)
        XCTAssertEqual(plain.connections, 2, "one connection from step 1, one from the outbox — none after")
        XCTAssertEqual(perm.asks.filter { $0.destination == .mailServer }.count, 4, "permission asked before every connection")
    }

    func testT35_splitEHLO_upgradesTheSameConnection_thenAuthenticatesAndSends() async throws {
        let p = try await prepare()
        let perm = PermissionLog()
        let srv = try server { _ in var b = SMTPServerBehavior(); b.splitEHLO = true; return b }
        let connector = SimulatedTLSConnector()
        let clock = TestClock()
        let (box, _) = try outbox(clock, perm)
        await box.register(account: p.account.id, submitter: try smtp(srv, p.account, connector: connector, permission: perm))
        let op = try await box.enqueue(p.composed, draft: p.draft, route: .smtp(appendToSent: false))
        try await box.runDue()

        let after = try await box.operation(op.id)
        guard case .accepted(_, let response) = after.state else { return XCTFail("\(after.state)") }
        XCTAssertTrue(response.hasPrefix("250"))
        XCTAssertEqual(srv.connections, 1)
        XCTAssertEqual(connector.streams.count, 1)
        XCTAssertEqual(connector.streams[0].startTLSCalls, 1, "STARTTLS upgraded the one stream")
        let commands = srv.lines(0).map { $0.split(separator: " ").first.map(String.init) ?? "" }
        XCTAssertEqual(Array(commands.prefix(4)), ["EHLO", "STARTTLS", "EHLO", "AUTH"], "EHLO again after TLS, credentials only then")
        let auth = try XCTUnwrap(srv.lines(0).first { $0.hasPrefix("AUTH PLAIN ") })
        XCTAssertEqual(Data(base64Encoded: String(auth.dropFirst("AUTH PLAIN ".count))), Data("\0me@alpha.example\0\(password)".utf8))
    }

    // MARK: T36 — dot transparency, long headers, non-ASCII filename, Bcc

    func testT36_dotLines_longHeaders_nonASCIIFilename_bytesConformant_reparse_andBccOnlyInEnvelope() async throws {
        let body = ".starts with a dot\n..two dots\n.\nmiddle\n. dot space\n.\r\nend"
        let subject = "A very long subject line that has to be folded across more than one header line by the composer, safely and correctly"
        let p = try await prepare(body: body, subject: subject, filename: "Résumé – Zażółć.pdf")
        let perm = PermissionLog()
        let srv = try server { _ in SMTPServerBehavior() }
        let (box, store) = try outbox(TestClock(), perm)
        await box.register(account: p.account.id, submitter: try smtp(srv, p.account, permission: perm))
        let op = try await box.enqueue(p.composed, draft: p.draft, route: .smtp(appendToSent: false))
        try await box.runDue()
        guard case .accepted = try await box.operation(op.id).state else { return XCTFail() }

        let received = try XCTUnwrap(srv.messages.first)
        XCTAssertEqual(received, p.composed.bytes, "after dot-unstuffing the server holds exactly the composed bytes")
        let frozen = try await store.message(for: op)
        XCTAssertEqual(frozen, p.composed.bytes, "frozen copy unchanged")
        let wire = String(decoding: try XCTUnwrap(srv.wireMessages.first), as: UTF8.self)
        XCTAssertTrue(wire.contains("\r\n..starts with a dot\r\n...two dots\r\n..\r\nmiddle\r\n.. dot space\r\n..\r\nend"), "every leading dot doubled")
        XCTAssertEqual(wire.components(separatedBy: "\r\n").filter { $0 == "." }.count, 1, "exactly one terminator")
        XCTAssertFalse(wire.replacingOccurrences(of: "\r\n", with: "").contains("\r") || wire.replacingOccurrences(of: "\r\n", with: "").contains("\n"),
                       "CRLF line endings only")
        XCTAssertTrue(wire.components(separatedBy: "\r\n").allSatisfy { $0.utf8.count <= 1000 })

        let headers = headerSection(received)
        XCTAssertFalse(headers.lowercased().contains("bcc"))
        XCTAssertFalse(String(decoding: received, as: UTF8.self).contains("hidden@secret.example"), "Bcc nowhere in the message")
        XCTAssertTrue(srv.lines(0).contains("RCPT TO:<hidden@secret.example>"), "Bcc in the envelope")
        XCTAssertEqual(Set(srv.lines(0).filter { $0.hasPrefix("RCPT TO:") }),
                       ["RCPT TO:<ann@example.net>", "RCPT TO:<bob@example.org>", "RCPT TO:<hidden@secret.example>"])
        XCTAssertTrue(headers.components(separatedBy: "\r\n").contains { $0.hasPrefix(" ") }, "the long Subject was folded")
        XCTAssertFalse(srv.lines(0).contains { $0.hasPrefix("MAIL FROM:") && $0.contains("BODY=8BITMIME") }, "7-bit message: no 8BITMIME needed")

        let parsed = MIMEParser.parseEmail(rawEmail: String(decoding: received, as: UTF8.self))
        XCTAssertEqual(EncodedWord.decode(parsed.headers["Subject"] ?? "").replacingOccurrences(of: "\r\n", with: ""), subject)
        func leaves(_ parts: [MIMEPart]) -> [MIMEPart] { parts.flatMap { $0.mimeType.lowercased().hasPrefix("multipart/") ? leaves($0.subparts) : [$0] } }
        let parts = leaves(parsed.parts)
        XCTAssertTrue(parts[0].body.hasPrefix(".starts with a dot\r\n..two dots\r\n.\r\nmiddle"), "dots intact in the re-parsed text")
        let att = try XCTUnwrap(parts.first { $0.filename == "Résumé – Zażółć.pdf" })
        XCTAssertEqual(ArchivedMessageSource.decodedBytes(att), p.attachment)

        // Canonical-form guard: a bare LF or a Bcc header is refused at enqueue.
        XCTAssertThrowsError(try Outbox.checkCanonical(Data("Subject: x\r\n\r\nbad\nline\r\n".utf8)))
        XCTAssertThrowsError(try Outbox.checkCanonical(Data("Bcc: a@b.c\r\n\r\nx\r\n".utf8))) { XCTAssertEqual($0 as? OutboxError, .bccInHeader) }
        XCTAssertEqual(SMTPSubmitter.dotStuffed(Data(".\r\n.x".utf8)), Data("..\r\n..x\r\n".utf8))
    }

    // MARK: T37 — accepted, then QUIT / local write fails

    func testT37_acceptedThenQUITFails_andLocalWriteFails_noResubmission_acceptedSurvivesRestart() async throws {
        let perm = PermissionLog()
        let clock = TestClock()

        // A: 250 after the dot, then QUIT answered with garbage / dropped.
        let a = try await prepare()
        let srvA = try server { _ in var b = SMTPServerBehavior(); b.onQuit = .garbage; return b }
        do {
            let (box, _) = try outbox(clock, perm)
            await box.register(account: a.account.id, submitter: try smtp(srvA, a.account, permission: perm))
            let op = try await box.enqueue(a.composed, draft: a.draft, route: .smtp(appendToSent: false))
            try await box.runDue()
            let accepted = try await box.operation(op.id)
            guard case .accepted = accepted.state else { return XCTFail("\(accepted.state)") }
            clock.advance(3600); try await box.runDue()
            for next in [OutboxState.queued, .submitting, .retryWaiting(reason: "", notBefore: Date(), quota: false, automatic: true),
                         .outcomeUncertain(reason: "", reconciliation: .notChecked), .cancelledBeforeSubmission(at: Date())] {
                XCTAssertThrowsError(try { var o = accepted; try o.move(to: next, at: Date()) }(), "accepted never becomes resendable (\(next.name))")
            }
        }
        // Restart: the record says accepted; nothing is sent again.
        do {
            let (box, _) = try outbox(clock, perm)
            await box.register(account: a.account.id, submitter: try smtp(srvA, a.account, permission: perm))
            let ops = try await box.recoverAfterRestart()
            XCTAssertEqual(ops.count, 1)
            guard case .accepted = ops[0].state else { return XCTFail("\(ops[0].state)") }
            clock.advance(3600); try await box.runDue()
            do { _ = try await box.cancel(ops[0].id); XCTFail("cancel after acceptance must fail") } catch let e as OutboxError {
                XCTAssertEqual(e, .cannotCancelAfterSubmission(state: "accepted"))
            }
        }
        XCTAssertEqual(srvA.connections, 1)
        XCTAssertEqual(srvA.messages.count, 1)

        // B: 250 after the dot, but the disk refuses the "accepted" record.
        try FileManager.default.removeItem(at: dir.appendingPathComponent(OutboxStore.folderName))
        let b = try await prepare()
        let srvB = try server { _ in var be = SMTPServerBehavior(); be.onQuit = .close; return be }
        let opID: UUID
        do {
            let (box, store) = try outbox(clock, perm)
            await box.register(account: b.account.id, submitter: try smtp(srvB, b.account, permission: perm))
            let op = try await box.enqueue(b.composed, draft: b.draft, route: .smtp(appendToSent: false))
            opID = op.id
            // Saves: submitting, checkpoint — then the accepted record fails.
            await store.injectWriteFailures(5, afterSuccessfulWrites: 2)
            try await box.runDue()
            guard case .accepted = try await box.operation(op.id).state else { return XCTFail() }
            let unsaved = await box.hasUnsavedState(op.id)
            XCTAssertTrue(unsaved, "shown as accepted, the disk is behind")
            clock.advance(3600)
            try await box.runDue()           // still failing writes: no resend in this process
        }
        // Restart: the disk says "may have reached the provider" → uncertain, not resent; reconciled by Message-ID.
        do {
            let (box, _) = try outbox(clock, perm)
            let srvRef = srvB
            await box.register(account: b.account.id, submitter: try smtp(srvB, b.account, permission: perm),
                               lookup: FakeLookup { id in
                                   srvRef.messages.contains { String(decoding: $0, as: UTF8.self).contains("Message-ID: \(id)") } ? .found(providerReference: nil) : .notFound
                               })
            let restored = try await box.operation(opID)
            guard case .outcomeUncertain(_, .notChecked) = restored.state else { return XCTFail("\(restored.state)") }
            clock.advance(3600); try await box.runDue()
            XCTAssertEqual(srvB.connections, 1, "uncertain is never resent automatically")
            let reconciled = try await box.reconcile(opID)
            guard case .sentReconciled(_, .foundInSent) = reconciled.state else { return XCTFail("\(reconciled.state)") }
        }
        XCTAssertEqual(srvB.connections, 1)
        XCTAssertEqual(srvB.messages.count, 1)
    }

    // MARK: T38 — timeout, recipient rejection, quota

    func testT38_timeoutAfterDotIsUncertain_beforeIsRetry_rejectionKeepsRecipients_quotaWaits() async throws {
        let perm = PermissionLog()
        let clock = TestClock()

        // A: the server goes silent after the final dot → uncertain; resend only by the user after a Sent check.
        let a = try await prepare()
        let srvA = try server { n in var b = SMTPServerBehavior(); if n == 0 { b.afterDot = .stall(1.5) }; return b }
        let (box, store) = try outbox(clock, perm)
        await box.register(account: a.account.id, submitter: try smtp(srvA, a.account, permission: perm, dataTimeout: 0.5),
                           lookup: FakeLookup { _ in .notFound })
        let op = try await box.enqueue(a.composed, draft: a.draft, route: .smtp(appendToSent: false))
        try await box.runDue()
        guard case .outcomeUncertain(let reason, .notChecked) = try await box.operation(op.id).state else { return XCTFail() }
        XCTAssertTrue(reason.contains("after the whole message was sent"), reason)
        clock.advance(3600); try await box.runDue()
        XCTAssertEqual(srvA.connections, 1, "no automatic resend")
        do { _ = try await box.resendAfterUncertainty(op.id); XCTFail() } catch let e as OutboxError { XCTAssertEqual(e, .resendNeedsReconciliation) }
        let checked = try await box.reconcile(op.id)
        guard case .outcomeUncertain(_, .notFound) = checked.state else { return XCTFail("\(checked.state)") }
        _ = try await box.resendAfterUncertainty(op.id)
        try await box.runDue()
        let resent = try await box.operation(op.id)
        guard case .accepted = resent.state else { return XCTFail("\(resent.state)") }
        XCTAssertEqual(resent.userResends, 1)
        XCTAssertEqual(srvA.connections, 2)
        let ids = srvA.messages.map { headerSection($0).components(separatedBy: "\r\n").first { $0.hasPrefix("Message-ID:") } }
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(ids[0], ids[1], "the same Message-ID on both submissions")
        XCTAssertEqual(srvA.messages[0], srvA.messages[1], "the same frozen bytes")

        // B: a timeout BEFORE the dot (at RCPT) is a safe retry, not uncertain.
        let b = try await prepare()
        let srvB = try server { n in var be = SMTPServerBehavior(); if n == 0 { be.stallOnRCPT = 1.5 }; return be }
        await box.register(account: b.account.id, submitter: try smtp(srvB, b.account, permission: perm, commandTimeout: 0.5))
        let opB = try await box.enqueue(b.composed, draft: b.draft, route: .smtp(appendToSent: false))
        try await box.runDue()
        guard case .retryWaiting(_, _, false, true) = try await box.operation(opB.id).state else { return XCTFail() }
        XCTAssertTrue(srvB.messages.isEmpty)
        XCTAssertFalse(srvB.allLines.contains("DATA"))

        // C: one recipient refused (550 5.1.1) → known rejected, recipients and bytes intact, no DATA.
        let c = try await prepare()
        let srvC = try server { _ in var bc = SMTPServerBehavior(); bc.rcptReply = { $0 == "bob@example.org" ? "550 5.1.1 No such user" : "250 OK" }; return bc }
        await box.register(account: c.account.id, submitter: try smtp(srvC, c.account, permission: perm))
        let opC = try await box.enqueue(c.composed, draft: c.draft, route: .smtp(appendToSent: false))
        try await box.runDue()
        let rejected = try await box.operation(opC.id)
        guard case .rejected(let why, let refused) = rejected.state else { return XCTFail("\(rejected.state)") }
        XCTAssertEqual(refused, ["bob@example.org"])
        XCTAssertTrue(why.contains("1 of 3"), why)
        XCTAssertEqual(rejected.envelopeRecipients, c.composed.envelopeRecipients)
        let keptBytes = try await store.message(for: rejected)
        XCTAssertEqual(keptBytes, c.composed.bytes, "attachment bytes intact")
        XCTAssertFalse(srvC.allLines.contains("DATA"), "no partial send")
        clock.advance(86_400); try await box.runDue()
        XCTAssertEqual(srvC.connections, 1)

        // D: sending quota (550 5.4.5) → retry waiting, quota, not before the reset; then sent.
        let d = try await prepare()
        let srvD = try server { n in var bd = SMTPServerBehavior(); if n == 0 { bd.mailReply = "550 5.4.5 Daily user sending quota exceeded." }; return bd }
        await box.register(account: d.account.id, submitter: try smtp(srvD, d.account, permission: perm))
        let opD = try await box.enqueue(d.composed, draft: d.draft, route: .smtp(appendToSent: false))
        try await box.runDue()
        guard case .retryWaiting(_, let notBefore, true, true) = try await box.operation(opD.id).state else { return XCTFail() }
        XCTAssertEqual(notBefore.timeIntervalSince(clock.now), 3600, accuracy: 1)
        clock.advance(1800); try await box.runDue()
        XCTAssertEqual(srvD.connections, 1, "nothing before the quota window passes")
        clock.advance(1801); try await box.runDue()
        guard case .accepted = try await box.operation(opD.id).state else { return XCTFail() }
        XCTAssertEqual(srvD.connections, 2)
        XCTAssertEqual(srvD.messages.count, 1)
    }

    // MARK: T39 — provider-saved Sent not duplicated; APPEND failure never resends

    func testT39_gmailAndGraphNeverAppend_smtpAppendFailureRetriesAppendOnly() async throws {
        let perm = PermissionLog()
        let clock = TestClock()
        let (box, store) = try outbox(clock, perm)

        // Gmail: 401 → one refresh → 200 with the SENT label.
        let g = try await prepare()
        let gmailHTTP = FakeHTTP([.success(SendHTTPResponse(status: 401)),
                                  .success(SendHTTPResponse(status: 200, body: Data(#"{"id":"g-1","threadId":"t","labelIds":["SENT"]}"#.utf8)))])
        let tokens = FakeTokens()
        let gAppender = SpyAppender()
        await box.register(account: g.account.id, submitter: GmailSendSubmitter(tokens: tokens, transport: gmailHTTP, permission: perm.permission),
                           appender: gAppender)
        let gop = try await box.enqueue(g.composed, draft: g.draft, route: .gmailAPI)
        try await box.runDue()
        let gAfter = try await box.operation(gop.id)
        guard case .sentReconciled(_, .providerResponse) = gAfter.state else { return XCTFail("\(gAfter.state)") }
        XCTAssertEqual(gAfter.providerReference, "g-1")
        XCTAssertEqual(gAfter.sentCopy, .providerFiles)
        XCTAssertEqual(gAppender.callCount, 0, "Gmail files Sent itself")
        let refreshes = await tokens.refreshes
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(gmailHTTP.requests.count, 2)
        let gReq = gmailHTTP.requests[1]
        XCTAssertEqual(gReq.headers["Authorization"], "Bearer token-2")
        XCTAssertEqual(gReq.headers["Content-Type"], "message/rfc822")
        XCTAssertEqual(gReq.url, GmailSendSubmitter.endpoint)
        let gBody = String(decoding: gReq.body, as: UTF8.self)
        XCTAssertTrue(gBody.hasPrefix("Bcc: hidden@secret.example\r\n"), "the API reads Bcc from the submitted header (and strips it)")
        XCTAssertEqual(gReq.body.dropFirst("Bcc: hidden@secret.example\r\n".utf8.count), g.composed.bytes)
        let storedG = try await store.message(for: gAfter)
        XCTAssertFalse(String(decoding: storedG, as: UTF8.self).contains("hidden@"), "the stored copy has no Bcc")

        // Graph: 202 = accepted for processing; Exchange files Sent; reconcile confirms by Message-ID.
        let m = try await prepare(bcc: [])
        let graphHTTP = FakeHTTP([.success(SendHTTPResponse(status: 202, headers: ["request-id": "r-9"]))])
        let mAppender = SpyAppender()
        await box.register(account: m.account.id, submitter: GraphSendSubmitter(tokens: FakeTokens(), transport: graphHTTP, permission: perm.permission),
                           appender: mAppender, lookup: FakeLookup { [mid = m.composed.messageID] id in id == mid ? .found(providerReference: "AAMk") : .notFound })
        let mop = try await box.enqueue(m.composed, draft: m.draft, route: .graphAPI)
        try await box.runDue()
        let mAfter = try await box.operation(mop.id)
        guard case .accepted(_, let response) = mAfter.state else { return XCTFail("\(mAfter.state)") }
        XCTAssertTrue(response.contains("accepted the message for processing") && response.contains("not a delivery confirmation"))
        XCTAssertEqual(mAfter.providerReference, "r-9")
        XCTAssertEqual(graphHTTP.requests[0].headers["Content-Type"], "text/plain")
        XCTAssertEqual(Data(base64Encoded: graphHTTP.requests[0].body), m.composed.bytes)
        let mDone = try await box.reconcile(mop.id)
        guard case .sentReconciled(_, .foundInSent) = mDone.state else { return XCTFail("\(mDone.state)") }
        XCTAssertEqual(mAppender.callCount, 0)
        XCTAssertEqual(graphHTTP.requests.count, 1)

        // Graph 503 / dropped connection → uncertain; never resent by itself.
        let u = try await prepare(bcc: [])
        let flaky = FakeHTTP([.failure(URLError(.networkConnectionLost))])
        await box.register(account: u.account.id, submitter: GraphSendSubmitter(tokens: FakeTokens(), transport: flaky, permission: perm.permission))
        let uop = try await box.enqueue(u.composed, draft: u.draft, route: .graphAPI)
        try await box.runDue(); clock.advance(3600); try await box.runDue()
        guard case .outcomeUncertain = try await box.operation(uop.id).state else { return XCTFail() }
        XCTAssertEqual(flaky.requests.count, 1)

        // Generic SMTP + IMAP APPEND: the append fails, the message stays accepted; retrying appends only.
        let s = try await prepare()
        let srv = try server { _ in SMTPServerBehavior() }
        let sAppender = SpyAppender(failFirst: 1)
        await box.register(account: s.account.id, submitter: try smtp(srv, s.account, permission: perm), appender: sAppender,
                           lookup: FakeLookup { _ in .notFound })
        let sop = try await box.enqueue(s.composed, draft: s.draft, route: .smtp(appendToSent: true))
        try await box.runDue()
        let sAfter = try await box.operation(sop.id)
        guard case .accepted = sAfter.state, case .appendFailed(let why) = sAfter.sentCopy else { return XCTFail("\(sAfter.state) \(sAfter.sentCopy)") }
        XCTAssertTrue(why.contains("APPEND failed"))
        clock.advance(3600); try await box.runDue()
        XCTAssertEqual(srv.connections, 1, "an append failure never resends")
        let fixed = try await box.retrySentCopy(sop.id)
        guard case .sentReconciled(_, .appendedToSent) = fixed.state else { return XCTFail("\(fixed.state)") }
        XCTAssertEqual(fixed.sentCopy, .appended)
        XCTAssertEqual(sAppender.appended, [s.composed.bytes], "one Sent copy, the stored bytes (no Bcc)")
        XCTAssertEqual(srv.connections, 1)
        XCTAssertEqual(srv.messages.count, 1)
        XCTAssertTrue(perm.asks.contains { $0.host == "imap.test" }, "the append asked permission")
    }

    // MARK: T40 — Undo Send

    func testT40_undoBeforeSubmission_restartDuringDelay_cancelAfterSubmissionImpossible() async throws {
        let perm = PermissionLog()
        let clock = TestClock()
        let srv = try server { _ in SMTPServerBehavior() }

        // A: undo within the delay → nothing sent, ever.
        let a = try await prepare()
        let (box, _) = try outbox(clock, perm)
        await box.register(account: a.account.id, submitter: try smtp(srv, a.account, permission: perm))
        let opA = try await box.enqueue(a.composed, draft: a.draft, route: .smtp(appendToSent: false), undoDelay: 30)
        try await box.runDue()
        XCTAssertEqual(srv.connections, 0)
        let cancelled = try await box.cancel(opA.id)
        guard case .cancelledBeforeSubmission = cancelled.state else { return XCTFail() }
        clock.advance(60); try await box.runDue()
        XCTAssertEqual(srv.connections, 0)
        XCTAssertTrue(perm.asks.isEmpty, "no connection was even asked for")

        // B: restart during the delay — the delay is persisted and honoured.
        let b = try await prepare()
        let opB = try await box.enqueue(b.composed, draft: b.draft, route: .smtp(appendToSent: false), undoDelay: 30)
        let (box2, _) = try outbox(clock, perm)
        await box2.register(account: b.account.id, submitter: try smtp(srv, b.account, permission: perm))
        let restored = try await box2.operation(opB.id)
        XCTAssertEqual(restored.state, .queued)
        XCTAssertEqual(restored.notBefore?.timeIntervalSince1970 ?? 0, clock.now.addingTimeInterval(30).timeIntervalSince1970, accuracy: 0.001)
        clock.advance(10); try await box2.runDue()
        XCTAssertEqual(srv.connections, 0)
        clock.advance(21); try await box2.runDue()
        guard case .accepted = try await box2.operation(opB.id).state else { return XCTFail() }
        XCTAssertEqual(srv.connections, 1)
        do { _ = try await box2.cancel(opB.id); XCTFail() } catch let e as OutboxError {
            XCTAssertEqual(e, .cannotCancelAfterSubmission(state: "accepted"), "no recall promise")
        }

        // C: cancel while the submission is under way → refused; it completes.
        let c = try await prepare()
        let gate = GateSubmitter()
        let (box3, _) = try outbox(clock, perm)
        await box3.register(account: c.account.id, submitter: gate)
        let opC = try await box3.enqueue(c.composed, draft: c.draft, route: .smtp(appendToSent: false))
        let running = Task { try await box3.runDue() }
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in DispatchQueue.global().async { gate.started.wait(); k.resume() } }
        do { _ = try await box3.cancel(opC.id); XCTFail("cancel during submission") } catch let e as OutboxError {
            XCTAssertEqual(e, .cannotCancelAfterSubmission(state: "submitting"))
        }
        gate.release.signal()
        _ = try await running.value
        guard case .accepted = try await box3.operation(opC.id).state else { return XCTFail() }

        // Owner-only on disk.
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(OutboxStore.folderName).path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let rec = dir.appendingPathComponent(OutboxStore.folderName).appendingPathComponent(opC.id.uuidString)
        for name in ["operation.json", "message.eml"] {
            let fa = try FileManager.default.attributesOfItem(atPath: rec.appendingPathComponent(name).path)
            XCTAssertEqual((fa[.posixPermissions] as? NSNumber)?.intValue, 0o600, name)
        }
    }
}

// MARK: - Audit 2026-11-14 (Graph send)

extension OutboxSendTests {

    static func sentPage(_ ids: [String]) -> SendHTTPResponse {
        SendHTTPResponse(status: 200, headers: ["content-type": "application/json"],
                         body: Data(("{\"value\":[" + ids.map { "{\"id\":\"\($0)\"}" }.joined(separator: ",") + "]}").utf8))
    }

    /// #3: a Graph send can be checked against Sent Items by Message-ID —
    /// uncertain and accepted (202) sends reconcile through `GraphSentLookup`.
    func testAudit1114_graphSentLookup_reconcilesUncertainAndAcceptedSends() async throws {
        let perm = PermissionLog()
        let clock = TestClock()
        let (box, _) = try outbox(clock, perm)

        // A dropped connection → uncertain; the lookup finds it in Sent Items.
        let u = try await prepare(bcc: [])
        let flaky = FakeHTTP([.failure(URLError(.networkConnectionLost))])
        let lookupHTTP = FakeHTTP([.success(SendHTTPResponse(status: 401)), .success(Self.sentPage(["AAMk-sent-1"]))])
        let tokens = FakeTokens()
        let lookup = GraphSentLookup(tokens: tokens, transport: lookupHTTP, permission: perm.permission)
        await box.register(account: u.account.id, submitter: GraphSendSubmitter(tokens: FakeTokens(), transport: flaky, permission: perm.permission),
                           lookup: lookup)
        let uop = try await box.enqueue(u.composed, draft: u.draft, route: .graphAPI)
        try await box.runDue()
        guard case .outcomeUncertain = try await box.operation(uop.id).state else { return XCTFail() }
        let found = try await box.reconcile(uop.id)
        guard case .sentReconciled(_, .foundInSent) = found.state else { return XCTFail("\(found.state)") }
        XCTAssertEqual(found.providerReference, "AAMk-sent-1")
        XCTAssertEqual(flaky.requests.count, 1, "never resent")
        // The request: Sent Items, filtered by the exact Message-ID, ids only, refreshed once after a 401.
        XCTAssertEqual(lookupHTTP.requests.count, 2)
        let request = lookupHTTP.requests[1]
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.url.host, "graph.microsoft.com")
        XCTAssertEqual(request.url.path, "/v1.0/me/mailFolders/sentitems/messages")
        let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "$filter" }?.value, "internetMessageId eq '\(u.composed.messageID)'")
        XCTAssertEqual(items.first { $0.name == "$select" }?.value, "id")
        XCTAssertEqual(request.headers["Authorization"], "Bearer token-2")
        XCTAssertTrue(perm.asks.contains { $0.host == "graph.microsoft.com" && $0.destination == .mailServer })

        // Not in Sent: recorded, and only then may the user send again.
        let n = try await prepare(bcc: [])
        await box.register(account: n.account.id, submitter: GraphSendSubmitter(tokens: FakeTokens(), transport: FakeHTTP([.failure(URLError(.networkConnectionLost))]),
                                                                               permission: perm.permission),
                           lookup: GraphSentLookup(tokens: FakeTokens(), transport: FakeHTTP([.success(Self.sentPage([]))]), permission: perm.permission))
        let nop = try await box.enqueue(n.composed, draft: n.draft, route: .graphAPI)
        try await box.runDue()
        let missing = try await box.reconcile(nop.id)
        guard case .outcomeUncertain(_, .notFound) = missing.state else { return XCTFail("\(missing.state)") }

        // Accepted (202) → confirmed in Sent.
        let a = try await prepare(bcc: [])
        await box.register(account: a.account.id, submitter: GraphSendSubmitter(tokens: FakeTokens(), transport: FakeHTTP([.success(SendHTTPResponse(status: 202))]),
                                                                               permission: perm.permission),
                           lookup: GraphSentLookup(tokens: FakeTokens(), transport: FakeHTTP([.success(Self.sentPage(["AAMk-a"]))]), permission: perm.permission))
        let aop = try await box.enqueue(a.composed, draft: a.draft, route: .graphAPI)
        try await box.runDue()
        guard case .accepted = try await box.operation(aop.id).state else { return XCTFail() }
        let confirmed = try await box.reconcile(aop.id)
        guard case .sentReconciled(_, .foundInSent) = confirmed.state else { return XCTFail("\(confirmed.state)") }

        // A quote in a Message-ID is an OData literal, never the end of the filter.
        let quoted = try lookup.url(for: "<o'brien@x.example>")
        let filter = URLComponents(url: quoted, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "$filter" }?.value
        XCTAssertEqual(filter, "internetMessageId eq '<o''brien@x.example>'")
    }

    /// #4: Graph's 4 MB encoded limit is a pure check the app runs before
    /// queueing; `submit` refuses the same messages with a reason the app words.
    func testAudit1114_graphSendSizeCheck_beforeQueueing_andTheRefusalIsRecognisable() async throws {
        for n in [0, 1, 2, 3, 4, 1_000, 3_145_727, 3_145_728] {
            XCTAssertEqual(GraphSendSubmitter.encodedByteCount(messageBytes: n), Data(count: n).base64EncodedData().count, "\(n)")
        }
        XCTAssertEqual(GraphSendSubmitter.maxEncodedBytes, 4 * 1024 * 1024)
        XCTAssertEqual(GraphSendSubmitter.sizeCheck(messageBytes: 3_145_728), .fits(encodedBytes: 4_194_304), "exactly 4 MB encoded fits")
        XCTAssertEqual(GraphSendSubmitter.sizeCheck(messageBytes: 3_145_729), .tooLarge(encodedBytes: 4_194_308))

        let http = FakeHTTP([.success(SendHTTPResponse(status: 202))])
        let submitter = GraphSendSubmitter(tokens: FakeTokens(), transport: http, permission: PermissionLog().permission)
        let big = OutboundMessage(operationID: UUID(), accountID: UUID(), messageID: "<m@x.example>", envelopeFrom: "a@x.example",
                                  envelopeRecipients: ["b@x.example"], requiresSMTPUTF8: false, bytes: Data(count: 3_145_729))
        let outcome = await submitter.submit(big) { _ in }
        guard case .rejected(let reason, _) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(GraphSendSubmitter.tooLargeEncodedBytes(inReason: reason), 4_194_308)
        XCTAssertNil(GraphSendSubmitter.tooLargeEncodedBytes(inReason: "Microsoft refused the message (HTTP 400)"))
        XCTAssertTrue(http.requests.isEmpty, "nothing was sent")
    }

    /// #6: the no-redirect transport can be ended (a URLSession keeps its
    /// delegate until invalidated), and the app shares one instance.
    func testAudit1114_noRedirectTransport_invalidateReleasesIt_sharedInstance() async throws {
        XCTAssertTrue(NoRedirectSendHTTPTransport.shared === NoRedirectSendHTTPTransport.shared)
        weak var released: NoRedirectSendHTTPTransport?
        do {
            let transport = NoRedirectSendHTTPTransport()
            released = transport
            transport.invalidate()
            XCTAssertTrue(transport.isInvalidated)
            do {
                _ = try await transport.perform(SendHTTPRequest(method: "GET", url: URL(string: "https://graph.microsoft.com/v1.0/me")!,
                                                                headers: [:], body: Data()))
                XCTFail("a closed transport sent a request")
            } catch is NotSentError {}
        }
        var waited = 0
        while released != nil, waited < 300 { try await Task.sleep(nanoseconds: 10_000_000); waited += 1 }
        XCTAssertNil(released, "the transport is released once its session is ended")
    }
}
