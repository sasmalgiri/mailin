@testable import ArchiveCore
//
//  ArchiveSidebar.swift
//  maxmailin
//
//  A2: the first pane of the three-pane archive shell. Mailboxes (All mail,
//  Sent, Received, With attachments, Pinned, Trash), the imported sources,
//  the parser labels (Gmail labels, Maildir folders, PST folders) and the
//  saved searches — every row compiles to an `EmailQuery` base that the list
//  pane pages through. Counts come from GROUP BY aggregates, never from a
//  corpus walk.
//

import SwiftUI

// MARK: - Selection

enum ArchiveSidebarSelection: Hashable, Sendable {
    case allMail
    case sent
    case received
    case withAttachments
    case pinned
    case trash
    case source(String)
    case label(String)
    /// FOLD-02: one folder of one source — "Inbox" of two archives are two rows.
    case folder(id: Int64, name: String)
    case saved(UUID)

    /// The archive-wide query this row stands for; the search field and the
    /// date scope are compiled on top by `ArchiveBrowseState`.
    func baseQuery(savedSearches: [ArchiveSavedSearch]) -> EmailQuery {
        var q = EmailQuery.all
        switch self {
        case .allMail:
            break
        case .sent:
            q.messageType = "sent"
        case .received:
            q.messageType = "received"
        case .withAttachments:
            q.hasAttachments = true
        case .pinned:
            q.pinnedOnly = true
        case .trash:
            q.includeTrashed = true
            q.trashedOnly = true
        case .source(let filename):
            q.sourceFileName = filename
        case .label(let tag):
            q.userTag = tag
        case .folder(let id, _):
            q.folderID = id
        case .saved(let id):
            if let saved = savedSearches.first(where: { $0.id == id }) {
                q = ArchiveQueryCompiler.compile(saved.query)
            }
        }
        return q
    }

    var title: String {
        switch self {
        case .allMail: return String(localized: "All Mail")
        case .sent: return String(localized: "Sent")
        case .received: return String(localized: "Received")
        case .withAttachments: return String(localized: "With Attachments")
        case .pinned: return String(localized: "Pinned")
        case .trash: return String(localized: "Trash")
        case .source(let name): return name
        case .label(let tag): return tag
        case .folder(_, let name): return name
        case .saved: return String(localized: "Saved Search")
        }
    }
}

// MARK: - Saved searches

/// Same JSON shape and defaults key as the full list's saved searches, so a
/// search saved in either list appears in both.
struct ArchiveSavedSearch: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var query: String
    /// SEARCH-02: the Advanced Search applied when it was saved — the same
    /// serialised, versioned `SearchSpec` the toolbar edits. Optional so
    /// searches saved before it still decode.
    var spec: SearchSpec? = nil

    /// Everything the saved search asks for: its words compiled as the search
    /// box compiles them, with its Advanced Search on top.
    var runnableQuery: EmailQuery {
        var q = ArchiveQueryCompiler.compile(query)
        if let spec, !spec.isEmpty { q.spec = spec }
        return q
    }

    /// What the search is, in words: the typed text and the conditions.
    var summary: String {
        ArchiveSavedSearch.describe(query: query, spec: spec)
    }

    static func describe(query: String, spec: SearchSpec?) -> String {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let spec, !spec.isEmpty else { return text }
        let conditions = SearchSpecDescriber.summary(spec)
        return text.isEmpty ? conditions : text + " · " + conditions
    }
}

@MainActor
final class ArchiveSavedSearchStore: ObservableObject {
    static let shared = ArchiveSavedSearchStore()
    static let defaultsKey = "mailin_savedSearches"

