import SwiftUI
import os.log

// MARK: - Reasoning Studio — V3 Phase 1b
//
// The shared tier-2 method canvases from the kalsmritikosh job spec, scoped
// to email evidence: 5W1H worksheet (INV-05), Five Whys (INV-13/IND-19),
// Fishbone (INV-14), and a human-gated Root-Cause assessment (INV-15).
// Serves the "method workbench" job for every persona (LAW-16/JRN-16/RES-17,
// IND-15, causal-analysis variants).
//
// Evidence-gating rules honored:
// - 5W1H cells either cite emails or are explicitly marked UNKNOWN — no
//   fabricated answers.
// - Five Whys may stop early: a level without support is marked unsupported
//   and deeper levels are not required (never force five).
// - Fishbone bones are CANDIDATE causes only.
// - PROHIBITED OUTCOME: the app never confirms a root cause. Confirmation is
//   a recorded human decision with rationale.

// MARK: - Model

struct FiveWCell: Codable, Equatable {
    var answer: String = ""
    var evidence: [ACHEvidence] = []
    var markedUnknown: Bool = false

    var isComplete: Bool {
        markedUnknown || (!answer.trimmingCharacters(in: .whitespaces).isEmpty && !evidence.isEmpty)
    }
}

struct WhyLevel: Identifiable, Codable, Equatable {
    var id = UUID()
    var statement: String = ""
    var evidence: [ACHEvidence] = []
    var unsupported: Bool = false
}

struct FishboneBone: Identifiable, Codable, Equatable {
    var id = UUID()
    var category: String
    var causes: [String] = []
}

struct RootCauseCandidate: Identifiable, Codable, Equatable {
    var id = UUID()
    var statement: String
    var supportNote: String = ""
}

struct ReasoningCaseModel: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String = "Untitled reasoning case"
    var problemStatement: String = ""

    // 5W1H
    static let fiveWKeys = ["Who", "What", "When", "Where", "Why", "How"]
    var fiveW: [String: FiveWCell] = [:]

    // Five Whys
    var whys: [WhyLevel] = []

    // Fishbone
    var bones: [FishboneBone] = []

    // Root cause (human decision)
    var candidates: [RootCauseCandidate] = []
    var confirmedCandidateID: UUID?
    var decisionRationale: String = ""
    var decidedBy: String = ""
    var decidedAt: Date?

    var createdAt: Date = Date()
    var postedDocumentNumber: String?

    func cell(_ key: String) -> FiveWCell { fiveW[key] ?? FiveWCell() }

    var fiveWIncomplete: [String] {
        Self.fiveWKeys.filter { !cell($0).isComplete }
    }

    var postBlockers: [String] {
        var blockers: [String] = []
        if problemStatement.trimmingCharacters(in: .whitespaces).isEmpty {
            blockers.append("State the problem being analyzed.")
        }
        let missing = fiveWIncomplete
        if !missing.isEmpty {
            blockers.append("5W1H incomplete: \(missing.joined(separator: ", ")) — cite emails or mark UNKNOWN.")
        }
        if confirmedCandidateID != nil {
            if decisionRationale.trimmingCharacters(in: .whitespaces).isEmpty {
                blockers.append("A confirmed root cause requires a written rationale.")
            }
            if decidedBy.trimmingCharacters(in: .whitespaces).isEmpty {
                blockers.append("A confirmed root cause requires the decider's name.")
            }
        }
        return blockers
    }
}

// MARK: - Persistence

@MainActor
final class ReasoningCaseStore: ObservableObject {
    static let shared = ReasoningCaseStore()

    @Published var cases: [ReasoningCaseModel] = [] {
        didSet { if initialized { save() } }
    }

