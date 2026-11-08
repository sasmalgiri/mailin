//
//  ExportReconciliation.swift
//  ArchiveCore
//
//  Five jobs OUT-04 (COMP-16; strengthened 2026-11-07, completion directive §2):
//  "the export is verified" meant, until now, that the bytes on disk are the
//  bytes that were written (`ExportInventory.verify`). This goes one step
//  further and asks whether what was written still SAYS what the archive
//  says: every output the inventory ties to a message is parsed back with the
//  same readers an import would use and compared, field by field, with the
//  archive's record.
//
//  Rules this file holds (each has a test in ExportReconciliationTests):
//
//  1. Attachments are compared as OCCURRENCES — name, SHA-256 of the bytes,
//     byte count, Content-ID and disposition — never as a set of hashes.
//     Bytes that cannot be read on either side make the item `unverifiable`;
//     they never disappear from the comparison.
//  2. Every field the field contract (FIELD_CONTRACT.md) promises for a
//     message is checked, including presence and absence. Each field ends in
//     one of: unchanged, sourceAbsent, permittedTransformation (named),
//     lost (named), unverifiable (named).
//  3. Normalisation is per field and documented in `Normalization`. Subject
//     keeps its case; bodies keep their representation (plain and HTML are
//     compared separately); dates are compared at the precision both sides
//     carry, and a comparison that had to drop precision is NAMED, never
//     reported as "unchanged".
//  4. A header-only record (a located message whose bytes stayed in the
//     source) is hydrated through the caller's `hydrate` closure when there
//     is one; otherwise its body and attachments are `unverifiable`. Full
//     content equality is never inferred from headers.
//  5. The report has an explicit `Outcome` (complete / partial / failed /
//     unavailable) and full denominators. Files without a record and parse
//     failures count against completeness. No path returns nil for "nothing
//     could be checked" — it returns `.unavailable` with the reason.
//  6. mbox and PST outputs are parsed back with the bounded streaming readers
//     and reconciled per message (selection, content, folder where the format
//     carries it). The byte-integrity statement (`ExportInventory.verify`)
//     stays a separate statement; nothing here re-hashes files.
//  7. Streaming: outputs arrive as a sequence, source records are looked up
//     in pages of at most `pageSize` (≤ 500) through the caller's closure.
//     Nothing here asks for a dictionary of the whole archive.
//
//  Content, not bytes: an .eml re-rendered from a PST message has different
//  bytes from the source but the same content; that is a match here and a
//  difference for the byte inventory — the two statements stay apart.
//

import Foundation
import CryptoKit

enum ExportReconciliation {

    // MARK: - Fields and their normalisation

    /// The fields FIELD_CONTRACT.md promises for a message and that an
    /// .eml / .msg / mbox / PST output is expected to carry.
    enum Field: String, CaseIterable, Sendable, Codable {
        case subject
        case from
        case to
        case cc
        case bcc
        case date
        case messageID = "message-id"
        case inReplyTo = "in-reply-to"
        case references
        case plainBody = "body"
        case htmlBody = "html body"
        case attachments
        case attachmentContentIDs = "attachment content-ids"
        case attachmentDispositions = "attachment dispositions"
        case folder

        var normalization: Normalization {
            switch self {
            case .subject: return .headerText
            case .from, .to, .cc, .bcc: return .addressList
            case .messageID, .inReplyTo: return .identifier
            case .references: return .identifierList
            case .date: return .instant
            case .plainBody, .htmlBody: return .text
            case .attachments: return .attachmentOccurrences
            case .attachmentContentIDs: return .identifier
            case .attachmentDispositions: return .exact
            case .folder: return .exact
            }
        }
    }

    /// What counts as "the same value" for a field. Every rule here is the
    /// WHOLE of what the comparison forgives; anything else is a difference.
    enum Normalization: String, Sendable, Codable {
        /// Header text: folded lines unfolded (CRLF + leading whitespace → one
        /// space), surrounding whitespace trimmed. Case and inner spacing kept.
        case headerText
        /// First the header strings as `headerText`; if they differ, the
        /// addresses alone (display names dropped, lower-cased, order
        /// ignored, count kept). Equal addresses under different presentation
        /// is reported as a NAMED transformation, not as unchanged.
        case addressList
        /// Angle brackets and surrounding whitespace trimmed; case kept.
        case identifier
        /// A whitespace-separated list of `identifier`s, order kept.
        case identifierList
        /// Parsed to an instant (RFC 2822 or ISO 8601) and compared at the
        /// finest precision BOTH sides carry: the second when both strings
        /// have seconds, otherwise the minute — and that drop is named in the
        /// result. The zone offset is not compared (same instant, re-expressed).
        case instant
        /// Body text: CRLF → LF, trailing whitespace on each line and trailing
        /// blank lines dropped. Case, inner spacing and representation (plain
        /// vs HTML) kept — plain and HTML are compared separately.
        case text
        /// Per occurrence: file name (trimmed), SHA-256 of the bytes, byte
        /// count, Content-ID (`identifier`) and disposition (inline or not).
        /// Multiplicity matters: A/A/B and A/B/B differ.
        case attachmentOccurrences
        /// Exact string equality after trimming surrounding whitespace.
        case exact
    }

    /// The result for one field of one message.
    enum FieldOutcome: Sendable, Equatable, Codable {
        /// Equal under the field's normalisation, nothing dropped.
        case unchanged
        /// The record had no value and the output has none either.
        case sourceAbsent
        /// Equal in substance after a NAMED transformation the format or
        /// writer imposes, or a NAMED loss of precision in the comparison.
        case permittedTransformation(String)
        /// The record had a value the output does not carry, or the values differ.
        case lost(String)
        /// Could not be compared, with the reason (bytes unavailable, record
        /// header-only and not hydrated, …). Never counts as a match.
        case unverifiable(String)

        var isLost: Bool { if case .lost = self { return true } else { return false } }
        var isUnverifiable: Bool { if case .unverifiable = self { return true } else { return false } }
        var transformation: String? { if case .permittedTransformation(let s) = self { return s } else { return nil } }
    }

    struct FieldResult: Sendable, Equatable, Codable {
        let field: Field
        let outcome: FieldOutcome
        var normalization: Normalization { field.normalization }
    }

    // MARK: - Output kinds and what each format can carry

    enum OutputKind: Sendable, Equatable, Codable {
        case eml, msg, mbox, pst
        case other(String)

        static func of(url: URL) -> OutputKind {
            switch url.pathExtension.lowercased() {
            case "eml": return .eml
            case "msg": return .msg
            case "mbox", "mbx": return .mbox
            case "pst": return .pst
            case let ext: return .other(ext)
            }
        }

        var isContainer: Bool { self == .mbox || self == .pst }
        var isPerMessageFile: Bool { self == .eml || self == .msg }
        var label: String {
            switch self {
            case .eml: return ".eml"
            case .msg: return ".msg"
            case .mbox: return "mbox"
            case .pst: return "PST"
            case .other(let ext): return ext.isEmpty ? "file" : ".\(ext)"
            }
        }
    }

