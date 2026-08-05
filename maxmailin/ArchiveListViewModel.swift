//
//  ArchiveListViewModel.swift
//  maxmailin
//
//  Stage 5D.1A (v2-core-cutover): a bounded, repository-backed list model. Its
//  single job is to browse a large archive correctly using bounded
//  `EmailSummary` pages from `ArchiveDataService` — NOT to reproduce the legacy
//  filter/analytics/AI machinery (those migrate in their own slices).
//
//  Bounded by construction:
//    • keyset pages of `pageSize`; only `maxRetained` summaries are ever kept
//      resident (older pages are dropped as you scroll forward — a reverse
//      scroll re-fetches from the top via reload()).
//    • a monotonically increasing `queryRevision` discards any in-flight page
//      whose query was superseded, so a slow old response can never overwrite a
//      newer query's results.
//

import Foundation

@MainActor
final class ArchiveListViewModel: ObservableObject {
    @Published private(set) var summaries: [EmailSummary] = []
    @Published private(set) var totalCount = 0
    @Published private(set) var isLoading = false
    @Published private(set) var hasMore = false
    @Published private(set) var error: Error?

    private(set) var query: EmailQuery = .all
    private var nextCursor: EmailPageCursor?
    private var queryRevision: UInt64 = 0

    private let archive: ArchiveDataService
    let pageSize: Int
    let maxRetained: Int

    /// High-water mark of resident summaries — lets a test assert the window
    /// stays bounded across a large traversal.
    private(set) var maxRetainedObserved = 0

    #if DEBUG
    /// Test hook: every appended page is reported here so a bounded traversal
    /// can verify no-skip/no-duplicate even while the resident window is capped.
    var _debugOnAppend: (([EmailSummary]) -> Void)?
    #endif

    init(archive: ArchiveDataService = .shared, pageSize: Int = 100, maxRetained: Int = 2_000) {
        self.archive = archive
        self.pageSize = max(1, pageSize)
        self.maxRetained = max(self.pageSize, maxRetained)
    }

    /// Load (or reload) the first page for the current query.
    func loadInitial() async {
        queryRevision &+= 1
        let revision = queryRevision
        summaries = []
        nextCursor = nil
        hasMore = false
        error = nil
        isLoading = true
        do {
            let count = try await archive.count(query: query)
            let page = try await archive.page(query: query, cursor: nil, limit: pageSize)
            guard revision == queryRevision else { return }   // superseded by a newer query
            totalCount = count
            let batch = Array(page.summaries.prefix(pageSize))
            summaries = batch
            nextCursor = page.nextCursor
            hasMore = page.nextCursor != nil
            maxRetainedObserved = max(maxRetainedObserved, summaries.count)
            isLoading = false
            #if DEBUG
            _debugOnAppend?(batch)
            #endif
        } catch {
            guard revision == queryRevision else { return }
            self.error = error
            isLoading = false
        }
    }

    /// Load the next keyset page (no-op if already loading or at the end).
    func loadNextPage() async {
        guard hasMore, !isLoading, let cursor = nextCursor else { return }
        let revision = queryRevision
        isLoading = true
        do {
            let page = try await archive.page(query: query, cursor: cursor, limit: pageSize)
            guard revision == queryRevision else { return }   // query changed mid-flight
            let batch = Array(page.summaries.prefix(pageSize))
            summaries.append(contentsOf: batch)
            // Bounded window: drop the oldest resident pages beyond the cap.
            if summaries.count > maxRetained {
                summaries.removeFirst(summaries.count - maxRetained)
            }
            nextCursor = page.nextCursor
            hasMore = page.nextCursor != nil
            maxRetainedObserved = max(maxRetainedObserved, summaries.count)
            isLoading = false
            #if DEBUG
            _debugOnAppend?(batch)
            #endif
        } catch {
            guard revision == queryRevision else { return }
            self.error = error
            isLoading = false
        }
    }

    /// Change the query and reload from the first page.
    func setQuery(_ newQuery: EmailQuery) async {
        query = newQuery
        await loadInitial()
    }

    func reload() async { await loadInitial() }

    /// Hydrate a full email on demand (detail view).
    func fullEmail(id: EmailID) async throws -> MBOXParser.RawEmail? {
        try await archive.fullEmail(id: id)
    }

    /// Clear state and cancel any in-flight page (via revision bump).
    func reset() {
        queryRevision &+= 1
        summaries = []
        nextCursor = nil
        hasMore = false
        isLoading = false
        error = nil
        totalCount = 0
    }
}
