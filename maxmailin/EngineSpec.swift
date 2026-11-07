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

        // MARK: 3.1 — promoted (A4, owner 2026-10-15: "promote all"). Each is on by default and
        // stays a switch in the matrix with the earlier engine one switch away (rule 14).
        case .streamingBinaryParsers:
            // Five jobs OPEN-02. Gate passed 2026-11-05: a ~100 MB PST (2,000
            // messages) streamed in batches of 100 through the factory with
            // the process footprint growing by less than half the file, same
            // order as the array path (V2CutoverTests.testOPEN02_*). Promoted.
            return EngineSpec(.archive, requires: [.v3PSTSpecReader], maturity: .stable,
                name: String(localized: "Streaming PST and NSF import"),
                detail: String(localized: "Reads Outlook PST and OST files and Notes NSF databases message by message in batches, so memory follows the batch rather than the file. Off: every message in the file is read first, then stored."))
        case .selfContainedArchive:
            // Five jobs LIFE-01. Gate passed 2026-11-05: an import with the
            // switch on reads and digest-verifies its deferred message after
            // the original file is deleted; a tampered copy is discarded
            // (V2CutoverTests.testLIFE01_*). Promoted: on by default — the
            // archive should not depend on a file it does not own.
            return EngineSpec(.archive, maturity: .stable,
                name: String(localized: "Self-contained archive"),
                detail: String(localized: "Copies each imported mailbox file into the archive, checks the copy byte for byte, and imports from the copy — so the archive stays complete when the original file is moved, renamed or deleted. Uses as much extra space as the files themselves. Off: messages above the full-parse ceiling are read from the original file, which must stay where it was imported from."))
        case .searchQueryModel:
            // Five jobs FIND-04/07. Gate passed 2026-11-05: the acceptance
            // cases in V2CutoverTests.testFIND04_*/testFIND06_*/testFIND07_*
            // (groups and repeated fields, exclusion-only with unknowns,
            // same-attachment correlation, inclusive days in the displayed
            // zone, punctuation and SQL-looking input, a 5 MB body with a
            // phrase across a chunk boundary, scope outside OR/exclude).
            // Promoted: on by default; the previous search one switch away.
            return EngineSpec(.archive, maturity: .stable,
                name: String(localized: "Search model (whole text, no cutoffs)"),
                detail: String(localized: "Indexes every message body and attachment text in full, in chunks, inside the archive, and runs Advanced Search as one query: all / any / exclude groups, conditions that must hold for the same attachment, and an honest “may still match” count for mail whose text is not indexed yet. Off: the previous search, which indexes the first 4 MB of a body and the first 500,000 characters of an attachment."))
        case .v3PSTSpecReader:
            // Gate passed 2026-10-13: 15 public Outlook PSTs (Digital Corpora) read
            // with the same messages, Message-IDs, subjects and deleted-items
            // counts as libpst's readpst; the heuristic reader read 0–1 per file.
            return EngineSpec(.archive, maturity: .stable,
                name: String(localized: "Outlook PST reader (MS-PST)"),
                detail: String(localized: "Reads Outlook PST and OST files by Microsoft's published format: every folder, message, recipient and attachment, ANSI and Unicode files, all encodings. Off: the earlier reader, which reads mailin's own PST exports."))
        case .v3PSTSpecWriter:
            // B8: 1,000 emails written and read back exactly by mailin's MS-PST
            // reader, libpff and libpst; SCANPST finds nothing to repair and Outlook
            // opens the v9 export (owner, Windows, 2026-10-15; PST_EXPORT_VALIDATION.md).
            return EngineSpec(.archive, maturity: .stable,
                name: String(localized: "Outlook PST writer (MS-PST)"),
                detail: String(localized: "Writes PST exports in the layout Outlook writes: folders, recipients, attachments, HTML and long bodies. Off: the earlier writer, which mailin reads but Outlook may not open."))
        case .v31Recovery:
            return EngineSpec(.archive, maturity: .stable,
                name: String(localized: "Deleted-email recovery"),
                detail: String(localized: "Marks mail that was deleted but is still in the file — deleted folders, unpurged Thunderbird mail, Apple Mail deleted flags, PST orphans — and records how each was found."))
        case .v31DeepRecovery:
            return EngineSpec(.archive, requires: [.v31Recovery], maturity: .stable,
                name: String(localized: "Deep recovery and carving"),
                detail: String(localized: "Scans the unused space of PST files and any damaged file for messages that are no longer listed. Slow on large files; recovered messages are marked partial when incomplete."))
        case .v31ShortcutsActions:
            return EngineSpec(.archive, maturity: .stable,
                name: String(localized: "Shortcuts actions"),
                detail: String(localized: "Lets Shortcuts find emails and tag, hold, number, export and verify them — every action checks your role and is recorded."))
        case .v31Scripts:
            return EngineSpec(.professional, maturity: .stable,
                name: String(localized: "mailin Scripts"),
                detail: String(localized: "Runs your own JavaScript over the archive on this device, with no network access. Changes are shown before they apply and every run is recorded."))
        case .v31ReviewPack:
            // Archive page (free tier): a reviewer needs no licence to code a
            // pack they received. Sending packs and merging responses stay
            // Professional, checked where those actions are offered.
            return EngineSpec(.archive, maturity: .stable,
                name: String(localized: "Review Pack"),
                detail: String(localized: "Sends a set of emails to a reviewer who codes them in any copy of mailin, even the free one, and merges their decisions back with who decided what."))
        case .v31TeamCase:
            // Archive page like Review Pack: any reviewer can join a case;
            // starting a case and applying it to an archive need Professional.
            return EngineSpec(.archive, requires: [.v31ReviewPack], maturity: .stable,
                name: String(localized: "Team case on a shared folder"),
                detail: String(localized: "Several reviewers work on one case kept on a shared drive, with signed logs, batches, a conflict list and quality control. No server needed."))
        case .v31ForensicTimestamps:
            return EngineSpec(.professional, maturity: .stable,
                name: String(localized: "Hidden timestamps and signature checks"),
                detail: String(localized: "Decodes timestamps hidden in Message-IDs, MIME boundaries and Thread-Index, and flags messages that should carry a DKIM signature but do not."))
        // MARK: 3.0.x — Phase E (owner 2026-10-15), promoted the same day ("switch on what we just built")
        case .devonthinkHandOff:
            // E2: work alongside DEVONthink. Exports .eml through the normal export run, then hands
            // the files to DEVONthink; mailin://email/<id> links open an email from any app.
            return EngineSpec(.archive, maturity: .stable,
                name: String(localized: "Send to DEVONthink and email links"),
                detail: String(localized: "Sends emails to DEVONthink as standard .eml files, and copies links that open an email in mailin from DEVONthink or any notes app. Nothing leaves this Mac."))
        case .attachmentOCR:
            // E1: Apple Vision text recognition on scanned PDFs and images, on the device.
            return EngineSpec(.archive, maturity: .stable,
                name: String(localized: "Text in scanned attachments (OCR)"),
                detail: String(localized: "Reads the text in scanned PDFs and photos attached to emails, on this device, so attachment search finds it. No network."))
        case .attachmentSpeech:
            // TYPE-05: Apple Speech on-device recognition for audio and video attachments.
            return EngineSpec(.archive, maturity: .stable,
                name: String(localized: "Speech in audio and video attachments"),
                detail: String(localized: "Recognises the words spoken in voice memos, calls and videos attached to emails, on this device, so search finds them and says \"Recognised speech\". Asks once for permission. No network."))
        case .notesODSReader:
            // GAP-NSF: 45 of 45 mail notes of the public SampleNSF.nsf read and checked against the
            // raw file; preview until the owner's own Notes database has been run through it.
            return EngineSpec(.archive, maturity: .preview,
                name: String(localized: "Lotus Notes reader (ODS)"),
                detail: String(localized: "Reads Notes mail databases (.nsf) by their on-disk layout: every mail note with its headers, body and attachments, design notes and deletion stubs counted out. Not yet read: folder membership, compressed attachment objects and encrypted items. Off: the earlier reader, which reads only mailin's own test files."))
        case .protectedMessageDecrypt:
            // §13.8 step 5: CMSDecoder with the keychain's identities; preview until a real identity has run it.
            return EngineSpec(.archive, maturity: .preview,
                name: String(localized: "Read S/MIME with your keychain key"),
                detail: String(localized: "Decrypts S/MIME-protected parts with a private key already in this Mac's keychain, then reads the message inside for search. Off, they are recorded as locked. Nothing leaves this Mac; no key is copied."))
        default:
            return nil
        }
    }
}
