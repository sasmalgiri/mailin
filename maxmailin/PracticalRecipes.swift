@testable import ArchiveCore
//
//  PracticalRecipes.swift
//  maxmailin
//
//  v4.0 REC-06 / REC-05 / SEARCH-04: the five practical recipes that sit beside
//  Archive and Search (plan §2.1):
//
//    1. Find messages and export    search with coverage → freeze → export → verify → receipt
//    2. Find and save attachments   matching files (an attachment, or a file inside one,
//                                   chosen explicitly) → safe names + byte inventory → verify
//    3. Archive and safely clean up selection → duplicate classification → only verified-
//                                   identical extra copies to the Trash, after the count
//    4. Back up and restore         write + verify a backup → restore it into an isolated,
//                                   empty profile → reconcile counts and the inventory
//    5. Collect and hand over       sender / dates / words / folder + a name → saved search
//                                   → preview of matches and totals → verified export
//
//  Each recipe drives the SAME engines the tools use — `ArchiveExportService`,
//  `ExportInventory`, `DuplicateVerification` + `removeDuplicateCopies`,
//  `ArchiveBackup`, `FrozenSearchSelection`, `ContainerTextExtractor.materialize`
//  — and its result is read back from what those engines persisted (REC-05):
//  the export receipt, the inventory, the registry document, the backup
//  inventory. A cancelled, failed or unverified job never yields "Completed".
//
//  At most three decisions before running (file pickers and safety
//  confirmations excepted); Free runs every recipe whose actions Free is
//  entitled to, with its real limits stated; no AI and no Professional page.
//

import Foundation

// MARK: - The five recipes

enum PracticalRecipeKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case findAndExport, saveAttachments, cleanUpDuplicates, backUpAndRestore, collectAndHandOver

    var id: String { rawValue }

    var title: String {
        switch self {
        case .findAndExport: return String(localized: "Find messages and export")
        case .saveAttachments: return String(localized: "Find and save attachments")
        case .cleanUpDuplicates: return String(localized: "Archive and safely clean up")
        case .backUpAndRestore: return String(localized: "Back up and restore")
        case .collectAndHandOver: return String(localized: "Collect a project and hand over")
        }
    }

    var summary: String {
        switch self {
        case .findAndExport:
            return String(localized: "Search with coverage, freeze the matches, export them and verify every file.")
        case .saveAttachments:
            return String(localized: "Find PDF, Word or Excel files — also inside ZIPs and attached messages — and save them with a byte inventory.")
        case .cleanUpDuplicates:
            return String(localized: "Find copies verified identical and move only the extra copies to the Trash, after showing the count.")
        case .backUpAndRestore:
            return String(localized: "Write and verify a backup, then restore it into a separate empty profile and compare the counts.")
        case .collectAndHandOver:
            return String(localized: "Save a search for a sender, dates, words or a folder, preview the matches and export a verified handover.")
        }
    }

    var icon: String {
        switch self {
        case .findAndExport: return "square.and.arrow.up.on.square"
        case .saveAttachments: return "paperclip"
        case .cleanUpDuplicates: return "square.on.square.dashed"
        case .backUpAndRestore: return "externaldrive.badge.checkmark"
        case .collectAndHandOver: return "folder.badge.person.crop"
        }
    }

    /// The essential decisions before running — never more than three
    /// (file pickers and safety confirmations are not counted, plan REC-08).
    var decisions: [String] {
        switch self {
        case .findAndExport: return [String(localized: "What to find"), String(localized: "Export format")]
        case .saveAttachments: return [String(localized: "What to find"), String(localized: "Which files to save")]
        case .cleanUpDuplicates: return [String(localized: "Which mail to check")]
        case .backUpAndRestore: return [String(localized: "Back up now, or check a backup")]
        case .collectAndHandOver: return [String(localized: "Conditions"), String(localized: "Collection name"), String(localized: "Export format")]
        }
    }

    /// The jobs the recipe runs, in order.
    var jobs: [RecipeJobKind] {
        switch self {
        case .findAndExport, .collectAndHandOver: return [.search, .export]
        case .saveAttachments: return [.search, .export]
        case .cleanUpDuplicates: return [.search, .dedupe]
        case .backUpAndRestore: return [.backup, .restore]
        }
    }

    /// Free runs every recipe whose actions Free is entitled to: search,
    /// export (500 per run), attachment saves (the daily allowance) and
    /// backup / restore (never gated). Duplicate clean-up is the Duplicate
    /// Manager's work and follows its tier.
    func isEntitled(_ policy: AccessPolicy) -> Bool {
        switch self {
        case .cleanUpDuplicates:
            return HubDestination.duplicateManager.requiredTier == .free || policy.allowsPaidWork
        case .findAndExport, .saveAttachments, .backUpAndRestore, .collectAndHandOver:
            return true
        }
    }

    /// The real limit the plan puts on this recipe, said before it runs.
    func limitNote(_ policy: AccessPolicy) -> String? {
        switch self {
        case .findAndExport, .collectAndHandOver:
            guard let cap = policy.exportCap(for: .emlFiles) else { return nil }
            return String(localized: "Free plan: up to \(cap) messages per export; the receipt says how many of the matches were written.")
        case .saveAttachments:
            guard policy.attachmentDownloadLimit(usedToday: 0, freeAllowance: 1) != nil else { return nil }
            return String(localized: "Free plan: attachment saves count against the daily allowance; files beyond it are listed as not saved.")
        case .cleanUpDuplicates:
            return isEntitled(policy) ? nil : String(localized: "Duplicate clean-up needs the Personal or Professional plan.")
        case .backUpAndRestore:
            return nil
        }
    }
}

enum PracticalExportFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    /// One .eml per message in a folder, with the per-file inventory.
    case emlFolder
    /// One mbox file, hashed while written.
    case mboxFile

    var id: String { rawValue }
    var unified: UnifiedExportFormat { self == .emlFolder ? .emlFiles : .mbox }
    var label: String {
        switch self {
        case .emlFolder: return String(localized: "EML files in a folder")
        case .mboxFile: return String(localized: "One MBOX file")
        }
    }
}

