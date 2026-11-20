//
//  ClearArchiveTimingTests.swift
//  ArchiveCoreTests
//
//  Owner report 2026-11-20: deleting an archive takes a long time. Opt-in
//  (MAILIN_SCALE=1, MAILIN_SCALE_FILE): imports the file, then times the two
//  steps of the archive clear (`fts.clear()`, `store.clearAll()`) and each
//  table's DELETE on a side connection, and lists triggers and the tables
//  that reference `emails`.
//

import XCTest
import SQLite3
@testable import ArchiveCore

final class ClearArchiveTimingTests: XCTestCase {
    private func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }

    private func rows(_ db: OpaquePointer, _ sql: String) -> [String] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return ["(prepare failed: \(String(cString: sqlite3_errmsg(db))))"] }
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var cols: [String] = []
            for i in 0..<sqlite3_column_count(stmt) { cols.append(sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "NULL") }
            out.append(cols.joined(separator: " | "))
        }
        return out
    }

    func testClearAfterImport_timing() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["MAILIN_SCALE"] == "1", "opt-in")
        let file = URL(fileURLWithPath: try XCTUnwrap(env["MAILIN_SCALE_FILE"]))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clear-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeDir = root.appendingPathComponent("store", isDirectory: true)
        let store = SQLiteEmailStore(directory: storeDir)
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts", isDirectory: true))
        let coordinator = await BulkImportCoordinator(store: store, fts: fts, checkpoints: ImportCheckpointStore(store: store),
                                                      requiresStorageActivation: false)
        var options = BulkImportCoordinator.Options()
        options.enforceStoragePreflight = false
        options.useOffsetEngine = true
        options.recordLocators = true
        SearchChunkPolicy.isEnabled = true
        let clock = ContinuousClock()
        let t0 = clock.now
        let summary = try await coordinator.runImport(urls: [file], options: options)
        print("CLEAR import: \(summary.parsed) messages in \(String(format: "%.1f", seconds(clock.now - t0))) s")

        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(storeDir.appendingPathComponent("emails.db").path, &handle), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 30_000)
        print("CLEAR triggers: \(rows(db, "SELECT name || ' ON ' || tbl_name FROM sqlite_master WHERE type='trigger';"))")
        print("CLEAR referencing emails: \(rows(db, "SELECT name FROM sqlite_master WHERE type='table' AND sql LIKE '%REFERENCES emails%';"))")
        print("CLEAR foreign_keys: \(rows(db, "PRAGMA foreign_keys;"))")
        for table in rows(db, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;") {
            let n = rows(db, "SELECT COUNT(*) FROM \"\(table)\";").first ?? "?"
            if n != "0" { print("CLEAR rows \(table): \(n)") }
        }

        // The app's two steps, timed.
        let t1 = clock.now
        try await fts.clear()
        print("CLEAR fts.clear(): \(String(format: "%.2f", seconds(clock.now - t1))) s")
        // Per table on the side connection, in the order clearAll uses (then clearAll itself for what is left).
        for table in ["emails", "email_bodies", "derived", "duplicates", "thread_keys",
                      "predictive_records", "near_dup_findings", "sources", "attachments",
                      "email_participants", "email_tags", "email_domains",
                      "email_review_state", "email_user_tags", "email_annotations",
                      "attachment_search", "attachment_text_state", "deletion_tombstones",
                      "features", "ioc_rows", "minhash_bands", "fingerprints", "fingerprint_buckets", "entity_rows"] {
            let t = clock.now
            let rc = sqlite3_exec(db, "DELETE FROM \(table);", nil, nil, nil)
            let s = seconds(clock.now - t)
            if s > 0.05 || rc != SQLITE_OK { print("CLEAR delete \(table): \(String(format: "%.2f", s)) s rc=\(rc)") }
        }
        let t2 = clock.now
        try await store.clearAll()
        print("CLEAR store.clearAll() after: \(String(format: "%.2f", seconds(clock.now - t2))) s")
        for table in rows(db, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;") {
            let n = rows(db, "SELECT COUNT(*) FROM \"\(table)\";").first ?? "?"
            if n != "0" { print("CLEAR left after clear \(table): \(n)") }
        }
    }

    /// CLEAR-01: the clear leaves no per-message row anywhere (it used to leave
    /// the word-chunk index, its documents and the byte locators), the search
    /// index is empty, and the archive takes a new import and finds it again.
    func testClear_leavesNothingPerMessage_andTheArchiveTakesANewImport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clear01-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func mbox(_ tag: String, _ n: Int) throws -> URL {
            var text = ""
            for i in 0..<n {
                text += "From a@example.com Mon Jan  6 10:00:00 2025\nMessage-ID: <\(tag)-\(i)@example.com>\nFrom: Asha <asha@example.com>\nTo: ravi@example.org\nSubject: \(tag) \(i)\nDate: Mon, 6 Jan 2025 10:00:00 +0530\n\nbody \(tag)word \(i) \(String(repeating: "filler ", count: 40))\n\n"
            }
            let url = root.appendingPathComponent("\(tag).mbox")
            try Data(text.utf8).write(to: url)
            return url
        }
        let storeDir = root.appendingPathComponent("store", isDirectory: true)
        let store = SQLiteEmailStore(directory: storeDir)
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts", isDirectory: true))
        let coordinator = await BulkImportCoordinator(store: store, fts: fts, checkpoints: ImportCheckpointStore(store: store),
                                                      requiresStorageActivation: false)
        var options = BulkImportCoordinator.Options()
        options.enforceStoragePreflight = false
        options.useOffsetEngine = true
        options.recordLocators = true
        let wasOn = SearchChunkPolicy.isEnabled
        SearchChunkPolicy.isEnabled = true
        defer { SearchChunkPolicy.isEnabled = wasOn }

        _ = try await coordinator.runImport(urls: [try mbox("alpha", 300)], options: options)
        let before = try await store.totalCount()
        XCTAssertEqual(before, 300)

        try await fts.clear()
        try await store.clearAll()

        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(storeDir.appendingPathComponent("emails.db").path, &handle), SQLITE_OK)
        let db = try XCTUnwrap(handle)
        defer { sqlite3_close(db) }
        for table in ["emails", "email_bodies", "search_docs", "search_chunks", "message_locators", "part_locators",
                      "email_participants", "email_domains", "sources", "source_coverage"] {
            let left = rows(db, "SELECT COUNT(*) FROM \(table);").first
            XCTAssertEqual(left, "0", "\(table) is empty after the clear")
        }
        let indexed = try await fts.rowCount()
        XCTAssertEqual(indexed, 0, "the search index is empty")
        let ghost = try await fts.search("alphaword")
        XCTAssertTrue(ghost.isEmpty, "nothing deleted is found")

        // A new import into the cleared archive, searchable.
        let second = await BulkImportCoordinator(store: store, fts: fts, checkpoints: ImportCheckpointStore(store: store),
                                                 requiresStorageActivation: false)
        _ = try await second.runImport(urls: [try mbox("beta", 120)], options: options)
        let after = try await store.totalCount()
        XCTAssertEqual(after, 120)
        let found = try await fts.search("betaword", limit: 500)
        XCTAssertEqual(found.count, 120, "the new import is searchable")
        XCTAssertEqual(rows(db, "SELECT COUNT(*) FROM search_docs;").first.flatMap(Int.init) ?? 0 > 0, true,
                       "the word-chunk index works again after being recreated")
    }
}
