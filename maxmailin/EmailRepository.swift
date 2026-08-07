//
//  EmailRepository.swift
//  maxmailin
//
//  Stage 3 (v2-core-cutover): the bounded data contract the UI/AI will consume
//  instead of holding the whole archive as `[RawEmail]`. Screens depend on this
//  boundary, not SwiftData details — so the storage implementation can be
//  swapped (e.g. to a direct-SQLite engine) if the stress harness proves
//  SwiftData unsuitable at scale, WITHOUT rewriting the UI again.
//
//  Nothing here copies full bodies / raw source / attachment bytes into list
//  summaries. Full content is fetched by id, on demand.
//

import Foundation

typealias EmailID = UUID

/// Errors a repository may return instead of silently ignoring a request.
enum EmailRepositoryError: Error, Sendable, Equatable {
    /// A query field combination isn't implemented yet — returned rather than
    /// accepting the query and ignoring part of it.
    case unsupportedQueryCombination(String)
    /// A ranked-search cursor was presented for a different query — the query
    /// changed, so the continuation is invalid (thrown, never silently mixed).
    case staleSearchCursor
}

/// Lightweight row for lists — no bodies, no attachment bytes.
struct EmailSummary: Identifiable, Sendable, Equatable {
    let id: EmailID
    let messageID: String?
    let subject: String
    let from: String
    let date: Date
    let bodyPreview: String
    let hasAttachments: Bool
    let sizeBytes: Int
}

/// Stable keyset cursor (date, id) — no offsets, so deep pagination stays O(log n).
struct EmailPageCursor: Sendable, Equatable {
    let beforeDate: Date
    let beforeID: EmailID
}

/// One bounded page plus the cursor to fetch the next (nil = end).
struct EmailPage: Sendable {
    let summaries: [EmailSummary]
    let nextCursor: EmailPageCursor?
}

/// A resolvable query — never a materialized archive. Extended incrementally
/// (sender/tag/account/etc.) as screens are cut over.
struct EmailQuery: Sendable, Equatable {
    var text: String? = nil          // FTS free-text / Boolean / (NEAR handled upstream)
    var beforeDate: Date? = nil
    var afterDate: Date? = nil

    static let all = EmailQuery()
    var isEmpty: Bool { (text?.isEmpty ?? true) && beforeDate == nil && afterDate == nil }
}

// MARK: - Part P2 — ranked search continuation

/// Continuation cursor for ranked (bm25) text search: the repository-level
/// fingerprint binds it to the exact query (text + date bounds); the wrapped
/// FTS cursor carries per-shard offsets and the last (score, id) boundary.
/// Pure value type — bounded, resumable, no open resources.
struct RankedSearchCursor: Sendable, Equatable {
    let fingerprint: UInt64
    var fts: FTSSearchIndex.RankedCursor
}

/// One bounded page of ranked results plus the cursor to fetch the next
/// (nil = exhausted).
struct RankedSearchPage: Sendable {
    let summaries: [EmailSummary]
    let nextCursor: RankedSearchCursor?
}

/// Optional repository capability: ranked (bm25) search with a bounded
/// continuation cursor. Kept separate from `EmailRepository` so existing
/// conformers (including test fakes) are unaffected; callers fall back to a
/// single bounded page when the capability is absent.
protocol RankedSearchRepository: Sendable {
    /// First page: `cursor == nil`. Resume: pass the returned cursor with the
    /// SAME query — a changed query throws `.staleSearchCursor`. Iterating to
    /// exhaustion yields every match exactly once, in stable order, with
    /// memory bounded by `limit` (× shard count inside the index).
    func searchRanked(query: EmailQuery, cursor: RankedSearchCursor?, limit: Int) async throws -> RankedSearchPage
}

/// Bounded repository boundary. Every method returns pages/batches/streams or a
/// single record — never the whole corpus.
protocol EmailRepository: Sendable {
    func page(query: EmailQuery, cursor: EmailPageCursor?, limit: Int) async throws -> EmailPage
    func summaries(ids: [EmailID]) async throws -> [EmailSummary]
    func fullEmail(id: EmailID) async throws -> MBOXParser.RawEmail?
    /// Bounded hydration of full emails (with bodies) for a specific id batch —
    /// for derived consumers that need bodies, fed one bounded page at a time.
    func fullEmails(ids: [EmailID]) async throws -> [MBOXParser.RawEmail]
    func exists(ids: [EmailID]) async throws -> Set<EmailID>
    func count(query: EmailQuery) async throws -> Int
    func delete(ids: [EmailID]) async throws
}

