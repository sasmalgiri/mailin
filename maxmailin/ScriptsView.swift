//
//  ScriptsView.swift
//  maxmailin
//
//  3.1 S6–S11 screen: the script library, an editor, dry run then apply over
//  a search scope, import-time switch per script, no-code recipes, the
//  on-device assistant, .mailinscript files and the run history with
//  "Re-run and prove". Shown only while Capability.v31Scripts is on.
//

import SwiftUI
import UniformTypeIdentifiers
@testable import ArchiveCore

struct ScriptsView: View {
    @State private var library = ScriptLibraryStore.shared
    @State private var selectedID: UUID?
    @State private var editing: MailinScript?
    @State private var showRecipe = false
    @State private var showImport = false
    @State private var history: [SQLiteEmailStore.ScriptRunRow] = []
    @State private var status: String?

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedID) {
                Section(String(localized: "Bundled")) {
                    ForEach(library.scripts.filter(\.builtIn)) { row($0) }
                }
                Section(String(localized: "Yours")) {
                    ForEach(library.scripts.filter { !$0.builtIn }) { row($0) }
                }
            }
            .toolbar {
                Menu {
                    Button(String(localized: "New script")) {
                        editing = MailinScript(name: String(localized: "New script"), source: "function process(email) {\n  \n}\n")
                    }
                    Button(String(localized: "New recipe (no code)…")) { showRecipe = true }
                    Button(String(localized: "Import .mailinscript…")) { showImport = true }
                } label: { Label("Add", systemImage: "plus") }
            }
        } detail: {
            if let s = library.scripts.first(where: { $0.id == selectedID }) {
                ScriptDetailView(script: s, edit: { editing = $0 }, history: history.filter { $0.name == s.name },
                                 onRun: { Task { await reloadHistory() } })
            } else {
                VStack(alignment: .leading, spacing: Spacing.small) {
                    Text("Scripts run on this device only and never reach the network. Choose a script to run it over a search, or add your own.")
                    Text("Limits: a script is stopped when one email takes more than \(Int(ScriptPolicy.perEmailSeconds)) seconds or the app's memory passes \(ScriptPolicy.memoryCeiling / 1_073_741_824) GB.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let status { Text(status).font(.callout) }
                }
                .padding()
            }
        }
        .navigationTitle(String(localized: "Scripts"))
        .task { await reloadHistory() }
        .sheet(item: $editing) { s in
            ScriptEditorView(script: s) { saved in
                library.upsert(saved)
                selectedID = saved.id
            }
            .frame(minWidth: 640, minHeight: 480)
        }
        .sheet(isPresented: $showRecipe) {
            RecipeBuilderView { s in
                library.upsert(s)
                selectedID = s.id
            }
            .frame(minWidth: 640, minHeight: 480)
        }
        .fileImporter(isPresented: $showImport, allowedContentTypes: [.data, .json, .item]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let s = try ScriptFile.importScript(try Data(contentsOf: url))
                library.upsert(s)
                selectedID = s.id
                status = String(localized: "Imported \(s.label). Read it before you run it.")
            } catch {
                status = error.localizedDescription
            }
        }
    }

    private func row(_ s: MailinScript) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Text(s.name)
                if s.runsAtImport { Image(systemName: "tray.and.arrow.down").help(String(localized: "Runs at import")) }
            }
            Text(s.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .tag(s.id)
    }

    private func reloadHistory() async {
        history = (try? await SQLiteEmailStore.shared.scriptRuns()) ?? []
    }
}

