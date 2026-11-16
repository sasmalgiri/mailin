//
//  ReleaseCloseoutTests.swift
//  ArchiveCoreTests
//
//  Review 2026-11-16, open items closed in the package:
//    1. ArchiveDataService: a store error while listing an attachment's
//       children or text is an error, not "no files inside" / "no text".
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
}
