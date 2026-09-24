//
//  Capability.swift
//  mailin
//
//  The on/off matrix, one level below the four pages.
//
//  `AppModule` answers "is this PAGE on?". This file answers "is this
//  particular capability on?" — so a user (or a rollback) can switch off one
//  engine, one background job or one surface without giving up the page it
//  lives on, and without anything being destroyed.
//
//  Three rules the whole layer is built around:
//
//   1. **A capability can never run while its page is off.** `isOn` requires
//      BOTH. That keeps the page-independence rules (V3_0_PLAN.md §3.3 R1–R6)
//      true no matter what the capability table says — a stale "on" flag for
//      an AI capability cannot resurrect AI work on a Page-1-only install.
//
//   2. **Off means dormant, never destructive.** Every capability states, in
//      `whenOff`, what happens to work already done. Nothing here deletes
//      data: switching the blob tier off still READS existing blobs, and
//      switching a studio off keeps its cases. "Nothing will be lost" is the
//      requirement, so it is a property of the type, not a convention.
//
//   3. **New and unproven defaults to OFF.** A capability shipped before it
//      has been executed against real data starts off, so installing this
//      build changes no behaviour until someone deliberately turns it on.
//      `maturity` says which is which, and the matrix shows it.
//
//  Dependencies are declared (`requires`) rather than implied: locator-backed
//  reads are meaningless without the offset parser, so turning the parser off
//  turns the reads off too, and the matrix explains why the row is dimmed.
//

import Foundation

/// One individually switchable capability.
///
/// Raw values are the persistence keys and must never be renamed — a renamed
/// key silently reverts a user's choice to the default, which for an
/// experimental capability means silently turning it ON.
enum Capability: String, CaseIterable, Codable, Sendable, Identifiable {

    // MARK: Archive (Page 1) — storage and parsing engines

    /// S3b. Raw MIME above 8 MiB goes to the content-addressed blob store
    /// instead of the row, because SQLite's 1 GB row ceiling makes a
    /// multi-gigabyte message unstorable inline.
    case blobTier

    /// S4. Offset-based mbox/eml scanning: index message boundaries, parse
    /// headers only, never decode a body at import. Removes the 100 MB
    /// single-message ceiling.
    case offsetParser

    /// S5. Attachment and export reads served from byte ranges in the source
    /// rather than from a re-parse of the whole message.
    case locatorReads

    /// B5. Let the archive live on a chosen volume (internal or a local
    /// external SSD). No cloud: the store file must never be in iCloud.
    case externalStorage

    // MARK: Archive — import and search surfaces

    /// A3. The pre-import sheet: what was detected, what it will cost, what
    /// will be indexed, before anything is written.
    case guidedImport

    /// A4. A visible queue of pending, running and finished imports, with
    /// per-source verdicts.
    case importQueue

    /// S0. The note under search results saying how many messages are indexed
    /// only in part, so a miss is not mistaken for an absence.
    case searchCoverageBadge

    // MARK: AI Insights (Page 2)

    case aiAssistant
    case aiDigest
    case anomalyDetection
    case smartAutoTagger
    case topicClusters
    case threadSummarizer
    case smartAlerts
    case keywordMonitor
    case predictiveCoding

    // MARK: Professional Workflows (Page 3)

    case custodianPanel
    case reviewBatches
    case auditTrail
    case eDiscovery
    case batesNumbering
    case redaction
    case gdprReport
    case chainOfCustody
    case investigationReport
    case reportBuilder
    case reasoningStudios

    var id: String { rawValue }

    // MARK: Ownership

    /// The page that owns this capability. `isOn` is false whenever the owner
    /// is off, whatever the stored flag says.
    var owner: AppModule {
        switch self {
        case .blobTier, .offsetParser, .locatorReads, .externalStorage,
             .guidedImport, .importQueue, .searchCoverageBadge:
            return .archive
        case .aiAssistant, .aiDigest, .anomalyDetection, .smartAutoTagger,
             .topicClusters, .threadSummarizer, .smartAlerts, .keywordMonitor,
             .predictiveCoding:
            return .aiInsights
        case .custodianPanel, .reviewBatches, .auditTrail, .eDiscovery,
             .batesNumbering, .redaction, .gdprReport, .chainOfCustody,
             .investigationReport, .reportBuilder, .reasoningStudios:
            return .professional
        }
    }

    // MARK: Maturity and defaults

