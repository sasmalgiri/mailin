import SwiftUI
import os.log

// MARK: - Fact–Evidence Matrix — V3 Phase 2 (kalsmritikosh LAW-04)
//
// Deposition-grade mapping of contested facts to the emails that support or
// oppose them. Evidence-gating rules honored:
// - Every evidence link carries an email locator (Message-ID + date) or is an
//   acknowledged assumption (reuses ACHEvidence).
// - HONESTY LABELS: each fact is labeled supported / contested / opposed /
//   unsupported — contested facts keep BOTH sides; absence of evidence is
//   surfaced, never hidden.
// - The numbered document cannot post while any fact is unsupported and
//   unacknowledged, and posting requires explicit human confirmation.

enum FEStance: String, Codable, CaseIterable {
    case supports = "Supports"
    case opposes = "Opposes"

    var color: Color { self == .supports ? .green : .red }
    var icon: String { self == .supports ? "checkmark.circle" : "xmark.circle" }
}

enum FEFactStatus: String {
    case supported = "Supported"
    case contested = "Contested"
    case opposed = "Opposed"
    case unsupported = "Unsupported"

    var color: Color {
        switch self {
        case .supported: return .green
        case .contested: return .orange
        case .opposed: return .red
        case .unsupported: return .gray
        }
    }
}

struct FEFact: Identifiable, Codable, Equatable {
    var id = UUID()
    var statement: String
    /// A fact with no evidence can only remain in a posted document if the
    /// author explicitly acknowledges it as an open item.
    var acknowledgedOpen: Bool = false
}

struct FactEvidenceModel: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String = "Untitled matter"
    var facts: [FEFact] = []
    var evidence: [ACHEvidence] = []
    /// factID → evidenceID → stance
    var links: [UUID: [UUID: FEStance]] = [:]
    var notes: String = ""
    var createdAt: Date = Date()
    var postedDocumentNumber: String?

    func evidence(for fact: FEFact, stance: FEStance) -> [ACHEvidence] {
        let ids = (links[fact.id] ?? [:]).filter { $0.value == stance }.map(\.key)
        return evidence.filter { ids.contains($0.id) }
    }

    func status(for fact: FEFact) -> FEFactStatus {
        let s = evidence(for: fact, stance: .supports).count
        let o = evidence(for: fact, stance: .opposes).count
        switch (s > 0, o > 0) {
        case (true, true): return .contested
        case (true, false): return .supported
        case (false, true): return .opposed
        case (false, false): return .unsupported
        }
    }

    var postBlockers: [String] {
        var blockers: [String] = []
        if facts.isEmpty { blockers.append("Add at least one fact.") }
        let unsupported = facts.filter { status(for: $0) == .unsupported && !$0.acknowledgedOpen }
        if !unsupported.isEmpty {
            blockers.append("\(unsupported.count) fact(s) have no evidence — link emails or acknowledge them as open items.")
        }
        let unackedAssumptions = evidence.filter { !$0.isCited && !$0.isAssumption }
        if !unackedAssumptions.isEmpty {
            blockers.append("\(unackedAssumptions.count) uncited evidence row(s) must be marked as assumptions.")
        }
        return blockers
    }
}

// MARK: - Persistence

@MainActor
final class FactEvidenceStore: ObservableObject {
    static let shared = FactEvidenceStore()

    @Published var matrices: [FactEvidenceModel] = [] {
        didSet { if initialized { save() } }
    }

    private var initialized = false
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "mailin", category: "FactEvidence")

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mailin", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("fact_evidence_matrices.json")
    }

    private init() {
        if let data = try? Data(contentsOf: fileURL) {
            matrices = (try? JSONDecoder().decode([FactEvidenceModel].self, from: data)) ?? []
        }
        initialized = true
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(matrices)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            log.error("Fact-evidence save failed: \(error.localizedDescription)")
        }
    }

    func update(_ model: FactEvidenceModel) {
        if let idx = matrices.firstIndex(where: { $0.id == model.id }) {
            matrices[idx] = model
        } else {
            matrices.insert(model, at: 0)
        }
    }

    func delete(_ model: FactEvidenceModel) {
        matrices.removeAll { $0.id == model.id }
    }
}

// MARK: - Studio root

struct FactEvidenceStudioView: View {
    @StateObject private var store = FactEvidenceStore.shared
    @State private var open: FactEvidenceModel?

