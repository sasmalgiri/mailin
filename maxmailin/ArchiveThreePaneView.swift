//
//  ArchiveThreePaneView.swift
//  maxmailin
//
//  A2: the three-pane archive shell — sidebar (mailboxes, sources, labels,
//  saved searches) / list / detail. Every pane is bounded by construction:
//  the sidebar reads aggregates, the list pages `EmailSummary` rows by keyset
//  or ranked cursor through `ArchiveListViewModel`, and the detail hydrates
//  one message by id through `ArchiveDetailViewModel`. There is no array of
//  the corpus anywhere in this view.
//
//  The sidebar's row compiles to an `EmailQuery` base; the search field and
//  the date scope are compiled on top by `ArchiveBrowseState`, the same step
//  the full list uses, so `from:alice` means the same thing here.
//

import SwiftUI

struct ArchiveThreePaneView: View {
    @StateObject private var model: ArchiveListViewModel
    @StateObject private var detail: ArchiveDetailViewModel
    @StateObject private var sidebar: ArchiveSidebarModel
    @ObservedObject private var savedSearches = ArchiveSavedSearchStore.shared

    @State private var selection: ArchiveSidebarSelection? = .allMail
    @State private var selectedID: EmailID?
    @State private var searchText = ""
    @State private var scope: ArchiveDateScope = .all
    @State private var searchTask: Task<Void, Never>?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// Return to the tools hub (the Archive page keeps its other surfaces).
    var onHome: (() -> Void)? = nil
    /// Import entry point, so the shell has Import / Search / Export.
    var onImport: (() -> Void)? = nil

    init(archive: ArchiveDataService = .shared,
         onHome: (() -> Void)? = nil,
         onImport: (() -> Void)? = nil) {
        _model = StateObject(wrappedValue: ArchiveListViewModel(archive: archive, pageSize: 100, maxRetained: 500))
        _detail = StateObject(wrappedValue: ArchiveDetailViewModel(archive: archive))
        _sidebar = StateObject(wrappedValue: ArchiveSidebarModel(archive: archive))
        self.onHome = onHome
        self.onImport = onImport
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ArchiveSidebarView(model: sidebar,
                               savedSearches: savedSearches,
                               selection: $selection,
                               currentSearchText: searchText,
                               onImport: onImport)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } content: {
            ArchiveListPane(model: model,
                            detail: detail,
                            selectedID: $selectedID,
                            matchTerms: SearchMatchTerms(searchText: searchText),
                            isSearching: !searchText.trimmingCharacters(in: .whitespaces).isEmpty)
                .navigationTitle(selection?.title ?? "Archive")
                .searchable(text: $searchText, prompt: "Search subject, sender, body…")
                .toolbar {
                    ToolbarItem {
                        Menu {
                            Picker("Date", selection: $scope) {
                                ForEach(ArchiveDateScope.allCases) { Text($0.rawValue).tag($0) }
                            }
                        } label: {
                            Label(scope.rawValue, systemImage: "calendar")
                        }
                        .help("Limit the list to a date range")
                        .accessibilityIdentifier("archive.list.dateScope")
                    }
                    if let onHome {
                        ToolbarItem(placement: .navigation) {
                            Button(action: onHome) {
                                Label("Tools", systemImage: "square.grid.2x2")
                            }
                            .help("Open the tools hub — analytics, exports, workflows")
                            .accessibilityIdentifier("archive.threePane.tools")
                        }
                    }
                }
                .navigationSplitViewColumnWidth(min: 320, ideal: 420, max: 620)
        } detail: {
            ArchiveDetailHost(
                detail: detail,
                orderedIDs: model.visibleOrderedIDs,
                onNavigate: { id in selectedID = id }
            )
        }
        .task {
            await sidebar.refresh()
            if model.summaries.isEmpty && model.error == nil { await applyQuery() }
        }
        .onChange(of: selection) { _, _ in
            selectedID = nil
            Task { await applyQuery() }
        }
        .onChange(of: scope) { _, _ in Task { await applyQuery() } }
        .onChange(of: searchText) { _, _ in scheduleQuery() }
        .onChange(of: selectedID) { _, id in
            Task { await detail.select(id) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newEmailsImported)) { _ in
            Task { await sidebar.refresh(); await model.reload() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .fidelityBackfillCompleted)) { _ in
            Task { await sidebar.refresh() }
        }
        .accessibilityIdentifier("archive.threePane")
    }

    /// Debounced search; sidebar and date changes apply at once.
    private func scheduleQuery() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            await applyQuery()
        }
    }

    private func applyQuery() async {
        let base = (selection ?? .allMail).baseQuery(savedSearches: savedSearches.searches)
        let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        // A saved search already carries its text; a typed search narrows it.
        let query = ArchiveBrowseState(searchText: text, afterDate: scope.after).query(base: base)
        await model.setQuery(query)
    }
}
