//
//  ConnectedMailboxListingTests.swift
//  ArchiveCoreTests
//
//  Plan v4 V4-13: what the Mail workspace reads about captured mail — folder
//  and label counts (captured / unread at capture), the capture selection,
//  and keyset pages of captured messages with filters. Every page together
//  lists every matching message exactly once, and the total is the full
//  count, not the page size (no hidden cap).
//

import XCTest
import Foundation
@testable import ArchiveCore

final class ConnectedMailboxListingTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("connected-mailbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func stage(_ sink: ConnectedArchiveSink, _ bytes: Data) throws -> StagedRawMessage {
        let writer = try sink.makeStagingWriter()
        try writer.append(bytes)
        return try writer.finish()
    }

    private func item(_ sink: ConnectedArchiveSink, account: UUID, id: String, labels: [String], flags: [String], day: Int) throws -> CaptureItem {
        let bytes = Data(("Message-ID: <\(id)@example.com>\r\nFrom: Asha <asha@example.com>\r\nTo: ravi@example.org\r\n"
                          + "Subject: Message \(id)\r\nDate: Mon, 6 Jan 2025 10:00:00 +0000\r\nMIME-Version: 1.0\r\n"
                          + "Content-Type: text/plain; charset=utf-8\r\n\r\nBody \(id)\r\n").utf8)
        return CaptureItem(accountID: account, identity: .gmail(messageID: id),
                           occurrences: labels.map { RemoteFolderOccurrence(serverID: $0, displayPath: $0, kind: .label) },
                           raw: try stage(sink, bytes),
                           metadata: ProviderMetadata(representation: .gmailRaw,
                                                      internalDate: Date(timeIntervalSince1970: 1_736_000_000 + Double(day) * 86_400),
                                                      revision: "h-\(id)", flags: flags))
    }

    func testFolderCountsSelectionAndPagedFilteredListing() async throws {
        let sink = ConnectedArchiveSink(storeDirectory: dir)
        let account = UUID()
        try await sink.saveAccount(ConnectedAccountRecord(
            accountID: account, provider: .gmail, issuer: "https://accounts.google.com", displayIdentity: "asha@example.com",
            grantedScopes: [], enabledModes: [], connectionState: "connected", createdAt: Date(), updatedAt: Date()))
        try await sink.recordFolders(accountID: account, folders: [
            RemoteFolderOccurrence(serverID: "INBOX", displayPath: "INBOX", kind: .label),
            RemoteFolderOccurrence(serverID: "Label_P", displayPath: "Projects", kind: .label),
            RemoteFolderOccurrence(serverID: "Label_E", displayPath: "Empty", kind: .label),
        ])
        let run = try await sink.beginRun(accountID: account, selection: "all")
        _ = try await sink.capture(try item(sink, account: account, id: "m1", labels: ["INBOX"], flags: ["UNREAD"], day: 1), runID: run)
        _ = try await sink.capture(try item(sink, account: account, id: "m2", labels: ["INBOX", "Label_P"], flags: ["STARRED"], day: 2), runID: run)
        _ = try await sink.capture(try item(sink, account: account, id: "m3", labels: ["Label_P"], flags: ["UNREAD"], day: 3), runID: run)
        _ = try await sink.finishRun(run)

        let folders = try await sink.folderSummaries(accountID: account)
        let byID = Dictionary(uniqueKeysWithValues: folders.map { ($0.serverID, $0) })
        XCTAssertEqual(byID["INBOX"]?.messages, 2)
        XCTAssertEqual(byID["INBOX"]?.unread, 1)
        XCTAssertEqual(byID["Label_P"]?.messages, 2)
        XCTAssertEqual(byID["Label_P"]?.unread, 1)
        XCTAssertEqual(byID["Label_E"]?.messages, 0, "an empty folder is listed with zero")
        XCTAssertTrue(folders.allSatisfy(\.selected), "every folder is selected until the person deselects one")

        try await sink.setFolderSelected(accountID: account, serverID: "Label_P", selected: false)
        let after = try await sink.folderSummaries(accountID: account)
        XCTAssertEqual(after.first { $0.serverID == "Label_P" }?.selected, false)
        XCTAssertEqual(after.first { $0.serverID == "INBOX" }?.selected, true)

        // Pages of two: every message exactly once, newest first, total = 3.
        var seen: [String] = []
        var cursor: ConnectedMailboxCursor?
        repeat {
            let page = try await sink.mailboxPage(ConnectedMailboxQuery(accountIDs: [account], pageSize: 2), after: cursor)
            XCTAssertEqual(page.total, 3)
            XCTAssertLessThanOrEqual(page.rows.count, 2)
            seen += page.rows.map { row -> String in
                if case .gmail(let id) = row.identity { return id }
                return "?"
            }
            cursor = page.next
        } while cursor != nil
        XCTAssertEqual(seen, ["m3", "m2", "m1"])

        let unread = try await sink.mailboxPage(ConnectedMailboxQuery(accountIDs: [account], unreadOnly: true))
        XCTAssertEqual(unread.total, 2)
        XCTAssertEqual(Set(unread.rows.map(\.isRead)), [false])
        let flagged = try await sink.mailboxPage(ConnectedMailboxQuery(accountIDs: [account], flaggedOnly: true))
        XCTAssertEqual(flagged.total, 1)
        XCTAssertEqual(flagged.rows.first?.isFlagged, true)
        XCTAssertEqual(flagged.rows.first?.folderServerIDs, ["INBOX", "Label_P"])
        let projects = try await sink.mailboxPage(ConnectedMailboxQuery(accountIDs: [account], folderServerID: "Label_P"))
        XCTAssertEqual(projects.total, 2)
        let none = try await sink.mailboxPage(ConnectedMailboxQuery(accountIDs: []))
        XCTAssertEqual(none.total, 0)
        let other = try await sink.mailboxPage(ConnectedMailboxQuery(accountIDs: [UUID()]))
        XCTAssertEqual(other.total, 0, "another account's mailbox shows none of these")
    }
}
