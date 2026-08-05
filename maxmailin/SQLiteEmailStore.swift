//
//  SQLiteEmailStore.swift
//  maxmailin
//
//  Stage 4B (v2-core-cutover): the direct-SQLite/blob canonical store that
//  replaces SwiftData behind `EmailRepository`. Chosen because the stress
//  harness proved SwiftData couldn't scale import (O(N²) unindexed dedup) or
//  keyset paging (O(N) unindexed date) on the macOS 14.6 / iOS 17.6 target,
//  where SwiftData exposes no secondary-index API. Here we `CREATE INDEX`
//  freely:
//    • a PARTIAL UNIQUE index on message_id (WHERE message_id IS NOT NULL) turns
//      dedup into a single `INSERT OR IGNORE` — O(1) per row, and NULLs (no
//      Message-ID) are never collapsed, so no data loss;
//    • an index on (date, id) makes the keyset page an O(log N) seek.
//
//  Bounded memory by construction: bodies live in a separate `email_bodies`
//  table, so summary/paging/count/reconcile scans never touch blob data. The
//  same actor-isolated contract as `EmailStore` (see `EmailArchiveStore`), so
//  the repository and UI are unchanged.
//

import Foundation
import SQLite3
import os.log

private let sqliteStoreLog = Logger(subsystem: "com.ecosanskriti.mailin", category: "SQLiteEmailStore")

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

