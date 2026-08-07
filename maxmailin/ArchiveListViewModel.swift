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

    /// Unified page cursor: non-text queries page by keyset; text queries page
    /// by the ranked (bm25) continuation cursor (Part P2) — so the list can
    /// scroll DEEP into ranked search results instead of seeing only a fixed
    /// first window. Both are bounded value types.
    private enum PageCursor: Equatable {
        case keyset(EmailPageCursor)
        case ranked(RankedSearchCursor)
    }

    // Page bookkeeping. `startCursor[i]` fetches page i (page 0 = nil). Kept for
    // all discovered pages (lightweight cursors only, NOT summaries) so a
    // dropped page can be re-fetched. `nextCursor[i]` is the cursor after page i.
    private var residentPages: [(index: Int, summaries: [EmailSummary])] = []
    private var startCursor: [Int: PageCursor?] = [:]
    private var nextCursorByPage: [Int: PageCursor?] = [:]
    private var lastDiscoveredPage = -1   // highest page index whose existence is known

    /// One page fetch, routed by query shape (ranked continuation for text,
    /// keyset for everything else).
    private func fetchPage(startingAt cursor: PageCursor?) async throws -> (batch: [EmailSummary], next: PageCursor?) {
        if !(query.text?.isEmpty ?? true) {
            let rankedCursor: RankedSearchCursor?
            if case .ranked(let c) = cursor { rankedCursor = c } else { rankedCursor = nil }
            let page = try await archive.searchRanked(query: query, cursor: rankedCursor, limit: pageSize)
            return (Array(page.summaries.prefix(pageSize)), page.nextCursor.map(PageCursor.ranked))
        }
        let keysetCursor: EmailPageCursor?
        if case .keyset(let c) = cursor { keysetCursor = c } else { keysetCursor = nil }
        let page = try await archive.page(query: query, cursor: keysetCursor, limit: pageSize)
        return (Array(page.summaries.prefix(pageSize)), page.nextCursor.map(PageCursor.keyset))
    }

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

    /// Ordered ids of the loaded page window — the detail view's navigation
    /// order (Part R: detail navigation sources list PAGE state, never a
    /// whole-corpus array).
    var visibleOrderedIDs: [EmailID] { summaries.map(\.id) }

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
            let (batch, next) = try await fetchPage(startingAt: nil)
            guard revision == queryRevision else { return }
            totalCount = count
            startCursor[0] = .some(nil)
            nextCursorByPage[0] = next
            lastDiscoveredPage = 0
            residentPages = [(0, batch)]
            rebuildPublished()
            hasMore = next != nil
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
            let (batch, next) = try await fetchPage(startingAt: cursor)
            guard revision == queryRevision else { return }
            startCursor[newIndex] = .some(cursor)
            nextCursorByPage[newIndex] = next
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
            let (batch, next) = try await fetchPage(startingAt: fetchCursor)
            guard revision == queryRevision else { return }
            nextCursorByPage[prevIndex] = next
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

    /// §19.1: "Delete" in the browse UI is Move to Trash — a restorable review
    /// flag, never physical destruction. Pages/counts exclude trashed rows, so
    /// a reload reflects the removal with no skip/duplicate corruption.
    func delete(_ ids: Set<EmailID>) async {
        guard !ids.isEmpty else { return }
        do {
            try await archive.setTrashed(ids: Array(ids), true)
        } catch {
            self.error = error
        }
        await loadInitial()
    }

    /// Restore trashed emails back into the browse surfaces.
    func restore(_ ids: Set<EmailID>) async {
        guard !ids.isEmpty else { return }
        do {
            try await archive.setTrashed(ids: Array(ids), false)
        } catch {
            self.error = error
        }
        await loadInitial()
    }

    /// PERMANENT deletion — distinct, explicit operation (row + FTS ghost).
    func permanentlyDelete(_ ids: Set<EmailID>) async {
        guard !ids.isEmpty else { return }
        do {
            try await archive.delete(ids: Array(ids))
        } catch {
            self.error = error
        }
        await loadInitial()
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