/// Production implementation over the current SwiftData `EmailStore` + FTS5.
/// Kept deliberately thin so the storage engine can be replaced behind it.
struct EmailStoreRepository: EmailRepository {
    static let shared = EmailStoreRepository()

    /// The store + index this repository resolves against. Defaults to the
    /// production singletons; `MailinStorageEnvironment.disposable` injects
    /// isolated instances so a harness can never reach real user data. `store`
    /// is the bounded-store contract, so the engine (SwiftData vs direct
    /// SQLite) can be swapped without touching this repository or the UI.
    let store: any EmailArchiveStore
    let fts: FTSSearchIndex

    init(store: any EmailArchiveStore = EmailStore.shared, fts: FTSSearchIndex = .shared) {
        self.store = store
        self.fts = fts
    }

    /// Bounded cap on a single ranked text search. A term matching more than this
    /// many rows is ranked/date-filtered over this bounded candidate window — we
    /// never materialize the full result set. Deep ranked continuation beyond the
    /// cap is a later refinement (cross-shard BM25 cursor).
    static let textSearchCap = 2_000

    func page(query: EmailQuery, cursor: EmailPageCursor?, limit: Int) async throws -> EmailPage {
        if let text = query.text, !text.isEmpty {
            // Text (optionally + date): FTS5 ranked candidate ids → summaries →
            // apply exact date bounds → bm25 order → bounded page.
            let ordered = try await rankedTextSummaries(text, query: query)
            return EmailPage(summaries: Array(ordered.prefix(limit)), nextCursor: nil)
        }
        // Non-text: keyset page with the query's date bounds applied in the DB.
        let sums = try await store.summaryPage(
            after: query.afterDate, before: query.beforeDate,
            cursorDate: cursor?.beforeDate, cursorID: cursor?.beforeID, limit: limit
        )
        let next = (sums.count == limit) ? sums.last.map { EmailPageCursor(beforeDate: $0.date, beforeID: $0.id) } : nil
        return EmailPage(summaries: sums, nextCursor: next)
    }

    /// FTS candidate ids → summaries → exact date filter → bm25 rank order.
    /// Part P1: when the query carries date bounds, the FTS work is pruned to
    /// the year shards intersecting the range (+ the unknown-date shard), then
    /// the EXACT bounds are applied on the hydrated summaries — same results
    /// as the unpruned reference, bounded work.
    private func rankedTextSummaries(_ text: String, query: EmailQuery) async throws -> [EmailSummary] {
        let ftsQuery = FTSQueryBuilder.freeTextOrBoolean(text) ?? FTSQueryBuilder.escapeTerm(text)
        let years = FTSSearchIndex.shardYears(after: query.afterDate, before: query.beforeDate)
        let ids: [UUID]
        if years != nil {
            let ranked = try? await fts.searchRanked(ftsQuery, years: years, limit: Self.textSearchCap)
            ids = ranked?.hits.map(\.id) ?? []
        } else {
            ids = (try? await fts.searchRaw(ftsQuery, limit: Self.textSearchCap)) ?? []
        }
        var sums = try await store.summaries(ids: ids)
        if query.afterDate != nil || query.beforeDate != nil {
            let lo = query.afterDate ?? .distantPast
            let hi = query.beforeDate ?? .distantFuture
            sums = sums.filter { $0.date >= lo && $0.date < hi }
        }
        sums = try await excludingTrashed(sums)
        let rank = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        return sums.sorted { (rank[$0.id] ?? .max) < (rank[$1.id] ?? .max) }
    }

    /// §19.1: trashed rows stay in the FTS index (restore must not require a
    /// reindex) but are excluded from every user-facing search result at the
    /// hydration boundary — one bounded review-state lookup per page.
    private func excludingTrashed(_ sums: [EmailSummary]) async throws -> [EmailSummary] {
        guard !sums.isEmpty, let sqlite = store as? SQLiteEmailStore else { return sums }
        let states = try await sqlite.reviewStates(ids: sums.map(\.id))
        return sums.filter { !(states[$0.id]?.trashed ?? false) }
    }

    func summaries(ids: [EmailID]) async throws -> [EmailSummary] {
        try await store.summaries(ids: ids)
    }

    func fullEmail(id: EmailID) async throws -> MBOXParser.RawEmail? {
        try await store.fullEmail(id: id)
    }

    func fullEmails(ids: [EmailID]) async throws -> [MBOXParser.RawEmail] {
        try await store.emails(withIDs: ids)
    }

