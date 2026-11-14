@testable import ArchiveCore
import AppIntents
import Foundation

//
//  MailinAppEntities.swift
//  maxmailin
//
//  3.1 S1–S4 (switch: `v31ShortcutsActions`, preview, off).
//
//  S1 — `EmailEntity` with an `EntityPropertyQuery`: Shortcuts gets an automatic
//  "Find Emails" action filtering on sender, subject, date, attachments and
//  recovered — answered by SQL over the whole archive, page by page.
//  S2 — action intents: count, tag, place a legal hold, export CSV. Each one
//  goes through `OrgPolicy`, asks for confirmation with the exact count
//  first (rule 4), runs through the scope engine (S3: progress, cancel,
//  receipt) and writes its audit entry only after the work happened.
//  S4 — every action is usable from Terminal: `shortcuts run "<shortcut>"`
//  (see SHORTCUTS_AUTOMATION.md).
//

/// Pushed by CapabilityWiring; intents can run without any view on screen.
enum ShortcutsPolicy {
    nonisolated(unsafe) static var actionsEnabled = false
    /// CAP-05: Find has no cap of its own. Shortcuts' own "Limit" option on
    /// the Find action bounds the list when the person wants it; without it,
    /// every match is returned (a Shortcuts list lives in memory — that is
    /// the person's call, stated in the action's description).
    static func effectiveFindLimit(_ requested: Int?) -> Int { requested ?? Int.max }

    static func requireEnabled() throws {
        guard actionsEnabled else { throw ShortcutsActionError.switchedOff }
        guard TierAccess.allows(.shortcutsActions) else { throw ShortcutsActionError.needsPurchase }
    }
}

enum ShortcutsActionError: Error, CustomLocalizedStringResourceConvertible {
    case switchedOff
    case needsPurchase
    case notReady
    case denied(String)
    case failed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .switchedOff: return "Shortcuts actions are off. Turn them on in mailin ▸ Settings ▸ Modules."
        case .needsPurchase: return "Shortcuts actions are part of mailin Professional."
        case .notReady: return "mailin's archive isn't ready yet. Open mailin once, then try again."
        case .denied(let why): return "\(why)"
        case .failed(let why): return "\(why)"
        }
    }
}

// MARK: - S1 Email entity

struct EmailEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Email"
    static var defaultQuery = EmailEntityQuery()

    var id: UUID
    @Property(title: "Subject") var subject: String
    @Property(title: "From") var from: String
    @Property(title: "Date") var date: Date
    @Property(title: "Has Attachments") var hasAttachments: Bool
    @Property(title: "Recovered") var recovered: Bool
    @Property(title: "Preview") var preview: String

    init(summary s: EmailSummary, recovered: Bool) {
        id = s.id
        subject = s.subject
        from = s.from
        date = s.date
        hasAttachments = s.hasAttachments
        self.recovered = recovered
        preview = s.bodyPreview
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(subject.isEmpty ? "(no subject)" : subject)",
                              subtitle: "\(from) · \(date.formatted(date: .abbreviated, time: .shortened))")
    }
}

/// One Shortcuts filter row, mapped onto `EmailQuery`.
enum EmailEntityClause: Sendable {
    case sender(String), subject(String), text(String)
    case after(Date), before(Date)
    case hasAttachments(Bool), recovered(Bool)

    func apply(to q: inout EmailQuery) {
        switch self {
        case .sender(let s): q.sender = s
        case .subject(let s): q.subjectContains = s
        case .text(let s): q.text = s
        case .after(let d): q.afterDate = d
        case .before(let d): q.beforeDate = d
        case .hasAttachments(let b): q.hasAttachments = b
        case .recovered(let b):
            if b { q.recovery = "any" } else {
                q.exclusions = (q.exclusions ?? []) + [EmailExclusion(field: .recovered, value: "any")]
            }
        }
    }
}

struct EmailEntityQuery: EntityPropertyQuery {
    typealias ComparatorMappingType = EmailEntityClause

    static var properties = QueryProperties {
        Property(\EmailEntity.$from) {
            ContainsComparator { EmailEntityClause.sender($0) }
            EqualToComparator { EmailEntityClause.sender($0) }
        }
        Property(\EmailEntity.$subject) {
            ContainsComparator { EmailEntityClause.subject($0) }
        }
        Property(\EmailEntity.$preview) {
            ContainsComparator { EmailEntityClause.text($0) }
        }
        Property(\EmailEntity.$date) {
            GreaterThanComparator { EmailEntityClause.after($0) }
            LessThanComparator { EmailEntityClause.before($0) }
        }
        Property(\EmailEntity.$hasAttachments) {
            EqualToComparator { EmailEntityClause.hasAttachments($0) }
        }
        Property(\EmailEntity.$recovered) {
            EqualToComparator { EmailEntityClause.recovered($0) }
        }
    }

