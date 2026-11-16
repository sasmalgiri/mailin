//
//  StoreAccountingTests.swift
//  ArchiveCoreTests
//
//  Review 2026-11-16 C7 / C8 / C17 and §E store hardening: what the store
//  says it did is what it did.
//
//   • C7  account-archive deletion stopped part-way says "X of Y", the
//         records not reached stay in the archive AND in search.
//   • C8  a child-hash repair that throws is reported, retried, and the run
//         is not "completed" while one is owed.
//   • C17 a workflow run is found by its number, however old.
//   • §E  values with a quote are bound, not interpolated; a confirmation
//         and its history row are one transaction; a deleted email takes
//         its folder/locator/chunk/child rows with it (held ones keep
//         theirs); `%`/`_` in an attachment type match only themselves.
//
//  Faults are injected with SQLite triggers created on a second connection
//  to the archive file — the store code under test is unchanged.
//

import XCTest
import Foundation
import SQLite3
import CryptoKit
@testable import ArchiveCore

final class StoreAccountingTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("store-accounting-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    // MARK: - Plumbing

    private var storeDir: URL { dir.appendingPathComponent("store", isDirectory: true) }

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

    /// COUNT(*) of `sql` on a second connection.
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

    private static func message(id: String, body: String) -> Data {
        Data(("Message-ID: <\(id)>\r\nFrom: Asha <asha@example.com>\r\nTo: ravi@example.org\r\n"
              + "Subject: Ledger \(id)\r\nDate: Mon, 6 Jan 2025 10:00:00 +0530\r\nMIME-Version: 1.0\r\n"
              + "Content-Type: text/plain; charset=utf-8\r\n\r\n\(body)\r\n").utf8)
    }

    private func captureAccount(_ sink: ConnectedArchiveSink, n: Int) async throws -> UUID {
        let account = UUID()
        try await sink.saveAccount(ConnectedAccountRecord(
            accountID: account, provider: .gmail, issuer: "https://accounts.google.com", host: nil, port: nil,
            displayIdentity: "asha@example.com", grantedScopes: ["https://www.googleapis.com/auth/gmail.readonly"],
            enabledModes: ["capture"], connectionState: "connected", createdAt: Date(), updatedAt: Date()))
        let run = try await sink.beginRun(accountID: account, selection: "all")
        for i in 0..<n {
            let writer = try sink.makeStagingWriter()
            try writer.append(Self.message(id: "acct\(i)@x", body: "zebrafinch body \(i)"))
            let staged = try writer.finish()
            let item = CaptureItem(accountID: account, identity: .gmail(messageID: "g\(i)"),
                                   occurrences: [RemoteFolderOccurrence(serverID: "INBOX", displayPath: "Inbox", kind: .label)],
                                   raw: staged,
                                   metadata: ProviderMetadata(representation: .gmailRaw, internalDate: Date(timeIntervalSince1970: 1_736_137_800),
                                                              revision: "h\(i)", flags: []))
            _ = try await sink.capture(item, runID: run)
        }
        _ = try await sink.finishRun(run)
        return account
    }

    // MARK: - C7

    /// A failure on page 3 of 5: pages 1–2 are deleted and gone from search;
    /// the 12 records not reached stay in the archive and stay searchable,
    /// and the error says "Deleted 8 of 20".
    func testC7_pageFailure_reportsXofY_andRecordsNotReachedStaySearchable() async throws {
        let sink = ConnectedArchiveSink(storeDirectory: storeDir)
        let account = try await captureAccount(sink, n: 20)
        let ids = try await sink.deletableRecordIDs(accountID: account)
        XCTAssertEqual(ids.count, 20)
        let fts = FTSSearchIndex(shardsDirectory: dir.appendingPathComponent("fts", isDirectory: true))
        try await fts.indexBatch(try await sink.store.emails(withIDs: ids))
        let indexed = try await fts.rowCount()
        XCTAssertEqual(indexed, 20)
        // Page 3 (ids[8..<12]) fails inside its transaction.
        sideSQL("CREATE TRIGGER c7_fault BEFORE DELETE ON emails WHEN old.id = '\(ids[9].uuidString)' BEGIN SELECT RAISE(ABORT, 'injected page fault'); END;")

        let purged = ProgressIDs()
        do {
            _ = try await sink.deleteAccountArchive(accountID: account, confirmedCount: 20, pageSize: 4, afterPage: { page in
                purged.append(page)
                try await fts.delete(ids: page)
            })
            XCTFail("a failed page must not read as a finished deletion")
        } catch let incomplete as ConnectedAccountArchiveDeletionIncomplete {
            XCTAssertEqual(incomplete.partial.deletedEmailIDs, Array(ids[0..<8]))
            XCTAssertEqual(incomplete.partial.total, 20)
            XCTAssertEqual(incomplete.partial.notDeleted, 12)
            XCTAssertEqual(incomplete.partial.searchIndexNotPurged, 0)
            let text = incomplete.localizedDescription
            XCTAssertTrue(text.contains("Deleted 8 of 20") && text.contains("12"), text)
            XCTAssertTrue(text.contains("injected page fault"), text)
        }
        XCTAssertEqual(Set(purged.all), Set(ids[0..<8]), "the index lost exactly the committed pages")
        let left = try await sink.store.emails(withIDs: ids)
        XCTAssertEqual(Set(left.map(\.id)), Set(ids[8...]), "pages 3–5 are still in the archive")
        let stillSearchable = try await fts.rowCount()
        XCTAssertEqual(stillSearchable, 12, "…and still searchable")
        // The deleted pages' occurrence rows went with them; the rest stay.
        XCTAssertEqual(sideCount("SELECT COUNT(*) FROM remote_messages WHERE account_id = '\(account.uuidString)';"), 12)

        // The fault cleared, the same request finishes the rest.
        sideSQL("DROP TRIGGER c7_fault;")
        let summary = try await sink.accountArchiveSummary(accountID: account)
        XCTAssertEqual(summary.deletable, 12)
        let rest = try await sink.deleteAccountArchive(accountID: account, confirmedCount: 12, pageSize: 4,
                                                       afterPage: { try await fts.delete(ids: $0) })
        XCTAssertEqual(rest.deletedEmailIDs.count, 12)
        XCTAssertEqual(rest.total, 12)
        XCTAssertEqual(rest.notDeleted, 0)
        let none = try await fts.rowCount()
        XCTAssertEqual(none, 0)
    }

    /// The store path the app calls today: a page failure throws the "X of
    /// Y" error (not the bare SQLite error) and still cleans up what the
    /// committed pages removed.
    func testC7_storePath_pageFailure_throwsXofY_andCleansUpCommittedPages() async throws {
        let sink = ConnectedArchiveSink(storeDirectory: storeDir)
        let account = try await captureAccount(sink, n: 10)
        let ids = try await sink.deletableRecordIDs(accountID: account)
        sideSQL("CREATE TRIGGER c7_fault BEFORE DELETE ON emails WHEN old.id = '\(ids[6].uuidString)' BEGIN SELECT RAISE(ABORT, 'injected'); END;")
        do {
            _ = try await sink.store.deleteConnectedAccountArchive(accountID: account, confirmedCount: 10, pageSize: 3)
            XCTFail("must throw")
        } catch let incomplete as ConnectedAccountArchiveDeletionIncomplete {
            XCTAssertEqual(incomplete.partial.deletedEmailIDs.count, 6)
            XCTAssertEqual(incomplete.partial.total, 10)
            XCTAssertTrue(incomplete.localizedDescription.contains("Deleted 6 of 10"), incomplete.localizedDescription)
        }
        XCTAssertEqual(sideCount("SELECT COUNT(*) FROM remote_messages WHERE account_id = '\(account.uuidString)';"), 4,
                       "the six deleted records' occurrence rows are cleaned up")
    }

    /// A search-index failure after a committed page stops the run and is counted.
    func testC7_searchPurgeFailure_stopsAndCountsTheUnpurgedPage() async throws {
        let sink = ConnectedArchiveSink(storeDirectory: storeDir)
        let account = try await captureAccount(sink, n: 9)
        struct IndexDown: Error, LocalizedError { var errorDescription: String? { "index down" } }
        let calls = ProgressIDs()
        do {
            _ = try await sink.deleteAccountArchive(accountID: account, confirmedCount: 9, pageSize: 3, afterPage: { page in
                calls.append(page)
                if calls.all.count > 3 { throw IndexDown() }
            })
            XCTFail("must throw")
        } catch let incomplete as ConnectedAccountArchiveDeletionIncomplete {
            XCTAssertEqual(incomplete.partial.deletedEmailIDs.count, 6, "page 2 was deleted before its purge failed")
            XCTAssertEqual(incomplete.partial.searchIndexNotPurged, 3)
            XCTAssertEqual(incomplete.partial.notDeleted, 3)
            XCTAssertTrue(incomplete.localizedDescription.contains("index down"), incomplete.localizedDescription)
        }
    }

    final class ProgressIDs: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [UUID] = []
        func append(_ ids: [UUID]) { lock.withLock { items.append(contentsOf: ids) } }
        var all: [UUID] { lock.withLock { items } }
    }

    // MARK: - C8

    private func mimePart(_ filename: String, _ mime: String, _ data: Data) -> String {
        "--B\r\nContent-Type: \(mime); name=\"\(filename)\"\r\nContent-Disposition: attachment; filename=\"\(filename)\"\r\n"
            + "Content-Transfer-Encoding: base64\r\n\r\n\(data.base64EncodedString())\r\n"
    }

    /// Two carriers of an attached .eml whose child row holds the double hash.
    private func childHashFixture(_ store: SQLiteEmailStore) async throws -> (a: UUID, b: UUID, plain: Data) {
        let plain = Data("Plain file next to the document".utf8)
        let inner = "From: inner@example.com\r\nTo: me@example.com\r\nSubject: Inner\r\nMIME-Version: 1.0\r\n"
            + "Content-Type: multipart/mixed; boundary=\"B\"\r\n\r\n--B\r\nContent-Type: text/plain\r\n\r\nInner body\r\n"
            + mimePart("plain.txt", "text/plain", plain) + "--B--\r\n"
        func outer(_ n: Int) throws -> MBOXParser.RawEmail {
            let raw = "From: sender@example.com\r\nTo: user@dest.org\r\nSubject: Carrier \(n)\r\nDate: Wed, 15 Jan 2025 10:0\(n):00 +0000\r\n"
                + "Message-ID: <carrier-\(n)@t>\r\nMIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=\"B\"\r\n\r\n"
                + "--B\r\nContent-Type: text/plain\r\n\r\ncarrier body \(n)\r\n" + mimePart("inner.eml", "message/rfc822", Data(inner.utf8)) + "--B--\r\n"
            return try MBOXParser.processRawMessage(raw, senderEmail: "")
        }
        let emails = [try outer(1), try outer(2)]
        try await store.insertBatch(emails, batchSize: 10)
        let double = ExportFolderManifest.hex(Data(SHA256.hash(data: plain)))
        for e in emails {
            sideSQL("""
                INSERT INTO attachment_text_state(email_id, indexed_at, text_count) VALUES ('\(e.id.uuidString)', 1, 1);
                INSERT INTO attachment_children(email_id, position, child_index, path, filename, kind, sha256, bytes, state, note)
                VALUES ('\(e.id.uuidString)', 0, 0, 'plain.txt', 'plain.txt', 'txt', '\(double)', \(plain.count), 'complete', NULL);
            """)
        }
        return (emails[0].id, emails[1].id, plain)
    }

    func testC8_aThrowingRepair_isReported_notCompleted_andRetriedNextRun() async throws {
        let store = SQLiteEmailStore(directory: storeDir)
        let (a, b, plain) = try await childHashFixture(store)
        let selected = try await store.childHashRepairPage(after: nil, maxExtractorVersion: 7, limit: 10)
        XCTAssertEqual(Set(selected), [a, b], "the fixture is on the affected path")
        let suite = "childhash-acct-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        // A's one-message transaction fails.
        sideSQL("CREATE TRIGGER c8_fault BEFORE UPDATE ON attachment_children WHEN old.email_id = '\(a.uuidString)' BEGIN SELECT RAISE(ABORT, 'injected'); END;")
        let first = await ChildHashRepair.run(store: store, defaults: defaults)
        XCTAssertEqual(first.messages, 2)
        XCTAssertEqual(first.rowsFailed, 1)
        XCTAssertEqual(first.rowsRepaired, 1, "B only — A's rolled-back update is not counted as repaired")
        XCTAssertFalse(first.completed, "a run with a failed message is not complete")
        let afterFirst = try XCTUnwrap(ChildHashRepair.record(defaults: defaults))
        XCTAssertFalse(afterFirst.completed)
        XCTAssertEqual(afterFirst.rowsFailed, 1)
        XCTAssertEqual(afterFirst.failedMessageIDs, [a])
        let text = try XCTUnwrap(ChildHashRepair.reportText(afterFirst))
        XCTAssertTrue(text.contains("1 repaired") && text.contains("1 messages failed"), text)
        XCTAssertTrue(text.contains("Not finished"), text)

        // The fault cleared: the next run retries A only, and completes.
        sideSQL("DROP TRIGGER c8_fault;")
        let second = await ChildHashRepair.run(store: store, defaults: defaults)
        XCTAssertFalse(second.alreadyDone)
        XCTAssertEqual(second.messages, 1, "only the owed message")
        XCTAssertEqual(second.rowsFailed, 0)
        XCTAssertEqual(second.rowsRepaired, 1)
        XCTAssertTrue(second.completed)
        let done = try XCTUnwrap(ChildHashRepair.record(defaults: defaults))
        XCTAssertTrue(done.completed)
        XCTAssertEqual(done.rowsFailed, 0)
        XCTAssertNil(done.failedMessageIDs)
        XCTAssertEqual(done.rowsRepaired, 2)
        XCTAssertEqual(done.messages, 2)
        let rows = try await store.attachmentChildren(forEmailID: a)
        XCTAssertEqual(rows.map(\.sha256), [ExportFolderManifest.hex(plain)])
        let finalText = try XCTUnwrap(ChildHashRepair.reportText(done))
        XCTAssertFalse(finalText.contains("failed"), finalText)
    }

    /// A record written before failures were kept ("completed" with failures
    /// it cannot name) is not trusted: the repair runs again.
    func testC8_legacyCompletedRecordWithFailures_runsAgain() async throws {
        let store = SQLiteEmailStore(directory: storeDir)
        let (a, _, plain) = try await childHashFixture(store)
        let suite = "childhash-acct-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = ChildHashRepair.Record(version: ChildHashRepair.currentVersion, storePath: store.storeDirectory.path, completed: true,
                                            cursor: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"), messages: 2, rowsChecked: 1,
                                            rowsRepaired: 1, rowsUnverifiable: 0, rowsFailed: 1, startedAt: Date(), updatedAt: Date())
        ChildHashRepair.save(legacy, defaults: defaults)
        let run = await ChildHashRepair.run(store: store, defaults: defaults)
        XCTAssertFalse(run.alreadyDone)
        XCTAssertTrue(run.completed)
        let rows = try await store.attachmentChildren(forEmailID: a)
        XCTAssertEqual(rows.map(\.sha256), [ExportFolderManifest.hex(plain)])
    }

    // MARK: - C17

    func testC17_instanceByNumber_findsARunOlderThanTheNewest10000() async throws {
        let store = SQLiteEmailStore(directory: storeDir)
        let wf = try await store.createInstance(defID: "def-1", title: "Oldest run", now: Date(timeIntervalSince1970: 1_000))
        // 10,050 newer runs.
        var sql = "BEGIN;"
        for i in 0..<10_050 {
            sql += "INSERT INTO workflow_instances(wf_number, def_id, title, status, created_at, created_by, updated_at, reverses) VALUES ('WF-N\(i)', 'def-1', 't', 'open', \(2_000 + i), '', \(2_000 + i), NULL);"
        }
        sideSQL(sql + "COMMIT;")
        let found = try await store.instance(wf: wf)
        XCTAssertEqual(found?.wfNumber, wf)
        XCTAssertEqual(found?.title, "Oldest run")
        let missing = try await store.instance(wf: "WF-none")
        XCTAssertNil(missing)
    }

    // MARK: - §E bound values, confirmOperation transaction

    func testSQL_valuesWithAQuote_areBound() async throws {
        let store = SQLiteEmailStore(directory: storeDir)
        try await store.upsertDefinition(defID: "o'brien-def", name: "O'Brien", persona: "Counsel's", builtin: false,
                                         operations: [.init(seq: 1, key: "k", title: "Step", hint: "", postsDocType: nil)])
        try await store.upsertDefinition(defID: "o'brien-def", name: "O'Brien", persona: "Counsel's", builtin: false,
                                         operations: [.init(seq: 1, key: "k2", title: "Step", hint: "", postsDocType: nil)])
        let defs = try await store.definitions(persona: "Counsel's")
        XCTAssertEqual(defs.map(\.defID), ["o'brien-def"])
        XCTAssertEqual(defs.first?.operations.map(\.key), ["k2"], "the re-upsert replaced the operations")
        let filtered = try await store.instances(status: "it's")
        XCTAssertTrue(filtered.isEmpty)

        let doc = try await store.issueDocument(type: "T'X", summary: "s")
        let reversal = try await store.reverseDocument(doc, type: "T'X", reason: "wrong")
        let docs = try await store.documents(ofType: "T'X")
        XCTAssertEqual(Set(docs.map(\.number)), [doc, reversal])
        XCTAssertEqual(docs.first { $0.number == doc }?.reversedBy, reversal)

        sideSQL("INSERT INTO workflow_instances(wf_number, def_id, title, status, created_at, created_by, updated_at, reverses) VALUES ('WF''1', 'd', 't', 'open', 1, '', 1, NULL);")
        try await store.confirmOperation(wf: "WF'1", seq: 1, totalOps: 1, result: "ok", note: "", docNumber: nil)
        let run = try await store.instance(wf: "WF'1")
        XCTAssertEqual(run?.status, "confirmed")
    }

    func testConfirmOperation_failedHistoryInsert_undoesTheConfirmation() async throws {
        let store = SQLiteEmailStore(directory: storeDir)
        let wf = try await store.createInstance(defID: "def-1", title: "Run")
        sideSQL("CREATE TRIGGER hist_fault BEFORE INSERT ON workflow_status_history BEGIN SELECT RAISE(ABORT, 'injected'); END;")
        do {
            try await store.confirmOperation(wf: wf, seq: 1, totalOps: 2, result: "ok", note: "", docNumber: nil)
            XCTFail("a failed history insert must fail the confirmation")
        } catch {}
        XCTAssertEqual(sideCount("SELECT COUNT(*) FROM workflow_confirmations WHERE wf_number = '\(wf)';"), 0)
        let run = try await store.instance(wf: wf)
        XCTAssertEqual(run?.status, "open", "status unchanged: nothing of the confirmation landed")
        sideSQL("DROP TRIGGER hist_fault;")
        try await store.confirmOperation(wf: wf, seq: 1, totalOps: 2, result: "ok", note: "", docNumber: nil)
        XCTAssertEqual(sideCount("SELECT COUNT(*) FROM workflow_status_history WHERE wf_number = '\(wf)';"), 1)
    }

    // MARK: - §E deleteReportingHeld dependents

    func testDelete_removesDependentRows_ofDeletedMailOnly_heldKeepTheirs() async throws {
        let store = SQLiteEmailStore(directory: storeDir)
        let emails = try (0..<3).map { i in
            try MBOXParser.processRawMessage(String(decoding: Self.message(id: "dep\(i)@x", body: "body \(i)"), as: UTF8.self), senderEmail: "")
        }
        try await store.insertBatch(emails, batchSize: 10)
        let (gone, held, other) = (emails[0].id.uuidString, emails[1].id.uuidString, emails[2].id.uuidString)
        for id in [gone, held, other] {
            sideSQL("""
                INSERT OR IGNORE INTO email_folders(email_id, folder_id) VALUES ('\(id)', 1);
                INSERT OR REPLACE INTO message_locators(email_id, source_path, source_digest, msg_offset, msg_length, header_offset, header_length, body_offset, body_length)
                VALUES ('\(id)', '/src.mbox', NULL, 0, 10, 0, 5, 5, 5);
                INSERT OR REPLACE INTO part_locators(email_id, part_index, mime_path, mime_type, filename, content_id, encoding, content_offset, content_length, header_offset, header_length)
                VALUES ('\(id)', 0, '1', 'text/plain', NULL, NULL, NULL, 0, 1, 0, 1);
                INSERT OR REPLACE INTO attachment_children(email_id, position, child_index, path, filename, kind, sha256, bytes, state, note)
                VALUES ('\(id)', 0, 0, 'a.txt', 'a.txt', 'txt', '', 1, 'complete', NULL);
                INSERT OR REPLACE INTO search_docs(email_id, kind, ordinal, state) VALUES ('\(id)', 'body', 0, 'complete');
                INSERT INTO search_chunks(email_id, kind, ordinal, chunk, text) VALUES ('\(id)', 'body', 0, 0, 'kestrel words');
            """)
        }
        let before = try await store.backupCounts()
        await store.setEnforcesDatabaseLegalHolds(true)
        _ = try await store.legalHoldsAdd([emails[1].id], matter: "M", sync: true)
        let refused = try await store.deleteReportingHeld(ids: [emails[0].id, emails[1].id])
        XCTAssertEqual(refused, [emails[1].id])
        for table in ["email_folders", "message_locators", "part_locators", "attachment_children", "search_docs", "search_chunks"] {
            XCTAssertEqual(sideCount("SELECT COUNT(*) FROM \(table) WHERE email_id = '\(gone)';"), 0, "\(table) rows of the deleted email")
            XCTAssertEqual(sideCount("SELECT COUNT(*) FROM \(table) WHERE email_id = '\(held)';"), 1, "\(table) rows of the held email stay")
            XCTAssertEqual(sideCount("SELECT COUNT(*) FROM \(table) WHERE email_id = '\(other)';"), 1, "\(table) rows of an untouched email stay")
        }
        let after = try await store.backupCounts()
        XCTAssertEqual(after.emails, before.emails - 1)
        XCTAssertEqual(after.locatorBacked, before.locatorBacked - 1, "the backup inventory no longer counts the deleted mail's locator")
        XCTAssertEqual(after.folderMemberships, before.folderMemberships - 1)
    }

    // MARK: - §E LIKE escaping

    @MainActor
    func testAttachmentType_percentAndUnderscore_matchOnlyThemselves() async throws {
        let wasOn = SearchChunkPolicy.isEnabled
        SearchChunkPolicy.isEnabled = true
        defer { SearchChunkPolicy.isEnabled = wasOn }
        let store = SQLiteEmailStore(directory: storeDir)
        let fts = FTSSearchIndex(shardsDirectory: dir.appendingPathComponent("fts", isDirectory: true))
        let archive = ArchiveDataService(repository: EmailStoreRepository(store: store, fts: fts))
        let names = ["report.docx", "odd.d_cx", "pct.d%cx", "back.d\\cx"]
        let emails = names.enumerated().map { i, name in
            MBOXParser.RawEmail(
                headers: ["Message-ID": "<like-\(i)@test>", "Subject": name, "From": "a@test", "To": "b@test",
                          "Date": "Wed, 01 Mar 2023 12:00:0\(i) +0000"],
                rawSource: "", messageType: "email",
                attachments: [AttachmentMetadata(filename: name, mimeType: "application/octet-stream", size: 3)],
                timestamp: "", domains: [], plainBody: "cover", htmlBody: "")
        }
        try await store.insertBatch(emails, batchSize: 10)
        func subjects(type: String) async throws -> Set<String> {
            var query = EmailQuery()
            query.spec = SearchSpec(groups: [SearchGroup(.all, attachments: [AttachmentConditionGroup(type: type)])])
            var out = Set<String>()
            for try await batch in archive.streamFullEmails(query: query, batchSize: 50) {
                for e in batch { out.insert(e.headers["Subject"] ?? "") }
            }
            let count = try await archive.count(query: query)
            XCTAssertEqual(count, out.count)
            return out
        }
        let docx = try await subjects(type: "docx")
        XCTAssertEqual(docx, ["report.docx"])
        let underscore = try await subjects(type: "d_cx")
        XCTAssertEqual(underscore, ["odd.d_cx"], "_ is not a wildcard")
        let percent = try await subjects(type: "d%cx")
        XCTAssertEqual(percent, ["pct.d%cx"], "% is not a wildcard")
        let backslash = try await subjects(type: "d\\cx")
        XCTAssertEqual(backslash, ["back.d\\cx"], "the escape character is itself literal")
        XCTAssertEqual(SQLiteEmailStore.likeLiteral("a%b_c\\d"), "a\\%b\\_c\\\\d")
    }
}
