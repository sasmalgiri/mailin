//
//  IMAPAdapterTests.swift
//  MailConnectivityTests
//
//  V4-07: `IMAPAdapter` against the in-process IMAP server on 127.0.0.1,
//  through the REAL `SyncEngine` and a REAL archive (`ConnectedArchiveSink`).
//    full capture   nested Unicode folders (UTF8=ACCEPT and modified UTF-7,
//                   literal names), empty + \Noselect folders, hostile bytes
//                   → every record byte-exact; incremental arrivals/deletions
//                   via QRESYNC and via plain UID SEARCH reconciliation
//    T24            read-only: EXAMINE + UID FETCH BODY.PEEK[] only; no
//                   SELECT / STORE / EXPUNGE / non-UID FETCH; no \Seen change
//    T11            UIDVALIDITY change, sequence renumbering, folder rename
//    security       STARTTLS absent → no AUTH; TLS required (implicit TLS to a
//                   plaintext server sends nothing); plaintext only on loopback;
//                   network permission asked before connecting
//    accounts       two servers, same login → distinct secrets and records
//    resilience     drop mid-literal → reconnect, nothing short preserved;
//                   UID-range paging over sparse UIDs; IDLE
//

import XCTest
import Foundation
import CryptoKit
@testable import MailConnectivity
@testable import ArchiveCore

final class IMAPAdapterTests: XCTestCase {
    private var dir: URL!
    private var servers: [LocalIMAPServer] = []

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("imap-adapter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for s in servers { s.stop() }
        servers = []
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    // MARK: Helpers

    final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T
        init(_ value: T) { stored = value }
        var value: T { lock.withLock { stored } }
        func mutate<R>(_ body: (inout T) -> R) -> R { lock.withLock { body(&stored) } }
    }

    static func message(_ id: String, extra: String = "") -> Data {
        var d = Data(("Message-ID: <\(id)@imap.example>\r\nFrom: Asha <asha@example.com>\r\nTo: ravi@example.org\r\n"
                      + "Subject: Nachricht \(id) – ü 日本\r\nDate: Mon, 6 Jan 2025 10:00:00 +0530\r\nMIME-Version: 1.0\r\n"
                      + "Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n"
                      + "Body \(id)\r\nM5 OK UID FETCH completed\r\n* BYE\r\n.\r\n{3}\r\n\(extra)").utf8)
        d.append(contentsOf: [0xE2, 0x9C, 0x89, 0x0D, 0x0A, 0xC3, 0xBC, 0x0D, 0x0A])
        return d
    }

    static func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    func startServer(_ configure: (IMAPServerModel) -> Void = { _ in }) async throws -> LocalIMAPServer {
        let model = IMAPServerModel()
        configure(model)
        let server = try LocalIMAPServer(model: model)
        try await server.start()
        servers.append(server)
        return server
    }

    func makeAdapter(_ server: LocalIMAPServer, account: UUID = UUID(), credentials: InMemoryCredentialStore = InMemoryCredentialStore(),
                     password: String? = nil, security: IMAPSecurity = .plaintextLoopbackOnly, host: String = "127.0.0.1",
                     pageSize: Int = 500, maxConnections: Int = 2, permission: NetworkPermission? = nil,
                     reconnectSleeps: Box<[TimeInterval]>? = nil) throws -> IMAPAdapter {
        try credentials.write(Data((password ?? server.model.password).utf8), kind: .password, account: account)
        let config = IMAPAccountConfiguration(host: host, port: server.port, security: security, login: server.model.login,
                                              maxConnections: maxConnections, pageSize: pageSize, timeout: 10)
        let sleeps = reconnectSleeps
        return IMAPAdapter(accountID: account, configuration: config, credentials: credentials, permission: permission,
                           reconnect: IMAPReconnectPolicy(base: 1, maximum: 8, sleep: { s in sleeps?.mutate { $0.append(s) } }))
    }

