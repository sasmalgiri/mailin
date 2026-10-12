@testable import ArchiveCore
//
//  EngineSpec.swift
//  maxmailin
//
//  Descriptions of the 3.0 replacement engines (SCALE_TODO_3_0.md §3-M).
//
//  Every engine rebuilt in 3.0 ships as its own capability next to the old
//  code path. This table is the single place that says, for each one: which
//  page owns it, what it does, what it needs, and how mature it is. The
//  `Capability` switches delegate here so adding an engine is one entry.
//
//  Requirements stay within one page (a page must work on its own): AI and
//  Professional engines never require an Archive-page engine — the scope job
//  runs regardless of its switch, and engines that read the analysis index
//  state its coverage.
//
//  All start as `.preview` (OFF): installing the build changes nothing until an
//  engine is promoted (plan §3-M5). Promotion is a deliberate edit of
//  `maturity` here, recorded in the plan.
//

import Foundation

struct EngineSpec: Sendable {
    let owner: AppModule
    let maturity: Capability.Maturity
    let requires: [Capability]
    let name: String
    let detail: String
    let warning: String?

    // M5 (owner, 2026-10-12): every 3.0 engine is promoted — on by default in
    // every build. Each stays a switch in the matrix (the previous engine one
    // switch away), and an engine the app stops inside still switches itself
    // off at the next launch (M2).
    init(_ owner: AppModule, requires: [Capability] = [], maturity: Capability.Maturity = .stable,
         name: String, detail: String, warning: String? = nil) {
        self.owner = owner
        self.maturity = maturity
        self.requires = requires
        self.name = name
        self.detail = detail
        self.warning = warning
    }

