//
//  ArchiveDataService.swift
//  maxmailin
//
//  Stage 5C.0 (v2-core-cutover): the migration firewall. Every UI screen and
//  derived consumer obtains archive data through THIS service — bounded pages,
//  counts, single emails, bounded id batches, and bounded streaming — instead
//  of reaching into `ContentViewModel.parsedEmails` /
//  `ParsedEmailListViewModel.allEmails` / `filteredEmails`.
//
//  It fronts the activated SQLite store via `EmailRepository`, so consumers are
//  bounded-by-construction and the storage engine stays swappable. During the
//  cutover the old whole-array path remains as a temporary correctness ORACLE
//  (differential tests compare new-vs-old on fixtures); once every consumer is
//  migrated, the array — and this dual world — is deleted.
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

    func delete(ids: [EmailID]) async throws {
        try await repository.delete(ids: ids)
    }

    // MARK: - Bounded streaming (for derived jobs)

    /// Stream every matching summary in keyset pages of `batchSize`. Only one
    /// page is resident at a time — a derived job (analytics, tagging, …) can
    /// walk the whole archive with bounded memory and cooperative cancellation.
    func streamSummaries(query: EmailQuery = .all, batchSize: Int = 500) -> AsyncThrowingStream<[EmailSummary], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var cursor: EmailPageCursor? = nil
                do {
                    while true {
                        if Task.isCancelled { break }
                        let page = try await repository.page(query: query, cursor: cursor, limit: batchSize)
                        if page.summaries.isEmpty { break }
                        continuation.yield(page.summaries)
                        guard let next = page.nextCursor else { break }
                        cursor = next
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
                var cursor: EmailPageCursor? = nil
                do {
                    while true {
                        if Task.isCancelled { break }
                        let page = try await repository.page(query: query, cursor: cursor, limit: batchSize)
                        if page.summaries.isEmpty { break }
                        let emails = try await repository.fullEmails(ids: page.summaries.map(\.id))
                        continuation.yield(emails)
                        guard let next = page.nextCursor else { break }
                        cursor = next
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
