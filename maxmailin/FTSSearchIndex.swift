//
//  FTSSearchIndex.swift
//  maxmailin
//
//  SQLite FTS5 full-text search index — sharded by year to scale into the
//  billion-row regime that a 1 TB email archive requires.
//
//  Layout:
//      ~/Library/Application Support/com.ecosanskriti.mailin/fts5/
//          email_search_2024.db
//          email_search_2025.db
//          email_search_0.db          ← unknown / unparseable Date headers
//
//  Why shard:
//   • A single FTS5 file slows down past ~500M rows on consumer SSDs.
//   • Most user queries are time-bounded (recent quarter / year). Hitting one
//     shard is far faster than scanning a single monolithic index.
//   • Each shard stays under ~50 GB in practice; SQLite + APFS handle that
//     gracefully.
//   • Index can be `clear()`-ed per-shard if a particular year needs a
//     rebuild — no need to wipe everything.
//
//  Public API is **unchanged** from the pre-sharded version, so callers
//  (BulkImportCoordinator, MaxmailinSelfTest, etc.) work without
//  modification.
//
//  Pure-Swift, on-device, strictly local.
//

import Foundation
import SQLite3
import os.log

/// Compiles parsed user queries into valid FTS5 grammar. Leaf-term escaping is
/// separate from grammar generation: `escapeTerm` only quotes a single term;
/// the grammar methods own Boolean / prefix / `NEAR(...)` syntax. This keeps a
/// punctuated or quote-bearing term from ever breaking the FTS5 query.
enum FTSQueryBuilder {
    /// Quote a single leaf term (doubling any internal double-quotes).
    static func escapeTerm(_ term: String) -> String {
        "\"" + term.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// `term1 NEAR/n term2` → `NEAR("term1" "term2", n)`. Nil if either term is
    /// empty. Distance is clamped to ≥ 1.
    static func proximity(term1: String, term2: String, distance: Int) -> String? {
        let a = term1.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = term2.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty, !b.isEmpty else { return nil }
        return "NEAR(\(escapeTerm(a)) \(escapeTerm(b)), \(max(1, distance)))"
    }

    /// Free-text / Boolean: preserve AND/OR/NOT operators, quote every leaf
    /// term, and prefix-match the last term (`"budg"*` matches "budget"). Nil if
    /// there are no tokens.
    static func freeTextOrBoolean(_ raw: String) -> String? {
        let operators: Set<String> = ["AND", "OR", "NOT"]
        let tokens = raw.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard !tokens.isEmpty else { return nil }
        let lastTermIndex = tokens.lastIndex(where: { !operators.contains($0.uppercased()) })
        return tokens.enumerated().map { idx, tok in
            if operators.contains(tok.uppercased()) { return tok.uppercased() }
            let quoted = escapeTerm(tok)
            return idx == lastTermIndex ? quoted + "*" : quoted
        }.joined(separator: " ")
    }
}

/// Bounded, restartable store→FTS reconciliation. Pages `EmailStore` by keyset
/// cursor, checks the FTS registry per batch, indexes only genuinely-missing
/// rows, and persists a cursor after each page. No archive-wide `Set<UUID>`, no
/// fixed record ceiling; safe to interrupt and resume.
enum FTSReconciler {
    private static let cursorDateKey = "fts.reconcile.cursor.date"
    private static let cursorIDKey = "fts.reconcile.cursor.id"

    @discardableResult
    static func reconcile(pageSize: Int = 5_000, maxPages: Int? = nil) async -> Int {
        var beforeDate = loadCursorDate()
        var beforeID = loadCursorID()
        var indexed = 0
        var pages = 0
        while true {
            if Task.isCancelled { break }
            if let maxPages, pages >= maxPages { break }
            let page: [(id: UUID, date: Date)]
            do {
                page = try await EmailStore.shared.reconcilePage(beforeDate: beforeDate, beforeID: beforeID, limit: pageSize)
            } catch { break }
            if page.isEmpty { clearCursor(); break }               // exhausted
            let ids = page.map(\.id)
            let already = (try? await FTSSearchIndex.shared.indexedSubset(of: ids)) ?? Set(ids)
            let missing = ids.filter { !already.contains($0) }
            if !missing.isEmpty,
               let emails = try? await EmailStore.shared.emails(withIDs: missing),
               (try? await FTSSearchIndex.shared.indexBatch(emails)) != nil {
                indexed += emails.count
            }
            if let last = page.last {
                beforeDate = last.date
                beforeID = last.id
                saveCursor(date: last.date, id: last.id)           // restartable
            }
            pages += 1
            if page.count < pageSize { clearCursor(); break }      // exhausted
        }
        return indexed
    }

