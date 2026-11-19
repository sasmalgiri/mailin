//
//  SearchChunkRunTests.swift
//  ArchiveCoreTests
//
//  2026-11-19: importing the 56,699-message Enron mailbox sat for hours in
//  the app (33 % after one hour) while the engine benchmark of the same file
//  took 12 minutes. The backtrace stopped in `indexSearchDocument`: its
//  `DELETE FROM search_chunks WHERE email_id = ? AND kind = ? AND ordinal = ?`
//  filters on UNINDEXED FTS5 columns, so every one of the five documents per
//  message scanned the whole chunk table before it was written — cost grew
//  with the table. Documents now remember the rowid run of their chunks and
//  are cleared by rowid range; a fresh document is not cleared at all.
//
//  Without the fix: the cost test fails (the last 300 messages take many
//  times longer than the first 300), and no run is recorded.
//

import XCTest
import Foundation
import SQLite3
@testable import ArchiveCore

final class SearchChunkRunTests: XCTestCase {
    private var dir: URL!
    private var policyWasEnabled = false

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("chunk-runs-\(UUID().uuidString)", isDirectory: true)
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

    private func emails(_ range: Range<Int>, prefix: String = "run") throws -> [MBOXParser.RawEmail] {
        try range.map { i in
            try MBOXParser.processRawMessage(Self.message(id: "\(prefix)\(i)@x", body: "kestrel \(i) words in the body of message \(i)"),
                                             senderEmail: "")
        }
    }

    /// Runs `sql` on a second connection to the archive file.
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

    private func sideText(_ sql: String) -> String? {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(storeDir.appendingPathComponent("emails.db").path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db = handle else { return nil }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: c)
    }

    // MARK: - Runs are recorded and used

    /// The import path records each document's run; rewriting one document
    /// replaces exactly its chunks and leaves every other document alone.
    func testImportedDocuments_recordTheirRun_andARewriteReplacesOnlyThatDocument() async throws {
        let store = SQLiteEmailStore(directory: storeDir)
        let batch = try emails(0..<3)
        try await store.insertBatch(batch, batchSize: 10)

        for email in batch {
            let recorded = try await store.searchDocumentRunForTesting(emailID: email.id.uuidString, kind: .body)
            let bodyRun = try XCTUnwrap(recorded, "the body document records its chunk run")
            XCTAssertLessThanOrEqual(bodyRun.first, bodyRun.last)
            // Subject / sender / recipients too — every document the import writes.
            for kind in [SearchDocKind.subject, .sender, .recipients] {
                let run = try await store.searchDocumentRunForTesting(emailID: email.id.uuidString, kind: kind)
                XCTAssertNotNil(run, "\(kind)")
            }
        }
        let chunksBefore = sideCount("SELECT COUNT(*) FROM search_chunks;")
        let target = batch[1].id.uuidString
        try await store.reindexDocumentForTesting(emailID: target, kind: .body, text: "heron replaced body")
        let rewritten = try await store.chunkTextsForTesting(emailID: target, kind: "body")
        XCTAssertEqual(rewritten, ["heron replaced body"])
        XCTAssertEqual(sideCount("SELECT COUNT(*) FROM search_chunks;"), chunksBefore, "one chunk out, one chunk in")
        XCTAssertEqual(sideCount("SELECT COUNT(*) FROM search_chunks WHERE text LIKE 'kestrel 1 %';"), 0, "the old body chunk is gone")
        XCTAssertEqual(sideCount("SELECT COUNT(*) FROM search_chunks WHERE text LIKE 'kestrel 0 %';"), 1, "the neighbour's body stays")
        XCTAssertEqual(sideCount("SELECT COUNT(*) FROM search_chunks WHERE text LIKE 'kestrel 2 %';"), 1)
        let afterRewrite = try await store.searchDocumentRunForTesting(emailID: target, kind: .body)
        let newRun = try XCTUnwrap(afterRewrite)
        XCTAssertEqual(newRun.first, newRun.last, "a one-chunk document has a one-row run")
        // A document emptied of text keeps a row and an empty run, never a NULL one.
        try await store.reindexDocumentForTesting(emailID: target, kind: .body, text: nil)
        let emptied = try await store.chunkTextsForTesting(emailID: target, kind: "body")
        XCTAssertEqual(emptied, [])
        let afterEmptying = try await store.searchDocumentRunForTesting(emailID: target, kind: .body)
        let emptyRun = try XCTUnwrap(afterEmptying)
        XCTAssertGreaterThan(emptyRun.first, emptyRun.last, "an empty run, so the row is never scanned for")
    }

