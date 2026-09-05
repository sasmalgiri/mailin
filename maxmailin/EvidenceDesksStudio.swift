import SwiftUI
import os.log

// MARK: - Evidence Desks — V3 Phase 3b
//
// Two shared desks from the kalsmritikosh spec:
//
// 1. SOURCE RELIABILITY GRID (INV-08 / LAW-18 / JRN-04) — Admiralty/NATO
//    two-axis rating: source reliability A–F × information credibility 1–6.
//    Seeded from the archive's own signals (SPF/DKIM/DMARC pass rates per
//    sender), but the RATING IS A HUMAN DECISION — the seed is only a hint.
//
// 2. CONTRADICTION & GAP DESK (INV-12 / IND-18 / JRN-10) — records
//    contradictions with BOTH sides cited (each side an email locator) and a
//    gap register where "no evidence found" is explicitly labelled:
//    absence of evidence is not evidence of absence.
//
// Both post numbered documents via DocumentRegistry.

// MARK: - Admiralty model

enum AdmiraltyReliability: String, Codable, CaseIterable, Identifiable {
    case a = "A", b = "B", c = "C", d = "D", e = "E", f = "F"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .a: return "A — Completely reliable"
        case .b: return "B — Usually reliable"
        case .c: return "C — Fairly reliable"
        case .d: return "D — Not usually reliable"
        case .e: return "E — Unreliable"
        case .f: return "F — Cannot be judged"
        }
    }
}

enum AdmiraltyCredibility: String, Codable, CaseIterable, Identifiable {
    case one = "1", two = "2", three = "3", four = "4", five = "5", six = "6"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .one: return "1 — Confirmed by other sources"
        case .two: return "2 — Probably true"
        case .three: return "3 — Possibly true"
        case .four: return "4 — Doubtful"
        case .five: return "5 — Improbable"
        case .six: return "6 — Cannot be judged"
        }
    }
}

struct SourceReliabilityEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    /// Sender address or domain being rated.
    var source: String
    var emailCount: Int = 0
    /// Archive-derived hint (auth pass rate) — advisory only.
    var authHint: String = ""
    var reliability: AdmiraltyReliability?
    var credibility: AdmiraltyCredibility?
    var note: String = ""

    var isRated: Bool { reliability != nil && credibility != nil }
    var ratingCode: String {
        guard let r = reliability, let c = credibility else { return "—" }
        return "\(r.rawValue)\(c.rawValue)"
    }
}

// MARK: - Contradiction & gap model

struct ContradictionEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    var topic: String
    /// Side A and side B — each cited to an email (or acknowledged assumption).
    var sideA: ACHEvidence
    var sideB: ACHEvidence
    var resolutionNote: String = ""
    /// Human decision: leave open (both sides stand) or record which reading
    /// the examiner prefers — the original contradiction is never deleted.
    var humanReading: String = ""
}

struct GapEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    /// What was looked for and not found (e.g., "No email from CFO approving the wire").
    var expected: String
    var searchedNote: String = ""
    var acknowledged: Bool = false
}

struct EvidenceDeskModel: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String = "Evidence desk"
    var sources: [SourceReliabilityEntry] = []
    var contradictions: [ContradictionEntry] = []
    var gaps: [GapEntry] = []
    var createdAt: Date = Date()
    var postedDocumentNumber: String?

    var postBlockers: [String] {
        var blockers: [String] = []
        if sources.isEmpty && contradictions.isEmpty && gaps.isEmpty {
            blockers.append("Record at least one source rating, contradiction, or gap.")
        }
        let unrated = sources.filter { !$0.isRated }
        if !unrated.isEmpty {
            blockers.append("\(unrated.count) source(s) listed but unrated — rate both axes or remove them (F6 = cannot judge).")
        }
        let unackedGaps = gaps.filter { !$0.acknowledged }
        if !unackedGaps.isEmpty {
            blockers.append("\(unackedGaps.count) gap(s) unacknowledged — confirm each records an ABSENCE, not a conclusion.")
        }
        return blockers
    }
}

// MARK: - Persistence

@MainActor
final class EvidenceDeskStore: ObservableObject {
    static let shared = EvidenceDeskStore()

    @Published var desks: [EvidenceDeskModel] = [] {
        didSet { if initialized { save() } }
    }

