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
    enum Kind: String, Equatable, Sendable { case text, longText, number, choice, bool, date, dateRange }
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
                f("window", "Time window", .dateRange, "The date range the timeline spans — pick From and To."),
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

    // MARK: - More multi-tool jobs (a job pre-wires the tools it needs)

    /// Forensic — Court Exhibit Package. Turn tagged evidence into a
    /// court-ready, Bates-stamped, redacted package (review → redact → stamp
    /// → export), so the examiner never assembles tools by hand.
    static let forensicExhibit = WorkflowDefinition(
        defID: "builtin.forensic.exhibit", name: "Court Exhibit Package",
        persona: "forensic", builtin: true, operations: [
            op(1, "select", "Select Evidence", "Pick the tagged items that become exhibits.", nil, launches: .forensicReview, [
                f("caseNumber", "Case / Matter number", .text, "The case this exhibit set belongs to.", placeholder: "CASE-2026-0001", required: true),
                f("itemsSelected", "Items selected", .number, "How many emails you're packaging as exhibits."),
            ]),
            op(2, "redact", "Redact", "Remove privileged / third-party PII before anything leaves.", nil, launches: .redaction, [
                f("redactedItems", "Items redacted", .number, "How many exhibits needed redaction."),
                f("redactionComplete", "Redaction complete", .bool, "Turn on once every exhibit is clear of privileged/third-party data."),
            ]),
            op(3, "bates", "Bates Stamp", "Apply sequential production numbers.", nil, launches: .batesNumbering, [
                f("batesPrefix", "Bates prefix", .text, "Production prefix.", placeholder: "ACME"),
                f("batesStart", "Bates start", .text, "First number.", placeholder: "ACME-000001"),
            ], gates: [WorkflowGate(rule: .fieldEquals(seq: 2, key: "redactionComplete", value: "Yes"),
                                    reason: "Redact before stamping and exporting — a leaked exhibit can't be unshared.")]),
            op(4, "package", "Export Package", "Produce the court-ready package with a cover report. Posts Export.", .export, launches: .investigationReport, [
                f("exhibitName", "Exhibit set name", .text, "Label for this package.", placeholder: "Exhibits A–F", required: true),
                f("recipient", "For", .text, "Who receives it — counsel, prosecutor, court."),
            ]),
        ])

    /// Forensic — Insider Threat Review. One job across comms patterns,
    /// anomalies and keywords to judge a subject.
    static let forensicInsider = WorkflowDefinition(
        defID: "builtin.forensic.insider", name: "Insider Threat Review",
        persona: "forensic", builtin: true, operations: [
            op(1, "scope", "Scope Subject", "Fix the subject and window under review.", nil, launches: .communicationPatterns, [
                f("subject", "Subject", .text, "The mailbox/person under review.", placeholder: "jdoe@corp.com", required: true),
                f("window", "Time window", .dateRange, "The period you're examining — pick From and To."),
            ]),
            op(2, "patterns", "Communication Patterns", "Look for off-hours, external, or unusual volume.", nil, launches: .communicationPatterns, [
                f("findings", "Pattern findings", .longText, "External recipients, off-hours spikes, new contacts."),
            ], gates: [WorkflowGate(rule: .operationConfirmed(seq: 1), reason: "Scope the subject first.")]),
            op(3, "anomalies", "Anomalies & Keywords", "Flag risky terms and statistical outliers.", nil, launches: .anomalyDetection, [
                f("anomalies", "Anomalies found", .number, "Outliers worth noting."),
                f("riskyTerms", "Risky terms", .longText, "Exfiltration, resignation, competitor names, etc."),
            ]),
            op(4, "report", "Report", "Record the judgment for HR/legal. Posts a Report.", .report, launches: .investigationReport, [
                f("verdict", "Verdict", .choice, "Where the review lands.", required: true, options: ["Concern found", "No concern", "Escalate"]),
                f("summary", "Summary", .longText, "The basis for the verdict."),
            ], gates: [WorkflowGate(rule: .operationConfirmed(seq: 2), reason: "Review the patterns before concluding.")]),
        ])

    /// Legal — Privilege QC & Redaction. The pre-production safety pass.
    static let legalPrivQC = WorkflowDefinition(
        defID: "builtin.legal.privqc", name: "Privilege QC & Redaction",
        persona: "legal", builtin: true, operations: [
            op(1, "qc", "QC Privilege Log", "Confirm every withheld doc has its basis annotated.", nil, launches: .reviewDashboard, [
                f("matter", "Matter", .text, "The matter this production serves.", placeholder: "Acme v. Roe", required: true),
                f("withheld", "Withheld count", .number, "Documents withheld as privileged."),
                f("gaps", "Unannotated gaps", .number, "Privileged docs still missing a basis — must reach zero."),
            ]),
            op(2, "redact", "Redact", "Apply redactions to partially-privileged docs.", nil, launches: .redaction, [
                f("redactedItems", "Items redacted", .number, "How many needed redaction."),
                f("redactionComplete", "Redaction complete", .bool, "Turn on once redactions are verified."),
            ]),
            op(3, "bates", "Bates Stamp", "Stamp the production set.", nil, launches: .batesNumbering, [
                f("batesPrefix", "Bates prefix", .text, "Production prefix.", placeholder: "ACME"),
            ], gates: [WorkflowGate(rule: .fieldEquals(seq: 2, key: "redactionComplete", value: "Yes"),
                                    reason: "Finish redaction before stamping the production.")]),
            op(4, "signoff", "Sign Off", "Clear the set for production. Posts a Report.", .report, launches: .reviewDashboard, [
                f("decision", "Decision", .choice, "The QC outcome.", required: true, options: ["Cleared for production", "Hold — gaps remain"]),
            ], gates: [WorkflowGate(rule: .operationConfirmed(seq: 1), reason: "QC the privilege log first.")]),
        ])

    /// Legal / Compliance — Retention & Compliance Audit.
    static let legalCompliance = WorkflowDefinition(
        defID: "builtin.legal.compliance", name: "Retention & Compliance Audit",
        persona: "legal", builtin: true, operations: [
            op(1, "scan", "Scan for PII", "Find personal data across the set.", nil, launches: .gdprCompliance, [
                f("matter", "Matter / scope", .text, "What you're auditing.", required: true),
                f("piiFound", "PII items found", .number, "Personal-data hits detected."),
            ]),
            op(2, "classify", "Classify Sensitivity", "Rank what's high-risk.", nil, launches: .gdprCompliance, [
                f("highRisk", "High-risk items", .number, "SSNs, financial, health, etc."),
                f("notes", "Notes", .longText, "What categories were found and where."),
            ]),
            op(3, "remediate", "Remediate", "Redact or flag the high-risk material.", nil, launches: .redaction, [
                f("redacted", "Items remediated", .number, "How many you redacted/flagged."),
            ]),
            op(4, "report", "Compliance Report", "Record the audit outcome. Posts a Report.", .report, launches: .reportBuilder, [
                f("conclusion", "Conclusion", .choice, "The audit result.", required: true, options: ["Compliant", "Gaps found — remediation needed"]),
            ], gates: [WorkflowGate(rule: .operationConfirmed(seq: 1), reason: "Scan for PII before concluding.")]),
        ])

    /// IT / SOC — Email Authentication Audit (SPF/DKIM/DMARC posture).
    static let itAuthAudit = WorkflowDefinition(
        defID: "builtin.it.authaudit", name: "Email Authentication Audit",
        persona: "it_admin", builtin: true, operations: [
            op(1, "scope", "Scope", "Which domains/senders to audit.", nil, launches: .itAdminDashboard, [
                f("scope", "Scope", .text, "Domains or senders under audit.", required: true),
            ]),
            op(2, "check", "Check SPF/DKIM/DMARC", "Assess the authentication posture.", nil, launches: .smartAlerts, [
                f("passRate", "Pass rate", .text, "Share passing all three.", placeholder: "e.g. 82%"),
                f("failures", "Failing senders", .number, "How many senders fail one or more."),
            ], gates: [WorkflowGate(rule: .operationConfirmed(seq: 1), reason: "Scope the audit first.")]),
            op(3, "spoof", "Spoofing Check", "Look for spoofing / lookalike anomalies.", nil, launches: .anomalyDetection, [
                f("spoofingFound", "Spoofing present", .bool, "Turn on if spoofing/lookalike domains appear."),
                f("notes", "Notes", .longText, "What you found."),
            ]),
            op(4, "report", "Report & Recommend", "Posture report with fixes. Posts a Report.", .report, launches: .investigationReport, [
                f("recommendations", "Recommendations", .longText, "DMARC policy, alignment, sender fixes.", required: true),
            ], gates: [WorkflowGate(rule: .operationConfirmed(seq: 2), reason: "Check auth before recommending.")]),
        ])

    /// IT / SOC — Security Metrics Report (periodic exec briefing).
    static let itMetrics = WorkflowDefinition(
        defID: "builtin.it.metrics", name: "Security Metrics Report",
        persona: "it_admin", builtin: true, operations: [
            op(1, "gather", "Gather Metrics", "Pull triage volumes for the period.", nil, launches: .phishingTriage, [
                f("period", "Reporting period", .text, "The window this report covers.", placeholder: "Aug 2026", required: true),
                f("incidents", "Incidents", .number, "Total reported this period."),
                f("confirmed", "Confirmed phishing", .number, "How many were real."),
            ]),
            op(2, "trends", "Trends & Anomalies", "Note what changed vs. last period.", nil, launches: .anomalyDetection, [
                f("trend", "Trend notes", .longText, "Up/down, new campaigns, notable events."),
            ]),
            op(3, "exec", "Executive View", "Assemble the at-a-glance numbers.", nil, launches: .executiveDashboard, [
                f("highlights", "Highlights", .longText, "The 3–5 points leadership needs."),
            ]),
            op(4, "report", "Executive Report", "Publish the briefing. Posts a Report.", .report, launches: .reportBuilder, [
                f("summary", "Summary", .longText, "The narrative for the report.", required: true),
            ], gates: [WorkflowGate(rule: .operationConfirmed(seq: 1), reason: "Gather metrics first.")]),
        ])

    /// Journalist — Tip & Lead Intake. Triage incoming tips into leads.
    static let journalistTips = WorkflowDefinition(
        defID: "builtin.journalist.tips", name: "Tip & Lead Intake",
        persona: "journalist", builtin: true, operations: [
            op(1, "ingest", "Ingest Tips", "Bring in the tips and skim them.", nil, launches: .emailInbox, [
                f("source", "Source", .text, "Where the tips came from.", required: true),
                f("tipsCount", "Tips received", .number, "How many messages/tips."),
            ]),
            op(2, "cluster", "Cluster by Topic", "Group tips into themes.", nil, launches: .topicClusters, [
                f("themes", "Themes", .longText, "The recurring subjects worth pursuing."),
            ]),
            op(3, "prioritize", "Prioritize Leads", "Pick the leads worth the work.", nil, launches: .emailInbox, [
                f("topLeads", "Top leads", .longText, "The leads you'll chase, ranked.", required: true),
            ], gates: [WorkflowGate(rule: .operationConfirmed(seq: 2), reason: "Cluster the tips before prioritizing.")]),
            op(4, "annotate", "Annotate", "Open the story file for the chosen leads. Posts a Story version.", .storyVersion, launches: .storyFile, [
                f("notes", "Working notes", .longText, "First annotations on the leads."),
            ]),
        ])

    /// Journalist — Data Story Pack. Numbers → charts → narrative → export.
    static let journalistDataPack = WorkflowDefinition(
        defID: "builtin.journalist.datapack", name: "Data Story Pack",
        persona: "journalist", builtin: true, operations: [
            op(1, "analyze", "Analyze", "Find the numbers behind the story.", nil, launches: .emailAnalytics, [
                f("dataset", "Dataset", .text, "What you're analyzing.", required: true),
                f("keyStat", "Key statistic", .text, "The headline number."),
            ]),
            op(2, "visualize", "Visualize", "Turn the numbers into charts.", nil, launches: .aiVisualizations, [
                f("charts", "Charts produced", .number, "How many visuals you made."),
            ]),
            op(3, "narrative", "Draft Narrative", "Write the story around the data.", nil, launches: .storyFile, [
                f("narrative", "Narrative", .longText, "How the data supports the story.", required: true),
            ], gates: [WorkflowGate(rule: .operationConfirmed(seq: 1), reason: "Analyze before drafting.")]),
            op(4, "export", "Export Pack", "Produce the shareable data pack. Posts Export.", .export, launches: .emailInbox, [
                f("outputName", "Pack name", .text, "Label for this data story pack.", required: true),
            ], gates: [WorkflowGate(rule: .operationConfirmed(seq: 3), reason: "Draft the narrative before exporting.")]),
        ])

    /// Personal — Receipts & Records Roundup. Find, collect, export.
    static let personalReceipts = WorkflowDefinition(
        defID: "builtin.personal.receipts", name: "Receipts & Records Roundup",
        persona: "personal", builtin: true, operations: [
            op(1, "find", "Find Receipts", "Search for the receipts/records you need.", nil, launches: .emailInbox, [
                f("query", "Search for", .text, "e.g. receipt, invoice, order, statement.", placeholder: "receipt OR invoice", required: true),
                f("found", "Matches found", .number, "How many matched."),
            ]),
            op(2, "select", "Review & Select", "Keep the ones that matter.", nil, launches: .emailInbox, [
                f("selected", "Selected", .number, "How many you're keeping."),
            ], gates: [WorkflowGate(rule: .operationConfirmed(seq: 1), reason: "Find them first.")]),
            op(3, "attachments", "Collect Attachments", "Gather the attached PDFs/images.", nil, launches: .attachmentGallery, [
                f("files", "Files collected", .number, "Attachments pulled together."),
            ]),
            op(4, "export", "Export", "Save the roundup. Posts Export.", .export, launches: .emailInbox, [
                f("destination", "Saved to", .text, "Where you filed them."),
            ]),
        ])

    // MARK: - Batch: 19 additional built-in secondary jobs

    static let forensicHeaders = WorkflowDefinition(
        defID: "builtin.forensic.headers", name: "Header & Authentication Analysis",
        persona: "forensic", builtin: true, operations: [
            op(1, "scope", "Scope", "Pick the messages whose headers you will examine.", nil, launches: .itAdminDashboard, [
                f("caseNumber", "Case / Matter number", .text, "Ties this analysis to the investigation.", placeholder: "CASE-2026-0001", required: true),
                f("messageCount", "Messages in scope", .number, "How many messages you are inspecting."),
            ]),
            op(2, "inspect", "Inspect Headers", "Read the raw headers and trace the Received hops.", nil, launches: .itAdminDashboard, [
                f("originIP", "Originating IP", .text, "The first sending IP in the Received chain.", placeholder: "203.0.113.4"),
                f("hopNotes", "Hop notes", .longText, "What the Received chain reveals about routing."),
            ]),
            op(3, "auth", "Check Auth & Spoofing", "Evaluate SPF, DKIM and DMARC, and flag spoofing.", nil, launches: .smartAlerts, [
                f("authResults", "Auth results", .longText, "SPF/DKIM/DMARC pass or fail per message."),
                f("spoofSuspected", "Spoofing suspected", .bool, "Turn on when the sender appears forged."),
            ]),
            op(4, "report", "Report", "Write up the header findings. Posts a Report.", .report, launches: .investigationReport, [
                f("title", "Report title", .text, "Label for this header-analysis report."),
                f("summary", "Findings summary", .longText, "What the headers prove about origin and authenticity."),
            ], gates: [WorkflowGate(rule: .operationConfirmed(seq: 3), reason: "Finish the prior steps first.")]),
        ])

    static let forensicCull = WorkflowDefinition(
        defID: "builtin.forensic.cull", name: "Deduplication & Culling",
        persona: "forensic", builtin: true, operations: [
            op(1, "load", "Load Set", "Load the evidence set you will cull.", nil, launches: .emailInbox, [
                f("caseNumber", "Case / Matter number", .text, "Ties this cull to the investigation.", placeholder: "CASE-2026-0001", required: true),
                f("startCount", "Starting count", .number, "Documents before culling."),
            ]),
            op(2, "dedupe", "Remove Duplicates", "Strip exact duplicates from the set.", nil, launches: .duplicateManager, [
                f("removedDupes", "Duplicates removed", .number, "How many exact duplicates were dropped."),
            ]),
            op(3, "nearDupe", "Near-Duplicate & Date Cull", "Trim near-duplicates and out-of-range dates.", nil, launches: .nearDuplicates, [
                f("nearRemoved", "Near-duplicates removed", .number, "How many near-duplicates were dropped."),
                f("dateFiltered", "Date-filtered out", .number, "How many fell outside the relevant window."),
            ]),
            op(4, "record", "Record Cull", "Record the culling results. Posts a Cleanup.", .cleanup, launches: .investigationReport, [
                f("finalCount", "Final count", .number, "Documents remaining after the cull."),
                f("notes", "Cull notes", .longText, "What was removed and why."),
            ], gates: [WorkflowGate(rule: .operationConfirmed(seq: 3), reason: "Finish the prior steps first.")]),
        ])

    static let forensicIOCReport = WorkflowDefinition(
        defID: "builtin.forensic.iocreport", name: "IOC Extraction & Report",
        persona: "forensic", builtin: true, operations: [
            op(1, "scope", "Scope", "Pick the messages to mine for indicators.", nil, launches: .emailInbox, [
                f("caseNumber", "Case / Matter number", .text, "Ties this extraction to the investigation.", placeholder: "CASE-2026-0001", required: true),
                f("scopeNote", "Scope note", .longText, "What set you are extracting indicators from."),
            ]),
            op(2, "extract", "Extract IOCs", "Pull URLs, domains, IPs and hashes from the set.", nil, launches: .iocExtractor, [
                f("iocCount", "IOCs extracted", .number, "How many indicators were pulled."),
                f("iocTypes", "IOC types", .longText, "Which kinds of indicator you found."),
            ]),
            op(3, "assess", "Assess", "Judge which indicators are genuinely malicious.", nil, launches: .anomalyDetection, [
                f("maliciousCount", "Malicious IOCs", .number, "How many indicators were confirmed bad."),
                f("assessment", "Assessment notes", .longText, "Why these indicators matter."),
            ]),
            op(4, "export", "Export & Report", "Export the indicators and write them up. Posts an Export.", .export, launches: .investigationReport, [
                f("format", "Export format", .text, "How the indicators are delivered.", placeholder: "STIX / CSV"),
                f("summary", "Report summary", .longText, "What the indicators reveal."),
            ], gates: [WorkflowGate(rule: .operationConfirmed(seq: 3), reason: "Finish the prior steps first.")]),
        ])

    static let forensicAffidavit = WorkflowDefinition(
        defID: "builtin.forensic.affidavit", name: "Expert Report",
        persona: "forensic", builtin: true, operations: [
            op(1, "gather", "Gather Findings", "Assemble the findings the report will rest on.", nil, launches: .forensicReview, [
                f("caseNumber", "Case / Matter number", .text, "Ties this report to the investigation.", placeholder: "CASE-2026-0001", required: true),
                f("findings", "Findings", .longText, "The evidence-backed findings you will attest to."),
            ]),
            op(2, "verify", "Verify Integrity", "Confirm the evidence is unchanged since intake.", nil, launches: .chainOfCustody, [
                f("hashMatches", "Hashes match", .bool, "Turn on when re-hashing confirms integrity."),
                f("custodyNotes", "Custody notes", .longText, "The chain-of-custody basis for your integrity claim."),
            ]),
            op(3, "draft", "Draft Report", "Write the body of the expert report.", nil, launches: .investigationReport, [
                f("methodology", "Methodology", .longText, "The methods you applied, stated defensibly."),
                f("opinions", "Opinions", .longText, "The conclusions you are prepared to defend."),
            ]),
            op(4, "finalize", "Finalize", "Finalize and sign off the report. Posts a Report.", .report, launches: .investigationReport, [
                f("title", "Report title", .text, "Label for this expert report."),
                f("signOff", "Signed off", .bool, "Turn on when the report is final and attested."),
            ], gates: [WorkflowGate(rule: .operationConfirmed(seq: 3), reason: "Finish the prior steps first.")]),
        ])

    static let legalCollection = WorkflowDefinition(
        defID: "builtin.legal.collection", name: "Collection",
        persona: "legal", builtin: true, operations: [
            op(1, "identify", "Identify Custodians", "List whose mail must be collected.", nil, launches: .custodianPanel, [
                f("matter", "Matter name", .text, "The matter this collection serves.", placeholder: "Acme v. Roe", required: true),
                f("custodians", "Custodians", .longText, "Everyone whose data is in scope — one per line."),
            ]),
            op(2, "collect", "Collect", "Pull the in-scope mailboxes into the case.", nil, launches: .emailInbox, [
                f("collectedCount", "Items collected", .number, "How many messages were collected."),
                f("sources", "Sources", .longText, "Which mailboxes and stores were collected."),
            ]),
            op(3, "verify", "Verify Completeness", "Confirm nothing in scope was missed.", nil, launches: .custodianPanel, [
                f("verified", "Completeness verified", .bool, "Turn on when every custodian's data is accounted for."),
                f("gaps", "Gaps", .longText, "Any custodians or sources still outstanding."),
            ]),
            op(4, "record", "Record Collection", "Record the collection results. Posts an Import.", .importRun, launches: .reviewDashboard, [
                f("totalCount", "Total collected", .number, "Final count of collected items."),
                f("notes", "Collection notes", .longText, "How and when the collection was done."),
            ], gates: [WorkflowGate(rule: .operationConfirmed(seq: 3), reason: "Finish the prior steps first.")]),
        ])

    static let legalProcessing = WorkflowDefinition(
        defID: "builtin.legal.processing", name: "Processing & Deduplication",
        persona: "legal", builtin: true, operations: [
            op(1, "load", "Load", "Load the collected set for processing.", nil, launches: .emailInbox, [
                f("matter", "Matter name", .text, "The matter being processed.", placeholder: "Acme v. Roe", required: true),
                f("startCount", "Starting count", .number, "Documents before processing."),
            ]),
            op(2, "dedupe", "Deduplicate", "Remove duplicate documents from the set.", nil, launches: .duplicateManager, [
                f("removedDupes", "Duplicates removed", .number, "How many duplicates were dropped."),
            ]),
            op(3, "thread", "Thread", "Group messages into conversation threads.", nil, launches: .threadSummarizer, [
                f("threadCount", "Threads formed", .number, "How many threads the set resolves into."),
                f("notes", "Threading notes", .longText, "Anything notable about the threading."),
            ]),
            op(4, "record", "Record", "Record the processing results. Posts a Cleanup.", .cleanup, launches: .reviewDashboard, [
                f("finalCount", "Final count", .number, "Documents remaining after processing."),
                f("summary", "Processing summary", .longText, "What processing did to the set."),
            ], gates: [WorkflowGate(rule: .operationConfirmed(seq: 3), reason: "Finish the prior steps first.")]),
        ])

    static let legalFirstPass = WorkflowDefinition(
        defID: "builtin.legal.firstpass", name: "First-Pass Review",
        persona: "legal", builtin: true, operations: [
            op(1, "assemble", "Assemble Batch", "Build the batch reviewers will code.", nil, launches: .reviewBatches, [
                f("matter", "Matter name", .text, "The matter under review.", placeholder: "Acme v. Roe", required: true),
                f("batchSize", "Batch size", .number, "How many documents in this batch."),
            ]),
            op(2, "code", "Code Responsiveness", "Tag each document responsive or not.", nil, launches: .emailInbox, [
                f("responsive", "Responsive", .number, "How many were coded responsive."),
                f("nonResponsive", "Non-responsive", .number, "How many were coded non-responsive."),
            ]),
            op(3, "velocity", "Track Velocity", "Watch the review rate against the deadline.", nil, launches: .reviewDashboard, [
                f("docsPerHour", "Docs per hour", .number, "Current review throughput."),
                f("onTrack", "On track", .bool, "Turn on if the pace meets the deadline."),
            ]),
            op(4, "report", "Report", "Report first-pass results. Posts a Report.", .report, launches: .reviewDashboard, [
                f("title", "Report title", .text, "Label for this first-pass report."),
                f("summary", "Summary", .longText, "Where the review stands and what is left."),
            ], gates: [WorkflowGate(rule: .operationConfirmed(seq: 3), reason: "Finish the prior steps first.")]),
        ])

    static let legalClawback = WorkflowDefinition(
        defID: "builtin.legal.clawback", name: "Clawback",
        persona: "legal", builtin: true, operations: [
            op(1, "identify", "Identify Disclosure", "Pin down the inadvertently disclosed material.", nil, launches: .reviewDashboard, [
                f("matter", "Matter name", .text, "The matter this clawback serves.", placeholder: "Acme v. Roe", required: true),
                f("disclosed", "Disclosed items", .longText, "What was produced that should not have been."),
            ]),
            op(2, "notify", "Notify & Log", "Send the clawback notice and log it.", nil, launches: .custodianPanel, [
                f("noticeSent", "Notice sent", .bool, "Turn on once the clawback notice has gone out."),
                f("recipients", "Recipients", .longText, "Who was notified of the clawback."),
            ]),
            op(3, "redact", "Redact or Remove", "Redact or pull the affected material.", nil, launches: .redaction, [
                f("itemsRemedied", "Items remedied", .number, "How many documents were redacted or removed."),
            ]),
            op(4, "record", "Record", "Record the clawback outcome. Posts a Report.", .report, launches: .reportBuilder, [
                f("title", "Record title", .text, "Label for this clawback record."),
                f("summary", "Summary", .longText, "What was clawed back and how it was resolved."),
            ], gates: [WorkflowGate(rule: .operationConfirmed(seq: 3), reason: "Finish the prior steps first.")]),
        ])

    static let itQuarantine = WorkflowDefinition(
        defID: "builtin.it.quarantine", name: "Quarantine Review",
        persona: "it_admin", builtin: true, operations: [
            op(1, "load", "Load Quarantine", "Pull the quarantined messages to review.", nil, launches: .phishingTriage, [
                f("queueName", "Queue name", .text, "Which quarantine queue you are working.", placeholder: "Default quarantine", required: true),
                f("itemCount", "Items in queue", .number, "How many messages are quarantined."),
            ]),
            op(2, "analyze", "Analyze", "Extract indicators and inspect the messages.", nil, launches: .iocExtractor, [
                f("iocCount", "IOCs found", .number, "How many indicators the messages contain."),
                f("notes", "Analysis notes", .longText, "What the analysis shows."),
            ]),
            op(3, "verdict", "Verdict", "Decide malicious, spam or clean per message.", nil, launches: .phishingTriage, [
                f("malicious", "Malicious", .number, "How many were judged malicious."),
                f("clean", "Clean", .number, "How many were judged safe to release."),
            ]),
            op(4, "close", "Release or Close", "Release the clean, hold the rest. Posts a Triage Verdict.", .triageVerdict, launches: .phishingTriage, [
                f("released", "Released", .number, "How many messages were released to users."),
                f("summary", "Disposition summary", .longText, "What happened to the queue."),
            ], gates: [WorkflowGate(rule: .operationConfirmed(seq: 3), reason: "Finish the prior steps first.")]),
        ])

    static let itRules = WorkflowDefinition(
        defID: "builtin.it.rules", name: "Inbox Rule Audit",
        persona: "it_admin", builtin: true, operations: [
            op(1, "scope", "Scope Mailboxes", "Choose the mailboxes to audit.", nil, launches: .itAdminDashboard, [
                f("scopeName", "Scope name", .text, "Which mailboxes or group you are auditing.", placeholder: "Finance dept", required: true),
                f("mailboxCount", "Mailboxes in scope", .number, "How many mailboxes are covered."),
            ]),
            op(2, "find", "Find Rules", "Surface auto-forward and hidden inbox rules.", nil, launches: .anomalyDetection, [
                f("rulesFound", "Rules found", .number, "How many inbox rules were discovered."),
                f("suspicious", "Suspicious rules", .longText, "Rules that forward or hide mail."),
            ]),
            op(3, "assess", "Assess", "Judge which rules signal compromise.", nil, launches: .iocExtractor, [
                f("maliciousRules", "Malicious rules", .number, "How many rules are hostile."),
                f("assessment", "Assessment", .longText, "Why these rules are a concern."),
            ]),
            op(4, "report", "Report", "Report the rule findings. Posts a Report.", .report, launches: .investigationReport, [
                f("title", "Report title", .text, "Label for this rule-audit report."),
                f("summary", "Summary", .longText, "What the audit found and what to remediate."),
            ], gates: [WorkflowGate(rule: .operationConfirmed(seq: 3), reason: "Finish the prior steps first.")]),
        ])

    static let itBlocklist = WorkflowDefinition(
        defID: "builtin.it.blocklist", name: "Blocklist Export",
        persona: "it_admin", builtin: true, operations: [
            op(1, "gather", "Gather IOCs", "Collect the indicators to block.", nil, launches: .iocExtractor, [
                f("sourceName", "Source name", .text, "Where these indicators come from.", placeholder: "Campaign 2026-08", required: true),
                f("iocCount", "IOCs gathered", .number, "How many indicators you collected."),
            ]),
            op(2, "validate", "Validate", "Weed out false positives before blocking.", nil, launches: .anomalyDetection, [
                f("validated", "Validated IOCs", .number, "How many indicators survived validation."),
                f("rejected", "Rejected", .number, "How many were dropped as false positives."),
            ]),
            op(3, "compile", "Compile Blocklist", "Assemble the final blocklist.", nil, launches: .iocExtractor, [
                f("entryCount", "Blocklist entries", .number, "How many entries the blocklist contains."),
                f("notes", "Compile notes", .longText, "Anything notable about the list."),
            ]),
            op(4, "export", "Export", "Export the blocklist for the gateway. Posts an Export.", .export, launches: .investigationReport, [
                f("format", "Export format", .text, "The format the gateway expects.", placeholder: "CSV / plaintext"),
                f("summary", "Export summary", .longText, "What was exported and where it goes."),
            ], gates: [WorkflowGate(rule: .operationConfirmed(seq: 3), reason: "Finish the prior steps first.")]),
        ])

    static let itDLP = WorkflowDefinition(
        defID: "builtin.it.dlp", name: "Data Exfiltration Review",
        persona: "it_admin", builtin: true, operations: [
            op(1, "scope", "Scope", "Define the sensitive terms and window to review.", nil, launches: .keywordMonitor, [
                f("scopeName", "Scope name", .text, "What exfiltration concern you are reviewing.", placeholder: "PII leak Q3", required: true),
                f("window", "Time window", .dateRange, "The period under review — pick From and To."),
            ]),
            op(2, "scan", "Scan Sensitive Terms", "Search the traffic for sensitive terms.", nil, launches: .keywordMonitor, [
                f("hits", "Term hits", .number, "How many messages hit a sensitive term."),
                f("terms", "Terms used", .longText, "The sensitive terms you scanned for."),
            ]),
            op(3, "traffic", "Traffic Analysis", "Look for abnormal outbound patterns.", nil, launches: .communicationPatterns, [
                f("anomalies", "Anomalies", .number, "How many abnormal outbound patterns you found."),
                f("notes", "Traffic notes", .longText, "What the outbound patterns reveal."),
            ]),
            op(4, "report", "Report", "Report the exfiltration findings. Posts a Report.", .report, launches: .investigationReport, [
                f("title", "Report title", .text, "Label for this exfiltration report."),
                f("summary", "Summary", .longText, "What data may have left and how."),
            ], gates: [WorkflowGate(rule: .operationConfirmed(seq: 3), reason: "Finish the prior steps first.")]),
        ])

    static let journalistProvenance = WorkflowDefinition(
        defID: "builtin.journalist.provenance", name: "Provenance Check",
        persona: "journalist", builtin: true, operations: [
            op(1, "receive", "Receive Material", "Take in the material and note where it came from.", nil, launches: .emailInbox, [
                f("storyName", "Story name", .text, "The story this material feeds.", placeholder: "The leaked memos", required: true),
                f("origin", "Stated origin", .longText, "Where the source says the material came from."),
            ]),
            op(2, "verify", "Verify Authenticity", "Check the material is genuine, not fabricated.", nil, launches: .forensicReview, [
                f("authentic", "Appears authentic", .bool, "Turn on when the material checks out."),
                f("checks", "Authenticity checks", .longText, "What you did to confirm authenticity."),
            ]),
            op(3, "corroborate", "Corroborate Source", "Find independent support for the material.", nil, launches: .emailInbox, [
                f("corroboration", "Corroboration", .longText, "Independent evidence that backs the material."),
                f("sourceCount", "Corroborating sources", .number, "How many independent sources agree."),
            ]),
            op(4, "record", "Record", "Record the provenance finding. Posts a Report.", .report, launches: .storyFile, [
                f("title", "Record title", .text, "Label for this provenance record."),
                f("finding", "Provenance finding", .longText, "Your conclusion on the material's provenance."),
            ], gates: [WorkflowGate(rule: .operationConfirmed(seq: 3), reason: "Finish the prior steps first.")]),
        ])

    static let journalistFOIA = WorkflowDefinition(
        defID: "builtin.journalist.foia", name: "Records Request (FOIA)",
        persona: "journalist", builtin: true, operations: [
            op(1, "draft", "Draft Request", "Write the records request to send.", nil, launches: .emailInbox, [
                f("agency", "Agency", .text, "Which body you are requesting records from.", placeholder: "City Housing Authority", required: true),
                f("request", "Request text", .longText, "What records you are asking for."),
            ]),
            op(2, "track", "Track Responses", "Follow the agency's replies and deadlines.", nil, launches: .emailInbox, [
                f("status", "Response status", .text, "Where the request stands.", placeholder: "Acknowledged / partial / denied"),
                f("dueDate", "Statutory due date", .text, "When the response is legally due.", placeholder: "2026-09-15"),
            ]),
            op(3, "review", "Review Released Records", "Read what the agency released.", nil, launches: .emailInbox, [
                f("recordCount", "Records released", .number, "How many records you received."),
                f("notes", "Review notes", .longText, "What the released records show."),
            ]),
            op(4, "log", "Log", "Log the request outcome. Posts a Report.", .report, launches: .reportBuilder, [
                f("title", "Log title", .text, "Label for this request log."),
                f("outcome", "Outcome", .longText, "What was released, withheld, or appealed."),
            ], gates: [WorkflowGate(rule: .operationConfirmed(seq: 3), reason: "Finish the prior steps first.")]),
        ])

    static let journalistQuotes = WorkflowDefinition(
        defID: "builtin.journalist.quotes", name: "Quote & Attribution",
        persona: "journalist", builtin: true, operations: [
            op(1, "find", "Find Statements", "Locate the quotable statements in the mail.", nil, launches: .emailInbox, [
                f("storyName", "Story name", .text, "The story these quotes serve.", placeholder: "The leaked memos", required: true),
                f("query", "Search for", .text, "Terms that surface the statements you need.", placeholder: "\"we knew\""),
            ]),
            op(2, "summarize", "Summarize Threads", "Read the surrounding threads for context.", nil, launches: .threadSummarizer, [
                f("threadCount", "Threads read", .number, "How many threads you reviewed for context."),
                f("context", "Context notes", .longText, "What the threads add to the quotes."),
            ]),
            op(3, "attribute", "Attribute Sources", "Tie each quote to who said it and when.", nil, launches: .storyFile, [
                f("attributions", "Attributions", .longText, "Each quote with its speaker and date."),
            ]),
            op(4, "save", "Save", "Save the attributed quotes. Posts a Story Version.", .storyVersion, launches: .storyFile, [
                f("versionLabel", "Version label", .text, "Label for this saved quote set."),
                f("summary", "Summary", .longText, "What these quotes establish for the story."),
            ], gates: [WorkflowGate(rule: .operationConfirmed(seq: 3), reason: "Finish the prior steps first.")]),
        ])

    static let journalistCrossRef = WorkflowDefinition(
        defID: "builtin.journalist.crossref", name: "Cross-Reference Datasets",
        persona: "journalist", builtin: true, operations: [
            op(1, "load", "Load Datasets", "Load the datasets you will cross-reference.", nil, launches: .archiveComparison, [
                f("storyName", "Story name", .text, "The story this comparison serves.", placeholder: "The leaked memos", required: true),
                f("datasets", "Datasets", .longText, "Which sets you are comparing — one per line."),
            ]),
            op(2, "compare", "Compare", "Diff the datasets to surface differences.", nil, launches: .archiveComparison, [
                f("differences", "Differences", .number, "How many differences the comparison found."),
                f("notes", "Comparison notes", .longText, "What the differences suggest."),
            ]),
            op(3, "map", "Map Overlaps", "Chart where the datasets connect.", nil, launches: .relationshipGraph, [
                f("overlaps", "Overlaps", .number, "How many overlapping entities you mapped."),
                f("mapNotes", "Map notes", .longText, "What the overlaps reveal."),
            ]),
            op(4, "report", "Report", "Report the cross-reference findings. Posts a Report.", .report, launches: .storyFile, [
                f("title", "Report title", .text, "Label for this cross-reference report."),
                f("summary", "Summary", .longText, "What linking the datasets uncovered."),
            ], gates: [WorkflowGate(rule: .operationConfirmed(seq: 3), reason: "Finish the prior steps first.")]),
        ])

    static let personalBackup = WorkflowDefinition(
        defID: "builtin.personal.backup", name: "Full Backup",
        persona: "personal", builtin: true, operations: [
            op(1, "scope", "Choose Scope", "Pick what to back up.", nil, launches: .emailInbox, [
                f("scopeName", "What to back up", .text, "Which mail you are backing up.", placeholder: "All mail", required: true),
                f("itemCount", "Items in scope", .number, "How many messages are covered."),
            ]),
            op(2, "dedupe", "Deduplicate", "Drop duplicates so the backup stays lean.", nil, launches: .duplicateManager, [
                f("removedDupes", "Duplicates removed", .number, "How many duplicates were dropped."),
            ]),
            op(3, "export", "Export Backup", "Write the backup out.", nil, launches: .emailInbox, [
                f("format", "Backup format", .text, "The format you are saving in.", placeholder: "MBOX / ZIP"),
                f("size", "Backup size", .text, "Roughly how big the backup is.", placeholder: "2.3 GB"),
            ]),
            op(4, "confirm", "Confirm", "Confirm the backup is complete and readable. Posts an Export.", .export, launches: .emailInbox, [
                f("destination", "Saved to", .text, "Where the backup lives."),
                f("verified", "Verified readable", .bool, "Turn on once you have confirmed the backup opens."),
            ], gates: [WorkflowGate(rule: .operationConfirmed(seq: 3), reason: "Finish the prior steps first.")]),
        ])

    static let personalAttachments = WorkflowDefinition(
        defID: "builtin.personal.attachments", name: "Find Attachments",
        persona: "personal", builtin: true, operations: [
            op(1, "search", "Search", "Search for the mail with the attachments you want.", nil, launches: .emailInbox, [
                f("query", "Search for", .text, "Terms that find the right mail.", placeholder: "invoice pdf", required: true),
                f("found", "Matches found", .number, "How many messages matched."),
            ]),
            op(2, "browse", "Browse Gallery", "Skim the attachments in the gallery.", nil, launches: .attachmentGallery, [
                f("attachmentCount", "Attachments shown", .number, "How many attachments the gallery holds."),
            ]),
            op(3, "select", "Select", "Keep the attachments you want.", nil, launches: .attachmentGallery, [
                f("selected", "Selected", .number, "How many attachments you are keeping."),
            ]),
            op(4, "export", "Export", "Save the selected attachments. Posts an Export.", .export, launches: .emailInbox, [
                f("destination", "Saved to", .text, "Where you saved the attachments."),
                f("count", "Files exported", .number, "How many files were saved out."),
            ], gates: [WorkflowGate(rule: .operationConfirmed(seq: 3), reason: "Finish the prior steps first.")]),
        ])

    static let personalContacts = WorkflowDefinition(
        defID: "builtin.personal.contacts", name: "Contacts Roundup",
        persona: "personal", builtin: true, operations: [
            op(1, "analyze", "Analyze Contacts", "See who you correspond with most.", nil, launches: .emailAnalytics, [
                f("scopeName", "What to analyze", .text, "Which mail you are drawing contacts from.", placeholder: "All mail", required: true),
                f("contactCount", "Contacts found", .number, "How many distinct contacts appear."),
            ]),
            op(2, "patterns", "Communication Patterns", "Look at how often you talk to each.", nil, launches: .communicationPatterns, [
                f("topContacts", "Top contacts", .longText, "The people you correspond with most."),
            ]),
            op(3, "select", "Select Key Contacts", "Pick the contacts worth keeping.", nil, launches: .emailInbox, [
                f("selected", "Selected", .number, "How many contacts you are keeping."),
            ]),
            op(4, "export", "Export", "Export the contacts list. Posts an Export.", .export, launches: .emailInbox, [
                f("destination", "Saved to", .text, "Where you saved the contacts."),
                f("format", "Format", .text, "The format you exported in.", placeholder: "vCard / CSV"),
            ], gates: [WorkflowGate(rule: .operationConfirmed(seq: 3), reason: "Finish the prior steps first.")]),
        ])

    // MARK: - Researcher jobs (V3 Phase 5 — kalsmritikosh RES-01/07/08, INV-06)
    // Shipped under the General Explorer persona until the dedicated
    // Researcher persona lands; the jobs themselves are complete.

    static let researchProtocol = WorkflowDefinition(
        defID: "builtin.researcher.protocol", name: "Research Protocol",
        persona: "general", builtin: true, operations: [
            op(1, "question", "Research Question", "State the question this corpus should answer — the protocol persists with the record.", nil, launches: .emailInbox, [
                f("question", "Question", .longText, "The question being investigated.", required: true),
                f("scope", "Corpus scope", .text, "Which archives / senders / date range are in scope.", required: true),
                f("dateBounds", "Date bounds", .text, "Earliest and latest dates considered.", placeholder: "e.g. 2019-01 to 2022-12"),
            ]),
            op(2, "method", "Method Plan", "Record how you will search, screen, and code — before you start.", nil, launches: .reasoningStudio, [
                f("searchPlan", "Search plan", .longText, "Terms, operators, and saved searches you will run.", required: true),
                f("criteria", "Include / exclude criteria", .longText, "What qualifies an email into the study.", required: true),
            ], gates: afterPrevious(2)),
            op(3, "protocolDoc", "Post Protocol", "Posts the protocol as a numbered document — the method is now on record.", .report, launches: .emailInbox, [
                f("notes", "Protocol notes", .longText, "Anything future readers need to reproduce the study."),
            ], gates: afterPrevious(3)),
        ])

    static let researcherScreening = WorkflowDefinition(
        defID: "builtin.researcher.screening", name: "Screening (Include / Exclude)",
        persona: "general", builtin: true, operations: [
            op(1, "criteria", "Confirm Criteria", "Restate the include/exclude criteria from your protocol.", nil, launches: .emailInbox, [
                f("criteria", "Criteria", .longText, "The rules that decide inclusion.", required: true),
            ]),
            op(2, "screen", "Screen the Corpus", "Search and tag: decisions are recorded, reversible, never silent.", nil, launches: .emailInbox, [
                f("included", "Included", .number, "How many emails were screened in."),
                f("excluded", "Excluded", .number, "How many were screened out."),
                f("excludeReasons", "Exclusion reasons", .longText, "Why the excluded ones were excluded — recorded, not silent."),
            ], gates: afterPrevious(2)),
            op(3, "log", "Post Screening Log", "Posts the screening decisions as a numbered document.", .report, launches: .emailInbox, [
                f("notes", "Notes", .longText, "Edge cases and judgment calls."),
            ], gates: afterPrevious(3)),
        ])

    static let researcherCoding = WorkflowDefinition(
        defID: "builtin.researcher.coding", name: "Extraction & Coding",
        persona: "general", builtin: true, operations: [
            op(1, "codebook", "Codebook", "Define the codes before coding — each code needs a definition.", nil, launches: .emailInbox, [
                f("codes", "Codes & definitions", .longText, "One code per line with its meaning.", required: true),
            ]),
            op(2, "code", "Code the Passages", "Tag emails with codes; every coded passage cites its email.", nil, launches: .emailInbox, [
                f("codedCount", "Emails coded", .number, "How many emails carry at least one code."),
            ], gates: afterPrevious(2)),
            op(3, "dataset", "Post Coded Dataset", "Posts the coded dataset summary as a numbered document; export CSV for analysis.", .report, launches: .emailInbox, [
                f("export", "Exported to", .text, "Where the coded dataset was saved."),
            ], gates: afterPrevious(3)),
        ])

    static let forensicEvidencePlan = WorkflowDefinition(
        defID: "builtin.forensic.evidenceplan", name: "Evidence Collection Plan",
        persona: "forensic", builtin: true, operations: [
            op(1, "hypotheses", "Hypotheses & Gaps", "List what each hypothesis still lacks — start from your ACH matrix.", nil, launches: .achMatrix, [
                f("gaps", "Evidence gaps", .longText, "What is missing, per hypothesis.", required: true),
            ]),
            op(2, "requests", "Evidence Requests", "One request per gap: source, custodian, and what it would show. Requests assert nothing.", nil, launches: .evidenceDesks, [
                f("requests", "Requests", .longText, "Numbered requests linked to hypotheses.", required: true),
                f("custodians", "Custodians involved", .text, "Who holds each requested item."),
            ], gates: afterPrevious(2)),
            op(3, "plan", "Post Collection Plan", "Posts the plan as a numbered document — never asserts the evidence exists.", .report, launches: .emailInbox, [
                f("notes", "Notes", .longText, "Constraints, deadlines, legal considerations."),
            ], gates: afterPrevious(3)),
        ])

    static let all: [WorkflowDefinition] = [
        forensic, legal, itAdmin, journalist, personal,
        forensicTimeline, legalHold, legalECA, legalDSAR, itThreatHunt, journalistNetwork,
        itCampaign, forensicKeywordSweep, forensicCustodyVerify,
        itBEC, journalistFactCheck, journalistPublish, personalFindExport, personalDeclutter,
        forensicExhibit, forensicInsider, legalPrivQC, legalCompliance,
        itAuthAudit, itMetrics, journalistTips, journalistDataPack, personalReceipts,
        forensicHeaders, forensicCull, forensicIOCReport, forensicAffidavit,
        legalCollection, legalProcessing, legalFirstPass, legalClawback,
        itQuarantine, itRules, itBlocklist, itDLP,
        journalistProvenance, journalistFOIA, journalistQuotes, journalistCrossRef,
        personalBackup, personalAttachments, personalContacts,
        researchProtocol, researcherScreening, researcherCoding, forensicEvidencePlan,
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
        case "builtin.forensic.exhibit":
            return "Turn tagged evidence into a court-ready package — select, redact, Bates-stamp, and export with a cover report."
        case "builtin.forensic.insider":
            return "Judge a subject across comms patterns, anomalies, and risky terms — and record the finding for HR/legal."
        case "builtin.legal.privqc":
            return "The pre-production safety pass — QC the privilege log, redact, stamp, and sign off before anything ships."
        case "builtin.legal.compliance":
            return "Audit the set for personal data — scan, classify sensitivity, remediate, and report compliance."
        case "builtin.it.authaudit":
            return "Check your senders' SPF/DKIM/DMARC posture, look for spoofing, and report fixes."
        case "builtin.it.metrics":
            return "Turn a period's triage activity into an executive security briefing — metrics, trends, report."
        case "builtin.journalist.tips":
            return "Triage a pile of tips into real leads — ingest, cluster by theme, prioritize, and start the story."
        case "builtin.journalist.datapack":
            return "Build a data-driven story — analyze the numbers, visualize, draft the narrative, export the pack."
        case "builtin.personal.receipts":
            return "Round up receipts and records — search, select, collect attachments, and export them in one go."
        case "builtin.personal.cleanup":
            return "Tidy a personal archive — import, dedupe, categorize, and export a clean backup."
        case "builtin.forensic.headers":
            return "Read the raw headers, trace the routing, and prove whether a message is authentic or spoofed."
        case "builtin.forensic.cull":
            return "Shrink the evidence set defensibly — drop exact and near-duplicates and out-of-range dates, then record the cull."
        case "builtin.forensic.iocreport":
            return "Mine the mail for indicators of compromise, judge which are real, and export a reported set."
        case "builtin.forensic.affidavit":
            return "Turn your findings into a signed expert report, with evidence integrity verified before you attest."
        case "builtin.legal.collection":
            return "Collect the custodians' mail into the case and prove the collection was complete."
        case "builtin.legal.processing":
            return "Get a collected set review-ready — deduplicate, thread, and record what processing changed."
        case "builtin.legal.firstpass":
            return "Run the first-pass responsiveness review — batch it, code it, watch the pace, and report progress."
        case "builtin.legal.clawback":
            return "Recover inadvertently produced material — identify it, notify opposing counsel, redact or remove, and log it."
        case "builtin.it.quarantine":
            return "Work the quarantine queue — analyze the held mail, verdict each one, and release the clean or hold the rest."
        case "builtin.it.rules":
            return "Audit mailboxes for hostile auto-forward and hidden inbox rules that signal a compromise, and report them."
        case "builtin.it.blocklist":
            return "Turn confirmed indicators into a validated blocklist your mail gateway can import."
        case "builtin.it.dlp":
            return "Hunt for data leaving the org — scan sensitive terms, analyze outbound traffic, and report suspected exfiltration."
        case "builtin.journalist.provenance":
            return "Establish where leaked material came from — verify it is genuine, corroborate the source, and record the finding."
        case "builtin.journalist.foia":
            return "Run a public-records request end to end — draft it, track responses, review what's released, and log the outcome."
        case "builtin.journalist.quotes":
            return "Pull quotable statements, read the surrounding threads for context, and attribute each quote to who said it."
        case "builtin.journalist.crossref":
            return "Cross-reference two datasets — compare them, map where they overlap, and report what the links reveal."
        case "builtin.personal.backup":
            return "Make a lean, verified backup of your mail — pick the scope, dedupe, export, and confirm it opens."
        case "builtin.personal.attachments":
            return "Find and save the attachments you need — search, browse the gallery, select, and export."
        case "builtin.personal.contacts":
            return "Round up your key contacts — analyze who you talk to, spot the patterns, pick the keepers, and export them."
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