    private var initialized = false
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "mailin", category: "ReasoningStudio")

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mailin", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("reasoning_cases.json")
    }

    private init() {
        if let data = try? Data(contentsOf: fileURL) {
            cases = (try? JSONDecoder().decode([ReasoningCaseModel].self, from: data)) ?? []
        }
        initialized = true
    }

    private func save() {
        do {
            try JSONEncoder().encode(cases).write(to: fileURL, options: .atomic)
        } catch {
            log.error("Reasoning case save failed: \(error.localizedDescription)")
        }
    }

    func update(_ model: ReasoningCaseModel) {
        if let idx = cases.firstIndex(where: { $0.id == model.id }) {
            cases[idx] = model
        } else {
            cases.insert(model, at: 0)
        }
    }

    func delete(_ model: ReasoningCaseModel) {
        cases.removeAll { $0.id == model.id }
    }
}

// MARK: - Studio root

struct ReasoningStudioView: View {
    @StateObject private var store = ReasoningCaseStore.shared
    @State private var open: ReasoningCaseModel?

    var body: some View {
        Group {
            if let current = open {
                ReasoningCaseEditorView(model: current) { updated in
                    store.update(updated)
                    open = updated
                } onClose: { open = nil }
            } else {
                listView
            }
        }
    }

    private var listView: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reasoning Studio")
                        .font(Typography.headline)
                    Text("Structured analysis over email evidence: 5W1H, Five Whys, Fishbone, and a human-decided root cause. Cells cite emails or say UNKNOWN — never guesses.")
                        .font(Typography.caption1)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    var fresh = ReasoningCaseModel()
                    fresh.title = "Case \(store.cases.count + 1)"
                    store.update(fresh)
                    open = fresh
                } label: { Label("New Case", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
            }
            .padding([.horizontal, .top])

            if store.cases.isEmpty {
                ContentUnavailableView(
                    "No reasoning cases yet",
                    systemImage: "brain.head.profile",
                    description: Text("Create a case, state the problem, and work the methods with cited email evidence.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(store.cases) { c in
                        Button { open = c } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(c.title).fontWeight(.semibold)
                                    if let doc = c.postedDocumentNumber {
                                        Text(doc)
                                            .font(.caption2.monospaced())
                                            .padding(.horizontal, 6).padding(.vertical, 1)
                                            .background(Color.green.opacity(0.15))
                                            .clipShape(Capsule())
                                    }
                                }
                                Text("\(6 - c.fiveWIncomplete.count)/6 5W1H · \(c.whys.count) whys · \(c.candidates.count) candidate causes\(c.confirmedCandidateID != nil ? " · decided" : "")")
                                    .font(Typography.caption1).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { idx in for i in idx { store.delete(store.cases[i]) } }
                }
                .listStyle(.plain)
            }
        }
    }
}

// MARK: - Editor

struct ReasoningCaseEditorView: View {
    @State var model: ReasoningCaseModel
    var onSave: (ReasoningCaseModel) -> Void
    var onClose: () -> Void

    private enum Tab: String, CaseIterable {
        case fiveW = "5W1H", whys = "Five Whys", fishbone = "Fishbone", rootCause = "Root Cause"
    }
    @State private var tab: Tab = .fiveW
    @State private var pickerForKey: String?          // 5W1H cell key
    @State private var pickerForWhy: UUID?            // Why level id
    @State private var newBoneCategory = ""
    @State private var newCandidateText = ""
    @State private var showPostConfirm = false
    @State private var postResult: String?
    @State private var isPosting = false