    private var initialized = false
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "mailin", category: "EvidenceDesk")

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mailin", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("evidence_desks.json")
    }

    private init() {
        if let data = try? Data(contentsOf: fileURL) {
            desks = (try? JSONDecoder().decode([EvidenceDeskModel].self, from: data)) ?? []
        }
        initialized = true
    }

    private func save() {
        do {
            try JSONEncoder().encode(desks).write(to: fileURL, options: .atomic)
        } catch {
            log.error("Evidence desk save failed: \(error.localizedDescription)")
        }
    }

    func update(_ model: EvidenceDeskModel) {
        if let idx = desks.firstIndex(where: { $0.id == model.id }) {
            desks[idx] = model
        } else {
            desks.insert(model, at: 0)
        }
    }

    func delete(_ model: EvidenceDeskModel) {
        desks.removeAll { $0.id == model.id }
    }
}

// MARK: - Seeding from the archive (advisory hints only)

enum SourceReliabilitySeeder {
    /// Aggregates the working set by sender and derives an auth-pass hint.
    /// The Admiralty rating itself stays empty — rating is a human decision.
    static func seed(from emails: [MBOXParser.RawEmail]) -> [SourceReliabilityEntry] {
        struct Tally { var count = 0; var pass = 0; var fail = 0 }
        var bySender: [String: Tally] = [:]
        for email in emails {
            let from = (email.headers["From"] ?? "?").lowercased()
            let addr: String
            if let s = from.firstIndex(of: "<"), let e = from.firstIndex(of: ">"), s < e {
                addr = String(from[from.index(after: s)..<e])
            } else {
                addr = from.trimmingCharacters(in: .whitespaces)
            }
            var tally = bySender[addr] ?? Tally()
            tally.count += 1
            let auth = EmailNLPEngine.parseAuthenticationResults(email.headers)
            if auth.spfResult == .pass || auth.dkimResult == .pass || auth.dmarcResult == .pass {
                tally.pass += 1
            }
            if auth.spfResult == .fail || auth.dkimResult == .fail || auth.dmarcResult == .fail {
                tally.fail += 1
            }
            bySender[addr] = tally
        }
        return bySender
            .sorted { $0.value.count > $1.value.count }
            .prefix(100)
            .map { addr, t in
                var hint = "\(t.count) emails"
                if t.pass > 0 || t.fail > 0 {
                    hint += " · auth pass \(t.pass), fail \(t.fail)"
                } else {
                    hint += " · no auth headers"
                }
                return SourceReliabilityEntry(source: addr, emailCount: t.count, authHint: hint)
            }
    }
}

// MARK: - Studio root

struct EvidenceDesksStudioView: View {
    let workingSet: [MBOXParser.RawEmail]

    @StateObject private var store = EvidenceDeskStore.shared
    @State private var open: EvidenceDeskModel?

