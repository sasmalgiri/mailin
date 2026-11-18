//
//  DuplicateRestoreUndoTests.swift
//  ArchiveCoreTests
//
//  CLOSE-06 J4 (2026-11-18): "move identical copy to Trash" merged the copy's
//  folder memberships into the kept copy, and Restore from Trash did not undo
//  the merge — after move-and-restore the Inbox counted the kept copy AND the
//  restored copy (4 instead of 3). Restore is now a true undo: exactly the
//  memberships / tags the merge gave the survivor come off it again; ones it
//  had before stay, and so do ones another still-trashed copy also gave it.
//

import XCTest
import Foundation
@testable import ArchiveCore

final class DuplicateRestoreUndoTests: XCTestCase {

    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dup-undo-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func email(_ name: String, folders: [String]) -> MBOXParser.RawEmail {
        var e = MBOXParser.RawEmail(
            headers: ["Message-ID": "<undo-\(name)-\(UUID().uuidString)@test>", "Subject": "Quarterly ledger", "From": "a@test",
                      "To": "me@test", "Date": "Wed, 15 Jan 2025 14:30:00 +0000"],
            rawSource: "", messageType: "email", attachments: [], timestamp: "", domains: [],
            plainBody: "The ledger is closed.", htmlBody: "")
        e.tags = folders
        return e
    }

    /// Folder path → message count (folders with mail only).
    private func counts(_ store: SQLiteEmailStore) async throws -> [String: Int] {
        var out: [String: Int] = [:]
        for node in try await store.folderNodes() where node.messageCount > 0 { out[node.path, default: 0] += node.messageCount }
        return out
    }

    func testRestoringAMergedCopy_takesOffExactlyWhatTheMergeAdded() async throws {
        let store = SQLiteEmailStore(directory: root)
        // The J4 shape: the ledger in Inbox (kept) and in Work (the identical copy),
        // plus a folder both copies are in ("Shared") and a tag only the copy has.
        let kept = email("kept", folders: ["Inbox", "Shared"])
        let copy = email("copy", folders: ["Work", "Shared"])
        let other = email("other", folders: ["Inbox"])
        try await store.insertBatch([kept, copy, other], batchSize: 10)
        try await store.userTagAdd("from-copy", ids: [copy.id])
        try await store.userTagAdd("both", ids: [kept.id, copy.id])
        let before = try await counts(store)
        XCTAssertEqual(before["Inbox"], 2)
        XCTAssertEqual(before["Work"], 1)
        XCTAssertEqual(before["Shared"], 2)

        let result = try await store.removeDuplicateCopies([.init(survivor: kept.id, removed: [copy.id])])
        XCTAssertEqual(result.trashed, [copy.id])
        XCTAssertGreaterThan(result.membershipsMerged, 0, "the merge still gives the kept copy the copy's folders")
        let keptTagsMerged = try await store.userTags(ids: [kept.id])[kept.id] ?? []
        XCTAssertEqual(keptTagsMerged, ["both", "from-copy"])

        try await store.reviewSetFlag(.trashed, ids: [copy.id], value: false)

        let after = try await counts(store)
        XCTAssertEqual(after, before, "restore undoes the merge: every folder counts what it did before")
        let keptTags = try await store.userTags(ids: [kept.id])[kept.id] ?? []
        XCTAssertEqual(keptTags, ["both"], "the tag the kept copy had stays; the merged one goes")
        let copyTags = try await store.userTags(ids: [copy.id])[copy.id] ?? []
        XCTAssertEqual(copyTags, ["both", "from-copy"], "the restored copy keeps its own tags")
        let states = try await store.reviewStates(ids: [copy.id])
        XCTAssertEqual(states[copy.id]?.trashed, false)
    }

    func testTwoCopiesGaveTheSameFolder_itStaysUntilTheLastIsRestored() async throws {
        let store = SQLiteEmailStore(directory: root)
        let kept = email("kept", folders: ["Inbox"])
        let first = email("first", folders: ["Work"])
        let second = email("second", folders: ["Work"])
        try await store.insertBatch([kept, first, second], batchSize: 10)

        _ = try await store.removeDuplicateCopies([.init(survivor: kept.id, removed: [first.id, second.id])])
        let merged = try await counts(store)
        XCTAssertEqual(merged["Work"], 3, "kept + two trashed copies are members of Work")

        // The first copy back: the second (still in the Trash) also gave the kept copy Work.
        try await store.reviewSetFlag(.trashed, ids: [first.id], value: false)
        let oneBack = try await counts(store)
        XCTAssertEqual(oneBack["Work"], 3)

        // The last copy back: the kept copy loses the Work it only had from the merges.
        try await store.reviewSetFlag(.trashed, ids: [second.id], value: false)
        let after = try await counts(store)
        XCTAssertEqual(after["Work"], 2, "\(after)")
        XCTAssertEqual(after["Inbox"], 1)
    }

    func testPlainTrashRestore_changesNoMemberships() async throws {
        let store = SQLiteEmailStore(directory: root)
        let a = email("a", folders: ["Inbox"]), b = email("b", folders: ["Inbox", "Work"])
        try await store.insertBatch([a, b], batchSize: 10)
        let before = try await counts(store)
        try await store.reviewSetFlag(.trashed, ids: [b.id], value: true)
        try await store.reviewSetFlag(.trashed, ids: [b.id], value: false)
        let after = try await counts(store)
        XCTAssertEqual(after, before)
    }
}
