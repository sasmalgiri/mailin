//
//  DocumentRegistry.swift
//  maxmailin
//
//  SAP-style document numbers: nothing is real until it has a number you
//  can quote. Types are typed prefixes with per-year ranges (IMP-2026-0001);
//  numbers come from the store's transactional counters, are embedded in
//  the artifacts they identify, and are echoed into the audit chain.
//

import Foundation

/// Pure formatting — unit-tested independent of the store.
enum DocumentNumberFormat {
    static func format(type: String, year: Int, sequence: Int) -> String {
        String(format: "%@-%d-%04d", type.uppercased(), year, sequence)
    }

    /// Master-element alias for a source row: SRC-0001.
    static func sourceAlias(_ sourceID: Int64) -> String {
        String(format: "SRC-%04d", sourceID)
    }
}

/// The document types the app posts. Adding one is adding a case —
/// the range machinery is type-agnostic.
enum DocumentType: String {
    case importRun = "IMP"        // an import completed
    case triageVerdict = "VRD"    // a phishing-triage verdict
    case export = "EXP"           // anything produced/left the app
    case report = "RPT"           // daily activity / defensibility reports
    case storyVersion = "STY"     // a saved story-file version
    case cleanup = "CLN"          // archive-wide duplicate removal

    var displayName: String {
        switch self {
        case .importRun: return "Import"
        case .triageVerdict: return "Triage Verdict"
        case .export: return "Export"
        case .report: return "Report"
        case .storyVersion: return "Story Version"
        case .cleanup: return "Cleanup"
        }
    }

    var icon: String {
        switch self {
        case .importRun: return "square.and.arrow.down"
        case .triageVerdict: return "tag"
        case .export: return "square.and.arrow.up"
        case .report: return "doc.badge.clock"
        case .storyVersion: return "text.book.closed"
        case .cleanup: return "trash"
        }
    }
}

enum DocumentRegistry {
    /// Issue a number, echo it into the audit chain, return it.
    /// Never throws to callers — a registry hiccup must not block the
    /// workflow itself; the audit entry still records the action.
    @MainActor
    static func post(_ type: DocumentType, summary: String, refs: String = "") async -> String? {
        let number = try? await SQLiteEmailStore.shared.issueDocument(
            type: type.rawValue, summary: summary, refs: refs)
        if let number {
            ForensicManager.shared.logAction(
                "Document posted: \(number)", detail: summary)
        }
        return number
    }
}