    var body: some View {
        Group {
            if let current = open {
                EvidenceDeskEditorView(model: current, workingSet: workingSet) { updated in
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
                    Text("Evidence Desks")
                        .font(Typography.headline)
                    Text("Source reliability (Admiralty A–F × 1–6, seeded from SPF/DKIM signals) and the contradiction & gap register — both sides preserved; absence is never proof.")
                        .font(Typography.caption1)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    var fresh = EvidenceDeskModel()
                    fresh.title = "Desk \(store.desks.count + 1)"
                    store.update(fresh)
                    open = fresh
                } label: { Label("New Desk", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
            }
            .padding([.horizontal, .top])

            if store.desks.isEmpty {
                ContentUnavailableView(
                    "No desks yet",
                    systemImage: "scalemass",
                    description: Text("Create a desk to rate sources and record contradictions and gaps for the current working set.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(store.desks) { d in
                        Button { open = d } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(d.title).fontWeight(.semibold)
                                    if let doc = d.postedDocumentNumber {
                                        Text(doc)
                                            .font(.caption2.monospaced())
                                            .padding(.horizontal, 6).padding(.vertical, 1)
                                            .background(Color.green.opacity(0.15))
                                            .clipShape(Capsule())
                                    }
                                }
                                Text("\(d.sources.count) sources · \(d.contradictions.count) contradictions · \(d.gaps.count) gaps")
                                    .font(Typography.caption1).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { idx in for i in idx { store.delete(store.desks[i]) } }
                }
                .listStyle(.plain)
            }
        }
    }
}

// MARK: - Editor

struct EvidenceDeskEditorView: View {
    @State var model: EvidenceDeskModel
    let workingSet: [MBOXParser.RawEmail]
    var onSave: (EvidenceDeskModel) -> Void
    var onClose: () -> Void

    private enum Tab: String, CaseIterable { case sources = "Source Reliability", contradictions = "Contradictions", gaps = "Gaps" }
    @State private var tab: Tab = .sources
    @State private var newTopic = ""
    @State private var newGap = ""
    @State private var pickerFor: (topic: String, pickingSideA: Bool)?
    @State private var pendingSideA: ACHEvidence?
    @State private var showPostConfirm = false
    @State private var postResult: String?
    @State private var isPosting = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            Divider().padding(.top, Spacing.xSmall)

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.medium) {
                    switch tab {
                    case .sources: sourcesTab
                    case .contradictions: contradictionsTab
                    case .gaps: gapsTab
                    }
                    postPanel
                }
                .padding()
            }
        }
        .sheet(isPresented: Binding(
            get: { pickerFor != nil },
            set: { if !$0 { pickerFor = nil; pendingSideA = nil } }
        )) {
            ArchiveEmailPickerView { picked in
                guard let target = pickerFor, let first = picked.first else { pickerFor = nil; return }
                let fmt = DateFormatter(); fmt.dateStyle = .medium; fmt.timeStyle = .short
                let row = ACHEvidence(
                    summary: first.subject.isEmpty ? first.bodyPreview : first.subject,
                    emailID: first.id, messageID: first.messageID,
                    fromLine: first.from, dateLine: fmt.string(from: first.date)
                )
                if target.pickingSideA {
                    pendingSideA = row
                    pickerFor = (target.topic, false)   // now pick side B
                } else if let a = pendingSideA {
                    model.contradictions.append(ContradictionEntry(topic: target.topic, sideA: a, sideB: row))
                    pendingSideA = nil
                    pickerFor = nil
                    onSave(model)
                }
            } onCancel: { pickerFor = nil; pendingSideA = nil }
        }
        .confirmationDialog("Post evidence desk document?", isPresented: $showPostConfirm, titleVisibility: .visible) {
            Button("Confirm — ratings and registers reviewed") { Task { await postDocument() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The document records Admiralty ratings (human decisions; archive signals are hints only), contradictions with both sides cited, and gaps labelled as absences — not conclusions.")
        }
    }

    private var header: some View {
        HStack {
            Button { onSave(model); onClose() } label: { Label("Desks", systemImage: "chevron.left") }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            TextField("Desk title", text: $model.title)
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

    // MARK: Sources tab

    private var sourcesTab: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack {
                Text("ADMIRALTY RATINGS — HUMAN DECISIONS; SIGNALS ARE HINTS")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                Spacer()
                Button {
                    let seeded = SourceReliabilitySeeder.seed(from: workingSet)
                    let known = Set(model.sources.map(\.source))
                    model.sources.append(contentsOf: seeded.filter { !known.contains($0.source) })
                    onSave(model)
                } label: {
                    Label("Seed from working set (\(workingSet.count) emails)", systemImage: "wand.and.stars")
                }
                .disabled(workingSet.isEmpty)
            }

            if model.sources.isEmpty {
                Text("Seed senders from the working set, then rate each source on both Admiralty axes.")
                    .font(Typography.caption1).foregroundStyle(.secondary)
            }

            ForEach($model.sources) { $entry in
                HStack(alignment: .top, spacing: Spacing.small) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.source).font(Typography.caption1.weight(.semibold)).lineLimit(1)
                        Text(entry.authHint).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("", selection: $entry.reliability) {
                        Text("Reliability…").tag(AdmiraltyReliability?.none)
                        ForEach(AdmiraltyReliability.allCases) { r in Text(r.label).tag(AdmiraltyReliability?.some(r)) }
                    }
                    .frame(maxWidth: 210)
                    .onChange(of: entry.reliability) { _, _ in onSave(model) }
                    Picker("", selection: $entry.credibility) {
                        Text("Credibility…").tag(AdmiraltyCredibility?.none)
                        ForEach(AdmiraltyCredibility.allCases) { c in Text(c.label).tag(AdmiraltyCredibility?.some(c)) }
                    }
                    .frame(maxWidth: 230)
                    .onChange(of: entry.credibility) { _, _ in onSave(model) }
                    Text(entry.ratingCode)
                        .font(.caption.monospaced().weight(.bold))
                        .frame(width: 34)
                        .foregroundStyle(entry.isRated ? Color.green : Color.orange)
                }
                .padding(Spacing.xxSmall)
                .background(AppColors.backgroundSecondary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contextMenu {
                    Button(role: .destructive) {
                        model.sources.removeAll { $0.id == entry.id }
                        onSave(model)
                    } label: { Label("Remove source", systemImage: "trash") }
                }
            }
        }
    }

    // MARK: Contradictions tab

    private var contradictionsTab: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text("CONTRADICTIONS — BOTH SIDES PRESERVED, NEVER AVERAGED")
                .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)

            ForEach($model.contradictions) { $c in
                VStack(alignment: .leading, spacing: Spacing.xSmall) {
                    Text(c.topic).font(Typography.caption1.weight(.semibold))
                    HStack(alignment: .top, spacing: Spacing.small) {
                        sideView("A", c.sideA)
                        sideView("B", c.sideB)
                    }
                    TextField("Examiner reading (optional — the contradiction itself stays on record)", text: $c.humanReading)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption2)
                        .onSubmit { onSave(model) }
                }
                .padding(Spacing.xSmall)
                .background(AppColors.backgroundSecondary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.medium))
                .contextMenu {
                    Button(role: .destructive) {
                        model.contradictions.removeAll { $0.id == c.id }
                        onSave(model)
                    } label: { Label("Remove", systemImage: "trash") }
                }
            }

            HStack {
                TextField("Contradiction topic (e.g. 'When was the contract signed?')", text: $newTopic)
                    .textFieldStyle(.roundedBorder)
                Button {
                    let t = newTopic.trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty else { return }
                    pickerFor = (t, true)
                    newTopic = ""
                } label: { Label("Cite both sides…", systemImage: "envelope.badge.plus") }
                .disabled(newTopic.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if pendingSideA != nil {
                Label("Side A chosen — now pick the email for side B.", systemImage: "info.circle")
                    .font(Typography.caption1).foregroundStyle(.blue)
            }
        }
    }

    private func sideView(_ label: String, _ e: ACHEvidence) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Side \(label)").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            Text(e.summary).font(.caption2).lineLimit(2)
            Text(e.locatorLine).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.xxSmall)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: Gaps tab

    private var gapsTab: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text("GAP REGISTER — ABSENCE OF EVIDENCE IS NOT EVIDENCE OF ABSENCE")
                .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)

            ForEach($model.gaps) { $g in
                VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                    Text(g.expected).font(Typography.caption1.weight(.semibold))
                    TextField("What was searched (scopes, terms, dates)…", text: $g.searchedNote)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption2)
                        .onSubmit { onSave(model) }
                    Toggle(isOn: $g.acknowledged) {
                        Text("Acknowledged: this records an ABSENCE within the searched scope, not a conclusion")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .onChange(of: g.acknowledged) { _, _ in onSave(model) }
                }
                .padding(Spacing.xSmall)
                .background(AppColors.backgroundSecondary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.medium))
                .contextMenu {
                    Button(role: .destructive) {
                        model.gaps.removeAll { $0.id == g.id }
                        onSave(model)
                    } label: { Label("Remove", systemImage: "trash") }
                }
            }

            HStack {
                TextField("Expected but not found (e.g. 'No approval email from CFO')…", text: $newGap)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addGap() }
                Button { addGap() } label: { Image(systemName: "plus.circle.fill") }
                    .buttonStyle(.plain)
                    .disabled(newGap.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func addGap() {
        let t = newGap.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        model.gaps.append(GapEntry(expected: t))
        newGap = ""
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
                        Label(model.postedDocumentNumber == nil ? "Post numbered desk document" : "Post revision", systemImage: "number.square")
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
            .init(key: "Source ratings", value: "Admiralty/NATO scale (reliability A–F × credibility 1–6); archive auth signals are advisory hints, ratings are human decisions."),
            .init(key: "Contradictions", value: "Both sides preserved with locators; never averaged or auto-resolved."),
            .init(key: "Gaps", value: "Each gap records an absence within a searched scope — not a conclusion."),
        ]))
        if !model.sources.isEmpty {
            sections.append(.init(name: "Source reliability", fields:
                model.sources.map { .init(key: $0.source, value: "\($0.ratingCode) · \($0.authHint)\($0.note.isEmpty ? "" : " · \($0.note)")") }
            ))
        }
        for c in model.contradictions {
            sections.append(.init(name: "Contradiction: \(c.topic)", fields: [
                .init(key: "Side A: \(c.sideA.summary)", value: c.sideA.locatorLine),
                .init(key: "Side B: \(c.sideB.summary)", value: c.sideB.locatorLine),
                .init(key: "Examiner reading", value: c.humanReading.isEmpty ? "left open — both sides stand" : c.humanReading),
            ]))
        }
        if !model.gaps.isEmpty {
            sections.append(.init(name: "Gap register", fields:
                model.gaps.map { .init(key: $0.expected, value: "searched: \($0.searchedNote.isEmpty ? "—" : $0.searchedNote) · absence within scope, not proof") }
            ))
        }

        let refs = (model.contradictions.flatMap { [$0.sideA.messageID, $0.sideB.messageID] }).compactMap { $0 }.joined(separator: " ")
        let number = await DocumentRegistry.captureStructured(
            .report,
            summary: "Evidence desk: \(model.title) — \(model.sources.count) sources, \(model.contradictions.count) contradictions, \(model.gaps.count) gaps",
            document: CapturedDocument(title: "Evidence Desk — \(model.title)", sections: sections),
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