    var body: some View {
        Group {
            if let current = open {
                FactEvidenceEditorView(model: current) { updated in
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
                    Text("Fact–Evidence Matrix")
                        .font(Typography.headline)
                    Text("Map each contested fact to the emails that support or oppose it. Both sides are preserved; unsupported facts are labeled, never hidden.")
                        .font(Typography.caption1)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    var fresh = FactEvidenceModel()
                    fresh.title = "Matter \(store.matrices.count + 1)"
                    store.update(fresh)
                    open = fresh
                } label: { Label("New Matrix", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
            }
            .padding([.horizontal, .top])

            if store.matrices.isEmpty {
                ContentUnavailableView(
                    "No matrices yet",
                    systemImage: "checklist",
                    description: Text("Create a matrix, state the facts at issue, and link supporting or opposing emails to each.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(store.matrices) { m in
                        Button { open = m } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(m.title).fontWeight(.semibold)
                                    if let doc = m.postedDocumentNumber {
                                        Text(doc)
                                            .font(.caption2.monospaced())
                                            .padding(.horizontal, 6).padding(.vertical, 1)
                                            .background(Color.green.opacity(0.15))
                                            .clipShape(Capsule())
                                    }
                                }
                                Text("\(m.facts.count) facts · \(m.evidence.count) evidence rows")
                                    .font(Typography.caption1).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { idx in for i in idx { store.delete(store.matrices[i]) } }
                }
                .listStyle(.plain)
            }
        }
    }
}

// MARK: - Editor

struct FactEvidenceEditorView: View {
    @State var model: FactEvidenceModel
    var onSave: (FactEvidenceModel) -> Void
    var onClose: () -> Void

    @State private var newFactText = ""
    @State private var pickerTarget: (fact: FEFact, stance: FEStance)?
    @State private var showPostConfirm = false
    @State private var postResult: String?
    @State private var isPosting = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.medium) {
                    factList
                    notesPanel
                    postPanel
                }
                .padding()
            }
        }
        .sheet(isPresented: Binding(
            get: { pickerTarget != nil },
            set: { if !$0 { pickerTarget = nil } }
        )) {
            if let target = pickerTarget {
                ArchiveEmailPickerView { picked in
                    attach(picked, to: target.fact, stance: target.stance)
                    pickerTarget = nil
                } onCancel: { pickerTarget = nil }
            }
        }
        .confirmationDialog("Post fact–evidence document?", isPresented: $showPostConfirm, titleVisibility: .visible) {
            Button("Confirm — facts and statuses reviewed") { Task { await postDocument() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The document records every fact with its status (supported / contested / opposed / unsupported), both sides of the evidence, and all locators. Contested and open items are preserved, not resolved by the app.")
        }
    }

    private var header: some View {
        HStack {
            Button {
                onSave(model); onClose()
            } label: { Label("Matrices", systemImage: "chevron.left") }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)

            TextField("Matter title", text: $model.title)
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

    private var factList: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text("FACTS AT ISSUE")
                .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)

            ForEach(model.facts) { fact in
                factCard(fact)
            }

            HStack {
                TextField("State a fact at issue…", text: $newFactText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addFact() }
                Button { addFact() } label: { Image(systemName: "plus.circle.fill") }
                    .buttonStyle(.plain)
                    .disabled(newFactText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func addFact() {
        let t = newFactText.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        model.facts.append(FEFact(statement: t))
        newFactText = ""
        onSave(model)
    }

    private func factCard(_ fact: FEFact) -> some View {
        let status = model.status(for: fact)
        return VStack(alignment: .leading, spacing: Spacing.xSmall) {
            HStack(alignment: .top) {
                Text(fact.statement)
                    .font(Typography.caption1.weight(.semibold))
                Spacer()
                Text(status.rawValue)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(status.color.opacity(0.15))
                    .foregroundStyle(status.color)
                    .clipShape(Capsule())
            }

            ForEach(FEStance.allCases, id: \.self) { stance in
                let rows = model.evidence(for: fact, stance: stance)
                HStack(alignment: .top, spacing: Spacing.xSmall) {
                    Label(stance.rawValue, systemImage: stance.icon)
                        .font(.caption2)
                        .foregroundStyle(stance.color)
                        .frame(width: 84, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        if rows.isEmpty {
                            Text("none").font(.caption2).foregroundStyle(.tertiary)
                        }
                        ForEach(rows) { e in
                            VStack(alignment: .leading, spacing: 0) {
                                Text(e.summary).font(.caption2).lineLimit(1)
                                Text(e.locatorLine).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .contextMenu {
                                Button(role: .destructive) {
                                    model.links[fact.id]?[e.id] = nil
                                    onSave(model)
                                } label: { Label("Unlink", systemImage: "link.badge.minus") }
                            }
                        }
                    }
                    Spacer()
                    Button {
                        pickerTarget = (fact, stance)
                    } label: {
                        Image(systemName: "envelope.badge.plus").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("Link emails that \(stance.rawValue.lowercased()) this fact")
                }
            }

            if status == .unsupported {
                Toggle(isOn: Binding(
                    get: { fact.acknowledgedOpen },
                    set: { newVal in
                        if let idx = model.facts.firstIndex(where: { $0.id == fact.id }) {
                            model.facts[idx].acknowledgedOpen = newVal
                            onSave(model)
                        }
                    }
                )) {
                    Text("Acknowledge as OPEN ITEM (no evidence yet — absence is not proof)")
                        .font(.caption2).foregroundStyle(.orange)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
        }
        .padding(Spacing.xSmall)
        .background(AppColors.backgroundSecondary.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.medium))
        .contextMenu {
            Button(role: .destructive) {
                model.facts.removeAll { $0.id == fact.id }
                model.links[fact.id] = nil
                onSave(model)
            } label: { Label("Delete fact", systemImage: "trash") }
        }
    }

    private func attach(_ picked: [EmailSummary], to fact: FEFact, stance: FEStance) {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium; fmt.timeStyle = .short
        for s in picked {
            // Reuse an existing evidence row for the same email if present.
            let existing = model.evidence.first { $0.emailID == s.id }
            let row: ACHEvidence
            if let existing {
                row = existing
            } else {
                row = ACHEvidence(
                    summary: s.subject.isEmpty ? s.bodyPreview : s.subject,
                    emailID: s.id,
                    messageID: s.messageID,
                    fromLine: s.from,
                    dateLine: fmt.string(from: s.date)
                )
                model.evidence.append(row)
            }
            model.links[fact.id, default: [:]][row.id] = stance
        }
        onSave(model)
    }

    private var notesPanel: some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            Text("NOTES")
                .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            TextField("Context, caveats, standard of proof…", text: $model.notes, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
                .onSubmit { onSave(model) }
        }
    }

    private var postPanel: some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            let blockers = model.postBlockers
            ForEach(blockers, id: \.self) { b in
                Label(b, systemImage: "lock").font(Typography.caption1).foregroundStyle(.orange)
            }
            HStack {
                Button {
                    showPostConfirm = true
                } label: {
                    if isPosting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(model.postedDocumentNumber == nil ? "Post numbered fact–evidence document" : "Post revision", systemImage: "number.square")
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
        sections.append(.init(name: "Method", fields: [
            .init(key: "Technique", value: "Fact–evidence matrix: each fact mapped to supporting and opposing emails with locators; both sides preserved."),
            .init(key: "Open items", value: "Facts without evidence are recorded as OPEN — absence of evidence is not evidence of absence."),
        ]))
        for fact in model.facts {
            var fields: [CapturedDocument.Field] = [
                .init(key: "Status", value: model.status(for: fact).rawValue)
            ]
            for e in model.evidence(for: fact, stance: .supports) {
                fields.append(.init(key: "Supports: \(e.summary)", value: e.locatorLine))
            }
            for e in model.evidence(for: fact, stance: .opposes) {
                fields.append(.init(key: "Opposes: \(e.summary)", value: e.locatorLine))
            }
            if model.status(for: fact) == .unsupported {
                fields.append(.init(key: "Open item", value: "acknowledged — no evidence linked yet"))
            }
            sections.append(.init(name: fact.statement, fields: fields))
        }
        if !model.notes.trimmingCharacters(in: .whitespaces).isEmpty {
            sections.append(.init(name: "Notes", fields: [.init(key: "Author notes", value: model.notes)]))
        }

        let refs = model.evidence.compactMap(\.messageID).joined(separator: " ")
        let contested = model.facts.filter { model.status(for: $0) == .contested }.count
        let number = await DocumentRegistry.captureStructured(
            .report,
            summary: "Fact–evidence: \(model.title) — \(model.facts.count) facts, \(contested) contested",
            document: CapturedDocument(title: "Fact–Evidence — \(model.title)", sections: sections),
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
