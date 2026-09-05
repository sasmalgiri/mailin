import SwiftUI
import os.log

// MARK: - ACH (Analysis of Competing Hypotheses) — V3 Phase 1
//
// The tier-2 analytic studio kalsmritikosh specifies as INV-07 / LAW-19 /
// JRN-19 / RES-17: hypotheses as columns, evidence rows cited to archive
// emails, per-cell consistency ratings, and a fewest-inconsistencies ranking.
//
// Evidence-gating rules honored here (kalsmritikosh):
// - Every evidence row is either CITED (carries an email locator: archive id
//   + Message-ID + date) or explicitly marked as an uncited assumption.
// - PROHIBITED OUTCOME: the app never "picks the winner". The ranking is
//   presented as "least refuted", and posting the numbered document requires
//   an explicit human confirmation.
// - The posted document records the method note, every locator, and the
//   assumptions, so the work product reopens to its evidence.

// MARK: - Model

enum ACHRating: String, Codable, CaseIterable, Identifiable {
    case cc = "CC"   // strongly consistent
    case c  = "C"    // consistent
    case n  = "N"    // neutral / not applicable
    case i  = "I"    // inconsistent
    case ii = "II"   // strongly inconsistent

    var id: String { rawValue }

    /// ACH ranks by refutation: only inconsistencies score.
    var inconsistencyWeight: Int {
        switch self {
        case .ii: return 2
        case .i: return 1
        case .cc, .c, .n: return 0
        }
    }

    var color: Color {
        switch self {
        case .cc: return .green
        case .c: return .mint
        case .n: return .gray
        case .i: return .orange
        case .ii: return .red
        }
    }

    var help: String {
        switch self {
        case .cc: return "Strongly consistent with the hypothesis"
        case .c: return "Consistent"
        case .n: return "Neutral / not applicable"
        case .i: return "Inconsistent"
        case .ii: return "Strongly inconsistent"
        }
    }
}

struct ACHHypothesis: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
}

struct ACHEvidence: Identifiable, Codable, Equatable {
    var id = UUID()
    var summary: String
    /// Locator into the archive — nil for manual rows.
    var emailID: UUID?
    var messageID: String?
    var fromLine: String?
    var dateLine: String?
    /// Uncited rows must be explicitly acknowledged as assumptions.
    var isAssumption: Bool = false

    var isCited: Bool { emailID != nil }

    var locatorLine: String {
        guard isCited else { return "ASSUMPTION (uncited)" }
        var parts: [String] = []
        if let messageID, !messageID.isEmpty { parts.append("Message-ID: \(messageID)") }
        if let dateLine, !dateLine.isEmpty { parts.append(dateLine) }
        if let fromLine, !fromLine.isEmpty { parts.append(fromLine) }
        return parts.isEmpty ? "archive \(emailID?.uuidString.prefix(8) ?? "")" : parts.joined(separator: " · ")
    }
}

struct ACHMatrixModel: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String = "Untitled analysis"
    var hypotheses: [ACHHypothesis] = []
    var evidence: [ACHEvidence] = []
    /// evidenceID → hypothesisID → rating. Unrated cells are absent — the
    /// posting gate requires every cell to be explicitly rated.
    var cells: [UUID: [UUID: ACHRating]] = [:]
    var assumptionsNote: String = ""
    var createdAt: Date = Date()
    var postedDocumentNumber: String?

    func rating(evidence e: UUID, hypothesis h: UUID) -> ACHRating? {
        cells[e]?[h]
    }

    mutating func setRating(_ r: ACHRating, evidence e: UUID, hypothesis h: UUID) {
        cells[e, default: [:]][h] = r
    }

    /// Fewest-inconsistencies score (lower = least refuted).
    func inconsistencyScore(for h: ACHHypothesis) -> Int {
        evidence.reduce(0) { $0 + (rating(evidence: $1.id, hypothesis: h.id)?.inconsistencyWeight ?? 0) }
    }

    /// Hypotheses ranked by ascending inconsistency (least refuted first).
    var ranking: [(hypothesis: ACHHypothesis, score: Int)] {
        hypotheses
            .map { ($0, inconsistencyScore(for: $0)) }
            .sorted { $0.1 < $1.1 }
    }

    var unratedCellCount: Int {
        hypotheses.count * evidence.count
            - evidence.reduce(0) { count, e in
                count + hypotheses.filter { rating(evidence: e.id, hypothesis: $0.id) != nil }.count
            }
    }

    /// Gate for posting the numbered document (kalsmritikosh tier-4 rigor).
    var postBlockers: [String] {
        var blockers: [String] = []
        if hypotheses.count < 2 { blockers.append("At least 2 competing hypotheses are required.") }
        if evidence.count < 3 { blockers.append("At least 3 evidence rows are required.") }
        if unratedCellCount > 0 { blockers.append("\(unratedCellCount) cell(s) are unrated — rate every cell (N is a valid rating).") }
        let unackedAssumptions = evidence.filter { !$0.isCited && !$0.isAssumption }
        if !unackedAssumptions.isEmpty {
            blockers.append("\(unackedAssumptions.count) uncited row(s) must be marked as assumptions or linked to emails.")
        }
        return blockers
    }
}

