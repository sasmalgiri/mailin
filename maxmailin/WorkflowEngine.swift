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

/// One data element captured at an operation — the "master element
/// property" the user fills in. Grounded in the real forms each profession
/// uses (chain-of-custody intake, eDiscovery coding, phishing IR report,
/// verification checklist).
struct WorkflowField: Identifiable, Equatable, Sendable {
    enum Kind: String, Equatable, Sendable { case text, longText, number, choice, bool, date }
    var id: String { key }
    let key: String
    let label: String
    let kind: Kind
    let help: String
    var placeholder: String = ""
    var required: Bool = false
    var options: [String] = []
}

struct WorkflowOperation: Identifiable, Equatable, Sendable {
    var id: Int { seq }
    let seq: Int
    let key: String
    let title: String
    let hint: String
    /// The DocumentType this step posts on confirmation (nil = manual step).
    let postsDocType: DocumentType?
    /// The tool this step opens so the user actually DOES the work from the
    /// workflow (nil = a manual/record-only step).
    var launches: HubDestination? = nil
    /// The data the user records at this step — saved into the completion
    /// document so the whole run is reusable later.
    var fields: [WorkflowField] = []
    /// Preconditions that must hold before this step may be confirmed — the
    /// SAP status-gate. Empty = always available.
    var gates: [WorkflowGate] = []
}

/// A precondition on an operation. Governs whether the step can run, so the
/// documented defensibility holes (produce-before-privilege, close-without-
/// verdict, report-before-hash) become structurally impossible.
struct WorkflowGate: Equatable, Sendable {
    enum Rule: Equatable, Sendable {
        /// The operation at this seq must be confirmed first.
        case operationConfirmed(seq: Int)
        /// A field on a specific operation must be non-empty.
        case fieldPresent(seq: Int, key: String)
        /// A field on a specific operation must equal a value (e.g. "Yes").
        case fieldEquals(seq: Int, key: String, value: String)
    }
    let rule: Rule
    /// Plain-language reason shown when the gate is closed.
    let reason: String
}

/// Pure gate evaluation — unit-tested, no store/UI.
enum GatePolicy {
    struct RunState {
        /// seqs that are confirmed.
        let confirmed: Set<Int>
        /// seq -> [fieldKey: value] captured so far.
        let fieldValues: [Int: [String: String]]
    }

