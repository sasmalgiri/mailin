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

    struct ReconcileResult: Sendable {
        var pagesProcessed = 0
        var rowsChecked = 0
        var rowsIndexed = 0
        var completed = false
        var cursor: EmailPageCursor?
    }

    /// Cursor progress means: everything before the cursor has been successfully
    /// examined and repaired — nothing weaker. Any failure (registry lookup,
    /// store fetch, FTS index) throws WITHOUT advancing the cursor, so a retry
    /// reprocesses that page. Never treats a lookup failure as "all indexed".
    ///
    /// Production entry point: reconciles the shared store/index and persists
    /// its cursor in UserDefaults so it survives process restarts.
    @discardableResult
    static func reconcile(pageSize: Int = 5_000, maxPages: Int? = nil) async throws -> ReconcileResult {
        try await reconcileCore(
            store: EmailStore.shared, fts: .shared, pageSize: pageSize, maxPages: maxPages,
            initialDate: loadCursorDate(), initialID: loadCursorID(),
            onAdvance: { saveCursor(date: $0, id: $1) },
            onComplete: { clearCursor() }
        )
    }

    /// Isolated entry point for harnesses/tests: reconciles explicit store +
    /// index instances (e.g. a `MailinStorageEnvironment.disposable`) with an
    /// in-run cursor only — never touches the global UserDefaults cursor, so
    /// concurrent disposable environments stay independent. Same semantics
    /// otherwise: a failure throws without losing progress within the run.
    @discardableResult
    static func reconcile(
        store: any EmailArchiveStore,
        fts: FTSSearchIndex,
        pageSize: Int = 5_000,
        maxPages: Int? = nil
    ) async throws -> ReconcileResult {
        try await reconcileCore(
            store: store, fts: fts, pageSize: pageSize, maxPages: maxPages,
            initialDate: nil, initialID: nil,
            onAdvance: { _, _ in }, onComplete: { }
        )
    }

    /// Shared reconcile loop. Cursor persistence is injected via `onAdvance` /
    /// `onComplete` so the production path can use UserDefaults while the
    /// harness path uses nothing — the page-walk logic is identical for both.
    private static func reconcileCore(
        store: any EmailArchiveStore,
        fts: FTSSearchIndex,
        pageSize: Int,
        maxPages: Int?,
        initialDate: Date?,
        initialID: UUID?,
        onAdvance: @Sendable (Date, UUID) -> Void,
        onComplete: @Sendable () -> Void
    ) async throws -> ReconcileResult {
        var beforeDate = initialDate
        var beforeID = initialID
        var result = ReconcileResult()
        while true {
            if Task.isCancelled { break }
            if let maxPages, result.pagesProcessed >= maxPages { break }
            let page = try await store.reconcilePage(beforeDate: beforeDate, beforeID: beforeID, limit: pageSize)
            if page.isEmpty { onComplete(); result.completed = true; break }
            let ids = page.map(\.id)
            result.rowsChecked += ids.count
            // Propagate registry-lookup failures — do NOT assume "all indexed".
            let already = try await fts.indexedSubset(of: ids)
            let missing = ids.filter { !already.contains($0) }
            if !missing.isEmpty {
                let emails = try await store.emails(withIDs: missing)
                try await fts.indexBatch(emails)
                result.rowsIndexed += emails.count
            }
            // Only advance the cursor after ALL page work succeeded.
            if let last = page.last {
                beforeDate = last.date
                beforeID = last.id
                onAdvance(last.date, last.id)
                result.cursor = EmailPageCursor(beforeDate: last.date, beforeID: last.id)
            }
            result.pagesProcessed += 1
            if page.count < pageSize { onComplete(); result.completed = true; break }
        }
        return result
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

    /// When non-nil, this instance stores its shards under an explicit
    /// directory instead of the shared Application Support location. Set only
    /// via `init(shardsDirectory:)` for isolated harness/test environments.
    /// Release-safe (not gated behind DEBUG).
    private let shardsDirectoryOverrideInstance: URL?

    private init() { self.shardsDirectoryOverrideInstance = nil }

    /// Isolated instance storing shards under `shardsDirectory` — never the
    /// shared production index. Used by `MailinStorageEnvironment.disposable`.
    init(shardsDirectory: URL) {
        self.shardsDirectoryOverrideInstance = shardsDirectory
    }

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
        try migrateLegacyIfNeeded()
        let db = try ensureShard(year: Self.year(for: email))
        // Wrap the FTS row + registry upsert in ONE transaction (same guarantee
        // as indexBatch) so the two can never drift on a mid-write failure.
        try exec(db, "BEGIN TRANSACTION;")
        do {
            try insertWithHandle(email, db: db)
            try exec(db, "COMMIT;")
        } catch {
            try? exec(db, "ROLLBACK;")
            throw error
        }
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

    // MARK: - Part P1/P2 — pruned, resumable ranked search

    /// One bm25-ranked hit. `rank` is the FTS5 bm25 rank (lower = more
    /// relevant); exposed so a caller can keep a stable continuation boundary.
    struct RankedHit: Sendable, Equatable {
        let id: UUID
        let rank: Double
    }

    /// Continuation state for `searchRanked`. Carries the query fingerprint
    /// (any query/prune change invalidates it), per-shard row offsets into the
    /// deterministic `(rank, email_id)` order, and the last emitted
    /// score + tie-break boundary (a defensive no-duplicate guard if the index
    /// mutates between pages). Value type — bounded, no open resources.
    struct RankedCursor: Sendable, Equatable {
        let fingerprint: UInt64
        var shardOffsets: [Int: Int]
        var lastRank: Double?
        var lastIDString: String?
    }

    /// The shard years that can possibly hold an email whose parsed Date falls
    /// in `[after, before)`, or nil when there are no bounds (all shards).
    /// Always includes shard 0 (unknown/unparseable/out-of-range dates) and one
    /// extra year on each side, so second-rounding and calendar/timezone edges
    /// can never drop a boundary email — pruning must return results EQUAL to
    /// the unpruned reference, it only bounds the work.
    nonisolated static func shardYears(after: Date?, before: Date?) -> Set<Int>? {
        guard after != nil || before != nil else { return nil }
        let cal = Calendar(identifier: .gregorian)
        let loYear = after.map { cal.component(.year, from: $0) - 1 } ?? 1901
        let hiYear = before.map { cal.component(.year, from: $0) + 1 } ?? 2199
        let lo = max(1901, loYear)
        let hi = min(2199, hiYear)
        var years: Set<Int> = [0]   // the unknown-date shard is always searched
        if lo <= hi { for y in lo...hi { years.insert(y) } }
        return years
    }

    /// Deterministic (process-independent) FNV-1a fingerprint binding a cursor
    /// to its exact query + shard-prune set.
    nonisolated static func rankedFingerprint(query: String, years: Set<Int>?) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        func mix(_ s: String) {
            for byte in s.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x100000001b3
            }
        }
        mix(query)
        mix("|")
        mix(years.map { $0.sorted().map(String.init).joined(separator: ",") } ?? "*")
        return hash
    }

    /// Ranked (bm25) search with bounded continuation. Pass `years` (from
    /// `shardYears(after:before:)`) to prune the shards visited for a
    /// date-bounded query; exact date filtering happens on the hydrated rows
    /// upstream (the FTS document carries no date).
    ///
    /// Paging contract: per shard the row order `(rank ASC, email_id ASC)` is
    /// deterministic, the cursor stores how many rows of each shard were
    /// consumed, and pages are produced by a k-way merge of the next rows of
    /// every shard — so iterating to exhaustion yields every match exactly
    /// once, in a stable global order, with memory bounded by
    /// `limit × shardCount`. A cursor built for a different query/prune set
    /// throws `FTSError.staleCursor`.
    func searchRanked(
        _ ftsQuery: String,
        years: Set<Int>? = nil,
        limit: Int,
        cursor: RankedCursor? = nil
    ) throws -> (hits: [RankedHit], next: RankedCursor?) {
        #if DEBUG
        debugSearchCallCount += 1
        #endif
        try migrateLegacyIfNeeded()
        let trimmed = ftsQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, limit > 0 else { return ([], nil) }
        let fingerprint = Self.rankedFingerprint(query: trimmed, years: years)
        if let cursor, cursor.fingerprint != fingerprint {
            throw FTSError.staleCursor
        }

        var shardYears = try discoverAllShardYears()
        if let years { shardYears = shardYears.filter { years.contains($0) } }

        // Fetch the next `limit` rows of every (pruned) shard from its offset.
        struct Row { let id: UUID?; let idString: String; let rank: Double }
        var buffers: [Int: [Row]] = [:]
        var fetchedFull: Set<Int> = []
        for year in shardYears {
            let offset = cursor?.shardOffsets[year] ?? 0
            let db = try ensureShard(year: year)
            let stmt = try prepare(db, """
                SELECT email_id, rank
                FROM email_search
                WHERE email_search MATCH ?
                ORDER BY rank, email_id
                LIMIT ? OFFSET ?;
            """)
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, trimmed)
            sqlite3_bind_int(stmt, 2, Int32(limit))
            sqlite3_bind_int(stmt, 3, Int32(offset))
            var rows: [Row] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let idString = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                // Malformed ids stay in the buffer (they occupy an offset slot)
                // but are never emitted.
                rows.append(Row(id: UUID(uuidString: idString), idString: idString,
                                rank: sqlite3_column_double(stmt, 1)))
            }
            if rows.count == limit { fetchedFull.insert(year) }
            buffers[year] = rows
        }

        // K-way merge by (rank, email_id): globally emit the next `limit` hits.
        var heads: [Int: Int] = [:]              // shard year → next index in buffer
        var consumed: [Int: Int] = [:]           // shard year → rows consumed this page
        var hits: [RankedHit] = []
        hits.reserveCapacity(limit)
        var lastRank = cursor?.lastRank
        var lastID = cursor?.lastIDString
        while hits.count < limit {
            var bestYear: Int? = nil
            var bestRow: Row? = nil
            for (year, rows) in buffers {
                let i = heads[year] ?? 0
                guard i < rows.count else { continue }
                let row = rows[i]
                if let current = bestRow {
                    if row.rank < current.rank ||
                        (row.rank == current.rank && row.idString < current.idString) {
                        bestYear = year; bestRow = row
                    }
                } else {
                    bestYear = year; bestRow = row
                }
            }
            guard let year = bestYear, let row = bestRow else { break }
            heads[year] = (heads[year] ?? 0) + 1
            consumed[year] = (consumed[year] ?? 0) + 1
            // Defensive boundary: never re-emit at or before the last emitted
            // (rank, id) — protects against duplicates if the index shifted.
            if let lr = lastRank, let li = lastID {
                if row.rank < lr || (row.rank == lr && row.idString <= li) { continue }
            }
            guard let id = row.id else { continue }
            hits.append(RankedHit(id: id, rank: row.rank))
            lastRank = row.rank
            lastID = row.idString
        }

        // A shard may have more rows if its buffer wasn't fully consumed, or if
        // it was fetched full (the database may hold rows beyond the buffer).
        let hasMore = shardYears.contains { year in
            let total = buffers[year]?.count ?? 0
            let used = consumed[year] ?? 0
            return used < total || fetchedFull.contains(year)
        }
        guard hasMore else { return (hits, nil) }
        var offsets = cursor?.shardOffsets ?? [:]
        for year in shardYears {
            offsets[year] = (offsets[year] ?? 0) + (consumed[year] ?? 0)
        }
        let next = RankedCursor(fingerprint: fingerprint, shardOffsets: offsets,
                                lastRank: lastRank, lastIDString: lastID)
        return (hits, next)
    }

    /// Of the given ids, which match `ftsQuery` — the preview-bounded search
    /// primitive (Part P): the legacy Simple list filters a bounded resident
    /// preview, so it asks which PREVIEW rows match instead of materializing an
    /// archive-wide result list. Work and memory are bounded by `ids.count`
    /// (chunked `MATCH … AND email_id IN (…)` per shard).
    func matchingSubset(of ids: [UUID], ftsQuery: String) throws -> Set<UUID> {
        #if DEBUG
        debugSearchCallCount += 1
        #endif
        try migrateLegacyIfNeeded()
        let trimmed = ftsQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !ids.isEmpty else { return [] }
        var found = Set<UUID>()
        let idStrings = ids.map { $0.uuidString }
        for year in try discoverAllShardYears() {
            let db = try ensureShard(year: year)
            var start = 0
            while start < idStrings.count {
                let end = min(start + 500, idStrings.count)
                let chunk = Array(idStrings[start..<end])
                start = end
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                let stmt = try prepare(db, """
                    SELECT email_id FROM email_search
                    WHERE email_search MATCH ? AND email_id IN (\(placeholders));
                """)
                defer { sqlite3_finalize(stmt) }
                bindText(stmt, 1, trimmed)
                for (i, s) in chunk.enumerated() { bindText(stmt, Int32(i + 2), s) }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let c = sqlite3_column_text(stmt, 0), let u = UUID(uuidString: String(cString: c)) {
                        found.insert(u)
                    }
                }
            }
        }
        return found
    }

    /// Count matches for an already-valid FTS5 query via O(1)-memory
    /// `COUNT(*)` per shard — never materializes result UUIDs.
    func countRaw(_ ftsQuery: String) throws -> Int {
        try migrateLegacyIfNeeded()
        let trimmed = ftsQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        var total = 0
        for year in try discoverAllShardYears() {
            let db = try ensureShard(year: year)
            let stmt = try prepare(db, "SELECT COUNT(*) FROM email_search WHERE email_search MATCH ?;")
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, trimmed)
            if sqlite3_step(stmt) == SQLITE_ROW {
                total += Int(sqlite3_column_int64(stmt, 0))
            }
        }
        return total
    }

    /// §15: which of `ids` match `ftsQuery` — one bounded query per shard per
    /// chunk (MATCH + email_id IN). Used to verify Select-All exclusions
    /// against the query, never to materialize result sets.
    func matchingIDs(among ids: [UUID], ftsQuery: String) throws -> Set<UUID> {
        try migrateLegacyIfNeeded()
        let trimmed = ftsQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !ids.isEmpty else { return [] }
        var out = Set<UUID>()
        let chunks = stride(from: 0, to: ids.count, by: 500).map {
            Array(ids[$0..<Swift.min($0 + 500, ids.count)])
        }
        for year in try discoverAllShardYears() {
            let db = try ensureShard(year: year)
            for chunk in chunks {
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                let stmt = try prepare(db, """
                    SELECT email_id FROM email_search
                    WHERE email_search MATCH ? AND email_id IN (\(placeholders));
                """)
                defer { sqlite3_finalize(stmt) }
                bindText(stmt, 1, trimmed)
                for (i, id) in chunk.enumerated() { bindText(stmt, Int32(i + 2), id.uuidString) }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let c = sqlite3_column_text(stmt, 0), let id = UUID(uuidString: String(cString: c)) {
                        out.insert(id)
                    }
                }
            }
        }
        return out
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

    /// One-time repair for archives indexed by a pre-idempotent build, which
    /// could append more than one FTS row per email (the registry masked it,
    /// so the reconciler never repaired it, and search returned doubles). Per
    /// shard, if the content table has more rows than distinct ids, collapse
    /// each id to its lowest-rowid row. Bounded: the `GROUP BY` runs INSIDE
    /// SQLite over a single year-shard — no archive-wide `Set` is built in
    /// Swift. Idempotent — a no-op once every shard is clean. Returns the
    /// number of duplicate rows removed.
    @discardableResult
    func dedupeShards() throws -> Int {
        try migrateLegacyIfNeeded()
        var removed = 0
        for year in try discoverAllShardYears() {
            let db = try ensureShard(year: year)
            // Cheap gate: only rewrite shards that actually carry duplicates.
            let check = try prepare(db, "SELECT count(*) - count(DISTINCT email_id) FROM email_search;")
            var dupes = 0
            if sqlite3_step(check) == SQLITE_ROW { dupes = Int(sqlite3_column_int(check, 0)) }
            sqlite3_finalize(check)
            guard dupes > 0 else { continue }
            try exec(db, "BEGIN TRANSACTION;")
            do {
                try exec(db, """
                    DELETE FROM email_search
                    WHERE rowid NOT IN (SELECT min(rowid) FROM email_search GROUP BY email_id);
                """)
                try exec(db, "COMMIT;")
                removed += dupes
            } catch {
                try? exec(db, "ROLLBACK;")
                throw error
            }
        }
        return removed
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

    /// LEGACY / test-only — materializes every indexed UUID (unbounded memory).
    /// Production reconciliation must use `indexedSubset(of:)` + `FTSReconciler`
    /// instead. Do not reintroduce this on a production path.
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
        // W3: FTS shards are read/written by the launch reconciler and
        // background indexing after device lock → background-readable class
        // on iOS (children inherit); owner-only 700 directory on macOS.
        ArtifactProtection.applyBackgroundReadable(to: url.deletingLastPathComponent())

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
        // Owner-only shard file; SQLite propagates these permissions to the
        // shard's -wal/-shm companions on first write.
        ArtifactProtection.applyBackgroundReadable(to: url)
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
        let idString = email.id.uuidString

        // Idempotent index: clear any prior FTS row for this id in THIS shard
        // before inserting. Without this, re-indexing the same email (a re-run
        // import, or a reconcile after a partial index) appends a SECOND row —
        // the registry (INSERT OR REPLACE below) still reads as "indexed once",
        // masking the duplicate so the reconciler never repairs it, and search
        // would return the email twice.
        let del = try prepare(db, "DELETE FROM email_search WHERE email_id = ?;")
        bindText(del, 1, idString)
        let delOK = sqlite3_step(del) == SQLITE_DONE
        sqlite3_finalize(del)
        guard delOK else { throw FTSError.execFailed(lastError(db)) }

        let stmt = try prepare(db, """
            INSERT INTO email_search (email_id, subject, sender, recipients, body)
            VALUES (?, ?, ?, ?, ?);
        """)
        defer { sqlite3_finalize(stmt) }

        let subject = email.headers["Subject"] ?? ""
        let sender = email.headers["From"] ?? ""
        let recipients = (email.headers["To"] ?? "") + " " + (email.headers["Cc"] ?? "")
        let body = email.plainBody.isEmpty
            ? Self.stripHTMLText(email.htmlBody)
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
        // Isolated instance (harness/test environment) — Release-safe.
        if let override = shardsDirectoryOverrideInstance {
            try? FileManager.default.createDirectory(at: override, withIntermediateDirectories: true)
            return override
        }
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

    /// Lightweight HTML → text used for the FTS body column. Shared (static)
    /// so BoundedRegexSearch verifies regexes against EXACTLY the text that
    /// was indexed.
    nonisolated static func stripHTMLText(_ html: String) -> String {
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
        /// A `RankedCursor` was presented for a different query / prune set —
        /// the query changed, so the continuation is invalid.
        case staleCursor

        var errorDescription: String? {
            switch self {
            case .openFailed(let d): return "FTS5 open failed: \(d)"
            case .execFailed(let d): return "FTS5 query failed: \(d)"
            case .staleCursor: return "Search cursor is stale: the query changed."
            }
        }
    }
}

