import SwiftUI
import os.log

// MARK: - Action Register (CAPA) — V3 Phase 3
//
// One shared register serving the kalsmritikosh CAPA chain across personas:
// INV-16/17 (CAPA + effectiveness), LAW-20/21 (remediation), JRN-21/22
// (corrections), IND-20/21 (fix-it list + did-the-fix-work).
//
// Evidence-gating rules honored:
// - Each action links a cause/finding (free text) and optionally cites emails
//   (ACHEvidence locators).
// - PROHIBITED OUTCOME: the app never closes an action by itself. Closing
//   requires a human effectiveness decision, and "effective" requires an
//   evidence note — declaring effectiveness without evidence is blocked.
// - The register posts as a numbered document with per-action status,
//   verification decisions, and locators.

enum CAPAStatus: String, Codable, CaseIterable, Identifiable {
    case open = "Open"
    case inProgress = "In Progress"
    case awaitingVerification = "Awaiting Verification"
    case closedEffective = "Closed — Effective"
    case closedIneffective = "Closed — Ineffective (reopened follow-up advised)"

    var id: String { rawValue }

    var isClosed: Bool { self == .closedEffective || self == .closedIneffective }

    var color: Color {
        switch self {
        case .open: return .gray
        case .inProgress: return .blue
        case .awaitingVerification: return .orange
        case .closedEffective: return .green
        case .closedIneffective: return .red
        }
    }
}

struct CAPAAction: Identifiable, Codable, Equatable {
    var id = UUID()
    /// What will be done.
    var action: String
    /// The cause/finding this action addresses — every action links a cause.
    var cause: String = ""
    var owner: String = ""
    var dueNote: String = ""
    var status: CAPAStatus = .open
    /// Evidence locators supporting the cause or the verification.
    var evidence: [ACHEvidence] = []
    /// Human effectiveness decision (required to close).
    var effectivenessNote: String = ""
    var verifiedBy: String = ""
    var verifiedAt: Date?
}

struct ActionRegisterModel: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String = "Action register"
    var actions: [CAPAAction] = []
    var createdAt: Date = Date()
    var postedDocumentNumber: String?

    var openCount: Int { actions.filter { !$0.status.isClosed }.count }

    var postBlockers: [String] {
        var blockers: [String] = []
        if actions.isEmpty { blockers.append("Add at least one action.") }
        let uncaused = actions.filter { $0.cause.trimmingCharacters(in: .whitespaces).isEmpty }
        if !uncaused.isEmpty { blockers.append("\(uncaused.count) action(s) have no linked cause — every action must state what it addresses.") }
        return blockers
    }

    /// Gate for closing one action as effective (kalsmritikosh: effectiveness
    /// must cite evidence; the app never declares it).
    static func closeBlockers(for action: CAPAAction, asEffective: Bool) -> [String] {
        var blockers: [String] = []
        if asEffective && action.effectivenessNote.trimmingCharacters(in: .whitespaces).isEmpty {
            blockers.append("An effectiveness note describing the verification evidence is required.")
        }
        if action.verifiedBy.trimmingCharacters(in: .whitespaces).isEmpty {
            blockers.append("The verifier's name is required — closing is a human decision.")
        }
        return blockers
    }
}

// MARK: - Persistence

@MainActor
final class ActionRegisterStore: ObservableObject {
    static let shared = ActionRegisterStore()

    @Published var registers: [ActionRegisterModel] = [] {
        didSet { if initialized { save() } }
    }

    private var initialized = false
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "mailin", category: "ActionRegister")

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mailin", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("action_registers.json")
    }

    private init() {
        if let data = try? Data(contentsOf: fileURL) {
            registers = (try? JSONDecoder().decode([ActionRegisterModel].self, from: data)) ?? []
        }
        initialized = true
    }

    private func save() {
        do {
            try JSONEncoder().encode(registers).write(to: fileURL, options: .atomic)
        } catch {
            log.error("Action register save failed: \(error.localizedDescription)")
        }
    }

    func update(_ model: ActionRegisterModel) {
        if let idx = registers.firstIndex(where: { $0.id == model.id }) {
            registers[idx] = model
        } else {
            registers.insert(model, at: 0)
        }
    }

    func delete(_ model: ActionRegisterModel) {
        registers.removeAll { $0.id == model.id }
    }
}

