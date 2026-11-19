//
//  ImportWriteEfficiencyTests.swift
//  ArchiveCoreTests
//
//  PERF-01 (owner instruction 2026-11-19, "remove repeated database work"):
//
//   • deletion tombstones are looked up per message through their indexes;
//     the whole table is no longer loaded into memory on every batch
//     (deleted mail must still never reappear);
//   • the search-document statements are prepared once per batch call, not
//     three per document;
//   • rows written before the chunk-run columns (CLOSE-08) get their runs in
//     one grouped pass on open, once per archive.
//

import XCTest
import Foundation
import SQLite3
@testable import ArchiveCore

final class ImportWriteEfficiencyTests: XCTestCase {
    private var dir: URL!
    private var policyWasEnabled = false

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("write-efficiency-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        policyWasEnabled = SearchChunkPolicy.isEnabled
        SearchChunkPolicy.isEnabled = true
    }

    override func tearDown() {
        SearchChunkPolicy.isEnabled = policyWasEnabled
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private var storeDir: URL { dir.appendingPathComponent("store", isDirectory: true) }

    private static func message(id: String, body: String) -> String {
        "Message-ID: <\(id)>\r\nFrom: Asha <asha@example.com>\r\nTo: ravi@example.org\r\n"
        + "Subject: Ledger \(id)\r\nDate: Mon, 6 Jan 2025 10:00:00 +0530\r\nMIME-Version: 1.0\r\n"
        + "Content-Type: text/plain; charset=utf-8\r\n\r\n\(body)\r\n"
    }

    private func emails(_ range: Range<Int>, prefix: String) throws -> [MBOXParser.RawEmail] {
        try range.map { i in
            try MBOXParser.processRawMessage(Self.message(id: "\(prefix)\(i)@x", body: "kestrel \(i) words in the body"), senderEmail: "")
        }
    }

    private func sideSQL(_ sql: String, file: StaticString = #filePath, line: UInt = #line) {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(storeDir.appendingPathComponent("emails.db").path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let db = handle else { return XCTFail("cannot open the archive file", file: file, line: line) }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5_000)
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            XCTFail("side SQL failed: \(err.map { String(cString: $0) } ?? "?") — \(sql)", file: file, line: line)
            sqlite3_free(err)
        }
    }

