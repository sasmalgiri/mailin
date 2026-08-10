//
//  ArchiveDataService.swift
//  maxmailin
//
//  Stage 5C.0 (v2-core-cutover): the migration firewall. Every UI screen and
//  derived consumer obtains archive data through THIS service — bounded pages,
//  counts, single emails, bounded id batches, and bounded streaming.
//
//  It fronts the activated SQLite store via `EmailRepository`, so consumers are
//  bounded-by-construction and the storage engine stays swappable. Part Q/R/S
//  completed the cutover: the legacy whole-corpus arrays are deleted and both
//  list modes page through this service.
//
//  No `loadAll()` / `loadEverything()` is offered on purpose: the firewall must
//  not let a migrated screen silently reconstruct the whole corpus.
//

import Foundation

@MainActor
final class ArchiveDataService {

    /// Production instance over the activated SQLite store + FTS5.
    static let shared = ArchiveDataService(
        repository: EmailStoreRepository(store: SQLiteEmailStore.shared, fts: .shared)
    )

    private let repository: any EmailRepository

    init(repository: any EmailRepository) {
        self.repository = repository
    }

    // MARK: - Bounded reads

    /// One keyset page of lightweight summaries (no bodies).
    func page(query: EmailQuery = .all, cursor: EmailPageCursor? = nil, limit: Int = 100) async throws -> EmailPage {
        try await repository.page(query: query, cursor: cursor, limit: limit)
    }

    /// Exact result count for a query (O(1)-memory aggregate; never materializes).
    func count(query: EmailQuery = .all) async throws -> Int {
        try await repository.count(query: query)
    }

    /// Summaries for a specific id batch (no bodies).
    func summaries(ids: [EmailID]) async throws -> [EmailSummary] {
        try await repository.summaries(ids: ids)
    }

    /// Full email (bodies + headers) hydrated on demand for a single id.
    func fullEmail(id: EmailID) async throws -> MBOXParser.RawEmail? {
        try await repository.fullEmail(id: id)
    }

    /// Bounded full-email hydration for a specific id batch.
    func fullEmails(ids: [EmailID]) async throws -> [MBOXParser.RawEmail] {
        try await repository.fullEmails(ids: ids)
    }

    /// Which of the given ids exist.
    func exists(ids: [EmailID]) async throws -> Set<EmailID> {
        try await repository.exists(ids: ids)
    }

    /// §15: which of `ids` genuinely match `query` — structured filters
    /// verified in SQL, text via a bounded per-ID FTS check. Used to verify
    /// Select-All exclusions; bounded by `ids`, never by the result set.
    func matchingIDs(among ids: [EmailID], query: EmailQuery) async throws -> Set<EmailID> {
        guard !ids.isEmpty else { return [] }
        guard let repo = repository as? EmailStoreRepository,
              let sqlite = repo.store as? SQLiteEmailStore else {
            return try await exists(ids: ids)   // best effort without SQL access
        }
        var candidates = try await sqlite.matchingIDs(among: ids, query: query)
        if let text = query.text, !text.isEmpty, !candidates.isEmpty {
            let ftsQuery = FTSQueryBuilder.freeTextOrBoolean(text) ?? FTSQueryBuilder.escapeTerm(text)
            candidates = try await repo.fts.matchingIDs(among: Array(candidates), ftsQuery: ftsQuery)
        }
        return candidates
    }

    // MARK: - Part P — ranked continuation + bounded regex

    /// One bounded page of ranked (bm25) text-search results with a
    /// continuation cursor (Part P2). Resuming with the same query yields
    /// every match exactly once in stable order; a changed query throws
    /// `.staleSearchCursor`. Falls back to a single bounded page (no
    /// continuation) when the repository lacks the ranked capability.
    func searchRanked(query: EmailQuery, cursor: RankedSearchCursor? = nil, limit: Int = 100) async throws -> RankedSearchPage {
        if let ranked = repository as? RankedSearchRepository {
            return try await ranked.searchRanked(query: query, cursor: cursor, limit: limit)
        }
        let page = try await repository.page(query: query, cursor: nil, limit: limit)
        return RankedSearchPage(summaries: page.summaries, nextCursor: nil)
    }