// MARK: - Persistence (JSON in Application Support — bounded, local-first)

@MainActor
final class ACHMatrixStore: ObservableObject {
    static let shared = ACHMatrixStore()

    @Published var matrices: [ACHMatrixModel] = [] {
        didSet { if initialized { save() } }
    }

    private var initialized = false
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "mailin", category: "ACHMatrix")

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mailin", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ach_matrices.json")
    }

    private init() {
        load()
        initialized = true
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        matrices = (try? JSONDecoder().decode([ACHMatrixModel].self, from: data)) ?? []
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(matrices)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            log.error("ACH save failed: \(error.localizedDescription)")
        }
    }

    func update(_ model: ACHMatrixModel) {
        if let idx = matrices.firstIndex(where: { $0.id == model.id }) {
            matrices[idx] = model
        } else {
            matrices.insert(model, at: 0)
        }
    }

    func delete(_ model: ACHMatrixModel) {
        matrices.removeAll { $0.id == model.id }
    }
}

// MARK: - Studio root: list of analyses

struct ACHMatrixStudioView: View {
    @StateObject private var store = ACHMatrixStore.shared
    @State private var openMatrix: ACHMatrixModel?

    var body: some View {
        Group {
            if let current = openMatrix {
                ACHMatrixEditorView(model: current) { updated in
                    store.update(updated)
                    openMatrix = updated
                } onClose: {
                    openMatrix = nil
                }
            } else {
                listView
            }
        }
    }