    /// Returns the reasons this operation is currently locked (empty = open).
    static func lockedReasons(_ op: WorkflowOperation, state: RunState) -> [String] {
        op.gates.compactMap { gate in
            let satisfied: Bool
            switch gate.rule {
            case .operationConfirmed(let seq):
                satisfied = state.confirmed.contains(seq)
            case .fieldPresent(let seq, let key):
                satisfied = !((state.fieldValues[seq]?[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            case .fieldEquals(let seq, let key, let value):
                satisfied = (state.fieldValues[seq]?[key] ?? "") == value
            }
            return satisfied ? nil : gate.reason
        }
    }
}

/// Pure validation — required fields must be non-empty. Returns the missing
/// field labels (empty = valid). Unit-tested.
enum WorkflowFieldValidation {
    static func missingRequired(_ fields: [WorkflowField], values: [String: String]) -> [String] {
        fields.filter { $0.required }
            .filter { (values[$0.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map(\.label)
    }
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
                   _ doc: DocumentType? = nil, launches: HubDestination? = nil,
                   _ fields: [WorkflowField] = [], gates: [WorkflowGate] = []) -> WorkflowOperation {
        WorkflowOperation(seq: seq, key: key, title: title, hint: hint,
                          postsDocType: doc, launches: launches, fields: fields, gates: gates)
    }
    /// The default sequential gate: each step waits on the one before it.
    static func afterPrevious(_ seq: Int) -> [WorkflowGate] {
        seq <= 1 ? [] : [WorkflowGate(rule: .operationConfirmed(seq: seq - 1),
                                      reason: "Finish step \(seq - 1) first.")]
    }
    static func f(_ key: String, _ label: String, _ kind: WorkflowField.Kind, _ help: String,
                  placeholder: String = "", required: Bool = false, options: [String] = []) -> WorkflowField {
        WorkflowField(key: key, label: label, kind: kind, help: help,
                      placeholder: placeholder, required: required, options: options)
    }

    static let forensic = WorkflowDefinition(
        defID: "builtin.forensic.intake", name: "Evidence Intake & Review",
        persona: "forensic", builtin: true, operations: [
            op(1, "receive", "Receive & Identify", "Record the case and custodian; import the source. Posts an Import document.", .importRun, launches: .emailInbox, [
                f("caseNumber", "Case / Matter number", .text, "Links this evidence to the investigation. Use your lab's case-numbering scheme.", placeholder: "CASE-2026-0001", required: true),
                f("custodian", "Custodian / owner", .text, "Whose mailbox or account this evidence came from.", placeholder: "jdoe@corp.com", required: true),
                f("sourceLocation", "Source location", .text, "Where the data resided — server, cloud tenant, device.", placeholder: "Exchange Online tenant"),
                f("purpose", "Purpose of collection", .longText, "Why this evidence is being collected — the authority or request behind it."),
            ]),
            op(2, "preserve", "Preserve & Hash", "Compute and verify per-email SHA-256 so integrity is provable.", nil, launches: .chainOfCustody, [
                f("method", "Acquisition method", .choice, "How the copy was made without altering the source.", required: true, options: ["Write-blocked image", "Cloud/API export", "Server backup", "EML/PST export"]),
                f("hashAlg", "Hash algorithm", .choice, "The integrity fingerprint algorithm used.", options: ["SHA-256", "SHA-1", "MD5"]),
                f("sealNote", "Seal / storage note", .text, "Where the acquired evidence is stored and how it's sealed."),
            ]),
            op(3, "examine", "Examine & Code", "Tag evidence, flag items of interest.", nil, launches: .forensicReview, [
                f("itemsOfInterest", "Items of interest", .number, "How many emails you flagged as relevant this pass."),
                f("codingNotes", "Examination notes", .longText, "What you looked for and what stood out — the examiner's contemporaneous notes."),
            ]),
            op(4, "analyze", "Analyze", "Extract IOCs and anomalies across the set.", nil, launches: .iocExtractor, [
                f("iocSummary", "IOC / findings summary", .longText, "Indicators (domains, IPs, hashes) and authentication anomalies (SPF/DKIM/DMARC) found."),
                f("anomalies", "Anomalies present", .bool, "Turn on if the set shows tampering, spoofing, or routing anomalies worth noting."),
            ]),
            op(5, "report", "Document & Report", "Generate the daily activity report for the case file. Posts a Report document.", .report, launches: .investigationReport, [
                f("findings", "Findings summary", .longText, "The conclusions this run supports — written for the case file.", required: true),
            ], gates: [
                WorkflowGate(rule: .operationConfirmed(seq: 4), reason: "Finish Analyze first."),
                WorkflowGate(rule: .fieldPresent(seq: 2, key: "method"),
                             reason: "Record the acquisition method in Preserve & Hash — a report can't rest on unverified custody."),
            ]),
        ])

    static let legal = WorkflowDefinition(
        defID: "builtin.legal.production", name: "Production Run",
        persona: "legal", builtin: true, operations: [
            op(1, "assemble", "Assemble Batch", "Create/assign the review batch (EDRM Review).", nil, launches: .reviewBatches, [
                f("matter", "Matter name", .text, "The litigation or matter this production serves.", placeholder: "Acme v. Roe", required: true),
                f("requestNo", "Request / RFP reference", .text, "The discovery request this responds to."),
                f("reviewer", "Reviewer", .text, "Who is coding this batch (goes on the defensibility record)."),
                f("batchSize", "Batch size", .number, "How many documents are in this batch."),
            ]),
            op(2, "review", "Review & Code", "Responsive / non-responsive / privileged.", nil, launches: .emailInbox, [
                f("responsive", "Responsive count", .number, "Documents coded responsive to the request."),
                f("nonResponsive", "Non-responsive count", .number, "Documents coded not responsive."),
                f("confidentiality", "Confidentiality designation", .choice, "Highest confidentiality applied in this batch.", options: ["None", "Confidential", "Highly Confidential — AEO"]),
            ]),
            op(3, "privilege", "Privilege Log", "Annotate every privileged document — the defensibility gate.", nil, launches: .reviewDashboard, [
                f("privCount", "Privileged count", .number, "Documents withheld as privileged."),
                f("privBasis", "Privilege basis", .choice, "The ground for withholding — recorded in the privilege log.", options: ["Attorney-Client", "Work Product", "Both", "Not applicable"]),
                f("logComplete", "Privilege log complete", .bool, "Turn on only when every privileged doc has an annotation explaining the basis."),
            ]),
            op(4, "bates", "Bates & Redact", "Stamp production numbers; redact as needed.", nil, launches: .batesNumbering, [
                f("batesPrefix", "Bates prefix", .text, "Production prefix for sequential stamping.", placeholder: "ACME"),
                f("batesStart", "Bates start", .text, "First Bates number in this production.", placeholder: "ACME-000001"),
                f("redactions", "Redactions applied", .number, "How many documents required redaction."),
            ]),
            op(5, "produce", "Produce", "Export the set and copy the defensibility summary. Posts Export + Report.", .export, launches: .eDiscovery, [
                f("productionName", "Production set name", .text, "Label for this production volume.", placeholder: "PROD001", required: true),
                f("format", "Production format", .choice, "How the set is produced.", options: ["Native", "PDF (Bates-stamped)", "Load file (DAT/Opticon)"]),
            ], gates: [
                WorkflowGate(rule: .operationConfirmed(seq: 4), reason: "Finish Bates & Redact first."),
                WorkflowGate(rule: .fieldEquals(seq: 3, key: "logComplete", value: "Yes"),
                             reason: "Complete the privilege log first — producing before every privileged doc is annotated is the gap opposing counsel finds."),
            ]),
        ])

    static let itAdmin = WorkflowDefinition(
        defID: "builtin.it.phishing", name: "Phishing Incident",
        persona: "it_admin", builtin: true, operations: [
            op(1, "intake", "Intake", "Reported email enters the triage queue (watch folder auto-imports).", .importRun, launches: .phishingTriage, [
                f("reporter", "Reporter", .text, "Who reported the suspicious email.", placeholder: "user@corp.com", required: true),
                f("sender", "Sender (From)", .text, "The email's From address — check it against Reply-To/Return-Path."),
                f("subject", "Subject", .text, "The reported email's subject line."),
            ]),
            op(2, "analyze", "Analyze", "Headers/auth, URLs, attachment hashes; IOC extraction.", nil, launches: .iocExtractor, [
                f("auth", "Authentication result", .choice, "SPF/DKIM/DMARC outcome — a fail is a strong phishing signal.", options: ["All pass", "SPF fail", "DKIM fail", "DMARC fail", "Multiple fail"]),
                f("iocCount", "IOCs found", .number, "How many indicators (URLs, IPs, hashes) you extracted."),
                f("iocNotes", "IOC notes", .longText, "The indicators themselves and why they're suspicious."),
            ]),
            op(3, "verdict", "Verdict", "Confirmed / Safe / Needs-info. Posts the Verdict document your ticket cites.", .triageVerdict, launches: .phishingTriage, [
                f("disposition", "Disposition", .choice, "The verdict — this is the number your ticket cites.", required: true, options: ["Confirmed phishing", "Safe", "Suspicious — needs info"]),
                f("severity", "Severity", .choice, "Business impact tier.", options: ["P1 — Critical", "P2 — High", "P3 — Medium", "P4 — Low"]),
                f("confidence", "Confidence", .choice, "How sure you are of the verdict.", options: ["High", "Medium", "Low"]),
            ]),
            op(4, "contain", "Contain", "Export the IOC blocklist for the gateway/firewall. Posts Export.", .export, launches: .phishingTriage, [
                f("actions", "Actions taken", .longText, "Containment steps — blocks added, mailboxes purged, accounts reset."),
                f("affected", "Affected users", .number, "How many recipients received it; note any who clicked."),
            ]),
            op(5, "close", "Close", "Incident note and metrics.", nil, [
                f("rootCause", "Root cause / lessons", .longText, "What let it through and what to improve."),
            ], gates: [
                WorkflowGate(rule: .fieldPresent(seq: 3, key: "disposition"),
                             reason: "Set a verdict first — an incident can't be closed without a disposition on record."),
            ]),
        ])

    static let journalist = WorkflowDefinition(
        defID: "builtin.journalist.story", name: "Story Build",
        persona: "journalist", builtin: true, operations: [
            op(1, "ingest", "Ingest & Verify", "Import the leak/FOIA set with its provenance receipt. Posts Import.", .importRun, launches: .emailInbox, [
                f("dataset", "Dataset name", .text, "What this set is and where it came from.", placeholder: "Acme leak 2026", required: true),
                f("provenance", "Provenance", .longText, "How you obtained it and why you trust it — the five-pillars provenance note."),
            ]),
            op(2, "leads", "Find Leads", "Search; identify the threads worth pursuing.", nil, launches: .emailInbox, [
                f("lead", "Lead description", .longText, "The thread you're chasing and why it matters."),
            ]),
            op(3, "annotate", "Annotate Findings", "One claim per annotation — each becomes a cited finding.", nil, launches: .emailInbox, [
                f("claims", "Claims recorded", .number, "How many cited findings you annotated."),
            ]),
            op(4, "compile", "Compile Story", "Build the cited Markdown story file. Posts a Story version.", .storyVersion, launches: .storyFile, [
                f("title", "Story title", .text, "Working title for this version.", required: true),
            ]),
            op(5, "factcheck", "Fact-check & Version", "Verify each claim; save the versioned story. Posts a Story version.", .storyVersion, launches: .storyFile, [
                f("corroboration", "Independent corroborating sources", .number, "At least one independent source per explosive claim."),
                f("rightOfReply", "Right of reply obtained", .bool, "Turn on once subjects have been given a chance to respond."),
            ]),
        ])

    static let personal = WorkflowDefinition(
        defID: "builtin.personal.cleanup", name: "Archive Cleanup",
        persona: "personal", builtin: true, operations: [
            op(1, "import", "Import / Backup", "Bring the archive in. Posts Import.", .importRun, launches: .emailInbox, [
                f("archive", "Archive name", .text, "What you're cleaning up.", placeholder: "Gmail export 2026"),
            ]),
            op(2, "dedupe", "Dedupe", "Remove exact duplicates archive-wide. Posts Cleanup.", .cleanup, launches: .duplicateManager, [
                f("removed", "Duplicates removed", .number, "How many exact duplicates were cleared."),
            ]),
            op(3, "categorize", "Categorize", "Labels and folders.", nil, launches: .emailInbox, [
                f("labels", "Labels applied", .longText, "How you organized it — labels or folders used."),
            ]),
            op(4, "export", "Export", "Final backup. Posts Export.", .export, launches: .emailInbox, [
                f("backup", "Backup location", .text, "Where the cleaned archive is saved."),
            ]),
        ])

    static let all: [WorkflowDefinition] = [forensic, legal, itAdmin, journalist, personal]

    static func templates(for persona: String) -> [WorkflowDefinition] {
        all.filter { $0.persona == persona }
    }
}

/// SAP "determination": values the app can compute from live data, so the
/// human keys almost nothing. Pure — the context is gathered by the runner
/// and passed in, keeping this testable.
struct DerivationContext: Sendable {
    var caseNumber: String = ""
    var examiner: String = ""
    var relevantCount: Int = 0
    var privilegedCount: Int = 0
    var privilegedUnannotated: Int = 0
    var irrelevantCount: Int = 0
    var archiveDuplicateCount: Int = 0
    var archiveTotal: Int = 0
}

enum FieldDerivation {
    /// Field values to PREFILL for one operation (only used where the field
    /// is still empty — the user's own entry always wins).
    static func derive(defID: String, opKey: String, ctx: DerivationContext) -> [String: String] {
        var out: [String: String] = [:]
        switch (defID, opKey) {
        case ("builtin.forensic.intake", "receive"):
            if !ctx.caseNumber.isEmpty { out["caseNumber"] = ctx.caseNumber }
        case ("builtin.forensic.intake", "preserve"):
            out["hashAlg"] = "SHA-256"                 // the forensic default
        case ("builtin.legal.production", "review"):
            if ctx.relevantCount > 0 { out["responsive"] = String(ctx.relevantCount) }
            if ctx.irrelevantCount > 0 { out["nonResponsive"] = String(ctx.irrelevantCount) }
        case ("builtin.legal.production", "privilege"):
            if ctx.privilegedCount > 0 { out["privCount"] = String(ctx.privilegedCount) }
            // The gate opens only at "Yes"; derive it truthfully so the human
            // isn't asked to assert completeness the data contradicts.
            if ctx.privilegedCount > 0 && ctx.privilegedUnannotated == 0 {
                out["logComplete"] = "Yes"
            }
        case ("builtin.personal.cleanup", "dedupe"):
            if ctx.archiveDuplicateCount > 0 { out["removed"] = String(ctx.archiveDuplicateCount) }
        default:
            break
        }
        return out
    }

    /// Which of an operation's fields would be auto-filled (for the "derived"
    /// note in the UI).
    static func derivedKeys(defID: String, opKey: String, ctx: DerivationContext) -> Set<String> {
        Set(derive(defID: defID, opKey: opKey, ctx: ctx).keys)
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
    /// seq -> [fieldKey: value] — the data the user entered, embedded so the
    /// finished document carries the whole run.
    var fieldValues: [Int: [String: String]] = [:]

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
            // The data the user recorded at this step (the reusable content).
            let vals = fieldValues[opn.seq] ?? [:]
            for field in opn.fields {
                let v = vals[field.key] ?? ""
                guard !v.isEmpty else { continue }
                out += "        \(field.label): \(v)\n"
            }
        }
        out += "\nGenerated by mailin — single-examiner record kept on-device.\n"
        return out
    }
}
