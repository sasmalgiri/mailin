//
//  PaginatedEmailViewModel.swift
//  maxmailin
//
//  Memory-bounded list source for SwiftUI views. Holds only a window of
//  emails in RAM regardless of total archive size. Backed by EmailStore.
//
//  Pagination is keyset (cursor-based) on the (date, id) tuple, not offset
//  based. At depth — e.g. when the user has scrolled to position 1,000,000
//  in the archive — offset-based pagination forces SQLite to scan and
//  discard that many rows on every request, which freezes the UI. Keyset
//  pagination uses the existing date index to seek directly to the cursor
//  position; jumping deep into the archive is no slower than the first page.
//
//  Use this in place of `[RawEmail]` arrays in any view that needs to scroll
//  through the full archive at scale.
//

import Foundation
import SwiftUI

@MainActor
@Observable
final class PaginatedEmailViewModel {
    var emails: [MBOXParser.RawEmail] = []
    var totalCount: Int = 0
    var isLoading: Bool = false
    var loadError: String?

    private let pageSize: Int

    // Keyset cursor: the (date, id) tuple of the last row in the most-recent
    // page. Pass these to `pageKeyset` to fetch strictly older rows. Both nil
    // on first load — that path fetches the newest `pageSize` rows.
    private var cursorDate: Date?
    private var cursorID: UUID?
    private var didReachEnd: Bool = false

    init(pageSize: Int = 100) {
        self.pageSize = pageSize
    }

    /// Reload from the top. Call when the user pulls-to-refresh or when the
    /// underlying SwiftData store changes.
    func refresh() async {
        cursorDate = nil
        cursorID = nil
        didReachEnd = false
        emails = []
        await loadMore()
        await refreshTotalCount()
    }

    /// Append the next page. Safe to call repeatedly; no-ops once the end
    /// is reached. Designed to be called from `.onAppear` on a sentinel row
    /// near the bottom of the visible list.
    func loadMore() async {
        guard !isLoading, !didReachEnd else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            let page = try await EmailStore.shared.pageKeyset(
                beforeDate: cursorDate,
                beforeID: cursorID,
                limit: pageSize
            )
            if page.isEmpty {
                didReachEnd = true
                return
            }
            emails.append(contentsOf: page)
            // Advance the cursor to the last row of this page. `MBOXParser.parseDate`
            // matches the parsing EmailStore uses to write the StoredEmail.date column,
            // so the cursor lines up with the database's sort key.
            if let last = page.last {
                cursorDate = MBOXParser.parseDate(last.headers["Date"]) ?? .distantPast
                cursorID = last.id
            }
            if page.count < pageSize {
                didReachEnd = true
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Async fetch of full body for an email when the user opens it. The list
    /// only carries previews; bodies are loaded on demand.
    func fullEmail(id: UUID) async -> MBOXParser.RawEmail? {
        do {
            return try await EmailStore.shared.fullEmail(id: id)
        } catch {
            loadError = error.localizedDescription
            return nil
        }
    }

    private func refreshTotalCount() async {
        do {
            totalCount = try await EmailStore.shared.totalCount()
        } catch {
            // Non-fatal; UI just won't show a total.
        }
    }
}
