//
//  GmailRetryLocateTests.swift
//  MailConnectivityTests
//
//  Review B10 (2026-11-16): an earlier failure is retried with no folder
//  (`RemoteItemRef(identity:, folder: nil)`, SyncEngine.retryEarlierFailures).
//  On Gmail with [Gmail]/All Mail hidden from IMAP the adapter had nowhere to
//  look, threw `.itemUnavailable`, and the engine recorded the still-present
//  message as terminally "Deleted or moved on the server". The adapter now
//  finds it by UID SEARCH X-GM-MSGID in the listed folders.
//

import XCTest
import Foundation
import CryptoKit
@testable import MailConnectivity
@testable import ArchiveCore

final class GmailRetryLocateTests: XCTestCase {
    private var dir: URL!
    private var servers: [LocalIMAPServer] = []

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("gmail-retry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for s in servers { s.stop() }
        servers = []
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    /// Gmail's layout with All Mail hidden from IMAP ("Show in IMAP" off).
    private static let hiddenAllMailTree: [(String, [String])] = [
        ("INBOX", ["\\HasNoChildren"]),
        ("Work", ["\\HasNoChildren"]),
        ("[Gmail]", ["\\Noselect", "\\HasChildren"]),
        ("[Gmail]/Sent Mail", ["\\HasNoChildren", "\\Sent"]),
        ("[Gmail]/Spam", ["\\HasNoChildren", "\\Junk"]),
        ("[Gmail]/Trash", ["\\HasNoChildren", "\\Trash"]),
    ]

    private static func message(_ id: String) -> Data {
        Data(("Message-ID: <\(id)@gmail.example>\r\nFrom: a@example.com\r\nTo: b@example.org\r\nSubject: \(id)\r\n"
              + "Date: Mon, 6 Jan 2025 10:00:00 +0000\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n"
              + "Body \(id)\r\n").utf8)
    }

    private static func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    private func startServer() async throws -> LocalIMAPServer {
        let model = IMAPServerModel()
        model.postAuthCapabilities.append("X-GM-EXT-1")
        for (name, attrs) in Self.hiddenAllMailTree { model.addMailbox(name, attributes: attrs) }
        let server = try LocalIMAPServer(model: model)
        try await server.start()
        servers.append(server)
        return server
    }

    private func makeAdapter(_ server: LocalIMAPServer) throws -> IMAPAdapter {
        let account = UUID()
        let credentials = InMemoryCredentialStore()
        try credentials.write(Data(server.model.password.utf8), kind: .password, account: account)
        let config = IMAPAccountConfiguration(host: "127.0.0.1", port: server.port, security: .plaintextLoopbackOnly,
                                              login: server.model.login, maxConnections: 2, pageSize: 500, timeout: 10)
        return IMAPAdapter(accountID: account, configuration: config, credentials: credentials,
                           transportFactory: IMAPTransports.system, permission: nil,
                           reconnect: IMAPReconnectPolicy(base: 1, maximum: 8, sleep: { _ in }))
    }

    /// A retried message (folder nil, no listing to hand) that is still on the
    /// server in a label folder is fetched, byte-exact — not "unavailable".
    func testRetryWithNoFolder_allMailHidden_findsMessageInAListedFolder() async throws {
        let server = try await startServer()
        let bytes = Self.message("gm-work-only")
        let id: UInt64 = 1_766_000_000_000_042
        server.model.addGmail(bytes, msgID: id, labels: ["Work"], in: ["Work"])
        let sink = ConnectedArchiveSink(storeDirectory: dir.appendingPathComponent("archive", isDirectory: true))
        let adapter = try makeAdapter(server)
        let ctx = ProviderRequestContext(accountID: adapter.accountID, accessToken: nil, attempt: 0)
        _ = try await adapter.listFolders(pageToken: nil, context: ctx)
        let limits = await adapter.listingLimits
        XCTAssertEqual(limits.map(\.code), [IMAPErrorCode.gmailAllMailHidden], "precondition: All Mail is hidden")

        let raw = RawByteSink(writer: try sink.makeStagingWriter())
        let fetched: FetchedItemMetadata
        do {
            fetched = try await adapter.fetchRaw(RemoteItemRef(identity: .gmailIMAP(messageID: id), folder: nil),
                                                 into: raw, context: ctx)
        } catch {
            raw.discard()
            XCTFail("a message still on the server was reported \(error)")
            await adapter.disconnect()
            return
        }
        let staged = try raw.finish()
        defer { try? FileManager.default.removeItem(at: staged.fileURL) }
        XCTAssertEqual(staged.sha256, Self.sha(bytes), "preserved byte-exact")
        XCTAssertEqual(fetched.occurrences.map(\.serverID), ["Work"])
        XCTAssertEqual(fetched.metadata.extra["imap.mailbox"], "Work")
        XCTAssertEqual(fetched.metadata.extra["imap.gmailMessageID"], String(id))
        XCTAssertTrue(server.model.transcript.contains { $0.hasSuffix("UID SEARCH X-GM-MSGID \(id)") })
        // Read-only throughout.
        for forbidden in [" SELECT ", " STORE ", " EXPUNGE", " COPY ", " MOVE "] {
            XCTAssertFalse(server.model.transcript.contains { $0.uppercased().contains(forbidden) }, "\(forbidden) was sent")
        }
        await adapter.disconnect()
    }

    /// A message only in Trash is still found (searched last), and one on no
    /// listed folder is still `.itemUnavailable`.
    func testRetryWithNoFolder_allMailHidden_trashIsSearched_andAGoneMessageIsUnavailable() async throws {
        let server = try await startServer()
        let trashed = Self.message("gm-trashed")
        let trashedID: UInt64 = 1_766_000_000_000_043
        server.model.addGmail(trashed, msgID: trashedID, labels: ["\\Trash"], in: ["[Gmail]/Trash"])
        let sink = ConnectedArchiveSink(storeDirectory: dir.appendingPathComponent("archive", isDirectory: true))
        let adapter = try makeAdapter(server)
        let ctx = ProviderRequestContext(accountID: adapter.accountID, accessToken: nil, attempt: 0)
        _ = try await adapter.listFolders(pageToken: nil, context: ctx)

        let raw = RawByteSink(writer: try sink.makeStagingWriter())
        do {
            _ = try await adapter.fetchRaw(RemoteItemRef(identity: .gmailIMAP(messageID: trashedID), folder: nil),
                                           into: raw, context: ctx)
            let staged = try raw.finish()
            XCTAssertEqual(staged.sha256, Self.sha(trashed))
            try? FileManager.default.removeItem(at: staged.fileURL)
        } catch {
            raw.discard()
            XCTFail("a message in Trash was reported \(error)")
        }

        let gone = RawByteSink(writer: try sink.makeStagingWriter())
        do {
            _ = try await adapter.fetchRaw(RemoteItemRef(identity: .gmailIMAP(messageID: 7), folder: nil), into: gone, context: ctx)
            XCTFail("a message on no folder must not be fetched")
        } catch let e as MailProviderError {
            XCTAssertEqual(e, .itemUnavailable)
        }
        gone.discard()
        await adapter.disconnect()
    }
}
