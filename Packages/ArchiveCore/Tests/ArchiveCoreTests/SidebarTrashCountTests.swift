//
//  SidebarTrashCountTests.swift
//  ArchiveCoreTests
//
//  Gate 1 follow-up 2026-11-18 (iPad): while one email was in the Trash,
//  All Emails and Received dropped to 6, but "Labels (3)" with its label rows
//  and Source Folders > Inbox still counted it. The sidebars' label, folder
//  and source-file counts now leave the Trash out, as All Mail does. Without
//  `excludingTrashed` the queries keep counting every stored row (the
//  duplicate merge/restore bookkeeping relies on that).
//

import XCTest
import Foundation
@testable import ArchiveCore

final class SidebarTrashCountTests: XCTestCase {

    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sidebar-trash-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func email(_ name: String, folders: [String]) -> MBOXParser.RawEmail {
        var e = MBOXParser.RawEmail(
            headers: ["Message-ID": "<sidebar-\(name)-\(UUID().uuidString)@test>", "Subject": "Note \(name)", "From": "a@test",
                      "To": "me@test", "Date": "Wed, 15 Jan 2025 14:30:00 +0000"],
            rawSource: "", messageType: "received", attachments: [], timestamp: "", domains: [],
            plainBody: "Body \(name).", htmlBody: "")
        e.tags = folders
        return e
    }

    private func folderCounts(_ nodes: [ArchiveFolderNode]) -> [String: Int] {
        var out: [String: Int] = [:]
        for node in nodes { out[node.path, default: 0] += node.messageCount }
        return out
    }

    private func bucketCounts(_ buckets: [AggregateBucket]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: buckets.map { ($0.value, $0.count) })
    }

    func testLabelFolderAndSourceCountsLeaveTheTrashOut_likeAllMail() async throws {
        let store = SQLiteEmailStore(directory: root)
        let trashed = email("trashed", folders: ["Inbox", "Clients"])
        let inbox = email("inbox", folders: ["Inbox"])
        let work = email("work", folders: ["Work"])
        try await store.insertBatch([trashed, inbox, work], batchSize: 10)
        try await store.reviewSetFlag(.trashed, ids: [trashed.id], value: true)

        // All Mail's count leaves the Trash out.
        let allMail = try await store.count(after: nil, before: nil)
        XCTAssertEqual(allMail, 2)

        // Labels: rows, the paged rows and the total.
        let labels = bucketCounts(try await store.parserTagCounts(limit: 10, excludingTrashed: true))
        XCTAssertEqual(labels, ["Inbox": 1, "Work": 1], "Clients held only the trashed email")
        let page = bucketCounts(try await store.parserTagCounts(matching: nil, offset: 0, limit: 10, excludingTrashed: true))
        XCTAssertEqual(page, labels)
        let total = try await store.parserTagTotal(excludingTrashed: true)
        XCTAssertEqual(total, 2)
        // The name filter still binds with the Trash left out.
        let filteredTotal = try await store.parserTagTotal(matching: "inb", excludingTrashed: true)
        XCTAssertEqual(filteredTotal, 1)
        let filtered = bucketCounts(try await store.parserTagCounts(matching: "inb", offset: 0, limit: 10, excludingTrashed: true))
        XCTAssertEqual(filtered, ["Inbox": 1])
        let clientsTotal = try await store.parserTagTotal(matching: "Clients", excludingTrashed: true)
        XCTAssertEqual(clientsTotal, 0)

        // Source folders and source files.
        let folders = folderCounts(try await store.folderNodes(excludingTrashed: true))
        XCTAssertEqual(folders["Inbox"], 1)
        XCTAssertEqual(folders["Work"], 1)
        XCTAssertEqual(folders["Clients"] ?? 0, 0)
        let sources = try await store.sourceFileCounts(limit: 10, excludingTrashed: true)
        XCTAssertEqual(sources.reduce(0) { $0 + $1.count }, allMail, "source files add up to All Mail")

        // Without the switch: every stored row, as before.
        let stored = bucketCounts(try await store.parserTagCounts(limit: 10))
        XCTAssertEqual(stored, ["Inbox": 2, "Clients": 1, "Work": 1])
        let storedTotal = try await store.parserTagTotal()
        XCTAssertEqual(storedTotal, 3)
        let storedFolders = folderCounts(try await store.folderNodes())
        XCTAssertEqual(storedFolders["Inbox"], 2)
        let storedSources = try await store.sourceFileCounts(limit: 10)
        XCTAssertEqual(storedSources.reduce(0) { $0 + $1.count }, 3)

        // Restore: the counts come back.
        try await store.reviewSetFlag(.trashed, ids: [trashed.id], value: false)
        let restored = bucketCounts(try await store.parserTagCounts(limit: 10, excludingTrashed: true))
        XCTAssertEqual(restored, stored)
        let restoredFolders = folderCounts(try await store.folderNodes(excludingTrashed: true))
        XCTAssertEqual(restoredFolders["Inbox"], 2)
        XCTAssertEqual(restoredFolders["Clients"], 1)
    }
}