    /// A row written before the run columns (NULL run) is still cleared
    /// completely — by the old scan — and leaves with a run of its own.
    func testLegacyDocumentWithoutARun_isStillReplacedCompletely_andGainsARun() async throws {
        let store = SQLiteEmailStore(directory: storeDir)
        let id = UUID().uuidString
        try await store.plantLegacyChunksForTesting(emailID: id, kind: "body", chunks: ["old one", "old two", "old three"])
        let planted = try await store.searchDocumentRunForTesting(emailID: id, kind: .body)
        XCTAssertNil(planted, "planted the old way: no run")
        XCTAssertEqual(sideCount("SELECT COUNT(*) FROM search_chunks WHERE email_id = '\(id)';"), 3)

        try await store.reindexDocumentForTesting(emailID: id, kind: .body, text: "new text")
        let texts = try await store.chunkTextsForTesting(emailID: id, kind: "body")
        XCTAssertEqual(texts, ["new text"])
        XCTAssertEqual(sideCount("SELECT COUNT(*) FROM search_chunks WHERE email_id = '\(id)';"), 1, "all three legacy chunks are gone")
        let run = try await store.searchDocumentRunForTesting(emailID: id, kind: .body)
        XCTAssertNotNil(run, "rewritten with a run")
    }

    /// A store created before the columns gains them on open, before any write.
    func testOlderStore_gainsTheRunColumnsOnOpen() async throws {
        let first = SQLiteEmailStore(directory: storeDir)
        try await first.insertBatch(try emails(0..<1, prefix: "old"), batchSize: 10)
        let fresh = try await first.searchDocColumnsForTesting()
        XCTAssertEqual(Set(fresh).intersection(["first_rowid", "last_rowid"]).count, 2)
        // Make the file look like one written before 2026-11-19.
        sideSQL("ALTER TABLE search_docs DROP COLUMN first_rowid; ALTER TABLE search_docs DROP COLUMN last_rowid;")

        let reopened = SQLiteEmailStore(directory: storeDir)
        let columns = try await reopened.searchDocColumnsForTesting()
        XCTAssertTrue(columns.contains("first_rowid") && columns.contains("last_rowid"), "added on open: \(columns)")
        // Its rows are legacy now (NULL run) and are still rewritten correctly.
        XCTAssertEqual(sideCount("SELECT COUNT(*) FROM search_docs WHERE kind = 'body';"), 1)
        let bodyID = try XCTUnwrap(sideText("SELECT email_id FROM search_docs WHERE kind = 'body' LIMIT 1;"))
        let legacyRun = try await reopened.searchDocumentRunForTesting(emailID: bodyID, kind: .body)
        XCTAssertNil(legacyRun)
        try await reopened.reindexDocumentForTesting(emailID: bodyID, kind: .body, text: "after reopen")
        let texts = try await reopened.chunkTextsForTesting(emailID: bodyID, kind: "body")
        XCTAssertEqual(texts, ["after reopen"])
        let run = try await reopened.searchDocumentRunForTesting(emailID: bodyID, kind: .body)
        XCTAssertNotNil(run)
    }

    // MARK: - Cost does not grow with the table

    /// The defect: writing the Nth message cost O(table). Eight groups of 300
    /// messages (four documents each) are indexed; the last group must not
    /// take materially longer than the first. Before the fix the last group
    /// is tens of times slower (each of its documents scanned ~9,000 chunk
    /// rows); after it, both are a few hundred small statements.
    func testWriteCost_staysFlatAsTheIndexGrows() async throws {
        let store = SQLiteEmailStore(directory: storeDir)
        let groups = 8, perGroup = 300
        var seconds: [Double] = []
        for g in 0..<groups {
            let batch = try emails(g * perGroup..<(g + 1) * perGroup, prefix: "cost")
            let start = Date()
            try await store.indexEmailSearchDocumentsForTesting(batch)
            seconds.append(Date().timeIntervalSince(start))
        }
        XCTAssertEqual(sideCount("SELECT COUNT(*) FROM search_docs;"), groups * perGroup * 4, "subject, sender, recipients, body per message")
        let first = max(seconds[0], 0.005), last = seconds[groups - 1]
        XCTAssertLessThan(last / first, 4.0,
                          "writing the last 300 messages took \(String(format: "%.3f", last)) s against \(String(format: "%.3f", first)) s for the first 300: cost grows with the table — \(seconds)")
        XCTAssertLessThan(last, 3.0, "300 messages must index in well under 3 s on any Mac: \(seconds)")
    }
}