    func makeSink(_ name: String = "archive") -> ConnectedArchiveSink {
        ConnectedArchiveSink(storeDirectory: dir.appendingPathComponent(name, isDirectory: true))
    }

    func register(_ adapter: IMAPAdapter, in sink: ConnectedArchiveSink) async throws {
        try await sink.saveAccount(ConnectedAccountRecord(
            accountID: adapter.accountID, provider: .imap, issuer: "", host: adapter.configuration.host,
            port: Int(adapter.configuration.port), loginName: adapter.configuration.login,
            displayIdentity: "\(adapter.configuration.login)@\(adapter.configuration.host):\(adapter.configuration.port)",
            enabledModes: ["capture"], connectionState: "connected", createdAt: Date(), updatedAt: Date()))
    }

    static let plenty = StorageProbe(reserveBytes: 1_024, availableBytes: { _ in 1 << 40 })

    func makeEngine(_ adapter: IMAPAdapter, _ sink: ConnectedArchiveSink, asks: Box<[NetworkAsk]> = Box([])) -> SyncEngine {
        SyncEngine(adapter: adapter, sink: sink, scheduler: FairDownloadScheduler(totalSlots: 4), tokens: nil,
                   permission: { ask in asks.mutate { $0.append(ask) } },
                   backoff: BackoffPolicy(base: 1, maximum: 4, transientAttempts: 4, maximumThrottleWait: 60,
                                          jitter: { 0.5 }, sleep: { _ in await Task.yield() }),
                   storage: Self.plenty)
    }

    /// (mailbox, uidValidity, uid) → digest, for one account.
    func records(_ sink: ConnectedArchiveSink, account: UUID) async throws -> [String: (mailbox: String, validity: UInt32, uid: UInt32, digest: String, emailID: UUID?)] {
        var out: [String: (String, UInt32, UInt32, String, UUID?)] = [:]
        for row in try await sink.store.remoteMessageDigests() where row.account == account {
            guard case .imap(let m, let v, let u) = try ProviderMessageIdentity(key: row.key) else { XCTFail("not IMAP"); continue }
            out["\(m)|\(v)|\(u)"] = (m, v, u, row.digest, row.emailID)
        }
        return out.mapValues { (mailbox: $0.0, validity: $0.1, uid: $0.2, digest: $0.3, emailID: $0.4) }
    }

    /// Every record's bytes equal the server's bytes for that exact identity.
    func assertByteExact(_ sink: ConnectedArchiveSink, account: UUID, oracle: [String: Data],
                         file: StaticString = #filePath, line: UInt = #line) async throws {
        let recs = try await records(sink, account: account)
        for (key, r) in recs {
            guard let expected = oracle[key] else { XCTFail("unexpected record \(key)", file: file, line: line); continue }
            XCTAssertEqual(r.digest, Self.sha(expected), "\(key) preserved byte-exact", file: file, line: line)
            XCTAssertTrue(sink.store.blobStore.exists(BlobReference(digest: r.digest, length: 0)), "\(key) has its bytes", file: file, line: line)
        }
    }

    /// The server's current content as identity key → bytes.
    func oracle(_ model: IMAPServerModel) -> [String: Data] {
        var out: [String: Data] = [:]
        for m in model.mailboxes { for msg in m.messages { out["\(m.name)|\(m.uidValidity)|\(msg.uid)"] = msg.bytes } }
        return out
    }

    static let unicodeTree: [(String, [String])] = [
        ("INBOX", ["\\HasNoChildren"]),
        ("Archiv", ["\\Noselect", "\\HasChildren"]),
        ("Archiv/2024", ["\\HasChildren"]),
        ("Archiv/2024/Entwürfe", ["\\HasNoChildren", "\\Drafts"]),
        ("日本語", ["\\HasChildren"]),
        ("日本語/受信トレイ", ["\\HasNoChildren"]),
        ("Sent Messages", ["\\HasNoChildren", "\\Sent"]),
        ("Leer \"quoted\" & more", ["\\HasNoChildren"]),
    ]

