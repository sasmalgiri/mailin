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

    // MARK: - Secondary daily jobs (grounded in the same frameworks)

    /// Forensic — Keyword / Term Sweep (NIST 800-86 Examination). Run a
    /// search-term list across the evidence and turn the hits into findings.
    static let forensicKeywordSweep = WorkflowDefinition(
        defID: "builtin.forensic.keywordsweep", name: "Keyword / Term Sweep",
        persona: "forensic", builtin: true, operations: [
            op(1, "terms", "Define Terms", "Draft the search-term list that scopes the examination.", nil, launches: .keywordMonitor, [
                f("caseNumber", "Case / Matter number", .text, "Ties this sweep to the investigation.", placeholder: "CASE-2026-0001", required: true),
                f("terms", "Search terms", .longText, "Keywords and phrases — one per line.", required: true),
                f("rationale", "Why these terms", .text, "The theory the terms are testing."),
            ]),
            op(2, "sweep", "Run Sweep", "Execute the term list across the evidence set.", nil, launches: .keywordMonitor, [
                f("hits", "Matches found", .number, "How many emails matched any term."),
                f("coverage", "Coverage", .text, "Date range and custodians searched."),
            ], gates: [WorkflowGate(rule: .operationConfirmed(seq: 1), reason: "Define the terms first.")]),
            op(3, "review", "Review Hits", "Triage each match for relevance.", nil, launches: .forensicReview, [
                f("relevant", "Relevant hits", .number, "Matches that actually matter."),
                f("falsePositives", "False positives", .number, "Matches discarded as noise."),
                f("notes", "Examination notes", .longText, "What the hits show — the examiner's contemporaneous notes."),
            ]),
            op(4, "report", "Report Findings", "Write up what the sweep established. Posts a Report.", .report, launches: .investigationReport, [
                f("summary", "Findings summary", .longText, "The conclusions this sweep supports — for the case file.", required: true),
            ], gates: [WorkflowGate(rule: .operationConfirmed(seq: 2), reason: "Run the sweep before reporting.")]),
        ])

    /// Forensic — Custody Verification (chain-of-custody integrity). Re-hash
    /// the set, prove nothing changed since intake, and seal a report.
    static let forensicCustodyVerify = WorkflowDefinition(
        defID: "builtin.forensic.custodyverify", name: "Custody Verification",
        persona: "forensic", builtin: true, operations: [
            op(1, "scope", "Select Evidence", "Choose the items to re-verify.", nil, launches: .chainOfCustody, [
                f("caseNumber", "Case / Matter number", .text, "Ties this verification to the investigation.", placeholder: "CASE-2026-0001", required: true),
                f("itemCount", "Items under verification", .number, "How many evidence items you're checking."),
            ]),
            op(2, "rehash", "Recompute Hashes", "Re-hash every item and compare to the intake fingerprints.", nil, launches: .chainOfCustody, [
                f("algorithm", "Hash algorithm", .choice, "The integrity fingerprint algorithm.", required: true, options: ["SHA-256", "SHA-1", "MD5"]),
                f("verified", "Items matching", .number, "How many items still match their intake hash."),
                f("mismatches", "Items changed", .number, "How many items no longer match — must be zero for intact custody."),
            ], gates: [WorkflowGate(rule: .operationConfirmed(seq: 1), reason: "Select the evidence first.")]),
            op(3, "resolve", "Resolve Mismatches", "Investigate and explain any item that changed.", nil, launches: .forensicReview, [
                f("explanation", "Mismatch explanation", .longText, "Explain or escalate every changed item — a hole here breaks admissibility."),
            ], gates: [WorkflowGate(rule: .fieldPresent(seq: 2, key: "algorithm"), reason: "Recompute the hashes first.")]),
            op(4, "seal", "Seal & Report", "Record the verdict and seal the custody report. Posts a Report.", .report, launches: .investigationReport, [
                f("conclusion", "Integrity conclusion", .choice, "The verdict this verification supports.", required: true, options: ["Integrity intact", "Integrity broken — flagged"]),
                f("verifier", "Verified by", .text, "Who performed the verification."),
            ], gates: [WorkflowGate(rule: .operationConfirmed(seq: 2), reason: "Recompute the hashes before sealing.")]),
        ])

    /// Forensic — Timeline Reconstruction (NIST 800-86 Analysis phase). The
    /// central DFIR deliverable: put the events in provable order.
    static let forensicTimeline = WorkflowDefinition(
        defID: "builtin.forensic.timeline", name: "Timeline Reconstruction",
        persona: "forensic", builtin: true, operations: [
            op(1, "scope", "Set Scope", "Fix the window and custodians the timeline will cover.", nil, launches: .emailInbox, [
                f("caseNumber", "Case / Matter number", .text, "Ties this timeline to the investigation.", placeholder: "CASE-2026-0001", required: true),
                f("window", "Time window", .text, "The date range the timeline spans.", placeholder: "2025-01-01 → 2025-06-30"),
                f("custodians", "Custodians in scope", .longText, "Whose mail is included — one per line."),
            ]),
            op(2, "build", "Build Timeline", "Assemble the chronological event list from the set.", nil, launches: .timeline, [
                f("eventCount", "Events placed", .number, "How many dated events you put on the timeline."),
                f("sources", "Timestamp sources", .longText, "Where the times come from — header Date, Received hops, server logs."),
            ], gates: [WorkflowGate(rule: .operationConfirmed(seq: 1), reason: "Set the scope first.")]),
            op(3, "keyEvents", "Mark Key Events", "Flag the pivotal moments and any unexplained gaps.", nil, launches: .timeline, [
                f("pivotal", "Pivotal events", .longText, "The moments that matter to the case, in order.", required: true),
                f("gaps", "Unexplained gaps", .longText, "Silences or missing intervals worth noting."),
            ]),
            op(4, "corroborate", "Corroborate", "Cross-check the sequence against independent evidence.", nil, launches: .forensicReview, [
                f("method", "Corroboration method", .choice, "How you confirmed the ordering is sound.", options: ["Received-header hops", "Server logs", "Third-party records", "Message metadata"]),
                f("corroboration", "Corroboration notes", .longText, "What independently supports the timeline."),
            ]),
            op(5, "exhibit", "Export Exhibit", "Produce the timeline exhibit for the file. Posts a Timeline document.", .timeline, launches: .investigationReport, [
                f("title", "Exhibit title", .text, "Label for this timeline exhibit.", required: true),
                f("scopeNote", "Scope statement", .longText, "One line on what the timeline does and does not cover."),
            ], gates: [WorkflowGate(rule: .operationConfirmed(seq: 2), reason: "Build the timeline before exporting an exhibit.")]),
        ])

    /// Legal — Legal Hold & Preservation (EDRM Information Governance /
    /// Preservation). The first duty in any matter; missing it is spoliation.
    static let legalHold = WorkflowDefinition(
        defID: "builtin.legal.hold", name: "Legal Hold & Preservation",
        persona: "legal", builtin: true, operations: [
            op(1, "identify", "Identify Custodians", "List everyone who must preserve, and the sources in scope.", nil, launches: .custodianPanel, [
                f("matter", "Matter name", .text, "The litigation or investigation this hold serves.", placeholder: "Acme v. Roe", required: true),
                f("custodians", "Custodians", .longText, "Everyone under a duty to preserve — one per line.", required: true),
                f("scope", "Data sources in scope", .longText, "Mailboxes, drives, devices covered by the hold."),
            ]),
            op(2, "issue", "Issue Hold Notice", "Record the preservation notice sent to custodians. Posts a Legal Hold document.", .legalHold, launches: .custodianPanel, [
                f("holdDate", "Hold date", .date, "When the hold took effect."),
                f("instructions", "Preservation instructions", .longText, "Exactly what recipients must preserve and not delete."),
                f("legalBasis", "Legal basis", .text, "The trigger — litigation, subpoena, investigation."),
            ], gates: [WorkflowGate(rule: .fieldPresent(seq: 1, key: "custodians"),
                                    reason: "Identify the custodians before issuing the hold.")]),
            op(3, "acknowledge", "Track Acknowledgements", "Record who has confirmed the hold.", nil, launches: .custodianPanel, [
                f("acknowledged", "Acknowledged", .number, "How many custodians confirmed receipt."),
                f("outstanding", "Outstanding", .number, "How many have not yet confirmed."),
                f("reminderSent", "Reminder sent", .bool, "Turn on once you've chased the outstanding custodians."),
            ]),
            op(4, "preserve", "Preserve Sources", "Snapshot or place a hold on the in-scope data.", nil, launches: .emailInbox, [
                f("method", "Preservation method", .choice, "How the data is being held.", options: ["In-place hold", "Collected copy", "Export snapshot"]),
                f("preservedSources", "Sources preserved", .number, "How many mailboxes/sources are now under preservation."),
            ]),
            op(5, "monitor", "Monitor / Release", "Keep the hold active, or lift it with a reason on record.", nil, launches: .custodianPanel, [
                f("status", "Hold status", .choice, "Active while the duty persists; Released only when it ends.", options: ["Active", "Released"]),
                f("releaseReason", "Release reason", .longText, "Why the hold was lifted — required if releasing."),
            ], gates: [WorkflowGate(rule: .operationConfirmed(seq: 3), reason: "Track acknowledgements before changing hold status.")]),
        ])

    /// Legal — Early Case Assessment (EDRM Processing/Analysis). Cull before
    /// the expensive review; decide scope on evidence, not guesswork.
    static let legalECA = WorkflowDefinition(
        defID: "builtin.legal.eca", name: "Early Case Assessment",
        persona: "legal", builtin: true, operations: [
            op(1, "terms", "Define Search Terms", "Draft the term list that scopes the case.", nil, launches: .keywordMonitor, [
                f("matter", "Matter name", .text, "The matter under assessment.", placeholder: "Acme v. Roe", required: true),
                f("terms", "Search terms", .longText, "Keywords and queries — one per line.", required: true),
                f("dateRange", "Date range", .text, "The relevant period.", placeholder: "2024-01 → 2025-12"),
            ]),
            op(2, "cull", "Cull & Dedupe", "Reduce the set — dedupe and date-filter before review.", nil, launches: .duplicateManager, [
                f("startCount", "Starting count", .number, "Documents before culling."),
                f("afterDedupe", "After dedupe", .number, "Documents left after removing duplicates."),
                f("afterDateFilter", "After date filter", .number, "Documents left after the date range is applied."),
            ]),
            op(3, "sample", "Sample & Assess", "QC a random sample to gauge how rich the set is.", nil, launches: .predictiveCoding, [
                f("sampleSize", "Sample size", .number, "How many documents you reviewed in the sample."),
                f("richnessPct", "Richness (% responsive)", .number, "Share of the sample that was responsive."),
                f("notes", "Assessment notes", .longText, "What the sample suggests about the whole set."),
            ]),
            op(4, "estimate", "Estimate Scope & Cost", "Project the review volume and effort.", nil, launches: .reviewDashboard, [
                f("projectedReviewSet", "Projected review set", .number, "Estimated documents needing human review."),
                f("estimatedHours", "Estimated review hours", .number, "Rough effort at your review rate."),
            ]),
            op(5, "decide", "Decide Scope", "Proceed, narrow, or negotiate — with the rationale on record. Posts a Report.", .report, launches: .reviewDashboard, [
                f("decision", "Decision", .choice, "The scoping call this assessment supports.", required: true, options: ["Proceed to review", "Narrow terms", "Negotiate scope"]),
                f("rationale", "Rationale", .longText, "Why — the defensible basis for the scope decision.", required: true),
            ], gates: [WorkflowGate(rule: .operationConfirmed(seq: 3), reason: "Assess a sample before deciding scope.")]),
        ])

    /// Legal / Compliance — Data Subject Request (GDPR Art. 15 & related).
    /// A statutory-deadline job; releasing others' PII is itself a breach.
    static let legalDSAR = WorkflowDefinition(
        defID: "builtin.legal.dsar", name: "Data Subject Request (DSAR)",
        persona: "legal", builtin: true, operations: [
            op(1, "log", "Log Request", "Capture the request and its statutory clock.", nil, launches: .gdprCompliance, [
                f("requestId", "Request ID", .text, "Your internal reference for this request.", placeholder: "DSAR-2026-001", required: true),
                f("subject", "Data subject", .text, "Whose personal data is requested.", placeholder: "name / email", required: true),
                f("type", "Request type", .choice, "The right being exercised.", options: ["Access", "Erasure", "Rectification", "Portability"]),
                f("deadline", "Statutory deadline", .date, "The date the response is legally due."),
            ]),
            op(2, "search", "Locate Subject Data", "Find every email that mentions or belongs to the subject.", nil, launches: .emailInbox, [
                f("matches", "Matches found", .number, "How many emails matched the subject."),
                f("searchTerms", "Search terms used", .longText, "Names, addresses, identifiers you searched on."),
            ]),
            op(3, "redact", "Redact Third-Party PII", "Remove other people's personal data from the set.", nil, launches: .redaction, [
                f("redactedItems", "Items redacted", .number, "How many documents needed redaction."),
                f("thirdPartyRedacted", "Third-party PII removed", .bool, "Turn on only when no other individual's personal data remains."),
            ]),
            op(4, "review", "Legal Review", "Apply exemptions and privilege before release.", nil, launches: .reviewDashboard, [
                f("exemptionsApplied", "Exemptions applied", .longText, "Any legal exemptions withholding material."),
                f("withheld", "Documents withheld", .number, "How many were withheld under exemption/privilege."),
            ]),
            op(5, "produce", "Produce Response", "Deliver the response pack to the subject. Posts a Subject Response document.", .subjectResponse, launches: .eDiscovery, [
                f("format", "Response format", .choice, "How the pack is delivered.", options: ["PDF pack", "Native + index"]),
                f("deliveredDate", "Delivered date", .date, "When the response was sent to the subject."),
            ], gates: [WorkflowGate(rule: .fieldEquals(seq: 3, key: "thirdPartyRedacted", value: "Yes"),
                                    reason: "Redact third-party personal data before producing — releasing others' PII is itself a breach.")]),
        ])

    /// IT / SOC — Threat Hunt (NIST 800-61 proactive). The other half of the
    /// job: hunt the archive instead of waiting for a report.
    static let itThreatHunt = WorkflowDefinition(
        defID: "builtin.it.threathunt", name: "Threat Hunt",
        persona: "it_admin", builtin: true, operations: [
            op(1, "hypothesis", "Form Hypothesis", "State what you're hunting and where.", nil, launches: .keywordMonitor, [
                f("hypothesis", "Hunt hypothesis", .longText, "The threat you suspect — e.g. lookalike-domain BEC targeting finance.", required: true),
                f("scope", "Scope", .text, "Mailboxes and date range to hunt across."),
            ]),
            op(2, "hunt", "Hunt", "Run the searches and indicators against the archive.", nil, launches: .keywordMonitor, [
                f("queriesRun", "Queries run", .number, "How many searches/indicators you executed."),
                f("leads", "Leads found", .number, "Hits worth a closer look."),
            ], gates: [WorkflowGate(rule: .operationConfirmed(seq: 1), reason: "Form the hypothesis first.")]),
            op(3, "analyze", "Analyze Anomalies", "Check authentication, routing, and attachment anomalies.", nil, launches: .anomalyDetection, [
                f("authFindings", "Authentication findings", .choice, "The strongest signal found.", options: ["None", "SPF/DKIM/DMARC fails", "Spoofed display name", "Suspicious routing"]),
                f("anomalies", "Anomaly notes", .longText, "What stood out and why it's suspicious."),
            ]),
            op(4, "extract", "Extract IOCs", "Pull indicators for blocking and sharing.", nil, launches: .iocExtractor, [
                f("iocCount", "IOCs extracted", .number, "How many indicators you collected."),
                f("iocList", "Indicators", .longText, "The domains, IPs, and hashes themselves."),
            ]),
            op(5, "report", "Report Findings", "Write up the verdict and recommendations. Posts a Threat Hunt document.", .threatHunt, launches: .investigationReport, [
                f("verdict", "Verdict", .choice, "The hunt's conclusion.", required: true, options: ["Threat found", "No threat found", "Inconclusive"]),
                f("recommendations", "Recommendations", .longText, "What to block, harden, or hunt next.", required: true),
            ], gates: [WorkflowGate(rule: .operationConfirmed(seq: 2), reason: "Run the hunt before reporting.")]),
        ])

    /// Journalist — Entity & Network Map (ICIJ cross-reference). The story
    /// spine: who is connected to whom, and how.
    static let journalistNetwork = WorkflowDefinition(
        defID: "builtin.journalist.network", name: "Entity & Network Map",
        persona: "journalist", builtin: true, operations: [
            op(1, "extract", "Extract Entities", "Pull out the people, organizations, and addresses.", nil, launches: .knowledgeGraphExplorer, [
                f("dataset", "Dataset", .text, "The set you're mapping.", placeholder: "Acme leak 2026", required: true),
                f("entityCount", "Entities found", .number, "How many distinct entities surfaced."),
                f("entityTypes", "Entity types", .longText, "What kinds — people, orgs, domains, accounts."),
            ]),
            op(2, "map", "Map Connections", "Chart who communicates with whom.", nil, launches: .relationshipGraph, [
                f("keyPlayers", "Key players", .longText, "The central figures in the network.", required: true),
                f("strongestTies", "Strongest ties", .longText, "The most active or telling relationships."),
            ]),
            op(3, "patterns", "Find Patterns", "Look for timing, frequency, and hidden links.", nil, launches: .communicationPatterns, [
                f("patterns", "Patterns observed", .longText, "Bursts, silences, back-channels, unusual routing."),
                f("suspiciousTiming", "Suspicious timing present", .bool, "Turn on if the timing itself is part of the story."),
            ]),
            op(4, "annotate", "Annotate the Map", "Label the story-relevant nodes and write the narrative. Posts an Entity Map document.", .entityMap, launches: .storyFile, [
                f("annotatedNodes", "Nodes annotated", .number, "How many entities you tagged as story-relevant."),
                f("narrative", "Network narrative", .longText, "How the network supports the story — in plain prose.", required: true),
            ], gates: [WorkflowGate(rule: .operationConfirmed(seq: 2), reason: "Map the connections before annotating.")]),
        ])

    /// IT / SOC — Phishing Campaign (Bulk). The many-reports reality: one
    /// campaign generates dozens of user reports; triage them as a single
    /// incident with one verdict and one bulk containment, not one-by-one.
    static let itCampaign = WorkflowDefinition(
        defID: "builtin.it.campaign", name: "Phishing Campaign (Bulk)",
        persona: "it_admin", builtin: true, operations: [
            op(1, "cluster", "Cluster Reports", "Group the many reported emails into one campaign.", nil, launches: .nearDuplicates, [
                f("campaignName", "Campaign name", .text, "A label for this campaign — you'll cite it in the incident.", placeholder: "Invoice-lure Aug 2026", required: true),
                f("reportsCount", "User reports", .number, "How many separate user reports this campaign generated."),
                f("clusterKey", "Clustered by", .choice, "What ties the reports together into one campaign.", options: ["Sender domain", "Subject pattern", "URL / landing page", "Attachment hash"]),
            ]),
            op(2, "scope", "Scope Impact", "Determine reach — who received it and who clicked.", nil, launches: .emailInbox, [
                f("recipients", "Total recipients", .number, "How many mailboxes received a message in this campaign."),
                f("delivered", "Delivered (not blocked)", .number, "How many actually landed in inboxes."),
                f("clicked", "Known clicks", .number, "Recipients known to have clicked or replied."),
            ]),
            op(3, "verdict", "Campaign Verdict", "One disposition for the whole campaign. Posts the Verdict document.", .triageVerdict, launches: .phishingTriage, [
                f("disposition", "Disposition", .choice, "The single verdict that covers every clustered report.", required: true, options: ["Confirmed phishing", "Safe", "Suspicious — needs info"]),
                f("severity", "Severity", .choice, "Business impact of the campaign as a whole.", options: ["P1 — Critical", "P2 — High", "P3 — Medium", "P4 — Low"]),
            ]),
            op(4, "contain", "Bulk Contain", "Block the indicators and purge across all affected mailboxes at once. Posts Export.", .export, launches: .iocExtractor, [
                f("iocCount", "IOCs blocked", .number, "Indicators pushed to the gateway/firewall."),
                f("mailboxesPurged", "Mailboxes purged", .number, "How many mailboxes had the message removed."),
                f("blocksAdded", "Blocks added", .number, "Sender/domain/URL blocks put in place."),
            ], gates: [WorkflowGate(rule: .fieldPresent(seq: 3, key: "disposition"),
                                    reason: "Set the campaign verdict before bulk containment — don't purge on a hunch.")]),
            op(5, "notify", "Notify & Close", "Notify affected users and record the campaign's metrics.", nil, [
                f("usersNotified", "Users notified", .number, "How many recipients were warned or briefed."),
                f("rootCause", "Root cause / lessons", .longText, "How it got through and what to harden."),
            ]),
        ])

    /// IT / SOC — Account Compromise (BEC) Investigation (NIST 800-61). Work
    /// a suspected mailbox takeover end to end.
    static let itBEC = WorkflowDefinition(
        defID: "builtin.it.bec", name: "Account Compromise (BEC)",
        persona: "it_admin", builtin: true, operations: [
            op(1, "detect", "Detect & Scope", "Identify the account and why it's suspected.", nil, launches: .itAdminDashboard, [
                f("account", "Compromised mailbox", .text, "The account under investigation.", placeholder: "user@corp.com", required: true),
                f("indicators", "Suspicion indicators", .longText, "What flagged it — new inbox rules, forwarding, impossible-travel logins."),
            ]),
            op(2, "analyze", "Analyze Activity", "Inspect inbox rules, sent items, and indicators.", nil, launches: .iocExtractor, [
                f("rulesFound", "Malicious inbox rules", .number, "Auto-forward/delete rules the attacker set."),
                f("authFindings", "Auth / login findings", .choice, "The strongest access signal.", options: ["None", "Impossible travel", "MFA fatigue", "Token theft", "Unknown"]),
                f("iocCount", "IOCs found", .number, "Indicators extracted from the account's mail."),
            ], gates: [WorkflowGate(rule: .operationConfirmed(seq: 1), reason: "Scope the account first.")]),
            op(3, "verdict", "Verdict", "Confirm or clear the compromise. Posts the Verdict.", .triageVerdict, launches: .phishingTriage, [
                f("disposition", "Disposition", .choice, "The call this investigation supports.", required: true, options: ["Confirmed compromise", "False alarm", "Needs info"]),
                f("severity", "Severity", .choice, "Business impact.", options: ["P1 — Critical", "P2 — High", "P3 — Medium", "P4 — Low"]),
            ]),
            op(4, "contain", "Contain & Recover", "Reset credentials, revoke sessions, remove attacker rules.", nil, launches: .iocExtractor, [
                f("actions", "Actions taken", .longText, "Password reset, sessions revoked, rules removed, MFA re-enrolled."),
                f("affected", "Downstream recipients", .number, "People who got mail from the account while compromised."),
            ], gates: [WorkflowGate(rule: .fieldPresent(seq: 3, key: "disposition"),
                                    reason: "Set a verdict before containment — don't lock a user out on a hunch.")]),
            op(5, "report", "Report", "Incident write-up and lessons. Posts a Report.", .report, launches: .investigationReport, [
                f("rootCause", "Root cause", .longText, "How the account was taken over.", required: true),
                f("lessons", "Lessons / hardening", .longText, "What to change so it doesn't recur."),
            ], gates: [WorkflowGate(rule: .operationConfirmed(seq: 3), reason: "Reach a verdict before reporting.")]),
        ])

    /// Journalist — Fact-Check & Verify (ICIJ verification). Stand up every
    /// claim before publication.
    static let journalistFactCheck = WorkflowDefinition(
        defID: "builtin.journalist.factcheck", name: "Fact-Check & Verify",
        persona: "journalist", builtin: true, operations: [
            op(1, "claims", "List Claims", "Enumerate every factual claim to be checked.", nil, launches: .storyFile, [
                f("story", "Story", .text, "Which story these claims belong to.", required: true),
                f("claimCount", "Claims to check", .number, "How many discrete factual claims."),
            ]),
            op(2, "corroborate", "Corroborate", "Find independent support for each claim.", nil, launches: .emailInbox, [
                f("corroborated", "Corroborated claims", .number, "Claims with at least one independent source."),
                f("uncorroborated", "Still uncorroborated", .number, "Claims that don't yet stand up."),
            ]),
            op(3, "rightOfReply", "Right of Reply", "Give every named subject a chance to respond.", nil, launches: .emailInbox, [
                f("subjectsContacted", "Subjects contacted", .number, "Named people/orgs you reached out to."),
                f("rightOfReplyDone", "Right of reply complete", .bool, "Turn on only when every subject has had a chance to respond."),
            ]),
            op(4, "signoff", "Verification Sign-off", "Record the go/hold decision. Posts a Report.", .report, launches: .storyFile, [
                f("decision", "Decision", .choice, "Where verification leaves the story.", required: true, options: ["Ready to publish", "Hold — unresolved claims"]),
                f("notes", "Verification notes", .longText, "What still needs work, or why it's ready."),
            ], gates: [WorkflowGate(rule: .fieldEquals(seq: 3, key: "rightOfReplyDone", value: "Yes"),
                                    reason: "Give every named subject a right of reply before sign-off.")]),
        ])

    /// Journalist — Source Protection & Publish. Strip anything that could
    /// identify a source before the set leaves your device.
    static let journalistPublish = WorkflowDefinition(
        defID: "builtin.journalist.publish", name: "Source Protection & Publish",
        persona: "journalist", builtin: true, operations: [
            op(1, "identify", "Identify Sensitive Data", "List what must be protected.", nil, launches: .redaction, [
                f("dataset", "Set to publish", .text, "What you're preparing for publication.", required: true),
                f("sensitive", "Sensitive items", .longText, "Names, locations, identifiers, metadata that could expose a source."),
            ]),
            op(2, "redact", "Redact", "Remove or obscure the identifying material.", nil, launches: .redaction, [
                f("redactedItems", "Items redacted", .number, "How many documents you redacted."),
                f("method", "Method", .choice, "How you protected the source.", options: ["Black-box redaction", "Remove attachment", "Paraphrase quote", "Strip metadata"]),
            ], gates: [WorkflowGate(rule: .operationConfirmed(seq: 1), reason: "Identify the sensitive data first.")]),
            op(3, "verify", "Verify No Leaks", "Double-check nothing identifying remains.", nil, launches: .emailInbox, [
                f("leakCheckPassed", "No source-identifying data remains", .bool, "Turn on only after you've confirmed the set is safe to release."),
            ]),
            op(4, "publish", "Prepare Publish Set", "Export the source-safe set. Posts Export.", .export, launches: .emailInbox, [
                f("outputName", "Output name", .text, "Label for the published set.", required: true),
            ], gates: [WorkflowGate(rule: .fieldEquals(seq: 3, key: "leakCheckPassed", value: "Yes"),
                                    reason: "Confirm no source-identifying data remains before exporting.")]),
        ])

    /// Personal — Find & Export. The everyday "find that email and save it" job.
    static let personalFindExport = WorkflowDefinition(
        defID: "builtin.personal.findexport", name: "Find & Export",
        persona: "personal", builtin: true, operations: [
            op(1, "search", "Find Emails", "Search for what you need.", nil, launches: .emailInbox, [
                f("query", "What are you looking for", .text, "Sender, subject, keyword, or date.", required: true),
                f("found", "Matches found", .number, "How many emails matched."),
            ]),
            op(2, "select", "Select & Review", "Pick the ones worth keeping.", nil, launches: .emailInbox, [
                f("selected", "Selected", .number, "How many you're keeping."),
                f("notes", "Notes", .longText, "Anything worth remembering about this set."),
            ]),
            op(3, "export", "Export", "Save them out. Posts Export.", .export, launches: .emailInbox, [
                f("format", "Format", .choice, "How to save them.", options: ["PDF", "EML files", "MBOX"]),
                f("destination", "Saved to", .text, "Where you put the export."),
            ], gates: [WorkflowGate(rule: .operationConfirmed(seq: 1), reason: "Find the emails first.")]),
            op(4, "confirm", "Confirm", "Open the export and sanity-check it.", nil, launches: .emailInbox, [
                f("verified", "Export looks right", .bool, "Turn on once you've opened it and confirmed it's complete."),
            ]),
        ])

    /// Personal — Unsubscribe & Declutter. Inbox hygiene.
    static let personalDeclutter = WorkflowDefinition(
        defID: "builtin.personal.declutter", name: "Unsubscribe & Declutter",
        persona: "personal", builtin: true, operations: [
            op(1, "scan", "Scan Clutter", "Find newsletters, promotions, and automated mail.", nil, launches: .topicClusters, [
                f("newsletters", "Newsletters", .number, "How many newsletter senders."),
                f("promotional", "Promotional", .number, "How many promotional/automated senders."),
            ]),
            op(2, "unsubscribe", "Unsubscribe", "Decide who to drop and who to keep.", nil, launches: .emailInbox, [
                f("unsubscribed", "Unsubscribed", .number, "Senders you unsubscribed from."),
                f("keep", "Keep these", .longText, "Senders worth keeping."),
            ]),
            op(3, "purge", "Purge Old Clutter", "Clear out the old low-value mail. Posts Cleanup.", .cleanup, launches: .duplicateManager, [
                f("removed", "Emails cleared", .number, "How many you removed."),
            ], gates: [WorkflowGate(rule: .operationConfirmed(seq: 1), reason: "Scan first so you know what's clutter.")]),
            op(4, "summary", "Summary", "Record what changed.", nil, launches: .emailInbox, [
                f("notes", "What changed", .longText, "A quick note on the cleanup for next time."),
            ]),
        ])

    static let all: [WorkflowDefinition] = [
        forensic, legal, itAdmin, journalist, personal,
        forensicTimeline, legalHold, legalECA, legalDSAR, itThreatHunt, journalistNetwork,
        itCampaign, forensicKeywordSweep, forensicCustodyVerify,
        itBEC, journalistFactCheck, journalistPublish, personalFindExport, personalDeclutter,
    ]

    static func templates(for persona: String) -> [WorkflowDefinition] {
        all.filter { $0.persona == persona }
    }

    /// One plain-language line explaining what a recipe is for and when to
    /// reach for it — shown in the Work Center list and the runner header so
    /// a first-time user (the Datashare "missed 20% of features" problem)
    /// knows why the workflow exists without reading a manual.
    static func purpose(for defID: String) -> String {
        switch defID {
        case "builtin.forensic.intake":
            return "Take in a mailbox as evidence and work it end to end — receive, hash, examine, analyze, report — with the chain of custody written for you."
        case "builtin.forensic.timeline":
            return "Reconstruct what happened and when, then export a defensible timeline exhibit for the case file."
        case "builtin.forensic.keywordsweep":
            return "Run a search-term list across the evidence, triage the hits, and turn them into cited findings."
        case "builtin.forensic.custodyverify":
            return "Re-hash the evidence and prove nothing changed since intake — then seal a chain-of-custody report."
        case "builtin.legal.production":
            return "Run a document production the defensible way — review, privilege-log, Bates, produce — with the privilege gate enforced before you release."
        case "builtin.legal.hold":
            return "Put a legal hold in place and prove it: identify custodians, issue the notice, track acknowledgements, preserve the data."
        case "builtin.legal.eca":
            return "Assess a matter before the expensive review — cull, sample, estimate scope — and decide how to proceed on evidence, not a guess."
        case "builtin.legal.dsar":
            return "Answer a data-subject/GDPR request on the clock — locate the data, redact everyone else's, and produce a clean response pack."
        case "builtin.it.phishing":
            return "Work a single reported email start to finish — analyze, verdict, contain, close — and post the verdict number your ticket cites."
        case "builtin.it.threathunt":
            return "Hunt the archive proactively on a hypothesis, extract indicators, and report what you found — before anyone reports it to you."
        case "builtin.it.campaign":
            return "Handle one phishing campaign that generated many reports as a single incident: cluster, verdict once, contain in bulk."
        case "builtin.journalist.story":
            return "Build a story from a leak the honest way — verify provenance, annotate cited findings, compile and fact-check a sourced draft."
        case "builtin.journalist.network":
            return "Map who knew whom — extract the entities, chart the connections, and turn the network into the spine of your story."
        case "builtin.journalist.factcheck":
            return "Stand up every claim before publication — corroborate independently, give subjects a right of reply, then sign off."
        case "builtin.journalist.publish":
            return "Strip anything that could identify a source, verify the set is clean, and prepare a publish-safe export."
        case "builtin.it.bec":
            return "Work a suspected mailbox takeover end to end — scope, analyze rules/logins, verdict, contain and recover, report."
        case "builtin.personal.findexport":
            return "Find the emails you need and save them out — search, select, export, and confirm."
        case "builtin.personal.declutter":
            return "Tame the inbox — find newsletters and promos, unsubscribe, and clear out the old clutter."
        case "builtin.personal.cleanup":
            return "Tidy a personal archive — import, dedupe, categorize, and export a clean backup."
        default:
            return "A guided recipe that does the job step by step and keeps a numbered record for you."
        }
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

/// Flatten/expand the per-operation field map for storage as one blob —
/// a saved "selection variant" (SAP): the setup of a run, reusable.
enum VariantCodec {
    /// [seq: [key: value]] -> ["seq|key": value]
    static func flatten(_ values: [Int: [String: String]]) -> [String: String] {
        var out: [String: String] = [:]
        for (seq, fields) in values {
            for (k, v) in fields where !v.isEmpty { out["\(seq)|\(k)"] = v }
        }
        return out
    }
    /// inverse
    static func expand(_ flat: [String: String]) -> [Int: [String: String]] {
        var out: [Int: [String: String]] = [:]
        for (compound, v) in flat {
            let parts = compound.split(separator: "|", maxSplits: 1)
            guard parts.count == 2, let seq = Int(parts[0]) else { continue }
            out[seq, default: [:]][String(parts[1])] = v
        }
        return out
    }
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

/// A clean, plain-language rendering of a run for a NON-technical reader —
/// the "portable case" / executive summary the reviews say the incumbents do
/// badly (AXIOM "portable case is difficult for detectives and prosecutors";
/// Relativity "improve executive summary reports"). No seqs, no jargon, no
/// key dumps — prose a stakeholder can read. Pure and unit-tested.
struct StakeholderSummary {
    let wfNumber: String
    let title: String
    let persona: String
    let status: String
    let preparedBy: String
    let preparedAt: Date
    let operations: [WorkflowOperation]
    /// seq -> (confirmedAt, by, result, note, docNumber)
    let confirmations: [Int: (Date, String, String, String, String?)]
    var fieldValues: [Int: [String: String]] = [:]

    private var intro: String {
        switch persona {
        case "forensic":
            return "This is a plain-language summary of the evidence handling and review performed on this matter, for case reviewers, counsel, and other stakeholders who need to understand what was done without technical detail."
        case "legal":
            return "This is a plain-language summary of the document review and production performed for this matter, for counsel and stakeholders."
        case "it_admin":
            return "This is a plain-language summary of how this reported email was investigated and resolved, for management and the teams involved."
        case "journalist":
            return "This is a plain-language summary of the sourcing, verification, and reporting steps behind this story."
        default:
            return "This is a plain-language summary of the work performed on this archive."
        }
    }

    /// Reader-friendly Markdown. Prints with a proportional font, not the
    /// monospace technical report.
    func rendered() -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .long; fmt.timeStyle = .short
        let dayFmt = DateFormatter(); dayFmt.dateStyle = .long

        let done = confirmations.count
        let total = operations.count
        let readableTitle = title.isEmpty ? wfNumber : title

        var out = "# \(readableTitle)\n\n"
        out += "**Reference:** \(wfNumber)  \n"
        out += "**Prepared by:** \(preparedBy.isEmpty ? "—" : preparedBy)  \n"
        out += "**Date:** \(fmt.string(from: preparedAt))  \n"
        let statusLine = done == total
            ? "Complete — all \(total) steps done"
            : "In progress — \(done) of \(total) steps done"
        out += "**Status:** \(statusLine)\n\n"
        out += intro + "\n\n"

        out += "## What was done\n\n"
        for opn in operations {
            if let c = confirmations[opn.seq] {
                out += "**\(opn.title)** — completed \(dayFmt.string(from: c.0))"
                if !c.1.isEmpty { out += " by \(c.1)" }
                out += ".\n"
                let vals = fieldValues[opn.seq] ?? [:]
                for field in opn.fields {
                    let v = vals[field.key] ?? ""
                    guard !v.isEmpty else { continue }
                    out += "- \(field.label): \(v)\n"
                }
                if !c.3.isEmpty { out += "- Note: \(c.3)\n" }
                out += "\n"
            } else {
                out += "**\(opn.title)** — not yet started.\n\n"
            }
        }

        let docs = operations.compactMap { confirmations[$0.seq]?.4 }
        if !docs.isEmpty {
            out += "## Records produced\n\n"
            for d in docs { out += "- \(d)\n" }
            out += "\n"
        }

        out += "---\n"
        out += "_This document was produced automatically by mailin as the work was performed. All records are kept on this device._\n"
        return out
    }
}