    /// What the writer of each format is KNOWN not to carry. A field listed
    /// here that the record had and the output lacks is a named permitted
    /// transformation; anything not listed that goes missing is `lost`.
    struct FormatRules: Sendable {
        let kind: OutputKind
        /// Per field: the reason it is not carried, when it is not.
        let notCarried: [Field: String]

        static func rules(for kind: OutputKind) -> FormatRules {
            switch kind {
            case .eml:
                return FormatRules(kind: kind, notCarried: [:])
            case .msg:
                return FormatRules(kind: kind, notCarried: [
                    .attachmentContentIDs: "the .msg writer does not carry attachment Content-IDs",
                    .attachmentDispositions: "the .msg writer does not carry the inline disposition",
                ])
            case .mbox:
                return FormatRules(kind: kind, notCarried: [
                    .folder: "mbox carries no folder path",
                ])
            case .pst:
                return FormatRules(kind: kind, notCarried: [
                    .folder: "the PST export writes every message into its export folder; the source folder path is not carried",
                ])
            case .other:
                return FormatRules(kind: kind, notCarried: [:])
            }
        }
    }

    // MARK: - Report model

    /// One output message's result. Only non-matching items are retained in
    /// the report (`findings`); matching ones are counted.
    struct Item: Sendable, Equatable, Codable {
        enum Status: String, Sendable, Codable {
            case matching, mismatched, unverifiable, withoutRecord, unparsed
            /// R3: an occurrence the container's manifest expects that the output does not hold.
            case missing
            /// R3: an output message no expected occurrence accounts for (a second copy, an unselected record, …).
            case extra
        }
        /// The output file's path relative to the export folder; for a
        /// container (mbox / PST) the message's ordinal is appended as `#n`.
        let path: String
        let emailID: UUID?
        let messageID: String?
        let status: Status
        /// Why the item is `withoutRecord` or `unparsed`.
        let reason: String?
        /// Per-field results (empty for `withoutRecord` / `unparsed`).
        let fields: [FieldResult]

        var lostFields: [Field] { fields.filter { $0.outcome.isLost }.map(\.field) }
        var unverifiableFields: [Field] { fields.filter { $0.outcome.isUnverifiable }.map(\.field) }
        var transformations: [String] { fields.compactMap { $0.outcome.transformation } }

        /// Which fields differ, in the words the receipt uses ("subject", "body", …).
        var differences: [String] {
            fields.compactMap { result -> String? in
                switch result.outcome {
                case .lost(let detail): return detail.isEmpty ? result.field.rawValue : "\(result.field.rawValue): \(detail)"
                case .unverifiable(let why): return "\(result.field.rawValue) not verifiable: \(why)"
                default: return nil
                }
            }
        }
    }

    struct ContentReport: Sendable, Equatable, Codable {
        enum Outcome: String, Sendable, Codable {
            /// Every eligible output was parsed, tied to its record and matched.
            case complete
            /// The run did not reach the end (cancelled, or a reader failed
            /// mid-way), or some outputs could not be verified. The counts are
            /// what was established so far; nothing is inferred for the rest.
            case partial
            /// Every eligible output was reached and at least one does not
            /// say what the archive says, has no record, or could not be parsed.
            case failed
            /// Nothing could be checked (no inventory, no per-message outputs,
            /// an output kind this check does not parse). `reason` says why.
            case unavailable
        }

        var outcome: Outcome = .unavailable
        /// Why the outcome is not `complete`.
        var reason: String? = nil

        // Denominators (per output MESSAGE: one per .eml/.msg file, one per
        // record inside an mbox or PST).
        /// Output messages that should be checked: every per-message file the
        /// inventory lists plus every record read from a container.
        var eligible = 0
        /// Parsed and tied to a record, so a comparison ran.
        var checked = 0
        var matching = 0
        var mismatched = 0
        var unverifiable = 0
        var withoutRecord = 0
        var unparsed = 0

        // File-level counts (what the inventory listed).
        var listedFiles = 0
        /// Files of a kind this check parses (.eml, .msg, mbox, PST).
        var eligibleFiles = 0
        /// Eligible files that were opened before the run ended.
        var filesReached = 0
        /// Inventory files of a kind this check does not parse (reports, CSV, attachments).
        var notApplicable = 0

        /// What the export promised to write (inventory `written`, or the
        /// caller's count for a single-file export) against the output
        /// messages actually found. A shortfall is named in `reason`.
        var promised: Int? = nil

        /// Named transformations seen, with how many items each applied to
        /// (e.g. "date compared to the minute because the output carries no seconds": 12).
        var transformations: [String: Int] = [:]

        /// Header-only (located) records whose content was fetched for the
        /// comparison — through the caller's `hydrate` closure or the
        /// hydrator's locator route. The rest of such records are `unverifiable`.
        var hydrated = 0

        /// Non-matching items only (mismatched, unverifiable, withoutRecord, unparsed, missing, extra).
        var findings: [Item] = []

        /// R3: the one-to-one selection check of container outputs (mbox,
        /// PST). Nil when the run reached no container. Optional so reports
        /// saved before it existed still decode.
        var selection: SelectionCheck? = nil

        var mismatches: [Item] { findings.filter { $0.status == .mismatched } }
        var isComplete: Bool { outcome == .complete }

        /// Plain English summary (the app localises its own receipt line).
        var summary: String {
            var line: String
            switch outcome {
            case .complete: line = "content checked: \(matching) of \(eligible) say what the archive says"
            case .partial: line = "content check incomplete: \(matching) of \(eligible) reached say what the archive says"
            case .failed: line = "content check failed: \(matching) of \(eligible) say what the archive says"
            case .unavailable: line = "content not checked"
            }
            if let reason, !reason.isEmpty { line += " — \(reason)" }
            if mismatched > 0 { line += " · differ \(mismatched)" }
            if unverifiable > 0 { line += " · not verifiable \(unverifiable)" }
            if withoutRecord > 0 { line += " · no record \(withoutRecord)" }
            if unparsed > 0 { line += " · unparsable \(unparsed)" }
            if hydrated > 0 { line += " · \(hydrated) located record(s) read from their source bytes" }
            if let selection {
                if selection.missing > 0 { line += " · missing \(selection.missing)" }
                if selection.extra > 0 { line += " · extra \(selection.extra)" }
            }
            if !transformations.isEmpty {
                line += " · " + transformations.sorted { $0.key < $1.key }.map { "\($0.key) (\($0.value))" }.joined(separator: "; ")
            }
            return line
        }
    }

    /// R3: how container outputs were tied to the export's selection.
    struct SelectionCheck: Sendable, Equatable, Codable {
        /// Containers checked one-to-one against the manifest their export wrote.
        var manifests = 0
        /// Containers without a manifest (written before manifests existed):
        /// tied to records by Message-ID only, which cannot prove one-to-one.
        var withoutManifest = 0
        /// Manifests without an end mark (the export did not finish).
        var unfinishedManifests = 0
        /// Expected occurrences the manifests list.
        var expected = 0
        /// Expected occurrences paired to exactly one output message.
        var paired = 0
        /// Of those, paired after the first pass (out of order, or by Message-ID / place hint).
        var pairedOutOfOrder = 0
        /// Expected occurrences no output message accounts for.
        var missing = 0
        /// Output messages no expected occurrence accounts for.
        var extra = 0
    }

    // MARK: - Inputs