struct ScriptDetailView: View {
    let script: MailinScript
    let edit: (MailinScript) -> Void
    let history: [SQLiteEmailStore.ScriptRunRow]
    let onRun: () -> Void
    @State private var library = ScriptLibraryStore.shared
    @State private var search = ""
    @State private var scopeCount: Int?
    @State private var dryRun: ScriptRunSummary?
    @State private var result: String?
    @State private var running = false
    @State private var progress: Double = 0
    @State private var runTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                Text(script.summary)
                LabeledContent(String(localized: "Version"), value: script.version)
                LabeledContent(String(localized: "SHA-256"), value: String(script.sha256.prefix(16)) + "…")
                Toggle(String(localized: "Also run on newly imported mail"), isOn: Binding(
                    get: { script.runsAtImport }, set: { library.setRunsAtImport(script.id, $0) }))
                HStack {
                    Button(script.builtIn ? String(localized: "Copy and edit…") : String(localized: "Edit…")) {
                        var s = script
                        if s.builtIn { s.id = UUID(); s.builtIn = false; s.name += String(localized: " (copy)") }
                        edit(s)
                    }
                    Button(String(localized: "Export .mailinscript…")) {
                        if let data = try? ScriptFile.export(script) {
                            result = PlatformExport.save(data: data, suggestedName: "\(script.name).\(ScriptFile.fileExtension)")
                                .message(String(localized: "Script"))
                        }
                    }
                    if !script.builtIn {
                        Button(String(localized: "Delete"), role: .destructive) { library.delete(script.id) }
                    }
                }
            } header: { Text(script.label) }

            Section {
                TextField(String(localized: "Search (empty = whole archive)"), text: $search)
                    .onSubmit { Task { await count() } }
                if let scopeCount { Text("\(scopeCount) emails in scope.").font(.callout) }
                if running {
                    ProgressView(value: progress)
                    Button(String(localized: "Stop")) { runTask?.cancel() }
                } else {
                    Button(String(localized: "Dry run (writes nothing)")) { start(apply: false) }
                    if let dryRun {
                        Text(dryRun.line).font(.callout)
                        Text("\(dryRun.emailsChanged) emails would change.").font(.callout)
                        Button(String(localized: "Apply to \(dryRun.processed) emails")) { start(apply: true) }
                            .disabled(dryRun.emailsChanged == 0)
                        if !dryRun.report.isEmpty {
                            DisclosureGroup(String(localized: "Report (\(dryRun.report.count) lines)")) {
                                Text(dryRun.report.prefix(500).joined(separator: "\n")).font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }
                        if !dryRun.errors.isEmpty {
                            DisclosureGroup(String(localized: "Errors (\(dryRun.errors.count))")) {
                                Text(dryRun.errors.joined(separator: "\n")).font(.caption.monospaced())
                            }
                        }
                    }
                }
                if let result { Text(result).font(.callout).textSelection(.enabled) }
            } header: { Text("Run") }

            if !history.isEmpty {
                Section {
                    ForEach(history.prefix(20), id: \.runID) { r in
                        HStack {
                            VStack(alignment: .leading) {
                                Text("\(r.startedAt.formatted()) · v\(r.version) · \(r.processed) emails · \(r.startedBy)")
                                Text(r.changesJSON).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button(String(localized: "Re-run and prove")) {
                                Task { result = (try? await ScriptEngine.prove(r, script: script)) ?? String(localized: "The run could not be repeated.") }
                            }
                        }
                    }
                } header: { Text("Runs") }
            }

            Section {
                Text(script.source).font(.caption.monospaced()).textSelection(.enabled)
            } header: { Text("Code") }
        }
        .formStyle(.grouped)
        .task(id: script.id) { dryRun = nil; result = nil; await count() }
    }

    private var query: EmailQuery { ArchiveQueryCompiler.compile(search) }

    private func count() async {
        scopeCount = try? await ArchiveDataService.shared.count(query: query)
    }

    private func start(apply: Bool) {
        running = true
        progress = 0
        runTask = Task {
            defer { running = false; onRun() }
            do {
                let s = try await ScriptEngine.run(script, query: query, apply: apply) { done, total in
                    progress = total > 0 ? Double(done) / Double(total) : 1
                }
                if apply {
                    result = String(localized: "Applied: \(s.line).")
                    dryRun = nil
                } else {
                    dryRun = s
                }
            } catch {
                result = error.localizedDescription
            }
        }
    }
}

struct ScriptEditorView: View {
    @State var script: MailinScript
    let onSave: (MailinScript) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var check: String?
    @State private var ask = ""
    @State private var drafting = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            TextField(String(localized: "Name"), text: $script.name)
            TextField(String(localized: "What it does"), text: $script.summary)
            TextEditor(text: $script.source).font(.body.monospaced())
            if #available(macOS 26.0, iOS 26.0, *), ScriptAssistant.isAvailable {
                HStack {
                    TextField(String(localized: "Describe a script and let the on-device model draft it"), text: $ask)
                    Button(drafting ? String(localized: "Drafting…") : String(localized: "Draft")) {
                        drafting = true
                        Task {
                            defer { drafting = false }
                            do {
                                script.source = try await ScriptAssistant.draft(ask)
                                check = String(localized: "Draft ready. Read it and press Check before saving.")
                            } catch { check = error.localizedDescription }
                        }
                    }
                    .disabled(ask.isEmpty || drafting)
                }
            }
            if let check { Text(check).font(.callout) }
            HStack {
                Button(String(localized: "Check")) { check = validate() ?? String(localized: "The script compiles.") }
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }
                Button(String(localized: "Save")) {
                    if let problem = validate() { check = problem; return }
                    onSave(script)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
    }

    private func validate() -> String? {
        do { _ = try ScriptRuntime(script); return nil } catch { return error.localizedDescription }
    }
}

struct RecipeBuilderView: View {
    let onSave: (MailinScript) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var recipe = ScriptRecipe()

    var body: some View {
        Form {
            TextField(String(localized: "Name"), text: $recipe.name)
            Picker(String(localized: "Match"), selection: $recipe.matchAll) {
                Text("All conditions").tag(true)
                Text("Any condition").tag(false)
            }
            Section {
                ForEach($recipe.conditions) { $c in
                    HStack {
                        Picker("", selection: $c.field) { ForEach(ScriptRecipe.Field.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        Picker("", selection: $c.op) { ForEach(ScriptRecipe.Op.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        TextField(String(localized: "Value"), text: $c.value)
                    }
                }
                Button(String(localized: "Add condition")) { recipe.conditions.append(.init(field: .subject, op: .contains, value: "")) }
            } header: { Text("When") }
            Section {
                ForEach($recipe.actions) { $a in
                    HStack {
                        Picker("", selection: $a.kind) { ForEach(ScriptRecipe.ActionKind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        TextField(a.kind == .column ? String(localized: "Column") : String(localized: "Value"), text: $a.value)
                        if a.kind == .column { TextField(String(localized: "Column value"), text: $a.value2) }
                    }
                }
                Button(String(localized: "Add action")) { recipe.actions.append(.init(kind: .tag, value: "")) }
            } header: { Text("Then") }
            Section {
                Text(recipe.source).font(.caption.monospaced()).textSelection(.enabled)
            } header: { Text("Generated code") }
            HStack {
                Button(String(localized: "Cancel")) { dismiss() }
                Spacer()
                Button(String(localized: "Save as script")) {
                    onSave(MailinScript(name: recipe.name, summary: String(localized: "Recipe"), source: recipe.source))
                    dismiss()
                }
                .disabled(recipe.actions.isEmpty)
            }
        }
        .formStyle(.grouped)
    }
}