    /// Bounded regex search (Part P3): literal-derived FTS candidates + exact
    /// verification, or a capped scope scan when no literal is derivable. The
    /// outcome's `truncated` flag MUST be surfaced by callers.
    func regexSearch(pattern: String, after: Date? = nil, before: Date? = nil) async throws -> RegexSearchOutcome {
        guard let repo = repository as? EmailStoreRepository else { return RegexSearchOutcome() }
        return try await BoundedRegexSearch.run(
            pattern: pattern, store: repo.store, fts: repo.fts, after: after, before: before
        )
    }

    // MARK: - Bounded mutation

    /// PERMANENT deletion (row + bodies + derived + FTS via repository).
    /// §19.1: browse UIs must not call this as their default "delete" —
    /// use `setTrashed` and keep destruction an explicit second step.
    func delete(ids: [EmailID]) async throws {
        try await repository.delete(ids: ids)
    }

    /// §19.1 soft trash: flag rows in review state so browse pages/counts
    /// exclude them; fully restorable.
    func setTrashed(ids: [EmailID], _ value: Bool) async throws {
        guard let repo = repository as? EmailStoreRepository,
              let sqlite = repo.store as? SQLiteEmailStore else {
            throw SQLiteStoreError.schema("trash requires the SQLite review-state store")
        }
        try await sqlite.reviewSetFlag(.trashed, ids: ids, value: value)
    }

    /// Trashed IDs, newest first (the Trash surface's read path).
    func trashedIDs(limit: Int, offset: Int) async throws -> [EmailID] {
        guard let repo = repository as? EmailStoreRepository,
              let sqlite = repo.store as? SQLiteEmailStore else { return [] }
        return try await sqlite.reviewIDs(where: .trashed, limit: limit, offset: offset)
    }

    func trashedCount() async throws -> Int {
        guard let repo = repository as? EmailStoreRepository,
              let sqlite = repo.store as? SQLiteEmailStore else { return 0 }
        return try await sqlite.reviewCount(of: .trashed)
    }

    // MARK: - Bounded streaming (for derived jobs)

    /// Stream every matching summary in keyset pages of `batchSize`. Only one
    /// page is resident at a time — a derived job (analytics, tagging, …) can
    /// walk the whole archive with bounded memory and cooperative cancellation.
    /// Walk EVERY summary page of a query. Text queries iterate the RANKED
    /// CONTINUATION cursor to exhaustion — `page()`'s text path is a single
    /// bounded page, so streaming through it would silently truncate
    /// Select All / exports / bulk ops to one page (H1). Non-text queries use
    /// the keyset page loop.
    private func forEachSummaryPage(
        query: EmailQuery, batchSize: Int,
        _ body: ([EmailSummary]) async throws -> Void
    ) async throws {
        if let text = query.text, !text.isEmpty {
            var cursor: RankedSearchCursor? = nil
            while true {
                try Task.checkCancellation()
                let page = try await searchRanked(query: query, cursor: cursor, limit: batchSize)
                if !page.summaries.isEmpty { try await body(page.summaries) }
                guard let next = page.nextCursor else { break }
                cursor = next
            }
            return
        }
        var cursor: EmailPageCursor? = nil
        while true {
            try Task.checkCancellation()
            let page = try await repository.page(query: query, cursor: cursor, limit: batchSize)
            if page.summaries.isEmpty { break }
            try await body(page.summaries)
            guard let next = page.nextCursor else { break }
            cursor = next
        }
    }

    func streamSummaries(query: EmailQuery = .all, batchSize: Int = 500) -> AsyncThrowingStream<[EmailSummary], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.forEachSummaryPage(query: query, batchSize: batchSize) { summaries in
                        continuation.yield(summaries)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Stream full emails (with bodies) in bounded pages — for consumers that
    /// genuinely need bodies (AI evidence, analytics text). Each page's ids are
    /// hydrated then released before the next page.
    func streamFullEmails(query: EmailQuery = .all, batchSize: Int = 200) -> AsyncThrowingStream<[MBOXParser.RawEmail], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.forEachSummaryPage(query: query, batchSize: batchSize) { summaries in
                        let emails = try await self.repository.fullEmails(ids: summaries.map(\.id))
                        continuation.yield(emails)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