    static func resetCursorForTesting() { clearCursor() }

    private static func loadCursorDate() -> Date? {
        guard let d = UserDefaults.standard.object(forKey: cursorDateKey) as? Double else { return nil }
        return Date(timeIntervalSinceReferenceDate: d)
    }
    private static func loadCursorID() -> UUID? {
        UserDefaults.standard.string(forKey: cursorIDKey).flatMap(UUID.init(uuidString:))
    }
    private static func saveCursor(date: Date, id: UUID) {
        UserDefaults.standard.set(date.timeIntervalSinceReferenceDate, forKey: cursorDateKey)
        UserDefaults.standard.set(id.uuidString, forKey: cursorIDKey)
    }
    private static func clearCursor() {
        UserDefaults.standard.removeObject(forKey: cursorDateKey)
        UserDefaults.standard.removeObject(forKey: cursorIDKey)
    }
}

actor FTSSearchIndex {

    static let shared = FTSSearchIndex()

    private let logger = Logger(subsystem: "com.ecosanskriti.mailin",
                                category: "FTSSearchIndex")

    /// Open SQLite handles, keyed by year. `0` is the "unknown year" shard.
    private var shards: [Int: OpaquePointer] = [:]
    /// Monotonic counter used as an LRU tick for shard access tracking.
    private var lruCounter: UInt64 = 0
    /// Last-access tick per shard. Used by `evictIdleShards` to decide which
    /// handles to close under memory pressure.
    private var shardLastAccess: [Int: UInt64] = [:]
    private var didMigrateLegacy: Bool = false

    #if DEBUG
    /// Test-only: redirect FTS shards to a temp dir so tests are isolated from
    /// the real (sandbox-container) index.
    nonisolated(unsafe) static var testShardsDirectoryOverride: URL?
    /// Test-only: close open shard handles + reset in-memory state so the next
    /// access re-opens from the (possibly newly-overridden) directory.
    func resetForTesting() {
        for (_, handle) in shards { sqlite3_close(handle) }
        shards.removeAll()
        shardLastAccess.removeAll()
        didMigrateLegacy = false
    }
    #endif

    private init() {}

    /// Close every shard handle except the `keep` most-recently-accessed.
    /// Used by the memory-pressure handler to release SQLite page caches
    /// when the OS reports memory pressure. The shards re-open lazily on
    /// the next access — no data loss, just dropped in-memory state.
    func evictIdleShards(keep: Int) {
        guard shards.count > keep else { return }
        let ordered = shardLastAccess.sorted(by: { $0.value < $1.value })
        let toClose = ordered.prefix(shards.count - keep).map(\.key)
        for year in toClose {
            if let handle = shards[year] {
                sqlite3_close(handle)
            }
            shards.removeValue(forKey: year)
            shardLastAccess.removeValue(forKey: year)
        }
        logger.info("Evicted \(toClose.count) idle FTS shards under memory pressure.")
    }

    // MARK: - Public API (stable shape — preserves pre-sharded surface)

    func index(_ email: MBOXParser.RawEmail) throws {
        let year = Self.year(for: email)
        try insert(email, into: year)
    }

    /// Batched index. Groups emails by year so each shard runs a single
    /// transaction, which is dramatically faster than per-row commits.
    func indexBatch(_ emails: [MBOXParser.RawEmail]) throws {
        try migrateLegacyIfNeeded()
        // Bucket by year first.
        var byYear: [Int: [MBOXParser.RawEmail]] = [:]
        for email in emails {
            let y = Self.year(for: email)
            byYear[y, default: []].append(email)
        }
        for (year, group) in byYear {
            let db = try ensureShard(year: year)
            try exec(db, "BEGIN TRANSACTION;")
            do {
                for email in group {
                    try insertWithHandle(email, db: db)
                }
                try exec(db, "COMMIT;")
            } catch {
                try? exec(db, "ROLLBACK;")
                throw error
            }
        }
    }

    #if DEBUG
    /// Test-only: counts calls to `search` so a wiring test can assert the live
    /// search path actually reached FTS5 (vs. the in-RAM fallback). Reset
    /// immediately before the dispatch under observation, then assert `== 1`.
    private(set) var debugSearchCallCount = 0
    func resetDebugSearchCallCount() { debugSearchCallCount = 0 }
    #endif

    /// Plain user text → built FTS5 query (leaf terms escaped, prefix on the
    /// last term, AND/OR/NOT preserved) → `searchRaw`.
    func search(_ query: String, limit: Int = 50) throws -> [UUID] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let fts = FTSQueryBuilder.freeTextOrBoolean(trimmed) ?? FTSQueryBuilder.escapeTerm(trimmed)
        return try searchRaw(fts, limit: limit)
    }

