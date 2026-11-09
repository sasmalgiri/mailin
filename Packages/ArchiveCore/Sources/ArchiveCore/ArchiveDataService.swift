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
    nonisolated static let shared = ArchiveDataService(
        repository: EmailStoreRepository(store: SQLiteEmailStore.shared, fts: .shared)
    )

    private let repository: any EmailRepository

    /// Purchase-tier scope: when set, every query through this service sees
    /// only the newest `accessLimit` emails of the archive — list, counts,
    /// search, AI retrieval, analytics, exports, attachments. The app sets it
    /// from the store manager (Free = 500, paid = nil). Bounded once here,
    /// not per screen.
    var accessLimit: Int? = nil

    nonisolated init(repository: any EmailRepository) {
        self.repository = repository
    }

    /// `query` with the tier's scope applied (the tighter of the two limits).
    func scoped(_ query: EmailQuery) -> EmailQuery {
        guard let accessLimit else { return query }
        var q = query
        q.newestLimit = min(q.newestLimit ?? Int.max, accessLimit)
        return q
    }

    // MARK: - Bounded reads

    /// One keyset page of lightweight summaries (no bodies).
    func page(query: EmailQuery = .all, cursor: EmailPageCursor? = nil, limit: Int = 100) async throws -> EmailPage {
        try await repository.page(query: scoped(query), cursor: cursor, limit: limit)
    }

    /// Exact result count for a query (O(1)-memory aggregate; never materializes).
    func count(query: EmailQuery = .all) async throws -> Int {
        try await repository.count(query: scoped(query))
    }

    /// The count WITHOUT the tier's scope — what the archive holds in total,
    /// for the Free banners that say "first 500 of 526" and "26 more with
    /// Personal". Never used to fetch rows.
    func unscopedCount(query: EmailQuery = .all) async throws -> Int {
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

    /// S5: where a message's bytes ARE when they are located rather than
    /// stored (the offset engine's header-only import). Nil for rows with
    /// stored raw MIME, rows imported before locators existed, and stores
    /// that have no locator table.
    func messageLocator(for id: EmailID) async throws -> MessageLocator? {
        guard let sqlite = (repository as? EmailStoreRepository)?.store as? SQLiteEmailStore else { return nil }
        return try await sqlite.locator(forEmailID: id)
    }

    /// Which of the given ids exist.
    func exists(ids: [EmailID]) async throws -> Set<EmailID> {
        try await repository.exists(ids: ids)
    }

    /// §15: which of `ids` genuinely match `query` — structured filters
    /// verified in SQL, text via a bounded per-ID FTS check. Used to verify
    /// Select-All exclusions; bounded by `ids`, never by the result set.
    func matchingIDs(among ids: [EmailID], query unscoped: EmailQuery) async throws -> Set<EmailID> {
        guard !ids.isEmpty else { return [] }
        let query = scoped(unscoped)
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
    func searchRanked(query unscoped: EmailQuery, cursor: RankedSearchCursor? = nil, limit: Int = 100) async throws -> RankedSearchPage {
        let query = scoped(unscoped)
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

    /// Trashed IDs, newest first, keyset-paged: pass the last row back as the
    /// cursor for the next page.
    func trashedIDs(after cursor: SQLiteEmailStore.DateIDCursor?, limit: Int) async throws -> [(id: EmailID, date: Date)] {
        guard let repo = repository as? EmailStoreRepository,
              let sqlite = repo.store as? SQLiteEmailStore else { return [] }
        return try await sqlite.reviewIDs(where: .trashed, after: cursor, limit: limit)
    }

    func trashedCount() async throws -> Int {
        guard let repo = repository as? EmailStoreRepository,
              let sqlite = repo.store as? SQLiteEmailStore else { return 0 }
        return try await sqlite.reviewCount(of: .trashed)
    }

    /// A6: every stored row, trashed included — the denominator index
    /// coverage is measured against (trashed rows stay indexed for Restore).
    func storedTotalCount() async throws -> Int {
        guard let repo = repository as? EmailStoreRepository,
              let sqlite = repo.store as? SQLiteEmailStore else { return try await count(query: .all) }
        return try await sqlite.totalCount()
    }

    /// User tags for a bounded id batch (F-4 exclusions).
    func userTags(ids: [EmailID]) async throws -> [EmailID: Set<String>] {
        guard let repo = repository as? EmailStoreRepository,
              let sqlite = repo.store as? SQLiteEmailStore else { return [:] }
        return try await sqlite.userTags(ids: ids)
    }

    // MARK: - A2 sidebar aggregates (GROUP BY, never a corpus walk)

    /// Imported sources, newest first.
    func sources() async throws -> [SQLiteEmailStore.StoredSource] {
        guard let repo = repository as? EmailStoreRepository,
              let sqlite = repo.store as? SQLiteEmailStore else { return [] }
        return try await sqlite.sources()
    }

    /// A6: per-source index coverage (committed vs indexed), keyed by source id.
    func sourceCoverage() async throws -> [Int64: SQLiteEmailStore.SourceCoverage] {
        guard let repo = repository as? EmailStoreRepository,
              let sqlite = repo.store as? SQLiteEmailStore else { return [:] }
        return Dictionary(uniqueKeysWithValues: try await sqlite.sourceCoverage().map { ($0.sourceID, $0) })
    }

    /// Parser labels (Gmail labels, Maildir/PST folders) with counts.
    func parserTagCounts(limit: Int) async throws -> [AggregateBucket] {
        guard let repo = repository as? EmailStoreRepository,
              let sqlite = repo.store as? SQLiteEmailStore else { return [] }
        return try await sqlite.parserTagCounts(limit: limit)
    }

    /// The SQLite store behind this service, when that is what it is.
    var sqliteStore: SQLiteEmailStore? {
        (repository as? EmailStoreRepository)?.store as? SQLiteEmailStore
    }

    /// §13.3 (5): the files inside the attachments of one message, as recorded by the indexing job.
    func attachmentChildren(emailID: EmailID) async -> [AttachmentChildRow] {
        guard let sqlite = sqliteStore else { return [] }
        return (try? await sqlite.attachmentChildren(forEmailID: emailID)) ?? []
    }

    /// §13.3 (9): the extracted text of one attachment document or child, for the text view.
    func attachmentDocumentText(emailID: EmailID, ordinal: Int) async -> String? {
        guard let sqlite = sqliteStore else { return nil }
        return try? await sqlite.attachmentDocumentText(emailID: emailID, ordinal: ordinal)
    }

    /// R7: whether that text exists — one EXISTS on the document row, no text read.
    func attachmentDocumentHasText(emailID: EmailID, ordinal: Int) async -> Bool {
        guard let sqlite = sqliteStore else { return false }
        return (try? await sqlite.attachmentDocumentHasText(emailID: emailID, ordinal: ordinal)) ?? false
    }

    /// LIFE-06 (audit A08): the paid tier recorded inside the archive (raw
    /// value; 0 = none) and the write that records one.
    func paidTierRecord() async -> Int {
        guard let sqlite = sqliteStore else { return 0 }
        return (try? await sqlite.paidTierRecord()) ?? 0
    }

    func recordPaidTier(_ tier: Int) async {
        guard let sqlite = sqliteStore else { return }
        try? await sqlite.recordPaidTier(tier)
    }

    /// FIND-03/07: how far the chunk index reaches (bodies and attachments with an evaluable document).
    func searchDocCoverage() async throws -> SQLiteEmailStore.SearchDocCoverage {
        guard let sqlite = sqliteStore else {
            return SQLiteEmailStore.SearchDocCoverage(bodiesEvaluable: 0, emails: 0, attachmentsEvaluable: 0, attachments: 0, bodyChunks: 0)
        }
        return try await sqlite.searchDocCoverage()
    }

    /// FIND-05: why one row is in the results — from the chunk index, never guessed.
    func matchEvidence(emailID: EmailID, spec: SearchSpec?, freeText: String?) async throws -> [MatchEvidence] {
        guard let repo = repository as? EmailStoreRepository,
              let sqlite = repo.store as? SQLiteEmailStore else { return [] }
        return try await sqlite.matchEvidence(emailID: emailID, spec: spec, freeText: freeText)
    }

    /// FIND-04: rows that pass the search's positive part but whose relevant
    /// text is not indexed yet — "may still match", counted apart.
    func unresolvedCount(query: EmailQuery) async throws -> Int {
        guard let repo = repository as? EmailStoreRepository,
              let sqlite = repo.store as? SQLiteEmailStore else { return 0 }
        // SEARCH-01: in the tier's scope, like the rows it sits next to — a
        // Free list of the newest 500 must not count "may still match" rows
        // from outside them.
        return try await sqlite.specUnresolvedCount(scoped(query))
    }

    /// FOLD-02: every folder of every source with its direct message count.
    func folderNodes() async throws -> [ArchiveFolderNode] {
        guard let repo = repository as? EmailStoreRepository,
              let sqlite = repo.store as? SQLiteEmailStore else { return [] }
        return try await sqlite.folderNodes()
    }

    /// FOLD-01: distinct labels/folders, optionally those containing `filter`.
    func parserTagTotal(matching filter: String? = nil) async throws -> Int {
        guard let repo = repository as? EmailStoreRepository,
              let sqlite = repo.store as? SQLiteEmailStore else { return 0 }
        return try await sqlite.parserTagTotal(matching: filter)
    }

    /// FOLD-01: one page of labels/folders, busiest first, optionally filtered.
    func parserTagCounts(matching filter: String?, offset: Int, limit: Int) async throws -> [AggregateBucket] {
        guard let repo = repository as? EmailStoreRepository,
              let sqlite = repo.store as? SQLiteEmailStore else { return [] }
        return try await sqlite.parserTagCounts(matching: filter, offset: offset, limit: limit)
    }

    /// sent / received / other counts.
    func messageTypeCounts() async throws -> [String: Int] {
        guard let repo = repository as? EmailStoreRepository,
              let sqlite = repo.store as? SQLiteEmailStore else { return [:] }
        return try await sqlite.messageTypeCounts()
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
        query unscoped: EmailQuery, batchSize: Int,
        _ body: ([EmailSummary]) async throws -> Void
    ) async throws {
        let query = scoped(unscoped)
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
