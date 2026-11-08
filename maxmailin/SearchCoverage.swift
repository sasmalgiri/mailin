@testable import ArchiveCore
//
//  SearchCoverage.swift
//  maxmailin
//
//  A6 / five jobs FIND-03: index-coverage truth. A search answers over what
//  the index holds at that moment; a "0 results" that does not say what was
//  covered is a false statement about the archive. This model reads bounded
//  counters — stored rows, indexed rows, partially indexed rows, and (with
//  the search model on) how many message bodies and attachments have an
//  evaluable text document — and the list shows them next to any result set
//  or empty state.
//
//  Plan §5.3.6: a counter that cannot be read is UNKNOWN, shown as
//  "coverage unavailable" with Retry — never zero, never a complete-looking
//  result.
//

import SwiftUI

struct SearchCoverageSnapshot: Equatable, Sendable {
    /// Rows in the store (including trashed rows, which stay indexed). Nil = could not be read.
    var storedMessages: Int?
    /// Rows the FTS index holds. Nil = could not be read.
    var indexedMessages: Int?
    /// Rows indexed only up to the per-message text budget (S0). Nil = could not be read.
    var partiallyIndexedMessages: Int?
    /// FIND-07: the chunk index's reach (nil when the search model is off or unreadable).
    var chunks: SQLiteEmailStore.SearchDocCoverage?
    /// FIND-03: per-attachment states (nil when nothing recorded or unreadable).
    var attachments: AttachmentCoverageSummary?
    var takenAt: Date = Date()

    init(storedMessages: Int?, indexedMessages: Int?, partiallyIndexedMessages: Int?,
         chunks: SQLiteEmailStore.SearchDocCoverage? = nil, attachments: AttachmentCoverageSummary? = nil, takenAt: Date = Date()) {
        self.storedMessages = storedMessages
        self.indexedMessages = indexedMessages
        self.partiallyIndexedMessages = partiallyIndexedMessages
        self.chunks = chunks
        self.attachments = attachments
        self.takenAt = takenAt
    }

    /// Completeness could not be checked.
    var isUnavailable: Bool { storedMessages == nil || indexedMessages == nil || partiallyIndexedMessages == nil }

    var pendingMessages: Int {
        guard let storedMessages, let indexedMessages else { return 0 }
        return max(0, storedMessages - indexedMessages)
    }
    /// True when a search could not have seen every stored message.
    var isPartial: Bool { pendingMessages > 0 }

    /// FIND-07: bodies the chunk index has not reached yet (search model on).
    var chunkPendingBodies: Int {
        guard let chunks else { return 0 }
        return max(0, chunks.emails - chunks.bodiesEvaluable)
    }
    /// FIND-03: attachments whose text cannot be evaluated yet (not extracted, unsupported, locked, failed).
    var attachmentsNotEvaluable: Int {
        guard let chunks else { return 0 }
        return max(0, chunks.attachments - chunks.attachmentsEvaluable)
    }
    /// Anything the line should say while a search is on screen.
    var needsNotice: Bool { isUnavailable || isPartial || (partiallyIndexedMessages ?? 0) > 0 || chunkPendingBodies > 0 || attachmentsNotEvaluable > 0 }