// MARK: - SEARCH-04: saved-query templates (only fields SearchSpec supports)

struct SearchQueryTemplate: Identifiable, Sendable {
    enum Parameter: String, CaseIterable, Sendable {
        case keyword, sender, fromDay, toDay, phrase, fileType
        var label: String {
            switch self {
            case .keyword: return String(localized: "Word")
            case .sender: return String(localized: "Sender")
            case .fromDay: return String(localized: "From (yyyy-MM-dd)")
            case .toDay: return String(localized: "To (yyyy-MM-dd)")
            case .phrase: return String(localized: "Phrase")
            case .fileType: return String(localized: "File type")
            }
        }
    }

    let id: String
    let title: String
    let parameters: [Parameter]
    let defaults: [Parameter: String]
    let build: @Sendable ([Parameter: String], String) -> SearchSpec

    /// The template's spec for `values` (missing values fall back to the defaults).
    func spec(_ values: [Parameter: String], timeZone: String = TimeZone.current.identifier) -> SearchSpec {
        var merged = defaults
        for (k, v) in values where !v.trimmingCharacters(in: .whitespaces).isEmpty { merged[k] = v.trimmingCharacters(in: .whitespaces) }
        return build(merged, timeZone)
    }
}

enum SearchQueryTemplates {
    /// File types the templates offer: SearchSpec families and extensions.
    static let fileTypes: [(label: String, value: String)] = [
        (String(localized: "PDF"), "PDF"), (String(localized: "Word (.docx)"), "docx"),
        (String(localized: "Excel (.xlsx)"), "xlsx"), (String(localized: "Office documents"), "Office documents"),
        (String(localized: "Images"), "Images"), (String(localized: "Archives"), "Archives"),
    ]

    static let invoicesWithPDF = SearchQueryTemplate(
        id: "invoicesWithPDF", title: String(localized: "Invoices with PDF attachments"),
        parameters: [.keyword], defaults: [.keyword: "invoice"]) { v, _ in
            SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.anyText, .contains, v[.keyword] ?? "invoice")],
                                            attachments: [AttachmentConditionGroup(type: "PDF")])])
        }

    static let senderInDateRange = SearchQueryTemplate(
        id: "senderInDateRange", title: String(localized: "From a sender in a date range"),
        parameters: [.sender, .fromDay, .toDay], defaults: [:]) { v, zone in
            var c: [SearchCondition] = []
            if let s = v[.sender] { c.append(SearchCondition(.sender, .contains, s)) }
            if let d = v[.fromDay] { c.append(SearchCondition(.dateOnOrAfter, .equals, d, timeZone: zone)) }
            if let d = v[.toDay] { c.append(SearchCondition(.dateOnOrBefore, .equals, d, timeZone: zone)) }
            return SearchSpec(groups: [SearchGroup(.all, c)])
        }

    static let attachmentsContainingPhrase = SearchQueryTemplate(
        id: "attachmentsContainingPhrase", title: String(localized: "Attachments containing a phrase"),
        parameters: [.phrase, .fileType], defaults: [:]) { v, _ in
            SearchSpec(groups: [SearchGroup(.all, attachments: [AttachmentConditionGroup(type: v[.fileType], contentMatch: .phrase, content: v[.phrase])])])
        }

    static let officeFilesFromSender = SearchQueryTemplate(
        id: "officeFilesFromSender", title: String(localized: "Word or Excel files from a sender"),
        parameters: [.sender, .fileType], defaults: [.fileType: "Office documents"]) { v, _ in
            var c: [SearchCondition] = []
            if let s = v[.sender] { c.append(SearchCondition(.sender, .contains, s)) }
            return SearchSpec(groups: [SearchGroup(.all, c, attachments: [AttachmentConditionGroup(type: v[.fileType] ?? "Office documents")])])
        }

    static let filesOfType = SearchQueryTemplate(
        id: "filesOfType", title: String(localized: "Every attachment of one type"),
        parameters: [.fileType], defaults: [.fileType: "PDF"]) { v, _ in
            SearchSpec(groups: [SearchGroup(.all, attachments: [AttachmentConditionGroup(type: v[.fileType] ?? "PDF")])])
        }

    static let all: [SearchQueryTemplate] = [invoicesWithPDF, senderInDateRange, attachmentsContainingPhrase, officeFilesFromSender, filesOfType]
}

// MARK: - Collect and hand over: the conditions

struct CollectionConditions: Codable, Equatable, Sendable {
    var sender = ""
    var fromDay = ""
    var toDay = ""
    var words = ""
    var folderID: Int64? = nil

    /// A deterministic spec: every filled condition must hold.
    func spec(timeZone: String = TimeZone.current.identifier) -> SearchSpec {
        var c: [SearchCondition] = []
        func filled(_ s: String) -> String? { let t = s.trimmingCharacters(in: .whitespaces); return t.isEmpty ? nil : t }
        if let s = filled(sender) { c.append(SearchCondition(.sender, .contains, s)) }
        if let d = filled(fromDay) { c.append(SearchCondition(.dateOnOrAfter, .equals, d, timeZone: timeZone)) }
        if let d = filled(toDay) { c.append(SearchCondition(.dateOnOrBefore, .equals, d, timeZone: timeZone)) }
        if let w = filled(words) { c.append(SearchCondition(.anyText, .allWords, w)) }
        if let folderID { c.append(SearchCondition(.folder, .equals, String(folderID))) }
        return SearchSpec(groups: [SearchGroup(.all, c)])
    }
}

// MARK: - SEARCH-04: files that matched

