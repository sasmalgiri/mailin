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
    private func rankedTextSummaries(_ text: String, query: EmailQuery) async throws -> [EmailSummary] {
        let ftsQuery = FTSQueryBuilder.freeTextOrBoolean(text) ?? FTSQueryBuilder.escapeTerm(text)
        let ids = (try? await fts.searchRaw(ftsQuery, limit: Self.textSearchCap)) ?? []
        var sums = try await store.summaries(ids: ids)
        if query.afterDate != nil || query.beforeDate != nil {
            let lo = query.afterDate ?? .distantPast
            let hi = query.beforeDate ?? .distantFuture
            sums = sums.filter { $0.date >= lo && $0.date < hi }
        }
        let rank = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        return sums.sorted { (rank[$0.id] ?? .max) < (rank[$1.id] ?? .max) }
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