    func exists(ids: [EmailID]) async throws -> Set<EmailID> {
        try await store.existingIDs(among: ids)
    }

    func count(query: EmailQuery) async throws -> Int {
        let hasDates = query.afterDate != nil || query.beforeDate != nil
        if let text = query.text, !text.isEmpty {
            if hasDates {
                // Text + date: count the date-filtered candidates (bounded by the
                // search cap; exact when total text matches ≤ cap).
                return try await rankedTextSummaries(text, query: query).count
            }
            // O(1)-memory FTS COUNT(*) — never materializes result ids.
            let ftsQuery = FTSQueryBuilder.freeTextOrBoolean(text) ?? FTSQueryBuilder.escapeTerm(text)
            return try await fts.countRaw(ftsQuery)
        }
        return try await store.count(after: query.afterDate, before: query.beforeDate)
    }

    func delete(ids: [EmailID]) async throws {
        guard !ids.isEmpty else { return }
        // FTS first, then store: if the store delete fails afterward, the
        // canonical row still exists and bounded reconcile restores search —
        // no ghost FTS row. Errors propagate (no silent try?).
        for id in ids { try await fts.delete(id: id) }
        try await store.delete(ids: Set(ids))
    }
}

// MARK: - Part P2 — ranked continuation over the SQLite store + FTS5

extension EmailStoreRepository: RankedSearchRepository {

    /// Bounded number of fill rounds per page request. Each round consumes at
    /// least one FTS hit, so a round only "wastes" work when date filtering
    /// rejects candidates from boundary shards; returning a short page with a
    /// live cursor after this many rounds keeps per-call work bounded without
    /// skipping anything.
    static let maxRankedFillRounds = 50

    func searchRanked(query: EmailQuery, cursor: RankedSearchCursor?, limit: Int) async throws -> RankedSearchPage {
        guard let rawText = query.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawText.isEmpty, limit > 0 else {
            return RankedSearchPage(summaries: [], nextCursor: nil)
        }
        let ftsQuery = FTSQueryBuilder.freeTextOrBoolean(rawText) ?? FTSQueryBuilder.escapeTerm(rawText)
        // P1: prune the shard set to the queried date range (exact bounds are
        // re-applied on the hydrated summaries below).
        let years = FTSSearchIndex.shardYears(after: query.afterDate, before: query.beforeDate)
        let fingerprint = Self.rankedQueryFingerprint(ftsQuery: ftsQuery, query: query, years: years)
        if let cursor, cursor.fingerprint != fingerprint {
            throw EmailRepositoryError.staleSearchCursor
        }

        let lo = query.afterDate ?? .distantPast
        let hi = query.beforeDate ?? .distantFuture
        let needsDateFilter = query.afterDate != nil || query.beforeDate != nil

        var ftsCursor = cursor?.fts
        var out: [EmailSummary] = []
        var next: FTSSearchIndex.RankedCursor? = ftsCursor
        var rounds = 0
        repeat {
            rounds += 1
            let (hits, cont) = try await fts.searchRanked(
                ftsQuery, years: years, limit: limit - out.count, cursor: ftsCursor
            )
            next = cont
            if hits.isEmpty && cont == nil { break }
            if !hits.isEmpty {
                let hydrated = try await excludingTrashed(store.summaries(ids: hits.map(\.id)))
                let byID = Dictionary(hydrated.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                for hit in hits {
                    guard let summary = byID[hit.id] else { continue }
                    if needsDateFilter && !(summary.date >= lo && summary.date < hi) { continue }
                    out.append(summary)
                }
            }
            ftsCursor = cont
        } while out.count < limit && next != nil && rounds < Self.maxRankedFillRounds

        return RankedSearchPage(
            summaries: out,
            nextCursor: next.map { RankedSearchCursor(fingerprint: fingerprint, fts: $0) }
        )
    }

    /// Fingerprint binding a cursor to text + exact date bounds + prune set.
    static func rankedQueryFingerprint(ftsQuery: String, query: EmailQuery, years: Set<Int>?) -> UInt64 {
        let loSecs = query.afterDate.map { String(Int64($0.timeIntervalSince1970.rounded())) } ?? "-"
        let hiSecs = query.beforeDate.map { String(Int64($0.timeIntervalSince1970.rounded())) } ?? "-"
        return FTSSearchIndex.rankedFingerprint(
            query: ftsQuery + "\u{1}" + loSecs + "\u{1}" + hiSecs, years: years
        )
    }
}
