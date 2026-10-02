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

    func add(name: String, query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let label = name.trimmingCharacters(in: .whitespaces).isEmpty ? trimmed : name
        searches.append(ArchiveSavedSearch(id: UUID(), name: label, query: trimmed))
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
    @Published private(set) var lastRefresh: Date?

    private let archive: ArchiveDataService
    static let labelLimit = 200

    init(archive: ArchiveDataService = .shared) {
        self.archive = archive
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
        if let types = try? await archive.messageTypeCounts() {
            sentCount = types["sent"] ?? 0
            receivedCount = types["received"] ?? 0
        }
        sources = (try? await archive.sources()) ?? sources
        coverage = (try? await archive.sourceCoverage()) ?? coverage
        labels = (try? await archive.parserTagCounts(limit: Self.labelLimit)) ?? labels
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
    var onImport: (() -> Void)? = nil

    @State private var showSaveSearch = false
    @State private var saveSearchName = ""
    @State private var sourcesExpanded = true
    @State private var labelsExpanded = true
    @State private var savedExpanded = true

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

            if !model.labels.isEmpty {
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
                        .help(saved.query)
                        .contextMenu {
                            Button(role: .destructive) {
                                savedSearches.remove(id: saved.id)
                                if selection == .saved(saved.id) { selection = .allMail }
                            } label: { Label("Delete Saved Search", systemImage: "trash") }
                        }
                        .accessibilityIdentifier("archive.sidebar.saved")
                }
                if !currentSearchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button {
                        saveSearchName = ""
                        showSaveSearch = true
                    } label: {
                        Label("Save Current Search…", systemImage: "plus.circle")
                    }
                    .buttonStyle(.plain)
                    .help("Keep “\(currentSearchText)” in this list")
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
                savedSearches.add(name: saveSearchName, query: currentSearchText)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves “\(currentSearchText)” so it can be run again from the sidebar.")
        }
    }

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