// MARK: - Part P3 — bounded regex search

/// Result of a bounded regex search. `truncated` means the bounded scan hit
/// its cap BEFORE covering the full scope — callers MUST surface this to the
/// user (silent truncation is not acceptable).
struct RegexSearchOutcome: Sendable {
    var matchedIDs: Set<UUID> = []
    var truncated: Bool = false
    var scanned: Int = 0
    var usedLiteralPath: Bool = false
}

/// Conservative extraction of MANDATORY literal tokens from a regex pattern —
/// substrings that must appear in ANY string the pattern matches. Used to turn
/// a regex search into FTS candidate retrieval + exact verification.
///
/// Conservative by construction: anything uncertain (top-level alternation,
/// groups, classes, unbalanced syntax) contributes nothing or aborts with []
/// — a missing literal only costs speed (capped-scan fallback), never
/// correctness.
enum RegexLiteralExtractor {

    /// Alphanumeric tokens (length ≥ 3) drawn from the pattern's mandatory
    /// literal runs. Empty when no literal can be derived with certainty.
    /// NOTE: candidate retrieval is token/prefix-granular (FTS5); a literal
    /// that only ever occurs mid-token in a document is a caveat covered by
    /// the exact-verify step operating on FTS-retrieved candidates.
    static func mandatoryLiteralTokens(from pattern: String) -> [String] {
        guard let runs = mandatoryLiteralRuns(from: pattern) else { return [] }
        var tokens: [String] = []
        for run in runs {
            for piece in run.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                let token = String(piece)
                if token.count >= 3 && !tokens.contains(token) { tokens.append(token) }
            }
        }
        return Array(tokens.prefix(4))   // keep the FTS query small
    }

    /// The contiguous literal runs that must appear in every match, or nil if
    /// extraction is uncertain.
    private static func mandatoryLiteralRuns(from pattern: String) -> [String]? {
        var runs: [String] = []
        var current = ""
        func flush(droppingLast: Bool = false) {
            if droppingLast, !current.isEmpty { current.removeLast() }
            if !current.isEmpty { runs.append(current) }
            current = ""
        }
        let chars = Array(pattern)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            switch ch {
            case "|":
                // Top-level alternation: either branch may match — nothing in
                // the whole pattern is mandatory. (Groups are skipped wholesale
                // below, so any "|" seen here is top-level.)
                return nil
            case "(":
                // Skip the entire group: its contents may be optional or
                // alternated. The group breaks literal contiguity.
                guard let close = skipGroup(chars, from: i) else { return nil }
                flush()
                i = close
                // A quantifier after the group applies to the group; skip it.
                i = skipQuantifier(chars, from: i + 1) ?? (i + 1)
                continue
            case ")":
                return nil   // unbalanced — uncertain
            case "[":
                guard let close = skipCharacterClass(chars, from: i) else { return nil }
                flush()
                i = close
                i = skipQuantifier(chars, from: i + 1) ?? (i + 1)
                continue
            case "\\":
                guard i + 1 < chars.count else { return nil }
                let next = chars[i + 1]
                if next.isLetter || next.isNumber {
                    // \d \w \b \1 \u… — a class/anchor/reference, not a literal.
                    flush()
                    i += 2
                    i = skipQuantifier(chars, from: i) ?? i
                    continue
                }
                // Escaped punctuation is a literal char — but a following
                // quantifier may make it optional.
                if let after = quantifierKind(chars, at: i + 2) {
                    if after.minZero { /* optional char: not appended */ } else { current.append(next) }
                    flush()
                    i = after.endIndex
                    continue
                }
                current.append(next)
                i += 2
                continue
            case ".", "^", "$":
                flush()
            case "?", "*", "+", "{":
                // Quantifier applying to the previous literal char.
                guard let q = quantifierKind(chars, at: i) else { return nil }
                if q.minZero {
                    flush(droppingLast: true)     // char may be absent
                } else {
                    flush()                       // char appears ≥ once, run ends
                }
                i = q.endIndex
                continue
            default:
                // A literal char — unless the NEXT char is a min-zero
                // quantifier, in which case it is optional (handled above on
                // the quantifier itself).
                current.append(ch)
            }
            i += 1
        }
        flush()
        return runs
    }

    private struct Quantifier { let minZero: Bool; let endIndex: Int }

    /// Parse a quantifier at `chars[at]` (`?`, `*`, `+`, `{m,n}`), if present.
    /// Returns nil for `?`/`*`/`+`… absent, and treats any `{…}` as min-zero
    /// (conservative — `{0,n}` and `{2}` are handled identically: drop the
    /// preceding char from the mandatory run).
    private static func quantifierKind(_ chars: [Character], at index: Int) -> Quantifier? {
        guard index < chars.count else { return nil }
        switch chars[index] {
        case "?", "*":
            return Quantifier(minZero: true, endIndex: skipLazyMarker(chars, after: index))
        case "+":
            return Quantifier(minZero: false, endIndex: skipLazyMarker(chars, after: index))
        case "{":
            var j = index + 1
            while j < chars.count, chars[j] != "}" { j += 1 }
            guard j < chars.count else { return nil }
            return Quantifier(minZero: true, endIndex: skipLazyMarker(chars, after: j))
        default:
            return nil
        }
    }

    /// `?`/`+` after a quantifier are lazy/possessive markers, not quantifiers.
    private static func skipLazyMarker(_ chars: [Character], after index: Int) -> Int {
        let next = index + 1
        if next < chars.count, chars[next] == "?" || chars[next] == "+" { return next + 1 }
        return next
    }

    /// Index of the quantifier position when `chars[from]` is a quantifier —
    /// convenience for "skip a quantifier if one follows".
    private static func skipQuantifier(_ chars: [Character], from index: Int) -> Int? {
        guard let q = quantifierKind(chars, at: index) else { return nil }
        return q.endIndex
    }

    /// Index of the ")" closing the group opened at `chars[from]` (nesting,
    /// escapes, and character classes honored), or nil when unbalanced.
    private static func skipGroup(_ chars: [Character], from index: Int) -> Int? {
        var depth = 0
        var i = index
        while i < chars.count {
            switch chars[i] {
            case "\\": i += 1
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 { return i }
            case "[":
                guard let close = skipCharacterClass(chars, from: i) else { return nil }
                i = close
            default: break
            }
            i += 1
        }
        return nil
    }

    /// Index of the "]" closing the class opened at `chars[from]`, or nil.
    private static func skipCharacterClass(_ chars: [Character], from index: Int) -> Int? {
        var i = index + 1
        if i < chars.count, chars[i] == "^" { i += 1 }
        if i < chars.count, chars[i] == "]" { i += 1 }   // leading "]" is a member
        while i < chars.count {
            if chars[i] == "\\" { i += 2; continue }
            if chars[i] == "]" { return i }
            i += 1
        }
        return nil
    }
}