    /// Execute an already-valid FTS5 query across every shard. The grammar
    /// (Boolean / prefix / `NEAR(...)`) is owned by the caller / FTSQueryBuilder;
    /// this does NOT escape. Returns matched UUIDs in bm25 order, capped.
    func searchRaw(_ ftsQuery: String, limit: Int = 50) throws -> [UUID] {
        #if DEBUG
        debugSearchCallCount += 1
        #endif
        try migrateLegacyIfNeeded()
        let trimmed = ftsQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let allShardYears = try discoverAllShardYears()

        // Per-shard heap: top `limit` rows from each shard, ranked by `rank`
        // (lower is more relevant in FTS5 bm25). We then merge across shards.
        struct Hit { let id: UUID; let rank: Double }
        var merged: [Hit] = []
        merged.reserveCapacity(limit * max(1, allShardYears.count))

        for year in allShardYears {
            let db = try ensureShard(year: year)
            let stmt = try prepare(db, """
                SELECT email_id, rank
                FROM email_search
                WHERE email_search MATCH ?
                ORDER BY rank
                LIMIT ?;
            """)
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, trimmed)
            sqlite3_bind_int(stmt, 2, Int32(limit))
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let cstr = sqlite3_column_text(stmt, 0) else { continue }
                let idStr = String(cString: cstr)
                guard let uuid = UUID(uuidString: idStr) else { continue }
                let rank = sqlite3_column_double(stmt, 1)
                merged.append(Hit(id: uuid, rank: rank))
            }
        }

        // Global top-N by rank. FTS5 bm25 ranks are not perfectly comparable
        // across shards but are calibrated enough for relevance ordering on
        // the scale we care about.
        return merged.sorted(by: { $0.rank < $1.rank })
            .prefix(limit)
            .map(\.id)
    }

    /// Remove every row from every shard. Files are kept (lighter than a
    /// full unlink, and the next insert re-uses the open handles).
    func clear() throws {
        try migrateLegacyIfNeeded()
        let years = try discoverAllShardYears()
        for year in years {
            let db = try ensureShard(year: year)
            try exec(db, "DELETE FROM email_search;")
            // Reset the registry too, or it would falsely report rows as indexed
            // after the FTS content is gone (store↔registry drift).
            try exec(db, "DELETE FROM indexed_message;")
            try exec(db, "VACUUM;")
        }
    }

    /// Drop and recreate. Rebuilds from the supplied emails using the same
    /// year-shard routing as `indexBatch`.
    func rebuild(from emails: [MBOXParser.RawEmail]) throws {
        try clear()
        try indexBatch(emails)
    }

    /// Remove a single email from every shard by its UUID. Call on delete /
    /// redaction so search never returns rows for content no longer present in
    /// the store (otherwise deleted/redacted emails linger as searchable
    /// "ghost rows").
    func delete(id: UUID) throws {
        try migrateLegacyIfNeeded()
        let idString = id.uuidString
        for year in try discoverAllShardYears() {
            let db = try ensureShard(year: year)
            try exec(db, "BEGIN TRANSACTION;")
            do {
                let stmt = try prepare(db, "DELETE FROM email_search WHERE email_id = ?;")
                bindText(stmt, 1, idString)
                let ok1 = sqlite3_step(stmt) == SQLITE_DONE
                sqlite3_finalize(stmt)
                guard ok1 else { throw FTSError.execFailed(lastError(db)) }

                let reg = try prepare(db, "DELETE FROM indexed_message WHERE email_id = ?;")
                bindText(reg, 1, idString)
                let ok2 = sqlite3_step(reg) == SQLITE_DONE
                sqlite3_finalize(reg)
                guard ok2 else { throw FTSError.execFailed(lastError(db)) }

                try exec(db, "COMMIT;")
            } catch {
                try? exec(db, "ROLLBACK;")
                throw error
            }
        }
    }

    /// Total rows summed across every shard.
    func rowCount() throws -> Int {
        try migrateLegacyIfNeeded()
        var total = 0
        for year in try discoverAllShardYears() {
            let db = try ensureShard(year: year)
            let stmt = try prepare(db, "SELECT COUNT(*) FROM email_search;")
            defer { sqlite3_finalize(stmt) }
            if sqlite3_step(stmt) == SQLITE_ROW {
                total += Int(sqlite3_column_int(stmt, 0))
            }
        }
        return total
    }

    /// All email UUIDs currently in the index (across every shard).
    func allIndexedIDs() throws -> Set<UUID> {
        try migrateLegacyIfNeeded()
        var ids = Set<UUID>()
        for year in try discoverAllShardYears() {
            let db = try ensureShard(year: year)
            let stmt = try prepare(db, "SELECT email_id FROM email_search;")
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 0),
                   let u = UUID(uuidString: String(cString: c)) {
                    ids.insert(u)
                }
            }
        }
        return ids
    }

    private func hasAnyRow(_ db: OpaquePointer, _ table: String) throws -> Bool {
        let stmt = try prepare(db, "SELECT EXISTS(SELECT 1 FROM \(table) LIMIT 1);")
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_int(stmt, 0) == 1
    }

    /// Of the given ids, which are already indexed (present in any shard's
    /// registry). Bounded — the `IN (...)` clause is chunked; no archive-wide
    /// Set is built. Used by paged reconciliation.
    func indexedSubset(of ids: [UUID]) throws -> Set<UUID> {
        try migrateLegacyIfNeeded()
        guard !ids.isEmpty else { return [] }
        var found = Set<UUID>()
        let idStrings = ids.map { $0.uuidString }
        for year in try discoverAllShardYears() {
            let db = try ensureShard(year: year)
            var start = 0
            while start < idStrings.count {
                let end = min(start + 900, idStrings.count)
                let chunk = Array(idStrings[start..<end])
                start = end
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                let stmt = try prepare(db, "SELECT email_id FROM indexed_message WHERE email_id IN (\(placeholders));")
                defer { sqlite3_finalize(stmt) }
                for (i, s) in chunk.enumerated() { bindText(stmt, Int32(i + 1), s) }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let c = sqlite3_column_text(stmt, 0), let u = UUID(uuidString: String(cString: c)) {
                        found.insert(u)
                    }
                }
            }
        }
        return found
    }

    /// Index only the emails not already present — repairs store↔FTS drift
    /// (e.g. a crash between the store commit and the FTS commit leaves a row
    /// in the store but unsearchable). Idempotent; returns the count newly
    /// indexed.
    func indexMissing(from emails: [MBOXParser.RawEmail]) throws -> Int {
        let existing = try allIndexedIDs()
        let missing = emails.filter { !existing.contains($0.id) }
        if !missing.isEmpty { try indexBatch(missing) }
        return missing.count
    }

    // MARK: - Shard management

    /// Soft cap on simultaneously-open shard handles. Each open handle pins
    /// SQLite page caches (typically tens of MB). 20 is enough to cover the
    /// "search across a decade" use case without leaking handles in the
    /// hypothetical 50-year archive. The actual file count on disk is
    /// unbounded; this only caps OPEN handles.
    private let maxOpenShards = 20

    private func ensureShard(year: Int) throws -> OpaquePointer {
        if let existing = shards[year] {
            lruCounter &+= 1
            shardLastAccess[year] = lruCounter
            return existing
        }
        try migrateLegacyIfNeeded()

        // Proactive LRU eviction: if opening this shard would push us past
        // the soft cap, close the least-recently-used one before opening
        // the new one. Independent of (and additive to) the memory-pressure
        // path in `evictIdleShards` — that one only fires under OS
        // pressure; this one keeps steady-state usage bounded.
        if shards.count >= maxOpenShards {
            evictIdleShards(keep: maxOpenShards - 1)
        }

        let url = try shardURL(year: year)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var db: OpaquePointer?
        let rc = sqlite3_open_v2(
            url.path,
            &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard rc == SQLITE_OK, let db else {
            throw FTSError.openFailed("sqlite3_open_v2 rc=\(rc) for shard \(year)")
        }
        try exec(db, "PRAGMA journal_mode = WAL;")
        try exec(db, "PRAGMA synchronous = NORMAL;")
        try exec(db, """
            CREATE VIRTUAL TABLE IF NOT EXISTS email_search USING fts5(
                email_id UNINDEXED,
                subject,
                sender,
                recipients,
                body,
                tokenize='porter unicode61 remove_diacritics 1'
            );
        """)
        // Registry beside the FTS shard: which email_ids are indexed and at what
        // revision. Written in the SAME transaction as FTS mutations. Lets
        // reconciliation check membership in bounded batches instead of building
        // an archive-wide Set<UUID>. `indexed_revision`/`content_hash` are the
        // future-proof scaffold for stale-content reindex (redaction etc.).
        try exec(db, """
            CREATE TABLE IF NOT EXISTS indexed_message(
                email_id TEXT PRIMARY KEY,
                indexed_revision INTEGER NOT NULL DEFAULT 1,
                content_hash TEXT,
                indexed_at INTEGER NOT NULL DEFAULT 0
            );
        """)
        // One-time backfill for shards indexed before the registry existed.
        if try !hasAnyRow(db, "indexed_message"), try hasAnyRow(db, "email_search") {
            try exec(db, "INSERT OR IGNORE INTO indexed_message(email_id, indexed_revision, indexed_at) SELECT email_id, 1, 0 FROM email_search;")
        }
        shards[year] = db
        lruCounter &+= 1
        shardLastAccess[year] = lruCounter
        logger.info("Opened FTS shard for year \(year)")
        return db
    }

    /// Walk the shards directory and union together open + on-disk shard
    /// years. Open shards are always returned; on-disk files for years we
    /// haven't opened yet are included so search hits historical data.
    private func discoverAllShardYears() throws -> [Int] {
        var years = Set(shards.keys)
        let dir = try shardsDirectory()
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) {
            for url in contents {
                let name = url.deletingPathExtension().lastPathComponent
                let prefix = "email_search_"
                guard name.hasPrefix(prefix) else { continue }
                let suffix = String(name.dropFirst(prefix.count))
                if let y = Int(suffix) { years.insert(y) }
            }
        }
        return years.sorted()
    }

    private func insert(_ email: MBOXParser.RawEmail, into year: Int) throws {
        try migrateLegacyIfNeeded()
        let db = try ensureShard(year: year)
        try insertWithHandle(email, db: db)
    }

    private func insertWithHandle(_ email: MBOXParser.RawEmail, db: OpaquePointer) throws {
        let stmt = try prepare(db, """
            INSERT INTO email_search (email_id, subject, sender, recipients, body)
            VALUES (?, ?, ?, ?, ?);
        """)
        defer { sqlite3_finalize(stmt) }

        let idString = email.id.uuidString
        let subject = email.headers["Subject"] ?? ""
        let sender = email.headers["From"] ?? ""
        let recipients = (email.headers["To"] ?? "") + " " + (email.headers["Cc"] ?? "")
        let body = email.plainBody.isEmpty
            ? stripHTML(email.htmlBody)
            : email.plainBody

        bindText(stmt, 1, idString)
        bindText(stmt, 2, subject)
        bindText(stmt, 3, sender)
        bindText(stmt, 4, recipients)
        bindText(stmt, 5, String(body.prefix(50_000)))

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw FTSError.execFailed(lastError(db))
        }

        // Registry upsert — same transaction as the FTS insert (indexBatch wraps
        // the shard group in BEGIN/COMMIT), so the two never drift.
        let reg = try prepare(db, """
            INSERT OR REPLACE INTO indexed_message(email_id, indexed_revision, content_hash, indexed_at)
            VALUES (?, 1, NULL, ?);
        """)
        defer { sqlite3_finalize(reg) }
        bindText(reg, 1, idString)
        sqlite3_bind_int64(reg, 2, Int64(Date().timeIntervalSince1970))
        guard sqlite3_step(reg) == SQLITE_DONE else {
            throw FTSError.execFailed(lastError(db))
        }
    }

    // MARK: - Legacy single-file migration

    /// If the previous monolithic `fts5_search.db` is present in App
    /// Support, move it under the new shards directory as the "year 0"
    /// (unknown) shard. Idempotent and silent if nothing to migrate.
    private func migrateLegacyIfNeeded() throws {
        if didMigrateLegacy { return }
        defer { didMigrateLegacy = true }

        let legacy = try legacySingleFileURL()
        let target = try shardURL(year: 0)
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacy.path) else { return }
        try fm.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fm.fileExists(atPath: target.path) {
            // Don't overwrite an existing year-0 shard. Append legacy data
            // by way of side-by-side rename instead; user can rebuild if
            // needed. We simply remove the orphan to avoid confusion.
            try? fm.removeItem(at: legacy)
        } else {
            try fm.moveItem(at: legacy, to: target)
            logger.info("Migrated legacy fts5_search.db -> year-0 shard")
        }
    }

    // MARK: - Year extraction

    private static func year(for email: MBOXParser.RawEmail) -> Int {
        guard let raw = email.headers["Date"],
              let date = MBOXParser.parseDate(raw) else { return 0 }
        let cal = Calendar(identifier: .gregorian)
        let y = cal.component(.year, from: date)
        // Calendar can return zero or negative years for pre-AD dates or
        // unparseable date components that survive parseDate. Treat any
        // non-positive or implausibly-far-future year as "unknown" so we
        // don't produce shard filenames like `email_search_-2.db` or
        // route to a year we'd never see again.
        guard y > 1900, y < 2200 else { return 0 }
        return y
    }

    // MARK: - URLs

    private func shardsDirectory() throws -> URL {
        #if DEBUG
        if let override = FTSSearchIndex.testShardsDirectoryOverride {
            try? FileManager.default.createDirectory(at: override, withIntermediateDirectories: true)
            return override
        }
        #endif
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return appSupport
            .appendingPathComponent("com.ecosanskriti.mailin", isDirectory: true)
            .appendingPathComponent("fts5", isDirectory: true)
    }

    private func shardURL(year: Int) throws -> URL {
        try shardsDirectory()
            .appendingPathComponent("email_search_\(year).db")
    }

    private func legacySingleFileURL() throws -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return appSupport
            .appendingPathComponent("com.ecosanskriti.mailin", isDirectory: true)
            .appendingPathComponent("fts5_search.db")
    }

    // MARK: - SQLite helpers (handle-aware)

    private func exec(_ db: OpaquePointer, _ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "sqlite3_exec rc=\(rc)"
            sqlite3_free(errMsg)
            throw FTSError.execFailed(msg)
        }
    }

    private func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        if rc != SQLITE_OK {
            throw FTSError.execFailed(lastError(db))
        }
        return stmt
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, index, value, -1, transient)
    }

    private func lastError(_ db: OpaquePointer) -> String {
        guard let cstr = sqlite3_errmsg(db) else { return "unknown error" }
        return String(cString: cstr)
    }

    /// Quote individual terms so punctuation can't break FTS5, while letting
    /// the boolean operators AND / OR / NOT survive as operators rather than
    /// being swallowed into a single quoted phrase. (Proximity `NEAR(...)` is
    /// built upstream by the query builder, not here.)
    private func stripHTML(_ html: String) -> String {
        guard !html.isEmpty else { return "" }
        let pattern = "<[^>]+>"
        let regex = try? NSRegularExpression(pattern: pattern, options: [])
        let range = NSRange(location: 0, length: html.utf16.count)
        let cleaned = regex?.stringByReplacingMatches(
            in: html, options: [], range: range, withTemplate: " "
        ) ?? html
        return cleaned
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    enum FTSError: LocalizedError {
        case openFailed(String)
        case execFailed(String)

        var errorDescription: String? {
            switch self {
            case .openFailed(let d): return "FTS5 open failed: \(d)"
            case .execFailed(let d): return "FTS5 query failed: \(d)"
            }
        }
    }
}