    private var listView: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hypothesis Matrix (ACH)")
                        .font(Typography.headline)
                    Text("Score competing explanations against email evidence. The matrix ranks by fewest inconsistencies — it never declares a winner; you do.")
                        .font(Typography.caption1)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    var fresh = ACHMatrixModel()
                    fresh.title = "Analysis \(store.matrices.count + 1)"
                    store.update(fresh)
                    openMatrix = fresh
                } label: {
                    Label("New Analysis", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding([.horizontal, .top])

            if store.matrices.isEmpty {
                ContentUnavailableView(
                    "No analyses yet",
                    systemImage: "tablecells.badge.ellipsis",
                    description: Text("Create an analysis, add competing hypotheses, attach email evidence, and rate each cell.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(store.matrices) { m in
                        Button {
                            openMatrix = m
                        } label: {
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
                                Text("\(m.hypotheses.count) hypotheses · \(m.evidence.count) evidence rows · \(m.unratedCellCount) unrated")
                                    .font(Typography.caption1)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { idx in
                        for i in idx { store.delete(store.matrices[i]) }
                    }
                }
                .listStyle(.plain)
            }
        }
    }
}

// MARK: - Editor

struct ACHMatrixEditorView: View {
    @State var model: ACHMatrixModel
    var onSave: (ACHMatrixModel) -> Void
    var onClose: () -> Void

    @State private var showEmailPicker = false
    @State private var showManualEvidence = false
    @State private var manualEvidenceText = ""
    @State private var newHypothesisText = ""
    @State private var showPostConfirm = false
    @State private var postResult: String?
    @State private var isPosting = false

    private let hypColumnWidth: CGFloat = 110
    private let evidenceColumnWidth: CGFloat = 260

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView([.vertical]) {
                VStack(alignment: .leading, spacing: Spacing.medium) {
                    hypothesisEditor
                    matrixGrid
                    rankingPanel
                    assumptionsPanel
                    postPanel
                }
                .padding()
            }
        }
        .sheet(isPresented: $showEmailPicker) {
            ArchiveEmailPickerView { picked in
                for s in picked {
                    let fmt = DateFormatter()
                    fmt.dateStyle = .medium; fmt.timeStyle = .short
                    model.evidence.append(ACHEvidence(
                        summary: s.subject.isEmpty ? s.bodyPreview : s.subject,
                        emailID: s.id,
                        messageID: s.messageID,
                        fromLine: s.from,
                        dateLine: fmt.string(from: s.date)
                    ))
                }
                onSave(model)
                showEmailPicker = false
            } onCancel: { showEmailPicker = false }
        }
        .alert("Add manual evidence", isPresented: $showManualEvidence) {
            TextField("Evidence statement", text: $manualEvidenceText)
            Button("Cancel", role: .cancel) { manualEvidenceText = "" }
            Button("Add as assumption") {
                guard !manualEvidenceText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                model.evidence.append(ACHEvidence(summary: manualEvidenceText, isAssumption: true))
                manualEvidenceText = ""
                onSave(model)
            }
        } message: {
            Text("Manual rows carry no email locator, so they are recorded as assumptions in the posted document.")
        }
        .confirmationDialog(
            "Post ACH document?",
            isPresented: $showPostConfirm,
            titleVisibility: .visible
        ) {
            Button("Confirm — I reviewed the ranking") { Task { await postDocument() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("ACH identifies the LEAST-REFUTED hypothesis; it does not prove any hypothesis. Posting records your confirmation, every evidence locator, and all assumptions in a numbered document.")
        }
    }

    private var header: some View {
        HStack {
            Button {
                onSave(model)
                onClose()
            } label: {
                Label("Analyses", systemImage: "chevron.left")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)

            TextField("Analysis title", text: $model.title)
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

    // MARK: Hypotheses

    private var hypothesisEditor: some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            Text("COMPETING HYPOTHESES")
                .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            HStack(spacing: Spacing.xSmall) {
                ForEach(model.hypotheses) { h in
                    HStack(spacing: 4) {
                        Text("H\((model.hypotheses.firstIndex(of: h) ?? 0) + 1)")
                            .font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                        Text(h.title).font(Typography.caption1)
                        Button {
                            model.hypotheses.removeAll { $0.id == h.id }
                            model.cells = model.cells.mapValues { row in row.filter { $0.key != h.id } }
                            onSave(model)
                        } label: {
                            Image(systemName: "xmark.circle.fill").font(.caption2).foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, Spacing.xSmall).padding(.vertical, 4)
                    .background(Color.blue.opacity(0.08))
                    .clipShape(Capsule())
                }
                TextField("Add hypothesis…", text: $newHypothesisText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .onSubmit {
                        let t = newHypothesisText.trimmingCharacters(in: .whitespaces)
                        guard !t.isEmpty else { return }
                        model.hypotheses.append(ACHHypothesis(title: t))
                        newHypothesisText = ""
                        onSave(model)
                    }
            }
        }
    }

    // MARK: Grid

    private var matrixGrid: some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            HStack {
                Text("EVIDENCE × HYPOTHESES")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                Spacer()
                Button { showEmailPicker = true } label: {
                    Label("Add emails", systemImage: "envelope.badge.plus")
                }
                Button { showManualEvidence = true } label: {
                    Label("Add assumption", systemImage: "text.badge.plus")
                }
            }

            if model.evidence.isEmpty {
                Text("Attach archive emails as evidence rows, then rate each against every hypothesis (CC · C · N · I · II).")
                    .font(Typography.caption1).foregroundStyle(.secondary)
                    .padding(.vertical, Spacing.small)
            } else {
                ScrollView(.horizontal) {
                    Grid(alignment: .leading, horizontalSpacing: Spacing.xxSmall, verticalSpacing: Spacing.xxSmall) {
                        GridRow {
                            Text("Evidence")
                                .font(.caption.weight(.semibold))
                                .frame(width: evidenceColumnWidth, alignment: .leading)
                            ForEach(Array(model.hypotheses.enumerated()), id: \.element.id) { idx, h in
                                Text("H\(idx + 1)")
                                    .font(.caption.weight(.semibold))
                                    .frame(width: hypColumnWidth)
                                    .help(h.title)
                            }
                        }
                        ForEach(model.evidence) { e in
                            GridRow {
                                evidenceCell(e)
                                ForEach(model.hypotheses) { h in
                                    ratingCell(evidence: e, hypothesis: h)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func evidenceCell(_ e: ACHEvidence) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(e.summary)
                .font(Typography.caption1)
                .lineLimit(2)
            Text(e.locatorLine)
                .font(.caption2)
                .foregroundStyle(e.isCited ? Color.secondary : Color.orange)
                .lineLimit(1)
        }
        .frame(width: evidenceColumnWidth, alignment: .leading)
        .padding(Spacing.xxSmall)
        .background(AppColors.backgroundSecondary.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contextMenu {
            Button(role: .destructive) {
                model.evidence.removeAll { $0.id == e.id }
                model.cells[e.id] = nil
                onSave(model)
            } label: { Label("Remove row", systemImage: "trash") }
        }
    }

    private func ratingCell(evidence e: ACHEvidence, hypothesis h: ACHHypothesis) -> some View {
        Menu {
            ForEach(ACHRating.allCases) { r in
                Button {
                    model.setRating(r, evidence: e.id, hypothesis: h.id)
                    onSave(model)
                } label: {
                    Label("\(r.rawValue) — \(r.help)", systemImage: model.rating(evidence: e.id, hypothesis: h.id) == r ? "checkmark" : "circle")
                }
            }
        } label: {
            let current = model.rating(evidence: e.id, hypothesis: h.id)
            Text(current?.rawValue ?? "—")
                .font(.caption.weight(.bold))
                .frame(width: hypColumnWidth, height: 34)
                .background((current?.color ?? Color.gray).opacity(current == nil ? 0.10 : 0.22))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    // MARK: Ranking

    private var rankingPanel: some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            Text("RANKING — LEAST REFUTED FIRST (advisory, not a verdict)")
                .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            ForEach(Array(model.ranking.enumerated()), id: \.element.hypothesis.id) { idx, entry in
                HStack {
                    Text("\(idx + 1).")
                        .font(Typography.caption1.weight(.bold))
                        .foregroundStyle(idx == 0 ? Color.green : Color.secondary)
                    Text(entry.hypothesis.title).font(Typography.caption1)
                    Spacer()
                    Text("inconsistency \(entry.score)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            if model.ranking.count >= 2,
               let first = model.ranking.first, let second = model.ranking.dropFirst().first,
               first.score == second.score {
                Label("Top hypotheses are tied — the evidence does not discriminate. Collect more before concluding.", systemImage: "exclamationmark.triangle")
                    .font(Typography.caption1)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var assumptionsPanel: some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            Text("ASSUMPTIONS & NOTES")
                .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            TextField("Key assumptions underlying the ratings…", text: $model.assumptionsNote, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
                .onSubmit { onSave(model) }
        }
    }

    // MARK: Posting gate

    private var postPanel: some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            let blockers = model.postBlockers
            if !blockers.isEmpty {
                ForEach(blockers, id: \.self) { b in
                    Label(b, systemImage: "lock").font(Typography.caption1).foregroundStyle(.orange)
                }
            }
            HStack {
                Button {
                    showPostConfirm = true
                } label: {
                    if isPosting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(model.postedDocumentNumber == nil ? "Post numbered ACH document" : "Post revision", systemImage: "number.square")
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
            .init(key: "Technique", value: "Analysis of Competing Hypotheses (fewest-inconsistencies ranking)"),
            .init(key: "Limitation", value: "The ranking identifies the least-refuted hypothesis; it does not prove any hypothesis. Human confirmation recorded."),
        ]))
        sections.append(.init(name: "Ranking", fields:
            model.ranking.enumerated().map { idx, entry in
                .init(key: "\(idx + 1). \(entry.hypothesis.title)", value: "inconsistency score \(entry.score)")
            }
        ))
        sections.append(.init(name: "Evidence", fields:
            model.evidence.map { e in
                .init(key: e.summary, value: e.locatorLine)
            }
        ))
        if !model.assumptionsNote.trimmingCharacters(in: .whitespaces).isEmpty {
            sections.append(.init(name: "Assumptions", fields: [
                .init(key: "Noted", value: model.assumptionsNote)
            ]))
        }
        let uncited = model.evidence.filter { !$0.isCited }
        if !uncited.isEmpty {
            sections.append(.init(name: "Uncited assumptions", fields:
                uncited.map { .init(key: $0.summary, value: "no email locator") }
            ))
        }

        let refs = model.evidence.compactMap(\.messageID).joined(separator: " ")
        let leastRefuted = model.ranking.first?.hypothesis.title ?? "—"
        let number = await DocumentRegistry.captureStructured(
            .report,
            summary: "ACH: \(model.title) — least refuted: \(leastRefuted)",
            document: CapturedDocument(title: "ACH — \(model.title)", sections: sections),
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
