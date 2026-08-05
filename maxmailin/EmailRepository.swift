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
    /// isolated instances so a harness can never reach real user data.
    let store: EmailStore
    let fts: FTSSearchIndex

    init(store: EmailStore = .shared, fts: FTSSearchIndex = .shared) {
        self.store = store
        self.fts = fts
    }

    func page(query: EmailQuery, cursor: EmailPageCursor?, limit: Int) async throws -> EmailPage {
        let hasText = !(query.text?.isEmpty ?? true)
        let hasDates = query.afterDate != nil || query.beforeDate != nil
        // Text + exact date range needs a time-scoped FTS planner (later stage).
        // Reject explicitly rather than silently ignoring the date bounds.
        if hasText && hasDates {
            throw EmailRepositoryError.unsupportedQueryCombination("text + exact date range")
        }
        if hasText, let text = query.text {
            // Text query → FTS5 → bounded IDs → summaries (bm25 order).
            let ftsQuery = FTSQueryBuilder.freeTextOrBoolean(text) ?? FTSQueryBuilder.escapeTerm(text)
            let ids = (try? await fts.searchRaw(ftsQuery, limit: limit)) ?? []
            let sums = try await store.summaries(ids: ids)
            let rank = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
            let ordered = sums.sorted { (rank[$0.id] ?? .max) < (rank[$1.id] ?? .max) }
            return EmailPage(summaries: ordered, nextCursor: nil)
        }
        // Non-text: keyset page with the query's date bounds applied in the DB.
        let sums = try await store.summaryPage(
            after: query.afterDate, before: query.beforeDate,
            cursorDate: cursor?.beforeDate, cursorID: cursor?.beforeID, limit: limit
        )
        let next = (sums.count == limit) ? sums.last.map { EmailPageCursor(beforeDate: $0.date, beforeID: $0.id) } : nil
        return EmailPage(summaries: sums, nextCursor: next)
    }

    func summaries(ids: [EmailID]) async throws -> [EmailSummary] {
        try await store.summaries(ids: ids)
    }

    func fullEmail(id: EmailID) async throws -> MBOXParser.RawEmail? {
        try await store.fullEmail(id: id)
    }

    func exists(ids: [EmailID]) async throws -> Set<EmailID> {
        try await store.existingIDs(among: ids)
    }

    func count(query: EmailQuery) async throws -> Int {
        let hasText = !(query.text?.isEmpty ?? true)
        let hasDates = query.afterDate != nil || query.beforeDate != nil
        if hasText && hasDates {
            throw EmailRepositoryError.unsupportedQueryCombination("text + exact date range")
        }
        if hasText, let text = query.text {
            // O(1)-memory FTS COUNT(*) — never materializes result IDs.
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