    private func sideCount(_ sql: String) -> Int {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(storeDir.appendingPathComponent("emails.db").path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db = handle else { return -1 }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return -2 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : -3
    }

    // MARK: - Tombstones

    /// 300,000 deletion records: the ones that match still block, the rest of
    /// the batch is stored, and ten batch calls do not read the table ten
    /// times (the old path loaded every row into two sets per call).
    func testTombstones_stillBlockDeletedMail_withoutLoadingTheTablePerBatch() async throws {
        let store = SQLiteEmailStore(directory: storeDir)
        try await store.insertBatch(try emails(0..<1, prefix: "warm"), batchSize: 10)   // creates the file
        sideSQL("""
            INSERT INTO deletion_tombstones(dedup_key, message_id, deleted_at)
            WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 300000)
            SELECT 'key-' || x, '<tomb' || x || '@x>', 0 FROM c;
        """)
        XCTAssertEqual(sideCount("SELECT COUNT(*) FROM deletion_tombstones;"), 300_000)

        // Three messages whose Message-IDs were deleted before, among 17 new ones.
        var batch = try emails(0..<17, prefix: "fresh")
        for n in [7, 150_000, 299_999] {
            batch.append(try MBOXParser.processRawMessage(Self.message(id: "tomb\(n)@x", body: "back from the dead"), senderEmail: ""))
        }
        let start = Date()
        var blocked = 0, inserted = 0
        for _ in 0..<10 {
            let result = try await store.insertBatch(batch, sourceFileHash: nil, accountID: nil, sourceID: nil, firstOrdinal: nil,
                                                     dedupPolicy: .messageID, batchSize: 50, progress: nil)
            blocked += result.blockedByTombstoneIDs.count
            inserted += result.insertedIDs.count
        }
        let seconds = Date().timeIntervalSince(start)
        XCTAssertEqual(blocked, 30, "the three deleted identities are refused on every call")
        XCTAssertEqual(inserted, 17, "the fresh messages were stored once; later calls see them as duplicates")
        XCTAssertEqual(sideCount("SELECT COUNT(*) FROM emails WHERE message_id LIKE '<tomb%';"), 0, "deleted mail never reappears")
        XCTAssertLessThan(seconds, 1.5, "ten batch calls against 300,000 tombstones took \(seconds) s — the table is being loaded per call")
    }

    // MARK: - Prepared statements

    /// One statement bundle per batch call, however many documents it writes.
    func testSearchDocumentStatements_arePreparedOncePerBatchCall() async throws {
        let store = SQLiteEmailStore(directory: storeDir)
        let before = SQLiteEmailStore.SearchDocStatements.preparedCount
        try await store.insertBatch(try emails(0..<120, prefix: "stmt"), batchSize: 50)   // 3 transactions, 480 documents
        let prepared = SQLiteEmailStore.SearchDocStatements.preparedCount - before
        XCTAssertEqual(prepared, 1, "480 documents in one call must share one prepared bundle, not prepare \(prepared) times")
        XCTAssertEqual(sideCount("SELECT COUNT(*) FROM search_docs;"), 480)
    }

    // MARK: - Legacy run backfill

    /// Rows written before the run columns get MIN/MAX rowid runs in one pass
    /// on open; the pass is marked and not repeated.
    func testLegacyRuns_areBackfilledOnceOnOpen() async throws {
        let first = SQLiteEmailStore(directory: storeDir)
        try await first.insertBatch(try emails(0..<2, prefix: "pre"), batchSize: 10)
        // Three documents the old way (NULL runs), one of them multi-chunk, plus a row with no chunks.
        let a = UUID().uuidString, b = UUID().uuidString, c = UUID().uuidString, empty = UUID().uuidString
        try await first.plantLegacyChunksForTesting(emailID: a, kind: "body", chunks: ["a one", "a two", "a three"])
        try await first.plantLegacyChunksForTesting(emailID: b, kind: "body", chunks: ["b one"])
        try await first.plantLegacyChunksForTesting(emailID: c, kind: "subject", chunks: ["c one", "c two"])
        sideSQL("INSERT INTO search_docs(email_id, kind, ordinal, state) VALUES ('\(empty)', 'body', 0, 'noText');")
        sideSQL("DELETE FROM meta WHERE key = '\(SQLiteEmailStore.searchDocRunBackfillKey)';")   // as if the pass never ran
        XCTAssertEqual(sideCount("SELECT COUNT(*) FROM search_docs WHERE first_rowid IS NULL;"), 4)

        let reopened = SQLiteEmailStore(directory: storeDir)
        _ = try await reopened.searchDocColumnsForTesting()   // opens, migrates, backfills
        XCTAssertEqual(sideCount("SELECT COUNT(*) FROM search_docs WHERE first_rowid IS NULL;"), 0, "every legacy row has a run now")
        for (id, kind, count) in [(a, "body", 3), (b, "body", 1), (c, "subject", 2)] {
            let lo = sideCount("SELECT MIN(rowid) FROM search_chunks WHERE email_id = '\(id)' AND kind = '\(kind)';")
            let hi = sideCount("SELECT MAX(rowid) FROM search_chunks WHERE email_id = '\(id)' AND kind = '\(kind)';")
            XCTAssertEqual(sideCount("SELECT first_rowid FROM search_docs WHERE email_id = '\(id)' AND kind = '\(kind)';"), lo)
            XCTAssertEqual(sideCount("SELECT last_rowid FROM search_docs WHERE email_id = '\(id)' AND kind = '\(kind)';"), hi)
            XCTAssertEqual(hi - lo + 1, count, "the chunks of one planted document are one contiguous run")
        }
        XCTAssertEqual(sideCount("SELECT first_rowid > last_rowid FROM search_docs WHERE email_id = '\(empty)';"), 1, "no chunks: the empty run")
        XCTAssertEqual(sideCount("SELECT value FROM meta WHERE key = '\(SQLiteEmailStore.searchDocRunBackfillKey)';"), 1)

        // The backfilled run is what a rewrite uses: the three old chunks go, one new one comes.
        try await reopened.reindexDocumentForTesting(emailID: a, kind: .body, text: "a rewritten")
        XCTAssertEqual(sideCount("SELECT COUNT(*) FROM search_chunks WHERE email_id = '\(a)';"), 1)

        // Marked: a legacy row planted later is not backfilled again on the next open (the scan path still handles it).
        let late = UUID().uuidString
        try await reopened.plantLegacyChunksForTesting(emailID: late, kind: "body", chunks: ["late"])
        let third = SQLiteEmailStore(directory: storeDir)
        _ = try await third.searchDocColumnsForTesting()
        XCTAssertEqual(sideCount("SELECT COUNT(*) FROM search_docs WHERE first_rowid IS NULL;"), 1, "the one-time pass does not run twice")
        try await third.reindexDocumentForTesting(emailID: late, kind: .body, text: "late rewritten")
        let texts = try await third.chunkTextsForTesting(emailID: late, kind: "body")
        XCTAssertEqual(texts, ["late rewritten"])
    }
}