/// One file a recipe can save: an attachment, or a file inside one.
struct RecipeFileCandidate: Identifiable, Hashable, Sendable {
    var id: String { "\(emailID.uuidString)#\(ordinal)#\(childIndex.map(String.init) ?? "-")" }
    let emailID: EmailID
    let subject: String
    let sender: String
    /// The top-level attachment's position in its message.
    let ordinal: Int
    /// Set for a file inside the attachment (archive member, attached message part).
    let childIndex: Int?
    /// "outer.zip › inner/minutes.docx" — the path the index recorded.
    let childPath: String?
    let filename: String
    let mimeType: String
    let bytes: Int?
    /// The index's state for a nested file ("locked", "unsupported", …); nil for a top-level attachment.
    let state: String?
    /// The file itself meets the search's attachment conditions (type / name).
    let matchesConditions: Bool

    var isNested: Bool { childIndex != nil }
    var family: String { SQLiteEmailStore.attachmentFamily(mimeType: mimeType, filename: filename) }
    /// A locked member cannot be extracted without its password.
    var isLocked: Bool { state == ChildDocument.State.locked.rawValue }
    var location: String { childPath.map { String(localized: "inside attachment \(ordinal + 1): \($0)") } ?? String(localized: "attachment \(ordinal + 1)") }
}

enum RecipeFileBrowser {
    /// True when a file meets every attachment condition of `spec` that is
    /// about the FILE (type, name). Content conditions are answered by the
    /// index and shown as evidence; they do not hide a file here.
    static func matches(filename: String, mimeType: String, spec: SearchSpec) -> Bool {
        let groups = spec.liveGroups.filter { $0.kind != .exclude }.flatMap(\.liveAttachmentGroups).filter { !$0.isNegated }
        let fileGroups = groups.filter { !(($0.type ?? "").isEmpty && ($0.nameContains ?? "").isEmpty) }
        guard !fileGroups.isEmpty else { return true }
        return fileGroups.contains { g in typeMatches(g.type, filename: filename, mimeType: mimeType) && nameMatches(g.nameContains, filename: filename) }
    }

    static func typeMatches(_ type: String?, filename: String, mimeType: String) -> Bool {
        guard let type = type?.trimmingCharacters(in: .whitespaces), !type.isEmpty else { return true }
        let family = SQLiteEmailStore.attachmentFamily(mimeType: mimeType, filename: filename)
        if family.caseInsensitiveCompare(type) == .orderedSame { return true }
        return (filename as NSString).pathExtension.lowercased() == type.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    static func nameMatches(_ name: String?, filename: String) -> Bool {
        guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return true }
        return filename.localizedCaseInsensitiveContains(name)
    }

    /// The candidates of one message: each attachment and each recorded file
    /// inside it, flagged when it meets the conditions.
    static func candidates(email: MBOXParser.RawEmail, children: [AttachmentChildRow], spec: SearchSpec) -> [RecipeFileCandidate] {
        var out: [RecipeFileCandidate] = []
        let subject = email.headers["Subject"] ?? ""
        let sender = email.headers["From"] ?? ""
        for (i, att) in email.attachments.enumerated() {
            out.append(RecipeFileCandidate(emailID: email.id, subject: subject, sender: sender, ordinal: i, childIndex: nil, childPath: nil,
                                           filename: att.filename, mimeType: att.mimeType, bytes: att.size, state: nil,
                                           matchesConditions: matches(filename: att.filename, mimeType: att.mimeType, spec: spec)))
            for child in children where child.position == i {
                out.append(RecipeFileCandidate(emailID: email.id, subject: subject, sender: sender, ordinal: i, childIndex: child.childIndex,
                                               childPath: child.path, filename: child.filename, mimeType: "", bytes: child.bytes, state: child.state,
                                               matchesConditions: matches(filename: child.filename, mimeType: "", spec: spec)))
            }
        }
        return out
    }

    /// A file name that is safe on every file system and unique in `used`.
    static func uniqueSafeName(_ filename: String, used: inout Set<String>) -> String {
        let safe = ExportInventory.safeComponent(EvidenceAttachmentOpener.safeFilename(filename, mimeType: ""))
        let base = safe.isEmpty ? "attachment" : safe
        var name = base
        var n = 2
        let stem = (base as NSString).deletingPathExtension
        let ext = (base as NSString).pathExtension
        while used.contains(name.lowercased()) {
            name = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            n += 1
        }
        used.insert(name.lowercased())
        return name
    }
}

// MARK: - Results (REC-05: read back from the receipts, kept across restarts)

struct PracticalRecipeResult: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var recipe: PracticalRecipeKind
    var state: RecipeRunState
    var startedAt: Date
    var finishedAt: Date
    /// One entry per job, each read from that job's persisted receipt.
    var facts: [RecipeResultFacts]
    /// Anything else the run created (a saved search, the restore check folder).
    var notes: [String] = []

    var isCompleted: Bool { state == .completed }

    /// Completed only when every job succeeded AND its verification passed;
    /// a cancelled, failed, partial or unverified job decides the state.
    static func state(of facts: [RecipeResultFacts]) -> RecipeRunState {
        if facts.contains(where: { $0.outcome == .cancelled }) { return .cancelled }
        if facts.contains(where: { $0.outcome == .failed }) { return .failed }
        if facts.contains(where: { $0.outcome == .unverifiable || $0.verificationPassed == false }) { return .needsAttention }
        if facts.contains(where: { $0.outcome == .partial || $0.outcome == .running }) { return .partial }
        if facts.isEmpty { return .failed }
        let jobs = facts.filter { $0.receiptKind != .measurement }
        if jobs.contains(where: { $0.verificationPassed != true }) { return .partial }
        if facts.contains(where: { !$0.skipped.isEmpty && $0.receiptKind != .backupInventory && $0.receiptKind != .restoreInventory }) { return .partial }
        return .completed
    }
}

final class PracticalRecipeResultStore: @unchecked Sendable {
    let directory: URL
    init(directory: URL) { self.directory = directory }

