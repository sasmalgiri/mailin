//
//  ImportVerdict.swift
//  mailin
//
//  Plan task A5. The directive's rule for Page 1: an import is **Complete only
//  if counts and index state reconcile**, and anything else must be labelled
//  Partial or Failed *precisely*. Until now the coordinator reported
//  `.completed` whenever no error was thrown, which is exactly the "looked
//  imported without reaching the store" failure the receipt exists to prevent.
//
//  The verdict is COMPUTED from the receipt's own numbers rather than stored:
//  a new stored field would change the receipt's canonical encoding and so
//  invalidate the content hash of every receipt already written to disk.
//

import Foundation

/// Why an import did not come out Complete. Each case names one specific,
/// checkable condition — no catch-all "something went wrong".
enum ImportShortfall: String, Sendable, Equatable, CaseIterable {
    /// Messages the parser could not read (recovered and counted, not silently
    /// dropped).
    case damagedMessages
    /// Parsed messages whose store insert failed.
    case persistFailures
    /// Whole source files that failed.
    case sourceFileFailures
    /// Fewer rows are searchable than were stored.
    case indexIncomplete
    /// FTS is knowingly behind and needs the reconciler.
    case reconciliationPending
    /// Parsed messages that are neither stored, nor duplicates, nor counted as
    /// persist failures — an accounting hole, the most serious shortfall short
    /// of outright failure.
    case unaccountedMessages

    var explanation: String {
        switch self {
        case .damagedMessages:
            return "Some messages could not be read and were skipped."
        case .persistFailures:
            return "Some messages were read but could not be saved."
        case .sourceFileFailures:
            return "Some source files could not be imported."
        case .indexIncomplete:
            return "Fewer messages are searchable than were saved."
        case .reconciliationPending:
            return "The search index is behind and needs to be rebuilt."
        case .unaccountedMessages:
            return "Some messages are unaccounted for between reading and saving."
        }
    }
}

/// The only three outcomes an import may report.
enum ImportVerdict: Sendable, Equatable {
    /// Every discovered message is accounted for and searchable.
    case complete
    /// The import produced usable results with named gaps.
    case partial([ImportShortfall])
    /// Nothing usable came out of at least one source.
    case failed([ImportShortfall])

    var isComplete: Bool { self == .complete }

    var shortfalls: [ImportShortfall] {
        switch self {
        case .complete: return []
        case .partial(let s), .failed(let s): return s
        }
    }

    /// Short label for the receipt window and the import queue.
    var label: String {
        switch self {
        case .complete: return "Complete"
        case .partial: return "Partial"
        case .failed: return "Failed"
        }
    }

    /// One sentence a non-specialist can act on.
    var summary: String {
        switch self {
        case .complete:
            return "Every message was imported and is searchable."
        case .partial(let shortfalls), .failed(let shortfalls):
            return shortfalls.map(\.explanation).joined(separator: " ")
        }
    }
}

/// Decides the verdict from a receipt. Pure and total, so it is unit-testable
/// and cannot depend on whether an exception happened to be thrown.
enum ImportReconciler {

    static func verdict(for receipt: ImportReceipt) -> ImportVerdict {
        var shortfalls: [ImportShortfall] = []

        if receipt.damaged > 0 { shortfalls.append(.damagedMessages) }
        if receipt.persistFailed > 0 { shortfalls.append(.persistFailures) }
        if !receipt.fileFailures.isEmpty { shortfalls.append(.sourceFileFailures) }
        if receipt.reconciliationPending || receipt.ftsDegraded {
            shortfalls.append(.reconciliationPending)
        }

        // Index coverage: compare against what actually reached the store. When
        // the store delta is unavailable it is never fabricated, so fall back to
        // parsed-minus-failures rather than assuming zero.
        let expectedSearchable = receipt.inserted ?? max(0, receipt.parsed - receipt.persistFailed)
        if receipt.indexed < expectedSearchable, !shortfalls.contains(.reconciliationPending) {
            shortfalls.append(.indexIncomplete)
        }

        // Accounting hole: only checked when both deltas are known, because a
        // nil count means "unavailable", not "zero".
        if let inserted = receipt.inserted, let duplicates = receipt.duplicates {
            let accountedFor = inserted + duplicates + receipt.persistFailed
            if accountedFor < receipt.parsed {
                shortfalls.append(.unaccountedMessages)
            }
        }

        guard !shortfalls.isEmpty else { return .complete }

        // Failed, not merely partial, when nothing usable came out: messages
        // were discovered but none were parsed, or none of what was parsed
        // reached the store, or every source file failed.
        let parsedNothing = receipt.discovered > 0 && receipt.parsed == 0
        let storedNothing = receipt.parsed > 0 && (receipt.inserted ?? 0) == 0
            && receipt.persistFailed > 0
        let everySourceFailed = !receipt.sources.isEmpty
            && receipt.fileFailures.count >= receipt.sources.count
        if parsedNothing || storedNothing || everySourceFailed {
            return .failed(shortfalls)
        }
        return .partial(shortfalls)
    }
}

extension ImportReceipt {
    /// Complete / Partial / Failed, derived from this receipt's own counts.
    var verdict: ImportVerdict { ImportReconciler.verdict(for: self) }
}
