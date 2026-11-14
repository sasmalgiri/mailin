@testable import ArchiveCore
import AppIntents
import Foundation

//
//  MailinMoreEntities.swift
//  maxmailin
//
//  3.0 B5: Shortcuts can pick a Tag, a legal-hold Matter or an issued Document
//  (WF-, EXP-, LH-… numbers), each listed from the whole archive with its exact
//  count. "Find Emails with Tag" returns emails; "Get Document" returns the
//  document's text. Same switch, purchase and role checks as every other
//  mailin action.
//

// MARK: - Tag

struct TagEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Tag"
    static var defaultQuery = TagEntityQuery()

    var id: String
    @Property(title: "Emails") var count: Int

    init(tag: String, count: Int) { id = tag; self.count = count }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(id)", subtitle: "\(count) emails")
    }
}

struct TagEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [TagEntity] {
        try ShortcutsPolicy.requireEnabled()
        let all = try await Self.all()
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }
    func entities(matching string: String) async throws -> [TagEntity] {
        try ShortcutsPolicy.requireEnabled()
        return try await Self.all().filter { $0.id.localizedCaseInsensitiveContains(string) }
    }
    func suggestedEntities() async throws -> [TagEntity] {
        try ShortcutsPolicy.requireEnabled()
        return try await Self.all()
    }
    static func all() async throws -> [TagEntity] {
        guard await ScopeJobEnvironment.archiveReady() else { throw ShortcutsActionError.notReady }
        return try await ScopeJobEnvironment.store.userTagCounts().map { TagEntity(tag: $0.tag, count: $0.count) }
    }
}

// MARK: - Matter

struct MatterEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Legal Hold Matter"
    static var defaultQuery = MatterEntityQuery()

    var id: String
    @Property(title: "Emails on Hold") var count: Int
    @Property(title: "First Hold Placed") var firstPlaced: Date

    init(matter: String, count: Int, firstPlaced: Date) {
        id = matter
        self.count = count
        self.firstPlaced = firstPlaced
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(id.isEmpty ? String(localized: "Hold (no matter name)") : id)",
                              subtitle: "\(count) emails on hold")
    }
}

struct MatterEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [MatterEntity] {
        try ShortcutsPolicy.requireEnabled()
        let all = try await Self.all()
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }
    func entities(matching string: String) async throws -> [MatterEntity] {
        try ShortcutsPolicy.requireEnabled()
        return try await Self.all().filter { $0.id.localizedCaseInsensitiveContains(string) }
    }
    func suggestedEntities() async throws -> [MatterEntity] {
        try ShortcutsPolicy.requireEnabled()
        return try await Self.all()
    }
    static func all() async throws -> [MatterEntity] {
        guard await ScopeJobEnvironment.archiveReady() else { throw ShortcutsActionError.notReady }
        return try await ScopeJobEnvironment.store.legalHoldMatters().map {
            MatterEntity(matter: $0.matter, count: $0.count, firstPlaced: $0.firstPlaced)
        }
    }
}

// MARK: - Document

struct DocumentEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "mailin Document"
    static var defaultQuery = DocumentEntityQuery()

    var id: String
    @Property(title: "Type") var type: String
    @Property(title: "Summary") var summary: String
    @Property(title: "Created") var created: Date

    init(_ d: SQLiteEmailStore.IssuedDocument) {
        id = d.number
        type = d.type
        summary = d.summary
        created = d.createdAt
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(id)", subtitle: "\(summary)")
    }
}

struct DocumentEntityQuery: EntityStringQuery {
    /// Suggestions are the newest documents; a typed search reaches every one.
    static let suggestionCount = 50

    func entities(for identifiers: [String]) async throws -> [DocumentEntity] {
        try ShortcutsPolicy.requireEnabled()
        guard await ScopeJobEnvironment.archiveReady() else { throw ShortcutsActionError.notReady }
        var out: [DocumentEntity] = []
        for id in identifiers {
            if let d = try await ScopeJobEnvironment.store.lookupDocuments(matching: id, limit: 50).first(where: { $0.number == id }) {
                out.append(DocumentEntity(d))
            }
        }
        return out
    }
    func entities(matching string: String) async throws -> [DocumentEntity] {
        try ShortcutsPolicy.requireEnabled()
        guard await ScopeJobEnvironment.archiveReady() else { throw ShortcutsActionError.notReady }
        let total = try await ScopeJobEnvironment.store.documentCount(matching: string)
        var out: [DocumentEntity] = []
        var offset = 0
        while offset < total {
            let page = try await ScopeJobEnvironment.store.lookupDocuments(matching: string, limit: 500, offset: offset)
            if page.isEmpty { break }
            out += page.map(DocumentEntity.init)
            offset += page.count
        }
        return out
    }
    func suggestedEntities() async throws -> [DocumentEntity] {
        try ShortcutsPolicy.requireEnabled()
        guard await ScopeJobEnvironment.archiveReady() else { throw ShortcutsActionError.notReady }
        return try await ScopeJobEnvironment.store.recentDocuments(limit: Self.suggestionCount).map(DocumentEntity.init)
    }
}

// MARK: - Actions

struct FindEmailsWithTagIntent: AppIntent {
    static var title: LocalizedStringResource = "Find Emails with Tag in mailin"
    static var description: IntentDescription = "Returns the emails carrying a tag, newest first (up to 10,000 per run; Count Emails gives the exact total)."

    @Parameter(title: "Tag") var tag: TagEntity

    func perform() async throws -> some IntentResult & ReturnsValue<[EmailEntity]> {
        try ShortcutsPolicy.requireEnabled()
        guard await ScopeJobEnvironment.archiveReady() else { throw ShortcutsActionError.notReady }
        var q = EmailQuery()
        q.userTag = tag.id          // set directly: any tag text, quotes included
        var out: [EmailEntity] = []
        // CAP-05: every email with the tag; Shortcuts' own Limit bounds it when wanted.
        for try await page in await ScopeJobEnvironment.archive.streamSummaries(query: q, batchSize: 500) {
            let rec = (try? await ScopeJobEnvironment.store.recovery(for: page.map(\.id))) ?? [:]
            out += page.map { EmailEntity(summary: $0, recovered: rec[$0.id] != nil) }
        }
        return .result(value: out)
    }
}

struct GetDocumentIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Document from mailin"
    static var description: IntentDescription = "Returns the text of a numbered mailin document (workflow record, export record, hold notice, report)."

    @Parameter(title: "Document") var document: DocumentEntity

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try ShortcutsPolicy.requireEnabled()
        try ShortcutsActionSupport.allow(.export)
        guard await ScopeJobEnvironment.archiveReady() else { throw ShortcutsActionError.notReady }
        let payload = try await ScopeJobEnvironment.store.documentPayload(document.id)
        let text = payload?.body ?? "\(document.id) · \(document.type) · \(document.summary)"
        await MainActor.run { ScopeJobEnvironment.logAction("Shortcuts document read", detail: document.id) }
        return .result(value: text)
    }
}