    var budgetLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(FTSSearchIndex.indexedTextBudgetBytes), countStyle: .file)
    }

    var summaryLine: String {
        if isUnavailable {
            return String(localized: "Coverage could not be checked — whether every message was searched is not known.")
        }
        var parts: [String] = []
        if isPartial {
            parts.append(String(localized: "Index covers \((indexedMessages ?? 0).formatted()) of \((storedMessages ?? 0).formatted()) messages — \(pendingMessages.formatted()) still indexing"))
        }
        if let chunks {
            if chunkPendingBodies > 0 {
                parts.append(String(localized: "Full text indexed for \(chunks.bodiesEvaluable.formatted()) of \(chunks.emails.formatted()) message bodies"))
            }
            if attachmentsNotEvaluable > 0 {
                var detail = String(localized: "attachment text evaluable for \(chunks.attachmentsEvaluable.formatted()) of \(chunks.attachments.formatted()) attachments")
                if let attachments {
                    var reasons: [String] = []
                    if let n = attachments.counts[.unsupported], n > 0 { reasons.append(String(localized: "\(n) unsupported")) }
                    if let n = attachments.counts[.locked], n > 0 { reasons.append(String(localized: "\(n) locked")) }
                    if let n = attachments.counts[.failed], n > 0 { reasons.append(String(localized: "\(n) failed")) }
                    if !reasons.isEmpty { detail += " (" + reasons.joined(separator: ", ") + ")" }
                }
                parts.append(detail)
            }
        } else if let partiallyIndexedMessages, partiallyIndexedMessages > 0, !isPartial {
            parts.append(String(localized: "Every message indexed; \(partiallyIndexedMessages.formatted()) very large messages only in their first \(budgetLabel)"))
        }
        if parts.isEmpty { return String(localized: "Index covers every message") }
        return parts.joined(separator: " · ")
    }
}

@MainActor
final class SearchCoverageModel: ObservableObject {
    @Published private(set) var snapshot: SearchCoverageSnapshot?
    /// The last read error, for the detail text.
    @Published private(set) var lastError: String?

    private let archive: ArchiveDataService
    private let fts: FTSSearchIndex

    init(archive: ArchiveDataService = .shared, fts: FTSSearchIndex = .shared) {
        self.archive = archive
        self.fts = fts
    }

    /// R7: `scope` (the list's query) scopes the files-inside-attachments counts;
    /// without one they are reported archive-wide.
    func refresh(scope: EmailQuery? = nil) async {
        var errors: [String] = []
        func read<T>(_ what: String, _ body: () async throws -> T) async -> T? {
            do { return try await body() } catch { errors.append("\(what): \(error.localizedDescription)"); return nil }
        }
        let stored = await read("stored") { try await archive.storedTotalCount() }
        let indexed = await read("indexed") { try await fts.rowCount() }
        let partial = await read("partial") { try FTSSearchIndex.partiallyIndexedCountSnapshot() }
        var chunks: SQLiteEmailStore.SearchDocCoverage? = nil
        var attachments: AttachmentCoverageSummary? = nil
        if SearchChunkPolicy.isEnabled {
            chunks = await read("chunks") { try await archive.searchDocCoverage() }
            if let store = archive.sqliteStore {
                attachments = await AttachmentTextIndexJob.coverageSummary(store: store, scope: scope)
            }
        }
        snapshot = SearchCoverageSnapshot(storedMessages: stored, indexedMessages: indexed, partiallyIndexedMessages: partial,
                                          chunks: chunks, attachments: attachments)
        lastError = errors.isEmpty ? nil : errors.joined(separator: "; ")
    }
}

/// One line above a result list while the index is behind the store, or
/// while completeness cannot be checked.
struct SearchCoverageLine: View {
    let coverage: SearchCoverageSnapshot
    var onRetry: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: coverage.isUnavailable ? "exclamationmark.triangle" : "text.magnifyingglass")
                .font(.caption2)
                .foregroundStyle(coverage.isUnavailable ? .red : .orange)
            Text(coverage.summaryLine)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if coverage.isUnavailable, let onRetry {
                Button(String(localized: "Retry")) { onRetry() }
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle(.tint)
                    .accessibilityIdentifier("search.coverage.retry")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background((coverage.isUnavailable ? Color.red : Color.orange).opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
        .help(coverage.isUnavailable
              ? String(localized: "The index counters could not be read; the result list is still correct for what was searched, but completeness is unknown")
              : String(localized: "Results are drawn from the indexed messages only; the rest join as indexing finishes"))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("search.coverage.line")
    }
}