    var body: some View {
        VStack(spacing: 0) {
            header
            TextField("Problem statement (what happened / what is being analyzed)…", text: $model.problemStatement, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
                .padding(.horizontal)
                .onSubmit { onSave(model) }
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding([.horizontal, .top])
            Divider().padding(.top, Spacing.xSmall)

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.medium) {
                    switch tab {
                    case .fiveW: fiveWTab
                    case .whys: whysTab
                    case .fishbone: fishboneTab
                    case .rootCause: rootCauseTab
                    }
                    postPanel
                }
                .padding()
            }
        }
        .sheet(isPresented: Binding(
            get: { pickerForKey != nil || pickerForWhy != nil },
            set: { if !$0 { pickerForKey = nil; pickerForWhy = nil } }
        )) {
            ArchiveEmailPickerView { picked in
                let fmt = DateFormatter(); fmt.dateStyle = .medium; fmt.timeStyle = .short
                let rows = picked.map { s in
                    ACHEvidence(summary: s.subject.isEmpty ? s.bodyPreview : s.subject,
                                emailID: s.id, messageID: s.messageID,
                                fromLine: s.from, dateLine: fmt.string(from: s.date))
                }
                if let key = pickerForKey {
                    var cell = model.cell(key)
                    cell.evidence.append(contentsOf: rows)
                    cell.markedUnknown = false
                    model.fiveW[key] = cell
                } else if let whyID = pickerForWhy,
                          let idx = model.whys.firstIndex(where: { $0.id == whyID }) {
                    model.whys[idx].evidence.append(contentsOf: rows)
                    model.whys[idx].unsupported = false
                }
                pickerForKey = nil; pickerForWhy = nil
                onSave(model)
            } onCancel: { pickerForKey = nil; pickerForWhy = nil }
        }
        .confirmationDialog("Post reasoning document?", isPresented: $showPostConfirm, titleVisibility: .visible) {
            Button("Confirm — analysis reviewed") { Task { await postDocument() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The document records the 5W1H worksheet (with UNKNOWNs), the Why chain (unsupported levels labelled), candidate causes, and — only if you made one — your root-cause decision with rationale. The app confirms nothing on its own.")
        }
    }

    private var header: some View {
        HStack {
            Button { onSave(model); onClose() } label: { Label("Cases", systemImage: "chevron.left") }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            TextField("Case title", text: $model.title)
                .textFieldStyle(.plain)
                .font(Typography.headline)
                .onSubmit { onSave(model) }
            Spacer()
            if let posted = model.postedDocumentNumber {
                Label(posted, systemImage: "number.square")
                    .font(.caption.monospaced())
                    .foregroundStyle(.green)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, Spacing.xSmall)
    }

    // MARK: 5W1H

    private var fiveWTab: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text("EACH CELL: CITE EMAILS OR MARK UNKNOWN — NEVER GUESS")
                .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            ForEach(ReasoningCaseModel.fiveWKeys, id: \.self) { key in
                fiveWRow(key)
            }
        }
    }