    @Published private(set) var searches: [ArchiveSavedSearch] = []
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        reload()
    }

    func reload() {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([ArchiveSavedSearch].self, from: data) else {
            searches = []
            return
        }
        searches = decoded
    }

    /// SEARCH-02: keeps the typed words AND the applied Advanced Search.
    func add(name: String, query: String, spec: SearchSpec? = nil) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let liveSpec = (spec?.isEmpty ?? true) ? nil : spec
        guard !trimmed.isEmpty || liveSpec != nil else { return }
        let fallback = ArchiveSavedSearch.describe(query: trimmed, spec: liveSpec)
        let label = name.trimmingCharacters(in: .whitespaces).isEmpty ? fallback : name
        searches.append(ArchiveSavedSearch(id: UUID(), name: label, query: trimmed, spec: liveSpec))
        persist()
    }

    func remove(id: UUID) {
        searches.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(searches) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

// MARK: - Counts and trees

@MainActor
final class ArchiveSidebarModel: ObservableObject {
    @Published private(set) var totalCount = 0
    @Published private(set) var sentCount = 0
    @Published private(set) var receivedCount = 0
    @Published private(set) var attachmentCount = 0
    @Published private(set) var pinnedCount = 0
    @Published private(set) var trashedCount = 0
    @Published private(set) var sources: [SQLiteEmailStore.StoredSource] = []
    /// A6: per-source committed vs indexed, so a source still indexing says so.
    @Published private(set) var coverage: [Int64: SQLiteEmailStore.SourceCoverage] = [:]
    @Published private(set) var labels: [AggregateBucket] = []
    /// FOLD-01: how many labels/folders match the current filter — the whole
    /// archive's, not just the page shown. Equals `labels.count` on the
    /// previous path, which never knew the total.
    @Published private(set) var labelTotal = 0
    /// FOLD-01: the name filter the folder list is narrowed to.
    @Published private(set) var labelFilter = ""
    /// FOLD-02: every source's folder tree — declared (possibly empty) folders included.
    @Published private(set) var folderTrees: [FolderTree] = []
    @Published private(set) var lastRefresh: Date?

    struct FolderItem: Identifiable {
        let node: ArchiveFolderNode
        var children: [FolderItem]?
        var id: Int64 { node.folderID }
    }

    struct FolderTree: Identifiable {
        let sourceID: Int64
        let title: String
        let items: [FolderItem]
        var id: Int64 { sourceID }
    }

    /// Nest the flat folder rows under their parents, one tree per source.
    static func trees(from nodes: [ArchiveFolderNode], sources: [SQLiteEmailStore.StoredSource]) -> [FolderTree] {
        let bySource = Dictionary(grouping: nodes, by: \.sourceID)
        func build(_ group: [ArchiveFolderNode], parent: Int64?) -> [FolderItem]? {
            let level = group.filter { $0.parentID == parent }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            guard !level.isEmpty else { return nil }
            return level.map { FolderItem(node: $0, children: build(group, parent: $0.folderID)) }
        }
        return bySource.keys.sorted().compactMap { sourceID in
            guard let group = bySource[sourceID], let items = build(group, parent: nil) else { return nil }
            let title = sources.first { $0.sourceID == sourceID }?.filename ?? String(localized: "Earlier imports")
            return FolderTree(sourceID: sourceID, title: title, items: items)
        }
    }

    private let archive: ArchiveDataService
    nonisolated static let labelLimit = 200
    /// FOLD-01: how many folders one "Show more" adds.
    static let labelPage = 200
    /// FOLD-03: folder counts are occurrences; the archive counts messages once.
    static var occurrenceCountsNote: String {
        String(localized: "Folder counts are occurrences: a message kept in two folders or labels counts in each of them. The archive total, search results and exports count every message once — a message in several folders is one message with several locations, never two messages.")
    }
    /// FOLD-01: how many folders the list currently reaches; grows with "Show more".
    private var labelReach = labelPage

    /// FOLD-01 follows the "Complete lists (3.0)" switch: on, every folder is
    /// reachable page by page with the total shown; off, the previous
    /// busiest-200 list.
    var completeLabels: Bool { SQLiteEmailStore.unboundedIDLookups }

    init(archive: ArchiveDataService = .shared) {
        self.archive = archive
    }

    /// FOLD-01: reach the next page of folders.
    func loadMoreLabels() async {
        guard completeLabels, labels.count < labelTotal else { return }
        labelReach += Self.labelPage
        await reloadLabels()
    }

    /// FOLD-01: narrow the folder list by name; an empty filter shows all.
    func setLabelFilter(_ filter: String) async {
        let trimmed = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != labelFilter else { return }
        labelFilter = trimmed
        labelReach = Self.labelPage
        await reloadLabels()
    }

    private func reloadLabels() async {
        if completeLabels {
            let filter: String? = labelFilter.isEmpty ? nil : labelFilter
            labelTotal = (try? await archive.parserTagTotal(matching: filter)) ?? labelTotal
            labels = (try? await archive.parserTagCounts(matching: filter, offset: 0, limit: labelReach)) ?? labels
        } else {
            labels = (try? await archive.parserTagCounts(limit: Self.labelLimit)) ?? labels
            labelTotal = labels.count
        }
    }

    /// One pass of bounded aggregates. Each is an O(1)-memory SQL count or a
    /// GROUP BY; none materializes rows.
    func refresh() async {
        var attachments = EmailQuery.all; attachments.hasAttachments = true
        var pinned = EmailQuery.all; pinned.pinnedOnly = true

        totalCount = (try? await archive.count(query: .all)) ?? totalCount
        attachmentCount = (try? await archive.count(query: attachments)) ?? attachmentCount
        pinnedCount = (try? await archive.count(query: pinned)) ?? pinnedCount
        trashedCount = (try? await archive.trashedCount()) ?? trashedCount
        // IPAD-05: Sent / Received leave the Trash out, like All Mail and the
        // list itself — the GROUP BY over every stored row still counted a
        // copy moved to the Trash, so "Received 51" sat next to "All Mail 50".
        var sent = EmailQuery.all; sent.messageType = "sent"
        var received = EmailQuery.all; received.messageType = "received"
        sentCount = (try? await archive.count(query: sent)) ?? sentCount
        receivedCount = (try? await archive.count(query: received)) ?? receivedCount
        sources = (try? await archive.sources()) ?? sources
        coverage = (try? await archive.sourceCoverage()) ?? coverage
        await reloadLabels()
        if completeLabels, let nodes = try? await archive.folderNodes() {
            folderTrees = Self.trees(from: nodes, sources: sources)
        }
        lastRefresh = Date()
    }
}

// MARK: - View

struct ArchiveSidebarView: View {
    @ObservedObject var model: ArchiveSidebarModel
    @ObservedObject var savedSearches: ArchiveSavedSearchStore
    @Binding var selection: ArchiveSidebarSelection?
    /// The current search text, so "Save search" knows what to keep.
    var currentSearchText: String = ""
    /// SEARCH-02: the applied Advanced Search, saved with the text.
    var currentSpec: SearchSpec? = nil

    private var hasSomethingToSave: Bool {
        !currentSearchText.trimmingCharacters(in: .whitespaces).isEmpty || !(currentSpec?.isEmpty ?? true)
    }
    private var currentSearchSummary: String {
        ArchiveSavedSearch.describe(query: currentSearchText, spec: currentSpec)
    }
    var onImport: (() -> Void)? = nil

    @State private var showSaveSearch = false
    @State private var saveSearchName = ""
    @State private var sourcesExpanded = true
    @State private var labelsExpanded = true
    @State private var foldersExpanded = true
    @State private var savedExpanded = true
    /// FOLD-01: what is typed in the folder filter; applied after a short pause.
    @State private var labelFilterText = ""
    @State private var labelFilterTask: Task<Void, Never>?

    var body: some View {
        List(selection: $selection) {
            Section("Mailboxes") {
                row(.allMail, "All Mail", "tray.full", count: model.totalCount)
                row(.received, "Received", "tray.and.arrow.down", count: model.receivedCount)
                row(.sent, "Sent", "paperplane", count: model.sentCount)
                row(.withAttachments, "With Attachments", "paperclip", count: model.attachmentCount)
                row(.pinned, "Pinned", "pin", count: model.pinnedCount)
                row(.trash, "Trash", "trash", count: model.trashedCount)
            }

            if !model.sources.isEmpty {
                Section("Sources", isExpanded: $sourcesExpanded) {
                    ForEach(model.sources, id: \.sourceID) { source in
                        let cov = model.coverage[source.sourceID]
                        Label {
                            HStack(spacing: 4) {
                                Text(source.filename)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if let cov, cov.pending > 0 {
                                    // A6: this source is not fully searchable yet.
                                    Image(systemName: "text.magnifyingglass")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                        .accessibilityLabel("\(cov.indexed) of \(cov.committed) messages searchable")
                                }
                            }
                        } icon: {
                            Image(systemName: icon(forParser: source.parser))
                        }
                        .tag(ArchiveSidebarSelection.source(source.filename))
                        .help(sourceHelp(source, cov))
                        .accessibilityIdentifier("archive.sidebar.source")
                    }
                }
            }

            if model.completeLabels, !model.folderTrees.isEmpty {
                // FOLD-02: each source's own folder tree, empty folders included.
                // FOLD-03: the counts are occurrences, said on the header.
                Section(isExpanded: $foldersExpanded) {
                    ForEach(model.folderTrees) { tree in
                        DisclosureGroup {
                            OutlineGroup(tree.items, children: \.children) { item in
                                row(.folder(id: item.node.folderID, name: item.node.name), item.node.name,
                                    item.node.declared && item.node.messageCount == 0 ? "folder.badge.minus" : "folder",
                                    count: item.node.messageCount)
                                    .help(item.node.path)
                                    .accessibilityIdentifier("archive.sidebar.folder")
                            }
                        } label: {
                            Label(tree.title, systemImage: "archivebox")
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                } header: {
                    Text("Folders")
                        .help(ArchiveSidebarModel.occurrenceCountsNote)
                        .accessibilityHint(ArchiveSidebarModel.occurrenceCountsNote)
                }
            }

            if model.completeLabels {
                // FOLD-01: every folder reachable — filter by name, page with
                // "Show more", total always shown.
                if !model.labels.isEmpty || !model.labelFilter.isEmpty {
                    Section(isExpanded: $labelsExpanded) {
                        if model.labelTotal > Self.labelFilterThreshold || !model.labelFilter.isEmpty {
                            TextField("Filter folders", text: $labelFilterText)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("archive.sidebar.folderFilter")
                                .onChange(of: labelFilterText) { _, text in
                                    labelFilterTask?.cancel()
                                    labelFilterTask = Task {
                                        try? await Task.sleep(for: .milliseconds(250))
                                        guard !Task.isCancelled else { return }
                                        await model.setLabelFilter(text)
                                    }
                                }
                        }
                        ForEach(model.labels) { bucket in
                            row(.label(bucket.value), bucket.value, "folder", count: bucket.count)
                        }
                        if model.labels.isEmpty, !model.labelFilter.isEmpty {
                            Text("No folder matches “\(model.labelFilter)”")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if model.labels.count < model.labelTotal {
                            Button {
                                Task { await model.loadMoreLabels() }
                            } label: {
                                Label("Show more (\(model.labels.count) of \(model.labelTotal) folders)", systemImage: "ellipsis.circle")
                            }
                            .buttonStyle(.plain)
                            .help("Lists the next \(ArchiveSidebarModel.labelPage) folders, busiest first. Every folder in the archive can be reached this way or through the filter.")
                            .accessibilityIdentifier("archive.sidebar.moreFolders")
                        }
                    } header: {
                        Text("Labels & Folders (\(model.labelTotal))")
                    }
                }
            } else if !model.labels.isEmpty {
                Section("Labels & Folders", isExpanded: $labelsExpanded) {
                    ForEach(model.labels) { bucket in
                        row(.label(bucket.value), bucket.value, "folder", count: bucket.count)
                    }
                }
            }

            Section(isExpanded: $savedExpanded) {
                ForEach(savedSearches.searches) { saved in
                    Label(saved.name, systemImage: "magnifyingglass.circle")
                        .tag(ArchiveSidebarSelection.saved(saved.id))
                        .help(saved.summary)
                        .contextMenu {
                            Button(role: .destructive) {
                                savedSearches.remove(id: saved.id)
                                if selection == .saved(saved.id) { selection = .allMail }
                            } label: { Label("Delete Saved Search", systemImage: "trash") }
                        }
                        .accessibilityIdentifier("archive.sidebar.saved")
                }
                if hasSomethingToSave {
                    Button {
                        saveSearchName = ""
                        showSaveSearch = true
                    } label: {
                        Label("Save Current Search…", systemImage: "plus.circle")
                    }
                    .buttonStyle(.plain)
                    .help("Keep “\(currentSearchSummary)” in this list")
                    .accessibilityIdentifier("archive.sidebar.saveSearch")
                }
            } header: {
                Text("Saved Searches")
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("archive.sidebar")
        .toolbar {
            if let onImport {
                ToolbarItem(placement: .automatic) {
                    Button(action: onImport) {
                        Label("Import", systemImage: "square.and.arrow.down")
                    }
                    .help("Import a mailbox file or folder (⌘O)")
                    .accessibilityIdentifier("archive.sidebar.import")
                }
            }
        }
        .alert("Save Search", isPresented: $showSaveSearch) {
            TextField("Name", text: $saveSearchName)
            Button("Save") {
                savedSearches.add(name: saveSearchName, query: currentSearchText, spec: currentSpec)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves “\(currentSearchSummary)” so it can be run again from the sidebar.")
        }
    }

    /// FOLD-01: the filter field appears once there are more folders than fit a glance.
    private static let labelFilterThreshold = 12

    private func row(_ target: ArchiveSidebarSelection, _ title: String, _ symbol: String, count: Int) -> some View {
        Label {
            HStack {
                Text(title).lineLimit(1)
                Spacer()
                if count > 0 {
                    Text(count.formatted())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: symbol)
        }
        .tag(target)
        .accessibilityLabel("\(title), \(count) messages")
    }

    private func sourceHelp(_ source: SQLiteEmailStore.StoredSource, _ cov: SQLiteEmailStore.SourceCoverage?) -> String {
        var text = "\(source.filename) — \(source.parser), \(ByteCountFormatter.string(fromByteCount: Int64(source.byteSize), countStyle: .file)), imported \(source.importedAt.formatted(date: .abbreviated, time: .shortened))"
        if let cov {
            text += cov.pending > 0
                ? ". Search covers \(cov.indexed.formatted()) of \(cov.committed.formatted()) messages from this source — \(cov.pending.formatted()) still indexing"
                : ". Every one of its \(cov.committed.formatted()) messages is searchable"
        }
        return text
    }

    private func icon(forParser parser: String) -> String {
        switch parser.lowercased() {
        case let p where p.contains("pst") || p.contains("ost"): return "externaldrive"
        case let p where p.contains("zip") || p.contains("gzip"): return "doc.zipper"
        case let p where p.contains("maildir") || p.contains("eml"): return "folder"
        default: return "archivebox"
        }
    }
}