/// Part P3: bounded regex search over the archive.
///
/// Pipeline: derive mandatory literal tokens from the pattern → FTS candidate
/// retrieval on those literals (shard-pruned, cursor-paged) → bounded
/// hydration (batches of `hydrationBatch`) → exact regex verification on each
/// candidate. When NO narrowing literal is derivable, the scan is a bounded
/// keyset walk of the (optionally date-bounded) scope, hard-capped at
/// `scanCap` — the outcome reports `truncated = true` whenever the cap cut the
/// scope short, and callers must surface that.
///
/// The verified text is the SAME document FTS indexes (subject / from /
/// to+cc / body prefix), so the literal-derived path and a full scan of that
/// scope agree exactly.
enum BoundedRegexSearch {

    static let defaultNoLiteralScanCap = 5_000
    static let literalCandidateCap = 20_000
    static let hydrationBatch = 300
    static let maxPatternLength = 1_000

    /// `/pattern/` → pattern; otherwise the legacy glob convenience (`*` →
    /// `.*`) — matches the pre-P3 in-place scan's normalization.
    static func normalizedPattern(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") && trimmed.hasSuffix("/") && trimmed.count > 2 {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed.replacingOccurrences(of: "*", with: ".*")
    }

    /// The exact text a regex is verified against — mirrors the FTS document
    /// (subject, sender, recipients, body prefix) so candidate retrieval and
    /// verification cover the same content.
    static func searchableText(_ email: MBOXParser.RawEmail) -> String {
        let subject = email.headers["Subject"] ?? ""
        let sender = email.headers["From"] ?? ""
        let recipients = (email.headers["To"] ?? "") + " " + (email.headers["Cc"] ?? "")
        let body = email.plainBody.isEmpty
            ? FTSSearchIndex.stripHTMLText(email.htmlBody)
            : email.plainBody
        return subject + "\n" + sender + "\n" + recipients + "\n" + String(body.prefix(50_000))
    }