    static var production: PracticalRecipeResultStore {
        PracticalRecipeResultStore(directory: RecipeRunFileStore.baseDirectory.appendingPathComponent("practical-recipes", isDirectory: true))
    }

    func url(_ id: UUID) -> URL { directory.appendingPathComponent("result-\(id.uuidString).json") }

    @discardableResult
    func save(_ result: PracticalRecipeResult) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let u = url(result.id)
        try RecipeRunFileStore.encoder.encode(result).write(to: u, options: .atomic)
        return u
    }

    func load(_ id: UUID) throws -> PracticalRecipeResult {
        try RecipeRunFileStore.decoder.decode(PracticalRecipeResult.self, from: Data(contentsOf: url(id)))
    }

    /// Newest first.
    func list() -> [PracticalRecipeResult] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }
            .compactMap { try? RecipeRunFileStore.decoder.decode(PracticalRecipeResult.self, from: Data(contentsOf: $0)) }
            .sorted { $0.finishedAt > $1.finishedAt }
    }
}

// MARK: - The engine

enum PracticalRecipeError: LocalizedError, Equatable {
    case invalidSearch(String)
    case notFrozen
    case planUnknown
    case notEntitled

    var errorDescription: String? {
        switch self {
        case .invalidSearch(let why): return String(localized: "The search cannot run: \(why)")
        case .notFrozen: return String(localized: "The matches could not be frozen: this archive is not the SQLite store.")
        case .planUnknown: return String(localized: "Your plan could not be checked, so nothing was started.")
        case .notEntitled: return String(localized: "This recipe needs the Personal or Professional plan.")
        }
    }
}

/// What the review stage shows before anything is written: the frozen
/// matches, what could not be confirmed, and what the search could not read.
struct RecipeSearchPreview: Equatable, Sendable {
    let selection: FrozenSearchSelection
    let spec: SearchSpec
    let matches: Int
    /// Rows the search could not decide yet (unindexed text).
    let unresolved: Int
    /// RQ07: locked / unread / partly read files inside attachments in this scope.
    let coverage: String?
    let sourceLine: String

    /// The measured search, as the result's first fact.
    var facts: RecipeResultFacts {
        var f = RecipeResultFacts(report: RecipeJobReport(kind: .search, outcome: .succeeded,
                                                          receipt: .init(kind: .measurement, id: "\(matches) matches"),
                                                          summary: "Search: \(matches) matching messages" + (unresolved > 0 ? " · \(unresolved) not yet confirmed (unindexed content)" : ""),
                                                          count: matches, spec: spec, reportedAt: selection.frozenAt,
                                                          storeRevision: selection.revision),
                                  outcome: .succeeded)
        f.source = sourceLine
        f.coverage = coverage
        return f
    }
}

/// Duplicate clean-up, reviewed before anything moves.
struct RecipeCleanupPlan: Equatable, Sendable {
    let plans: [SQLiteEmailStore.DuplicateRemovalPlan]
    /// Extra copies verified identical — what Move to Trash affects.
    let removable: Int
    let verifiedGroups: Int
    /// Same Message-ID, different content: shown, never moved.
    let candidateGroups: Int
    let sourceLine: String
}

@MainActor
final class PracticalRecipeEngine {
    struct Environment {
        var archive: ArchiveDataService
        var store: SQLiteEmailStore
        var exportReceipts: ExportReceiptStore
        var results: PracticalRecipeResultStore
        var savedSearches: ArchiveSavedSearchStore
        var policy: AccessPolicy?
        var defaults: UserDefaults = .standard
        var receiptDirectories: [(name: String, url: URL)] = []
        /// Numbered registry document for a clean-up (rule 5: after it happened).
        var postDocument: (DocumentType, String) async -> String? = { type, summary in await DocumentRegistry.post(type, summary: summary) }
        var documentExists: (String) async -> Bool = { number in
            let docs = (try? await SQLiteEmailStore.shared.lookupDocuments(matching: number, limit: 5)) ?? []
            return docs.contains { $0.number == number }
        }
        var scratch: URL = FileManager.default.temporaryDirectory

        @MainActor static func production(policy: AccessPolicy?) -> Environment {
            Environment(archive: .shared, store: .shared, exportReceipts: .production, results: .production,
                        savedSearches: .shared, policy: policy, receiptDirectories: ArchiveBackups.receiptDirectories)
        }
    }

    let env: Environment
    /// Progress for the running stage: (what, done, total).
    var onProgress: ((String, Int, Int) -> Void)?

    init(env: Environment) { self.env = env }

    // MARK: Review (nothing written)

    /// Freezes the matches of `spec` (inside `base`, the scope) at the
    /// archive's current revision and measures them, with coverage.
    func preview(spec: SearchSpec, base: EmailQuery = .all, scopeName: String) async throws -> RecipeSearchPreview {
        if let problem = spec.problems().first { throw PracticalRecipeError.invalidSearch(problem.message) }
        var query = base
        query.spec = spec.isEmpty ? nil : spec
        guard let frozen = try await FrozenSearchSelection.freeze(query, archive: env.archive) else { throw PracticalRecipeError.notFrozen }
        let matches = try await env.archive.count(query: frozen.query)
        let unresolved = spec.isEmpty ? 0 : ((try? await env.archive.unresolvedCount(query: frozen.query)) ?? 0)
        let childCounts = try? await env.store.attachmentChildStateCounts(scope: frozen.query)
        let coverage = AttachmentTextIndexJob.childrenNotice(childCounts, scope: .search)
        let what = spec.isEmpty ? String(localized: "every message") : SearchSpecDescriber.summary(spec)
        return RecipeSearchPreview(selection: frozen, spec: spec, matches: matches, unresolved: unresolved, coverage: coverage,
                                   sourceLine: "\(scopeName): \(what)")
    }

    // MARK: 1 and 5 — export the frozen matches, verify, receipt

