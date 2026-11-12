@testable import ArchiveCore
//
//  PracticalRecipesView.swift
//  maxmailin
//
//  v4.0 REC-06 / REC-05 / SEARCH-04: the five practical recipes beside
//  Archive and Search — choose → review → result. The review stage shows the
//  real counts before anything runs (rule 4); the result stage shows what the
//  receipts say (counts, paths, hashes, skipped reasons, verification), never
//  values the person typed. The specialist workflow library stays one tap
//  away as the secondary entry.
//

import SwiftUI
import UniformTypeIdentifiers

/// The receipt's facts as labelled lines.
struct RecipeResultFactsView: View {
    let facts: RecipeResultFacts

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(facts.lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xSmall) {
                    Text(line.label)
                        .font(Typography.caption1).foregroundColor(AppColors.secondary)
                        .frame(minWidth: 90, alignment: .leading)
                    Text(line.value)
                        .font(Typography.caption1)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .accessibilityIdentifier("recipe.result.facts")
    }
}

/// The list of recipes, the last results and the way to the specialist library.
struct PracticalRecipesHome: View {
    let scopeName: String
    let currentSpec: SearchSpec?
    var onOpenSpecialist: (() -> Void)? = nil
    let onClose: () -> Void

    @EnvironmentObject private var storeManager: StoreManager
    @State private var running: PracticalRecipeKind?
    @State private var runningOnline: OnlineRecipeKind?
    @State private var recent: [PracticalRecipeResult] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(PracticalRecipeKind.allCases) { kind in
                        recipeRow(kind)
                    }
                } footer: {
                    Text("Each recipe uses the archive's own search, export, duplicate and backup engines. Its result is read from the job's receipt.")
                }
                // REC-07: connected-mail recipes, only while Mail runs.
                OnlineRecipesSection(running: $runningOnline)
                if !recent.isEmpty {
                    Section(String(localized: "Recent results")) {
                        ForEach(recent.prefix(5)) { result in
                            HStack {
                                Image(systemName: result.recipe.icon)
                                VStack(alignment: .leading) {
                                    Text(result.recipe.title).font(Typography.callout)
                                    Text("\(result.state.label) · \(result.finishedAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(Typography.caption1).foregroundColor(AppColors.secondary)
                                }
                            }
                        }
                    }
                }
                if let onOpenSpecialist {
                    Section {
                        Button(String(localized: "Specialist workflows…"), action: onOpenSpecialist)
                            .accessibilityIdentifier("recipes.specialist")
                    } footer: {
                        Text("Legal, forensic and other guided workflows stay in Tools ▸ Start a job.")
                    }
                }
            }
            .navigationTitle(String(localized: "Recipes"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Close"), action: onClose)
                }
            }
            .navigationDestination(item: $running) { kind in
                PracticalRecipeRunView(kind: kind, scopeName: scopeName, currentSpec: currentSpec,
                                       onFinished: { recent = PracticalRecipeResultStore.production.list() })
            }
            .navigationDestination(item: $runningOnline) { kind in
                OnlineRecipeRunView(kind: kind)
            }
        }
        .frame(minWidth: 420, minHeight: 480)
        .task { recent = PracticalRecipeResultStore.production.list() }
    }

    private func recipeRow(_ kind: PracticalRecipeKind) -> some View {
        let policy = storeManager.accessPolicy
        let entitled = kind.isEntitled(policy)
        return Button { running = kind } label: {
            HStack(alignment: .top, spacing: Spacing.small) {
                Image(systemName: kind.icon).font(.title3).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title).font(Typography.callout).fontWeight(.semibold)
                    Text(kind.summary).font(Typography.caption1).foregroundColor(AppColors.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let note = kind.limitNote(policy) {
                        Text(note).font(Typography.caption2).foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!entitled)
        .accessibilityIdentifier("recipes.\(kind.rawValue)")
        .accessibilityHint(kind.summary)
    }
}

/// One recipe: choose → review → result.
struct PracticalRecipeRunView: View {
    let kind: PracticalRecipeKind
    let scopeName: String
    let currentSpec: SearchSpec?
    var onFinished: () -> Void = {}

    enum Stage { case choose, review, running, result }
    enum Source: Hashable { case current, saved(UUID), template(String), wholeArchive }
    enum FolderPurpose { case destination, backupParent, backupToCheck }

    @EnvironmentObject private var storeManager: StoreManager
    @ObservedObject private var savedSearches = ArchiveSavedSearchStore.shared

    @State private var stage: Stage = .choose
    @State private var source: Source = .template(SearchQueryTemplates.all[0].id)
    @State private var templateValues: [SearchQueryTemplate.Parameter: String] = [:]
    @State private var format: PracticalExportFormat = .emlFolder
    @State private var conditions = CollectionConditions()
    @State private var collectionName = ""
    @State private var checkExisting = false
    @State private var destination: URL?
    @State private var preview: RecipeSearchPreview?
    @State private var candidates: [RecipeFileCandidate] = []
    @State private var chosen: Set<String> = []
    @State private var cleanupPlan: RecipeCleanupPlan?
    @State private var archiveCount: Int?
    @State private var result: PracticalRecipeResult?
    @State private var error: String?
    @State private var progressLine = ""
    @State private var task: Task<Void, Never>?
    @State private var showFolderPicker = false
    @State private var folderPurpose: FolderPurpose = .destination
    @State private var confirmCleanup = false
    @State private var evidence: [EmailID: [MatchEvidence]] = [:]

    private var policy: AccessPolicy { storeManager.accessPolicy }

    var body: some View {
        Form {
            Section {
                Text(kind.summary).font(Typography.caption1).foregroundColor(AppColors.secondary)
                if let note = kind.limitNote(policy) { Text(note).font(Typography.caption1).foregroundColor(.orange) }
            }
            switch stage {
            case .choose: chooseStage
            case .review: reviewStage
            case .running: runningStage
            case .result: resultStage
            }
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundColor(.red) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(kind.title)
        .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { picked in
            if case .success(let url) = picked { folderChosen(url) }
        }
        .confirmationDialog(cleanupConfirmTitle, isPresented: $confirmCleanup, titleVisibility: .visible) {
            Button(cleanupConfirmTitle, role: .destructive) { run() }
        } message: {
            Text("Each email keeps exactly one copy. The extra copies move to the Trash and can be restored from there.")
        }
        .onDisappear { task?.cancel() }
    }

    // MARK: Choose

    @ViewBuilder
    private var chooseStage: some View {
        switch kind {
        case .findAndExport, .saveAttachments, .cleanUpDuplicates:
            Section(String(localized: "What to find")) {
                Picker(String(localized: "Search"), selection: $source) {
                    if kind == .cleanUpDuplicates { Text("The whole archive").tag(Source.wholeArchive) }
                    if let currentSpec, !currentSpec.isEmpty { Text("The search on screen (\(scopeName))").tag(Source.current) }
                    ForEach(SearchQueryTemplates.all) { Text($0.title).tag(Source.template($0.id)) }
                    ForEach(savedSearches.searches.filter { $0.spec != nil }) { Text($0.name).tag(Source.saved($0.id)) }
                }
                .accessibilityIdentifier("recipe.source")
                if case .template(let id) = source, let template = SearchQueryTemplates.all.first(where: { $0.id == id }) {
                    ForEach(template.parameters, id: \.self) { p in
                        if p == .fileType {
                            Picker(p.label, selection: binding(p, default: template.defaults[p] ?? "PDF")) {
                                ForEach(SearchQueryTemplates.fileTypes, id: \.value) { Text($0.label).tag($0.value) }
                            }
                        } else {
                            TextField(p.label, text: binding(p, default: ""), prompt: Text(template.defaults[p] ?? ""))
                        }
                    }
                }
            }
            if kind == .findAndExport { formatSection }
        case .collectAndHandOver:
            Section(String(localized: "Conditions")) {
                TextField(String(localized: "Sender"), text: $conditions.sender)
                TextField(String(localized: "From (yyyy-MM-dd)"), text: $conditions.fromDay)
                TextField(String(localized: "To (yyyy-MM-dd)"), text: $conditions.toDay)
                TextField(String(localized: "Words"), text: $conditions.words)
            }
            Section(String(localized: "Collection name")) {
                TextField(String(localized: "Collection name"), text: $collectionName)
            }
            formatSection
        case .backUpAndRestore:
            Section {
                Picker(String(localized: "Back up now, or check a backup"), selection: $checkExisting) {
                    Text("Back up now and check it").tag(false)
                    Text("Check an existing backup").tag(true)
                }
                .pickerStyle(.inline)
            }
        }
        Section {
            Button(String(localized: "Review")) { Task { await review() } }
                .keyboardShortcut(.defaultAction)
                .disabled(!kind.isEntitled(policy))
                .accessibilityIdentifier("recipe.review")
        }
    }

    private var formatSection: some View {
        Section(String(localized: "Export format")) {
            Picker(String(localized: "Export format"), selection: $format) {
                ForEach(PracticalExportFormat.allCases) { Text($0.label).tag($0) }
            }
        }
    }

    private func binding(_ p: SearchQueryTemplate.Parameter, default value: String) -> Binding<String> {
        Binding(get: { templateValues[p] ?? value }, set: { templateValues[p] = $0 })
    }

    /// The spec the person chose, or nil for "the whole archive".
    private var chosenSpec: SearchSpec? {
        switch source {
        case .current: return currentSpec
        case .saved(let id): return savedSearches.searches.first { $0.id == id }?.spec
        case .template(let id): return SearchQueryTemplates.all.first { $0.id == id }?.spec(templateValues)
        case .wholeArchive: return nil
        }
    }

    private var sourceName: String {
        switch source {
        case .current: return scopeName
        case .saved(let id): return savedSearches.searches.first { $0.id == id }?.name ?? scopeName
        case .template(let id): return SearchQueryTemplates.all.first { $0.id == id }?.title ?? scopeName
        case .wholeArchive: return String(localized: "The whole archive")
        }
    }

    // MARK: Review (counts first — rule 4)

    private func engine() -> PracticalRecipeEngine {
        let e = PracticalRecipeEngine(env: .production(policy: policy))
        e.onProgress = { what, done, total in progressLine = total > 0 ? "\(what) \(done) / \(total)" : what }
        return e
    }

    @MainActor
    private func review() async {
        error = nil
        let e = engine()
        do {
            switch kind {
            case .findAndExport, .saveAttachments:
                guard let spec = chosenSpec else { return }
                preview = try await e.preview(spec: spec, scopeName: sourceName)
                if kind == .saveAttachments, let preview {
                    candidates = try await e.fileCandidates(preview)
                    chosen = Set(candidates.filter(\.matchesConditions).map(\.id))
                }
            case .collectAndHandOver:
                preview = try await e.preview(spec: conditions.spec(), scopeName: collectionName.isEmpty ? String(localized: "Collection") : collectionName)
            case .cleanUpDuplicates:
                preview = try await chosenSpec.asyncPreview(e, scopeName: sourceName)
                cleanupPlan = try await e.cleanupPlan(preview)
            case .backUpAndRestore:
                archiveCount = try? await ArchiveDataService.shared.storedTotalCount()
            }
            stage = .review
        } catch {
            self.error = error.localizedDescription
        }
    }

    @ViewBuilder
    private var reviewStage: some View {
        if let preview {
            Section(String(localized: "Matches")) {
                LabeledContent(String(localized: "Search"), value: preview.sourceLine)
                LabeledContent(String(localized: "Matching messages"), value: preview.matches.formatted())
                if preview.unresolved > 0 {
                    Text("\(preview.unresolved) more may match once their text is indexed; they are not included.")
                        .font(Typography.caption1).foregroundColor(.orange)
                }
                if let coverage = preview.coverage {
                    Label(coverage, systemImage: "lock.doc").font(Typography.caption1).foregroundColor(.orange)
                }
                Text("The matches are frozen now: mail imported later is not added to this run.")
                    .font(Typography.caption2).foregroundColor(AppColors.secondary)
            }
        }
        if kind == .saveAttachments {
            RecipeFileBrowserView(candidates: candidates, chosen: $chosen, spec: preview?.spec, evidence: $evidence)
        }
        if let plan = cleanupPlan {
            Section(String(localized: "Duplicates")) {
                LabeledContent(String(localized: "Extra copies verified identical"), value: plan.removable.formatted())
                LabeledContent(String(localized: "Groups"), value: plan.verifiedGroups.formatted())
                if plan.candidateGroups > 0 {
                    Text("\(plan.candidateGroups) groups share a Message-ID but differ in content; they are not moved.")
                        .font(Typography.caption1).foregroundColor(AppColors.secondary)
                }
            }
        }
        if kind == .backUpAndRestore {
            Section {
                if checkExisting {
                    Text("The backup is verified file by file, restored into a separate empty profile and its counts compared with the inventory. Your archive is not changed.")
                } else if let archiveCount {
                    Text("Backs up the whole archive: \(archiveCount) emails, with every file hashed. Then it is restored into a separate empty profile and compared.")
                }
            }
        }
        Section {
            if kind != .cleanUpDuplicates {
                Button(destination == nil ? destinationPrompt : String(localized: "Destination: \(destination?.lastPathComponent ?? "")")) {
                    folderPurpose = kind == .backUpAndRestore ? (checkExisting ? .backupToCheck : .backupParent) : .destination
                    showFolderPicker = true
                }
                .accessibilityIdentifier("recipe.destination")
            }
            HStack {
                Button(String(localized: "Back")) { stage = .choose }
                Spacer()
                Button(runTitle) {
                    if kind == .cleanUpDuplicates { confirmCleanup = true } else { run() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canRun)
                .accessibilityIdentifier("recipe.run")
            }
        }
    }

    private var destinationPrompt: String {
        switch kind {
        case .backUpAndRestore: return checkExisting ? String(localized: "Choose the backup folder…") : String(localized: "Choose where to save the backup…")
        default: return String(localized: "Choose a destination folder…")
        }
    }

    private var cleanupConfirmTitle: String {
        String(localized: "Move \(cleanupPlan?.removable ?? 0) copies to the Trash")
    }

    private var runTitle: String {
        switch kind {
        case .findAndExport, .collectAndHandOver: return String(localized: "Export \(preview?.matches ?? 0) messages")
        case .saveAttachments: return String(localized: "Save \(chosen.count) files")
        case .cleanUpDuplicates: return cleanupConfirmTitle
        case .backUpAndRestore: return checkExisting ? String(localized: "Check backup") : String(localized: "Back up and check")
        }
    }

    private var canRun: Bool {
        switch kind {
        case .cleanUpDuplicates: return cleanupPlan != nil
        case .saveAttachments: return destination != nil && !chosen.isEmpty
        default: return destination != nil
        }
    }

    private func folderChosen(_ url: URL) {
        destination = url
    }

    // MARK: Run and result

    private func run() {
        stage = .running
        error = nil
        let e = engine()
        let folder = destination
        let stamp = ArchiveBackups.backupDestination(parent: URL(fileURLWithPath: "/")).lastPathComponent.replacingOccurrences(of: "mailin-backup-", with: "")
        task = Task { @MainActor in
            let access = folder?.startAccessingSecurityScopedResource() ?? false
            defer { if access { folder?.stopAccessingSecurityScopedResource() } }
            var r: PracticalRecipeResult?
            switch kind {
            case .findAndExport:
                if let preview, let folder { r = await e.findAndExport(preview, format: format, destination: exportURL(folder, name: "mailin-export-\(stamp)")) }
            case .collectAndHandOver:
                if let folder {
                    let name = collectionName.isEmpty ? "collection" : collectionName
                    r = await e.collectAndHandOver(conditions, name: collectionName, format: format,
                                                   destination: exportURL(folder, name: ExportInventory.safeComponent(name) + "-\(stamp)"))
                }
            case .saveAttachments:
                if let preview, let folder {
                    r = await e.saveFiles(candidates.filter { chosen.contains($0.id) }, preview: preview,
                                          to: folder.appendingPathComponent("mailin-attachments-\(stamp)", isDirectory: true))
                }
            case .cleanUpDuplicates:
                if let cleanupPlan { r = await e.cleanUp(cleanupPlan, preview: preview) }
                NotificationCenter.default.post(name: .archiveTrashChanged, object: nil)
            case .backUpAndRestore:
                if let folder { r = checkExisting ? await e.checkBackup(folder) : await e.backUpAndCheck(parent: folder) }
            }
            result = r
            stage = .result
            onFinished()
        }
    }

    private func exportURL(_ folder: URL, name: String) -> URL {
        format == .emlFolder ? folder.appendingPathComponent(name, isDirectory: true) : folder.appendingPathComponent(name + ".mbox")
    }

    private var runningStage: some View {
        Section {
            HStack {
                ProgressView().controlSize(.small)
                Text(progressLine.isEmpty ? String(localized: "Working…") : progressLine)
                Spacer()
                Button(String(localized: "Cancel")) { task?.cancel() }
                    .accessibilityIdentifier("recipe.cancel")
            }
        }
    }

    @ViewBuilder
    private var resultStage: some View {
        if let result {
            Section {
                Label(result.state.label, systemImage: result.isCompleted ? "checkmark.seal.fill" : "exclamationmark.circle")
                    .foregroundColor(result.isCompleted ? .green : .orange)
                    .font(Typography.callout)
                    .accessibilityIdentifier("recipe.result.state")
                if !result.isCompleted {
                    Text("This run is not complete: see what was not done below. Nothing here was entered by hand.")
                        .font(Typography.caption1).foregroundColor(AppColors.secondary)
                }
                ForEach(result.notes, id: \.self) { Text($0).font(Typography.caption1) }
            }
            ForEach(Array(result.facts.enumerated()), id: \.offset) { _, facts in
                Section { RecipeResultFactsView(facts: facts) }
            }
        }
        Section {
            Button(String(localized: "Run again")) { stage = .choose; result = nil; destination = nil }
        }
    }
}

private extension Optional where Wrapped == SearchSpec {
    /// The clean-up's review: a search's frozen matches, or nil for the whole archive.
    @MainActor
    func asyncPreview(_ engine: PracticalRecipeEngine, scopeName: String) async throws -> RecipeSearchPreview? {
        guard let spec = self, !spec.isEmpty else { return nil }
        return try await engine.preview(spec: spec, scopeName: scopeName)
    }
}

/// SEARCH-04: the files that matched — attachments and files inside them —
/// with why they matched, Open, and an explicit choice of which to save.
struct RecipeFileBrowserView: View {
    let candidates: [RecipeFileCandidate]
    @Binding var chosen: Set<String>
    let spec: SearchSpec?
    @Binding var evidence: [EmailID: [MatchEvidence]]
    @State private var openFailure: String?
    @State private var onlyMatching = true

    private var shown: [RecipeFileCandidate] { onlyMatching ? candidates.filter(\.matchesConditions) : candidates }

    var body: some View {
        Section {
            Toggle(String(localized: "Only files that meet the conditions"), isOn: $onlyMatching)
            if shown.isEmpty {
                Text("No files here meet the conditions.").foregroundColor(AppColors.secondary)
            }
            ForEach(shown) { c in
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(isOn: Binding(get: { chosen.contains(c.id) },
                                         set: { if $0 { chosen.insert(c.id) } else { chosen.remove(c.id) } })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.filename).font(Typography.callout)
                            Text("\(c.family) · \(c.location) · \(c.subject)")
                                .font(Typography.caption2).foregroundColor(AppColors.secondary).lineLimit(2)
                            if let state = c.state, state != ChildDocument.State.extracted.rawValue {
                                Text(AttachmentChildrenList.stateLabel(state)).font(Typography.caption2).foregroundColor(.orange)
                            }
                        }
                    }
                    .accessibilityIdentifier("recipe.file.\(c.id)")
                    HStack {
                        if let items = evidence[c.emailID], !items.isEmpty {
                            MatchEvidenceChips(evidence: items, emailID: c.emailID) { ordinal, child in
                                Task { openFailure = await EvidenceAttachmentOpener.open(emailID: c.emailID, ordinal: ordinal, childPath: child, archive: .shared)?.message }
                            }
                        }
                        Spacer()
                        Button(String(localized: "Open")) {
                            Task { openFailure = await EvidenceAttachmentOpener.open(emailID: c.emailID, ordinal: c.ordinal, childPath: c.childPath, archive: .shared)?.message }
                        }
                        .buttonStyle(.borderless)
                        .disabled(c.isLocked)
                    }
                }
                .task(id: c.emailID) {
                    guard evidence[c.emailID] == nil, let spec else { return }
                    evidence[c.emailID] = (try? await ArchiveDataService.shared.matchEvidence(emailID: c.emailID, spec: spec, freeText: nil)) ?? []
                }
            }
            if let openFailure { Text(openFailure).font(Typography.caption1).foregroundColor(.red) }
        } header: {
            Text("Files — \(chosen.count) chosen of \(candidates.count)")
        } footer: {
            Text("A file inside a ZIP or an attached message is saved on its own only when you tick it. Locked files are listed in the receipt as not saved.")
        }
    }
}