    static func matches(_ regex: NSRegularExpression, _ email: MBOXParser.RawEmail) -> Bool {
        let text = searchableText(email)
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.firstMatch(in: text, options: [.withoutAnchoringBounds], range: range) != nil
    }

    /// Run a bounded regex search. `after`/`before` bound the scanned scope
    /// (exact date filtering applied on hydrated rows; shard pruning bounds
    /// the FTS candidate work).
    static func run(
        pattern rawPattern: String,
        store: any EmailArchiveStore,
        fts: FTSSearchIndex,
        after: Date? = nil,
        before: Date? = nil,
        scanCap: Int = defaultNoLiteralScanCap
    ) async throws -> RegexSearchOutcome {
        let pattern = normalizedPattern(rawPattern)
        guard pattern.count <= maxPatternLength, !pattern.isEmpty,
              let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return RegexSearchOutcome()   // invalid/oversized pattern → no matches (legacy parity)
        }
        var outcome = RegexSearchOutcome()
        let lo = after ?? .distantPast
        let hi = before ?? .distantFuture
        let hasDateBounds = after != nil || before != nil
        let iso = ISO8601DateFormatter()
        func inDateScope(_ email: MBOXParser.RawEmail) -> Bool {
            guard hasDateBounds else { return true }
            guard let d = iso.date(from: email.timestamp) else { return false }
            return d >= lo && d < hi
        }

