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

/// Stable keyset cursor — no offsets, so deep pagination stays O(log n).
/// `sortKey` carries the boundary value for non-date sorts (§16): the subject
/// string, size/priority as a decimal string; nil ⇒ the (date, id) keyset.
struct EmailPageCursor: Sendable, Equatable {
    let beforeDate: Date
    let beforeID: EmailID
    var sortKey: String? = nil
}

/// One bounded page plus the cursor to fetch the next (nil = end).
struct EmailPage: Sendable {
    let summaries: [EmailSummary]
    let nextCursor: EmailPageCursor?
}

/// §16: DB-native sort orders (each backed by a keyset + index — the archive
/// is never sorted in RAM).
enum EmailSortOrder: String, Sendable, Codable, CaseIterable {
    case dateDesc, dateAsc, subjectAZ, sizeDesc, priorityDesc
}

/// §13: a resolvable query — never a materialized archive. Every field maps
/// to a shipping filter; NO field is silently ignored (the store either
/// compiles it into SQL or the repository routes it explicitly).
struct EmailQuery: Sendable, Equatable {
    var text: String? = nil          // FTS free-text / Boolean / (NEAR handled upstream)
    var beforeDate: Date? = nil
    var afterDate: Date? = nil
    /// From-header contains (case-insensitive).
    var sender: String? = nil
    /// Recipient (To/Cc/Bcc participant) contains (normalized address).
    var recipient: String? = nil
    /// Subject contains (case-insensitive).
    var subjectContains: String? = nil
    /// Exact domain (normalized `email_domains`).
    var domain: String? = nil
    /// Exact user tag (`email_user_tags`).
    var userTag: String? = nil
    /// Exact forensic evidence tag (`forensic_evidence_tags`).
    var evidenceTag: String? = nil
    var hasAttachments: Bool? = nil
    /// Exact message type ("sent"/"received"/parser value).
    var messageType: String? = nil
    /// Only pinned rows (review state).
    var pinnedOnly = false
    /// Trash surfaces set this; every other surface excludes trashed rows.
    var includeTrashed = false
    var sort: EmailSortOrder = .dateDesc

    static let all = EmailQuery()

    /// True when only text/date are set (the pre-§13 fast paths apply).
    var hasStructuredFilters: Bool {
        sender != nil || recipient != nil || subjectContains != nil || domain != nil
            || userTag != nil || evidenceTag != nil || hasAttachments != nil
            || messageType != nil || pinnedOnly || includeTrashed || sort != .dateDesc
    }

