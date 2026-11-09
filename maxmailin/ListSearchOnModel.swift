@testable import ArchiveCore
//
//  ListSearchOnModel.swift
//  maxmailin
//
//  IPAD-03 (gate 1 walk, 2026-11-08): the full list (`ParsedEmailListViewModel`
//  — the default list on the Mac, the iPad list and the iPhone list) ran the
//  typed words on the previous per-year FTS index, so text that only an
//  attachment holds (a DOCX, a DOCX inside a ZIP) was never found, and a
//  search with no hits left a blank pane. The three-pane shell already ran
//  them on the search model (CAP-01). This file holds what the full list now
//  shares with it: the "no match" notice that says what was searched, read
//  from the same coverage counters (FIND-03 / FIND-07).
//

import Foundation

enum ModelSearchNotice {
    /// The coverage the search model answered over: stored messages, the
    /// chunk index's reach (bodies and attachments with an evaluable text
    /// document) and the per-attachment states. Nil when the counters could
    /// not be read — said as "not known", never as zero.
    @MainActor
    /// R7: `scope` (the search's query) scopes the files-inside-attachments counts.
    static func snapshot(archive: ArchiveDataService, scope: EmailQuery? = nil) async -> SearchCoverageSnapshot? {
        guard let stored = try? await archive.storedTotalCount(),
              let chunks = try? await archive.searchDocCoverage() else { return nil }
        var attachments: AttachmentCoverageSummary? = nil
        if let store = archive.sqliteStore {
            attachments = await AttachmentTextIndexJob.coverageSummary(store: store, scope: scope)
        }
        // The model reads the chunk index, so its reach is measured there
        // (`chunks`), not against the previous FTS shards.
        return SearchCoverageSnapshot(storedMessages: stored, indexedMessages: stored, partiallyIndexedMessages: 0,
                                      chunks: chunks, attachments: attachments)
    }

    /// What a search with no hits says: never a bare zero. The wording is the
    /// three-pane shell's empty state (`ArchiveNoResultsState`) plus the
    /// FIND-03 attachment line, so both lists say the same thing.
    static func noMatch(coverage: SearchCoverageSnapshot?) -> String {
        headline(coverage) + ". " + detail(coverage)
    }

    /// SEARCH-03: the five no-match cases, decided once for both lists.
    enum NoMatchCase: Equatable {
        /// The counters could not be read.
        case unknown
        /// Messages still waiting for the index.
        case indexing
        /// Bodies or attachments whose text is not evaluable yet.
        case textPending
        /// Everything indexed, but files inside attachments were not read
        /// (locked, unsupported, failed, partly read) or their states are unknown.
        case unreadableFiles
        /// Every message, attachment and file inside one was searched.
        case complete
    }

    static func noMatchCase(_ coverage: SearchCoverageSnapshot?) -> NoMatchCase {
        guard let coverage, !coverage.isUnavailable else { return .unknown }
        if coverage.isPartial { return .indexing }
        if coverage.chunkPendingBodies > 0 || coverage.attachmentsNotEvaluable > 0 { return .textPending }
        if coverage.childNotice != nil { return .unreadableFiles }
        return .complete
    }

    static func headline(_ coverage: SearchCoverageSnapshot?) -> String {
        switch noMatchCase(coverage) {
        case .unknown: return String(localized: "No matches — coverage could not be checked")
        case .indexing, .textPending: return String(localized: "No matches found yet — indexing is incomplete")
        case .unreadableFiles: return String(localized: "No matches in the text that could be read")
        case .complete: return String(localized: "No matching emails")
        }
    }

    static func detail(_ coverage: SearchCoverageSnapshot?) -> String {
        guard let coverage else {
            return String(localized: "The index counters could not be read, so whether every message was searched is not known.")
        }
        switch noMatchCase(coverage) {
        case .unknown:
            return String(localized: "The index counters could not be read, so whether every message was searched is not known.")
        case .indexing:
            return String(localized: "Searched the \((coverage.indexedMessages ?? 0).formatted()) of \((coverage.storedMessages ?? 0).formatted()) messages indexed so far — \(coverage.pendingMessages.formatted()) still indexing. Results may change as indexing finishes.")
        case .textPending, .unreadableFiles:
            return coverage.summaryLine
        case .complete:
            var text: String
            if let partial = coverage.partiallyIndexedMessages, partial > 0 {
                text = String(localized: "Searched every message. \(partial.formatted()) very large messages are indexed only in their first \(coverage.budgetLabel).")
            } else {
                text = String(localized: "Nothing in the fully indexed scope matches this search.")
            }
            if let attachments = coverage.attachments, attachments.total > 0 {
                text += " " + AttachmentTextIndexJob.noMatchNotice(attachments)
            }
            return text
        }
    }
}