    enum Maturity: String, Sendable {
        /// Shipped and exercised. On by default.
        case stable
        /// Implemented but not yet executed against real data. OFF by default,
        /// so installing the build changes nothing until asked.
        case preview
        /// Rewrites a core path. OFF by default, and the matrix warns.
        case experimental

        var label: String {
            switch self {
            case .stable: return "Stable"
            case .preview: return "Preview"
            case .experimental: return "Experimental"
            }
        }
    }

    var maturity: Maturity {
        switch self {
        // The engines added in this release cycle. None has been run against a
        // real archive yet, so none of them changes behaviour on install.
        case .offsetParser, .locatorReads:
            return .experimental
        case .blobTier, .externalStorage, .guidedImport, .importQueue:
            return .preview
        // Everything that shipped in 2.x / 2.1 and has been used.
        case .searchCoverageBadge, .aiAssistant, .aiDigest, .anomalyDetection,
             .smartAutoTagger, .topicClusters, .threadSummarizer, .smartAlerts,
             .keywordMonitor, .predictiveCoding, .custodianPanel,
             .reviewBatches, .auditTrail, .eDiscovery, .batesNumbering,
             .redaction, .gdprReport, .chainOfCustody, .investigationReport,
             .reportBuilder, .reasoningStudios:
            return .stable
        }
    }

    /// Whether this capability is on for a user who has never touched the
    /// matrix. Stable capabilities are on; anything unproven is off.
    var defaultsOn: Bool { maturity == .stable }

    // MARK: Dependencies

    /// Capabilities that must also be on. A dependency that is off makes this
    /// one off, and the matrix says which dependency is responsible rather
    /// than showing an unexplained dimmed row.
    var requires: [Capability] {
        switch self {
        case .locatorReads:
            // Byte-range reads need the offset index that only the offset
            // parser produces. Without it there are no locators to read from.
            return [.offsetParser]
        case .offsetParser:
            // A message too large to be a row has to have somewhere to live.
            return [.blobTier]
        case .importQueue:
            return [.guidedImport]
        default:
            return []
        }
    }

    // MARK: Copy

    var displayName: String {
        switch self {
        case .blobTier: return "Large-message storage"
        case .offsetParser: return "Offset parser (no message size limit)"
        case .locatorReads: return "Byte-range attachment & export reads"
        case .externalStorage: return "Archive on another volume"
        case .guidedImport: return "Pre-import review sheet"
        case .importQueue: return "Import queue"
        case .searchCoverageBadge: return "Search coverage note"
        case .aiAssistant: return "Ask questions"
        case .aiDigest: return "Digests & summaries"
        case .anomalyDetection: return "Anomaly detection"
        case .smartAutoTagger: return "Auto-tagging"
        case .topicClusters: return "Topic clusters"
        case .threadSummarizer: return "Thread summaries"
        case .smartAlerts: return "Smart alerts"
        case .keywordMonitor: return "Keyword monitor"
        case .predictiveCoding: return "Predictive coding (TAR)"
        case .custodianPanel: return "Cases & custodians"
        case .reviewBatches: return "Review batches"
        case .auditTrail: return "Audit trail"
        case .eDiscovery: return "eDiscovery workflow"
        case .batesNumbering: return "Bates numbering"
        case .redaction: return "Redaction"
        case .gdprReport: return "GDPR report"
        case .chainOfCustody: return "Chain of custody"
        case .investigationReport: return "Investigation report"
        case .reportBuilder: return "Report builder"
        case .reasoningStudios: return "Reasoning studios"
        }
    }