    var isEmpty: Bool {
        (text?.isEmpty ?? true) && beforeDate == nil && afterDate == nil && !hasStructuredFilters
    }
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
            // Text (optionally + filters): FTS5 ranked candidate ids →
            // summaries → SQL-verified filters → bm25 order → bounded page.
            // (Deep continuation callers use searchRanked; this is one page.)
            let ordered = try await rankedTextSummaries(text, query: query)
            return EmailPage(summaries: Array(ordered.prefix(limit)), nextCursor: nil)
        }
        // §13/§16: structured filters or a non-date sort → the SQL-compiled
        // keyset page (every query field participates; none is ignored).
        if query.hasStructuredFilters, let sqlite = store as? SQLiteEmailStore {
            let rows = try await sqlite.filteredSummaryPage(
                query, cursorSortKey: cursor?.sortKey, cursorID: cursor?.beforeID, limit: limit)
            let next: EmailPageCursor? = (rows.count == limit) ? rows.last.map {
                EmailPageCursor(beforeDate: $0.summary.date, beforeID: $0.summary.id, sortKey: $0.sortKey)
            } : nil
            return EmailPage(summaries: rows.map(\.summary), nextCursor: next)
        }
        // Text-free, date-only: the original (date, id) keyset fast path.
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
        sums = try await applyingStructuredFilters(sums, query: query)
        let rank = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        return sums.sorted { (rank[$0.id] ?? .max) < (rank[$1.id] ?? .max) }
    }

    /// §13/§19.1: verify FTS candidates against EVERY non-text query field in
    /// SQL (dates, sender/recipient/domain/tag/type/pinned — and the trash
    /// exclusion, so trashed rows stay indexed for Restore yet never surface).
    /// One bounded IN query per page.
    private func applyingStructuredFilters(_ sums: [EmailSummary], query: EmailQuery) async throws -> [EmailSummary] {
        guard !sums.isEmpty else { return sums }
        guard let sqlite = store as? SQLiteEmailStore else {
            // Legacy store: dates only (its query surface predates §13).
            if query.afterDate != nil || query.beforeDate != nil {
                let lo = query.afterDate ?? .distantPast
                let hi = query.beforeDate ?? .distantFuture
                return sums.filter { $0.date >= lo && $0.date < hi }
            }
            return sums
        }
        let matching = try await sqlite.matchingIDs(among: sums.map(\.id), query: query)
        return sums.filter { matching.contains($0.id) }
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
        if let text = query.text, !text.isEmpty {
            let ftsQuery = FTSQueryBuilder.freeTextOrBoolean(text) ?? FTSQueryBuilder.escapeTerm(text)
            let hasDates = query.afterDate != nil || query.beforeDate != nil
            // Fast path: pure text, no filters, and no trashed rows to
            // subtract → O(1)-memory FTS COUNT(*).
            if !hasDates && !query.hasStructuredFilters {
                if let sqlite = store as? SQLiteEmailStore {
                    let trashed = try await sqlite.reviewCount(of: .trashed)
                    if trashed == 0 { return try await fts.countRaw(ftsQuery) }
                } else {
                    return try await fts.countRaw(ftsQuery)
                }
            }
            // §14.2 EXACT text(+date/filter) count: stream the ranked cursor
            // to exhaustion in bounded ID pages, SQL-verifying each page.
            // Memory is bounded by the page size — never the result set, and
            // never a first-window approximation.
            return try await exactStreamedTextCount(ftsQuery: ftsQuery, query: query)
        }
        if query.hasStructuredFilters, let sqlite = store as? SQLiteEmailStore {
            return try await sqlite.filteredCount(query)
        }
        return try await store.count(after: query.afterDate, before: query.beforeDate)
    }

    private func exactStreamedTextCount(ftsQuery: String, query: EmailQuery) async throws -> Int {
        let years = FTSSearchIndex.shardYears(after: query.afterDate, before: query.beforeDate)
        var cursor: FTSSearchIndex.RankedCursor? = nil
        var total = 0
        while true {
            let (hits, cont) = try await fts.searchRanked(ftsQuery, years: years, limit: 1_000, cursor: cursor)
            if hits.isEmpty && cont == nil { break }
            if !hits.isEmpty {
                if let sqlite = store as? SQLiteEmailStore {
                    total += try await sqlite.matchingIDs(among: hits.map(\.id), query: query).count
                } else {
                    // Legacy store: date-only verification via summaries.
                    let sums = try await store.summaries(ids: hits.map(\.id))
                    let lo = query.afterDate ?? .distantPast
                    let hi = query.beforeDate ?? .distantFuture
                    total += sums.filter { $0.date >= lo && $0.date < hi }.count
                }
            }
            guard let next = cont else { break }
            cursor = next
        }
        return total
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
                // §13: every structured filter (dates, sender/tag/type/…,
                // trash exclusion) is SQL-verified per candidate page.
                let hydrated = try await applyingStructuredFilters(
                    store.summaries(ids: hits.map(\.id)), query: query)
                let byID = Dictionary(hydrated.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                for hit in hits {
                    guard let summary = byID[hit.id] else { continue }
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

    /// Fingerprint binding a cursor to the WHOLE query (text, dates, every
    /// structured filter, sort) + prune set — any mutation invalidates the
    /// continuation (§14.1).
    static func rankedQueryFingerprint(ftsQuery: String, query: EmailQuery, years: Set<Int>?) -> UInt64 {
        let loSecs = query.afterDate.map { String(Int64($0.timeIntervalSince1970.rounded())) } ?? "-"
        let hiSecs = query.beforeDate.map { String(Int64($0.timeIntervalSince1970.rounded())) } ?? "-"
        let filters = [
            query.sender ?? "-", query.recipient ?? "-", query.subjectContains ?? "-",
            query.domain ?? "-", query.userTag ?? "-", query.evidenceTag ?? "-",
            query.hasAttachments.map(String.init) ?? "-", query.messageType ?? "-",
            String(query.pinnedOnly), String(query.includeTrashed), query.sort.rawValue
        ].joined(separator: "\u{1}")
        return FTSSearchIndex.rankedFingerprint(
            query: ftsQuery + "\u{1}" + loSecs + "\u{1}" + hiSecs + "\u{1}" + filters, years: years
        )
    }
}
