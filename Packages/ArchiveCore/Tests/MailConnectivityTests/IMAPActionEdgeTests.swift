//
//  IMAPActionEdgeTests.swift
//  MailConnectivityTests
//
//  Review 2026-11-16 E:
//    • `UID MOVE` on a QRESYNC server without COPYUID: the server reports the
//      source's removal as `* VANISHED <uid>` (RFC 7162 §3.2.10), not
//      `* n EXPUNGE`; a completed move must not be recorded as a conflict.
//    • OAUTHBEARER's gs2 header carries the login as an RFC 5801 saslname
//      ("=" → "=3D", "," → "=2C"); XOAUTH2 sends it unescaped.
//

import XCTest
import Foundation
@testable import MailConnectivity
@testable import ArchiveCore

/// A real loopback transport whose received bytes are rewritten: every
/// `* n EXPUNGE` line answering a `UID MOVE <uid>` becomes `* VANISHED <uid>`
/// — what a QRESYNC-enabled server sends instead.
private final class VanishedRewritingTransport: IMAPByteTransport, @unchecked Sendable {
    private let inner: any IMAPByteTransport
    private let lock = NSLock()
    private var movedUID: String?
    init(_ inner: any IMAPByteTransport) { self.inner = inner }

    func receive() async throws -> Data? { rewrite(try await inner.receive()) }
    func receive(timeout: TimeInterval?) async throws -> Data? { rewrite(try await inner.receive(timeout: timeout)) }
    func send(_ data: Data) async throws {
        let text = String(decoding: data, as: UTF8.self)
        if let r = text.range(of: "UID MOVE ") {
            let uid = text[r.upperBound...].prefix { $0.isNumber }
            lock.withLock { movedUID = String(uid) }
        }
        try await inner.send(data)
    }
    func upgradeToTLS() async throws { try await inner.upgradeToTLS() }
    var isEncrypted: Bool { inner.isEncrypted }
    func close() { inner.close() }

    private func rewrite(_ data: Data?) -> Data? {
        guard let data, let uid = lock.withLock({ movedUID }) else { return data }
        let text = String(decoding: data, as: UTF8.self)
        guard text.contains(" EXPUNGE\r\n") else { return data }
        let lines = text.components(separatedBy: "\r\n").map { line -> String in
            let w = line.split(separator: " ")
            if w.count == 3, w[0] == "*", UInt64(w[1]) != nil, w[2] == "EXPUNGE" { return "* VANISHED \(uid)" }
            return line
        }
        return Data(lines.joined(separator: "\r\n").utf8)
    }
}

