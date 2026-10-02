@testable import ArchiveCore
//
//  SearchCoverage.swift
//  maxmailin
//
//  A6: index-coverage truth. A search answers over the messages the index
//  holds at that moment. During an import, or while a backfill is catching
//  up, that is fewer than the archive holds — and a "0 results" that does not
//  say so is a false statement about the archive. This model reads three
//  bounded counters (stored rows, indexed rows, partially indexed rows) and
//  the list shows them next to any result set or empty state.
//

import SwiftUI

struct SearchCoverageSnapshot: Equatable, Sendable {
    /// Rows in the store (including trashed rows, which stay indexed).
    var storedMessages: Int
    /// Rows the FTS index holds.
    var indexedMessages: Int
    /// Rows indexed only up to the per-message text budget (S0).
    var partiallyIndexedMessages: Int
    var takenAt: Date = Date()

    var pendingMessages: Int { max(0, storedMessages - indexedMessages) }
    /// True when a search could not have seen every stored message.
    var isPartial: Bool { pendingMessages > 0 }

    var budgetLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(FTSSearchIndex.indexedTextBudgetBytes), countStyle: .file)
    }

    var summaryLine: String {
        if isPartial {
            return "Index covers \(indexedMessages.formatted()) of \(storedMessages.formatted()) messages — \(pendingMessages.formatted()) still indexing"
        }
        if partiallyIndexedMessages > 0 {
            return "Every message indexed; \(partiallyIndexedMessages.formatted()) very large messages only in their first \(budgetLabel)"
        }
        return String(localized: "Index covers every message")
    }
}

@MainActor
final class SearchCoverageModel: ObservableObject {
    @Published private(set) var snapshot: SearchCoverageSnapshot?

    private let archive: ArchiveDataService
    private let fts: FTSSearchIndex

    init(archive: ArchiveDataService = .shared, fts: FTSSearchIndex = .shared) {
        self.archive = archive
        self.fts = fts
    }

    func refresh() async {
        let stored = (try? await archive.storedTotalCount()) ?? 0
        let indexed = (try? await fts.rowCount()) ?? 0
        let partial = (try? FTSSearchIndex.partiallyIndexedCountSnapshot()) ?? 0
        snapshot = SearchCoverageSnapshot(storedMessages: stored,
                                          indexedMessages: indexed,
                                          partiallyIndexedMessages: partial)
    }
}

/// One line above a result list while the index is behind the store.
struct SearchCoverageLine: View {
    let coverage: SearchCoverageSnapshot

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "text.magnifyingglass")
                .font(.caption2)
                .foregroundStyle(.orange)
            Text(coverage.summaryLine)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
        .help("Results are drawn from the indexed messages only; the rest join as indexing finishes")
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("search.coverage.line")
    }
}
