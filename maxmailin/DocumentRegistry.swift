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
    case legalHold = "HLD"        // a legal-hold / preservation notice
    case timeline = "TML"         // a reconstructed timeline exhibit
    case subjectResponse = "DSR"  // a data-subject (DSAR) response
    case threatHunt = "HNT"       // a proactive threat-hunt report
    case entityMap = "MAP"        // an entity / network map

    var displayName: String {
        switch self {
        case .importRun: return "Import"
        case .triageVerdict: return "Triage Verdict"
        case .export: return "Export"
        case .report: return "Report"
        case .storyVersion: return "Story Version"
        case .cleanup: return "Cleanup"
        case .legalHold: return "Legal Hold"
        case .timeline: return "Timeline"
        case .subjectResponse: return "Subject Response"
        case .threatHunt: return "Threat Hunt"
        case .entityMap: return "Entity Map"
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
        case .legalHold: return "hand.raised"
        case .timeline: return "calendar.day.timeline.left"
        case .subjectResponse: return "person.text.rectangle"
        case .threatHunt: return "binoculars"
        case .entityMap: return "point.3.connected.trianglepath.dotted"
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

    /// Universal capture — the SAP promise: any job, small or big, becomes a
    /// numbered document that reproduces the FULL work when opened. Posts the
    /// document, stamps who, attaches the complete `body` payload, folds a
    /// client/matter tag into search text, and echoes to the audit chain.
    /// Returns the document number. Always call this for tool completions so
    /// nothing the user does is lost.
    @MainActor
    @discardableResult
    static func capture(_ type: DocumentType, summary: String, body: String,
                        refs: String = "") async -> String? {
        let store = SQLiteEmailStore.shared
        let who = ForensicManager.shared.examinerName
        let number = try? await store.issueDocument(
            type: type.rawValue, summary: summary, refs: refs, createdBy: who)
        guard let number else { return nil }
        try? await store.attachDocumentPayload(number, body: body)
        ForensicManager.shared.logAction("Document posted: \(number)", detail: summary)
        return number
    }

    /// Structured capture — stores every field as typed key/value data (JSON),
    /// so the document opens as a spreadsheet-like table and can be exported to
    /// CSV / manipulated into custom reports. Maximum data fidelity.
    @MainActor
    @discardableResult
    static func captureStructured(_ type: DocumentType, summary: String,
                                  document: CapturedDocument, refs: String = "") async -> String? {
        let store = SQLiteEmailStore.shared
        let who = ForensicManager.shared.examinerName
        guard let number = try? await store.issueDocument(
            type: type.rawValue, summary: summary, refs: refs, createdBy: who) else { return nil }
        try? await store.attachDocumentPayload(number, contentType: "application/json",
                                               body: document.jsonString())
        ForensicManager.shared.logAction("Document posted: \(number)", detail: summary)
        return number
    }
}

// MARK: - Workflow facade (v8)

@MainActor
enum WorkflowService {
    /// Seed the built-in recipes once per launch (idempotent upsert by defID).
    static func seedBuiltins() async {
        for def in WorkflowCatalog.all {
            let ops = def.operations.map {
                SQLiteEmailStore.StoredOperation(
                    seq: $0.seq, key: $0.key, title: $0.title, hint: $0.hint,
                    postsDocType: $0.postsDocType?.rawValue)
            }
            try? await SQLiteEmailStore.shared.upsertDefinition(
                defID: def.defID, name: def.name, persona: def.persona,
                builtin: true, operations: ops,
                createdBy: ForensicManager.shared.examinerName)
        }
    }

    /// Start a run; audit-logs the WF number.
    static func start(_ def: WorkflowDefinition, title: String) async -> String? {
        let wf = try? await SQLiteEmailStore.shared.createInstance(
            defID: def.defID, title: title,
            createdBy: ForensicManager.shared.examinerName)
        if let wf {
            ForensicManager.shared.logAction("Workflow started: \(wf)", detail: title)
        }
        return wf
    }

    static func confirm(wf: String, seq: Int, totalOps: Int, result: String,
                        note: String, docNumber: String?) async {
        try? await SQLiteEmailStore.shared.confirmOperation(
            wf: wf, seq: seq, totalOps: totalOps, result: result, note: note,
            docNumber: docNumber, confirmedBy: ForensicManager.shared.examinerName)
        ForensicManager.shared.logAction(
            "Workflow \(wf) op \(seq) confirmed",
            detail: "\(result)\(docNumber.map { " → \($0)" } ?? "")")
    }
}