    private func fiveWRow(_ key: String) -> some View {
        let cell = model.cell(key)
        return VStack(alignment: .leading, spacing: Spacing.xxSmall) {
            HStack {
                Text(key.uppercased())
                    .font(.caption2.weight(.bold))
                    .frame(width: 52, alignment: .leading)
                    .foregroundStyle(cell.isComplete ? Color.green : Color.orange)
                TextField(cell.markedUnknown ? "UNKNOWN" : "Answer from the evidence…", text: Binding(
                    get: { model.cell(key).answer },
                    set: { model.fiveW[key, default: FiveWCell()].answer = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .font(Typography.caption1)
                .disabled(cell.markedUnknown)
                .onSubmit { onSave(model) }

                Button { pickerForKey = key } label: { Image(systemName: "envelope.badge.plus") }
                    .buttonStyle(.plain)
                    .help("Cite emails for \(key)")

                Toggle(isOn: Binding(
                    get: { model.cell(key).markedUnknown },
                    set: { newVal in
                        model.fiveW[key, default: FiveWCell()].markedUnknown = newVal
                        onSave(model)
                    }
                )) { Text("Unknown").font(.caption2) }
                .toggleStyle(.button)
                .controlSize(.small)
            }
            if !cell.evidence.isEmpty {
                ForEach(cell.evidence) { e in
                    Text("· \(e.summary) — \(e.locatorLine)")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        .padding(.leading, 56)
                }
            }
        }
        .padding(Spacing.xxSmall)
        .background(AppColors.backgroundSecondary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: Five Whys

    private var whysTab: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text("STOP WHEN EVIDENCE RUNS OUT — NEVER FORCE FIVE LEVELS")
                .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)

            ForEach(Array($model.whys.enumerated()), id: \.element.id) { idx, $why in
                VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                    HStack {
                        Text("WHY \(idx + 1)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(why.unsupported ? Color.orange : Color.blue)
                            .frame(width: 52, alignment: .leading)
                        TextField("Because…", text: $why.statement)
                            .textFieldStyle(.roundedBorder)
                            .font(Typography.caption1)
                            .onSubmit { onSave(model) }
                        Button { pickerForWhy = why.id } label: { Image(systemName: "envelope.badge.plus") }
                            .buttonStyle(.plain)
                        Toggle(isOn: $why.unsupported) { Text("Unsupported").font(.caption2) }
                            .toggleStyle(.button)
                            .controlSize(.small)
                            .onChange(of: why.unsupported) { _, _ in onSave(model) }
                    }
                    ForEach(why.evidence) { e in
                        Text("· \(e.summary) — \(e.locatorLine)")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            .padding(.leading, 56)
                    }
                    if why.unsupported {
                        Text("This level is a conjecture — the chain stops being evidential here.")
                            .font(.caption2).foregroundStyle(.orange)
                            .padding(.leading, 56)
                    }
                }
                .padding(Spacing.xxSmall)
                .background(AppColors.backgroundSecondary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                Button {
                    model.whys.append(WhyLevel())
                    onSave(model)
                } label: { Label("Add why level", systemImage: "plus") }
                if let last = model.whys.last {
                    Button(role: .destructive) {
                        model.whys.removeAll { $0.id == last.id }
                        onSave(model)
                    } label: { Label("Remove last", systemImage: "minus") }
                }
            }
        }
    }

    // MARK: Fishbone

    private var fishboneTab: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text("BONES ARE CANDIDATE CAUSES — NOT CONCLUSIONS")
                .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)

            ForEach($model.bones) { $bone in
                VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                    HStack {
                        Text(bone.category).font(Typography.caption1.weight(.bold))
                        Spacer()
                        Button {
                            bone.causes.append("")
                            onSave(model)
                        } label: { Image(systemName: "plus.circle") }
                        .buttonStyle(.plain)
                    }
                    ForEach(bone.causes.indices, id: \.self) { i in
                        TextField("Candidate cause…", text: $bone.causes[i])
                            .textFieldStyle(.roundedBorder)
                            .font(.caption2)
                            .onSubmit { onSave(model) }
                    }
                }
                .padding(Spacing.xSmall)
                .background(AppColors.backgroundSecondary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.medium))
                .contextMenu {
                    Button(role: .destructive) {
                        model.bones.removeAll { $0.id == bone.id }
                        onSave(model)
                    } label: { Label("Remove branch", systemImage: "trash") }
                }
            }

            HStack {
                TextField("Branch (People, Process, Systems, External…)", text: $newBoneCategory)
                    .textFieldStyle(.roundedBorder)
                Button {
                    let t = newBoneCategory.trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty else { return }
                    model.bones.append(FishboneBone(category: t))
                    newBoneCategory = ""
                    onSave(model)
                } label: { Image(systemName: "plus.circle.fill") }
                .buttonStyle(.plain)
                .disabled(newBoneCategory.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    // MARK: Root cause

    private var rootCauseTab: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text("THE APP NEVER CONFIRMS A ROOT CAUSE — YOU DO, ON THE RECORD")
                .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)

            ForEach($model.candidates) { $cand in
                HStack(alignment: .top) {
                    Button {
                        model.confirmedCandidateID = model.confirmedCandidateID == cand.id ? nil : cand.id
                        onSave(model)
                    } label: {
                        Image(systemName: model.confirmedCandidateID == cand.id ? "checkmark.seal.fill" : "seal")
                            .foregroundStyle(model.confirmedCandidateID == cand.id ? Color.green : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Mark as YOUR confirmed root cause")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cand.statement).font(Typography.caption1.weight(.semibold))
                        TextField("Supporting note (which whys/bones/evidence back this)…", text: $cand.supportNote)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption2)
                            .onSubmit { onSave(model) }
                    }
                }
                .padding(Spacing.xSmall)
                .background(AppColors.backgroundSecondary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.medium))
                .contextMenu {
                    Button(role: .destructive) {
                        if model.confirmedCandidateID == cand.id { model.confirmedCandidateID = nil }
                        model.candidates.removeAll { $0.id == cand.id }
                        onSave(model)
                    } label: { Label("Remove candidate", systemImage: "trash") }
                }
            }

