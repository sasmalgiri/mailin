//
//  WorkflowEngine.swift
//  maxmailin
//
//  SAP-style process orders for email work. A WorkflowDefinition is the
//  master recipe (persona template of ordered operations); running it makes
//  a WorkflowInstance (WF-YYYY-####) confirmed operation by operation, each
//  with who/when/result and the document it posted. The pure pieces here —
//  the built-in catalog and the report renderer — are unit-tested; the
//  store persists, the view drives.
//

import Foundation

struct WorkflowOperation: Identifiable, Equatable, Sendable {
    var id: Int { seq }
    let seq: Int
    let key: String
    let title: String
    let hint: String
    /// The DocumentType this step posts on confirmation (nil = manual step).
    let postsDocType: DocumentType?
}

struct WorkflowDefinition: Identifiable, Equatable, Sendable {
    let defID: String
    let name: String
    let persona: String
    let builtin: Bool
    let operations: [WorkflowOperation]
    var id: String { defID }
}

/// The five built-in recipes, grounded in the canonical frameworks
/// (NIST 800-86, EDRM, NIST 800-61, ICIJ-style, personal lifecycle).
enum WorkflowCatalog {

    static func op(_ seq: Int, _ key: String, _ title: String, _ hint: String,
                   _ doc: DocumentType? = nil) -> WorkflowOperation {
        WorkflowOperation(seq: seq, key: key, title: title, hint: hint, postsDocType: doc)
    }

    static let forensic = WorkflowDefinition(
        defID: "builtin.forensic.intake", name: "Evidence Intake & Review",
        persona: "forensic", builtin: true, operations: [
            op(1, "receive", "Receive & Identify", "Record the case and custodian; import the source. Posts an Import document.", .importRun),
            op(2, "preserve", "Preserve & Hash", "Compute and verify per-email SHA-256 so integrity is provable.", nil),
            op(3, "examine", "Examine & Code", "Tag evidence, flag items of interest.", nil),
            op(4, "analyze", "Analyze", "Extract IOCs and anomalies across the set.", nil),
            op(5, "report", "Document & Report", "Generate the daily activity report for the case file. Posts a Report document.", .report),
        ])

    static let legal = WorkflowDefinition(
        defID: "builtin.legal.production", name: "Production Run",
        persona: "legal", builtin: true, operations: [
            op(1, "assemble", "Assemble Batch", "Create/assign the review batch (EDRM Review).", nil),
            op(2, "review", "Review & Code", "Responsive / non-responsive / privileged.", nil),
            op(3, "privilege", "Privilege Log", "Annotate every privileged document — the defensibility gate.", nil),
            op(4, "bates", "Bates & Redact", "Stamp production numbers; redact as needed.", nil),
            op(5, "produce", "Produce", "Export the set and copy the defensibility summary. Posts Export + Report.", .export),
        ])

    static let itAdmin = WorkflowDefinition(
        defID: "builtin.it.phishing", name: "Phishing Incident",
        persona: "it_admin", builtin: true, operations: [
            op(1, "intake", "Intake", "Reported email enters the triage queue (watch folder auto-imports).", .importRun),
            op(2, "analyze", "Analyze", "Headers/auth, URLs, attachment hashes; IOC extraction.", nil),
            op(3, "verdict", "Verdict", "Confirmed / Safe / Needs-info. Posts the Verdict document your ticket cites.", .triageVerdict),
            op(4, "contain", "Contain", "Export the IOC blocklist for the gateway/firewall. Posts Export.", .export),
            op(5, "close", "Close", "Incident note and metrics.", nil),
        ])

    static let journalist = WorkflowDefinition(
        defID: "builtin.journalist.story", name: "Story Build",
        persona: "journalist", builtin: true, operations: [
            op(1, "ingest", "Ingest & Verify", "Import the leak/FOIA set with its provenance receipt. Posts Import.", .importRun),
            op(2, "leads", "Find Leads", "Search; identify the threads worth pursuing.", nil),
            op(3, "annotate", "Annotate Findings", "One claim per annotation — each becomes a cited finding.", nil),
            op(4, "compile", "Compile Story", "Build the cited Markdown story file. Posts a Story version.", .storyVersion),
            op(5, "factcheck", "Fact-check & Version", "Verify each claim; save the versioned story. Posts a Story version.", .storyVersion),
        ])

    static let personal = WorkflowDefinition(
        defID: "builtin.personal.cleanup", name: "Archive Cleanup",
        persona: "personal", builtin: true, operations: [
            op(1, "import", "Import / Backup", "Bring the archive in. Posts Import.", .importRun),
            op(2, "dedupe", "Dedupe", "Remove exact duplicates archive-wide. Posts Cleanup.", .cleanup),
            op(3, "categorize", "Categorize", "Labels and folders.", nil),
            op(4, "export", "Export", "Final backup. Posts Export.", .export),
        ])

    static let all: [WorkflowDefinition] = [forensic, legal, itAdmin, journalist, personal]

    static func templates(for persona: String) -> [WorkflowDefinition] {
        all.filter { $0.persona == persona }
    }
}

/// One run assembled for display/report: the definition plus what happened.
struct WorkflowInstanceReport {
    let wfNumber: String
    let title: String
    let status: String
    let createdBy: String
    let createdAt: Date
    let operations: [WorkflowOperation]
    /// seq -> (confirmedAt, by, result, note, docNumber)
    let confirmations: [Int: (Date, String, String, String, String?)]

    var confirmedCount: Int { confirmations.count }

    /// Plain-text / Markdown report — the printable document form.
    func rendered() -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium; fmt.timeStyle = .short
        var out = "WORKFLOW \(wfNumber)\n"
        out += String(repeating: "=", count: ("WORKFLOW " + wfNumber).count) + "\n"
        out += "Title:   \(title)\n"
        out += "Status:  \(status.uppercased())\n"
        out += "By:      \(createdBy.isEmpty ? "(examiner not set)" : createdBy)\n"
        out += "Started: \(fmt.string(from: createdAt))\n"
        out += "Progress: \(confirmedCount)/\(operations.count) operations\n\nOPERATIONS\n"
        for opn in operations {
            let mark = confirmations[opn.seq] != nil ? "[x]" : "[ ]"
            out += "  \(mark) \(opn.seq). \(opn.title)\n"
            if let c = confirmations[opn.seq] {
                out += "        \(fmt.string(from: c.0)) by \(c.1.isEmpty ? "?" : c.1)"
                if !c.2.isEmpty { out += " — \(c.2)" }
                if let doc = c.4 { out += " → \(doc)" }
                out += "\n"
                if !c.3.isEmpty { out += "        note: \(c.3)\n" }
            }
        }
        out += "\nGenerated by mailin — single-examiner record kept on-device.\n"
        return out
    }
}