    /// One output to check: a per-message file or a container.
    struct OutputRecord: Sendable {
        let url: URL
        /// Path as the receipt names it (relative to the export folder).
        let path: String
        let kind: OutputKind
        /// The record the inventory tied this file to (per-message files).
        let emailID: UUID?
        /// The folder path the layout recorded for this file (OUT-03), when it did.
        let originalFolder: String?
        /// R3 (iOS hand-off): the container's manifest where the receipt kept
        /// it, when the file was written inside the app and handed on alone.
        /// Tried before the sidecar beside the file; nil = the sidecar only.
        let manifestURL: URL?

        init(url: URL, path: String? = nil, kind: OutputKind? = nil, emailID: UUID? = nil, originalFolder: String? = nil,
             manifestURL: URL? = nil) {
            self.url = url
            self.path = path ?? url.lastPathComponent
            self.kind = kind ?? OutputKind.of(url: url)
            self.emailID = emailID
            self.originalFolder = originalFolder
            self.manifestURL = manifestURL
        }
    }

    /// How the archive's records are reached — one page at a time.
    struct SourceLookup: Sendable {
        /// Full records for up to `pageSize` IDs. Missing IDs are simply absent.
        var records: @Sendable ([UUID]) async throws -> [UUID: MBOXParser.RawEmail]
        /// Records by Message-ID, for container outputs (mbox, PST) whose
        /// messages carry no archive ID. Nil: container messages are
        /// `withoutRecord` with that reason.
        var recordsByMessageID: (@Sendable ([String]) async throws -> [String: MBOXParser.RawEmail])? = nil
        /// Full content for a header-only record (a located message). Nil, or
        /// a nil return: the body and attachments of that message are `unverifiable`.
        var hydrate: (@Sendable (UUID) async throws -> MBOXParser.RawEmail?)? = nil

        init(records: @escaping @Sendable ([UUID]) async throws -> [UUID: MBOXParser.RawEmail],
             recordsByMessageID: (@Sendable ([String]) async throws -> [String: MBOXParser.RawEmail])? = nil,
             hydrate: (@Sendable (UUID) async throws -> MBOXParser.RawEmail?)? = nil) {
            self.records = records
            self.recordsByMessageID = recordsByMessageID
            self.hydrate = hydrate
        }
    }

    /// The largest page of source records asked for at once.
    static let maxPageSize = 500

    // MARK: - Entry points

    /// Every output the folder's inventory lists, checked against the archive.
    /// Never throws: a folder without a readable inventory is `.unavailable`.
    static func reconcile(folder: URL, lookup: SourceLookup, pageSize: Int = maxPageSize) async -> ContentReport {
        let inventory: ExportInventory
        do { inventory = try ExportInventory.load(folder: folder) } catch {
            var report = ContentReport()
            report.outcome = .unavailable
            report.reason = "no export inventory could be read: \(error.localizedDescription)"
            return report
        }
        let files = inventory.files
        let stream = AsyncStream<OutputRecord> { continuation in
            for file in files {
                let url = folder.appendingPathComponent(file.path)
                continuation.yield(OutputRecord(url: url, path: file.path, kind: OutputKind.of(url: url),
                                                emailID: file.emailID.flatMap(UUID.init(uuidString:)),
                                                originalFolder: file.originalFolder))
            }
            continuation.finish()
        }
        // The inventory is known whole, so the denominators are fixed up front:
        // an interrupted run still says "n of ALL files reached".
        let eligibleFiles = files.filter { file -> Bool in
            let kind = OutputKind.of(url: URL(fileURLWithPath: file.path))
            return kind.isPerMessageFile || kind.isContainer
        }.count
        return await reconcile(outputs: stream, lookup: lookup, pageSize: pageSize, promised: inventory.written,
                               knownFiles: (listed: files.count, eligible: eligibleFiles))
    }

    /// A single output file (an mbox or PST written without a folder, or one
    /// .eml / .msg). `promised` is what the export said it wrote. `manifest`:
    /// where the receipt kept the container's manifest (iOS hand-off), tried
    /// before the sidecar beside the file.
    static func reconcile(file: URL, emailID: UUID? = nil, promised: Int? = nil, manifest: URL? = nil,
                          lookup: SourceLookup, pageSize: Int = maxPageSize) async -> ContentReport {
        let record = OutputRecord(url: file, path: file.lastPathComponent, emailID: emailID, manifestURL: manifest)
        let stream = AsyncStream<OutputRecord> { $0.yield(record); $0.finish() }
        return await reconcile(outputs: stream, lookup: lookup, pageSize: pageSize, promised: promised)
    }

    /// The streaming core. Outputs are consumed one at a time; per-message
    /// files are gathered into pages of at most `pageSize` before their
    /// records are looked up; containers are read in batches of `pageSize`.
    /// Cancellation ends the run with `.partial` and the counts so far.
    /// - Parameter knownFiles: when the caller knows the whole list (an
    ///   inventory), the file denominators are fixed from it instead of being
    ///   counted as outputs arrive.
    static func reconcile<S: AsyncSequence>(outputs: S, lookup: SourceLookup,
                                            pageSize: Int = maxPageSize, promised: Int? = nil,
                                            knownFiles: (listed: Int, eligible: Int)? = nil) async -> ContentReport
    where S.Element == OutputRecord {
        let page = max(1, min(pageSize, maxPageSize))
        var state = RunState(report: ContentReport(), lookup: lookup, pageSize: page)
        state.report.promised = promised
        if let knownFiles {
            state.report.listedFiles = knownFiles.listed
            state.report.eligibleFiles = knownFiles.eligible
        }
        var pending: [OutputRecord] = []
        var stoppedEarly: String? = nil
        var failure: String? = nil

        do {
            for try await output in outputs {
                if knownFiles == nil { state.report.listedFiles += 1 }
                if Task.isCancelled { throw CancellationError() }
                switch output.kind {
                case .eml, .msg:
                    if knownFiles == nil { state.report.eligibleFiles += 1 }
                    pending.append(output)
                    if pending.count >= page {
                        try await state.flush(&pending)
                    }
                case .mbox, .pst:
                    if knownFiles == nil { state.report.eligibleFiles += 1 }
                    try await state.flush(&pending)
                    try await state.reconcileContainer(output)
                case .other:
                    state.report.notApplicable += 1
                }
            }
            try await state.flush(&pending)
        } catch is CancellationError {
            stoppedEarly = "verification was stopped before the end (cancelled)"
        } catch {
            failure = "verification stopped: \(error.localizedDescription)"
        }
        // Files handed to a page but never opened still count as eligible outputs.
        for output in pending where output.kind.isPerMessageFile {
            state.report.eligible += 1
            state.note(Item(path: output.path, emailID: output.emailID, messageID: nil, status: .unverifiable,
                            reason: "not reached before the run ended", fields: []))
        }
        var report = state.report
        report.outcome = outcome(for: report, stoppedEarly: stoppedEarly, failure: failure)
        report.reason = reason(for: report, stoppedEarly: stoppedEarly, failure: failure)
        return report
    }

    // MARK: - Outcome