    func findAndExport(_ preview: RecipeSearchPreview, format: PracticalExportFormat, destination: URL,
                       recipe: PracticalRecipeKind = .findAndExport, notes: [String] = []) async -> PracticalRecipeResult {
        let started = Date()
        let exportFacts = await export(preview, format: format, destination: destination)
        return finish(recipe, started: started, facts: [preview.facts, exportFacts], notes: notes)
    }

    /// 5: the conditions become a saved, deterministic search under the collection's name, then 1 runs.
    func collectAndHandOver(_ conditions: CollectionConditions, name: String, format: PracticalExportFormat,
                            destination: URL) async -> PracticalRecipeResult {
        let started = Date()
        let spec = conditions.spec()
        let label = name.trimmingCharacters(in: .whitespaces).isEmpty ? SearchSpecDescriber.summary(spec) : name
        do {
            let preview = try await self.preview(spec: spec, scopeName: label)
            env.savedSearches.add(name: label, query: "", spec: spec)
            let saved = String(localized: "Saved search “\(label)” — run it again from the Archive sidebar.")
            return await findAndExport(preview, format: format, destination: destination, recipe: .collectAndHandOver, notes: [saved])
        } catch {
            return failed(.collectAndHandOver, started: started, kind: .search, error.localizedDescription)
        }
    }

    private func export(_ preview: RecipeSearchPreview, format: PracticalExportFormat, destination: URL) async -> RecipeResultFacts {
        let started = Date()
        guard !Task.isCancelled else { return cancelledFacts(.export, "Export cancelled before it started") }
        guard let policy = env.policy else {
            return RecipeResultFacts(report: .init(kind: .export, outcome: .failed, receipt: .init(kind: .none, id: ""),
                                                   summary: PracticalRecipeError.planUnknown.localizedDescription, reportedAt: Date()),
                                     outcome: .failed)
        }
        let scope = ArchiveSelectionScope.query(preview.selection.query, exclusions: [])
        let cap = policy.exportCap(for: format.unified)
        let service = ArchiveExportService(archive: env.archive)
        let progress: @MainActor @Sendable (Int, Int) -> Void = { [weak self] done, total in self?.onProgress?("export", done, total) }
        var result: ArchiveExportResult?
        var errorText: String?
        do {
            switch format {
            case .emlFolder:
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                result = try await service.exportEMLFiles(scope: scope, to: destination, limit: cap, onProgress: progress)
            case .mboxFile:
                result = try await service.exportMBOXArchive(scope: scope, to: destination, limit: cap, onProgress: progress)
            }
        } catch is CancellationError {
            result = nil
        } catch {
            errorText = error.localizedDescription
        }
        let requested = (try? await env.archive.count(scope: scope)) ?? preview.matches
        let written = result?.recordsWritten ?? 0
        let cancelled = result?.cancelled == true || Task.isCancelled || (result == nil && errorText == nil)
        var outcome: ExportReceipt.Outcome = .complete
        var reasons: [String] = []
        if cancelled {
            outcome = .cancelled
            reasons.append("cancelled — \(written) of \(requested) written before the stop")
        } else if errorText != nil {
            outcome = .failed
        } else if let cap, requested > cap {
            outcome = .truncated
            reasons.append("\(requested - written) not written — the Free plan exports up to \(cap) messages per run")
        } else if written < requested, result?.completed == false {
            outcome = .failed
        } else if let withheld = result?.withheld, withheld > 0 {
            outcome = .partial
            reasons.append("\(withheld) withheld: content not decoded at import — export them as MBOX or EML")
        }
        if let skipped = result?.skipped, skipped > 0 { reasons.append("\(skipped) produced no output from the writer") }
        if let failure = result?.inventoryFailure {
            if outcome == .complete { outcome = .unverified }
            reasons.append("the inventory file could not be written (\(failure))")
        }
        // Verify what is on disk now — a full re-hash, never sampled.
        var verificationLine: String?
        var passed: Bool?
        if !cancelled, errorText == nil {
            switch format {
            case .emlFolder:
                if result?.inventoryURL != nil, let v = try? ExportInventory.verify(folder: destination) {
                    verificationLine = ExportRunCenter.verificationText(v)
                    passed = v.isClean
                } else {
                    verificationLine = String(localized: "Verification could not run: the export has no inventory")
                    passed = false
                }
            case .mboxFile:
                verificationLine = await ExportRunCenter.fileRehashText(file: destination, recorded: result?.sha256Hex)
                passed = (try? ExportInventory.sha256(of: destination)).map { $0.lowercased() == result?.sha256Hex?.lowercased() } ?? false
            }
        }
        var receipt = ExportReceipt(
            title: "\(format == .emlFolder ? "EML" : "mbox") export", destination: destination.path, isFolder: format == .emlFolder,
            requested: requested, written: written, bytesWritten: result?.bytesWritten, outcome: outcome,
            sha256Hex: result?.sha256Hex, errorMessage: errorText, startedAt: started, completedAt: Date(),
            checked: result?.inventoryURL != nil ? written : nil, excluded: result.map { $0.withheld + $0.skipped },
            inventoryPath: result?.inventoryURL?.path, selectionFrozen: true)
        receipt.verificationLine = verificationLine
        receipt.sourceLine = preview.sourceLine
        receipt.coverageLine = preview.coverage
        receipt.skippedReasons = reasons
        return readBack(receipt, passed: passed)
    }

    /// Rule 5 / REC-05: the receipt is saved, then the result is READ BACK from it.
    private func readBack(_ receipt: ExportReceipt, passed: Bool?) -> RecipeResultFacts {
        do {
            let url = try env.exportReceipts.save(receipt)
            let stored = try env.exportReceipts.load(url)
            var facts = RecipeResultFacts(export: stored, receiptPath: url.path, outcome: PersistedReceiptVerifier.outcome(of: stored))
            facts.verificationPassed = passed
            return facts
        } catch {
            var facts = RecipeResultFacts(export: receipt, receiptPath: nil, outcome: .unverifiable)
            facts.verification = String(localized: "The receipt could not be saved: \(error.localizedDescription)")
            facts.verificationPassed = false
            return facts
        }
    }