// MARK: - Studio root

struct ActionRegisterStudioView: View {
    @StateObject private var store = ActionRegisterStore.shared
    @State private var open: ActionRegisterModel?

    var body: some View {
        Group {
            if let current = open {
                ActionRegisterEditorView(model: current) { updated in
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
                    Text("Action Register (CAPA)")
                        .font(Typography.headline)
                    Text("Corrective actions, remediations, corrections, fix-it items — each linked to its cause. Closing requires a human effectiveness decision with evidence.")
                        .font(Typography.caption1)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    var fresh = ActionRegisterModel()
                    fresh.title = "Register \(store.registers.count + 1)"
                    store.update(fresh)
                    open = fresh
                } label: { Label("New Register", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
            }
            .padding([.horizontal, .top])

            if store.registers.isEmpty {
                ContentUnavailableView(
                    "No registers yet",
                    systemImage: "checkmark.rectangle.stack",
                    description: Text("Create a register and record actions with their causes, owners, and verification.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(store.registers) { r in
                        Button { open = r } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(r.title).fontWeight(.semibold)
                                    if let doc = r.postedDocumentNumber {
                                        Text(doc)
                                            .font(.caption2.monospaced())
                                            .padding(.horizontal, 6).padding(.vertical, 1)
                                            .background(Color.green.opacity(0.15))
                                            .clipShape(Capsule())
                                    }
                                }
                                Text("\(r.actions.count) actions · \(r.openCount) open")
                                    .font(Typography.caption1).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { idx in for i in idx { store.delete(store.registers[i]) } }
                }
                .listStyle(.plain)
            }
        }
    }
}

// MARK: - Editor

struct ActionRegisterEditorView: View {
    @State var model: ActionRegisterModel
    var onSave: (ActionRegisterModel) -> Void
    var onClose: () -> Void

    @State private var newActionText = ""
    @State private var verifyTarget: CAPAAction?
    @State private var showPostConfirm = false
    @State private var postResult: String?
    @State private var isPosting = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.medium) {
                    actionList
                    postPanel
                }
                .padding()
            }
        }
        .sheet(item: $verifyTarget) { action in
            EffectivenessReviewSheet(action: action) { updated in
                if let idx = model.actions.firstIndex(where: { $0.id == updated.id }) {
                    model.actions[idx] = updated
                    onSave(model)
                }
                verifyTarget = nil
            } onCancel: { verifyTarget = nil }
        }
        .confirmationDialog("Post action register document?", isPresented: $showPostConfirm, titleVisibility: .visible) {
            Button("Confirm — register reviewed") { Task { await postDocument() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The numbered document records each action, its cause, owner, status, and any human verification decisions. Open items remain open — the app closes nothing.")
        }
    }

    private var header: some View {
        HStack {
            Button { onSave(model); onClose() } label: { Label("Registers", systemImage: "chevron.left") }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            TextField("Register title", text: $model.title)
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

    private var actionList: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text("ACTIONS")
                .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)

            ForEach($model.actions) { $action in
                actionCard($action)
            }

            HStack {
                TextField("Describe a corrective action…", text: $newActionText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addAction() }
                Button { addAction() } label: { Image(systemName: "plus.circle.fill") }
                    .buttonStyle(.plain)
                    .disabled(newActionText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func addAction() {
        let t = newActionText.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        model.actions.append(CAPAAction(action: t))
        newActionText = ""
        onSave(model)
    }

    private func actionCard(_ action: Binding<CAPAAction>) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            HStack(alignment: .top) {
                Text(action.wrappedValue.action)
                    .font(Typography.caption1.weight(.semibold))
                Spacer()
                Text(action.wrappedValue.status.rawValue)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(action.wrappedValue.status.color.opacity(0.15))
                    .foregroundStyle(action.wrappedValue.status.color)
                    .clipShape(Capsule())
            }

            TextField("Cause / finding this addresses (required)", text: action.cause)
                .textFieldStyle(.roundedBorder)
                .font(Typography.caption1)
                .onSubmit { onSave(model) }

            HStack {
                TextField("Owner", text: action.owner)
                    .textFieldStyle(.roundedBorder)
                    .font(Typography.caption1)
                    .frame(maxWidth: 160)
                    .onSubmit { onSave(model) }
                TextField("Due / timeframe", text: action.dueNote)
                    .textFieldStyle(.roundedBorder)
                    .font(Typography.caption1)
                    .frame(maxWidth: 160)
                    .onSubmit { onSave(model) }
                Spacer()

                if !action.wrappedValue.status.isClosed {
                    Menu {
                        Button("Open") { action.wrappedValue.status = .open; onSave(model) }
                        Button("In Progress") { action.wrappedValue.status = .inProgress; onSave(model) }
                        Button("Awaiting Verification") { action.wrappedValue.status = .awaitingVerification; onSave(model) }
                        Divider()
                        Button("Verify & close…") { verifyTarget = action.wrappedValue }
                    } label: {
                        Label("Status", systemImage: "arrow.triangle.branch")
                            .font(.caption)
                    }
                } else if let at = action.wrappedValue.verifiedAt {
                    Text("verified by \(action.wrappedValue.verifiedBy) · \(at.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(Spacing.xSmall)
        .background(AppColors.backgroundSecondary.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.medium))
        .contextMenu {
            Button(role: .destructive) {
                model.actions.removeAll { $0.id == action.wrappedValue.id }
                onSave(model)
            } label: { Label("Delete action", systemImage: "trash") }
        }
    }

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
                        Label(model.postedDocumentNumber == nil ? "Post numbered register document" : "Post revision", systemImage: "number.square")
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
            .init(key: "Technique", value: "CAPA register — every action links a cause; closure requires a named human verifier; 'effective' requires an evidence note."),
        ]))
        for a in model.actions {
            var fields: [CapturedDocument.Field] = [
                .init(key: "Cause", value: a.cause),
                .init(key: "Owner", value: a.owner.isEmpty ? "—" : a.owner),
                .init(key: "Due", value: a.dueNote.isEmpty ? "—" : a.dueNote),
                .init(key: "Status", value: a.status.rawValue),
            ]
            if a.status.isClosed {
                fields.append(.init(key: "Verified by", value: a.verifiedBy))
                fields.append(.init(key: "Effectiveness evidence", value: a.effectivenessNote.isEmpty ? "—" : a.effectivenessNote))
            }
            sections.append(.init(name: a.action, fields: fields))
        }

        let number = await DocumentRegistry.captureStructured(
            .report,
            summary: "Action register: \(model.title) — \(model.actions.count) actions, \(model.openCount) open",
            document: CapturedDocument(title: "Action Register — \(model.title)", sections: sections)
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

// MARK: - Effectiveness review (human-gated close)

private struct EffectivenessReviewSheet: View {
    @State var action: CAPAAction
    var onDone: (CAPAAction) -> Void
    var onCancel: () -> Void

    @State private var effective = true

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text("Effectiveness Review")
                .font(Typography.headline)
            Text(action.action)
                .font(Typography.caption1)
                .foregroundStyle(.secondary)

            Picker("Outcome", selection: $effective) {
                Text("Effective — evidence supports it").tag(true)
                Text("Ineffective — did not resolve the cause").tag(false)
            }
            .pickerStyle(.inline)
            .labelsHidden()

            TextField("Verification evidence (what shows the action worked / failed)…", text: $action.effectivenessNote, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)

            TextField("Verified by (your name — required)", text: $action.verifiedBy)
                .textFieldStyle(.roundedBorder)

            let blockers = ActionRegisterModel.closeBlockers(for: action, asEffective: effective)
            ForEach(blockers, id: \.self) { b in
                Label(b, systemImage: "lock").font(Typography.caption1).foregroundStyle(.orange)
            }

            HStack {
                Button("Cancel", role: .cancel) { onCancel() }
                Spacer()
                Button("Record decision & close") {
                    action.status = effective ? .closedEffective : .closedIneffective
                    action.verifiedAt = Date()
                    onDone(action)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!blockers.isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 420)
    }
}
