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
import CryptoKit
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
        // W3: the canonical store is read by background analysis/reconcile
        // jobs after device lock → background-readable class on iOS; new
        // files (emails.db + its -wal/-shm) inherit the directory's class.
        // macOS: 700 so no other local user can open the archive.
        ArtifactProtection.applyBackgroundReadable(to: directory)
        let url = directory.appendingPathComponent("emails.db")
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(
            url.path, &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil
        )
        guard rc == SQLITE_OK, let handle else {
            throw SQLiteStoreError.open("sqlite3_open_v2 rc=\(rc)")
        }
        // Owner-only on the DB file itself. SQLite creates -wal/-shm with the
        // database file's permissions, so setting emails.db before the first
        // write covers them too; the explicit calls handle files that already
        // existed from an earlier version.
        ArtifactProtection.applyBackgroundReadable(to: url)
        ArtifactProtection.applyBackgroundReadable(to: URL(fileURLWithPath: url.path + "-wal"))
        ArtifactProtection.applyBackgroundReadable(to: URL(fileURLWithPath: url.path + "-shm"))
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
        try exec(handle, "PRAGMA busy_timeout = 5000;")
        try migrateSchema(handle)
        self.db = handle
        return handle
    }

    // MARK: - Versioned schema migrations (§2)

    /// Explicit, transactional, restart-safe schema versioning via
    /// `PRAGMA user_version`:
    ///   v1 = the original direct-SQLite store (implicit schema of the first
    ///        v2-core-cutover builds)
    ///   v2 = full-fidelity + source identity + dedup policy + review state
    /// Each step runs inside one EXCLUSIVE transaction whose COMMIT also
    /// publishes the new user_version, so a crash mid-migration leaves the
    /// store fully at the previous version — never half-migrated, and a user
    /// DB is NEVER silently recreated. A store newer than this build refuses
    /// to open instead of guessing.
    static let currentSchemaVersion = 6

    private func migrateSchema(_ handle: OpaquePointer) throws {
        var v = try scalarInt(handle, "PRAGMA user_version;")
        if v > Self.currentSchemaVersion {
            throw SQLiteStoreError.schema(
                "store schema v\(v) is newer than this app supports (v\(Self.currentSchemaVersion)); refusing to open")
        }
        if v == 0 {
            // Either a brand-new database or a store created before schema
            // versioning existed (whose implicit schema is v1). Every v1 DDL
            // statement is IF NOT EXISTS, so running it unconditionally also
            // repairs a partially-created old store without touching data.
            try inExclusiveTransaction(handle) {
                try createSchemaV1(handle)
                try exec(handle, "PRAGMA user_version = 1;")
            }
            v = 1
        }
        if v == 1 {
            try inExclusiveTransaction(handle) {
                try migrateV1toV2(handle)
                try exec(handle, "PRAGMA user_version = 2;")
            }
            v = 2
        }
        if v == 2 {
            try inExclusiveTransaction(handle) {
                try migrateV2toV3(handle)
                try exec(handle, "PRAGMA user_version = 3;")
            }
            v = 3
        }
        if v == 3 {
            try inExclusiveTransaction(handle) {
                // §16: priority sort keyset support.
                try exec(handle, "CREATE INDEX IF NOT EXISTS idx_derived_priority ON derived(priority, email_id);")
                try exec(handle, "PRAGMA user_version = 4;")
            }
            v = 4
        }
        if v == 4 {
            try inExclusiveTransaction(handle) {
                // v5: fidelity-backfill work list. Rows persisted by pre-v2
                // builds carry message_type = '' (their structured metadata
                // was never stored); FidelityBackfillJob re-extracts it from
                // the raw MIME already in email_bodies. Partial index keeps
                // the "anything left?" probe O(1) at any archive size.
                try exec(handle, "CREATE INDEX IF NOT EXISTS idx_emails_fidelity_pending ON emails(id) WHERE message_type = '';")
                try exec(handle, "PRAGMA user_version = 5;")
            }
            v = 5
        }
        if v == 5 {
            try inExclusiveTransaction(handle) {
                // v6: attachment-content search. Extracted attachment text
                // (PDF/plain-text families) is indexed into a dedicated FTS5
                // table; the state registry is the extraction job's work-list
                // complement (an email row here = extraction attempted).
                try exec(handle, """
                    CREATE VIRTUAL TABLE IF NOT EXISTS attachment_search USING fts5(
                        email_id UNINDEXED,
                        filename,
                        content,
                        tokenize='porter unicode61 remove_diacritics 1'
                    );
                """)
                try exec(handle, """
                    CREATE TABLE IF NOT EXISTS attachment_text_state(
                        email_id   TEXT PRIMARY KEY,
                        indexed_at INTEGER NOT NULL DEFAULT 0,
                        text_count INTEGER NOT NULL DEFAULT 0
                    );
                """)
                try exec(handle, "PRAGMA user_version = 6;")
            }
            v = 6
        }
    }

    /// v2 → v3 (§21): forensic state moves from whole-in-memory JSON maps to
    /// indexed durable tables — evidence tags, examiner annotations, per-email
    /// hashes, source-file hashes, and the HMAC-chained audit log.
    private func migrateV2toV3(_ handle: OpaquePointer) throws {
        try exec(handle, """
            CREATE TABLE IF NOT EXISTS forensic_email_hashes(
                email_id   TEXT PRIMARY KEY,
                md5        TEXT NOT NULL DEFAULT '',
                sha1       TEXT NOT NULL DEFAULT '',
                sha256     TEXT NOT NULL DEFAULT '',
                byte_count INTEGER NOT NULL DEFAULT 0
            );
        """)
        try exec(handle, """
            CREATE TABLE IF NOT EXISTS forensic_evidence_tags(
                email_id  TEXT PRIMARY KEY,
                tag       TEXT NOT NULL,
                tagged_at INTEGER NOT NULL DEFAULT 0
            );
        """)
        try exec(handle, "CREATE INDEX IF NOT EXISTS idx_forensic_tag ON forensic_evidence_tags(tag, email_id);")
        try exec(handle, """
            CREATE TABLE IF NOT EXISTS forensic_annotations(
                email_id   TEXT PRIMARY KEY,
                note       TEXT NOT NULL DEFAULT '',
                examiner   TEXT NOT NULL DEFAULT '',
                created_at INTEGER NOT NULL DEFAULT 0
            );
        """)
        try exec(handle, """
            CREATE TABLE IF NOT EXISTS forensic_source_hashes(
                id          INTEGER PRIMARY KEY,
                filename    TEXT NOT NULL DEFAULT '',
                file_size   INTEGER NOT NULL DEFAULT 0,
                md5         TEXT NOT NULL DEFAULT '',
                sha1        TEXT NOT NULL DEFAULT '',
                sha256      TEXT NOT NULL,
                imported_at INTEGER NOT NULL DEFAULT 0
            );
        """)
        try exec(handle, "CREATE UNIQUE INDEX IF NOT EXISTS idx_forensic_source_sha ON forensic_source_hashes(sha256);")
        try exec(handle, """
            CREATE TABLE IF NOT EXISTS forensic_audit_log(
                seq       INTEGER PRIMARY KEY,
                entry_id  TEXT NOT NULL,
                ts        REAL NOT NULL,
                action    TEXT NOT NULL,
                detail    TEXT NOT NULL,
                examiner  TEXT NOT NULL,
                prev_hash TEXT NOT NULL,
                entry_hash TEXT NOT NULL
            );
        """)
    }

    private func inExclusiveTransaction(_ handle: OpaquePointer, _ body: () throws -> Void) throws {
        try exec(handle, "BEGIN EXCLUSIVE TRANSACTION;")
        do { try body(); try exec(handle, "COMMIT;") }
        catch { try? exec(handle, "ROLLBACK;"); throw error }
    }

    /// The original (pre-versioning) schema, byte-for-byte what the first
    /// v2-core-cutover builds created. Only ever executed for stores that are
    /// genuinely empty; existing v1 stores are detected and left untouched.
    private func createSchemaV1(_ handle: OpaquePointer) throws {
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
        // v1 dedup index: unique on Message-ID where present. Replaced in v2
        // by the policy-driven dedup_key index.
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
        // Persistent exact-dedup findings (Phase 10): rows dropped at import time
        // because their Message-ID already existed.
        try exec(handle, """
            CREATE TABLE IF NOT EXISTS duplicates(
                id           INTEGER PRIMARY KEY,
                duplicate_id TEXT,
                message_id   TEXT,
                source_hash  TEXT,
                created_at   INTEGER NOT NULL DEFAULT 0
            );
        """)
        // Part L: persisted thread relationships. One stable thread key per
        // email, derived from Message-ID / In-Reply-To / References (subject
        // fallback at lower confidence). Indexed so threadKey → members is an
        // O(log N) seek, never a runtime archive-wide grouping.
        try exec(handle, """
            CREATE TABLE IF NOT EXISTS thread_keys(
                email_id   TEXT PRIMARY KEY,
                thread_key TEXT NOT NULL,
                confidence INTEGER NOT NULL DEFAULT 0,
                updated_at INTEGER NOT NULL DEFAULT 0
            );
        """)
        try exec(handle, "CREATE INDEX IF NOT EXISTS idx_thread_keys_key ON thread_keys(thread_key);")
        // Part K: predictive-coding (TAR) records — compact features + human
        // label + model score per email, versioned. Never whole messages.
        try exec(handle, """
            CREATE TABLE IF NOT EXISTS predictive_records(
                email_id        TEXT PRIMARY KEY,
                label           INTEGER,
                score           REAL,
                features        TEXT,
                model_version   INTEGER NOT NULL DEFAULT 0,
                feature_version INTEGER NOT NULL DEFAULT 0,
                corpus_revision INTEGER NOT NULL DEFAULT 0,
                updated_at      INTEGER NOT NULL DEFAULT 0
            );
        """)
        try exec(handle, "CREATE INDEX IF NOT EXISTS idx_predictive_score ON predictive_records(score);")
        // Part M: persisted near-duplicate findings — one row per group member
        // (representative flagged), with similarity + algorithm version, so the
        // review UI pages persisted findings instead of recomputing.
        try exec(handle, """
            CREATE TABLE IF NOT EXISTS near_dup_findings(
                id                INTEGER PRIMARY KEY,
                group_key         TEXT NOT NULL,
                email_id          TEXT NOT NULL,
                is_representative INTEGER NOT NULL DEFAULT 0,
                similarity        REAL NOT NULL DEFAULT 0,
                algo_version      INTEGER NOT NULL DEFAULT 0,
                corpus_revision   INTEGER NOT NULL DEFAULT 0,
                created_at        INTEGER NOT NULL DEFAULT 0
            );
        """)
        try exec(handle, "CREATE INDEX IF NOT EXISTS idx_near_dup_group ON near_dup_findings(group_key);")
    }

    /// v1 → v2: full RawEmail fidelity (message type, attachments metadata,
    /// tags, domains, participants), first-class source identity
    /// (§3.1/§3.2), policy-driven dedup (§4), per-email content revisions
    /// (§22), review state (§19) and sort indexes (§16).
    private func migrateV1toV2(_ handle: OpaquePointer) throws {
        try exec(handle, "ALTER TABLE emails ADD COLUMN message_type TEXT NOT NULL DEFAULT '';")
        try exec(handle, "ALTER TABLE emails ADD COLUMN dedup_key TEXT;")
        try exec(handle, "ALTER TABLE emails ADD COLUMN source_id INTEGER;")
        try exec(handle, "ALTER TABLE emails ADD COLUMN source_ordinal INTEGER;")
        try exec(handle, "ALTER TABLE emails ADD COLUMN attachment_count INTEGER NOT NULL DEFAULT 0;")
        try exec(handle, "ALTER TABLE emails ADD COLUMN content_revision INTEGER NOT NULL DEFAULT 1;")
        try exec(handle, "ALTER TABLE emails ADD COLUMN imported_at INTEGER NOT NULL DEFAULT 0;")
        // Rows that exist under v1 were deduped by raw Message-ID; carrying
        // that value into dedup_key preserves their semantics exactly (and is
        // guaranteed collision-free because v1 enforced uniqueness on it).
        try exec(handle, "UPDATE emails SET dedup_key = message_id WHERE message_id IS NOT NULL;")
        try exec(handle, "UPDATE emails SET attachment_count = has_attach WHERE has_attach = 1;")
        // message_id becomes a lookup index; uniqueness moves to dedup_key so
        // `preserveAll` imports can legitimately store repeated Message-IDs.
        try exec(handle, "DROP INDEX IF EXISTS idx_emails_msgid;")
        try exec(handle, "CREATE INDEX IF NOT EXISTS idx_emails_msgid_lookup ON emails(message_id) WHERE message_id IS NOT NULL;")
        try exec(handle, "CREATE UNIQUE INDEX IF NOT EXISTS idx_emails_dedup_key ON emails(dedup_key) WHERE dedup_key IS NOT NULL;")
        // Stable source occurrence: crash-resume / repeated parses of the same
        // source re-hit this constraint instead of duplicating evidence.
        try exec(handle, """
            CREATE UNIQUE INDEX IF NOT EXISTS idx_emails_source_occurrence
            ON emails(source_id, source_ordinal)
            WHERE source_id IS NOT NULL AND source_ordinal IS NOT NULL;
        """)
        // §16 DB-native sort keysets.
        try exec(handle, "CREATE INDEX IF NOT EXISTS idx_emails_subject_id ON emails(subject COLLATE NOCASE, id);")
        try exec(handle, "CREATE INDEX IF NOT EXISTS idx_emails_size_id ON emails(size_bytes, id);")
        // §3.1 first-class sources.
        try exec(handle, """
            CREATE TABLE IF NOT EXISTS sources(
                source_id      INTEGER PRIMARY KEY,
                sha256         TEXT NOT NULL,
                filename       TEXT NOT NULL DEFAULT '',
                byte_size      INTEGER NOT NULL DEFAULT 0,
                parser         TEXT NOT NULL DEFAULT '',
                parser_version INTEGER NOT NULL DEFAULT 0,
                account_id     TEXT,
                imported_at    INTEGER NOT NULL DEFAULT 0,
                source_kind    TEXT NOT NULL DEFAULT ''
            );
        """)
        try exec(handle, "CREATE UNIQUE INDEX IF NOT EXISTS idx_sources_sha ON sources(sha256);")
        // §3.5 bounded attachment metadata (bytes stay reconstructable from raw MIME).
        try exec(handle, """
            CREATE TABLE IF NOT EXISTS attachments(
                attachment_id INTEGER PRIMARY KEY,
                email_id      TEXT NOT NULL,
                position      INTEGER NOT NULL DEFAULT 0,
                filename      TEXT NOT NULL DEFAULT '',
                mime_type     TEXT NOT NULL DEFAULT '',
                size_bytes    INTEGER NOT NULL DEFAULT 0,
                content_id    TEXT,
                is_inline     INTEGER NOT NULL DEFAULT 0,
                content_hash  TEXT
            );
        """)
        try exec(handle, "CREATE INDEX IF NOT EXISTS idx_attachments_email ON attachments(email_id);")
        // §3.4 normalized participants — the query basis for sender/recipient
        // filters and contact analytics, instead of re-parsing To:/Cc: strings.
        try exec(handle, """
            CREATE TABLE IF NOT EXISTS email_participants(
                email_id           TEXT NOT NULL,
                role               TEXT NOT NULL,
                address            TEXT NOT NULL,
                display_name       TEXT,
                normalized_address TEXT NOT NULL
            );
        """)
        try exec(handle, "CREATE INDEX IF NOT EXISTS idx_participants_lookup ON email_participants(role, normalized_address, email_id);")
        try exec(handle, "CREATE INDEX IF NOT EXISTS idx_participants_email ON email_participants(email_id);")
        // §3.6 queryable multi-value state.
        try exec(handle, """
            CREATE TABLE IF NOT EXISTS email_tags(
                email_id TEXT NOT NULL,
                tag      TEXT NOT NULL,
                PRIMARY KEY(email_id, tag)
            ) WITHOUT ROWID;
        """)
        try exec(handle, "CREATE INDEX IF NOT EXISTS idx_email_tags_tag ON email_tags(tag, email_id);")
        try exec(handle, """
            CREATE TABLE IF NOT EXISTS email_domains(
                email_id TEXT NOT NULL,
                domain   TEXT NOT NULL,
                PRIMARY KEY(email_id, domain)
            ) WITHOUT ROWID;
        """)
        try exec(handle, "CREATE INDEX IF NOT EXISTS idx_email_domains_domain ON email_domains(domain, email_id);")
        // §19 review state: pinned/read/archived/trashed + user tags +
        // annotations, indexed and page-addressable. Trash is a soft state —
        // never silent evidence destruction.
        try exec(handle, """
            CREATE TABLE IF NOT EXISTS email_review_state(
                email_id   TEXT PRIMARY KEY,
                pinned     INTEGER NOT NULL DEFAULT 0,
                is_read    INTEGER NOT NULL DEFAULT 0,
                archived   INTEGER NOT NULL DEFAULT 0,
                trashed    INTEGER NOT NULL DEFAULT 0,
                updated_at INTEGER NOT NULL DEFAULT 0
            );
        """)
        try exec(handle, "CREATE INDEX IF NOT EXISTS idx_review_trashed ON email_review_state(trashed) WHERE trashed = 1;")
        try exec(handle, "CREATE INDEX IF NOT EXISTS idx_review_pinned ON email_review_state(pinned) WHERE pinned = 1;")
        try exec(handle, """
            CREATE TABLE IF NOT EXISTS email_user_tags(
                email_id TEXT NOT NULL,
                tag      TEXT NOT NULL,
                PRIMARY KEY(email_id, tag)
            ) WITHOUT ROWID;
        """)
        try exec(handle, "CREATE INDEX IF NOT EXISTS idx_user_tags_tag ON email_user_tags(tag, email_id);")
        try exec(handle, """
            CREATE TABLE IF NOT EXISTS email_annotations(
                email_id   TEXT PRIMARY KEY,
                note       TEXT NOT NULL DEFAULT '',
                updated_at INTEGER NOT NULL DEFAULT 0
            );
        """)
    }

    /// `PRAGMA integrity_check` — "ok" means healthy. Exposed for the
    /// activation gate and diagnostics (§49.1).
    func integrityCheck() throws -> String {
        let db = try ensureDB()
        let stmt = try prepare(db, "PRAGMA integrity_check;")
        defer { sqlite3_finalize(stmt) }
        guard try stepRow(stmt, db) else { return "no result" }
        return columnText(stmt, 0)
    }

    /// Current `PRAGMA user_version` — exposed for tests/diagnostics.
    func schemaVersion() throws -> Int {
        let db = try ensureDB()
        return try scalarInt(db, "PRAGMA user_version;")
    }

    // MARK: - Duplicate findings (Phase 10)

    struct StoredDuplicate: Sendable, Equatable {
        let duplicateID: String
        let messageID: String?
        let sourceHash: String?
    }

    func duplicatesCount() throws -> Int {
        let db = try ensureDB()
        return try scalarInt(db, "SELECT COUNT(*) FROM duplicates;")
    }

    func recentDuplicates(limit: Int) throws -> [StoredDuplicate] {
        let db = try ensureDB()
        let stmt = try prepare(db, "SELECT duplicate_id, message_id, source_hash FROM duplicates ORDER BY id DESC LIMIT ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        var out: [StoredDuplicate] = []
        while try stepRow(stmt, db) {
            out.append(StoredDuplicate(duplicateID: columnText(stmt, 0),
                                       messageID: columnTextOptional(stmt, 1),
                                       sourceHash: columnTextOptional(stmt, 2)))
        }
        return out
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

    /// Reconcile the revision with the store's cardinality: if the row count
    /// changed since it was last observed (an import/delete path that didn't
    /// bump explicitly), bump once and remember the new count. Two O(1)
    /// aggregates — safe to call on every derived-state read. Content edits
    /// that keep the count constant (redaction) must still call
    /// `bumpCorpusRevision()` explicitly.
    @discardableResult
    func reconcileCorpusRevisionWithCount() throws -> Int {
        let db = try ensureDB()
        let total = try scalarInt(db, "SELECT COUNT(*) FROM emails;")
        let observed = try scalarInt(db, "SELECT value FROM meta WHERE key = 'corpus_observed_count';")
        guard total != observed else { return try corpusRevision() }
        try exec(db, """
            INSERT INTO meta(key, value) VALUES ('corpus_observed_count', \(total))
            ON CONFLICT(key) DO UPDATE SET value = \(total);
        """)
        return try bumpCorpusRevision()
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
    /// deleted rows never appear. `minAnalysisVersion` (Part I/K) marks records
    /// produced by an older analysis/model version as stale, so bumping the
    /// version constant triggers an incremental recompute.
    func derivedStaleIDs(below revision: Int, minAnalysisVersion: Int = 0, limit: Int) throws -> [EmailID] {
        let db = try ensureDB()
        let stmt = try prepare(db, """
            SELECT e.id FROM emails e
            LEFT JOIN derived d ON d.email_id = e.id
            WHERE d.email_id IS NULL OR d.corpus_revision < ? OR d.analysis_version < ?
            LIMIT ?;
        """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(revision))
        sqlite3_bind_int64(stmt, 2, Int64(minAnalysisVersion))
        sqlite3_bind_int(stmt, 3, Int32(limit))
        var out: [EmailID] = []
        while try stepRow(stmt, db) { if let id = columnUUID(stmt, 0) { out.append(id) } }
        return out
    }

    /// Partial upsert (Part J): set ONLY the topic column for the given emails,
    /// preserving every other derived field a different producer persisted.
    func derivedSetTopics(_ topics: [EmailID: String]) throws {
        guard !topics.isEmpty else { return }
        let db = try ensureDB()
        let now = Int(Date().timeIntervalSince1970)
        let stmt = try prepare(db, """
            INSERT INTO derived(email_id, topic, updated_at) VALUES (?,?,?)
            ON CONFLICT(email_id) DO UPDATE SET topic = excluded.topic, updated_at = excluded.updated_at;
        """)
        defer { sqlite3_finalize(stmt) }
        try exec(db, "BEGIN TRANSACTION;")
        do {
            for (id, topic) in topics {
                sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
                bindText(stmt, 1, id.uuidString)
                bindText(stmt, 2, topic)
                sqlite3_bind_int64(stmt, 3, Int64(now))
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
            }
            try exec(db, "COMMIT;")
        } catch { try? exec(db, "ROLLBACK;"); throw error }
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

    // MARK: - Thread keys (Part L)

    struct ThreadKeyRow: Sendable, Equatable {
        let emailID: EmailID
        let threadKey: String
        let confidence: Int
    }

    /// Header fields needed to derive a thread key — no bodies hydrated.
    struct ThreadKeySource: Sendable {
        let id: EmailID
        let messageID: String?
        let inReplyTo: String?
        let references: String?
        let subject: String
    }

    /// One bounded page of emails that don't have a thread key yet — the work
    /// list for the thread-key backfill job.
    func threadKeyMissingPage(limit: Int) throws -> [ThreadKeySource] {
        let db = try ensureDB()
        let stmt = try prepare(db, """
            SELECT e.id, e.message_id, e.in_reply_to, e.references_ids, e.subject
            FROM emails e LEFT JOIN thread_keys t ON t.email_id = e.id
            WHERE t.email_id IS NULL LIMIT ?;
        """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        var out: [ThreadKeySource] = []
        while try stepRow(stmt, db) {
            guard let id = columnUUID(stmt, 0) else { continue }
            out.append(ThreadKeySource(
                id: id,
                messageID: columnTextOptional(stmt, 1),
                inReplyTo: columnTextOptional(stmt, 2),
                references: columnTextOptional(stmt, 3),
                subject: columnText(stmt, 4)
            ))
        }
        return out
    }

    func threadKeysUpsert(_ rows: [ThreadKeyRow]) throws {
        guard !rows.isEmpty else { return }
        let db = try ensureDB()
        let now = Int64(Date().timeIntervalSince1970)
        let stmt = try prepare(db, """
            INSERT INTO thread_keys(email_id, thread_key, confidence, updated_at) VALUES (?,?,?,?)
            ON CONFLICT(email_id) DO UPDATE SET
                thread_key = excluded.thread_key, confidence = excluded.confidence, updated_at = excluded.updated_at;
        """)
        defer { sqlite3_finalize(stmt) }
        try exec(db, "BEGIN TRANSACTION;")
        do {
            for row in rows {
                sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
                bindText(stmt, 1, row.emailID.uuidString)
                bindText(stmt, 2, row.threadKey)
                sqlite3_bind_int64(stmt, 3, Int64(row.confidence))
                sqlite3_bind_int64(stmt, 4, now)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
            }
            try exec(db, "COMMIT;")
        } catch { try? exec(db, "ROLLBACK;"); throw error }
    }

    func threadKey(for id: EmailID) throws -> ThreadKeyRow? {
        let db = try ensureDB()
        let stmt = try prepare(db, "SELECT email_id, thread_key, confidence FROM thread_keys WHERE email_id = ?;")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, id.uuidString)
        guard try stepRow(stmt, db), let rid = columnUUID(stmt, 0) else { return nil }
        return ThreadKeyRow(emailID: rid, threadKey: columnText(stmt, 1), confidence: Int(sqlite3_column_int64(stmt, 2)))
    }

    /// Members of a thread, newest first, paginated — the indexed query path
    /// that replaces archive-wide runtime grouping.
    func threadEmailIDs(threadKey: String, limit: Int, offset: Int) throws -> [EmailID] {
        let db = try ensureDB()
        let stmt = try prepare(db, """
            SELECT t.email_id FROM thread_keys t
            JOIN emails e ON e.id = t.email_id
            WHERE t.thread_key = ? ORDER BY e.date DESC, e.id DESC LIMIT ? OFFSET ?;
        """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, threadKey)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        sqlite3_bind_int(stmt, 3, Int32(offset))
        var out: [EmailID] = []
        while try stepRow(stmt, db) { if let id = columnUUID(stmt, 0) { out.append(id) } }
        return out
    }

    func threadKeyCount() throws -> Int {
        let db = try ensureDB()
        return try scalarInt(db, "SELECT COUNT(*) FROM thread_keys;")
    }

    // MARK: - Predictive coding records (Part K)

    struct PredictiveRecordRow: Sendable, Equatable {
        let emailID: EmailID
        var label: Int? = nil          // 1 relevant / 0 irrelevant / nil unlabeled
        var score: Double? = nil
        var features: String? = nil    // compact JSON tf-idf features (labeled rows)
        var modelVersion: Int = 0
        var featureVersion: Int = 0
        var corpusRevision: Int = 0
        var updatedAt: Int = 0
    }

    /// Upsert human labels (+ compact features). Preserves any model score a
    /// scoring job already persisted for the row.
    func predictiveUpsertLabels(_ rows: [PredictiveRecordRow]) throws {
        guard !rows.isEmpty else { return }
        let db = try ensureDB()
        let now = Int64(Date().timeIntervalSince1970)
        let stmt = try prepare(db, """
            INSERT INTO predictive_records(email_id, label, features, model_version, feature_version, corpus_revision, updated_at)
            VALUES (?,?,?,?,?,?,?)
            ON CONFLICT(email_id) DO UPDATE SET
                label = excluded.label, features = excluded.features,
                feature_version = excluded.feature_version, corpus_revision = excluded.corpus_revision,
                updated_at = excluded.updated_at;
        """)
        defer { sqlite3_finalize(stmt) }
        try exec(db, "BEGIN TRANSACTION;")
        do {
            for row in rows {
                sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
                bindText(stmt, 1, row.emailID.uuidString)
                if let l = row.label { sqlite3_bind_int64(stmt, 2, Int64(l)) } else { sqlite3_bind_null(stmt, 2) }
                bindTextOrNull(stmt, 3, row.features)
                sqlite3_bind_int64(stmt, 4, Int64(row.modelVersion))
                sqlite3_bind_int64(stmt, 5, Int64(row.featureVersion))
                sqlite3_bind_int64(stmt, 6, Int64(row.corpusRevision))
                sqlite3_bind_int64(stmt, 7, now)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
            }
            try exec(db, "COMMIT;")
        } catch { try? exec(db, "ROLLBACK;"); throw error }
    }

    /// Upsert model scores from a (bounded) scoring pass. Preserves any human
    /// label / features already persisted for the row.
    func predictiveUpsertScores(_ scores: [EmailID: Double], modelVersion: Int, featureVersion: Int, corpusRevision: Int) throws {
        guard !scores.isEmpty else { return }
        let db = try ensureDB()
        let now = Int64(Date().timeIntervalSince1970)
        let stmt = try prepare(db, """
            INSERT INTO predictive_records(email_id, score, model_version, feature_version, corpus_revision, updated_at)
            VALUES (?,?,?,?,?,?)
            ON CONFLICT(email_id) DO UPDATE SET
                score = excluded.score, model_version = excluded.model_version,
                feature_version = excluded.feature_version, corpus_revision = excluded.corpus_revision,
                updated_at = excluded.updated_at;
        """)
        defer { sqlite3_finalize(stmt) }
        try exec(db, "BEGIN TRANSACTION;")
        do {
            for (id, score) in scores {
                sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
                bindText(stmt, 1, id.uuidString)
                sqlite3_bind_double(stmt, 2, score)
                sqlite3_bind_int64(stmt, 3, Int64(modelVersion))
                sqlite3_bind_int64(stmt, 4, Int64(featureVersion))
                sqlite3_bind_int64(stmt, 5, Int64(corpusRevision))
                sqlite3_bind_int64(stmt, 6, now)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
            }
            try exec(db, "COMMIT;")
        } catch { try? exec(db, "ROLLBACK;"); throw error }
    }

    private func predictiveRow(_ stmt: OpaquePointer?) -> PredictiveRecordRow? {
        guard let id = columnUUID(stmt, 0) else { return nil }
        return PredictiveRecordRow(
            emailID: id,
            label: sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 1)),
            score: sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 2),
            features: columnTextOptional(stmt, 3),
            modelVersion: Int(sqlite3_column_int64(stmt, 4)),
            featureVersion: Int(sqlite3_column_int64(stmt, 5)),
            corpusRevision: Int(sqlite3_column_int64(stmt, 6)),
            updatedAt: Int(sqlite3_column_int64(stmt, 7))
        )
    }

    private static let predictiveColumns =
        "email_id, label, score, features, model_version, feature_version, corpus_revision, updated_at"

    func predictiveFetch(ids: [EmailID]) throws -> [EmailID: PredictiveRecordRow] {
        guard !ids.isEmpty else { return [:] }
        let db = try ensureDB()
        var out: [EmailID: PredictiveRecordRow] = [:]
        for chunk in ids.chunked(into: 500) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let stmt = try prepare(db, "SELECT \(Self.predictiveColumns) FROM predictive_records WHERE email_id IN (\(placeholders));")
            defer { sqlite3_finalize(stmt) }
            for (i, id) in chunk.enumerated() { bindText(stmt, Int32(i + 1), id.uuidString) }
            while try stepRow(stmt, db) { if let row = predictiveRow(stmt) { out[row.emailID] = row } }
        }
        return out
    }

    /// Scored records paged by score (highest first) — the view's read path.
    func predictivePage(limit: Int, offset: Int) throws -> [PredictiveRecordRow] {
        let db = try ensureDB()
        let stmt = try prepare(db, """
            SELECT \(Self.predictiveColumns) FROM predictive_records
            WHERE score IS NOT NULL ORDER BY score DESC, email_id ASC LIMIT ? OFFSET ?;
        """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        sqlite3_bind_int(stmt, 2, Int32(offset))
        var out: [PredictiveRecordRow] = []
        while try stepRow(stmt, db) { if let row = predictiveRow(stmt) { out.append(row) } }
        return out
    }

    /// All labeled training rows — bounded by the number of human labels.
    func predictiveLabeled() throws -> [PredictiveRecordRow] {
        let db = try ensureDB()
        let stmt = try prepare(db, "SELECT \(Self.predictiveColumns) FROM predictive_records WHERE label IS NOT NULL;")
        defer { sqlite3_finalize(stmt) }
        var out: [PredictiveRecordRow] = []
        while try stepRow(stmt, db) { if let row = predictiveRow(stmt) { out.append(row) } }
        return out
    }

    func predictiveCount() throws -> Int {
        let db = try ensureDB()
        return try scalarInt(db, "SELECT COUNT(*) FROM predictive_records;")
    }

    // MARK: - Near-duplicate findings (Part M)

    struct NearDupMemberRow: Sendable, Equatable {
        let groupKey: String
        let emailID: EmailID
        let isRepresentative: Bool
        let similarity: Double
    }

    /// Replace the persisted near-duplicate findings wholesale (one analysis
    /// run = one findings set), stamping algorithm version + corpus revision.
    func nearDuplicatesReplace(_ rows: [NearDupMemberRow], algoVersion: Int, corpusRevision: Int) throws {
        let db = try ensureDB()
        let now = Int64(Date().timeIntervalSince1970)
        try exec(db, "BEGIN TRANSACTION;")
        do {
            try exec(db, "DELETE FROM near_dup_findings;")
            let stmt = try prepare(db, """
                INSERT INTO near_dup_findings(group_key, email_id, is_representative, similarity, algo_version, corpus_revision, created_at)
                VALUES (?,?,?,?,?,?,?);
            """)
            defer { sqlite3_finalize(stmt) }
            for row in rows {
                sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
                bindText(stmt, 1, row.groupKey)
                bindText(stmt, 2, row.emailID.uuidString)
                sqlite3_bind_int(stmt, 3, row.isRepresentative ? 1 : 0)
                sqlite3_bind_double(stmt, 4, row.similarity)
                sqlite3_bind_int64(stmt, 5, Int64(algoVersion))
                sqlite3_bind_int64(stmt, 6, Int64(corpusRevision))
                sqlite3_bind_int64(stmt, 7, now)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
            }
            try exec(db, "COMMIT;")
        } catch { try? exec(db, "ROLLBACK;"); throw error }
    }

    /// One page of group keys, largest groups first — the review UI pages these.
    func nearDuplicateGroupKeysPage(limit: Int, offset: Int) throws -> [String] {
        let db = try ensureDB()
        let stmt = try prepare(db, """
            SELECT group_key FROM near_dup_findings
            GROUP BY group_key ORDER BY COUNT(*) DESC, group_key ASC LIMIT ? OFFSET ?;
        """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        sqlite3_bind_int(stmt, 2, Int32(offset))
        var out: [String] = []
        while try stepRow(stmt, db) { out.append(columnText(stmt, 0)) }
        return out
    }

    func nearDuplicateMembers(groupKeys: [String]) throws -> [NearDupMemberRow] {
        guard !groupKeys.isEmpty else { return [] }
        let db = try ensureDB()
        var out: [NearDupMemberRow] = []
        for chunk in groupKeys.chunked(into: 500) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let stmt = try prepare(db, """
                SELECT group_key, email_id, is_representative, similarity
                FROM near_dup_findings WHERE group_key IN (\(placeholders));
            """)
            defer { sqlite3_finalize(stmt) }
            for (i, key) in chunk.enumerated() { bindText(stmt, Int32(i + 1), key) }
            while try stepRow(stmt, db) {
                guard let id = columnUUID(stmt, 1) else { continue }
                out.append(NearDupMemberRow(
                    groupKey: columnText(stmt, 0),
                    emailID: id,
                    isRepresentative: sqlite3_column_int(stmt, 2) != 0,
                    similarity: sqlite3_column_double(stmt, 3)
                ))
            }
        }
        return out
    }

    func nearDuplicateGroupCount() throws -> Int {
        let db = try ensureDB()
        return try scalarInt(db, "SELECT COUNT(DISTINCT group_key) FROM near_dup_findings;")
    }

    /// Version/revision the persisted findings were produced at (0/0 = none).
    func nearDuplicateMeta() throws -> (algoVersion: Int, corpusRevision: Int) {
        let db = try ensureDB()
        let stmt = try prepare(db, "SELECT MAX(algo_version), MAX(corpus_revision) FROM near_dup_findings;")
        defer { sqlite3_finalize(stmt) }
        guard try stepRow(stmt, db) else { return (0, 0) }
        let algo = sqlite3_column_type(stmt, 0) == SQLITE_NULL ? 0 : Int(sqlite3_column_int64(stmt, 0))
        let rev = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? 0 : Int(sqlite3_column_int64(stmt, 1))
        return (algo, rev)
    }

    // MARK: - Sources (§3.1)

    struct SourceDescriptor: Sendable {
        let sha256: String
        var filename: String = ""
        var byteSize: Int = 0
        var parser: String = ""
        var parserVersion: Int = 0
        var accountID: String? = nil
        var sourceKind: String = ""
    }

    /// Register (or re-touch) an import source, keyed by content SHA-256 —
    /// two files both named `Inbox.mbox` stay distinguishable (§21.2).
    /// Returns the stable source_id.
    @discardableResult
    func registerSource(_ s: SourceDescriptor) throws -> Int64 {
        let db = try ensureDB()
        let upsert = try prepare(db, """
            INSERT INTO sources(sha256, filename, byte_size, parser, parser_version, account_id, imported_at, source_kind)
            VALUES (?,?,?,?,?,?,?,?)
            ON CONFLICT(sha256) DO UPDATE SET imported_at = excluded.imported_at;
        """)
        defer { sqlite3_finalize(upsert) }
        bindText(upsert, 1, s.sha256)
        bindText(upsert, 2, s.filename)
        sqlite3_bind_int64(upsert, 3, Int64(s.byteSize))
        bindText(upsert, 4, s.parser)
        sqlite3_bind_int64(upsert, 5, Int64(s.parserVersion))
        bindTextOrNull(upsert, 6, s.accountID)
        sqlite3_bind_int64(upsert, 7, Int64(Date().timeIntervalSince1970))
        bindText(upsert, 8, s.sourceKind)
        guard sqlite3_step(upsert) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
        let lookup = try prepare(db, "SELECT source_id FROM sources WHERE sha256 = ?;")
        defer { sqlite3_finalize(lookup) }
        bindText(lookup, 1, s.sha256)
        guard try stepRow(lookup, db) else { throw SQLiteStoreError.step("source row vanished after upsert") }
        return sqlite3_column_int64(lookup, 0)
    }

    struct StoredSource: Sendable, Equatable {
        let sourceID: Int64
        let sha256: String
        let filename: String
        let byteSize: Int
        let parser: String
        let importedAt: Date
    }

    func sources() throws -> [StoredSource] {
        let db = try ensureDB()
        let stmt = try prepare(db, "SELECT source_id, sha256, filename, byte_size, parser, imported_at FROM sources ORDER BY imported_at DESC;")
        defer { sqlite3_finalize(stmt) }
        var out: [StoredSource] = []
        while try stepRow(stmt, db) {
            out.append(StoredSource(
                sourceID: sqlite3_column_int64(stmt, 0),
                sha256: columnText(stmt, 1),
                filename: columnText(stmt, 2),
                byteSize: Int(sqlite3_column_int64(stmt, 3)),
                parser: columnText(stmt, 4),
                importedAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 5)))
            ))
        }
        return out
    }

    // MARK: - Insertion

    /// Protocol witness — legacy signature, Message-ID dedup (v1 semantics).
    func insertBatch(
        _ emails: [MBOXParser.RawEmail],
        sourceFileHash: String?,
        accountID: String?,
        batchSize: Int,
        progress: ((Int, Int) -> Void)?
    ) throws {
        _ = try insertBatch(
            emails, sourceFileHash: sourceFileHash, accountID: accountID,
            sourceID: nil, firstOrdinal: nil, dedupPolicy: .messageID,
            batchSize: batchSize, progress: progress)
    }

    /// Full-fidelity, policy-driven insert (§3/§4/§5.3).
    ///
    /// When `sourceID`/`firstOrdinal` are provided, each email is stamped with
    /// its stable source occurrence `(source_id, firstOrdinal + i)`; a re-run
    /// over the same source (crash resume, repeated parse) hits the occurrence
    /// uniqueness and is reported in `existingSourceOccurrenceIDs` rather than
    /// duplicating evidence — even under `.preserveAll`.
    @discardableResult
    func insertBatch(
        _ emails: [MBOXParser.RawEmail],
        sourceFileHash: String?,
        accountID: String?,
        sourceID: Int64?,
        firstOrdinal: Int?,
        dedupPolicy: DedupPolicy,
        batchSize: Int,
        progress: ((Int, Int) -> Void)?
    ) throws -> BatchInsertResult {
        let db = try ensureDB()
        let total = emails.count
        var processed = 0
        var result = BatchInsertResult(attempted: total)

        let insertEmail = try prepare(db, """
            INSERT OR IGNORE INTO emails(
                id, message_id, subject, from_addr, to_addr, cc_addr, bcc_addr,
                date, body_preview, has_attach, size_bytes, in_reply_to,
                references_ids, account_id, source_hash,
                message_type, dedup_key, source_id, source_ordinal,
                attachment_count, content_revision, imported_at
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,1,?);
        """)
        let insertBody = try prepare(db, """
            INSERT OR IGNORE INTO email_bodies(id, plain, html, raw, headers_json)
            VALUES (?,?,?,?,?);
        """)
        let insertDup = try prepare(db, """
            INSERT INTO duplicates(duplicate_id, message_id, source_hash, created_at)
            VALUES (?,?,?,?);
        """)
        let insertAttachment = try prepare(db, """
            INSERT INTO attachments(email_id, position, filename, mime_type, size_bytes, content_id, is_inline)
            VALUES (?,?,?,?,?,?,?);
        """)
        let insertParticipant = try prepare(db, """
            INSERT INTO email_participants(email_id, role, address, display_name, normalized_address)
            VALUES (?,?,?,?,?);
        """)
        let insertTag = try prepare(db, "INSERT OR IGNORE INTO email_tags(email_id, tag) VALUES (?,?);")
        let insertDomain = try prepare(db, "INSERT OR IGNORE INTO email_domains(email_id, domain) VALUES (?,?);")
        let occurrenceExists = try prepare(db, "SELECT 1 FROM emails WHERE source_id = ? AND source_ordinal = ?;")
        defer {
            sqlite3_finalize(insertEmail); sqlite3_finalize(insertBody); sqlite3_finalize(insertDup)
            sqlite3_finalize(insertAttachment); sqlite3_finalize(insertParticipant)
            sqlite3_finalize(insertTag); sqlite3_finalize(insertDomain); sqlite3_finalize(occurrenceExists)
        }
        let now = Int64(Date().timeIntervalSince1970)

        var offset = 0
        for chunk in emails.chunked(into: max(1, batchSize)) {
            try exec(db, "BEGIN TRANSACTION;")
            do {
                for (i, email) in chunk.enumerated() {
                    let idStr = email.id.uuidString
                    let mid = email.headers["Message-ID"].flatMap {
                        $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
                    }
                    let dedupKey = Self.dedupKey(for: email, messageID: mid, policy: dedupPolicy)
                    let ordinal: Int64? = firstOrdinal.map { Int64($0 + offset + i) }
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
                    bindText(insertEmail, 16, email.messageType)
                    bindTextOrNull(insertEmail, 17, dedupKey)
                    if let sourceID { sqlite3_bind_int64(insertEmail, 18, sourceID) } else { sqlite3_bind_null(insertEmail, 18) }
                    if let ordinal { sqlite3_bind_int64(insertEmail, 19, ordinal) } else { sqlite3_bind_null(insertEmail, 19) }
                    sqlite3_bind_int64(insertEmail, 20, Int64(email.attachments.count))
                    sqlite3_bind_int64(insertEmail, 21, now)
                    guard sqlite3_step(insertEmail) == SQLITE_DONE else {
                        throw SQLiteStoreError.step(lastError(db))
                    }
                    if sqlite3_changes(db) == 1 {
                        result.insertedIDs.append(email.id)
                        sqlite3_reset(insertBody); sqlite3_clear_bindings(insertBody)
                        bindText(insertBody, 1, idStr)
                        bindBlob(insertBody, 2, email.plainBody.data(using: .utf8))
                        bindBlob(insertBody, 3, email.htmlBody.data(using: .utf8))
                        bindBlob(insertBody, 4, email.rawSource.data(using: .utf8))
                        bindBlob(insertBody, 5, try? JSONEncoder().encode(email.headers))
                        guard sqlite3_step(insertBody) == SQLITE_DONE else {
                            throw SQLiteStoreError.step(lastError(db))
                        }
                        for (pos, att) in email.attachments.enumerated() {
                            sqlite3_reset(insertAttachment); sqlite3_clear_bindings(insertAttachment)
                            bindText(insertAttachment, 1, idStr)
                            sqlite3_bind_int64(insertAttachment, 2, Int64(pos))
                            bindText(insertAttachment, 3, att.filename)
                            bindText(insertAttachment, 4, att.mimeType)
                            sqlite3_bind_int64(insertAttachment, 5, Int64(att.size))
                            bindTextOrNull(insertAttachment, 6, att.contentID)
                            sqlite3_bind_int(insertAttachment, 7, att.isInline ? 1 : 0)
                            guard sqlite3_step(insertAttachment) == SQLITE_DONE else {
                                throw SQLiteStoreError.step(lastError(db))
                            }
                        }
                        for (role, header) in [("FROM", "From"), ("TO", "To"), ("CC", "Cc"), ("BCC", "Bcc")] {
                            guard let raw = email.headers[header], !raw.isEmpty else { continue }
                            for p in Self.parseAddressList(raw) {
                                sqlite3_reset(insertParticipant); sqlite3_clear_bindings(insertParticipant)
                                bindText(insertParticipant, 1, idStr)
                                bindText(insertParticipant, 2, role)
                                bindText(insertParticipant, 3, p.address)
                                bindTextOrNull(insertParticipant, 4, p.display)
                                bindText(insertParticipant, 5, p.address.lowercased())
                                guard sqlite3_step(insertParticipant) == SQLITE_DONE else {
                                    throw SQLiteStoreError.step(lastError(db))
                                }
                            }
                        }
                        for tag in email.tags where !tag.isEmpty {
                            sqlite3_reset(insertTag); sqlite3_clear_bindings(insertTag)
                            bindText(insertTag, 1, idStr); bindText(insertTag, 2, tag)
                            guard sqlite3_step(insertTag) == SQLITE_DONE else {
                                throw SQLiteStoreError.step(lastError(db))
                            }
                        }
                        for domain in email.domains where !domain.isEmpty {
                            sqlite3_reset(insertDomain); sqlite3_clear_bindings(insertDomain)
                            bindText(insertDomain, 1, idStr); bindText(insertDomain, 2, domain)
                            guard sqlite3_step(insertDomain) == SQLITE_DONE else {
                                throw SQLiteStoreError.step(lastError(db))
                            }
                        }
                    } else {
                        // INSERT OR IGNORE skipped the row. Distinguish "this
                        // exact source occurrence is already stored" (resume)
                        // from "the dedup policy dropped it" (duplicate).
                        var isExistingOccurrence = false
                        if let sourceID, let ordinal {
                            sqlite3_reset(occurrenceExists); sqlite3_clear_bindings(occurrenceExists)
                            sqlite3_bind_int64(occurrenceExists, 1, sourceID)
                            sqlite3_bind_int64(occurrenceExists, 2, ordinal)
                            isExistingOccurrence = try stepRow(occurrenceExists, db)
                        }
                        if isExistingOccurrence {
                            result.existingSourceOccurrenceIDs.append(email.id)
                        } else {
                            result.duplicateIDs.append(email.id)
                            sqlite3_reset(insertDup); sqlite3_clear_bindings(insertDup)
                            bindText(insertDup, 1, idStr)
                            bindTextOrNull(insertDup, 2, mid)
                            bindTextOrNull(insertDup, 3, sourceFileHash)
                            sqlite3_bind_int64(insertDup, 4, dateInt)
                            guard sqlite3_step(insertDup) == SQLITE_DONE else {
                                throw SQLiteStoreError.step(lastError(db))
                            }
                        }
                    }
                }
                try exec(db, "COMMIT;")
            } catch {
                try? exec(db, "ROLLBACK;")
                throw error
            }
            offset += chunk.count
            processed += chunk.count
            progress?(processed, total)
        }
        return result
    }

    // MARK: - Dedup key / address parsing helpers

    /// §4/§4.1: the nullable dedup key. NULL never collides (SQLite partial
    /// unique index), so `.preserveAll` stores everything.
    static func dedupKey(for email: MBOXParser.RawEmail, messageID: String?, policy: DedupPolicy) -> String? {
        let normalizedMID = messageID?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch policy {
        case .preserveAll:
            return nil
        case .messageID:
            return (normalizedMID?.isEmpty == false) ? normalizedMID : nil
        case .messageIDOrCanonicalFingerprint:
            if let normalizedMID, !normalizedMID.isEmpty { return normalizedMID }
            return "fp:" + canonicalFingerprint(for: email)
        }
    }

    /// §4.2 canonical fallback fingerprint: SHA-256 over normalized
    /// From|To|Date|Subject plus a hash of the plain body. Deterministic and
    /// documented; collisions require all five normalized inputs to match,
    /// which is the product definition of "the same message without an ID".
    static func canonicalFingerprint(for email: MBOXParser.RawEmail) -> String {
        func norm(_ s: String?) -> String {
            (s ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let bodyHash = sha256Hex(Data(email.plainBody.utf8))
        let material = [
            norm(email.headers["From"]), norm(email.headers["To"]),
            norm(email.headers["Date"]), norm(email.headers["Subject"]),
            bodyHash
        ].joined(separator: "|")
        return sha256Hex(Data(material.utf8))
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Minimal RFC-5322-ish address-list split for participant rows: handles
    /// `Name <a@b>`, bare `a@b`, and comma-separated lists. Quoted display
    /// names containing commas are treated best-effort (split then re-checked
    /// for an @-bearing token), which is sufficient for filter/analytics use.
    static func parseAddressList(_ raw: String) -> [(display: String?, address: String)] {
        var out: [(String?, String)] = []
        for piece in raw.components(separatedBy: ",") {
            let part = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !part.isEmpty else { continue }
            if let lt = part.firstIndex(of: "<"), let gt = part.lastIndex(of: ">"), lt < gt {
                let addr = String(part[part.index(after: lt)..<gt]).trimmingCharacters(in: .whitespaces)
                guard addr.contains("@") else { continue }
                var display: String? = String(part[part.startIndex..<lt])
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                if display?.isEmpty == true { display = nil }
                out.append((display, addr))
            } else if part.contains("@") {
                out.append((nil, part.trimmingCharacters(in: CharacterSet(charactersIn: " \"'<>"))))
            }
        }
        return out
    }

    // MARK: - Counts

    func totalCount() throws -> Int {
        let db = try ensureDB()
        return try scalarInt(db, "SELECT COUNT(*) FROM emails;")
    }

    /// Browse count — excludes trashed rows (§19.1). `totalCount()` remains
    /// the physical row count for activation/reconcile gates.
    func count(after: Date?, before: Date?) throws -> Int {
        let db = try ensureDB()
        let lo = after.map { Int64($0.timeIntervalSince1970.rounded()) } ?? Int64.min
        let hi = before.map { Int64($0.timeIntervalSince1970.rounded()) } ?? Int64.max
        let stmt = try prepare(db, """
            SELECT COUNT(*) FROM emails e
            WHERE e.date >= ? AND e.date < ? AND \(Self.notTrashedPredicate);
        """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, lo)
        sqlite3_bind_int64(stmt, 2, hi)
        guard try stepRow(stmt, db) else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// §19.1: browse surfaces hide trashed rows. Correlated NOT EXISTS keeps
    /// the (date,id) keyset plan intact (review-state rows are sparse).
    static let notTrashedPredicate =
        "NOT EXISTS (SELECT 1 FROM email_review_state r WHERE r.email_id = e.id AND r.trashed = 1)"

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

    /// Total stored size in bytes (SUM aggregate — never streams bodies).
    func totalSizeBytes() throws -> Int {
        let db = try ensureDB()
        return try scalarInt(db, "SELECT COALESCE(SUM(size_bytes), 0) FROM emails;")
    }

    /// Emails whose From header contains `needle` (case-insensitive) — the
    /// DB-side equivalent of the legacy `from.contains(sender)` sent/received
    /// annotation, as a COUNT aggregate.
    func countFromContains(_ needle: String) throws -> Int {
        let db = try ensureDB()
        let stmt = try prepare(db, "SELECT COUNT(*) FROM emails WHERE instr(lower(from_addr), lower(?)) > 0;")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, needle)
        guard try stepRow(stmt, db) else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Per-sender rollup (count, total bytes, latest date) — GROUP BY aggregate
    /// powering the cleanup view without a corpus scan. Bounded by `limit`.
    struct SenderRollup: Sendable, Equatable {
        let sender: String
        let count: Int
        let totalSizeBytes: Int
        let latestDate: Date?
    }

    func senderRollups(limit: Int) throws -> [SenderRollup] {
        let db = try ensureDB()
        let stmt = try prepare(db, """
            SELECT from_addr, COUNT(*) AS c, COALESCE(SUM(size_bytes), 0), MAX(date)
            FROM emails WHERE from_addr <> '' GROUP BY from_addr
            ORDER BY c DESC, from_addr ASC LIMIT ?;
        """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        var out: [SenderRollup] = []
        while try stepRow(stmt, db) {
            let ts = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 3)
            out.append(SenderRollup(
                sender: columnText(stmt, 0),
                count: Int(sqlite3_column_int64(stmt, 1)),
                totalSizeBytes: Int(sqlite3_column_int64(stmt, 2)),
                latestDate: ts.map { Date(timeIntervalSince1970: Double($0)) }
            ))
        }
        return out
    }

    /// To-field frequencies of emails whose From contains `senderContains`
    /// (case-insensitive) — the bounded GROUP BY behind reply-frequency stats.
    /// Buckets are raw To strings; the caller splits multi-recipient fields.
    func recipientFieldCounts(senderContains: String, limit: Int) throws -> [AggregateBucket] {
        let db = try ensureDB()
        let stmt = try prepare(db, """
            SELECT to_addr, COUNT(*) AS c FROM emails
            WHERE instr(lower(from_addr), lower(?)) > 0 AND to_addr <> ''
            GROUP BY to_addr ORDER BY c DESC, to_addr ASC LIMIT ?;
        """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, senderContains)
        sqlite3_bind_int(stmt, 2, Int32(limit))
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

    // MARK: - §13 filtered queries (SQL-compiled; no field silently ignored)

    private enum QueryBind {
        case text(String)
        case int(Int64)
    }

    /// Compile every non-text EmailQuery field into WHERE clauses + binds.
    /// The email row is aliased `e`. Text is handled by FTS upstream.
    private static func filterClauses(_ q: EmailQuery) -> (sql: [String], binds: [QueryBind]) {
        var sql: [String] = []
        var binds: [QueryBind] = []
        if let after = q.afterDate {
            sql.append("e.date >= ?")
            binds.append(.int(Int64(after.timeIntervalSince1970.rounded())))
        }
        if let before = q.beforeDate {
            sql.append("e.date < ?")
            binds.append(.int(Int64(before.timeIntervalSince1970.rounded())))
        }
        if let sender = q.sender, !sender.isEmpty {
            sql.append("instr(lower(e.from_addr), lower(?)) > 0")
            binds.append(.text(sender))
        }
        if let recipient = q.recipient, !recipient.isEmpty {
            sql.append("""
                EXISTS (SELECT 1 FROM email_participants p WHERE p.email_id = e.id
                        AND p.role IN ('TO','CC','BCC') AND instr(p.normalized_address, lower(?)) > 0)
                """)
            binds.append(.text(recipient))
        }
        if let subject = q.subjectContains, !subject.isEmpty {
            sql.append("instr(lower(e.subject), lower(?)) > 0")
            binds.append(.text(subject))
        }
        if let domain = q.domain, !domain.isEmpty {
            sql.append("EXISTS (SELECT 1 FROM email_domains dm WHERE dm.email_id = e.id AND dm.domain = ?)")
            binds.append(.text(domain))
        }
        if let tag = q.userTag, !tag.isEmpty {
            sql.append("EXISTS (SELECT 1 FROM email_user_tags ut WHERE ut.email_id = e.id AND ut.tag = ?)")
            binds.append(.text(tag))
        }
        if let etag = q.evidenceTag, !etag.isEmpty {
            sql.append("EXISTS (SELECT 1 FROM forensic_evidence_tags ft WHERE ft.email_id = e.id AND ft.tag = ?)")
            binds.append(.text(etag))
        }
        if let hasAttach = q.hasAttachments {
            sql.append("e.has_attach = \(hasAttach ? 1 : 0)")
        }
        if let type = q.messageType, !type.isEmpty {
            sql.append("e.message_type = ?")
            binds.append(.text(type))
        }
        if q.pinnedOnly {
            sql.append("EXISTS (SELECT 1 FROM email_review_state rv WHERE rv.email_id = e.id AND rv.pinned = 1)")
        }
        if !q.includeTrashed {
            sql.append(notTrashedPredicate)
        }
        return (sql, binds)
    }

    /// ORDER BY + keyset predicate for each §16 sort. `sortKey` is the cursor
    /// boundary value (subject string / decimal size / decimal priority).
    private static func sortSQL(_ sort: EmailSortOrder) -> (orderBy: String, keyset: String, joins: String) {
        switch sort {
        case .dateDesc:
            return ("e.date DESC, e.id DESC", "(e.date < ? OR (e.date = ? AND e.id < ?))", "")
        case .dateAsc:
            return ("e.date ASC, e.id ASC", "(e.date > ? OR (e.date = ? AND e.id > ?))", "")
        case .subjectAZ:
            return ("e.subject COLLATE NOCASE ASC, e.id ASC",
                    "(e.subject > ? COLLATE NOCASE OR (e.subject = ? COLLATE NOCASE AND e.id > ?))", "")
        case .sizeDesc:
            return ("e.size_bytes DESC, e.id DESC",
                    "(e.size_bytes < ? OR (e.size_bytes = ? AND e.id < ?))", "")
        case .priorityDesc:
            return ("COALESCE(d.priority, -1) DESC, e.id DESC",
                    "(COALESCE(d.priority, -1) < ? OR (COALESCE(d.priority, -1) = ? AND e.id < ?))",
                    "LEFT JOIN derived d ON d.email_id = e.id")
        }
    }

    private func bindQueryValues(_ stmt: OpaquePointer?, _ binds: [QueryBind], startingAt index: Int32) -> Int32 {
        var idx = index
        for bind in binds {
            switch bind {
            case .text(let s): bindText(stmt, idx, s)
            case .int(let i): sqlite3_bind_int64(stmt, idx, i)
            }
            idx += 1
        }
        return idx
    }

    /// One keyset page of a fully SQL-compiled filtered query (§13/§16).
    /// Returns the summaries and each row's sort key so the caller can build
    /// the continuation cursor for any sort order.
    func filteredSummaryPage(
        _ query: EmailQuery, cursorSortKey: String?, cursorID: UUID?, limit: Int
    ) throws -> [(summary: EmailSummary, sortKey: String)] {
        let db = try ensureDB()
        let (clauses, binds) = Self.filterClauses(query)
        let (orderBy, keyset, joins) = Self.sortSQL(query.sort)
        let sortKeyExpr: String
        switch query.sort {
        case .dateDesc, .dateAsc: sortKeyExpr = "CAST(e.date AS TEXT)"
        case .subjectAZ: sortKeyExpr = "e.subject"
        case .sizeDesc: sortKeyExpr = "CAST(e.size_bytes AS TEXT)"
        case .priorityDesc: sortKeyExpr = "CAST(COALESCE(d.priority, -1) AS TEXT)"
        }
        var whereSQL = clauses.isEmpty ? "1=1" : clauses.joined(separator: " AND ")
        let hasCursor = (cursorSortKey != nil && cursorID != nil)
        if hasCursor { whereSQL += " AND " + keyset }
        let sql = """
            SELECT e.id, e.message_id, e.subject, e.from_addr, e.date, e.body_preview,
                   e.has_attach, e.size_bytes, \(sortKeyExpr)
            FROM emails e \(joins)
            WHERE \(whereSQL)
            ORDER BY \(orderBy) LIMIT ?;
        """
        let stmt = try prepare(db, sql)
        defer { sqlite3_finalize(stmt) }
        var idx = bindQueryValues(stmt, binds, startingAt: 1)
        if hasCursor, let key = cursorSortKey, let cid = cursorID {
            // The keyset predicates take (key, key, id) in every sort.
            switch query.sort {
            case .subjectAZ:
                bindText(stmt, idx, key); idx += 1
                bindText(stmt, idx, key); idx += 1
            default:
                guard let intKey = Int64(key) else {
                    throw SQLiteStoreError.schema("unparseable sort cursor '\(key)' for \(query.sort.rawValue)")
                }
                sqlite3_bind_int64(stmt, idx, intKey); idx += 1
                sqlite3_bind_int64(stmt, idx, intKey); idx += 1
            }
            bindText(stmt, idx, cid.uuidString); idx += 1
        }
        sqlite3_bind_int(stmt, idx, Int32(limit))

        var out: [(EmailSummary, String)] = []
        while try stepRow(stmt, db) {
            guard let id = columnUUID(stmt, 0) else { continue }
            let summary = EmailSummary(
                id: id,
                messageID: columnTextOptional(stmt, 1),
                subject: columnText(stmt, 2),
                from: columnText(stmt, 3),
                date: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 4))),
                bodyPreview: columnText(stmt, 5),
                hasAttachments: sqlite3_column_int(stmt, 6) != 0,
                sizeBytes: Int(sqlite3_column_int64(stmt, 7))
            )
            out.append((summary, columnText(stmt, 8)))
        }
        return out
    }

    /// Exact COUNT(*) for a fully SQL-compiled filtered query (§14.2 for the
    /// non-text case) — an aggregate, never a materialization.
    func filteredCount(_ query: EmailQuery) throws -> Int {
        let db = try ensureDB()
        let (clauses, binds) = Self.filterClauses(query)
        let whereSQL = clauses.isEmpty ? "1=1" : clauses.joined(separator: " AND ")
        let stmt = try prepare(db, "SELECT COUNT(*) FROM emails e WHERE \(whereSQL);")
        defer { sqlite3_finalize(stmt) }
        _ = bindQueryValues(stmt, binds, startingAt: 1)
        guard try stepRow(stmt, db) else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Which of `candidates` satisfy the query's NON-TEXT filters — used to
    /// verify FTS candidates (text queries) and scope exclusions (§15) with
    /// one bounded IN query per chunk.
    func matchingIDs(among candidates: [UUID], query: EmailQuery) throws -> Set<UUID> {
        guard !candidates.isEmpty else { return [] }
        let db = try ensureDB()
        let (clauses, binds) = Self.filterClauses(query)
        var out = Set<UUID>()
        for chunk in candidates.chunked(into: 500) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            var whereSQL = "e.id IN (\(placeholders))"
            if !clauses.isEmpty { whereSQL += " AND " + clauses.joined(separator: " AND ") }
            let stmt = try prepare(db, "SELECT e.id FROM emails e WHERE \(whereSQL);")
            defer { sqlite3_finalize(stmt) }
            var idx: Int32 = 1
            for id in chunk { bindText(stmt, idx, id.uuidString); idx += 1 }
            _ = bindQueryValues(stmt, binds, startingAt: idx)
            while try stepRow(stmt, db) { if let id = columnUUID(stmt, 0) { out.insert(id) } }
        }
        return out
    }

    // MARK: - Paging

    func summaryPage(after: Date?, before: Date?, cursorDate: Date?, cursorID: UUID?, limit: Int) throws -> [EmailSummary] {
        let db = try ensureDB()
        let lo = after.map { Int64($0.timeIntervalSince1970.rounded()) } ?? Int64.min
        let hi = before.map { Int64($0.timeIntervalSince1970.rounded()) } ?? Int64.max
        var sql = """
            SELECT e.id, e.message_id, e.subject, e.from_addr, e.date, e.body_preview, e.has_attach, e.size_bytes
            FROM emails e WHERE e.date >= ? AND e.date < ? AND \(Self.notTrashedPredicate)
        """
        let hasCursor = (cursorDate != nil && cursorID != nil)
        if hasCursor { sql += " AND (e.date < ? OR (e.date = ? AND e.id < ?))" }
        sql += " ORDER BY e.date DESC, e.id DESC LIMIT ?;"

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
                       b.plain, b.html, b.raw, b.headers_json,
                       e.message_type, t.thread_key
                FROM emails e
                LEFT JOIN email_bodies b ON e.id = b.id
                LEFT JOIN thread_keys t ON e.id = t.email_id
                WHERE e.id IN (\(placeholders));
            """)
            defer { sqlite3_finalize(stmt) }
            for (i, id) in chunk.enumerated() { bindText(stmt, Int32(i + 1), id.uuidString) }
            var base: [MBOXParser.RawEmail] = []
            while try stepRow(stmt, db) {
                if let email = rawEmailFromRow(stmt) { base.append(email) }
            }
            try hydrateSideTables(db, into: &base)
            out.append(contentsOf: base)
        }
        return out
    }

    func fullEmail(id: UUID) throws -> MBOXParser.RawEmail? {
        let db = try ensureDB()
        let stmt = try prepare(db, """
            SELECT e.id, e.message_id, e.in_reply_to, e.references_ids, e.date,
                   b.plain, b.html, b.raw, b.headers_json,
                   e.message_type, t.thread_key
            FROM emails e
            LEFT JOIN email_bodies b ON e.id = b.id
            LEFT JOIN thread_keys t ON e.id = t.email_id
            WHERE e.id = ?;
        """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, id.uuidString)
        guard try stepRow(stmt, db) else { return nil }
        guard let email = rawEmailFromRow(stmt) else { return nil }
        var one = [email]
        try hydrateSideTables(db, into: &one)
        return one.first
    }

    /// §3 full fidelity: attach the normalized side-table state (attachments
    /// metadata, parser tags, domains) to hydrated rows — one IN query per
    /// table per chunk, never per-email round-trips.
    private func hydrateSideTables(_ db: OpaquePointer, into emails: inout [MBOXParser.RawEmail]) throws {
        guard !emails.isEmpty else { return }
        let idStrings = emails.map { $0.id.uuidString }
        let placeholders = Array(repeating: "?", count: idStrings.count).joined(separator: ",")

        var attachmentsByEmail: [String: [AttachmentMetadata]] = [:]
        let attStmt = try prepare(db, """
            SELECT email_id, filename, mime_type, size_bytes, content_id, is_inline
            FROM attachments WHERE email_id IN (\(placeholders)) ORDER BY email_id, position;
        """)
        defer { sqlite3_finalize(attStmt) }
        for (i, id) in idStrings.enumerated() { bindText(attStmt, Int32(i + 1), id) }
        while try stepRow(attStmt, db) {
            attachmentsByEmail[columnText(attStmt, 0), default: []].append(AttachmentMetadata(
                filename: columnText(attStmt, 1),
                mimeType: columnText(attStmt, 2),
                size: Int(sqlite3_column_int64(attStmt, 3)),
                isInline: sqlite3_column_int(attStmt, 5) != 0,
                contentID: columnTextOptional(attStmt, 4)
            ))
        }

        var tagsByEmail: [String: [String]] = [:]
        let tagStmt = try prepare(db, "SELECT email_id, tag FROM email_tags WHERE email_id IN (\(placeholders));")
        defer { sqlite3_finalize(tagStmt) }
        for (i, id) in idStrings.enumerated() { bindText(tagStmt, Int32(i + 1), id) }
        while try stepRow(tagStmt, db) {
            tagsByEmail[columnText(tagStmt, 0), default: []].append(columnText(tagStmt, 1))
        }

        var domainsByEmail: [String: [String]] = [:]
        let domStmt = try prepare(db, "SELECT email_id, domain FROM email_domains WHERE email_id IN (\(placeholders));")
        defer { sqlite3_finalize(domStmt) }
        for (i, id) in idStrings.enumerated() { bindText(domStmt, Int32(i + 1), id) }
        while try stepRow(domStmt, db) {
            domainsByEmail[columnText(domStmt, 0), default: []].append(columnText(domStmt, 1))
        }

        for i in emails.indices {
            let key = emails[i].id.uuidString
            emails[i].attachments = attachmentsByEmail[key] ?? []
            emails[i].tags = (tagsByEmail[key] ?? []).sorted()
            emails[i].domains = (domainsByEmail[key] ?? []).sorted()
        }
    }

    // MARK: - Review state (§19)

    enum ReviewFlag: String, Sendable, CaseIterable {
        case pinned
        case isRead = "is_read"
        case archived
        case trashed
    }

    struct ReviewStateRow: Sendable, Equatable {
        var pinned = false
        var isRead = false
        var archived = false
        var trashed = false
    }

    func reviewSetFlag(_ flag: ReviewFlag, ids: [UUID], value: Bool) throws {
        guard !ids.isEmpty else { return }
        let db = try ensureDB()
        let now = Int64(Date().timeIntervalSince1970)
        let stmt = try prepare(db, """
            INSERT INTO email_review_state(email_id, \(flag.rawValue), updated_at) VALUES (?,?,?)
            ON CONFLICT(email_id) DO UPDATE SET \(flag.rawValue) = excluded.\(flag.rawValue), updated_at = excluded.updated_at;
        """)
        defer { sqlite3_finalize(stmt) }
        try exec(db, "BEGIN TRANSACTION;")
        do {
            for id in ids {
                sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
                bindText(stmt, 1, id.uuidString)
                sqlite3_bind_int(stmt, 2, value ? 1 : 0)
                sqlite3_bind_int64(stmt, 3, now)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
            }
            try exec(db, "COMMIT;")
        } catch { try? exec(db, "ROLLBACK;"); throw error }
    }

    func reviewStates(ids: [UUID]) throws -> [UUID: ReviewStateRow] {
        guard !ids.isEmpty else { return [:] }
        let db = try ensureDB()
        var out: [UUID: ReviewStateRow] = [:]
        for chunk in ids.chunked(into: 500) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let stmt = try prepare(db, """
                SELECT email_id, pinned, is_read, archived, trashed
                FROM email_review_state WHERE email_id IN (\(placeholders));
            """)
            defer { sqlite3_finalize(stmt) }
            for (i, id) in chunk.enumerated() { bindText(stmt, Int32(i + 1), id.uuidString) }
            while try stepRow(stmt, db) {
                guard let id = columnUUID(stmt, 0) else { continue }
                out[id] = ReviewStateRow(
                    pinned: sqlite3_column_int(stmt, 1) != 0,
                    isRead: sqlite3_column_int(stmt, 2) != 0,
                    archived: sqlite3_column_int(stmt, 3) != 0,
                    trashed: sqlite3_column_int(stmt, 4) != 0
                )
            }
        }
        return out
    }

    /// IDs carrying a flag, newest-email first, paged — powers Trash /
    /// Pinned views without materializing archive-sized sets.
    func reviewIDs(where flag: ReviewFlag, limit: Int, offset: Int) throws -> [UUID] {
        let db = try ensureDB()
        let stmt = try prepare(db, """
            SELECT r.email_id FROM email_review_state r
            JOIN emails e ON e.id = r.email_id
            WHERE r.\(flag.rawValue) = 1
            ORDER BY e.date DESC, e.id DESC LIMIT ? OFFSET ?;
        """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        sqlite3_bind_int(stmt, 2, Int32(offset))
        var out: [UUID] = []
        while try stepRow(stmt, db) { if let id = columnUUID(stmt, 0) { out.append(id) } }
        return out
    }

    func reviewCount(of flag: ReviewFlag) throws -> Int {
        let db = try ensureDB()
        return try scalarInt(db, "SELECT COUNT(*) FROM email_review_state WHERE \(flag.rawValue) = 1;")
    }

    // MARK: - User tags / annotations (§19)

    func userTagAdd(_ tag: String, ids: [UUID]) throws {
        try userTagMutate("INSERT OR IGNORE INTO email_user_tags(email_id, tag) VALUES (?,?);", tag: tag, ids: ids)
    }

    func userTagRemove(_ tag: String, ids: [UUID]) throws {
        try userTagMutate("DELETE FROM email_user_tags WHERE email_id = ? AND tag = ?;", tag: tag, ids: ids)
    }

    private func userTagMutate(_ sql: String, tag: String, ids: [UUID]) throws {
        guard !ids.isEmpty, !tag.isEmpty else { return }
        let db = try ensureDB()
        let stmt = try prepare(db, sql)
        defer { sqlite3_finalize(stmt) }
        try exec(db, "BEGIN TRANSACTION;")
        do {
            for id in ids {
                sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
                bindText(stmt, 1, id.uuidString)
                bindText(stmt, 2, tag)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
            }
            try exec(db, "COMMIT;")
        } catch { try? exec(db, "ROLLBACK;"); throw error }
    }

    func userTagsClear(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        let db = try ensureDB()
        for chunk in ids.chunked(into: 500) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let stmt = try prepare(db, "DELETE FROM email_user_tags WHERE email_id IN (\(placeholders));")
            defer { sqlite3_finalize(stmt) }
            for (i, id) in chunk.enumerated() { bindText(stmt, Int32(i + 1), id.uuidString) }
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
        }
    }

    func userTags(ids: [UUID]) throws -> [UUID: Set<String>] {
        guard !ids.isEmpty else { return [:] }
        let db = try ensureDB()
        var out: [UUID: Set<String>] = [:]
        for chunk in ids.chunked(into: 500) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let stmt = try prepare(db, "SELECT email_id, tag FROM email_user_tags WHERE email_id IN (\(placeholders));")
            defer { sqlite3_finalize(stmt) }
            for (i, id) in chunk.enumerated() { bindText(stmt, Int32(i + 1), id.uuidString) }
            while try stepRow(stmt, db) {
                guard let id = columnUUID(stmt, 0) else { continue }
                out[id, default: []].insert(columnText(stmt, 1))
            }
        }
        return out
    }

    /// Distinct tag vocabulary (bounded) — a DB aggregate, not a corpus scan.
    func distinctUserTags(limit: Int) throws -> [String] {
        let db = try ensureDB()
        let stmt = try prepare(db, "SELECT DISTINCT tag FROM email_user_tags ORDER BY tag LIMIT ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        var out: [String] = []
        while try stepRow(stmt, db) { out.append(columnText(stmt, 0)) }
        return out
    }

    func idsWithUserTag(_ tag: String, limit: Int, offset: Int) throws -> [UUID] {
        let db = try ensureDB()
        let stmt = try prepare(db, """
            SELECT t.email_id FROM email_user_tags t
            JOIN emails e ON e.id = t.email_id
            WHERE t.tag = ? ORDER BY e.date DESC, e.id DESC LIMIT ? OFFSET ?;
        """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, tag)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        sqlite3_bind_int(stmt, 3, Int32(offset))
        var out: [UUID] = []
        while try stepRow(stmt, db) { if let id = columnUUID(stmt, 0) { out.append(id) } }
        return out
    }

    func annotationSet(_ note: String?, id: UUID) throws {
        let db = try ensureDB()
        if let note, !note.isEmpty {
            let stmt = try prepare(db, """
                INSERT INTO email_annotations(email_id, note, updated_at) VALUES (?,?,?)
                ON CONFLICT(email_id) DO UPDATE SET note = excluded.note, updated_at = excluded.updated_at;
            """)
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, id.uuidString)
            bindText(stmt, 2, note)
            sqlite3_bind_int64(stmt, 3, Int64(Date().timeIntervalSince1970))
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
        } else {
            let stmt = try prepare(db, "DELETE FROM email_annotations WHERE email_id = ?;")
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, id.uuidString)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
        }
    }

    func annotations(ids: [UUID]) throws -> [UUID: String] {
        guard !ids.isEmpty else { return [:] }
        let db = try ensureDB()
        var out: [UUID: String] = [:]
        for chunk in ids.chunked(into: 500) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let stmt = try prepare(db, "SELECT email_id, note FROM email_annotations WHERE email_id IN (\(placeholders));")
            defer { sqlite3_finalize(stmt) }
            for (i, id) in chunk.enumerated() { bindText(stmt, Int32(i + 1), id.uuidString) }
            while try stepRow(stmt, db) {
                guard let id = columnUUID(stmt, 0) else { continue }
                out[id] = columnText(stmt, 1)
            }
        }
        return out
    }

    /// §20 one-shot legacy import — the JSON review file lands in one
    /// transaction so a crash can't leave half-migrated state.
    func reviewBulkImport(
        pinned: [UUID], read: [UUID], archived: [UUID], trashed: [UUID],
        tags: [UUID: Set<String>], annotations annots: [UUID: String]
    ) throws {
        let db = try ensureDB()
        let now = Int64(Date().timeIntervalSince1970)
        try exec(db, "BEGIN TRANSACTION;")
        do {
            let flagStmt = try prepare(db, """
                INSERT INTO email_review_state(email_id, pinned, is_read, archived, trashed, updated_at)
                VALUES (?,?,?,?,?,?)
                ON CONFLICT(email_id) DO UPDATE SET
                    pinned = MAX(pinned, excluded.pinned),
                    is_read = MAX(is_read, excluded.is_read),
                    archived = MAX(archived, excluded.archived),
                    trashed = MAX(trashed, excluded.trashed),
                    updated_at = excluded.updated_at;
            """)
            defer { sqlite3_finalize(flagStmt) }
            var flagValues: [UUID: (Bool, Bool, Bool, Bool)] = [:]
            for id in pinned { flagValues[id, default: (false, false, false, false)].0 = true }
            for id in read { flagValues[id, default: (false, false, false, false)].1 = true }
            for id in archived { flagValues[id, default: (false, false, false, false)].2 = true }
            for id in trashed { flagValues[id, default: (false, false, false, false)].3 = true }
            for (id, f) in flagValues {
                sqlite3_reset(flagStmt); sqlite3_clear_bindings(flagStmt)
                bindText(flagStmt, 1, id.uuidString)
                sqlite3_bind_int(flagStmt, 2, f.0 ? 1 : 0)
                sqlite3_bind_int(flagStmt, 3, f.1 ? 1 : 0)
                sqlite3_bind_int(flagStmt, 4, f.2 ? 1 : 0)
                sqlite3_bind_int(flagStmt, 5, f.3 ? 1 : 0)
                sqlite3_bind_int64(flagStmt, 6, now)
                guard sqlite3_step(flagStmt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
            }
            let tagStmt = try prepare(db, "INSERT OR IGNORE INTO email_user_tags(email_id, tag) VALUES (?,?);")
            defer { sqlite3_finalize(tagStmt) }
            for (id, set) in tags {
                for tag in set where !tag.isEmpty {
                    sqlite3_reset(tagStmt); sqlite3_clear_bindings(tagStmt)
                    bindText(tagStmt, 1, id.uuidString)
                    bindText(tagStmt, 2, tag)
                    guard sqlite3_step(tagStmt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
                }
            }
            let noteStmt = try prepare(db, """
                INSERT INTO email_annotations(email_id, note, updated_at) VALUES (?,?,?)
                ON CONFLICT(email_id) DO UPDATE SET note = excluded.note, updated_at = excluded.updated_at;
            """)
            defer { sqlite3_finalize(noteStmt) }
            for (id, note) in annots where !note.isEmpty {
                sqlite3_reset(noteStmt); sqlite3_clear_bindings(noteStmt)
                bindText(noteStmt, 1, id.uuidString)
                bindText(noteStmt, 2, note)
                sqlite3_bind_int64(noteStmt, 3, now)
                guard sqlite3_step(noteStmt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
            }
            try exec(db, "COMMIT;")
        } catch { try? exec(db, "ROLLBACK;"); throw error }
    }

    func reviewTotals() throws -> (states: Int, tags: Int, annotations: Int) {
        let db = try ensureDB()
        return (
            try scalarInt(db, "SELECT COUNT(*) FROM email_review_state;"),
            try scalarInt(db, "SELECT COUNT(*) FROM email_user_tags;"),
            try scalarInt(db, "SELECT COUNT(*) FROM email_annotations;")
        )
    }

    // MARK: - Fidelity backfill (legacy rows: message_type == '')

    struct FidelityCandidate: Sendable {
        let id: UUID
        let raw: String
    }

    /// Legacy rows still awaiting fidelity extraction, with their raw MIME —
    /// plus the ids whose raw source is missing (the CALLER marks those
    /// 'unknown' so the outcome accounting sees them).
    func fidelityBackfillCandidates(limit: Int) throws -> (candidates: [FidelityCandidate], rawless: [UUID]) {
        let db = try ensureDB()
        let stmt = try prepare(db, """
            SELECT e.id, b.raw FROM emails e
            LEFT JOIN email_bodies b ON b.id = e.id
            WHERE e.message_type = '' LIMIT ?;
        """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        var out: [FidelityCandidate] = []
        var unrecoverable: [UUID] = []
        // M2: pages are bounded by BYTES as well as rows — raw MIME with
        // base64 attachments can run tens of MB per message.
        let maxPageBytes = 32 * 1024 * 1024
        var pageBytes = 0
        while try stepRow(stmt, db) {
            guard let id = columnUUID(stmt, 0) else { continue }
            if let raw = columnBlobString(stmt, 1), !raw.isEmpty {
                out.append(FidelityCandidate(id: id, raw: raw))
                pageBytes += raw.utf8.count
                if pageBytes >= maxPageBytes { break }
            } else {
                unrecoverable.append(id)
            }
        }
        return (out, unrecoverable)
    }

    func fidelityPendingCount() throws -> Int {
        let db = try ensureDB()
        return try scalarInt(db, "SELECT COUNT(*) FROM emails WHERE message_type = '';")
    }

    /// Rows that cannot be re-extracted (no raw source) exit the work list
    /// honestly — "unknown", never a fabricated classification.
    func markFidelityUnknown(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        let db = try ensureDB()
        for chunk in ids.chunked(into: 500) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let stmt = try prepare(db, "UPDATE emails SET message_type = 'unknown' WHERE id IN (\(placeholders));")
            defer { sqlite3_finalize(stmt) }
            for (i, id) in chunk.enumerated() { bindText(stmt, Int32(i + 1), id.uuidString) }
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
        }
    }

    /// Apply re-extracted fidelity for one legacy row, in one transaction:
    /// message type + attachment flags on the email row, plus the normalized
    /// attachments/tags/domains side tables (§3 parity for old imports).
    func applyFidelity(id: UUID, from email: MBOXParser.RawEmail) throws {
        let db = try ensureDB()
        try exec(db, "BEGIN TRANSACTION;")
        do {
            let idStr = id.uuidString
            let update = try prepare(db, """
                UPDATE emails SET message_type = ?, has_attach = ?, attachment_count = ?
                WHERE id = ?;
            """)
            defer { sqlite3_finalize(update) }
            bindText(update, 1, email.messageType.isEmpty ? "unknown" : email.messageType)
            sqlite3_bind_int(update, 2, email.attachments.isEmpty ? 0 : 1)
            sqlite3_bind_int64(update, 3, Int64(email.attachments.count))
            bindText(update, 4, idStr)
            guard sqlite3_step(update) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }

            let clearAtt = try prepare(db, "DELETE FROM attachments WHERE email_id = ?;")
            defer { sqlite3_finalize(clearAtt) }
            bindText(clearAtt, 1, idStr)
            guard sqlite3_step(clearAtt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
            let insertAtt = try prepare(db, """
                INSERT INTO attachments(email_id, position, filename, mime_type, size_bytes, content_id, is_inline)
                VALUES (?,?,?,?,?,?,?);
            """)
            defer { sqlite3_finalize(insertAtt) }
            for (pos, att) in email.attachments.enumerated() {
                sqlite3_reset(insertAtt); sqlite3_clear_bindings(insertAtt)
                bindText(insertAtt, 1, idStr)
                sqlite3_bind_int64(insertAtt, 2, Int64(pos))
                bindText(insertAtt, 3, att.filename)
                bindText(insertAtt, 4, att.mimeType)
                sqlite3_bind_int64(insertAtt, 5, Int64(att.size))
                bindTextOrNull(insertAtt, 6, att.contentID)
                sqlite3_bind_int(insertAtt, 7, att.isInline ? 1 : 0)
                guard sqlite3_step(insertAtt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
            }

            let insertTag = try prepare(db, "INSERT OR IGNORE INTO email_tags(email_id, tag) VALUES (?,?);")
            defer { sqlite3_finalize(insertTag) }
            for tag in email.tags where !tag.isEmpty {
                sqlite3_reset(insertTag); sqlite3_clear_bindings(insertTag)
                bindText(insertTag, 1, idStr); bindText(insertTag, 2, tag)
                guard sqlite3_step(insertTag) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
            }
            let insertDomain = try prepare(db, "INSERT OR IGNORE INTO email_domains(email_id, domain) VALUES (?,?);")
            defer { sqlite3_finalize(insertDomain) }
            for domain in email.domains where !domain.isEmpty {
                sqlite3_reset(insertDomain); sqlite3_clear_bindings(insertDomain)
                bindText(insertDomain, 1, idStr); bindText(insertDomain, 2, domain)
                guard sqlite3_step(insertDomain) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
            }
            // Participants too — sender auto-detect and recipient filters
            // depend on them (legacy rows never had these).
            let clearPart = try prepare(db, "DELETE FROM email_participants WHERE email_id = ?;")
            defer { sqlite3_finalize(clearPart) }
            bindText(clearPart, 1, idStr)
            guard sqlite3_step(clearPart) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
            let insertPart = try prepare(db, """
                INSERT INTO email_participants(email_id, role, address, display_name, normalized_address)
                VALUES (?,?,?,?,?);
            """)
            defer { sqlite3_finalize(insertPart) }
            var participantsInserted = 0
            for (role, header) in [("FROM", "From"), ("TO", "To"), ("CC", "Cc"), ("BCC", "Bcc")] {
                guard let raw = email.headers[header], !raw.isEmpty else { continue }
                for participant in Self.parseAddressList(raw) {
                    sqlite3_reset(insertPart); sqlite3_clear_bindings(insertPart)
                    bindText(insertPart, 1, idStr)
                    bindText(insertPart, 2, role)
                    bindText(insertPart, 3, participant.address)
                    bindTextOrNull(insertPart, 4, participant.display)
                    bindText(insertPart, 5, participant.address.lowercased())
                    guard sqlite3_step(insertPart) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
                    participantsInserted += 1
                }
            }
            if participantsInserted == 0 {
                // Sentinel so the participants work list converges (see
                // markParticipantsNone).
                sqlite3_reset(insertPart); sqlite3_clear_bindings(insertPart)
                bindText(insertPart, 1, idStr)
                bindText(insertPart, 2, "NONE")
                bindText(insertPart, 3, "")
                sqlite3_bind_null(insertPart, 4)
                bindText(insertPart, 5, "")
                guard sqlite3_step(insertPart) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
            }
            try exec(db, "COMMIT;")
        } catch { try? exec(db, "ROLLBACK;"); throw error }
    }

    #if DEBUG
    /// Test fixture: strip the structured fidelity fields so rows look like
    /// they were persisted by a pre-full-fidelity build.
    func simulateLegacyRowsForTesting() throws {
        let db = try ensureDB()
        try exec(db, "UPDATE emails SET message_type = '', has_attach = 0, attachment_count = 0;")
        try exec(db, "DELETE FROM attachments;")
        try exec(db, "DELETE FROM email_tags;")
        try exec(db, "DELETE FROM email_domains;")
        try exec(db, "DELETE FROM email_participants;")
    }
    #endif

    // MARK: - Attachment-content search (v6)

    /// Emails with attachments whose text extraction hasn't been attempted —
    /// with raw MIME, byte-capped pages (the extraction job's work list).
    func attachmentTextCandidates(limit: Int) throws -> (candidates: [FidelityCandidate], rawless: [UUID]) {
        let db = try ensureDB()
        let stmt = try prepare(db, """
            SELECT e.id, b.raw FROM emails e
            LEFT JOIN email_bodies b ON b.id = e.id
            WHERE e.has_attach = 1
              AND NOT EXISTS (SELECT 1 FROM attachment_text_state s WHERE s.email_id = e.id)
            LIMIT ?;
        """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        var out: [FidelityCandidate] = []
        var rawless: [UUID] = []
        let maxPageBytes = 32 * 1024 * 1024
        var pageBytes = 0
        while try stepRow(stmt, db) {
            guard let id = columnUUID(stmt, 0) else { continue }
            if let raw = columnBlobString(stmt, 1), !raw.isEmpty {
                out.append(FidelityCandidate(id: id, raw: raw))
                pageBytes += raw.utf8.count
                if pageBytes >= maxPageBytes { break }
            } else {
                rawless.append(id)
            }
        }
        return (out, rawless)
    }

    /// Record one email's extracted attachment texts (possibly none) — FTS
    /// rows + the attempted-state marker in ONE transaction, idempotent via
    /// delete-then-insert.
    func attachmentTextIndex(emailID: UUID, texts: [(filename: String, content: String)]) throws {
        let db = try ensureDB()
        try exec(db, "BEGIN TRANSACTION;")
        do {
            let clear = try prepare(db, "DELETE FROM attachment_search WHERE email_id = ?;")
            defer { sqlite3_finalize(clear) }
            bindText(clear, 1, emailID.uuidString)
            guard sqlite3_step(clear) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }

            let insert = try prepare(db, "INSERT INTO attachment_search(email_id, filename, content) VALUES (?,?,?);")
            defer { sqlite3_finalize(insert) }
            for text in texts {
                sqlite3_reset(insert); sqlite3_clear_bindings(insert)
                bindText(insert, 1, emailID.uuidString)
                bindText(insert, 2, text.filename)
                bindText(insert, 3, text.content)
                guard sqlite3_step(insert) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
            }
            let state = try prepare(db, """
                INSERT INTO attachment_text_state(email_id, indexed_at, text_count) VALUES (?,?,?)
                ON CONFLICT(email_id) DO UPDATE SET indexed_at = excluded.indexed_at, text_count = excluded.text_count;
            """)
            defer { sqlite3_finalize(state) }
            bindText(state, 1, emailID.uuidString)
            sqlite3_bind_int64(state, 2, Int64(Date().timeIntervalSince1970))
            sqlite3_bind_int64(state, 3, Int64(texts.count))
            guard sqlite3_step(state) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
            try exec(db, "COMMIT;")
        } catch { try? exec(db, "ROLLBACK;"); throw error }
    }

    /// Emails whose attachment FILENAME or extracted CONTENT matches the FTS
    /// query — bounded by `limit`, never a materialized result set.
    func attachmentTextSearch(_ ftsQuery: String, limit: Int = 2_000) throws -> Set<UUID> {
        let trimmed = ftsQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        do {
            return try attachmentTextMatch(trimmed, limit: limit)
        } catch {
            // Raw user text can be FTS5 syntax (hyphens = column filters,
            // stray quotes). Retry with every token phrase-quoted — a search
            // must degrade to literal matching, never throw at the user.
            let quoted = trimmed.split(separator: " ")
                .map { "\"" + $0.replacingOccurrences(of: "\"", with: "") + "\"" }
                .joined(separator: " ")
            return try attachmentTextMatch(quoted, limit: limit)
        }
    }

    private func attachmentTextMatch(_ query: String, limit: Int) throws -> Set<UUID> {
        let db = try ensureDB()
        let stmt = try prepare(db, "SELECT DISTINCT email_id FROM attachment_search WHERE attachment_search MATCH ? LIMIT ?;")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, query)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        var out = Set<UUID>()
        while try stepRow(stmt, db) { if let id = columnUUID(stmt, 0) { out.insert(id) } }
        return out
    }

    /// (attempted, pending) — powers the honest indexing-progress notice.
    func attachmentTextProgress() throws -> (attempted: Int, pending: Int) {
        let db = try ensureDB()
        let attempted = try scalarInt(db, "SELECT COUNT(*) FROM attachment_text_state;")
        let pending = try scalarInt(db, """
            SELECT COUNT(*) FROM emails e WHERE e.has_attach = 1
              AND NOT EXISTS (SELECT 1 FROM attachment_text_state s WHERE s.email_id = e.id);
        """)
        return (attempted, pending)
    }

    // MARK: - Forensic state (§21)

    struct ForensicEmailHashRow: Sendable, Equatable {
        let md5: String
        let sha1: String
        let sha256: String
        let byteCount: Int
    }

    func forensicHashUpsert(_ hashes: [UUID: ForensicEmailHashRow]) throws {
        guard !hashes.isEmpty else { return }
        let db = try ensureDB()
        let stmt = try prepare(db, """
            INSERT INTO forensic_email_hashes(email_id, md5, sha1, sha256, byte_count)
            VALUES (?,?,?,?,?)
            ON CONFLICT(email_id) DO NOTHING;
        """)
        defer { sqlite3_finalize(stmt) }
        try exec(db, "BEGIN TRANSACTION;")
        do {
            for (id, h) in hashes {
                sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
                bindText(stmt, 1, id.uuidString)
                bindText(stmt, 2, h.md5)
                bindText(stmt, 3, h.sha1)
                bindText(stmt, 4, h.sha256)
                sqlite3_bind_int64(stmt, 5, Int64(h.byteCount))
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
            }
            try exec(db, "COMMIT;")
        } catch { try? exec(db, "ROLLBACK;"); throw error }
    }

    func forensicHashes(ids: [UUID]) throws -> [UUID: ForensicEmailHashRow] {
        guard !ids.isEmpty else { return [:] }
        let db = try ensureDB()
        var out: [UUID: ForensicEmailHashRow] = [:]
        for chunk in ids.chunked(into: 500) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let stmt = try prepare(db, "SELECT email_id, md5, sha1, sha256, byte_count FROM forensic_email_hashes WHERE email_id IN (\(placeholders));")
            defer { sqlite3_finalize(stmt) }
            for (i, id) in chunk.enumerated() { bindText(stmt, Int32(i + 1), id.uuidString) }
            while try stepRow(stmt, db) {
                guard let id = columnUUID(stmt, 0) else { continue }
                out[id] = ForensicEmailHashRow(
                    md5: columnText(stmt, 1), sha1: columnText(stmt, 2),
                    sha256: columnText(stmt, 3), byteCount: Int(sqlite3_column_int64(stmt, 4)))
            }
        }
        return out
    }

    func forensicHashCount() throws -> Int {
        let db = try ensureDB()
        return try scalarInt(db, "SELECT COUNT(*) FROM forensic_email_hashes;")
    }

    func forensicTagSet(_ tag: String?, ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        let db = try ensureDB()
        let now = Int64(Date().timeIntervalSince1970)
        let sql = tag == nil
            ? "DELETE FROM forensic_evidence_tags WHERE email_id = ?;"
            : """
              INSERT INTO forensic_evidence_tags(email_id, tag, tagged_at) VALUES (?,?,?)
              ON CONFLICT(email_id) DO UPDATE SET tag = excluded.tag, tagged_at = excluded.tagged_at;
              """
        let stmt = try prepare(db, sql)
        defer { sqlite3_finalize(stmt) }
        try exec(db, "BEGIN TRANSACTION;")
        do {
            for id in ids {
                sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
                bindText(stmt, 1, id.uuidString)
                if let tag {
                    bindText(stmt, 2, tag)
                    sqlite3_bind_int64(stmt, 3, now)
                }
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
            }
            try exec(db, "COMMIT;")
        } catch { try? exec(db, "ROLLBACK;"); throw error }
    }

    func forensicTags(ids: [UUID]) throws -> [UUID: (tag: String, taggedAt: Date)] {
        guard !ids.isEmpty else { return [:] }
        let db = try ensureDB()
        var out: [UUID: (String, Date)] = [:]
        for chunk in ids.chunked(into: 500) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let stmt = try prepare(db, "SELECT email_id, tag, tagged_at FROM forensic_evidence_tags WHERE email_id IN (\(placeholders));")
            defer { sqlite3_finalize(stmt) }
            for (i, id) in chunk.enumerated() { bindText(stmt, Int32(i + 1), id.uuidString) }
            while try stepRow(stmt, db) {
                guard let id = columnUUID(stmt, 0) else { continue }
                out[id] = (columnText(stmt, 1), Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 2))))
            }
        }
        return out
    }

    /// All (email_id, tag) pairs, paged — bounded hydration/scan path.
    func forensicTagsPage(limit: Int, offset: Int) throws -> [(id: UUID, tag: String, taggedAt: Date)] {
        let db = try ensureDB()
        let stmt = try prepare(db, "SELECT email_id, tag, tagged_at FROM forensic_evidence_tags ORDER BY email_id LIMIT ? OFFSET ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        sqlite3_bind_int(stmt, 2, Int32(offset))
        var out: [(UUID, String, Date)] = []
        while try stepRow(stmt, db) {
            guard let id = columnUUID(stmt, 0) else { continue }
            out.append((id, columnText(stmt, 1), Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 2)))))
        }
        return out
    }

    func forensicTagCounts() throws -> [String: Int] {
        let db = try ensureDB()
        let stmt = try prepare(db, "SELECT tag, COUNT(*) FROM forensic_evidence_tags GROUP BY tag;")
        defer { sqlite3_finalize(stmt) }
        var out: [String: Int] = [:]
        while try stepRow(stmt, db) { out[columnText(stmt, 0)] = Int(sqlite3_column_int64(stmt, 1)) }
        return out
    }

    func forensicIDs(withTag tag: String, limit: Int, offset: Int) throws -> [UUID] {
        let db = try ensureDB()
        let stmt = try prepare(db, "SELECT email_id FROM forensic_evidence_tags WHERE tag = ? ORDER BY email_id LIMIT ? OFFSET ?;")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, tag)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        sqlite3_bind_int(stmt, 3, Int32(offset))
        var out: [UUID] = []
        while try stepRow(stmt, db) { if let id = columnUUID(stmt, 0) { out.append(id) } }
        return out
    }

    func forensicAnnotationSet(_ note: String?, examiner: String, id: UUID) throws {
        let db = try ensureDB()
        if let note, !note.isEmpty {
            let stmt = try prepare(db, """
                INSERT INTO forensic_annotations(email_id, note, examiner, created_at) VALUES (?,?,?,?)
                ON CONFLICT(email_id) DO UPDATE SET note = excluded.note, examiner = excluded.examiner, created_at = excluded.created_at;
            """)
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, id.uuidString)
            bindText(stmt, 2, note)
            bindText(stmt, 3, examiner)
            sqlite3_bind_int64(stmt, 4, Int64(Date().timeIntervalSince1970))
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
        } else {
            let stmt = try prepare(db, "DELETE FROM forensic_annotations WHERE email_id = ?;")
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, id.uuidString)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
        }
    }

    func forensicAnnotations(ids: [UUID]) throws -> [UUID: (note: String, examiner: String, createdAt: Date)] {
        guard !ids.isEmpty else { return [:] }
        let db = try ensureDB()
        var out: [UUID: (String, String, Date)] = [:]
        for chunk in ids.chunked(into: 500) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let stmt = try prepare(db, "SELECT email_id, note, examiner, created_at FROM forensic_annotations WHERE email_id IN (\(placeholders));")
            defer { sqlite3_finalize(stmt) }
            for (i, id) in chunk.enumerated() { bindText(stmt, Int32(i + 1), id.uuidString) }
            while try stepRow(stmt, db) {
                guard let id = columnUUID(stmt, 0) else { continue }
                out[id] = (columnText(stmt, 1), columnText(stmt, 2),
                           Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 3))))
            }
        }
        return out
    }

    func forensicAnnotationCount() throws -> Int {
        let db = try ensureDB()
        return try scalarInt(db, "SELECT COUNT(*) FROM forensic_annotations;")
    }

    func forensicAnnotationsPage(limit: Int, offset: Int) throws -> [(id: UUID, note: String, examiner: String, createdAt: Date)] {
        let db = try ensureDB()
        let stmt = try prepare(db, "SELECT email_id, note, examiner, created_at FROM forensic_annotations ORDER BY email_id LIMIT ? OFFSET ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        sqlite3_bind_int(stmt, 2, Int32(offset))
        var out: [(UUID, String, String, Date)] = []
        while try stepRow(stmt, db) {
            guard let id = columnUUID(stmt, 0) else { continue }
            out.append((id, columnText(stmt, 1), columnText(stmt, 2),
                        Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 3)))))
        }
        return out
    }

    // MARK: - Forensic source hashes + audit log (§21.1/§21.2)

    struct ForensicSourceHashRow: Sendable, Equatable {
        let filename: String
        let fileSize: Int64
        let md5: String
        let sha1: String
        let sha256: String
        let importedAt: Date
    }

    func forensicSourceHashUpsert(_ row: ForensicSourceHashRow) throws {
        let db = try ensureDB()
        let stmt = try prepare(db, """
            INSERT INTO forensic_source_hashes(filename, file_size, md5, sha1, sha256, imported_at)
            VALUES (?,?,?,?,?,?)
            ON CONFLICT(sha256) DO UPDATE SET imported_at = excluded.imported_at;
        """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, row.filename)
        sqlite3_bind_int64(stmt, 2, row.fileSize)
        bindText(stmt, 3, row.md5)
        bindText(stmt, 4, row.sha1)
        bindText(stmt, 5, row.sha256)
        sqlite3_bind_int64(stmt, 6, Int64(row.importedAt.timeIntervalSince1970))
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
    }

    func forensicSourceHashes() throws -> [ForensicSourceHashRow] {
        let db = try ensureDB()
        let stmt = try prepare(db, "SELECT filename, file_size, md5, sha1, sha256, imported_at FROM forensic_source_hashes ORDER BY imported_at DESC;")
        defer { sqlite3_finalize(stmt) }
        var out: [ForensicSourceHashRow] = []
        while try stepRow(stmt, db) {
            out.append(ForensicSourceHashRow(
                filename: columnText(stmt, 0), fileSize: sqlite3_column_int64(stmt, 1),
                md5: columnText(stmt, 2), sha1: columnText(stmt, 3), sha256: columnText(stmt, 4),
                importedAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 5)))))
        }
        return out
    }

    struct ForensicAuditRow: Sendable, Equatable {
        let seq: Int
        let entryID: UUID
        let timestamp: Date
        let action: String
        let detail: String
        let examiner: String
        let previousHash: String
        let entryHash: String
    }

    /// Append one audit entry. `seq` is the PRIMARY KEY, so a duplicated or
    /// out-of-order append fails loudly instead of corrupting the chain.
    func forensicAuditAppend(_ row: ForensicAuditRow) throws {
        let db = try ensureDB()
        let stmt = try prepare(db, """
            INSERT INTO forensic_audit_log(seq, entry_id, ts, action, detail, examiner, prev_hash, entry_hash)
            VALUES (?,?,?,?,?,?,?,?);
        """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(row.seq))
        bindText(stmt, 2, row.entryID.uuidString)
        sqlite3_bind_double(stmt, 3, row.timestamp.timeIntervalSince1970)
        bindText(stmt, 4, row.action)
        bindText(stmt, 5, row.detail)
        bindText(stmt, 6, row.examiner)
        bindText(stmt, 7, row.previousHash)
        bindText(stmt, 8, row.entryHash)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
    }

    private func forensicAuditRow(_ stmt: OpaquePointer?) -> ForensicAuditRow? {
        guard let entryID = columnUUID(stmt, 1) else { return nil }
        return ForensicAuditRow(
            seq: Int(sqlite3_column_int64(stmt, 0)),
            entryID: entryID,
            timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
            action: columnText(stmt, 3), detail: columnText(stmt, 4),
            examiner: columnText(stmt, 5),
            previousHash: columnText(stmt, 6), entryHash: columnText(stmt, 7))
    }

    private static let auditColumns = "seq, entry_id, ts, action, detail, examiner, prev_hash, entry_hash"

    /// Ordered page for streamed verification (ascending from `fromSeq`).
    func forensicAuditPage(fromSeq: Int, limit: Int) throws -> [ForensicAuditRow] {
        let db = try ensureDB()
        let stmt = try prepare(db, "SELECT \(Self.auditColumns) FROM forensic_audit_log WHERE seq >= ? ORDER BY seq ASC LIMIT ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(fromSeq))
        sqlite3_bind_int(stmt, 2, Int32(limit))
        var out: [ForensicAuditRow] = []
        while try stepRow(stmt, db) { if let r = forensicAuditRow(stmt) { out.append(r) } }
        return out
    }

    /// Most recent entries for UI display (descending).
    func forensicAuditRecent(limit: Int) throws -> [ForensicAuditRow] {
        let db = try ensureDB()
        let stmt = try prepare(db, "SELECT \(Self.auditColumns) FROM forensic_audit_log ORDER BY seq DESC LIMIT ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        var out: [ForensicAuditRow] = []
        while try stepRow(stmt, db) { if let r = forensicAuditRow(stmt) { out.append(r) } }
        return out
    }

    func forensicAuditCount() throws -> Int {
        let db = try ensureDB()
        return try scalarInt(db, "SELECT COUNT(*) FROM forensic_audit_log;")
    }

    func forensicAuditLast() throws -> ForensicAuditRow? {
        try forensicAuditRecent(limit: 1).first
    }

    func forensicClearAll() throws {
        let db = try ensureDB()
        for table in ["forensic_email_hashes", "forensic_evidence_tags", "forensic_annotations",
                      "forensic_source_hashes", "forensic_audit_log"] {
            try exec(db, "DELETE FROM \(table);")
        }
    }

    /// Rows that HAVE a message type but NO participants rows (classified by
    /// an earlier build or by SQL reclassification, which skips extraction).
    /// Returns (id, raw) pages plus raw-less ids the caller marks done via a
    /// sentinel so the list converges.
    func participantsBackfillCandidates(limit: Int) throws -> (candidates: [FidelityCandidate], rawless: [UUID]) {
        let db = try ensureDB()
        let stmt = try prepare(db, """
            SELECT e.id, b.raw FROM emails e
            LEFT JOIN email_bodies b ON b.id = e.id
            WHERE e.message_type <> ''
              AND NOT EXISTS (SELECT 1 FROM email_participants p WHERE p.email_id = e.id)
            LIMIT ?;
        """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        var out: [FidelityCandidate] = []
        var rawless: [UUID] = []
        let maxPageBytes = 32 * 1024 * 1024
        var pageBytes = 0
        while try stepRow(stmt, db) {
            guard let id = columnUUID(stmt, 0) else { continue }
            if let raw = columnBlobString(stmt, 1), !raw.isEmpty {
                out.append(FidelityCandidate(id: id, raw: raw))
                pageBytes += raw.utf8.count
                if pageBytes >= maxPageBytes { break }
            } else {
                rawless.append(id)
            }
        }
        return (out, rawless)
    }

    /// Sentinel participant row (role NONE, empty address) — marks an email as
    /// "extraction attempted, nothing parseable" so the participants work list
    /// converges. Every consumer filters real roles / LIKE '%@%', so the
    /// sentinel is invisible to queries.
    func markParticipantsNone(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        let db = try ensureDB()
        let stmt = try prepare(db, """
            INSERT INTO email_participants(email_id, role, address, display_name, normalized_address)
            VALUES (?,'NONE','',NULL,'');
        """)
        defer { sqlite3_finalize(stmt) }
        try exec(db, "BEGIN TRANSACTION;")
        do {
            for id in ids {
                sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
                bindText(stmt, 1, id.uuidString)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
            }
            try exec(db, "COMMIT;")
        } catch { try? exec(db, "ROLLBACK;"); throw error }
    }

    /// v1-parity auto-detect: the archive owner's address. Primary heuristic:
    /// the normalized participant present in the most emails (the owner is on
    /// nearly every message — From when sent, To/Cc when received). Fallback
    /// (participants empty, e.g. pre-backfill): v1's exact heuristic — the
    /// most common raw From header.
    func detectOwnerAddress() throws -> String? {
        let db = try ensureDB()
        let stmt = try prepare(db, """
            SELECT normalized_address, COUNT(DISTINCT email_id) AS c
            FROM email_participants
            WHERE normalized_address LIKE '%@%'
            GROUP BY normalized_address
            ORDER BY c DESC, COUNT(DISTINCT role) DESC, normalized_address
            LIMIT 1;
        """)
        defer { sqlite3_finalize(stmt) }
        if try stepRow(stmt, db) {
            let addr = columnText(stmt, 0)
            if !addr.isEmpty { return addr }
        }
        return try topGrouped(.fromAddr, limit: 1).first?.value
    }

    /// M1: sent/received is derivable from from_addr in pure SQL — when the
    /// user's address changes, every already-classified row reclassifies in
    /// one statement (no re-parse). Rows still pending ('') are untouched;
    /// the backfill classifies them with the new address.
    func reclassifyMessageTypes(senderEmail: String) throws {
        let needle = senderEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return }
        let db = try ensureDB()
        let stmt = try prepare(db, """
            UPDATE emails SET message_type =
                CASE WHEN instr(lower(from_addr), lower(?)) > 0 THEN 'sent' ELSE 'received' END
            WHERE message_type IN ('sent', 'received', 'unknown');
        """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, needle)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
    }

    /// M6: per-email forensic rows for EXACTLY the given ids (used when a
    /// clear preserves legal-hold rows — their forensic state must survive).
    func forensicPerEmailDelete(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        let db = try ensureDB()
        for chunk in ids.chunked(into: 500) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            for table in ["forensic_email_hashes", "forensic_evidence_tags", "forensic_annotations"] {
                let stmt = try prepare(db, "DELETE FROM \(table) WHERE email_id IN (\(placeholders));")
                defer { sqlite3_finalize(stmt) }
                for (i, id) in chunk.enumerated() { bindText(stmt, Int32(i + 1), id.uuidString) }
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
            }
        }
    }

    /// §11.1: clear only the per-email forensic state (rows reference deleted
    /// emails); the audit log + source-hash history remain as evidence.
    func forensicPerEmailClear() throws {
        let db = try ensureDB()
        for table in ["forensic_email_hashes", "forensic_evidence_tags", "forensic_annotations"] {
            try exec(db, "DELETE FROM \(table);")
        }
    }

    // MARK: - Mutation

    func delete(ids: Set<UUID>) throws {
        guard !ids.isEmpty else { return }
        let db = try ensureDB()
        try exec(db, "BEGIN TRANSACTION;")
        do {
            for chunk in Array(ids).chunked(into: 500) {
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                // (table, id column) — derived tables are keyed by email_id.
                for (table, col) in [("emails", "id"), ("email_bodies", "id"), ("derived", "email_id"),
                                     ("thread_keys", "email_id"), ("predictive_records", "email_id"),
                                     ("near_dup_findings", "email_id"),
                                     ("attachments", "email_id"), ("email_participants", "email_id"),
                                     ("email_tags", "email_id"), ("email_domains", "email_id"),
                                     ("email_review_state", "email_id"), ("email_user_tags", "email_id"),
                                     ("email_annotations", "email_id"),
                                     ("attachment_search", "email_id"), ("attachment_text_state", "email_id")] {
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
        for table in ["emails", "email_bodies", "derived", "duplicates", "thread_keys",
                      "predictive_records", "near_dup_findings", "sources", "attachments",
                      "email_participants", "email_tags", "email_domains",
                      "email_review_state", "email_user_tags", "email_annotations",
                      "attachment_search", "attachment_text_state"] {
            try exec(db, "DELETE FROM \(table);")
        }
    }

    /// Fold the WAL back into the main db file. Keeps the on-disk footprint
    /// honest and bounds WAL growth after a large import.
    func checkpoint() throws {
        let db = try ensureDB()
        try exec(db, "PRAGMA wal_checkpoint(TRUNCATE);")
    }

    // MARK: - Row → RawEmail

    /// Base-row hydration. Side-table state (attachments/tags/domains) is
    /// attached afterwards by `hydrateSideTables` — this only reads columns.
    /// `message_type` is empty for rows persisted by pre-v2 builds (their
    /// structured metadata was never stored); those hydrate as "stored".
    private func rawEmailFromRow(_ stmt: OpaquePointer?) -> MBOXParser.RawEmail? {
        guard let id = columnUUID(stmt, 0) else { return nil }
        let messageID = columnTextOptional(stmt, 1)
        let inReplyTo = columnTextOptional(stmt, 2)
        let references = columnTextOptional(stmt, 3)
        let date = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 4)))
        let plain = columnBlobString(stmt, 5) ?? ""
        let html = columnBlobString(stmt, 6) ?? ""
        let raw = columnBlobString(stmt, 7) ?? ""
        let messageType = columnTextOptional(stmt, 9).flatMap { $0.isEmpty ? nil : $0 } ?? "stored"
        let threadKey = columnTextOptional(stmt, 10)

        var headers: [String: String] = [:]
        if let hdata = columnBlobData(stmt, 8),
           let decoded = try? JSONDecoder().decode([String: String].self, from: hdata) {
            headers = decoded
        } else if let messageID { headers["Message-ID"] = messageID }

        return MBOXParser.RawEmail(
            id: id,
            headers: headers,
            rawSource: raw,
            messageType: messageType,
            attachments: [],
            timestamp: ISO8601DateFormatter().string(from: date),
            domains: [],
            plainBody: plain,
            htmlBody: html,
            mimeRoot: nil, mimeSummary: nil, mimeDiagnostics: [],
            threadID: threadKey ?? messageID,
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
    case open(String), exec(String), prepare(String), step(String), schema(String)
    var errorDescription: String? {
        switch self {
        case .open(let m): return "SQLite open failed: \(m)"
        case .exec(let m): return "SQLite exec failed: \(m)"
        case .prepare(let m): return "SQLite prepare failed: \(m)"
        case .step(let m): return "SQLite step failed: \(m)"
        case .schema(let m): return "SQLite schema error: \(m)"
        }
    }
}