actor SQLiteEmailStore: EmailArchiveStore {

    private let directory: URL
    private var db: OpaquePointer?

    /// The production store, under Application Support (Data Protection applies).
    /// Kept in its own `sqlite/` subdir, separate from the SwiftData store so a
    /// non-destructive migration can read the old store while writing the new.
    static let shared = SQLiteEmailStore(directory: SQLiteEmailStore.productionDirectory)

    static var productionDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return appSupport
            .appendingPathComponent("com.ecosanskriti.mailin", isDirectory: true)
            .appendingPathComponent("sqlite", isDirectory: true)
    }

    /// Isolated on-disk store under `directory` (harness/test), or the shared
    /// production store via `.shared`.
    init(directory: URL) {
        self.directory = directory
    }

    /// The on-disk location of this store. Used by the activation coordinator's
    /// reopen gate to prove durability with a fresh connection.
    nonisolated var storeDirectory: URL { directory }

    deinit { if let db { sqlite3_close(db) } }

    // MARK: - Open / schema

    private func ensureDB() throws -> OpaquePointer {
        if let db { return db }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("emails.db")
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(
            url.path, &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil
        )
        guard rc == SQLITE_OK, let handle else {
            throw SQLiteStoreError.open("sqlite3_open_v2 rc=\(rc)")
        }
        try exec(handle, "PRAGMA journal_mode = WAL;")
        try exec(handle, "PRAGMA synchronous = NORMAL;")
        try exec(handle, "PRAGMA foreign_keys = OFF;")
        // The default 8 MB page cache is far too small for a multi-GB archive:
        // random inserts into the UUID-PK / message_id / (date,id) B-trees fall
        // off a cache cliff and go disk-bound. A fixed 128 MB cache + memory-
        // mapped reads keep import throughput and deep-page seeks flat. Both are
        // CONSTANT regardless of archive size, so resident memory stays bounded.
        try exec(handle, "PRAGMA cache_size = -131072;")   // 128 MB (negative ⇒ KB)
        try exec(handle, "PRAGMA mmap_size = 268435456;")  // 256 MB memory-mapped I/O
        try exec(handle, "PRAGMA temp_store = MEMORY;")
        try exec(handle, """
            CREATE TABLE IF NOT EXISTS emails(
                id            TEXT PRIMARY KEY,
                message_id    TEXT,
                subject       TEXT NOT NULL DEFAULT '',
                from_addr     TEXT NOT NULL DEFAULT '',
                to_addr       TEXT NOT NULL DEFAULT '',
                cc_addr       TEXT,
                bcc_addr      TEXT,
                date          INTEGER NOT NULL,
                body_preview  TEXT NOT NULL DEFAULT '',
                has_attach    INTEGER NOT NULL DEFAULT 0,
                size_bytes    INTEGER NOT NULL DEFAULT 0,
                in_reply_to   TEXT,
                references_ids TEXT,
                account_id    TEXT,
                source_hash   TEXT
            );
        """)
        try exec(handle, """
            CREATE TABLE IF NOT EXISTS email_bodies(
                id           TEXT PRIMARY KEY,
                plain        BLOB,
                html         BLOB,
                raw          BLOB,
                headers_json BLOB
            );
        """)
        // Keyset paging index: (date DESC, id DESC) is served by this.
        try exec(handle, "CREATE INDEX IF NOT EXISTS idx_emails_date_id ON emails(date, id);")
        // Dedup index: unique on Message-ID, but only where present — multiple
        // NULL (no-Message-ID) rows are allowed and never collapsed.
        try exec(handle, "CREATE UNIQUE INDEX IF NOT EXISTS idx_emails_msgid ON emails(message_id) WHERE message_id IS NOT NULL;")
        // Meta (corpus revision etc.) + per-email derived analysis state.
        try exec(handle, "CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value INTEGER NOT NULL DEFAULT 0);")
        try exec(handle, """
            CREATE TABLE IF NOT EXISTS derived(
                email_id         TEXT PRIMARY KEY,
                corpus_revision  INTEGER NOT NULL DEFAULT 0,
                analysis_version INTEGER NOT NULL DEFAULT 0,
                sentiment        TEXT,
                classification   TEXT,
                priority         INTEGER,
                phishing         INTEGER,
                topic            TEXT,
                thread_id        TEXT,
                predictive       REAL,
                smart_tags       TEXT,
                updated_at       INTEGER NOT NULL DEFAULT 0
            );
        """)
        try exec(handle, "CREATE INDEX IF NOT EXISTS idx_derived_topic ON derived(topic);")
        try exec(handle, "CREATE INDEX IF NOT EXISTS idx_derived_thread ON derived(thread_id);")
        try exec(handle, "CREATE INDEX IF NOT EXISTS idx_derived_rev ON derived(corpus_revision);")
        self.db = handle
        return handle
    }

    // MARK: - Corpus revision

    func corpusRevision() throws -> Int {
        let db = try ensureDB()
        return try scalarInt(db, "SELECT value FROM meta WHERE key = 'corpus_revision';")
    }

    @discardableResult
    func bumpCorpusRevision() throws -> Int {
        let db = try ensureDB()
        try exec(db, """
            INSERT INTO meta(key, value) VALUES ('corpus_revision', 1)
            ON CONFLICT(key) DO UPDATE SET value = value + 1;
        """)
        return try corpusRevision()
    }

    // MARK: - Derived state (per-email analysis)

    func derivedUpsert(_ records: [DerivedRecord]) throws {
        guard !records.isEmpty else { return }
        let db = try ensureDB()
        let stmt = try prepare(db, """
            INSERT INTO derived(email_id, corpus_revision, analysis_version, sentiment, classification,
                priority, phishing, topic, thread_id, predictive, smart_tags, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(email_id) DO UPDATE SET
                corpus_revision=excluded.corpus_revision, analysis_version=excluded.analysis_version,
                sentiment=excluded.sentiment, classification=excluded.classification, priority=excluded.priority,
                phishing=excluded.phishing, topic=excluded.topic, thread_id=excluded.thread_id,
                predictive=excluded.predictive, smart_tags=excluded.smart_tags, updated_at=excluded.updated_at;
        """)
        defer { sqlite3_finalize(stmt) }
        try exec(db, "BEGIN TRANSACTION;")
        do {
            for r in records {
                sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
                bindText(stmt, 1, r.emailID.uuidString)
                sqlite3_bind_int64(stmt, 2, Int64(r.corpusRevision))
                sqlite3_bind_int64(stmt, 3, Int64(r.analysisVersion))
                bindTextOrNull(stmt, 4, r.sentiment)
                bindTextOrNull(stmt, 5, r.classification)
                if let p = r.priority { sqlite3_bind_int64(stmt, 6, Int64(p)) } else { sqlite3_bind_null(stmt, 6) }
                if let ph = r.phishing { sqlite3_bind_int(stmt, 7, ph ? 1 : 0) } else { sqlite3_bind_null(stmt, 7) }
                bindTextOrNull(stmt, 8, r.topic)
                bindTextOrNull(stmt, 9, r.threadID)
                if let pv = r.predictiveScore { sqlite3_bind_double(stmt, 10, pv) } else { sqlite3_bind_null(stmt, 10) }
                bindTextOrNull(stmt, 11, r.smartTags.isEmpty ? nil : r.smartTags.joined(separator: "\u{1F}"))
                sqlite3_bind_int64(stmt, 12, Int64(r.updatedAt))
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
            }
            try exec(db, "COMMIT;")
        } catch { try? exec(db, "ROLLBACK;"); throw error }
    }

    func derivedFetch(ids: [EmailID]) throws -> [EmailID: DerivedRecord] {
        guard !ids.isEmpty else { return [:] }
        let db = try ensureDB()
        var out: [EmailID: DerivedRecord] = [:]
        for chunk in ids.chunked(into: 500) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let stmt = try prepare(db, """
                SELECT email_id, corpus_revision, analysis_version, sentiment, classification, priority,
                       phishing, topic, thread_id, predictive, smart_tags, updated_at
                FROM derived WHERE email_id IN (\(placeholders));
            """)
            defer { sqlite3_finalize(stmt) }
            for (i, id) in chunk.enumerated() { bindText(stmt, Int32(i + 1), id.uuidString) }
            while try stepRow(stmt, db) {
                guard let id = columnUUID(stmt, 0) else { continue }
                out[id] = DerivedRecord(
                    emailID: id,
                    corpusRevision: Int(sqlite3_column_int64(stmt, 1)),
                    analysisVersion: Int(sqlite3_column_int64(stmt, 2)),
                    sentiment: columnTextOptional(stmt, 3),
                    classification: columnTextOptional(stmt, 4),
                    priority: sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 5)),
                    phishing: sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : (sqlite3_column_int(stmt, 6) != 0),
                    topic: columnTextOptional(stmt, 7),
                    threadID: columnTextOptional(stmt, 8),
                    predictiveScore: sqlite3_column_type(stmt, 9) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 9),
                    smartTags: columnTextOptional(stmt, 10).map { $0.split(separator: "\u{1F}").map(String.init) } ?? [],
                    updatedAt: Int(sqlite3_column_int64(stmt, 11))
                )
            }
        }
        return out
    }

    /// Email ids whose derived state is missing or stale relative to `revision`
    /// — the work list for a background analysis job. Joined to `emails` so
    /// deleted rows never appear.
    func derivedStaleIDs(below revision: Int, limit: Int) throws -> [EmailID] {
        let db = try ensureDB()
        let stmt = try prepare(db, """
            SELECT e.id FROM emails e
            LEFT JOIN derived d ON d.email_id = e.id
            WHERE d.email_id IS NULL OR d.corpus_revision < ?
            LIMIT ?;
        """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(revision))
        sqlite3_bind_int(stmt, 2, Int32(limit))
        var out: [EmailID] = []
        while try stepRow(stmt, db) { if let id = columnUUID(stmt, 0) { out.append(id) } }
        return out
    }

    func derivedCount() throws -> Int {
        let db = try ensureDB()
        return try scalarInt(db, "SELECT COUNT(*) FROM derived;")
    }

    func derivedDelete(ids: Set<EmailID>) throws {
        guard !ids.isEmpty else { return }
        let db = try ensureDB()
        for chunk in Array(ids).chunked(into: 500) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let stmt = try prepare(db, "DELETE FROM derived WHERE email_id IN (\(placeholders));")
            defer { sqlite3_finalize(stmt) }
            for (i, id) in chunk.enumerated() { bindText(stmt, Int32(i + 1), id.uuidString) }
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
        }
    }

    // MARK: - Insertion

    func insertBatch(
        _ emails: [MBOXParser.RawEmail],
        sourceFileHash: String?,
        accountID: String?,
        batchSize: Int,
        progress: ((Int, Int) -> Void)?
    ) throws {
        let db = try ensureDB()
        let total = emails.count
        var processed = 0

        let insertEmail = try prepare(db, """
            INSERT OR IGNORE INTO emails(
                id, message_id, subject, from_addr, to_addr, cc_addr, bcc_addr,
                date, body_preview, has_attach, size_bytes, in_reply_to,
                references_ids, account_id, source_hash
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
        """)
        let insertBody = try prepare(db, """
            INSERT OR IGNORE INTO email_bodies(id, plain, html, raw, headers_json)
            VALUES (?,?,?,?,?);
        """)
        defer { sqlite3_finalize(insertEmail); sqlite3_finalize(insertBody) }

        for chunk in emails.chunked(into: max(1, batchSize)) {
            try exec(db, "BEGIN TRANSACTION;")
            do {
                for email in chunk {
                    let idStr = email.id.uuidString
                    let mid = email.headers["Message-ID"].flatMap { $0.isEmpty ? nil : $0 }
                    let date = Self.parsedDate(from: email.headers["Date"]) ?? Date.distantPast
                    let dateInt = Int64(date.timeIntervalSince1970.rounded())

                    sqlite3_reset(insertEmail); sqlite3_clear_bindings(insertEmail)
                    bindText(insertEmail, 1, idStr)
                    bindTextOrNull(insertEmail, 2, mid)
                    bindText(insertEmail, 3, email.headers["Subject"] ?? "(No Subject)")
                    bindText(insertEmail, 4, email.headers["From"] ?? "")
                    bindText(insertEmail, 5, email.headers["To"] ?? "")
                    bindTextOrNull(insertEmail, 6, email.headers["Cc"])
                    bindTextOrNull(insertEmail, 7, email.headers["Bcc"])
                    sqlite3_bind_int64(insertEmail, 8, dateInt)
                    bindText(insertEmail, 9, String(email.plainBody.prefix(400)))
                    sqlite3_bind_int(insertEmail, 10, email.attachments.isEmpty ? 0 : 1)
                    sqlite3_bind_int64(insertEmail, 11, Int64(email.rawSource.utf8.count))
                    bindTextOrNull(insertEmail, 12, email.headers["In-Reply-To"])
                    bindTextOrNull(insertEmail, 13, email.headers["References"])
                    bindTextOrNull(insertEmail, 14, accountID)
                    bindTextOrNull(insertEmail, 15, sourceFileHash)
                    guard sqlite3_step(insertEmail) == SQLITE_DONE else {
                        throw SQLiteStoreError.step(lastError(db))
                    }
                    // Only write the body if the email row was actually inserted
                    // (not a deduped duplicate) — keeps the two tables in step.
                    if sqlite3_changes(db) == 1 {
                        sqlite3_reset(insertBody); sqlite3_clear_bindings(insertBody)
                        bindText(insertBody, 1, idStr)
                        bindBlob(insertBody, 2, email.plainBody.data(using: .utf8))
                        bindBlob(insertBody, 3, email.htmlBody.data(using: .utf8))
                        bindBlob(insertBody, 4, email.rawSource.data(using: .utf8))
                        bindBlob(insertBody, 5, try? JSONEncoder().encode(email.headers))
                        guard sqlite3_step(insertBody) == SQLITE_DONE else {
                            throw SQLiteStoreError.step(lastError(db))
                        }
                    }
                }
                try exec(db, "COMMIT;")
            } catch {
                try? exec(db, "ROLLBACK;")
                throw error
            }
            processed += chunk.count
            progress?(processed, total)
        }
    }

    // MARK: - Counts

    func totalCount() throws -> Int {
        let db = try ensureDB()
        return try scalarInt(db, "SELECT COUNT(*) FROM emails;")
    }

    func count(after: Date?, before: Date?) throws -> Int {
        let db = try ensureDB()
        if after == nil && before == nil {
            return try scalarInt(db, "SELECT COUNT(*) FROM emails;")
        }
        let lo = after.map { Int64($0.timeIntervalSince1970.rounded()) } ?? Int64.min
        let hi = before.map { Int64($0.timeIntervalSince1970.rounded()) } ?? Int64.max
        let stmt = try prepare(db, "SELECT COUNT(*) FROM emails WHERE date >= ? AND date < ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, lo)
        sqlite3_bind_int64(stmt, 2, hi)
        guard try stepRow(stmt, db) else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    // MARK: - Aggregates (DB-side; never stream bodies to count metadata)

    /// Min/max stored date as unix seconds.
    func dateRangeSeconds() throws -> (min: Int64?, max: Int64?) {
        let db = try ensureDB()
        let stmt = try prepare(db, "SELECT MIN(date), MAX(date) FROM emails;")
        defer { sqlite3_finalize(stmt) }
        guard try stepRow(stmt, db) else { return (nil, nil) }
        let lo = sqlite3_column_type(stmt, 0) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 0)
        let hi = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 1)
        return (lo, hi)
    }

    func attachmentCount() throws -> Int {
        let db = try ensureDB()
        return try scalarInt(db, "SELECT COUNT(*) FROM emails WHERE has_attach = 1;")
    }

    /// Email volume per calendar month ("YYYY-MM" → count) — a DB GROUP BY, not
    /// a corpus scan. Powers analytics time-series without streaming bodies.
    func monthlyCounts() throws -> [AggregateBucket] {
        let db = try ensureDB()
        let stmt = try prepare(db, """
            SELECT strftime('%Y-%m', date, 'unixepoch') AS m, COUNT(*) AS c
            FROM emails GROUP BY m ORDER BY m;
        """)
        defer { sqlite3_finalize(stmt) }
        var out: [AggregateBucket] = []
        while try stepRow(stmt, db) {
            out.append(AggregateBucket(value: columnText(stmt, 0), count: Int(sqlite3_column_int64(stmt, 1))))
        }
        return out
    }

    /// Whitelisted grouping columns — the raw value is the actual column, so no
    /// user string is ever interpolated into SQL.
    enum GroupColumn: String, Sendable { case fromAddr = "from_addr", subject = "subject", toAddr = "to_addr" }

    /// Top `limit` values of a column by frequency (GROUP BY … ORDER BY count).
    func topGrouped(_ column: GroupColumn, limit: Int) throws -> [AggregateBucket] {
        let db = try ensureDB()
        let stmt = try prepare(db, """
            SELECT \(column.rawValue) AS v, COUNT(*) AS c FROM emails
            WHERE v IS NOT NULL AND v <> '' GROUP BY v ORDER BY c DESC, v ASC LIMIT ?;
        """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        var out: [AggregateBucket] = []
        while try stepRow(stmt, db) {
            out.append(AggregateBucket(value: columnText(stmt, 0), count: Int(sqlite3_column_int64(stmt, 1))))
        }
        return out
    }

    // MARK: - Paging

    func summaryPage(after: Date?, before: Date?, cursorDate: Date?, cursorID: UUID?, limit: Int) throws -> [EmailSummary] {
        let db = try ensureDB()
        let lo = after.map { Int64($0.timeIntervalSince1970.rounded()) } ?? Int64.min
        let hi = before.map { Int64($0.timeIntervalSince1970.rounded()) } ?? Int64.max
        var sql = """
            SELECT id, message_id, subject, from_addr, date, body_preview, has_attach, size_bytes
            FROM emails WHERE date >= ? AND date < ?
        """
        let hasCursor = (cursorDate != nil && cursorID != nil)
        if hasCursor { sql += " AND (date < ? OR (date = ? AND id < ?))" }
        sql += " ORDER BY date DESC, id DESC LIMIT ?;"

        let stmt = try prepare(db, sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, lo)
        sqlite3_bind_int64(stmt, 2, hi)
        var idx: Int32 = 3
        if hasCursor, let cd = cursorDate, let ci = cursorID {
            let cdInt = Int64(cd.timeIntervalSince1970.rounded())
            sqlite3_bind_int64(stmt, idx, cdInt); idx += 1
            sqlite3_bind_int64(stmt, idx, cdInt); idx += 1
            bindText(stmt, idx, ci.uuidString); idx += 1
        }
        sqlite3_bind_int(stmt, idx, Int32(limit))

        var out: [EmailSummary] = []
        while try stepRow(stmt, db) {
            guard let id = columnUUID(stmt, 0) else { continue }
            out.append(EmailSummary(
                id: id,
                messageID: columnTextOptional(stmt, 1),
                subject: columnText(stmt, 2),
                from: columnText(stmt, 3),
                date: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 4))),
                bodyPreview: columnText(stmt, 5),
                hasAttachments: sqlite3_column_int(stmt, 6) != 0,
                sizeBytes: Int(sqlite3_column_int64(stmt, 7))
            ))
        }
        return out
    }

    func reconcilePage(beforeDate: Date?, beforeID: UUID?, limit: Int) throws -> [(id: UUID, date: Date)] {
        let db = try ensureDB()
        var sql = "SELECT id, date FROM emails"
        let hasCursor = (beforeDate != nil && beforeID != nil)
        if hasCursor { sql += " WHERE (date < ? OR (date = ? AND id < ?))" }
        sql += " ORDER BY date DESC, id DESC LIMIT ?;"
        let stmt = try prepare(db, sql)
        defer { sqlite3_finalize(stmt) }
        var idx: Int32 = 1
        if hasCursor, let bd = beforeDate, let bi = beforeID {
            let bdInt = Int64(bd.timeIntervalSince1970.rounded())
            sqlite3_bind_int64(stmt, idx, bdInt); idx += 1
            sqlite3_bind_int64(stmt, idx, bdInt); idx += 1
            bindText(stmt, idx, bi.uuidString); idx += 1
        }
        sqlite3_bind_int(stmt, idx, Int32(limit))
        var out: [(id: UUID, date: Date)] = []
        while try stepRow(stmt, db) {
            guard let id = columnUUID(stmt, 0) else { continue }
            out.append((id, Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 1)))))
        }
        return out
    }

    // MARK: - Lookups by id

    func summaries(ids: [UUID]) throws -> [EmailSummary] {
        guard !ids.isEmpty else { return [] }
        let db = try ensureDB()
        var out: [EmailSummary] = []
        for chunk in ids.chunked(into: 500) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let stmt = try prepare(db, """
                SELECT id, message_id, subject, from_addr, date, body_preview, has_attach, size_bytes
                FROM emails WHERE id IN (\(placeholders));
            """)
            defer { sqlite3_finalize(stmt) }
            for (i, id) in chunk.enumerated() { bindText(stmt, Int32(i + 1), id.uuidString) }
            while try stepRow(stmt, db) {
                guard let id = columnUUID(stmt, 0) else { continue }
                out.append(EmailSummary(
                    id: id,
                    messageID: columnTextOptional(stmt, 1),
                    subject: columnText(stmt, 2),
                    from: columnText(stmt, 3),
                    date: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 4))),
                    bodyPreview: columnText(stmt, 5),
                    hasAttachments: sqlite3_column_int(stmt, 6) != 0,
                    sizeBytes: Int(sqlite3_column_int64(stmt, 7))
                ))
            }
        }
        return out
    }

    func existingIDs(among ids: [UUID]) throws -> Set<UUID> {
        guard !ids.isEmpty else { return [] }
        let db = try ensureDB()
        var found = Set<UUID>()
        for chunk in ids.chunked(into: 500) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let stmt = try prepare(db, "SELECT id FROM emails WHERE id IN (\(placeholders));")
            defer { sqlite3_finalize(stmt) }
            for (i, id) in chunk.enumerated() { bindText(stmt, Int32(i + 1), id.uuidString) }
            while try stepRow(stmt, db) {
                if let id = columnUUID(stmt, 0) { found.insert(id) }
            }
        }
        return found
    }

    func emails(withIDs ids: [UUID]) throws -> [MBOXParser.RawEmail] {
        guard !ids.isEmpty else { return [] }
        let db = try ensureDB()
        var out: [MBOXParser.RawEmail] = []
        for chunk in ids.chunked(into: 200) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let stmt = try prepare(db, """
                SELECT e.id, e.message_id, e.in_reply_to, e.references_ids, e.date,
                       b.plain, b.html, b.raw, b.headers_json
                FROM emails e LEFT JOIN email_bodies b ON e.id = b.id
                WHERE e.id IN (\(placeholders));
            """)
            defer { sqlite3_finalize(stmt) }
            for (i, id) in chunk.enumerated() { bindText(stmt, Int32(i + 1), id.uuidString) }
            while try stepRow(stmt, db) {
                if let email = rawEmailFromRow(stmt) { out.append(email) }
            }
        }
        return out
    }

    func fullEmail(id: UUID) throws -> MBOXParser.RawEmail? {
        let db = try ensureDB()
        let stmt = try prepare(db, """
            SELECT e.id, e.message_id, e.in_reply_to, e.references_ids, e.date,
                   b.plain, b.html, b.raw, b.headers_json
            FROM emails e LEFT JOIN email_bodies b ON e.id = b.id
            WHERE e.id = ?;
        """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, id.uuidString)
        guard try stepRow(stmt, db) else { return nil }
        return rawEmailFromRow(stmt)
    }

    // MARK: - Mutation

    func delete(ids: Set<UUID>) throws {
        guard !ids.isEmpty else { return }
        let db = try ensureDB()
        try exec(db, "BEGIN TRANSACTION;")
        do {
            for chunk in Array(ids).chunked(into: 500) {
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                // (table, id column) — derived is keyed by email_id.
                for (table, col) in [("emails", "id"), ("email_bodies", "id"), ("derived", "email_id")] {
                    let stmt = try prepare(db, "DELETE FROM \(table) WHERE \(col) IN (\(placeholders));")
                    defer { sqlite3_finalize(stmt) }
                    for (i, id) in chunk.enumerated() { bindText(stmt, Int32(i + 1), id.uuidString) }
                    guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
                }
            }
            try exec(db, "COMMIT;")
        } catch {
            try? exec(db, "ROLLBACK;")
            throw error
        }
    }

    func clearAll() throws {
        let db = try ensureDB()
        try exec(db, "DELETE FROM emails;")
        try exec(db, "DELETE FROM email_bodies;")
    }

    /// Fold the WAL back into the main db file. Keeps the on-disk footprint
    /// honest and bounds WAL growth after a large import.
    func checkpoint() throws {
        let db = try ensureDB()
        try exec(db, "PRAGMA wal_checkpoint(TRUNCATE);")
    }

    // MARK: - Row → RawEmail

    private func rawEmailFromRow(_ stmt: OpaquePointer?) -> MBOXParser.RawEmail? {
        guard let id = columnUUID(stmt, 0) else { return nil }
        let messageID = columnTextOptional(stmt, 1)
        let inReplyTo = columnTextOptional(stmt, 2)
        let references = columnTextOptional(stmt, 3)
        let date = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 4)))
        let plain = columnBlobString(stmt, 5) ?? ""
        let html = columnBlobString(stmt, 6) ?? ""
        let raw = columnBlobString(stmt, 7) ?? ""

        var headers: [String: String] = [:]
        if let hdata = columnBlobData(stmt, 8),
           let decoded = try? JSONDecoder().decode([String: String].self, from: hdata) {
            headers = decoded
        } else if let messageID { headers["Message-ID"] = messageID }

        return MBOXParser.RawEmail(
            id: id,
            headers: headers,
            rawSource: raw,
            messageType: "stored",
            attachments: [],
            timestamp: ISO8601DateFormatter().string(from: date),
            domains: [],
            plainBody: plain,
            htmlBody: html,
            mimeRoot: nil, mimeSummary: nil, mimeDiagnostics: [],
            threadID: messageID,
            inReplyTo: inReplyTo,
            references: references.map { $0.components(separatedBy: "\n") },
            tags: [], anomalies: []
        )
    }

    // MARK: - Date parsing (aligned with FTS shard-year)

    private static func parsedDate(from raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return MBOXParser.parseDate(raw)
    }

    // MARK: - SQLite helpers

    private func exec(_ db: OpaquePointer, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "sqlite3_exec rc=\(rc)"
            sqlite3_free(err)
            throw SQLiteStoreError.exec(msg)
        }
    }

    private func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteStoreError.prepare(lastError(db))
        }
        return stmt
    }

    private func scalarInt(_ db: OpaquePointer, _ sql: String) throws -> Int {
        let stmt = try prepare(db, sql)
        defer { sqlite3_finalize(stmt) }
        guard try stepRow(stmt, db) else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Step expecting rows: true = a row is available, false = DONE. Throws on
    /// any error (disk full, I/O, interrupt) instead of letting the caller's
    /// `while == SQLITE_ROW` loop silently mistake a failure for end-of-rows —
    /// which would return a partial result set as if it were complete.
    private func stepRow(_ stmt: OpaquePointer?, _ db: OpaquePointer) throws -> Bool {
        switch sqlite3_step(stmt) {
        case SQLITE_ROW:  return true
        case SQLITE_DONE: return false
        default:          throw SQLiteStoreError.step(lastError(db))
        }
    }

    private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, sqliteTransient)
    }
    private func bindTextOrNull(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value { sqlite3_bind_text(stmt, index, value, -1, sqliteTransient) }
        else { sqlite3_bind_null(stmt, index) }
    }
    private func bindBlob(_ stmt: OpaquePointer?, _ index: Int32, _ data: Data?) {
        guard let data, !data.isEmpty else { sqlite3_bind_null(stmt, index); return }
        data.withUnsafeBytes { raw in
            sqlite3_bind_blob(stmt, index, raw.baseAddress, Int32(data.count), sqliteTransient)
        }
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: c)
    }
    private func columnTextOptional(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }
    private func columnUUID(_ stmt: OpaquePointer?, _ index: Int32) -> UUID? {
        guard let c = sqlite3_column_text(stmt, index) else { return nil }
        return UUID(uuidString: String(cString: c))
    }
    private func columnBlobData(_ stmt: OpaquePointer?, _ index: Int32) -> Data? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let bytes = sqlite3_column_blob(stmt, index) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, index))
        guard count > 0 else { return nil }
        return Data(bytes: bytes, count: count)
    }
    private func columnBlobString(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        columnBlobData(stmt, index).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func lastError(_ db: OpaquePointer) -> String {
        guard let c = sqlite3_errmsg(db) else { return "unknown error" }
        return String(cString: c)
    }
}

enum SQLiteStoreError: LocalizedError {
    case open(String), exec(String), prepare(String), step(String)
    var errorDescription: String? {
        switch self {
        case .open(let m): return "SQLite open failed: \(m)"
        case .exec(let m): return "SQLite exec failed: \(m)"
        case .prepare(let m): return "SQLite prepare failed: \(m)"
        case .step(let m): return "SQLite step failed: \(m)"
        }
    }
}
