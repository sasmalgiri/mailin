//
//  ArchiveListViewModel.swift
//  maxmailin
//
//  Stage 5 Wave 1A (v2-core-cutover): the production list data source — a
//  bounded, bidirectional page WINDOW over the SQLite archive via
//  `ArchiveDataService`. NOT the legacy 1087-line model.
//
//  Boundedness with good live-scroll UX:
//    • Keyset pages of `pageSize`. Only `windowPages` pages are ever resident
//      (an LRU-ish sliding window); scrolling forward drops the front page,
//      scrolling back re-fetches it using its remembered START cursor — so
//      backward browsing beyond the window works WITHOUT a reverse query, and
//      resident memory never exceeds `windowPages * pageSize` summaries.
//    • A monotonically increasing `queryRevision` discards any in-flight page
//      whose query was superseded, so a slow old response can never overwrite a
//      newer query's results.
//

import Foundation

@MainActor
final class ArchiveListViewModel: ObservableObject {
    /// The concatenation of the resident window's pages, in archive order.
    @Published private(set) var summaries: [EmailSummary] = []
    @Published private(set) var totalCount = 0
    @Published private(set) var isLoading = false
    @Published private(set) var hasMore = false          // more pages after the window's tail
    @Published private(set) var hasPrevious = false      // pages exist before the window's head
    @Published private(set) var error: Error?

    private(set) var query: EmailQuery = .all
    private var queryRevision: UInt64 = 0

    // Page bookkeeping. `startCursor[i]` fetches page i (page 0 = nil). Kept for
    // all discovered pages (lightweight cursors only, NOT summaries) so a
    // dropped page can be re-fetched. `nextCursor[i]` is the cursor after page i.
    private var residentPages: [(index: Int, summaries: [EmailSummary])] = []
    private var startCursor: [Int: EmailPageCursor?] = [:]
    private var nextCursorByPage: [Int: EmailPageCursor?] = [:]
    private var lastDiscoveredPage = -1   // highest page index whose existence is known

    private let archive: ArchiveDataService
    let pageSize: Int
    let windowPages: Int

    private(set) var maxRetainedObserved = 0

    #if DEBUG
    /// Test hook: every freshly-fetched page's summaries are reported here.
    var _debugOnAppend: (([EmailSummary]) -> Void)?
    #endif

    /// `maxRetained` is expressed in summaries for continuity with earlier
    /// tests; it is converted to a whole number of resident pages.
    init(archive: ArchiveDataService = .shared, pageSize: Int = 100, maxRetained: Int = 500) {
        self.archive = archive
        self.pageSize = max(1, pageSize)
        self.windowPages = max(1, maxRetained / max(1, pageSize))
    }

    var maxRetained: Int { windowPages * pageSize }

    // MARK: - Loading

    /// Load (or reload) from the first page for the current query.
    func loadInitial() async {
        queryRevision &+= 1
        let revision = queryRevision
        residentPages = []
        startCursor = [:]
        nextCursorByPage = [:]
        lastDiscoveredPage = -1
        summaries = []
        hasMore = false
        hasPrevious = false
        error = nil
        isLoading = true
        do {
            let count = try await archive.count(query: query)
            let page = try await archive.page(query: query, cursor: nil, limit: pageSize)
            guard revision == queryRevision else { return }
            totalCount = count
            let batch = Array(page.summaries.prefix(pageSize))
            startCursor[0] = .some(nil)
            nextCursorByPage[0] = page.nextCursor
            lastDiscoveredPage = 0
            residentPages = [(0, batch)]
            rebuildPublished()
            hasMore = page.nextCursor != nil
            hasPrevious = false
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

    /// Load the page after the window's tail; drop the head if over the window.
    func loadNextPage() async {
        guard !isLoading, let tail = residentPages.last else { return }
        guard let cursor = nextCursorByPage[tail.index] ?? nil else { return }  // no next → at end
        let newIndex = tail.index + 1
        let revision = queryRevision
        isLoading = true
        do {
            let page = try await archive.page(query: query, cursor: cursor, limit: pageSize)
            guard revision == queryRevision else { return }
            let batch = Array(page.summaries.prefix(pageSize))
            startCursor[newIndex] = .some(cursor)
            nextCursorByPage[newIndex] = page.nextCursor
            lastDiscoveredPage = max(lastDiscoveredPage, newIndex)
            residentPages.append((newIndex, batch))
            if residentPages.count > windowPages { residentPages.removeFirst() }
            rebuildPublished()
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

    /// Load the page before the window's head (re-fetch via its remembered
    /// start cursor); drop the tail if over the window.
    func loadPreviousPage() async {
        guard !isLoading, let head = residentPages.first, head.index > 0 else { return }
        let prevIndex = head.index - 1
        // The remembered start cursor for a page re-fetches it (page 0 → nil).
        guard let fetchCursor = startCursor[prevIndex] else { return }
        let revision = queryRevision
        isLoading = true
        do {
            let page = try await archive.page(query: query, cursor: fetchCursor, limit: pageSize)
            guard revision == queryRevision else { return }
            let batch = Array(page.summaries.prefix(pageSize))
            nextCursorByPage[prevIndex] = page.nextCursor
            residentPages.insert((prevIndex, batch), at: 0)
            if residentPages.count > windowPages { residentPages.removeLast() }
            rebuildPublished()
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

    private func rebuildPublished() {
        summaries = residentPages.flatMap(\.summaries)
        hasMore = (nextCursorByPage[residentPages.last?.index ?? 0] ?? nil) != nil
        hasPrevious = (residentPages.first?.index ?? 0) > 0
        maxRetainedObserved = max(maxRetainedObserved, summaries.count)
    }

    // MARK: - Query / detail / lifecycle

    func setQuery(_ newQuery: EmailQuery) async {
        query = newQuery
        await loadInitial()
    }

    func reload() async { await loadInitial() }

    func fullEmail(id: EmailID) async throws -> MBOXParser.RawEmail? {
        try await archive.fullEmail(id: id)
    }

    func reset() {
        queryRevision &+= 1
        residentPages = []
        startCursor = [:]
        nextCursorByPage = [:]
        lastDiscoveredPage = -1
        summaries = []
        hasMore = false
        hasPrevious = false
        isLoading = false
        error = nil
        totalCount = 0
    }
}
