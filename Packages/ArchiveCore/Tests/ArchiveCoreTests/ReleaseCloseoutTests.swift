//
//  ReleaseCloseoutTests.swift
//  ArchiveCoreTests
//
//  Review 2026-11-16, open items closed in the package:
//    1. ArchiveDataService: a store error while listing an attachment's
//       children or text is an error, not "no files inside" / "no text".
//    2. Owner decision D-2: deleting an email also deletes its rows in
//       email_custom_values, email_recovery, the attachment coverage store and
//       the search registry (indexed_message); forensic, custody, review
//       coding and custodian rows are kept (the audit record); a held email
//       keeps everything.
//    4. NSF: a note the item placement search gave up on at its step limit
//       is named with that reason in the import report and the receipt's
//       warnings, not only in the log.
//

import XCTest
import Foundation
import SQLite3
@testable import ArchiveCore

final class ReleaseCloseoutTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("release-closeout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    static func message(id: String, body: String) -> String {
        "Message-ID: <\(id)>\r\nFrom: Asha <asha@example.com>\r\nTo: ravi@example.org\r\n"
            + "Subject: Figures\r\nDate: Mon, 6 Jan 2025 10:00:00 +0530\r\nMIME-Version: 1.0\r\n"
            + "Content-Type: text/plain; charset=utf-8\r\n\r\n\(body)\r\n"
    }

    private func insert(_ store: SQLiteEmailStore, count: Int, prefix: String = "m") async throws -> [MBOXParser.RawEmail] {
        let emails = try (0..<count).map { i in
            try MBOXParser.processRawMessage(Self.message(id: "\(prefix)-\(i)@x", body: "Body \(i)"), senderEmail: "")
        }
        _ = try await store.insertBatch(emails, sourceFileHash: nil, accountID: nil, sourceID: nil, firstOrdinal: nil,
                                        dedupPolicy: .messageID, batchSize: 10, progress: nil)
        return emails
    }

    private func rawExec(_ sql: String) throws {
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dir.appendingPathComponent("emails.db").path, &raw), SQLITE_OK)
        defer { sqlite3_close(raw) }
        XCTAssertEqual(sqlite3_exec(raw, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(raw)))
    }

    // MARK: 1 — ArchiveDataService store errors

    @MainActor
    func testAttachmentChildrenAndText_storeError_isThrown_notReadAsNone() async throws {
        let store = SQLiteEmailStore(directory: dir)
        let inserted = try await insert(store, count: 1)
        let email = try XCTUnwrap(inserted.first)
        let fts = FTSSearchIndex(shardsDirectory: dir.appendingPathComponent("fts", isDirectory: true))
        let archive = ArchiveDataService(repository: EmailStoreRepository(store: store, fts: fts))

        // A healthy store answers: nothing recorded is an empty answer, not an error.
        let none = try await archive.attachmentChildren(emailID: email.id)
        XCTAssertEqual(none.count, 0)
        let noText = try await archive.attachmentDocumentText(emailID: email.id, ordinal: 0)
        XCTAssertNil(noText)
        let hasText = try await archive.attachmentDocumentHasText(emailID: email.id, ordinal: 0)
        XCTAssertFalse(hasText)

        // The store fails (tables gone underneath it): each call says so.
        try rawExec("DROP TABLE attachment_children; DROP TABLE search_chunks; DROP TABLE search_docs;")
        do {
            let rows = try await archive.attachmentChildren(emailID: email.id)
            XCTFail("a store error was read as \(rows.count) files inside")
        } catch {}
        do {
            let text = try await archive.attachmentDocumentText(emailID: email.id, ordinal: 0)
            XCTFail("a store error was read as text \(String(describing: text))")
        } catch {}
        do {
            let has = try await archive.attachmentDocumentHasText(emailID: email.id, ordinal: 0)
            XCTFail("a store error was read as hasText = \(has)")
        } catch {}
    }

    // MARK: 2 — D-2 delete cleanup

    private func count(_ db: URL, _ sql: String) throws -> Int {
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(db.path, &raw), SQLITE_OK)
        defer { sqlite3_close(raw) }
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(raw, sql, -1, &stmt, nil), SQLITE_OK, String(cString: sqlite3_errmsg(raw)))
        defer { sqlite3_finalize(stmt) }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        return Int(sqlite3_column_int64(stmt, 0))
    }

    static let cleanedTables = ["email_custom_values", "email_recovery"]
    static let keptTables = ["review_coding", "custodian_assignments", "custody_events", "forensic_email_hashes",
                             "forensic_annotations", "forensic_evidence_tags"]

    func testD2_deleteRemovesCustomRecoveryCoverageAndSearchRows_keepsAuditRows_heldKeepsAll() async throws {
        let store = SQLiteEmailStore(directory: dir)
        let emails = try await insert(store, count: 2, prefix: "d2")
        let gone = emails[0].id, held = emails[1].id
        let fts = FTSSearchIndex(shardsDirectory: dir.appendingPathComponent("fts", isDirectory: true))
        for e in emails { try await fts.index(e) }
        let coverage = try AttachmentCoverageStore(url: await store.attachmentCoverageURL)
        for id in [gone, held] {
            try coverage.record(row: AttachmentCoverageRow(emailID: id, ordinal: 0, filename: "a.txt", mimeType: "text/plain",
                                                           state: .extracted, extractor: "text", extractorVersion: 1,
                                                           characters: 4, note: nil))
            let u = id.uuidString
            try rawExec("""
                INSERT INTO email_custom_values(email_id, key, value) VALUES ('\(u)', 'k', 'v');
                INSERT INTO email_recovery(email_id, state) VALUES ('\(u)', 'carved');
                INSERT INTO review_coding(workspace, email_id, field, value, updated_at) VALUES ('w', '\(u)', 'responsive', 'yes', 1);
                INSERT INTO custodian_assignments(email_id, custodian, assigned_at) VALUES ('\(u)', 'Asha', 1);
                INSERT INTO custody_events(event_id, email_id, at, payload) VALUES ('ev-\(u)', '\(u)', 1, x'00');
                INSERT INTO forensic_email_hashes(email_id, sha256) VALUES ('\(u)', 'abc');
                INSERT INTO forensic_annotations(email_id, note) VALUES ('\(u)', 'seen');
                INSERT INTO forensic_evidence_tags(email_id, tag) VALUES ('\(u)', 'key');
            """)
        }
        try await store.legalHoldsAdd([held])
        await store.setEnforcesDatabaseLegalHolds(true)

        try await EmailStoreRepository(store: store, fts: fts).delete(ids: [gone, held])

        let db = dir.appendingPathComponent("emails.db")
        let total = try await store.totalCount()
        XCTAssertEqual(total, 1, "the held email is not deleted")
        for table in Self.cleanedTables {
            XCTAssertEqual(try count(db, "SELECT COUNT(*) FROM \(table) WHERE email_id = '\(gone.uuidString)';"), 0,
                           "\(table) still holds rows of the deleted email")
            XCTAssertEqual(try count(db, "SELECT COUNT(*) FROM \(table) WHERE email_id = '\(held.uuidString)';"), 1,
                           "\(table) lost the held email's row")
        }
        for table in Self.keptTables {
            for id in [gone, held] {
                XCTAssertEqual(try count(db, "SELECT COUNT(*) FROM \(table) WHERE email_id = '\(id.uuidString)';"), 1,
                               "\(table) is the audit record and must be kept (\(id == held ? "held" : "deleted"))")
            }
        }
        let coverageAfter = try AttachmentCoverageStore(url: await store.attachmentCoverageURL)
        XCTAssertEqual(try coverageAfter.rows(for: gone).count, 0, "coverage still counts the deleted email's attachment")
        XCTAssertEqual(try coverageAfter.rows(for: held).count, 1, "the held email's coverage is kept")
        let indexed = try await fts.indexedSubset(of: [gone, held])
        XCTAssertEqual(indexed, [held], "the search registry keeps the held email and drops the deleted one")
    }

    // MARK: 4 — NSF step limit reason reaches the import

    func testNSF_placementStepLimit_reasonReachesReportAndWarning() throws {
        let data = try HostileHeaderSignalsTests.hostileDatabase(nonSummary: [0, 0, 0])
        var reader = try NSFODSReader(data: data)
        reader.placementStepLimit = 1_000
        var cursor = NSFODSReader.Cursor()
        var record: NSFODSReader.Record?
        while let r = reader.next(&cursor) {
            if case .object = r { continue }
            record = r
            break
        }
        guard case .unplacedAtStepLimit(let id)? = record else { return XCTFail("expected unplaced at the step limit, got \(String(describing: record))") }
        XCTAssertEqual(id, HostileHeaderSignalsTests.hostileNoteID)

        // The same file through the parser's inventory and report.
        let url = dir.appendingPathComponent("hostile.nsf")
        try data.write(to: url)
        let inventory = try NSFODSParser.inventory(fileURL: url, placementStepLimit: 1_000)
        XCTAssertEqual(inventory.unplacedDocuments, [HostileHeaderSignalsTests.hostileNoteID], "still counted as unplaced")
        XCTAssertEqual(inventory.unplacedAtStepLimit, [HostileHeaderSignalsTests.hostileNoteID])
        let report = NSFODSParser.report(NSFODSParser.Streamed(emitted: 0, inventory: inventory))
        XCTAssertEqual(report.failed, 1, "one failure, not counted twice")
        XCTAssertEqual(report.errorCategories[NSFODSReader.stepLimitCategory], 1)
        XCTAssertNil(report.errorCategories["nsf_document_items_unplaced"], "the reason replaces the generic category")

        let line = try XCTUnwrap(BulkImportCoordinator.nsfStepLimitLine(sourceName: "mail.nsf", categories: report.errorCategories))
        XCTAssertTrue(line.hasPrefix("mail.nsf: "), line)
        XCTAssertTrue(line.contains(NSFODSReader.placementStepLimit.formatted()), line)
        XCTAssertNil(BulkImportCoordinator.nsfStepLimitLine(sourceName: "mail.nsf", categories: ["nsf_document_items_unplaced": 2]))

        // Under the real limit the same table is simply unplaced (no step-limit reason).
        let plain = try NSFODSParser.inventory(fileURL: url)
        XCTAssertEqual(plain.unplacedAtStepLimit, [])
        XCTAssertEqual(plain.unplacedDocuments.count, 1)
    }
}