    private static func outcome(for r: ContentReport, stoppedEarly: String?, failure: String?) -> ContentReport.Outcome {
        if failure != nil { return r.eligible == 0 && r.eligibleFiles == 0 ? .unavailable : .partial }
        if stoppedEarly != nil { return .partial }
        if r.eligibleFiles == 0 { return .unavailable }
        if r.mismatched > 0 || r.withoutRecord > 0 || r.unparsed > 0 { return .failed }
        // R3: a missing or extra occurrence, or a count that is not exactly
        // the promise in EITHER direction, is a failure, never complete.
        if let s = r.selection, s.missing > 0 || s.extra > 0 { return .failed }
        if let promised = r.promised, promised != r.eligible { return .failed }
        if r.unverifiable > 0 { return .partial }
        if r.eligible == 0 { return .unavailable }
        return .complete
    }

    private static func reason(for r: ContentReport, stoppedEarly: String?, failure: String?) -> String? {
        var parts: [String] = []
        if let failure { parts.append(failure) }
        if let stoppedEarly { parts.append(stoppedEarly) }
        if stoppedEarly != nil || failure != nil {
            parts.append("\(r.filesReached) of \(r.eligibleFiles) files reached")
        } else if r.eligibleFiles == 0 {
            parts.append(r.listedFiles == 0 ? "the inventory lists no files" : "none of the \(r.listedFiles) listed files is a message output this check parses")
        } else if r.eligible == 0 {
            parts.append("no message could be read from the \(r.eligibleFiles) message file(s)")
        }
        if let promised = r.promised, stoppedEarly == nil, failure == nil, promised != r.eligible {
            parts.append(promised > r.eligible ? "the export promised \(promised) messages, \(r.eligible) found"
                                                : "\(r.eligible) messages found, the export promised \(promised)")
        }
        if let s = r.selection {
            if s.missing > 0 {
                let named = r.findings.filter { $0.status == .missing }.prefix(3).map { $0.emailID?.uuidString ?? $0.messageID ?? $0.path }
                parts.append("\(s.missing) selected record(s) missing from the output (\(named.joined(separator: ", "))\(s.missing > 3 ? ", …" : ""))")
            }
            if s.extra > 0 { parts.append("\(s.extra) output message(s) not in the export's selection or written twice") }
            if s.unfinishedManifests > 0 { parts.append("\(s.unfinishedManifests) manifest(s) have no end mark: the export did not finish") }
            if s.withoutManifest > 0 { parts.append("no manifest — checked by Message-ID only") }
        }
        if r.withoutRecord > 0 { parts.append("\(r.withoutRecord) output(s) have no archive record to compare with") }
        if r.unparsed > 0 { parts.append("\(r.unparsed) output(s) could not be parsed back") }
        if r.unverifiable > 0, r.mismatched == 0 { parts.append("\(r.unverifiable) output(s) could not be fully verified") }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    // MARK: - Run state (one reconciliation)

    private struct RunState {
        var report: ContentReport
        let lookup: SourceLookup
        let pageSize: Int

        init(report: ContentReport, lookup: SourceLookup, pageSize: Int) {
            self.report = report; self.lookup = lookup; self.pageSize = pageSize
        }

        mutating func note(_ item: Item) {
            // A comparison ran when there are field results (parsed AND tied to a record).
            ExportReconciliation.tally(item, into: &report)
        }

        /// Per-message files: one lookup for the page, then each file in turn.
        mutating func flush(_ pending: inout [OutputRecord]) async throws {
            guard !pending.isEmpty else { return }
            let outputs = pending
            let ids = outputs.compactMap(\.emailID)
            // `pending` keeps the page until its records are in hand, so a
            // lookup that fails or is cancelled leaves the files counted as
            // "not reached" rather than dropped from the denominator.
            let sources = ids.isEmpty ? [:] : try await lookup.records(ids)
            pending.removeAll()
            for output in outputs {
                if Task.isCancelled { pending.append(output); continue }
                report.filesReached += 1
                report.eligible += 1
                guard let id = output.emailID else {
                    note(Item(path: output.path, emailID: nil, messageID: nil, status: .withoutRecord,
                              reason: "the inventory lists no record for this file", fields: [])); continue
                }
                guard var source = sources[id] else {
                    note(Item(path: output.path, emailID: id, messageID: nil, status: .withoutRecord,
                              reason: "record \(id.uuidString) is not in the archive", fields: [])); continue
                }
                let parsed: MBOXParser.RawEmail
                do { parsed = try ExportReconciliation.parseOutput(url: output.url, kind: output.kind) } catch {
                    note(Item(path: output.path, emailID: id, messageID: source.headers["Message-ID"], status: .unparsed,
                              reason: error.localizedDescription, fields: [])); continue
                }
                defer { ExportReconciliation.removeScratch(of: parsed) }
                let hydrated = try await hydrateIfHeaderOnly(&source)
                let fields = ExportReconciliation.compare(output: parsed, source: source,
                                                          rules: FormatRules.rules(for: output.kind),
                                                          outputFolder: output.originalFolder, sourceHydrated: hydrated)
                note(ExportReconciliation.item(path: output.path, emailID: id, messageID: source.headers["Message-ID"], fields: fields))
            }
            if Task.isCancelled { throw CancellationError() }
        }

        /// mbox / PST. With the manifest the export wrote beside the file
        /// (R3), every output message is tied one-to-one to an expected
        /// occurrence and compared with the record it names, looked up by ID.
        /// Without one (an export from before manifests), each message is
        /// tied by Message-ID — which cannot prove one-to-one, and says so.
        /// Either way counts are accumulated batch by batch; only
        /// non-matching items are retained.
        mutating func reconcileContainer(_ output: OutputRecord) async throws {
            report.filesReached += 1
            let kept = output.manifestURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            let manifestURL = kept ?? ContainerManifest.url(for: output.url)
            if FileManager.default.fileExists(atPath: manifestURL.path),
               let scan = try? ContainerManifest.scan(url: manifestURL), scan.header?.version == ContainerManifest.version {
                let before = report.eligible
                do {
                    try await ExportReconciliation.reconcileWithManifest(output, manifestURL: manifestURL, scan: scan,
                                                                         lookup: lookup, pageSize: pageSize, report: &report)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try containerReadFailed(output, error: error, readAny: report.eligible > before)
                }
                return
            }
            report.selection = report.selection ?? SelectionCheck()
            report.selection?.withoutManifest += 1
            var ordinal = 0
            let lookup = self.lookup
            let kind = output.kind
            let path = output.path
            var local = report
            var readAny = false
            do {
                try await ExportReconciliation.readContainer(output.url, kind: kind, batchSize: pageSize) { batch in
                    readAny = true
                    let mids = batch.compactMap { ExportReconciliation.header("Message-ID", $0.headers).map(ExportReconciliation.identifier) }.filter { !$0.isEmpty }
                    var sources: [String: MBOXParser.RawEmail] = [:]
                    if let byMID = lookup.recordsByMessageID, !mids.isEmpty {
                        for (key, value) in try await byMID(mids) { sources[ExportReconciliation.identifier(key)] = value }
                    }
                    for parsed in batch {
                        ordinal += 1
                        local.eligible += 1
                        let itemPath = "\(path)#\(ordinal)"
                        let mid = ExportReconciliation.header("Message-ID", parsed.headers).map(ExportReconciliation.identifier)
                        guard let mid, !mid.isEmpty else {
                            ExportReconciliation.tally(Item(path: itemPath, emailID: nil, messageID: nil, status: .withoutRecord,
                                                            reason: "the message carries no Message-ID to tie it to a record", fields: []), into: &local); continue
                        }
                        guard lookup.recordsByMessageID != nil else {
                            ExportReconciliation.tally(Item(path: itemPath, emailID: nil, messageID: mid, status: .withoutRecord,
                                                            reason: "no Message-ID lookup was supplied for \(kind.label) output", fields: []), into: &local); continue
                        }
                        guard var source = sources[mid] else {
                            ExportReconciliation.tally(Item(path: itemPath, emailID: nil, messageID: mid, status: .withoutRecord,
                                                            reason: "no record with Message-ID \(mid) is in the archive", fields: []), into: &local); continue
                        }
                        var hydrated = false
                        if ExportReconciliation.isHeaderOnly(source) {
                            if let hydrate = lookup.hydrate, let full = try await hydrate(source.id), !ExportReconciliation.isHeaderOnly(full) {
                                source = full; hydrated = true
                            } else if let full = ExportReconciliation.hydrateFromLocatedSource(source) {
                                source = full; hydrated = true
                            }
                            if hydrated { local.hydrated += 1 }
                        }
                        let fields = ExportReconciliation.compare(output: parsed, source: source, rules: FormatRules.rules(for: kind),
                                                                  outputFolder: parsed.folderPath, sourceHydrated: hydrated)
                        ExportReconciliation.tally(ExportReconciliation.item(path: itemPath, emailID: source.id, messageID: mid, fields: fields), into: &local)
                    }
                }
            } catch is CancellationError {
                report = local
                throw CancellationError()
            } catch {
                report = local
                try containerReadFailed(output, error: error, readAny: readAny)
                return
            }
            report = local
        }

        /// A container that failed to read at all is one unparsed output;
        /// one that failed mid-way keeps what was read and is named.
        mutating func containerReadFailed(_ output: OutputRecord, error: Error, readAny: Bool) throws {
            if readAny { throw error }
            report.eligible += 1
            note(Item(path: output.path, emailID: nil, messageID: nil, status: .unparsed,
                      reason: "\(output.kind.label) could not be read: \(error.localizedDescription)", fields: []))
        }

        /// A located, header-only record is completed through the caller's
        /// closure when one is given, else through the hydrator's locator
        /// route. Returns whether it was.
        mutating func hydrateIfHeaderOnly(_ source: inout MBOXParser.RawEmail) async throws -> Bool {
            guard ExportReconciliation.isHeaderOnly(source) else { return false }
            if let hydrate = lookup.hydrate, let full = try await hydrate(source.id), !ExportReconciliation.isHeaderOnly(full) {
                source = full
                report.hydrated += 1
                return true
            }
            if let full = ExportReconciliation.hydrateFromLocatedSource(source) {
                source = full
                report.hydrated += 1
                return true
            }
            return false
        }
    }

    // MARK: - Parsing outputs

    struct ParseFailure: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// The output re-read with the reader an import would use.
    static func parseOutput(url: URL, kind: OutputKind) throws -> MBOXParser.RawEmail {
        let data = try Data(contentsOf: url)
        switch kind {
        case .msg:
            return try MSGParser.parse(data: data)
        case .eml:
            guard let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                throw ParseFailure(reason: "text encoding not recognised")
            }
            guard looksLikeMessage(raw) else { throw ParseFailure(reason: "the file has no message header block") }
            return try MBOXParser.processRawMessage(raw, senderEmail: "")
        default:
            throw ParseFailure(reason: "\(kind.label) is a container, not a single message")
        }
    }