    /// The spec for a 3.0 engine, or `nil` for every capability that existed
    /// before 3.0.
    static func of(_ capability: Capability) -> EngineSpec? {
        switch capability {
        // MARK: Archive (Page 1)
        case .v3SafeHTML:
            return EngineSpec(.archive,
                name: String(localized: "Safe email display (3.0)"),
                detail: String(localized: "Shows HTML email in an isolated renderer with scripts off and all remote content blocked, so opening a message never contacts the sender and a large message cannot freeze the app."))
        case .v3SQLiteHygiene:
            return EngineSpec(.archive,
                name: String(localized: "Database safety settings (3.0)"),
                detail: String(localized: "Waits briefly instead of failing when the database is busy, flushes the drive cache at checkpoints on macOS, and on iPhone and iPad finishes database work before the system suspends the app."))
        case .v3Snapshots:
            return EngineSpec(.archive,
                name: String(localized: "Archive snapshots (3.0)"),
                detail: String(localized: "Keeps a verified copy of the archive database before every upgrade and on a schedule, so a damaged database can be restored."))
        case .v3ScopeEngine:
            return EngineSpec(.archive,
                name: String(localized: "Whole-archive job engine (3.0)"),
                detail: String(localized: "Runs actions over the whole archive in batches with progress, Cancel and resume after an interruption, using flat memory at any archive size."))
        case .v3FeatureIndex:
            return EngineSpec(.archive, requires: [.v3ScopeEngine],
                name: String(localized: "Per-email analysis index (3.0)"),
                detail: String(localized: "Analyses each email once and stores the results, so analysis tools answer from the index instantly for the whole archive."))
        case .v3Fingerprints:
            return EngineSpec(.archive, requires: [.v3ScopeEngine],
                name: String(localized: "Archive fingerprint tree (3.0)"),
                detail: String(localized: "Builds a fingerprint tree over every email so the whole archive can be verified in seconds and a changed email is pinpointed."))
        case .v3PagedLists:
            return EngineSpec(.archive,
                name: String(localized: "Complete lists (3.0)"),
                detail: String(localized: "Documents, workflow runs, search results, senders and tags load page by page with the total shown, instead of stopping at a fixed number. Large PST exports are split into parts each drive and Outlook accept."))
        case .v3SemanticSearch:
            return EngineSpec(.archive, requires: [.v3FeatureIndex],
                name: String(localized: "Meaning-based search (3.0)"),
                detail: String(localized: "Finds emails by meaning as well as by words, using on-device sentence embeddings."))
        case .v3Duplicates:
            return EngineSpec(.archive, requires: [.v3ScopeEngine],
                name: String(localized: "Whole-archive duplicate groups (3.0)"),
                detail: String(localized: "Lists exact-duplicate groups for the whole archive from the database, page by page."))

        case .v3SearchOperators:
            return EngineSpec(.archive,
                name: String(localized: "Search exclusions (3.0)"),
                detail: String(localized: "Search can exclude as well as include: put - or NOT before any filter (from:, to:, subject:, domain:, tag:, source:, type:, evidence:, filename:, before:, after:, has:attachment, is:pinned)."))

        // MARK: AI Insights (Page 2)
        case .v3AnalysisQueries:
            return EngineSpec(.aiInsights,
                name: String(localized: "Whole-archive analysis (3.0)"),
                detail: String(localized: "Dashboards, statistics, attachments, subjects and IT security figures computed for the whole archive from the analysis index."))
        case .v3AlertsAnomalies:
            return EngineSpec(.aiInsights,
                name: String(localized: "Whole-archive alerts & anomalies (3.0)"),
                detail: String(localized: "Smart alerts, anomaly detection and background findings over the whole archive."))
        case .v3PredictiveCoding:
            return EngineSpec(.aiInsights,
                name: String(localized: "Whole-archive predictive coding (3.0)"),
                detail: String(localized: "Trains on every email you have tagged and ranks the whole archive."))
        case .v3NearDuplicates:
            return EngineSpec(.aiInsights,
                name: String(localized: "Whole-archive near-duplicates (3.0)"),
                detail: String(localized: "Finds near-duplicate emails across the whole archive with recorded similarity thresholds; groups, never deletes."))
        case .v3TopicClusters:
            return EngineSpec(.aiInsights,
                name: String(localized: "Whole-archive topic clusters (3.0)"),
                detail: String(localized: "Groups the whole archive by topic."))
        case .v3Threads:
            return EngineSpec(.aiInsights,
                name: String(localized: "Complete thread summaries (3.0)"),
                detail: String(localized: "Summarises every message of a conversation, however long, in parts that fit the on-device model."))
        case .v3AIAnswers:
            return EngineSpec(.aiInsights,
                name: String(localized: "Whole-archive AI answers (3.0)"),
                detail: String(localized: "Counting questions are answered by code over the whole archive; written answers say how many emails they read."))
        case .v3Graphs:
            return EngineSpec(.aiInsights,
                name: String(localized: "Whole-archive graphs (3.0)"),
                detail: String(localized: "Relationship and knowledge graphs built from the whole archive, showing the top results with totals."))
        case .v3KeywordMonitor:
            return EngineSpec(.aiInsights,
                name: String(localized: "Whole-archive keyword sweep (3.0)"),
                detail: String(localized: "Sweeps the whole archive for your keywords using the search index."))

        // MARK: Professional (Page 3)
        case .v3LegalState:
            return EngineSpec(.professional,
                name: String(localized: "Legal data in the archive database (3.0)"),
                detail: String(localized: "Legal holds, evidence seals, custodians, custody events and review coding are stored in the archive database with fast bulk updates. The previous files are kept up to date too."),
                warning: String(localized: "Takes a snapshot first. The previous files stay as a second copy for the whole of 3.0, so switching this off loses nothing."))
        case .v3EDiscovery:
            return EngineSpec(.professional,
                name: String(localized: "Whole-archive eDiscovery (3.0)"),
                detail: String(localized: "Search, legal hold, collection verification, classification, review batches and production files cover the whole archive."))
        case .v3Bates:
            return EngineSpec(.professional,
                name: String(localized: "Whole-archive Bates numbering (3.0)"),
                detail: String(localized: "Numbers the whole scope in date order. Numbers already assigned are never changed."))
        case .v3ChainOfCustody:
            return EngineSpec(.professional,
                name: String(localized: "Whole-archive custody verification (3.0)"),
                detail: String(localized: "Verifies every email in scope against its stored seal."))
        case .v3Custodians:
            return EngineSpec(.professional,
                name: String(localized: "Whole-archive custodians & holds (3.0)"),
                detail: String(localized: "Assigns custodians, places holds and verifies seals across the whole scope."))
        case .v3ReviewBatches:
            return EngineSpec(.professional,
                name: String(localized: "Whole-archive review batches (3.0)"),
                detail: String(localized: "Builds review batches from every email in scope."))
        case .v3BatchOperations:
            return EngineSpec(.professional,
                name: String(localized: "Whole-scope batch tagging (3.0)"),
                detail: String(localized: "Applies tags and classifications to every email in scope in the database."))
        case .v3AutomationRules:
            return EngineSpec(.professional,
                name: String(localized: "Whole-archive automation rules (3.0)"),
                detail: String(localized: "Runs your rules over the whole scope, after showing how many emails they will touch."))
        case .v3PrivilegeScan:
            return EngineSpec(.professional,
                name: String(localized: "Whole-archive privilege scan (3.0)"),
                detail: String(localized: "Scans every email in scope for privilege indicators and stores the flags."))
        case .v3PIIReport:
            return EngineSpec(.professional,
                name: String(localized: "Whole-archive PII report (3.0)"),
                detail: String(localized: "Finds personal data across the whole scope, page by page."))
        case .v3IOC:
            return EngineSpec(.professional,
                name: String(localized: "Whole-archive indicator extraction (3.0)"),
                detail: String(localized: "Extracts links, addresses, IPs and hashes from every email in scope."))
        case .v3InvestigationReport:
            return EngineSpec(.professional,
                name: String(localized: "Whole-scope investigation report (3.0)"),
                detail: String(localized: "Builds the report sections from the whole scope rather than a loaded subset."))
        case .v3LegalReview:
            return EngineSpec(.professional,
                name: String(localized: "Whole-archive legal review statistics (3.0)"),
                detail: String(localized: "Review progress and statistics cover every email, not a loaded subset."))
        case .v3EvidenceDesks:
            return EngineSpec(.professional,
                name: String(localized: "Whole-archive evidence desks seeding (3.0)"),
                detail: String(localized: "Seeds source reliability from the whole scope with totals."))
        case .v3EvidenceReceipts:
            return EngineSpec(.professional,
                name: String(localized: "Provable job receipts (3.0)"),
                detail: String(localized: "Every whole-archive job records its scope, the archive revision and a fingerprint of exactly which emails it covered, so the result can be re-run and proven."))
        case .v3PreservationExport:
            return EngineSpec(.professional,
                name: String(localized: "Preservation package export (3.0)"),
                detail: String(localized: "Exports a BagIt package with PREMIS metadata — the archival standard — with the original emails, checksums and sidecar files."))
        default:
            return nil
        }
    }
}