    func seedUnicodeTree(_ model: IMAPServerModel) {
        for (name, attrs) in Self.unicodeTree { model.addMailbox(name, attributes: attrs) }
        for i in 0..<5 { model.add(Self.message("inbox-\(i)"), to: "INBOX", flags: i == 0 ? ["\\Flagged"] : []) }
        for i in 0..<3 { model.add(Self.message("entwurf-\(i)"), to: "Archiv/2024/Entwürfe") }
        model.add(Self.message("2024-a"), to: "Archiv/2024")
        for i in 0..<4 { model.add(Self.message("jp-\(i)"), to: "日本語/受信トレイ") }
        model.add(Self.message("sent-0"), to: "Sent Messages")
    }

    // MARK: Full capture through the real engine

    func runFullCapture(utf8: Bool, qresync: Bool, namesAsLiterals: Bool) async throws {
        let server = try await startServer { m in
            if !utf8 { m.postAuthCapabilities.removeAll { $0 == "UTF8=ACCEPT" } }
            if !qresync { m.postAuthCapabilities.removeAll { ["QRESYNC", "CONDSTORE", "ESEARCH"].contains($0) } }
            m.namesAsLiterals = namesAsLiterals
            m.writeChunk = 61          // responses arrive in many small packets
        }
        let model = server.model
        seedUnicodeTree(model)
        let sink = makeSink()
        let adapter = try makeAdapter(server, pageSize: 3)
        try await register(adapter, in: sink)
        let asks = Box<[NetworkAsk]>([])
        let engine = makeEngine(adapter, sink, asks: asks)

        let report = await engine.sync()
        XCTAssertEqual(report.outcome, .completed, "\(report.outcome)")
        XCTAssertEqual(report.receipt?.stored, 14)
        XCTAssertEqual(report.receipt?.pending, 0)
        try await assertByteExact(sink, account: adapter.accountID, oracle: oracle(model))
        let recs = try await records(sink, account: adapter.accountID)
        XCTAssertEqual(recs.count, 14)

        // Folder tree: every listed folder (empty + \Noselect included), nested Unicode paths.
        let counts = try await sink.store.connectedTableCounts()
        XCTAssertEqual(counts["remote_folders"], Self.unicodeTree.count)
        let nodes = try await sink.store.folderNodes()
        let byPath = Dictionary(nodes.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(byPath["Archiv/2024/Entwürfe"]?.messageCount, 3, "\(nodes.map(\.path))")
        XCTAssertEqual(byPath["日本語/受信トレイ"]?.messageCount, 4)
        XCTAssertEqual(byPath["Archiv/2024"]?.messageCount, 1)
        XCTAssertEqual(byPath["Sent Messages"]?.messageCount, 1)
        XCTAssertEqual(byPath["Leer \"quoted\" & more"]?.messageCount, 0, "an empty folder is preserved in the tree")
        XCTAssertEqual(byPath["Leer \"quoted\" & more"]?.declared, true)
        XCTAssertNotNil(byPath["Archiv"], "the \\Noselect parent is in the tree")
        XCTAssertTrue(asks.value.allSatisfy { $0.host == "127.0.0.1" && $0.destination == .mailServer })

        // T24 — read-only, by the server's transcript.
        let transcript = model.transcript
        let commands = transcript.map { line -> String in
            let words = line.split(separator: " ")
            return words.count > 1 ? words[1].uppercased() + (words[1].uppercased() == "UID" && words.count > 2 ? " " + words[2].uppercased() : "") : ""
        }
        for forbidden in ["SELECT", "STORE", "EXPUNGE", "COPY", "MOVE", "APPEND", "FETCH", "SEARCH", "UID STORE", "UID EXPUNGE",
                          "UID MOVE", "UID COPY", "DELETE", "RENAME", "CREATE", "SUBSCRIBE"] {
            XCTAssertFalse(commands.contains(forbidden), "\(forbidden) was sent")
        }
        XCTAssertTrue(commands.contains("EXAMINE"))
        let bodyFetches = transcript.filter { $0.uppercased().contains("BODY") }
        XCTAssertEqual(bodyFetches.count, 14)
        XCTAssertTrue(bodyFetches.allSatisfy { $0.contains(" UID FETCH ") && $0.contains("BODY.PEEK[]") && !$0.contains(" BODY[]") })
        for m in model.mailboxes { for msg in m.messages { XCTAssertFalse(msg.flags.contains("\\Seen"), "\(m.name) \(msg.uid) stays unread") } }

        // Second run: nothing new → nothing downloaded again.
        let again = await engine.sync()
        XCTAssertEqual(again.outcome, .completed)
        XCTAssertEqual(again.receipt?.stored, 0)

        // Arrivals and an expunge → only the arrival is downloaded; the
        // expunged message stays preserved (projection: removed on server).
        let removedUID: UInt32 = 2
        let removedKey = "INBOX|\(model.mailboxes[0].uidValidity)|\(removedUID)"
        model.expunge(removedUID, from: "INBOX")
        model.add(Self.message("inbox-new"), to: "INBOX")
        model.add(Self.message("jp-new"), to: "日本語/受信トレイ")
        model.clearTranscript()
        let third = await engine.sync()
        XCTAssertEqual(third.outcome, .completed, "\(third.outcome)")
        XCTAssertEqual(third.receipt?.stored, 2)
        let after = try await records(sink, account: adapter.accountID)
        XCTAssertEqual(after.count, 16)
        XCTAssertNotNil(after[removedKey], "a server deletion never deletes preserved mail")
        let completeness = try await sink.completeness(accountID: adapter.accountID)
        XCTAssertEqual(completeness.acquisition.removedOnServer, 1)
        if qresync {
            XCTAssertTrue(model.transcript.contains { $0.contains("CHANGEDSINCE") && $0.contains("VANISHED") }, "QRESYNC used when offered")
        } else {
            XCTAssertTrue(model.transcript.contains { $0.hasSuffix("UID SEARCH ALL") }, "plain IMAP reconciles by UID SEARCH")
            XCTAssertFalse(model.transcript.contains { $0.contains("CHANGEDSINCE") })
        }
        await adapter.disconnect()
    }

    func testFullCapture_UTF8Accept_QRESYNC_realEngine_byteExact_readOnly() async throws {
        try await runFullCapture(utf8: true, qresync: true, namesAsLiterals: false)
    }

    func testFullCapture_modifiedUTF7_literalNames_plainIMAP_realEngine_byteExact_readOnly() async throws {
        try await runFullCapture(utf8: false, qresync: false, namesAsLiterals: true)
    }

    // MARK: T11

    func testT11_UIDVALIDITYChange_newGeneration_noNewMessageOnAnOldUID_nothingPreservedLost() async throws {
        let server = try await startServer { $0.bodyDelay = 0.03 }
        let model = server.model
        model.addMailbox("INBOX")
        for i in 0..<8 { model.add(Self.message("old-\(i)"), to: "INBOX") }
        let before = oracle(model)
        let oldValidity = model.mailboxes[0].uidValidity
        let sink = makeSink()
        // Two pooled connections: both hold a selection made under the OLD
        // UIDVALIDITY when the second run starts (the stale-selection case).
        let adapter = try makeAdapter(server, maxConnections: 2)
        try await register(adapter, in: sink)
        let engine = makeEngine(adapter, sink)
        let first = await engine.sync()
        XCTAssertEqual(first.outcome, .completed)
        let opened = await adapter.connectionsOpened
        XCTAssertEqual(opened, 2)

        // The server rebuilds the mailbox: UIDs 1…6 now name DIFFERENT messages.
        model.resetUIDValidity("INBOX", contents: [Self.message("new-0"), Self.message("old-1"), Self.message("new-2"),
                                                   Self.message("new-3"), Self.message("new-4"), Self.message("new-5")])
        XCTAssertNotEqual(model.mailboxes[0].uidValidity, oldValidity)
        let second = await engine.sync()
        XCTAssertEqual(second.outcome, .completed, "\(second.outcome)")
        XCTAssertTrue(second.fullEnumeration, "a UIDVALIDITY change is a full reconciliation")
        XCTAssertEqual(second.receipt?.stored, 6, "every message under the new UIDVALIDITY is its own identity")
        XCTAssertEqual(second.receipt?.unavailable, 0, "a stale pooled selection never turns a live message into 'unavailable'")

        var expected = before
        expected.merge(oracle(model)) { a, _ in a }
        try await assertByteExact(sink, account: adapter.accountID, oracle: expected)
        let recs = try await records(sink, account: adapter.accountID)
        XCTAssertEqual(recs.count, 14)
        XCTAssertEqual(recs.values.filter { $0.validity == oldValidity }.count, 8, "the old generation stays preserved")
        // Old UID 1 still holds old-0's bytes, never new-0's.
        XCTAssertEqual(recs["INBOX|\(oldValidity)|1"]?.digest, Self.sha(Self.message("old-0")))
    }

    func testT11_sequenceRenumbering_isIrrelevant_identitiesAreUIDs() async throws {
        let server = try await startServer { $0.uidAfterBody = true }
        let model = server.model
        model.addMailbox("INBOX")
        for i in 0..<6 { model.add(Self.message("m-\(i)"), to: "INBOX") }
        let sink = makeSink()
        let adapter = try makeAdapter(server, pageSize: 2)
        try await register(adapter, in: sink)
        let engine = makeEngine(adapter, sink)
        _ = await engine.sync()

        // Expunging the first messages shifts every sequence number.
        model.expunge(1, from: "INBOX"); model.expunge(2, from: "INBOX")
        model.add(Self.message("m-new"), to: "INBOX")
        let report = await engine.sync()
        XCTAssertEqual(report.outcome, .completed)
        XCTAssertEqual(report.receipt?.stored, 1)
        var expected = oracle(model)
        let v = model.mailboxes[0].uidValidity
        expected["INBOX|\(v)|1"] = Self.message("m-0"); expected["INBOX|\(v)|2"] = Self.message("m-1")
        try await assertByteExact(sink, account: adapter.accountID, oracle: expected)
        let newest = try await records(sink, account: adapter.accountID)["INBOX|\(v)|7"]
        XCTAssertEqual(newest?.digest, Self.sha(Self.message("m-new")))
    }

    func testT11_folderRename_newPathCaptured_oldRecordsKept() async throws {
        let server = try await startServer()
        let model = server.model
        model.addMailbox("INBOX")
        model.addMailbox("Projekte/Alpha")
        for i in 0..<3 { model.add(Self.message("p-\(i)"), to: "Projekte/Alpha") }
        let original = oracle(model)
        let sink = makeSink()
        let adapter = try makeAdapter(server)
        try await register(adapter, in: sink)
        let engine = makeEngine(adapter, sink)
        let first = await engine.sync()
        XCTAssertEqual(first.outcome, .completed)

        model.rename("Projekte/Alpha", to: "Projekte/Beta – 2025")
        let report = await engine.sync()
        XCTAssertEqual(report.outcome, .completed, "\(report.outcome)")
        var expected = original
        expected.merge(oracle(model)) { a, _ in a }
        try await assertByteExact(sink, account: adapter.accountID, oracle: expected)
        let recs = try await records(sink, account: adapter.accountID)
        XCTAssertEqual(recs.values.filter { $0.mailbox == "Projekte/Alpha" }.count, 3, "kept")
        XCTAssertEqual(recs.values.filter { $0.mailbox == "Projekte/Beta – 2025" }.count, 3, "the renamed folder is listed and captured")
    }

    // MARK: Security

    func testSTARTTLSAbsent_overLocalhost_noAuthSent_runStopsWithoutCompletion() async throws {
        let server = try await startServer { m in
            m.offerSTARTTLS = false
            m.greeting = "* OK mailin test server ready"       // capabilities must be asked for
        }
        server.model.addMailbox("INBOX")
        let sink = makeSink()
        let adapter = try makeAdapter(server, security: .startTLS)
        try await register(adapter, in: sink)
        let report = await makeEngine(adapter, sink).sync()
        XCTAssertFalse(report.outcome.isCompletion)
        guard case .failed(let why) = report.outcome else { return XCTFail("\(report.outcome)") }
        XCTAssertTrue(why.contains("STARTTLS"), why)
        let transcript = server.model.transcript
        XCTAssertFalse(transcript.contains { $0.uppercased().contains("LOGIN") || $0.uppercased().contains("AUTHENTICATE") }, "\(transcript)")
        XCTAssertFalse(transcript.joined().contains(server.model.password))
    }

    func testImplicitTLS_toAPlaintextServer_sendsNoCredentials() async throws {
        let server = try await startServer()
        server.model.addMailbox("INBOX")
        let adapter = try makeAdapter(server, security: .implicitTLS)
        do {
            _ = try await adapter.listFolders(pageToken: nil, context: ProviderRequestContext(accountID: adapter.accountID, accessToken: nil, attempt: 0))
            XCTFail("a TLS handshake with a plaintext server cannot succeed")
        } catch let e as MailProviderError {
            if case .transient = e {} else { XCTFail("\(e)") }
        }
        XCTAssertFalse(server.model.transcript.contains { $0.contains("LOGIN") || $0.contains("AUTHENTICATE") })
    }

    func testPlaintextModeRefusedForNonLoopbackHost_andPermissionAskedBeforeConnecting() async throws {
        let server = try await startServer()
        server.model.addMailbox("INBOX")
        let ctx = { (a: IMAPAdapter) in ProviderRequestContext(accountID: a.accountID, accessToken: nil, attempt: 0) }

        let remote = try makeAdapter(server, host: "imap.example.com")
        do { _ = try await remote.listFolders(pageToken: nil, context: ctx(remote)); XCTFail() }
        catch MailProviderError.permanent(let why) { XCTAssertTrue(why.contains("without encryption"), why) }

        struct No: LocalizedError { var errorDescription: String? { "Mail is switched off." } }
        let asks = Box<[NetworkAsk]>([])
        let refused = try makeAdapter(server, permission: { ask in asks.mutate { $0.append(ask) }; throw No() })
        do { _ = try await refused.listFolders(pageToken: nil, context: ctx(refused)); XCTFail() }
        catch MailProviderError.permanent(let why) { XCTAssertTrue(why.contains("not permitted"), why) }
        XCTAssertEqual(asks.value.count, 1)
        XCTAssertEqual(asks.value.first?.host, "127.0.0.1")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(server.model.connections, 0, "no connection before permission")
    }

    func testWrongPassword_needsSignIn_notRetriedForever() async throws {
        let server = try await startServer()
        server.model.addMailbox("INBOX")
        let sink = makeSink()
        let adapter = try makeAdapter(server, password: "wrong")
        try await register(adapter, in: sink)
        let report = await makeEngine(adapter, sink).sync()
        XCTAssertEqual(report.outcome, .needsSignIn)
        XCTAssertEqual(server.model.connections, 1)
    }

    func testXOAUTH2_tokenFromCredentialStore() async throws {
        let server = try await startServer { m in
            m.oauthToken = "access-123"
            m.greeting = "* OK mailin test server ready"       // capabilities asked for: AUTH=XOAUTH2 is listed
        }
        server.model.addMailbox("INBOX")
        server.model.add(Self.message("o-1"), to: "INBOX")
        let account = UUID()
        let creds = InMemoryCredentialStore()
        let set = OAuthTokenSet(accountID: account, issuer: "https://accounts.example", audience: "imap", accessToken: "access-123",
                                refreshToken: "r", expiresAt: Date().addingTimeInterval(3600), scopes: [])
        try creds.write(try set.encoded(), kind: .oauthTokenSet, account: account)
        let config = IMAPAccountConfiguration(host: "127.0.0.1", port: server.port, security: .plaintextLoopbackOnly,
                                              login: server.model.login, auth: .oauth2(audience: "imap", authorizationHost: "auth.example"))
        let adapter = IMAPAdapter(accountID: account, configuration: config, credentials: creds)
        let page = try await adapter.listFolders(pageToken: nil, context: ProviderRequestContext(accountID: account, accessToken: nil, attempt: 0))
        XCTAssertEqual(page.folders.map(\.serverID), ["INBOX"])
        XCTAssertTrue(server.model.transcript.contains { $0.contains("AUTHENTICATE XOAUTH2") })
        XCTAssertFalse(adapter.log.lines.joined().contains("access-123"))
        XCTAssertFalse(adapter.log.lines.joined().contains(Data("user=asha\u{1}auth=Bearer access-123\u{1}\u{1}".utf8).base64EncodedString()))
        await adapter.disconnect()
    }

    // MARK: Accounts

    func testTwoServersWithTheSameLogin_stayDistinct() async throws {
        let a = try await startServer { $0.password = "alpha-pass" }
        let b = try await startServer { $0.password = "beta-pass" }
        for s in [a, b] {
            s.model.addMailbox("INBOX")
            s.model.add(Self.message("same"), to: "INBOX")               // same Message-ID, same mailbox, same UID
        }
        b.model.add(Self.message("only-b"), to: "INBOX")
        let creds = InMemoryCredentialStore()                             // ONE store for both accounts
        let sink = makeSink()
        let adA = try makeAdapter(a, credentials: creds, password: "alpha-pass")
        let adB = try makeAdapter(b, credentials: creds, password: "beta-pass")
        XCTAssertEqual(a.model.login, b.model.login)
        for ad in [adA, adB] { try await register(ad, in: sink) }
        let ra = await makeEngine(adA, sink).sync()
        let rb = await makeEngine(adB, sink).sync()
        XCTAssertEqual(ra.outcome, .completed); XCTAssertEqual(rb.outcome, .completed)
        let recA = try await records(sink, account: adA.accountID)
        let recB = try await records(sink, account: adB.accountID)
        XCTAssertEqual(recA.count, 1); XCTAssertEqual(recB.count, 2)
        XCTAssertNotEqual(recA.values.first?.emailID, recB.values.first { $0.uid == 1 }?.emailID, "separate records per account")
        XCTAssertTrue(a.model.transcript.contains { $0.contains("AUTHENTICATE PLAIN") })
        // Each server saw only its own account's secret.
        let plainA = Data("\u{0}asha\u{0}alpha-pass".utf8).base64EncodedString()
        let plainB = Data("\u{0}asha\u{0}beta-pass".utf8).base64EncodedString()
        XCTAssertTrue(a.model.transcript.joined().contains(plainA)); XCTAssertFalse(a.model.transcript.joined().contains(plainB))
        XCTAssertTrue(b.model.transcript.joined().contains(plainB)); XCTAssertFalse(b.model.transcript.joined().contains(plainA))
    }

    // MARK: Resilience

    func testDropMidLiteral_reconnectsWithBackoff_nothingShortPreserved() async throws {
        let server = try await startServer { $0.dropOnBodyOfUID = 2 }
        let model = server.model
        model.addMailbox("INBOX")
        for i in 0..<3 { model.add(Self.message("r-\(i)", extra: String(repeating: "x", count: 5_000)), to: "INBOX") }
        let sink = makeSink()
        let sleeps = Box<[TimeInterval]>([])
        let adapter = try makeAdapter(server, maxConnections: 1, reconnectSleeps: sleeps)
        try await register(adapter, in: sink)
        let report = await makeEngine(adapter, sink).sync()
        XCTAssertEqual(report.outcome, .completed, "\(report.outcome)")
        XCTAssertEqual(report.receipt?.stored, 3)
        try await assertByteExact(sink, account: adapter.accountID, oracle: oracle(model))
        let opened = await adapter.connectionsOpened
        XCTAssertGreaterThanOrEqual(opened, 2, "a new connection after the drop")
        XCTAssertGreaterThanOrEqual(model.connections, 2)
    }

    func testReconnectPolicy_exponentialAndCapped() {
        let p = IMAPReconnectPolicy(base: 1, maximum: 8, sleep: { _ in })
        XCTAssertEqual((0...6).map { p.delay(afterFailures: $0) }, [0, 1, 2, 4, 8, 8, 8])
    }

    func testSparseUIDs_pagedByUIDRanges_everyMessageListed_noOpenEndedRange() async throws {
        let server = try await startServer()
        let model = server.model
        model.addMailbox("INBOX")
        var expectedUIDs: [UInt32] = []
        for i in 0..<25 {
            expectedUIDs.append(model.add(Self.message("s-\(i)"), to: "INBOX"))
            model.skipUIDs(UInt32(i % 3 == 0 ? 10_000 : 1), in: "INBOX")
        }
        let adapter = try makeAdapter(server, pageSize: 4)
        let ctx = ProviderRequestContext(accountID: adapter.accountID, accessToken: nil, attempt: 0)
        let folders = try await adapter.listFolders(pageToken: nil, context: ctx)
        var listed: [UInt32] = []
        var cursor: String?
        var pages = 0
        repeat {
            let page = try await adapter.enumerate(folder: folders.folders[0], cursor: cursor, pageSize: 4, context: ctx)
            XCTAssertLessThanOrEqual(page.items.count, 4)
            for item in page.items { if case .imap(_, _, let u) = item.identity { listed.append(u) } }
            cursor = page.nextCursor
            pages += 1
        } while cursor != nil && pages < 1_000
        XCTAssertEqual(listed, expectedUIDs, "complete, ordered, no duplicates")
        XCTAssertFalse(model.transcript.contains { $0.contains("UID FETCH") && $0.contains(":*") }, "bounded ranges only")
        await adapter.disconnect()
    }

    func testIDLE_reportsArrival_andTimesOut() async throws {
        let server = try await startServer()
        server.model.addMailbox("INBOX")
        let adapter = try makeAdapter(server)
        let ctx = ProviderRequestContext(accountID: adapter.accountID, accessToken: nil, attempt: 0)
        let inbox = try await adapter.listFolders(pageToken: nil, context: ctx).folders[0]
        let quiet = try await adapter.waitForChange(in: inbox, timeout: 0.2, context: ctx)
        XCTAssertFalse(quiet)
        let pusher = Task {
            try await Task.sleep(nanoseconds: 200_000_000)
            server.pushToIdlers("* 1 EXISTS")
        }
        let changed = try await adapter.waitForChange(in: inbox, timeout: 5, context: ctx)
        XCTAssertTrue(changed)
        _ = try await pusher.value
        XCTAssertTrue(server.model.transcript.contains("DONE"))
        await adapter.disconnect()
    }

    func testPresets() {
        XCTAssertEqual(IMAPProviderPreset.iCloud.host, "imap.mail.me.com")
        XCTAssertEqual(IMAPProviderPreset.iCloud.security, .implicitTLS)
        XCTAssertEqual(IMAPProviderPreset.fastmail.host, "imap.fastmail.com")
        XCTAssertEqual(IMAPProviderPreset.generic(host: "mail.example.org", port: 143, security: .startTLS).configuration(login: "a").security, .startTLS)
        for p in [IMAPProviderPreset.iCloud, .fastmail, .generic(host: "x")] {
            XCTAssertFalse(p.verifiedAgainstRealServer, "a preset is not proof of compatibility")
            XCTAssertNotEqual(p.security, .plaintextLoopbackOnly)
        }
    }
}