final class IMAPActionEdgeTests: XCTestCase {
    private var dir: URL!
    private var servers: [LocalIMAPServer] = []

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("imap-edge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for s in servers { s.stop() }
        servers = []
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    static func message(_ id: String) -> Data {
        Data("Message-ID: <\(id)@example.com>\r\nFrom: Asha <asha@example.com>\r\nTo: ravi@example.org\r\nSubject: \(id)\r\nDate: Mon, 6 Jan 2025 10:00:00 +0000\r\n\r\nBody of \(id)\r\n".utf8)
    }

    // MARK: UID MOVE + VANISHED

    /// A MOVE-capable QRESYNC server without UIDPLUS (so no COPYUID) answers
    /// `UID MOVE` with `* VANISHED <uid>`. Before the fix the move was
    /// recorded as a conflict although the message had been moved.
    func testUIDMoveAnsweredWithVanished_isApplied_notAConflict() async throws {
        let model = IMAPServerModel()
        model.serveServerActions = true
        model.postAuthCapabilities = ["IMAP4rev1", "LITERAL+", "ENABLE", "NAMESPACE", "LIST-EXTENDED", "SPECIAL-USE",
                                      "CONDSTORE", "QRESYNC", "ESEARCH", "MOVE"]          // MOVE, no UIDPLUS
        model.addMailbox("INBOX"); model.addMailbox("Trash", attributes: ["\\Trash"])
        for i in 0..<3 { model.add(Self.message("mv-\(i)"), to: "INBOX") }
        let server = try LocalIMAPServer(model: model)
        try await server.start()
        servers.append(server)

        let account = MailAccount(provider: .imap, host: "127.0.0.1", port: Int(server.port), loginName: model.login,
                                  displayIdentity: "asha@127.0.0.1", enabledModes: [.capture, .serverActions], connectionState: .connected)
        let credentials = InMemoryCredentialStore()
        try credentials.write(Data(model.password.utf8), kind: .password, account: account.id)
        let config = IMAPAccountConfiguration(host: "127.0.0.1", port: server.port, security: .plaintextLoopbackOnly,
                                              login: model.login, maxConnections: 1, timeout: 10)
        let adapter = IMAPAdapter(accountID: account.id, configuration: config, credentials: credentials,
                                  transportFactory: { ep in VanishedRewritingTransport(try await IMAPTransports.system(ep)) },
                                  reconnect: IMAPReconnectPolicy(base: 1, maximum: 1, sleep: { _ in }))
        let executor = IMAPActionExecutor(adapter: adapter, trashMailbox: "Trash", permission: { _ in })
        let journal = try RemoteOperationJournal(storeDirectory: dir.appendingPathComponent("journal", isDirectory: true))
        let service = RemoteActionService(account: account, executor: executor, journal: journal, changePermission: { _ in })

        let validity = model.mailboxes.first { $0.name == "INBOX" }!.uidValidity
        let op = try await service.perform(.imap(mailbox: "INBOX", uidValidity: validity, uid: 2), .moveToTrash(from: "INBOX"))
        guard case .applied(verified: false, alreadyInState: false)? = op.outcome else {
            return XCTFail("a move the server confirmed with VANISHED is applied (unconfirmed new UID), got \(String(describing: op.outcome))")
        }
        XCTAssertEqual(model.mailboxes.first { $0.name == "INBOX" }!.messages.map(\.uid), [1, 3])
        XCTAssertEqual(model.mailboxes.first { $0.name == "Trash" }!.messages.count, 1)
        XCTAssertTrue(model.transcript.contains { $0.uppercased().contains("UID MOVE 2") })
    }

    /// The evidence rule itself: EXPUNGE, or VANISHED naming the UID (single,
    /// range, list). VANISHED (EARLIER), another UID, or nothing is not evidence.
    func testSourceRemovedEvidence() throws {
        func result(_ lines: [String]) throws -> IMAPCommandResult {
            let framer = IMAPResponseFramer()
            let raws = try framer.feed(Data(lines.map { $0 + "\r\n" }.joined().utf8))
            XCTAssertEqual(raws.count, lines.count)
            let untagged = try raws.map { try IMAPResponseParser.parse($0) }
            return IMAPCommandResult(untagged: untagged, completion: IMAPStatusResponse(status: .ok, code: nil, text: "done"))
        }
        XCTAssertTrue(IMAPActionExecutor.sourceRemoved(try result(["* 4 EXPUNGE"]), uid: 9))
        XCTAssertTrue(IMAPActionExecutor.sourceRemoved(try result(["* VANISHED 9"]), uid: 9))
        XCTAssertTrue(IMAPActionExecutor.sourceRemoved(try result(["* VANISHED 1:3,7:12"]), uid: 9))
        XCTAssertFalse(IMAPActionExecutor.sourceRemoved(try result(["* VANISHED 10"]), uid: 9))
        XCTAssertFalse(IMAPActionExecutor.sourceRemoved(try result(["* VANISHED (EARLIER) 9"]), uid: 9))
        XCTAssertFalse(IMAPActionExecutor.sourceRemoved(try result(["* VANISHED :"]), uid: 9), "malformed: no evidence, no trap")
        XCTAssertFalse(IMAPActionExecutor.sourceRemoved(try result([]), uid: 9))
    }

    // MARK: OAUTHBEARER saslname

    static let endpoint = IMAPEndpoint(host: "imap.example.net", port: 993, security: .implicitTLS)

    func testOAUTHBEARER_loginIsSaslnameEscaped() async throws {
        let t = ScriptedIMAPTransport(packets: [Data("* OK [CAPABILITY IMAP4rev1 AUTH=OAUTHBEARER SASL-IR] hi\r\n".utf8)]) { line, _ in
            [Data("\(line.prefix { $0 != " " }) OK [CAPABILITY IMAP4rev1] ok\r\n".utf8)]
        }
        let s = IMAPSession(transport: t, endpoint: Self.endpoint, log: IMAPProtocolLog())
        try await s.establish(.oauth(login: "a=b,c@example.com", accessToken: "tok"))
        let words = try XCTUnwrap(t.lines.first).split(separator: " ")
        XCTAssertEqual(words.prefix(3).map(String.init), ["M1", "AUTHENTICATE", "OAUTHBEARER"])
        let decoded = String(decoding: try XCTUnwrap(Data(base64Encoded: String(words[3]))), as: UTF8.self)
        XCTAssertEqual(decoded, "n,a=a=3Db=2Cc@example.com,\u{1}host=imap.example.net\u{1}port=993\u{1}auth=Bearer tok\u{1}\u{1}")
        XCTAssertEqual(IMAPSession.saslname("plain@example.com"), "plain@example.com")
        XCTAssertEqual(IMAPSession.saslname("=,="), "=3D=2C=3D")
    }

    func testXOAUTH2_loginIsNotEscaped() async throws {
        let t = ScriptedIMAPTransport(packets: [Data("* OK [CAPABILITY IMAP4rev1 AUTH=XOAUTH2 SASL-IR] hi\r\n".utf8)]) { line, _ in
            [Data("\(line.prefix { $0 != " " }) OK [CAPABILITY IMAP4rev1] ok\r\n".utf8)]
        }
        let s = IMAPSession(transport: t, endpoint: Self.endpoint, log: IMAPProtocolLog())
        try await s.establish(.oauth(login: "a=b,c@example.com", accessToken: "tok"))
        let b64 = Data("user=a=b,c@example.com\u{1}auth=Bearer tok\u{1}\u{1}".utf8).base64EncodedString()
        XCTAssertEqual(t.lines.first, "M1 AUTHENTICATE XOAUTH2 \(b64)")
    }
}