    var detail: String {
        switch self {
        case .blobTier:
            return "Stores raw MIME over 8 MB beside the database instead of inside a row, so a multi-gigabyte message can be archived at all."
        case .offsetParser:
            return "Indexes message boundaries and parses headers only, so import memory does not scale with message size. Removes the 100 MB single-message ceiling."
        case .locatorReads:
            return "Reads an attachment or an export straight from its byte range in the stored source, instead of re-parsing the whole message."
        case .externalStorage:
            return "Keeps the archive on a volume you choose — an internal disk or a local external SSD. Never a cloud folder."
        case .guidedImport:
            return "Before writing anything: the detected format, the space required, what will be indexed, and what will not."
        case .importQueue:
            return "Pending, running and finished imports in one list, each with its Complete / Partial / Failed verdict."
        case .searchCoverageBadge:
            return "Says how many messages are searchable only in part, so an empty result is not read as proof of absence."
        case .aiAssistant: return "Questions answered with citations back to the exact messages."
        case .aiDigest: return "Summaries of a selection, a conversation or a search result."
        case .anomalyDetection: return "Unusual sending times, frequency spikes and first-seen domains."
        case .smartAutoTagger: return "Suggested tags across the archive."
        case .topicClusters: return "Groups the archive by topic."
        case .threadSummarizer: return "Conversation overviews."
        case .smartAlerts: return "Notifications when a rule you set matches."
        case .keywordMonitor: return "Flags messages containing terms you choose."
        case .predictiveCoding: return "Learns from your tagging to rank documents for review."
        case .custodianPanel: return "Case intake, custodian records and collection scope."
        case .reviewBatches: return "Messages organised into batches for systematic review."
        case .auditTrail: return "Tamper-evident HMAC chain of who did what, when."
        case .eDiscovery: return "End-to-end case management."
        case .batesNumbering: return "Sequential production stamping."
        case .redaction: return "Person and PII redaction with a validation pass."
        case .gdprReport: return "Data-protection reporting."
        case .chainOfCustody: return "Evidence tracking with a signed PDF."
        case .investigationReport: return "The full case report as a PDF."
        case .reportBuilder: return "Assemble a report from archive sections."
        case .reasoningStudios: return "ACH matrix, reasoning studio, fact–evidence matrix, evidence desks, action register."
        }
    }

    /// What happens to existing work when this is switched off. Nothing in
    /// this list deletes anything — that is the point.
    var whenOff: String {
        switch self {
        case .blobTier:
            return "Messages already stored outside the database are still read normally. New messages over 8 MB will fail to import until this is back on."
        case .offsetParser:
            return "Import returns to the streaming parser. Already-imported messages are unaffected; single messages over 100 MB are again reported as damaged rather than imported."
        case .locatorReads:
            return "Attachments and exports are served by re-parsing the stored source, as before. Nothing about the stored data changes."
        case .externalStorage:
            return "The archive stays exactly where it is. Only the ability to choose a different location is hidden."
        case .guidedImport:
            return "Imports start immediately on selection, as in 2.x. The storage preflight and the receipt still run."
        case .importQueue:
            return "Import progress shows in the toolbar only. Receipts are still written and still readable from the File menu."
        case .searchCoverageBadge:
            return "The note is hidden. Coverage is still recorded per message and still available on each message."
        case .predictiveCoding:
            return "Your relevant / irrelevant tags are kept. Only the ranking stops being computed."
        case .auditTrail, .chainOfCustody:
            return "The existing chain is kept intact and stays verifiable. No new entries are appended while this is off."
        case .custodianPanel, .reviewBatches, .eDiscovery:
            return "Cases, custodians, batches and legal holds are all kept. No hold is ever lifted by switching something off."
        case .reasoningStudios:
            return "Every studio's saved cases, matrices and registers are kept and reappear unchanged when it is back on."
        case .batesNumbering:
            return "Numbers already assigned are kept, and the sequence resumes where it left off."
        default:
            return "The surface is hidden. Work already saved is kept and returns unchanged when this is switched back on."
        }
    }

    /// Set for a capability that is risky enough to warrant a sentence before
    /// the user flips it, beyond the maturity label.
    var warning: String? {
        switch self {
        case .offsetParser:
            return "This replaces the import parser. It has not yet been run against a real archive — import a copy first, and check the receipt reconciles."
        case .locatorReads:
            return "Changes how attachment bytes are fetched. Verify an attachment opens and an export round-trips before relying on it."
        case .blobTier:
            return "Changes where large message bodies are written. Existing archives are not migrated or rewritten."
        case .externalStorage:
            return "An archive on an external disk is unreadable while that disk is detached. Never point this at a cloud-synced folder."
        default:
            return nil
        }
    }
}

// MARK: - Grouping for the matrix

extension Capability {
    /// Capabilities of one page, in declaration order (engines first, then
    /// surfaces) so the matrix reads from most to least consequential.
    static func all(for module: AppModule) -> [Capability] {
        allCases.filter { $0.owner == module }
    }

    /// Capabilities that would also switch off if this one did, because they
    /// declare it as a requirement. Shown in the confirmation so turning off
    /// one row never silently disables another.
    var dependents: [Capability] {
        Capability.allCases.filter { $0.requires.contains(self) }
    }
}
