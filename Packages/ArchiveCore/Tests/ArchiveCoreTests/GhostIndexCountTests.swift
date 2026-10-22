//
//  GhostIndexCountTests.swift
//  ArchiveCoreTests
//
//  A text-search count must never include index entries whose email is no
//  longer in the store. Found 2026-10-21 on the iPad simulator: 16 index rows
//  over 8 emails, so "launch" counted 6 while the list (which verifies every
//  hit) showed 3, and tools warned "working on the newest 3 of the 6 emails".
//

import XCTest
import Foundation
@testable import ArchiveCore

final class GhostIndexCountTests: XCTestCase {

    private func email(_ i: Int, subject: String) -> MBOXParser.RawEmail {
        let date = Date(timeIntervalSince1970: 1_735_689_600 + Double(i) * 86_400)
        let fmt = DateFormatter(); fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return MBOXParser.RawEmail(
            headers: ["Message-ID": "<ghost-\(i)-\(UUID().uuidString)@test>", "Subject": subject, "From": "a@test", "To": "me@test",
                      "Date": fmt.string(from: date)],
            rawSource: "", messageType: "email", attachments: [], timestamp: "", domains: [],
            plainBody: "body \(i) \(subject)", htmlBody: "")
    }

    @MainActor
    func testTextCountIgnoresIndexEntriesWithoutAnEmail() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ghost-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts", isDirectory: true))

        // In the archive: 3 emails, 2 of them about "launch".
        let kept = [email(0, subject: "launch plan"), email(1, subject: "launch review"), email(2, subject: "lunch menu")]
        try await store.insertBatch(kept, batchSize: 10)
        try await fts.indexBatch(kept)
        // Left behind in the index only: 2 more "launch" emails that are not in the store.
        try await fts.indexBatch([email(3, subject: "launch old"), email(4, subject: "launch older")])

        let archive = ArchiveDataService(repository: EmailStoreRepository(store: store, fts: fts))
        var query = EmailQuery(); query.text = "launch"
        let counted = try await archive.count(query: query)
        var listed = 0
        for try await batch in archive.streamFullEmails(query: query) { listed += batch.count }

        XCTAssertEqual(listed, 2, "the list shows only emails that exist")
        XCTAssertEqual(counted, listed, "the count must agree with the list, not with the index")
    }

    @MainActor
    func testFastCountStillUsedWhenIndexMatchesStore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ghost-ok-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts", isDirectory: true))
        let emails = (0..<5).map { email($0, subject: $0 < 3 ? "launch \($0)" : "other \($0)") }
        try await store.insertBatch(emails, batchSize: 10)
        try await fts.indexBatch(emails)
        let archive = ArchiveDataService(repository: EmailStoreRepository(store: store, fts: fts))
        var query = EmailQuery(); query.text = "launch"
        let counted = try await archive.count(query: query)
        XCTAssertEqual(counted, 3)
    }

    /// Loading the same emails twice (the sample, an intake re-run, a re-carve)
    /// gives them fresh UUIDs; the store skips them as duplicates. Indexing only
    /// `inserted(from:)` keeps the index one-for-one with the store.
    @MainActor
    func testSecondLoadOfTheSameEmailsAddsNoIndexEntries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ghost-twice-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts", isDirectory: true))
        let first = (0..<4).map { email($0, subject: "launch \($0)") }
        // The second load: same Message-IDs, new UUIDs (as a re-parse produces).
        let second = first.map { e -> MBOXParser.RawEmail in
            MBOXParser.RawEmail(headers: e.headers, rawSource: "", messageType: "email", attachments: [], timestamp: "",
                                domains: [], plainBody: e.plainBody, htmlBody: "")
        }
        for load in [first, second] {
            let r = try await store.insertBatch(load, sourceFileHash: nil, accountID: nil, sourceID: nil, firstOrdinal: nil,
                                                dedupPolicy: .messageID, batchSize: 10, progress: nil)
            try await fts.indexBatch(r.inserted(from: load))
        }
        let stored = try await store.count(after: nil, before: nil)
        let indexed = try await fts.rowCount()
        XCTAssertEqual(stored, 4)
        XCTAssertEqual(indexed, stored, "the second load must not add index entries")
    }

    /// Archives indexed by older builds already carry ghost entries; the launch
    /// prune removes exactly those and keeps every real one.
    @MainActor
    func testPruneRemovesOnlyEntriesWithoutAnEmail() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ghost-prune-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts", isDirectory: true))
        // Days 0…399 span two year-shards; page size 7 forces many pages.
        let kept = (0..<40).map { email($0 * 10, subject: "launch kept \($0)") }
        let ghosts = (0..<25).map { email($0 * 10 + 5, subject: "launch ghost \($0)") }
        try await store.insertBatch(kept, batchSize: 50)
        try await fts.indexBatch(kept)
        try await fts.indexBatch(ghosts)

        let removed = try await FTSReconciler.pruneGhosts(store: store, fts: fts, pageSize: 7)
        XCTAssertEqual(removed, 25)
        let indexed = try await fts.rowCount()
        XCTAssertEqual(indexed, 40)
        let present = try await fts.indexedSubset(of: kept.map(\.id))
        XCTAssertEqual(present.count, 40, "every real email stays searchable")
        let leftover = try await fts.indexedSubset(of: ghosts.map(\.id))
        XCTAssertTrue(leftover.isEmpty, "the registry forgets the ghosts too")

        let archive = ArchiveDataService(repository: EmailStoreRepository(store: store, fts: fts))
        var query = EmailQuery(); query.text = "launch"
        let counted = try await archive.count(query: query)
        XCTAssertEqual(counted, 40)
        // A second pass finds nothing.
        let again = try await FTSReconciler.pruneGhosts(store: store, fts: fts, pageSize: 7)
        XCTAssertEqual(again, 0)
    }
}
