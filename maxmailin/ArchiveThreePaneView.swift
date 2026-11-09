@testable import ArchiveCore
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
    // FIND-04: the applied Advanced Search and what could not be confirmed yet.
    @State private var spec: SearchSpec?
    @State private var unresolved = 0
    @State private var showAdvancedSearch = false
    /// REC-06: the five practical recipes, beside Search.
    @State private var showRecipes = false
    /// FIND-05: why an attachment named by a chip could not be opened.
    @State private var attachmentOpenFailure: EvidenceAttachmentOpener.Failure?
    @Environment(ModuleRegistry.self) private var modules: ModuleRegistry?

    /// Return to the tools hub (the Archive page keeps its other surfaces).
    var onHome: (() -> Void)? = nil
    /// Import entry point, so the shell has Import / Search / Export.
    var onImport: (() -> Void)? = nil
    /// Settings entry point (owner, 2026-09-30: the shell showed no way into
    /// Settings; the app menu is hidden in full screen).
    var onSettings: (() -> Void)? = nil

    @EnvironmentObject private var storeManager: StoreManager

    /// nil = the plan covers the whole archive (LIFE-06: also after a plan ended).
    private var accessLimit: Int? { storeManager.accessPolicy.archiveReadLimit }

    init(archive: ArchiveDataService = .shared,
         onHome: (() -> Void)? = nil,
         onImport: (() -> Void)? = nil,
         onSettings: (() -> Void)? = nil) {
        _model = StateObject(wrappedValue: ArchiveListViewModel(archive: archive, pageSize: 100, maxRetained: 500))
        _detail = StateObject(wrappedValue: ArchiveDetailViewModel(archive: archive))
        _sidebar = StateObject(wrappedValue: ArchiveSidebarModel(archive: archive))
        self.onHome = onHome
        self.onImport = onImport
        self.onSettings = onSettings
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ArchiveSidebarView(model: sidebar,
                               savedSearches: savedSearches,
                               selection: $selection,
                               currentSearchText: searchText,
                               currentSpec: spec,
                               onImport: onImport)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } content: {
            VStack(spacing: 0) {
                if let spec, !spec.isEmpty {
                    ActiveFiltersBar(spec: spec, scopeDescription: scopeDescription, unresolved: unresolved,
                                     onChange: { newSpec in self.spec = newSpec; Task { await applyQuery() } },
                                     onEdit: { showAdvancedSearch = true })
                    Divider()
                }
                ArchiveListPane(model: model,
                                detail: detail,
                                selectedID: $selectedID,
                                matchTerms: SearchMatchTerms(searchText: searchText),
                                evidenceProvider: evidenceProvider,
                                onOpenAttachment: openAttachmentFromEvidence,
                                isSearching: !searchText.trimmingCharacters(in: .whitespaces).isEmpty || !(spec?.isEmpty ?? true))
            }
                .alert(String(localized: "Could not open the attachment"),
                       isPresented: Binding(get: { attachmentOpenFailure != nil }, set: { if !$0 { attachmentOpenFailure = nil } }),
                       presenting: attachmentOpenFailure) { _ in
                    Button("OK", role: .cancel) { attachmentOpenFailure = nil }
                } message: { failure in
                    Text(failure.message)
                }
                .navigationTitle(selection?.title ?? "Archive")
                .searchable(text: $searchText, prompt: "Search subject, sender, body…")
                // v4.0 REC-02: pressing Return is the explicit "this is my search".
                .onSubmit(of: .search) { Task { await applyQuery(); await reportSearchToRecipe() } }
                .sheet(isPresented: $showRecipes) {
                    PracticalRecipesHome(scopeName: scopeDescription, currentSpec: spec,
                                         onOpenSpecialist: onHome.map { home in { showRecipes = false; home() } },
                                         onClose: { showRecipes = false })
                }
                .sheet(isPresented: $showAdvancedSearch) {
                    AdvancedSearchView(applied: spec, scopeDescription: scopeDescription,
                                       onApply: { newSpec in spec = newSpec; showAdvancedSearch = false; Task { await applyQuery(); await reportSearchToRecipe() } },
                                       onCancel: { showAdvancedSearch = false })
                }
                .toolbar {
                    if modules?.isOn(.searchQueryModel) ?? false {
                        ToolbarItem {
                            Button { showAdvancedSearch = true } label: {
                                Label("Advanced Search", systemImage: "line.3.horizontal.decrease.circle")
                            }
                            .help("Build a search from conditions: all / any / exclude, dates, attachments")
                            .accessibilityIdentifier("archive.list.advancedSearch")
                        }
                    }
                    ToolbarItem {
                        Button { showRecipes = true } label: {
                            Label("Recipes", systemImage: "checklist")
                        }
                        .help("Five practical recipes: find and export, save attachments, clean up duplicates, back up and restore, collect and hand over")
                        .accessibilityIdentifier("archive.list.recipes")
                    }
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
                    if let onSettings {
                        ToolbarItem {
                            Button(action: onSettings) {
                                Label("Settings", systemImage: "gearshape")
                            }
                            .help("Open Settings (⌘,)")
                            .accessibilityIdentifier("archive.threePane.settings")
                        }
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
            // Purchase depth: the Free tier browses the first 500 rows of any
            // query, the same rule the Advanced list applies. Set BEFORE the
            // first load so the first page is already clamped.
            model.accessLimit = accessLimit
            await sidebar.refresh()
            // v4.0 REC-01: opened from a recipe step — work on the run's frozen search.
            if let frozen = RecipeJobBroker.shared.requested?.context.selection?.spec, spec == nil {
                spec = frozen
                await applyQuery()
            }
            if model.summaries.isEmpty && model.error == nil { await applyQuery() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .recipeToolRequested)) { note in
            guard let frozen = (note.object as? RecipeJobTicket)?.context.selection?.spec else { return }
            spec = frozen
            Task { await applyQuery() }
        }
        .onChange(of: storeManager.isPremium) { _, _ in
            // A purchase (or an expiry) while the page is open changes what
            // may be reached; reload from the first page under the new rule.
            model.accessLimit = accessLimit
            Task { await model.reload() }
        }
        .onChange(of: selection) { _, newSelection in
            selectedID = nil
            // SEARCH-02: a saved search brings back the Advanced Search it was
            // saved with, as chips that edit and re-save like any other.
            if case .saved(let id) = newSelection,
               let saved = savedSearches.searches.first(where: { $0.id == id }),
               let savedSpec = saved.spec, !savedSpec.isEmpty {
                spec = savedSpec
            }
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
        .onReceive(NotificationCenter.default.publisher(for: .archiveTrashChanged)) { _ in
            Task { await sidebar.refresh(); await model.reload() }
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
        // FIND-04: the Advanced Search rides on top; scope stays in `base`.
        // CAP-01 / FIND-04: with the search model on, the typed words run on
        // the model too (same engine, coverage and evidence as Advanced
        // Search, no candidate window); otherwise the previous text path.
        let query = ArchiveBrowseState(searchText: text, afterDate: scope.after, spec: spec)
            .query(base: base, plainTextOnModel: modules?.isOn(.searchQueryModel) ?? false)
        await model.setQuery(query)
        if let applied = query.spec, !applied.isEmpty {
            unresolved = (try? await model.archive.unresolvedCount(query: query)) ?? 0
        } else {
            unresolved = 0
        }
    }

    /// v4.0 REC-02: a recipe search step waiting on this search gets the
    /// measured result — the spec, the typed words and the count the archive
    /// returned — never a number the person typed.
    private func reportSearchToRecipe() async {
        guard RecipeJobBroker.shared.ledger.hasOpenTicket(for: .search) else { return }
        let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !(spec?.isEmpty ?? true) || !text.isEmpty else { return }
        let query = model.query
        guard let count = try? await model.archive.count(query: query) else {
            RecipeJobBroker.shared.report(.search, outcome: .failed, receipt: .init(kind: .none, id: ""),
                                          summary: "The search could not be counted")
            return
        }
        var line = "Search in \(scopeDescription): \(count) matching messages"
        if !text.isEmpty { line += " · words \"\(text)\"" }
        if let spec, !spec.isEmpty { line += " · \(SearchSpecDescriber.summary(spec))" }
        if unresolved > 0 { line += " · \(unresolved) not yet confirmed (unindexed content)" }
        // REC-05: the row bound the count was measured at, so the run's later
        // export / clean-up works on these rows and not on mail imported since.
        let bound = try? await model.archive.selectionSnapshotBound()
        RecipeJobBroker.shared.report(.search, outcome: .succeeded,
                                      receipt: .init(kind: .measurement, id: "\(count) matches"),
                                      summary: line, count: count, spec: spec, storeRevision: bound)
    }

    /// FIND-05: with the search model on and a search active, each row asks
    /// the index why it is listed; otherwise the previous heuristic strip.
    private var evidenceProvider: ((EmailID) async -> [MatchEvidence])? {
        guard modules?.isOn(.searchQueryModel) ?? false else { return nil }
        let freeText = model.query.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        // IPAD-03: the spec the list ran — the typed words (on the model) and
        // the applied Advanced Search — so a plain search gets index evidence too.
        let applied = model.query.spec ?? spec
        guard !(applied?.isEmpty ?? true) || !(freeText?.isEmpty ?? true) else { return nil }
        let archive = model.archive
        return { id in (try? await archive.matchEvidence(emailID: id, spec: applied, freeText: freeText)) ?? [] }
    }

    /// FIND-05: a chip that names an attachment opens that attachment — the
    /// one at the recorded ordinal — and selects its message, in one click.
    private func openAttachmentFromEvidence(_ id: EmailID, _ ordinal: Int, _ childPath: String?) {
        selectedID = id
        let archive = model.archive
        Task { @MainActor in
            attachmentOpenFailure = await EvidenceAttachmentOpener.open(emailID: id, ordinal: ordinal, childPath: childPath, archive: archive)
        }
    }

    /// What the sidebar and date scope limit the list to, in words.
    private var scopeDescription: String {
        Self.describeScope(title: (selection ?? .allMail).title, dateScope: scope, accessLimit: accessLimit)
    }

    /// SEARCH-03: the searched scope in words — the sidebar row, the date
    /// range and, on Free, the newest-N window the plan reaches.
    static func describeScope(title: String, dateScope: ArchiveDateScope, accessLimit: Int?) -> String {
        var parts = [title]
        if dateScope != .all { parts.append(dateScope.rawValue) }
        if let accessLimit { parts.append(String(localized: "newest \(accessLimit) emails (Free plan)")) }
        return parts.joined(separator: " · ")
    }
}