    // MARK: 2 — find and save attachments

    /// Every attachment of the frozen matches, and every recorded file inside
    /// one, streamed a batch at a time; files that meet the conditions are flagged.
    func fileCandidates(_ preview: RecipeSearchPreview) async throws -> [RecipeFileCandidate] {
        var out: [RecipeFileCandidate] = []
        for try await batch in env.archive.streamSelected(scope: .query(preview.selection.query, exclusions: [])) {
            try Task.checkCancellation()
            for email in batch {
                let children = await env.archive.attachmentChildren(emailID: email.id)
                out.append(contentsOf: RecipeFileBrowser.candidates(email: email, children: children, spec: preview.spec))
            }
        }
        return out
    }

    /// Saves exactly the files chosen, under safe unique names, writes the
    /// byte inventory beside them, re-hashes every file and records the
    /// receipt. Locked, unreadable or over-allowance files are named with why.
    func saveFiles(_ chosen: [RecipeFileCandidate], preview: RecipeSearchPreview, to folder: URL) async -> PracticalRecipeResult {
        let started = Date()
        guard let policy = env.policy else { return failed(.saveAttachments, started: started, kind: .export, PracticalRecipeError.planUnknown.localizedDescription) }
        var reasons: [String] = []
        var files: [ExportInventory.File] = []
        var used = Set<String>()
        var bytesTotal = 0
        var cancelled = false
        let usedToday = env.defaults.integer(forKey: AttachmentDownloadGate.usedTodayKey)
        var remaining = AttachmentDownloadGate.decide(policy: policy, usedToday: usedToday).remainingToday
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { return failed(.saveAttachments, started: started, kind: .export, error.localizedDescription) }
        // Group by message so each message is read once.
        let byEmail = Dictionary(grouping: chosen, by: \.emailID)
        var done = 0
        var order: [EmailID] = []
        for item in chosen where !order.contains(item.emailID) { order.append(item.emailID) }
        for emailID in order {
            if Task.isCancelled { cancelled = true; break }
            let items = byEmail[emailID] ?? []
            guard let email = try? await env.archive.fullEmails(ids: [emailID]).first else {
                for item in items { reasons.append("\(item.filename) — the message could not be read from the archive") }
                continue
            }
            for item in items {
                if Task.isCancelled { cancelled = true; break }
                if item.isLocked {
                    reasons.append("\(item.filename) (\(item.location)) — locked: the file inside the attachment needs its password; unlock it from the message, then save again")
                    continue
                }
                if let r = remaining, r <= 0 {
                    reasons.append("\(item.filename) — not saved: today's Free attachment saves are used")
                    continue
                }
                let temp: Result<URL, EvidenceAttachmentOpener.Failure> = item.childPath.map {
                    EvidenceAttachmentOpener.temporaryFile(for: email, ordinal: item.ordinal, childPath: $0)
                } ?? EvidenceAttachmentOpener.temporaryFile(for: email, ordinal: item.ordinal)
                switch temp {
                case .failure(let why):
                    reasons.append("\(item.filename) (\(item.location)) — \(why.message)")
                case .success(let tempURL):
                    let name = RecipeFileBrowser.uniqueSafeName(item.filename, used: &used)
                    let target = folder.appendingPathComponent(name)
                    do {
                        if FileManager.default.fileExists(atPath: target.path) { throw CocoaError(.fileWriteFileExists) }
                        try FileManager.default.copyItem(at: tempURL, to: target)
                        let size = ((try? FileManager.default.attributesOfItem(atPath: target.path)[.size]) as? NSNumber)?.intValue ?? 0
                        files.append(ExportInventory.File(path: name, bytes: size, sha256: try ExportInventory.sha256(of: target),
                                                          emailID: emailID.uuidString, messageID: email.headers["Message-ID"],
                                                          originalFolder: item.childPath.map { "\(email.attachments[item.ordinal].filename) › \($0)" }))
                        bytesTotal += size
                        AttachmentDownloadGate.recordSave(policy: policy, defaults: env.defaults)
                        if let r = remaining { remaining = r - 1 }
                    } catch {
                        reasons.append("\(item.filename) — could not be written: \(error.localizedDescription)")
                    }
                    try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent())
                }
            }
            done += items.count
            onProgress?("files", done, chosen.count)
        }
        // The byte inventory beside the files, then a full re-hash.
        var verificationLine: String?
        var passed: Bool?
        var inventoryPath: String?
        let inventory = ExportInventory(createdAt: Date(), layout: "recipe-attachments", written: files.count, withheld: 0,
                                        skipped: reasons.count, positionsConsumed: chosen.count, files: files)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let url = folder.appendingPathComponent(ExportInventory.filename)
            try encoder.encode(inventory).write(to: url, options: .atomic)
            inventoryPath = url.path
            if !cancelled {
                let v = try ExportInventory.verify(folder: folder)
                verificationLine = ExportRunCenter.verificationText(v)
                passed = v.isClean
            }
        } catch {
            reasons.append("the inventory file could not be written (\(error.localizedDescription))")
            passed = false
        }
        let outcome: ExportReceipt.Outcome = cancelled ? .cancelled
            : inventoryPath == nil ? .unverified
            : (files.count < chosen.count ? .partial : .complete)
        var receipt = ExportReceipt(title: "Attachment save", destination: folder.path, isFolder: true, requested: chosen.count,
                                    written: files.count, bytesWritten: bytesTotal, outcome: outcome, startedAt: started, completedAt: Date(),
                                    checked: files.count, excluded: reasons.count, inventoryPath: inventoryPath, selectionFrozen: true)
        receipt.verificationLine = verificationLine
        receipt.sourceLine = preview.sourceLine + " · " + String(localized: "\(chosen.filter(\.isNested).count) of \(chosen.count) chosen files are inside attachments")
        receipt.coverageLine = preview.coverage
        receipt.skippedReasons = reasons
        return finish(.saveAttachments, started: started, facts: [preview.facts, readBack(receipt, passed: passed)])
    }

    // MARK: 3 — archive and safely clean up (local only)

    /// The duplicate classification for the frozen matches (or the whole
    /// archive): only extra copies VERIFIED identical are offered.
    func cleanupPlan(_ preview: RecipeSearchPreview?) async throws -> RecipeCleanupPlan {
        var groups = try await DuplicateManagerView.withoutTrashed(try await env.store.messageIDDuplicateGroups(), store: env.store)
        if let preview {
            groups = try await RecipeFrozenScope.restrict(groups: groups, to: preview.selection.query, archive: env.archive)
        }
        let archive = env.archive
        let result = try await DuplicateVerification.verifyArchiveWide(groups: groups) { ids in try await archive.fullEmails(ids: ids) }
        return RecipeCleanupPlan(plans: result.plans, removable: result.removable.count, verifiedGroups: result.verifiedGroups,
                                 candidateGroups: result.candidateGroups,
                                 sourceLine: preview?.sourceLine ?? String(localized: "The whole archive"))
    }

    /// Moves the plan's verified extra copies to the Trash (restorable) after
    /// the person confirmed the count; the registry document is posted only
    /// after the move happened, and the move is checked in the store.
    func cleanUp(_ plan: RecipeCleanupPlan, preview: RecipeSearchPreview?) async -> PracticalRecipeResult {
        let started = Date()
        var facts: [RecipeResultFacts] = preview.map { [$0.facts] } ?? []
        guard !Task.isCancelled else {
            return finish(.cleanUpDuplicates, started: started, facts: facts + [cancelledFacts(.dedupe, "Clean-up cancelled — nothing was moved")])
        }
        guard let policy = env.policy else { return failed(.cleanUpDuplicates, started: started, kind: .dedupe, PracticalRecipeError.planUnknown.localizedDescription) }
        guard PracticalRecipeKind.cleanUpDuplicates.isEntitled(policy) else {
            return failed(.cleanUpDuplicates, started: started, kind: .dedupe, PracticalRecipeError.notEntitled.localizedDescription)
        }
        if plan.plans.isEmpty {
            var f = RecipeResultFacts(report: .init(kind: .dedupe, outcome: .succeeded,
                                                    receipt: .init(kind: .measurement, id: "0 verified duplicate copies"),
                                                    summary: "Checked: 0 verified duplicate copies to move", count: 0, reportedAt: Date()),
                                      outcome: .succeeded)
            f.source = plan.sourceLine
            f.requested = 0
            f.verification = "nothing to move"
            f.verificationPassed = true
            if plan.candidateGroups > 0 { f.skipped = ["\(plan.candidateGroups) groups share a Message-ID but differ in content — kept for review"] }
            facts.append(f)
            return finish(.cleanUpDuplicates, started: started, facts: facts)
        }
        do {
            let result = try await env.store.removeDuplicateCopies(plan.plans)
            let summary = DuplicateManagerView.receiptSummary(result)
            let number = result.trashed.isEmpty ? nil : await env.postDocument(.cleanup, summary)
            // Check the move in the store: every moved copy is in the Trash, every kept copy is not.
            let states = try await env.store.reviewStates(ids: result.trashed + plan.plans.map(\.survivor))
            let inTrash = result.trashed.filter { states[$0]?.trashed == true }.count
            let survivorsKept = plan.plans.allSatisfy { states[$0.survivor]?.trashed != true }
            let documentFound = await number.asyncMap(env.documentExists) ?? false
            var f = RecipeResultFacts(report: .init(kind: .dedupe, outcome: number == nil ? .unverifiable : .succeeded,
                                                    receipt: .init(kind: number == nil ? .none : .registryDocument, id: number ?? ""),
                                                    summary: "\(number ?? "no receipt"): \(summary)", count: result.trashed.count, reportedAt: Date()),
                                      outcome: number == nil || !documentFound ? .unverifiable : .succeeded)
            f.source = plan.sourceLine
            f.requested = plan.removable
            f.destination = String(localized: "the archive's Trash (restorable)")
            f.verification = "\(inTrash) of \(result.trashed.count) moved copies are in the Trash; kept copies \(survivorsKept ? "stay in place" : "NOT all in place"); registry document \(number ?? "—") \(documentFound ? "found" : "not found")"
            f.verificationPassed = inTrash == result.trashed.count && survivorsKept && documentFound
            var reasons: [String] = []
            if !result.heldKept.isEmpty { reasons.append("\(result.heldKept.count) copies kept — under legal hold") }
            if plan.candidateGroups > 0 { reasons.append("\(plan.candidateGroups) groups share a Message-ID but differ in content — kept for review") }
            f.skipped = reasons
            facts.append(f)
            return finish(.cleanUpDuplicates, started: started, facts: facts)
        } catch {
            return finish(.cleanUpDuplicates, started: started,
                          facts: facts + [RecipeResultFacts(report: .init(kind: .dedupe, outcome: .failed, receipt: .init(kind: .none, id: ""),
                                                                          summary: "Duplicate removal failed — nothing was changed: \(error.localizedDescription)",
                                                                          reportedAt: Date()), outcome: .failed)])
        }
    }

    // MARK: 4 — back up and restore (into an isolated profile)

    /// Writes `mailin-backup-<date>` inside `parent`, then checks it by restoring.
    func backUpAndCheck(parent: URL) async -> PracticalRecipeResult {
        let started = Date()
        guard !Task.isCancelled else { return finish(.backUpAndRestore, started: started, facts: [cancelledFacts(.backup, "Backup cancelled")]) }
        let destination = ArchiveBackups.backupDestination(parent: parent)
        do {
            onProgress?("backup", 0, 1)
            _ = try await ArchiveBackup.create(store: env.store, to: destination, receiptDirectories: env.receiptDirectories)
            onProgress?("backup", 1, 1)
        } catch {
            return failed(.backUpAndRestore, started: started, kind: .backup, "Backup failed: \(error.localizedDescription)")
        }
        let backupOutcome = PersistedReceiptVerifier.inventoryOutcome(at: destination) ?? .unverifiable
        var backup = RecipeResultFacts(backupFolder: destination, restore: false, outcome: backupOutcome)
        if Task.isCancelled {
            return finish(.backUpAndRestore, started: started, facts: [backup, cancelledFacts(.restore, "Restore check cancelled — the backup was written")])
        }
        let check = await restoreCheck(destination)
        if let rehash = check.rehash { backup.verification = rehash; backup.verificationPassed = check.rehashClean }
        return finish(.backUpAndRestore, started: started, facts: [backup, check.facts])
    }

    /// Checks an existing backup by restoring it into an isolated, empty profile.
    func checkBackup(_ folder: URL) async -> PracticalRecipeResult {
        let started = Date()
        guard !Task.isCancelled else { return finish(.backUpAndRestore, started: started, facts: [cancelledFacts(.restore, "Restore check cancelled")]) }
        let check = await restoreCheck(folder)
        return finish(.backUpAndRestore, started: started, facts: [check.facts])
    }

    /// Verify every hash, restore into a fresh folder nothing else uses, open
    /// it, count what it holds and compare with the inventory. The live
    /// archive is not touched; the isolated copy is removed afterwards.
    private func restoreCheck(_ folder: URL) async -> (facts: RecipeResultFacts, rehash: String?, rehashClean: Bool) {
        var facts = RecipeResultFacts(backupFolder: folder, restore: true, outcome: .failed)
        let verification: ArchiveBackup.Verification
        do { verification = try ArchiveBackup.verify(backup: folder) } catch {
            facts.verification = error.localizedDescription
            facts.verificationPassed = false
            return (facts, nil, false)
        }
        let rehash = "rehash checked: \(verification.inventory.files.count - verification.problems.count) of \(verification.inventory.files.count) files match"
        guard verification.isClean else {
            facts.verification = rehash
            facts.verificationPassed = false
            facts.skipped = verification.problems
            return (facts, rehash, false)
        }
        let isolated = env.scratch.appendingPathComponent("mailin-restore-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: isolated) }
        do {
            onProgress?("restore", 0, 1)
            try ArchiveBackup.restore(backup: folder, intoStoreDirectory: isolated, mode: .cleanProfile)
            let restored = SQLiteEmailStore(directory: isolated)
            let counts = try await restored.backupCounts()
            await restored.reopenConnection()
            onProgress?("restore", 1, 1)
            let expected = verification.inventory.counts
            let differences = Self.differences(expected: expected, restored: counts)
            facts.outcome = differences.isEmpty ? .succeeded : .partial
            facts.completed = counts.emails
            facts.requested = expected.emails
            facts.destination = String(localized: "a separate empty profile (removed after the check)")
            facts.verification = rehash + " · " + (differences.isEmpty
                ? "restored into a separate empty profile: \(counts.emails) emails, \(counts.attachments) attachments, \(counts.folders) folders — all equal to the inventory"
                : "restored into a separate empty profile: \(differences.count) counts differ from the inventory")
            facts.verificationPassed = differences.isEmpty
            facts.skipped = differences
            facts.summary = "restore check of \(folder.lastPathComponent): \(counts.emails) of \(expected.emails) emails"
        } catch {
            facts.outcome = .failed
            facts.verification = rehash + " · " + "restore into a separate profile failed: \(error.localizedDescription)"
            facts.verificationPassed = false
        }
        return (facts, rehash, true)
    }

    static func differences(expected e: ArchiveBackupInventory.Counts, restored r: ArchiveBackupInventory.Counts) -> [String] {
        var out: [String] = []
        func cmp(_ name: String, _ a: Int, _ b: Int) { if a != b { out.append("\(name): inventory \(a), restored \(b)") } }
        cmp("emails", e.emails, r.emails); cmp("attachments", e.attachments, r.attachments)
        cmp("folders", e.folders, r.folders); cmp("folder memberships", e.folderMemberships, r.folderMemberships)
        cmp("tags", e.userTags, r.userTags); cmp("notes", e.annotations, r.annotations)
        cmp("legal holds", e.legalHolds, r.legalHolds); cmp("sources", e.sources, r.sources)
        cmp("located messages", e.locatorBacked, r.locatorBacked)
        return out
    }

    // MARK: Helpers

    private func cancelledFacts(_ kind: RecipeJobKind, _ line: String) -> RecipeResultFacts {
        RecipeResultFacts(report: .init(kind: kind, outcome: .cancelled, receipt: .init(kind: .none, id: ""), summary: line, reportedAt: Date()),
                          outcome: .cancelled)
    }

    private func failed(_ recipe: PracticalRecipeKind, started: Date, kind: RecipeJobKind, _ line: String) -> PracticalRecipeResult {
        finish(recipe, started: started, facts: [RecipeResultFacts(report: .init(kind: kind, outcome: .failed, receipt: .init(kind: .none, id: ""),
                                                                                 summary: line, reportedAt: Date()), outcome: .failed)])
    }

    /// The state follows the facts; the result is kept on disk so it reads the same after a restart.
    private func finish(_ recipe: PracticalRecipeKind, started: Date, facts: [RecipeResultFacts], notes: [String] = []) -> PracticalRecipeResult {
        var result = PracticalRecipeResult(recipe: recipe, state: PracticalRecipeResult.state(of: facts), startedAt: started,
                                           finishedAt: Date(), facts: facts, notes: notes)
        do { try env.results.save(result) } catch {
            result.notes.append(String(localized: "This result could not be kept on disk: \(error.localizedDescription)"))
        }
        return result
    }
}

private extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async -> T) async -> T? {
        guard let value = self else { return nil }
        return await transform(value)
    }
}