            HStack {
                TextField("Add a candidate cause…", text: $newCandidateText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addCandidate() }
                Button { addCandidate() } label: { Image(systemName: "plus.circle.fill") }
                    .buttonStyle(.plain)
                    .disabled(newCandidateText.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if model.confirmedCandidateID != nil {
                TextField("Decision rationale (required)…", text: $model.decisionRationale, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
                    .onSubmit { onSave(model) }
                TextField("Decided by (your name — required)", text: $model.decidedBy)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        model.decidedAt = Date()
                        onSave(model)
                    }
            }
        }
    }

    private func addCandidate() {
        let t = newCandidateText.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        model.candidates.append(RootCauseCandidate(statement: t))
        newCandidateText = ""
        onSave(model)
    }

    // MARK: Post

    private var postPanel: some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            let blockers = model.postBlockers
            ForEach(blockers, id: \.self) { b in
                Label(b, systemImage: "lock").font(Typography.caption1).foregroundStyle(.orange)
            }
            HStack {
                Button { showPostConfirm = true } label: {
                    if isPosting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(model.postedDocumentNumber == nil ? "Post numbered reasoning document" : "Post revision", systemImage: "number.square")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!blockers.isEmpty || isPosting)
                if let result = postResult {
                    Text(result).font(Typography.caption1).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.bottom, Spacing.large)
    }

    private func postDocument() async {
        isPosting = true
        defer { isPosting = false }

        var sections: [CapturedDocument.Section] = []
        sections.append(.init(name: "Problem", fields: [
            .init(key: "Statement", value: model.problemStatement),
            .init(key: "Method note", value: "5W1H cells cite emails or are UNKNOWN; Why levels stop when unsupported; fishbone bones are candidates; any root-cause confirmation is a recorded human decision."),
        ]))
        sections.append(.init(name: "5W1H", fields:
            ReasoningCaseModel.fiveWKeys.map { key in
                let c = model.cell(key)
                if c.markedUnknown { return .init(key: key, value: "UNKNOWN — no supporting evidence in scope") }
                let locs = c.evidence.map(\.locatorLine).joined(separator: " | ")
                return .init(key: key, value: "\(c.answer)\(locs.isEmpty ? "" : " [\(locs)]")")
            }
        ))
        if !model.whys.isEmpty {
            sections.append(.init(name: "Five Whys", fields:
                model.whys.enumerated().map { idx, w in
                    let locs = w.evidence.map(\.locatorLine).joined(separator: " | ")
                    let flag = w.unsupported ? " [UNSUPPORTED — conjecture]" : (locs.isEmpty ? "" : " [\(locs)]")
                    return .init(key: "Why \(idx + 1)", value: w.statement + flag)
                }
            ))
        }
        for bone in model.bones where !bone.causes.isEmpty {
            sections.append(.init(name: "Fishbone — \(bone.category)", fields:
                bone.causes.filter { !$0.isEmpty }.map { .init(key: "Candidate", value: $0) }
            ))
        }
        if !model.candidates.isEmpty {
            sections.append(.init(name: "Root-cause assessment", fields:
                model.candidates.map { c in
                    let confirmed = model.confirmedCandidateID == c.id
                    return .init(key: c.statement, value: confirmed
                        ? "CONFIRMED by \(model.decidedBy): \(model.decisionRationale)"
                        : "candidate\(c.supportNote.isEmpty ? "" : " — \(c.supportNote)")")
                }
            ))
        }

        let refs = (model.fiveW.values.flatMap(\.evidence) + model.whys.flatMap(\.evidence))
            .compactMap(\.messageID).joined(separator: " ")
        let number = await DocumentRegistry.captureStructured(
            .report,
            summary: "Reasoning: \(model.title)\(model.confirmedCandidateID != nil ? " — root cause decided" : "")",
            document: CapturedDocument(title: "Reasoning — \(model.title)", sections: sections),
            refs: refs
        )
        if let number {
            model.postedDocumentNumber = number
            onSave(model)
            postResult = "Posted \(number)"
        } else {
            postResult = "Posting failed — check the document registry."
        }
    }
}