    /// An .eml must start with header lines (`Name: value`, or an mbox
    /// envelope); arbitrary bytes are a parse failure, not an empty message.
    static func looksLikeMessage(_ raw: String) -> Bool {
        var firstLine = ""
        for line in raw.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false) { firstLine = String(line); break }
        if firstLine.hasPrefix("From ") { return true }
        guard let colon = firstLine.firstIndex(of: ":") else { return false }
        let name = firstLine[..<colon]
        return !name.isEmpty && name.allSatisfy { $0.isASCII && !$0.isWhitespace && $0 != ":" }
    }

    static func removeScratch(of email: MBOXParser.RawEmail) {
        for a in email.attachments { if let u = a.fileURL { try? FileManager.default.removeItem(at: u) } }
    }

    /// A record kept header-only (a located message): no raw source and no
    /// body text at all. Its content cannot be compared without hydration.
    static func isHeaderOnly(_ email: MBOXParser.RawEmail) -> Bool {
        email.rawSource.isEmpty && email.plainBody.isEmpty && email.htmlBody.isEmpty
    }

    /// The located message's own bytes, read through the hydrator's locator
    /// route (`AttachmentHydrator.locatorProvider`, wired by the app under
    /// `Capability.locatorReads`) and parsed with the import reader. The
    /// record's headers and folder stay the archive's statement; bodies,
    /// attachments and raw source come from the located bytes. Nil when no
    /// locator route is available or the bytes do not parse — the caller then
    /// reports the body as not verifiable.
    static func hydrateFromLocatedSource(_ source: MBOXParser.RawEmail) -> MBOXParser.RawEmail? {
        guard isHeaderOnly(source),
              let raw = AttachmentHydrator.rawSource(for: source), !raw.isEmpty,
              looksLikeMessage(raw),
              let parsed = try? MBOXParser.processRawMessage(raw, senderEmail: "", materializeAttachments: false),
              !isHeaderOnly(parsed) else { return nil }
        var full = MBOXParser.RawEmail(id: source.id, headers: source.headers, rawSource: parsed.rawSource, messageType: source.messageType,
                                       attachments: parsed.attachments, timestamp: source.timestamp, domains: source.domains,
                                       plainBody: parsed.plainBody, htmlBody: parsed.htmlBody, mimeRoot: parsed.mimeRoot,
                                       mimeSummary: parsed.mimeSummary, mimeDiagnostics: parsed.mimeDiagnostics,
                                       threadID: source.threadID, inReplyTo: source.inReplyTo, references: source.references,
                                       tags: source.tags, anomalies: source.anomalies)
        full.folderPath = source.folderPath
        full.flags = source.flags
        return full
    }

    // MARK: - Comparison

    static func item(path: String, emailID: UUID?, messageID: String?, fields: [FieldResult]) -> Item {
        let status: Item.Status
        if fields.contains(where: { $0.outcome.isLost }) { status = .mismatched }
        else if fields.contains(where: { $0.outcome.isUnverifiable }) { status = .unverifiable }
        else { status = .matching }
        return Item(path: path, emailID: emailID, messageID: messageID, status: status, reason: nil, fields: fields)
    }

    /// Every contract field of `output` against `source`, under `rules`.
    /// - Parameters:
    ///   - outputFolder: the folder the output carries (PST folder, or the
    ///     layout's recorded folder for a per-message file); nil when it carries none.
    ///   - sourceHydrated: the record was header-only and has been completed.
    static func compare(output: MBOXParser.RawEmail, source: MBOXParser.RawEmail, rules: FormatRules,
                        outputFolder: String? = nil, sourceHydrated: Bool = false) -> [FieldResult] {
        var results: [FieldResult] = []
        func add(_ field: Field, _ outcome: FieldOutcome) { results.append(FieldResult(field: field, outcome: outcome)) }

        add(.subject, compareSubject(output: header("Subject", output.headers), source: header("Subject", source.headers), rules: rules))
        for (field, name) in [(Field.from, "From"), (.to, "To"), (.cc, "Cc"), (.bcc, "Bcc")] {
            add(field, compareAddresses(output: header(name, output.headers), source: header(name, source.headers), field: field, rules: rules))
        }
        add(.date, compareDate(output: output, source: source, rules: rules))
        add(.messageID, compareIdentifier(output: header("Message-ID", output.headers), source: header("Message-ID", source.headers), field: .messageID, rules: rules))
        add(.inReplyTo, compareIdentifier(output: header("In-Reply-To", output.headers), source: header("In-Reply-To", source.headers), field: .inReplyTo, rules: rules))
        add(.references, compareIdentifier(output: header("References", output.headers), source: header("References", source.headers), field: .references, rules: rules))

        let headerOnly = isHeaderOnly(source) && !sourceHydrated
        if headerOnly {
            let why = "the record is header-only (located message) and was not hydrated"
            add(.plainBody, .unverifiable(why))
            add(.htmlBody, .unverifiable(why))
            add(.attachments, .unverifiable(why))
        } else {
            add(.plainBody, compareText(output: output.plainBody, source: source.plainBody, field: .plainBody, rules: rules))
            add(.htmlBody, compareText(output: output.htmlBody, source: source.htmlBody, field: .htmlBody, rules: rules))
            results.append(contentsOf: compareAttachments(output: output, source: source, rules: rules))
        }
        add(.folder, compareFolder(output: outputFolder, source: source.folderPath, rules: rules,
                                   memberships: SQLiteEmailStore.folderPaths(for: source)))
        return results
    }

    // MARK: Field comparisons

    static func compareSubject(output: String?, source: String?, rules: FormatRules) -> FieldOutcome {
        let s = source.map(unfold) ?? ""
        var o = output.map(unfold) ?? ""
        // The .msg reader substitutes "(No Subject)" for a missing subject.
        if rules.kind == .msg, s.isEmpty, o == "(No Subject)" { o = "" }
        if s.isEmpty && o.isEmpty { return .sourceAbsent }
        if s == o { return .unchanged }
        if s.isEmpty { return .lost("added in output") }
        if o.isEmpty { return notCarriedOrLost(.subject, rules, "missing from output") }
        return .lost("changed")
    }

    static func compareAddresses(output: String?, source: String?, field: Field, rules: FormatRules) -> FieldOutcome {
        let s = source.map(unfold) ?? ""
        let o = output.map(unfold) ?? ""
        if s.isEmpty && o.isEmpty { return .sourceAbsent }
        if s == o { return .unchanged }
        if s.isEmpty { return .lost("added in output") }
        if o.isEmpty { return notCarriedOrLost(field, rules, "missing from output") }
        if addressList(s) == addressList(o) {
            return .permittedTransformation("\(field.rawValue): same addresses, display names or order re-expressed")
        }
        return .lost("addresses differ")
    }

    static func compareIdentifier(output: String?, source: String?, field: Field, rules: FormatRules) -> FieldOutcome {
        let s = (source ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let o = (output ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty && o.isEmpty { return .sourceAbsent }
        if s.isEmpty { return .lost("added in output") }
        if o.isEmpty { return notCarriedOrLost(field, rules, "missing from output") }
        let same = field == .references ? identifierList(s) == identifierList(o) : identifier(s) == identifier(o)
        return same ? .unchanged : .lost("changed")
    }

    static func compareText(output: String, source: String, field: Field, rules: FormatRules) -> FieldOutcome {
        let s = text(source), o = text(output)
        if s.isEmpty && o.isEmpty { return .sourceAbsent }
        if s == o { return .unchanged }
        if s.isEmpty { return .lost("added in output") }
        if o.isEmpty { return notCarriedOrLost(field, rules, "missing from output") }
        return .lost("changed")
    }

    /// - Parameter memberships: every folder the record belongs to (its
    ///   folder path, then its labels). A per-folder-occurrence export (OUT-02)
    ///   writes one copy per membership; a copy in ANY of them is unchanged.
    static func compareFolder(output: String?, source: String?, rules: FormatRules, memberships: [String] = []) -> FieldOutcome {
        let s = (source ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let o = (output ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if rules.notCarried[.folder] == nil, !o.isEmpty,
           memberships.contains(where: { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) == o.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) }) {
            return .unchanged
        }
        if s.isEmpty { return .sourceAbsent }
        if let why = rules.notCarried[.folder] { return .permittedTransformation(why) }
        if o.isEmpty {
            return rules.kind.isPerMessageFile
                ? .permittedTransformation("the file layout did not record the folder")
                : .lost("missing from output")
        }
        return s == o ? .unchanged : .lost("changed")
    }

    /// Dates: the Date header when present (its presence is part of the
    /// contract), compared as instants at the precision both sides carry.
    static func compareDate(output: MBOXParser.RawEmail, source: MBOXParser.RawEmail, rules: FormatRules) -> FieldOutcome {
        let sHeader = header("Date", source.headers).map(unfold) ?? ""
        let oHeader = header("Date", output.headers).map(unfold) ?? ""
        if sHeader.isEmpty {
            if oHeader.isEmpty { return .sourceAbsent }
            if rules.kind == .msg || rules.kind == .pst {
                return .permittedTransformation("date: the \(rules.kind.label) carries a delivery time derived from the record (the source had no Date header)")
            }
            return .lost("added in output")
        }
        if oHeader.isEmpty { return notCarriedOrLost(.date, rules, "missing from output") }
        if sHeader == oHeader { return .unchanged }
        guard let sDate = parseDate(sHeader), let oDate = parseDate(oHeader) else {
            return .lost("changed (unparseable date compared as text)")
        }
        let sSeconds = carriesSeconds(sHeader), oSeconds = carriesSeconds(oHeader)
        if sSeconds && oSeconds {
            return Int(sDate.timeIntervalSince1970.rounded(.down)) == Int(oDate.timeIntervalSince1970.rounded(.down))
                ? .permittedTransformation("date re-expressed (same instant to the second)")
                : .lost("changed")
        }
        let side = !oSeconds ? "the \(rules.kind.label) output" : "the record"
        return Int(sDate.timeIntervalSince1970 / 60) == Int(oDate.timeIntervalSince1970 / 60)
            ? .permittedTransformation("date compared to the minute because \(side) carries no seconds")
            : .lost("changed")
    }

    // MARK: Attachments as occurrences

    /// One attachment occurrence: every field travels together, so a payload
    /// stays tied to its own name, Content-ID, disposition (and, when asked
    /// for, MIME type). Shared with duplicate verification (release audit
    /// bf1a5b9 R2): two copies match only when their occurrences match as a
    /// multiset of whole tuples — repeated identical payloads with the same
    /// metadata still match, swapped associations never do.
    ///
    /// Normalisations (the only ones): the file name is trimmed of
    /// surrounding whitespace; the Content-ID loses angle brackets and
    /// surrounding whitespace (`identifier`); the MIME type as
    /// `normalisedMIMEType` describes. `size` is the byte count of the decoded
    /// payload, so it is nil when the bytes could not be produced.
    struct Occurrence: Hashable, Sendable {
        let name: String
        let sha256: String?
        let size: Int?
        let contentID: String?
        let inline: Bool
        /// nil when the comparison does not include the type (export
        /// reconciliation: writers legitimately re-label types).
        var mimeType: String? = nil
        var withoutBytes: Occurrence { Occurrence(name: name, sha256: nil, size: nil, contentID: contentID, inline: inline, mimeType: mimeType) }
        var withoutContentID: Occurrence { Occurrence(name: name, sha256: sha256, size: size, contentID: nil, inline: inline, mimeType: mimeType) }
        var withoutDisposition: Occurrence { Occurrence(name: name, sha256: sha256, size: size, contentID: contentID, inline: false, mimeType: mimeType) }
    }

    /// `Occurrence.mimeType` normalisation: type/subtype and parameter names
    /// lower-cased (case-insensitive by RFC 2045 §5.1), whitespace around the
    /// pieces trimmed, and the `name` parameter dropped — it repeats the file
    /// name, which the occurrence compares on its own, and Outlook's .msg/PST
    /// store the type without it. Every other parameter (charset, method, …)
    /// is kept with its value as written.
    static func normalisedMIMEType(_ raw: String) -> String {
        let pieces = raw.split(separator: ";", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let type = pieces.first else { return "" }
        var out = [type.lowercased()]
        for parameter in pieces.dropFirst() where !parameter.isEmpty {
            let parts = parameter.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let name = parts[0].lowercased()
            if name == "name" { continue }
            out.append(parts.count == 2 ? "\(name)=\(parts[1])" : name)
        }
        return out.joined(separator: "; ")
    }

    static func occurrences(of email: MBOXParser.RawEmail, includeMIMEType: Bool = false) -> (list: [Occurrence], missingBytes: Int) {
        let cache = AttachmentHydrator.Cache()
        defer { cache.removeTemporaryFiles() }
        var missing = 0
        let list = email.attachments.enumerated().map { index, a -> Occurrence in
            let data = AttachmentHydrator.data(for: a, index: index, email: email, cache: cache)
            if data == nil { missing += 1 }
            return Occurrence(name: a.filename.trimmingCharacters(in: .whitespacesAndNewlines),
                              sha256: data.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() },
                              size: data?.count,
                              contentID: a.contentID.map(identifier).flatMap { $0.isEmpty ? nil : $0 },
                              inline: a.isInline,
                              mimeType: includeMIMEType ? normalisedMIMEType(a.mimeType) : nil)
        }
        return (list, missing)
    }

    /// Occurrences as a multiset of whole tuples (count kept, order ignored).
    static func occurrenceMultiset(_ items: [Occurrence]) -> [Occurrence: Int] { multiset(items) }

    static func compareAttachments(output: MBOXParser.RawEmail, source: MBOXParser.RawEmail, rules: FormatRules) -> [FieldResult] {
        var results: [FieldResult] = []
        let s = occurrences(of: source), o = occurrences(of: output)
        if s.list.isEmpty && o.list.isEmpty {
            results.append(FieldResult(field: .attachments, outcome: .sourceAbsent))
            return results
        }
        // Content-ID and disposition are compared on their own, so a writer
        // that cannot carry them is named without hiding a payload difference.
        var sList = s.list, oList = o.list
        let cidReason = rules.notCarried[.attachmentContentIDs]
        let dispReason = rules.notCarried[.attachmentDispositions]
        let sourceHasCID = sList.contains { $0.contentID != nil }
        let sourceHasInline = sList.contains(where: \.inline)
        if sourceHasCID {
            let cids: ([Occurrence]) -> [String?] = { $0.map(\.contentID) }
            if cids(sList).sorted(by: sortOptional) == cids(oList).sorted(by: sortOptional) {
                results.append(FieldResult(field: .attachmentContentIDs, outcome: .unchanged))
            } else if let cidReason {
                results.append(FieldResult(field: .attachmentContentIDs, outcome: .permittedTransformation(cidReason)))
            } else {
                results.append(FieldResult(field: .attachmentContentIDs, outcome: .lost("Content-IDs differ")))
            }
        }
        if sourceHasInline {
            if sList.filter(\.inline).count == oList.filter(\.inline).count {
                results.append(FieldResult(field: .attachmentDispositions, outcome: .unchanged))
            } else if let dispReason {
                results.append(FieldResult(field: .attachmentDispositions, outcome: .permittedTransformation(dispReason)))
            } else {
                results.append(FieldResult(field: .attachmentDispositions, outcome: .lost("inline dispositions differ")))
            }
        }
        if cidReason != nil { sList = sList.map(\.withoutContentID); oList = oList.map(\.withoutContentID) }
        if dispReason != nil { sList = sList.map(\.withoutDisposition); oList = oList.map(\.withoutDisposition) }

        if sList.count != oList.count {
            results.append(FieldResult(field: .attachments, outcome: .lost("\(sList.count) in the record, \(oList.count) in the output")))
            return results
        }
        let missing = s.missingBytes + o.missingBytes
        if missing > 0 {
            // Names, Content-IDs and dispositions can still be compared; the bytes cannot.
            if multiset(sList.map(\.withoutBytes)) != multiset(oList.map(\.withoutBytes)) {
                results.append(FieldResult(field: .attachments, outcome: .lost("attachment names or Content-IDs differ")))
            } else {
                var where_: [String] = []
                if s.missingBytes > 0 { where_.append("\(s.missingBytes) in the record") }
                if o.missingBytes > 0 { where_.append("\(o.missingBytes) in the output") }
                results.append(FieldResult(field: .attachments, outcome: .unverifiable("attachment bytes could not be read: \(where_.joined(separator: ", "))")))
            }
            return results
        }
        if multiset(sList) == multiset(oList) {
            results.append(FieldResult(field: .attachments, outcome: .unchanged))
        } else if multiset(sList.map(\.name)) != multiset(oList.map(\.name)) {
            results.append(FieldResult(field: .attachments, outcome: .lost("attachment names differ")))
        } else {
            let changed = Set(sList).subtracting(oList).map(\.name).sorted()
            results.append(FieldResult(field: .attachments, outcome: .lost("same names, different bytes: \(changed.joined(separator: ", "))")))
        }
        return results
    }

    private static func sortOptional(_ a: String?, _ b: String?) -> Bool { (a ?? "") < (b ?? "") }

    private static func multiset<T: Hashable>(_ items: [T]) -> [T: Int] {
        var out: [T: Int] = [:]
        for item in items { out[item, default: 0] += 1 }
        return out
    }

    private static func notCarriedOrLost(_ field: Field, _ rules: FormatRules, _ detail: String) -> FieldOutcome {
        if let why = rules.notCarried[field] { return .permittedTransformation(why) }
        return .lost(detail)
    }

    // MARK: - Normalisation helpers

    /// Case-insensitive header lookup (headers are stored as parsed: "Cc" or "CC").
    static func header(_ name: String, _ headers: [String: String]) -> String? {
        if let direct = headers[name] { return direct }
        let lower = name.lowercased()
        return headers.first { $0.key.lowercased() == lower }?.value
    }

    /// `Normalization.headerText`: folding undone, surrounding whitespace trimmed, case kept.
    static func unfold(_ s: String) -> String {
        s.replacingOccurrences(of: "\r?\n[ \t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `Normalization.addressList`: addresses only, lower-cased, sorted; count kept.
    static func addressList(_ header: String) -> [String] {
        var found: [String] = []
        for piece in header.components(separatedBy: CharacterSet(charactersIn: ",;")) {
            if let open = piece.lastIndex(of: "<"), let close = piece[open...].firstIndex(of: ">") {
                found.append(String(piece[piece.index(after: open)..<close]).trimmingCharacters(in: .whitespaces).lowercased())
            } else {
                let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !trimmed.isEmpty { found.append(trimmed) }
            }
        }
        return found.sorted()
    }

    /// `Normalization.identifier`: angle brackets and surrounding whitespace trimmed.
    static func identifier(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "<>")).trimmingCharacters(in: .whitespaces)
    }

    static func identifierList(_ s: String) -> [String] {
        s.components(separatedBy: .whitespacesAndNewlines).map(identifier).filter { !$0.isEmpty }
    }

    /// `Normalization.text`: CRLF → LF, trailing whitespace per line, trailing blank lines.
    static func text(_ s: String) -> String {
        guard !s.isEmpty else { return "" }
        let lines = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { line -> String in
                var end = line.endIndex
                while end > line.startIndex, line[line.index(before: end)].isWhitespace { end = line.index(before: end) }
                return String(line[..<end])
            }
        var trimmed = lines[...]
        while let last = trimmed.last, last.isEmpty { trimmed = trimmed.dropLast() }
        return trimmed.joined(separator: "\n")
    }

    static func carriesSeconds(_ dateText: String) -> Bool {
        dateText.range(of: "\\d{1,2}:\\d{2}:\\d{2}", options: .regularExpression) != nil
    }

    static func parseDate(_ text: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: text) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: text) { return d }
        let trimmed = text.replacingOccurrences(of: "\\s*\\(.*\\)$", with: "", options: .regularExpression)
        for format in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z", "d MMM yyyy HH:mm Z", "EEE, d MMM yyyy HH:mm:ss zzz"] {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = format
            if let d = f.date(from: trimmed) { return d }
        }
        return nil
    }

    // MARK: - Compatibility (the app's `ExportRunCenter` and its tests call these)
    //
    // `reconcile(folder:records:)` takes the records as a dictionary and runs
    // synchronously. It is the old entry point kept working; it uses the same
    // comparison as the streaming engine, so its answers are no weaker — a
    // header-only record is hydrated through the hydrator's locator route
    // when the app has wired it (`Capability.locatorReads`) and is
    // `unverifiable` otherwise, and `isClean` now requires every listed
    // per-message file to be tied to a record and verified.

    struct Mismatch: Sendable, Equatable {
        let path: String
        let differences: [String]
    }

    struct Report: Sendable, Equatable {
        /// Files the inventory ties to a message record and that could be parsed.
        var checked = 0
        var matching = 0
        var mismatches: [Mismatch] = []
        /// Files that could not be parsed back as a message (with the reason).
        var unparsed: [String] = []
        /// Files whose message record is no longer in the archive (or listed without one).
        var withoutRecord = 0
        /// Files that parsed and have a record but could not be fully compared (with the reason).
        var unverifiable: [String] = []
        /// Inventory files of a kind this check does not parse (reports, PST, mbox of many).
        var notApplicable = 0
        /// Named transformations seen (format limits, precision drops) with counts.
        var transformations: [String: Int] = [:]
        /// Header-only (located) records read from their source bytes for the comparison.
        var hydrated = 0

        var isClean: Bool {
            mismatches.isEmpty && unparsed.isEmpty && unverifiable.isEmpty && withoutRecord == 0 && checked > 0 && matching == checked
        }
    }

    /// Re-parse each per-message output file the inventory lists and compare
    /// it with `records[emailID]`. Full, never sampled. Container outputs
    /// (mbox, PST) are `notApplicable` here — use `reconcile(folder:lookup:)`.
    static func reconcile(folder: URL, records: [UUID: MBOXParser.RawEmail]) throws -> Report {
        let inventory = try ExportInventory.load(folder: folder)
        var report = Report()
        for file in inventory.files {
            let url = folder.appendingPathComponent(file.path)
            let kind = OutputKind.of(url: url)
            guard kind.isPerMessageFile else { report.notApplicable += 1; continue }
            guard let idString = file.emailID, let id = UUID(uuidString: idString), var source = records[id] else { report.withoutRecord += 1; continue }
            let output: MBOXParser.RawEmail
            do { output = try parseOutput(url: url, kind: kind) } catch {
                report.unparsed.append("\(file.path): \(error.localizedDescription)"); continue
            }
            defer { removeScratch(of: output) }
            report.checked += 1
            var hydrated = false
            if let full = hydrateFromLocatedSource(source) { source = full; hydrated = true; report.hydrated += 1 }
            let item = item(path: file.path, emailID: id, messageID: source.headers["Message-ID"],
                            fields: compare(output: output, source: source, rules: FormatRules.rules(for: kind),
                                            outputFolder: file.originalFolder, sourceHydrated: hydrated))
            for name in item.transformations { report.transformations[name, default: 0] += 1 }
            switch item.status {
            case .matching: report.matching += 1
            case .mismatched: report.mismatches.append(Mismatch(path: file.path, differences: item.lostFields.map(\.rawValue)))
            case .unverifiable: report.unverifiable.append("\(file.path): \(item.differences.joined(separator: "; "))")
            case .withoutRecord: report.withoutRecord += 1
            case .unparsed: report.unparsed.append(file.path)
            case .missing, .extra: break   // container outcomes; per-message files never produce them
            }
        }
        return report
    }

    /// The fields in which the re-parsed output disagrees with the archive's
    /// record (lost fields only; see `compare` for the full per-field result).
    static func differences(output: MBOXParser.RawEmail, source: MBOXParser.RawEmail) -> [String] {
        compare(output: output, source: source, rules: FormatRules.rules(for: .eml)).filter { $0.outcome.isLost }.map(\.field.rawValue)
    }

    /// Addresses only, lower-cased and sorted: "Ann <a@x.com>" and "a@x.com" agree.
    static func addresses(_ header: String?) -> String {
        guard let header, !header.isEmpty else { return "" }
        return addressList(header).joined(separator: ",")
    }

    /// The minute the message carries, from the Date header or the stored
    /// timestamp (RFC 2822 or ISO 8601); unparsable values compare as text.
    /// Kept for the app's existing test; the engine itself uses `compareDate`.
    static func dateKey(_ header: String?, _ timestamp: String) -> String {
        for candidate in [header ?? "", timestamp] where !candidate.isEmpty {
            if let date = parseDate(candidate) { return String(Int(date.timeIntervalSince1970 / 60)) }
        }
        return collapse(header ?? timestamp)
    }

    static func collapse(_ s: String?) -> String {
        (s ?? "").components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ").lowercased()
    }
}