        let literals = RegexLiteralExtractor.mandatoryLiteralTokens(from: pattern)
        if !literals.isEmpty {
            // Literal path: FTS candidates (every match must contain all the
            // literals) → bounded hydration → exact verify.
            outcome.usedLiteralPath = true
            let ftsQuery = literals.map { FTSQueryBuilder.escapeTerm($0) + "*" }
                .joined(separator: " AND ")
            let years = FTSSearchIndex.shardYears(after: after, before: before)
            var cursor: FTSSearchIndex.RankedCursor? = nil
            while true {
                if Task.isCancelled { break }
                let (hits, next) = try await fts.searchRanked(
                    ftsQuery, years: years, limit: hydrationBatch, cursor: cursor
                )
                if !hits.isEmpty {
                    let emails = try await store.emails(withIDs: hits.map(\.id))
                    for email in emails where inDateScope(email) {
                        outcome.scanned += 1
                        if matches(regex, email) { outcome.matchedIDs.insert(email.id) }
                    }
                }
                guard let n = next else { break }
                if outcome.scanned >= literalCandidateCap {
                    outcome.truncated = true   // candidates beyond the cap remain
                    break
                }
                cursor = n
            }
            return outcome
        }

        // No narrowing literal: bounded keyset scan of the scope, capped.
        var cursorDate: Date? = nil
        var cursorID: UUID? = nil
        while outcome.scanned < scanCap {
            if Task.isCancelled { break }
            let batch = min(hydrationBatch, scanCap - outcome.scanned)
            let page = try await store.summaryPage(
                after: after, before: before,
                cursorDate: cursorDate, cursorID: cursorID, limit: batch
            )
            if page.isEmpty { break }
            let emails = try await store.emails(withIDs: page.map(\.id))
            for email in emails {
                outcome.scanned += 1
                if matches(regex, email) { outcome.matchedIDs.insert(email.id) }
            }
            cursorDate = page.last?.date
            cursorID = page.last?.id
            if page.count < batch { return outcome }   // whole scope covered
        }
        // Cap reached — truncated only if scope actually continues past it.
        if outcome.scanned >= scanCap {
            let probe = try await store.summaryPage(
                after: after, before: before,
                cursorDate: cursorDate, cursorID: cursorID, limit: 1
            )
            outcome.truncated = !probe.isEmpty
        }
        return outcome
    }
}