    static var sortingOptions = SortingOptions {
        SortableBy(\EmailEntity.$date)
    }

    func entities(for identifiers: [UUID]) async throws -> [EmailEntity] {
        try ShortcutsPolicy.requireEnabled()
        let found = try await ScopeJobEnvironment.archive.summaries(ids: identifiers)
        let rec = (try? await ScopeJobEnvironment.store.recovery(for: identifiers)) ?? [:]
        return found.map { EmailEntity(summary: $0, recovered: rec[$0.id] != nil) }
    }

    func suggestedEntities() async throws -> [EmailEntity] {
        try ShortcutsPolicy.requireEnabled()
        return try await Self.find([], mode: .and, limit: 20)
    }

    func entities(matching comparators: [EmailEntityClause], mode: ComparatorMode,
                  sortedBy: [EntityQuerySort<EmailEntity>], limit: Int?) async throws -> [EmailEntity] {
        try ShortcutsPolicy.requireEnabled()
        return try await Self.find(comparators, mode: mode, limit: ShortcutsPolicy.effectiveFindLimit(limit))
    }

    /// "All" = one query; "any" = one query per clause, merged without repeats.
    static func find(_ clauses: [EmailEntityClause], mode: ComparatorMode, limit: Int) async throws -> [EmailEntity] {
        guard await ScopeJobEnvironment.archiveReady() else { throw ShortcutsActionError.notReady }
        let queries: [EmailQuery]
        if mode == .or, clauses.count > 1 {
            queries = clauses.map { c in var q = EmailQuery(); c.apply(to: &q); return q }
        } else {
            var q = EmailQuery()
            for c in clauses { c.apply(to: &q) }
            queries = [q]
        }
        var seen = Set<UUID>()
        var out: [EmailEntity] = []
        for q in queries {
            for try await page in await ScopeJobEnvironment.archive.streamSummaries(query: q, batchSize: 500) {
                let fresh = page.filter { seen.insert($0.id).inserted }
                let rec = (try? await ScopeJobEnvironment.store.recovery(for: fresh.map(\.id))) ?? [:]
                out.append(contentsOf: fresh.map { EmailEntity(summary: $0, recovered: rec[$0.id] != nil) })
                if out.count >= limit { return Array(out.prefix(limit)) }
            }
        }
        return out
    }
}

// MARK: - S2 Action intents

/// Shared: compile the search text, check the switch and the role, count.
enum ShortcutsActionSupport {
    static func scope(_ search: String) async throws -> (ArchiveScope, Int) {
        try ShortcutsPolicy.requireEnabled()
        guard await ScopeJobEnvironment.archiveReady() else { throw ShortcutsActionError.notReady }
        let q = ArchiveQueryCompiler.compile(search)
        let n = try await ScopeJobEnvironment.archive.count(query: q)
        return (ArchiveScope(query: q, total: n, loaded: nil), n)
    }

    /// Count-before-action prompt (rule 4); throws when the person cancels.
    /// Before macOS 15 / iOS 18 the prompt confirms the search parameter.
    static func confirm<I: AppIntent>(_ intent: I, _ dialog: IntentDialog,
                                      older: () async throws -> Bool) async throws {
        if #available(macOS 15.0, iOS 18.0, *) {
            try await intent.requestConfirmation(dialog: dialog)
        } else if try await !older() {
            throw CancellationError()
        }
    }

    static func allow(_ permission: OrgPermission) throws {
        if let why = OrgPolicy.denial(permission) { throw ShortcutsActionError.denied(why) }
    }

    /// "X of Y" when a run stopped early (rule 5).
    static func line(_ verb: String, done: Int, total: Int, receipt: ScopeJobReceipt) -> String {
        receipt.cancelled
            ? String(localized: "\(verb) \(receipt.processed) of \(total) emails before the run stopped. Fingerprint \(receipt.fingerprint).")
            : String(localized: "\(verb) \(done) of \(total) emails. Fingerprint \(receipt.fingerprint).")
    }
}

struct CountEmailsIntent: AppIntent {
    static var title: LocalizedStringResource = "Count Emails in mailin"
    static var description: IntentDescription = "Counts every email in the archive that matches a search (mailin search syntax, e.g. from:anna has:attachment)."

    @Parameter(title: "Search", default: "")
    var search: String

    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let (_, n) = try await ShortcutsActionSupport.scope(search)
        return .result(value: n, dialog: "\(n) emails match.")
    }
}

struct TagEmailsIntent: AppIntent {
    static var title: LocalizedStringResource = "Tag Emails in mailin"
    static var description: IntentDescription = "Adds a tag to every email matching a search. Shows the number of emails and asks before it runs."

