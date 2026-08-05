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

    func page(query: EmailQuery, cursor: EmailPageCursor?, limit: Int) async throws -> EmailPage {
        if let text = query.text, !text.isEmpty {
            // Text query → FTS5 → bounded IDs → summaries (bm25 order). Single
            // bounded page (ranked); cursor pagination of ranked results is a
            // later refinement.
            let fts = FTSQueryBuilder.freeTextOrBoolean(text) ?? FTSQueryBuilder.escapeTerm(text)
            let ids = (try? await FTSSearchIndex.shared.searchRaw(fts, limit: limit)) ?? []
            let sums = try await EmailStore.shared.summaries(ids: ids)
            let rank = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
            let ordered = sums.sorted { (rank[$0.id] ?? .max) < (rank[$1.id] ?? .max) }
            return EmailPage(summaries: ordered, nextCursor: nil)
        }
        let sums = try await EmailStore.shared.summaryPage(
            beforeDate: cursor?.beforeDate, beforeID: cursor?.beforeID, limit: limit
        )
        let next = (sums.count == limit) ? sums.last.map { EmailPageCursor(beforeDate: $0.date, beforeID: $0.id) } : nil
        return EmailPage(summaries: sums, nextCursor: next)
    }

    func summaries(ids: [EmailID]) async throws -> [EmailSummary] {
        try await EmailStore.shared.summaries(ids: ids)
    }

    func fullEmail(id: EmailID) async throws -> MBOXParser.RawEmail? {
        try await EmailStore.shared.fullEmail(id: id)
    }

    func exists(ids: [EmailID]) async throws -> Set<EmailID> {
        try await EmailStore.shared.existingIDs(among: ids)
    }

    func count(query: EmailQuery) async throws -> Int {
        if let text = query.text, !text.isEmpty {
            let fts = FTSQueryBuilder.freeTextOrBoolean(text) ?? FTSQueryBuilder.escapeTerm(text)
            return ((try? await FTSSearchIndex.shared.searchRaw(fts, limit: 1_000_000)) ?? []).count
        }
        return try await EmailStore.shared.totalCount()
    }

    func delete(ids: [EmailID]) async throws {
        try await EmailStore.shared.delete(ids: Set(ids))
        for id in ids { try? await FTSSearchIndex.shared.delete(id: id) }
    }
}