    @Parameter(title: "Search") var search: String
    @Parameter(title: "Tag") var tag: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try ShortcutsActionSupport.allow(.review)
        let (scope, n) = try await ShortcutsActionSupport.scope(search)
        try await ShortcutsActionSupport.confirm(self, "Tag \(n) emails “\(tag)”?") {
            try await $search.requestConfirmation(for: search, dialog: "Tag \(n) emails “\(tag)”?")
        }
        let r = try await BatchOperationsEngine.apply(.add(tag), scope: scope, loaded: [])
        return .result(value: ShortcutsActionSupport.line(String(localized: "Tagged"), done: r.count, total: n, receipt: r.receipt))
    }
}

struct PlaceLegalHoldIntent: AppIntent {
    static var title: LocalizedStringResource = "Place Legal Hold in mailin"
    static var description: IntentDescription = "Places a legal hold on every email matching a search. Shows the number of emails and asks before it runs."

    @Parameter(title: "Search") var search: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try ShortcutsActionSupport.allow(.placeHold)
        let (scope, n) = try await ShortcutsActionSupport.scope(search)
        try await ShortcutsActionSupport.confirm(self, "Place a legal hold on \(n) emails?") {
            try await $search.requestConfirmation(for: search, dialog: "Place a legal hold on \(n) emails?")
        }
        let r = try await EDiscoveryEngine.applyHold(scope: scope)
        return .result(value: ShortcutsActionSupport.line(String(localized: "Held"), done: r.held, total: n, receipt: r.receipt))
    }
}

struct ExportEmailsCSVIntent: AppIntent {
    static var title: LocalizedStringResource = "Export Emails as CSV from mailin"
    static var description: IntentDescription = "Writes every email matching a search to a CSV file (date, from, subject, attachments, preview) and returns the file."

    @Parameter(title: "Search", default: "") var search: String

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        try ShortcutsActionSupport.allow(.export)
        let (scope, n) = try await ShortcutsActionSupport.scope(search)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mailin export \(UUID().uuidString.prefix(8)).csv")
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else {
            throw ShortcutsActionError.failed(String(localized: "The CSV file could not be created."))
        }
        defer { try? handle.close() }
        try handle.write(contentsOf: Data(csvRow(["Email ID", "Date", "From", "Subject", "Attachments", "Preview"]).utf8))
        var written = 0
        // Streamed page by page: memory stays flat at any archive size.
        for try await page in await ScopeJobEnvironment.archive.streamSummaries(query: scope.query, batchSize: 1_000) {
            var chunk = ""
            for s in page {
                chunk += csvRow([s.id.uuidString, s.date.ISO8601Format(), s.from, s.subject,
                                 s.hasAttachments ? "yes" : "no", s.bodyPreview])
            }
            try handle.write(contentsOf: Data(chunk.utf8))
            written += page.count
        }
        guard written == n else {
            throw ShortcutsActionError.failed(String(localized: "The export wrote \(written) of \(n) emails; the archive changed while it ran. Run it again."))
        }
        let detail = "\(written) emails — scope: \(ScopeJob.describe(scope.query))"
        await MainActor.run {
            ScopeJobEnvironment.logAction("Shortcuts CSV export", detail: detail)
        }
        return .result(value: IntentFile(fileURL: url, filename: url.lastPathComponent, type: .commaSeparatedText))
    }
}

struct AssignBatesIntent: AppIntent {
    static var title: LocalizedStringResource = "Assign Bates Numbers in mailin"
    static var description: IntentDescription = "Numbers every email matching a search that has no Bates number yet, oldest first, using the prefix set in mailin. Numbers already given never change. Shows the count and asks first."

    @Parameter(title: "Search") var search: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try ShortcutsActionSupport.allow(.produce)
        let (scope, n) = try await ShortcutsActionSupport.scope(search)
        try await ShortcutsActionSupport.confirm(self, "Number up to \(n) emails?") {
            try await $search.requestConfirmation(for: search, dialog: "Number up to \(n) emails?")
        }
        let r = try await BatesEngine.assign(scope: scope, manager: BatesNumberingManager.shared)
        let range = r.state.first.map { "\($0) – \(r.state.last ?? $0)" } ?? "—"
        return .result(value: String(localized: "\(r.state.assigned) new numbers (\(range)); \(r.state.skipped) already numbered, unchanged. Fingerprint \(r.receipt.fingerprint)."))
    }
}

struct VerifyIntegrityIntent: AppIntent {
    static var title: LocalizedStringResource = "Verify Emails in mailin"
    static var description: IntentDescription = "Checks every email matching a search against its original seal and reports how many passed and failed."

    @Parameter(title: "Search", default: "") var search: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let (scope, n) = try await ShortcutsActionSupport.scope(search)
        let (state, receipt) = try await EDiscoveryEngine.verifyCollection(scope: scope)
        let base = String(localized: "\(state.passed) of \(n) verified, \(state.failed) failed, \(state.newlySealed) sealed for the first time. Fingerprint \(receipt.fingerprint).")
        return .result(value: receipt.cancelled ? String(localized: "Stopped early: ") + base : base)
    }
}
