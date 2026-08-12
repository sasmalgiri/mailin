//
//  WorkflowRunnerView.swift
//  maxmailin
//
//  Runs one workflow instance: a WF-#### whose steps expand INLINE. Each step
//  shows its guidance and its fields right in the checklist; entries auto-save
//  as you type and a step marks itself done automatically once its required
//  fields are filled (and, for a step that launches a tool, once you've opened
//  that tool). Confirm is demoted to an optional one-tap "Sign off" — surfaced
//  for Forensic/Legal, where a who/when attestation matters. Both behaviours
//  are user options (auto-save / auto-complete) that can be turned off, in
//  which case the user saves and marks each step done by hand. Heavy tools open
//  as sibling windows bound to the run; the run renders to a printable report.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

struct WorkflowRunnerView: View {
    let definition: WorkflowDefinition
    /// nil = start a fresh run; non-nil = resume an existing WF number.
    var resumeWF: String? = nil
    /// Optional saved variant to pre-fill a fresh run from (SAP variant).
    var startVariant: SQLiteEmailStore.StoredVariant? = nil
    /// Opens the tool a step performs its work in — this is what lets the
    /// user DO the job from the workflow, not just record it.
    var onOpenDestination: ((HubDestination) -> Void)? = nil
    var onClose: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var wfNumber: String = ""
    @State private var title: String = ""
    @State private var status: String = "open"
    @State private var confirmations: [Int: SQLiteEmailStore.StoredConfirmation] = [:]
    @State private var savedValues: [Int: [String: String]] = [:]
    @State private var notes: [Int: String] = [:]
    @State private var derivation = DerivationContext()
    @State private var derivedKeysBySeq: [Int: Set<String>] = [:]
    @State private var validationBySeq: [Int: String] = [:]
    @State private var showSaveVariant = false
    @State private var variantName = ""
    @State private var completedNumber: String? = nil
    @State private var clientName = ""
    @State private var showSummary = false
    @State private var isLoading = true
    // Inline-step interaction state.
    @State private var expanded: Set<Int> = []
    @State private var openedSteps: Set<Int> = []
    @State private var dirtySeqs: Set<Int> = []
    @State private var savedFlashSeq: Int? = nil
    @State private var saveTasks: [Int: Task<Void, Never>] = [:]
    @State private var scrollTarget: Int? = nil
    // First-run guidance — shown once per workflow, and once per step's Open.
    @AppStorage("wfIntroSeen") private var introSeenBlob = ""
    @AppStorage("wfStepOpenSeen") private var stepOpenSeenBlob = ""
    // User options — both default ON (see Settings ▸ Documents & History and
    // the automation menu in this window's header).
    @AppStorage("wfAutoSave") private var autoSave = true
    @AppStorage("wfAutoComplete") private var autoComplete = true
    @State private var showIntro = false
    @State private var openPromptOp: WorkflowOperation? = nil

    private var needsSignoff: Bool { definition.persona == "forensic" || definition.persona == "legal" }
    private var doneLabel: String { needsSignoff ? "Sign off" : "Mark done" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if isLoading {
                Spacer(); HStack { Spacer(); ProgressView(); Spacer() }; Spacer()
            } else {
                if showIntro { introCard }
                roadmap
                Divider()
                ScrollViewReader { proxy in
                    List {
                        Section {
                            ForEach(definition.operations) { op in
                                operationRow(op).id(op.seq)
                            }
                        } header: {
                            Text("\(confirmations.count) of \(definition.operations.count) steps done")
                        } footer: {
                            Text(footerText).font(Typography.caption2)
                        }
                    }
                    .onChange(of: scrollTarget) { _, t in
                        if let t { withAnimation { proxy.scrollTo(t, anchor: .top) } }
                    }
                }
            }
        }
        .toolWindowFrame()
        .task { await bootstrap() }
        .sheet(isPresented: $showSummary) { summarySheet }
        .alert("Save as Variant", isPresented: $showSaveVariant) {
            TextField("Variant name", text: $variantName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { Task { await saveVariant() } }
        } message: {
            Text("Reuse this run's field entries next time by starting from this variant.")
        }
        .alert("Opening a tool for this step",
               isPresented: Binding(get: { openPromptOp != nil },
                                    set: { if !$0 { openPromptOp = nil } }),
               presenting: openPromptOp) { op in
            Button("Open now") { performOpen(op) }
            Button("Cancel", role: .cancel) { openPromptOp = nil }
        } message: { op in
            Text("\(op.hint)\n\nA separate window opens for this. Do the work there, then come back and fill this step's fields — it saves automatically\(autoComplete ? " and marks itself done" : "; then press \(doneLabel)").")
        }
    }

    private var footerText: String {
        if autoSave && autoComplete {
            return "Your work saves as you go, and each step marks itself done once its required fields are filled.\(needsSignoff ? " Use \(doneLabel) to add your who/when attestation." : "")"
        } else if autoSave {
            return "Your work saves as you go. Press \(doneLabel) on each step when you're ready to finalize it."
        } else if autoComplete {
            return "Steps mark themselves done once filled. Auto-save is off — press Save to store your entries."
        } else {
            return "Auto-save and auto-complete are off — press Save to store entries, and \(doneLabel) to finalize each step."
        }
    }

    @MainActor
    private func saveVariant() async {
        let name = variantName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        try? await SQLiteEmailStore.shared.saveVariant(
            defID: definition.defID, name: name,
            values: VariantCodec.flatten(savedValues),
            createdBy: ForensicManager.shared.examinerName)
        ForensicManager.shared.logAction("Workflow variant saved", detail: "\(definition.name): \(name)")
    }

    private var header: some View {
      VStack(alignment: .leading, spacing: Spacing.xSmall) {
        HStack {
            VStack(alignment: .leading, spacing: Spacing.xxxSmall) {
                Label(definition.name, systemImage: "flowchart")
                    .font(Typography.title2)
                Text(WorkflowCatalog.purpose(for: definition.defID))
                    .font(Typography.caption1).foregroundColor(AppColors.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Spacing.xSmall) {
                    if !wfNumber.isEmpty {
                        Text(wfNumber)
                            .font(Typography.monoBody).fontWeight(.semibold)
                            .textSelection(.enabled)
                    }
                    Text(status.uppercased())
                        .font(Typography.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background((status == "confirmed" ? Color.green : status == "released" ? Color.blue : Color.gray).opacity(0.15))
                        .clipShape(Capsule())
                }
                HStack(spacing: Spacing.xxSmall) {
                    Text("Client / matter").font(Typography.caption2).foregroundColor(AppColors.secondary)
                    TextField("name this job so you can find it later", text: $clientName)
                        .textFieldStyle(.roundedBorder)
                        .font(Typography.caption1)
                        .frame(maxWidth: 320)
                        .onSubmit { Task { await persistTitle() } }
                }
            }
            Spacer()
            automationMenu
            Button { showIntro = true } label: {
                Image(systemName: "questionmark.circle").imageScale(.large)
            }
            .buttonStyle(.plain)
            .help("How this job works — show the step-by-step guide again")
            .accessibilityLabel("How this job works")
            Button {
                variantName = ""
                showSaveVariant = true
            } label: { Label("Save as Variant", systemImage: "square.and.arrow.down.on.square") }
            .disabled(wfNumber.isEmpty)
            .help("Save this run's entries as a reusable variant — next time, start a run pre-filled in one click")
            Button {
                showSummary = true
            } label: { Label("Summary", systemImage: "doc.richtext") }
            .disabled(wfNumber.isEmpty)
            .help("A clean, plain-language summary you can hand to a non-technical reader — counsel, a manager, a prosecutor. Copy or print it.")
            Button {
                PlatformClipboard.copyString(renderReport())
            } label: { Label("Copy Report", systemImage: "doc.on.doc") }
            .disabled(wfNumber.isEmpty)
            #if os(macOS)
            Button { printReport() } label: { Label("Print", systemImage: "printer") }
            .disabled(wfNumber.isEmpty)
            #endif
            Button { if let onClose { onClose() } else { dismiss() } } label: {
                Image(systemName: "xmark.circle.fill").foregroundColor(AppColors.secondary).imageScale(.large)
            }
            .buttonStyle(.plain).help("Close").accessibilityLabel("Close workflow")
        }
        if let done = completedNumber {
            HStack(spacing: Spacing.xSmall) {
                Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                Text("Executed — document ")
                    .font(Typography.callout) +
                Text(done).font(Typography.monoBody).fontWeight(.bold)
                Text("saved. Find it later in Work Center ▸ Documents by this number, the client/matter, the date, or any value you entered.")
                    .font(Typography.caption2).foregroundColor(AppColors.secondary)
                Spacer()
                Button { PlatformClipboard.copyString(done) } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain).help("Copy the document number")
            }
            .padding(Spacing.xSmall)
            .background(Color.green.opacity(0.1))
            .cornerRadius(CornerRadius.small)
        }
      }
      .padding(Spacing.medium)
    }

    /// Quick per-run automation switches (mirror the Settings toggles).
    private var automationMenu: some View {
        Menu {
            Toggle(isOn: $autoSave) { Label("Auto-save as I go", systemImage: "square.and.arrow.down") }
            Toggle(isOn: $autoComplete) { Label("Auto-complete steps when filled", systemImage: "checkmark.circle") }
            Divider()
            Text("Off = save and \(doneLabel.lowercased()) each step yourself.")
        } label: {
            Image(systemName: "slider.horizontal.3").imageScale(.large)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Automation — turn auto-save and auto-complete on or off (also in Settings)")
    }

    // MARK: - Where-am-I roadmap + first-run guidance

    private enum StepState { case done, current, upcoming, locked }

    private func stepState(_ op: WorkflowOperation) -> StepState {
        if confirmations[op.seq] != nil { return .done }
        if !lockedReasons(op).isEmpty { return .locked }
        if op.seq == currentOp?.seq { return .current }
        return .upcoming
    }

    /// The step the user should be on now: first not-done, unlocked step.
    private var currentOp: WorkflowOperation? {
        definition.operations.first { confirmations[$0.seq] == nil && lockedReasons($0).isEmpty }
    }

    private func nextUpcoming(after op: WorkflowOperation) -> WorkflowOperation? {
        guard let i = definition.operations.firstIndex(where: { $0.seq == op.seq }),
              i + 1 < definition.operations.count else { return nil }
        return definition.operations[i + 1]
    }
    private func prevStep(_ op: WorkflowOperation) -> WorkflowOperation? {
        guard let i = definition.operations.firstIndex(where: { $0.seq == op.seq }), i > 0 else { return nil }
        return definition.operations[i - 1]
    }
    private func nextStep(_ op: WorkflowOperation) -> WorkflowOperation? { nextUpcoming(after: op) }

    /// A short descriptive phrase (≈5 words) drawn from the step's hint, so the
    /// roadmap rail says "Draft Report — write the findings & opinion", not just
    /// the bare title.
    private func shortHint(_ op: WorkflowOperation) -> String {
        let words = op.hint.split(whereSeparator: { $0 == " " || $0 == "\n" })
        let clipped = words.prefix(6).joined(separator: " ")
        let trimmed = clipped.trimmingCharacters(in: CharacterSet(charactersIn: " .,;:"))
        return words.count > 6 ? trimmed + "…" : trimmed
    }

    /// Plain-language "what to do here" for a step.
    private func stepGuidance(_ op: WorkflowOperation) -> String {
        var s = op.hint
        if op.launches != nil {
            s += " Press “Open tool” to do this in the app, then come back and fill the fields below."
        } else {
            s += " Fill the fields below."
        }
        if autoSave { s += " Entries save as you type" } else { s += " Press Save to store entries" }
        if autoComplete { s += "; the step marks itself done once its required fields are filled." }
        else { s += "; press \(doneLabel) to finalize it." }
        if let doc = op.postsDocType {
            s += " Finalizing posts a \(doc.displayName) you can quote or export later."
        }
        return s
    }

    private func chipHelp(_ op: WorkflowOperation, state: StepState) -> String {
        switch state {
        case .done: return "Done — click to review or edit this step"
        case .current: return "You are here — \(op.hint)"
        case .locked: return "Locked — \(lockedReasons(op).first ?? "finish the earlier step first")"
        case .upcoming: return "Coming up — \(op.hint)"
        }
    }

    // First-run tracking (comma-separated keys in @AppStorage).
    private func introSeen() -> Bool {
        introSeenBlob.split(separator: ",").map(String.init).contains(definition.defID)
    }
    private func markIntroSeen() {
        if !introSeen() {
            introSeenBlob += (introSeenBlob.isEmpty ? "" : ",") + definition.defID
        }
        showIntro = false
    }
    private func stepOpenSeen(_ op: WorkflowOperation) -> Bool {
        stepOpenSeenBlob.split(separator: ",").map(String.init).contains("\(definition.defID)#\(op.seq)")
    }
    private func markStepOpenSeen(_ op: WorkflowOperation) {
        let key = "\(definition.defID)#\(op.seq)"
        if !stepOpenSeen(op) {
            stepOpenSeenBlob += (stepOpenSeenBlob.isEmpty ? "" : ",") + key
        }
    }

    /// Open the step's tool. First time for this step, explain what to do in the
    /// window that opens; after that, open straight away.
    private func requestOpen(_ op: WorkflowOperation) {
        if stepOpenSeen(op) { performOpen(op) } else { openPromptOp = op }
    }
    private func performOpen(_ op: WorkflowOperation) {
        markStepOpenSeen(op)
        openedSteps.insert(op.seq)
        openPromptOp = nil
        if let dest = op.launches { onOpenDestination?(dest) }
    }

    private var roadmap: some View {
        VStack(alignment: .leading, spacing: Spacing.xxSmall) {
            if status == "confirmed" {
                Label("All steps done — this run is complete.", systemImage: "checkmark.seal.fill")
                    .font(Typography.caption1).foregroundColor(.green)
            } else if let cur = currentOp {
                let idx = (definition.operations.firstIndex { $0.seq == cur.seq } ?? 0) + 1
                (Text("Step \(idx) of \(definition.operations.count)  ").fontWeight(.semibold)
                 + Text("Now: \(cur.title)")
                 + Text(nextUpcoming(after: cur).map { "  →  Next: \($0.title)" } ?? "  →  Finish")
                    .foregroundColor(AppColors.secondary))
                    .font(Typography.caption1)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.xSmall) {
                    ForEach(Array(definition.operations.enumerated()), id: \.element.id) { i, op in
                        roadmapChip(op)
                        if i < definition.operations.count - 1 {
                            Image(systemName: "chevron.right")
                                .font(.caption2).foregroundColor(AppColors.secondary.opacity(0.5))
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.xSmall)
    }

    private func roadmapChip(_ op: WorkflowOperation) -> some View {
        let st = stepState(op)
        let icon: String
        let color: Color
        switch st {
        case .done:     icon = "checkmark.circle.fill"; color = .green
        case .current:  icon = "arrow.right.circle.fill"; color = AppColors.primary
        case .locked:   icon = "lock.fill"; color = .orange
        case .upcoming: icon = "\(op.seq).circle"; color = AppColors.secondary
        }
        return Button {
            let locks = confirmations[op.seq] == nil ? lockedReasons(op) : []
            if locks.isEmpty { expandStep(op) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundColor(color)
                VStack(alignment: .leading, spacing: 1) {
                    Text(op.title)
                        .font(Typography.caption2)
                        .fontWeight(st == .current ? .bold : .semibold)
                        .lineLimit(1)
                    Text(shortHint(op))
                        .font(Typography.caption2)
                        .foregroundColor(AppColors.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(st == .current ? AppColors.primary.opacity(0.12) : AppColors.secondary.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.small)
                    .stroke(st == .current ? AppColors.primary.opacity(0.5) : Color.clear, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.small))
        }
        .buttonStyle(.plain)
        .help(chipHelp(op, state: st))
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            HStack {
                Label("How this job works", systemImage: "lightbulb.fill")
                    .font(Typography.callout).fontWeight(.semibold)
                Spacer()
                Button { markIntroSeen() } label: { Image(systemName: "xmark").imageScale(.small) }
                    .buttonStyle(.plain).help("Hide — reopen any time with the ? button")
            }
            Text(WorkflowCatalog.purpose(for: definition.defID))
                .font(Typography.caption1).foregroundColor(AppColors.secondary)
                .fixedSize(horizontal: false, vertical: true)
            guideLine("1", "Name the job in Client / matter so you can find it later.")
            guideLine("2", "Work top to bottom. Tap a step to open it; fill its fields right here. For a step that needs a tool, press Open first.")
            guideLine("3", autoComplete
                      ? "Each step marks itself done once its required fields are filled — no separate confirm."
                      : "Press \(doneLabel) on each step to finalize it (auto-complete is off).")
            guideLine("4", autoSave
                      ? "Everything auto-saves — close any time and reopen to resume exactly where you left off."
                      : "Auto-save is off — press Save on a step to store your entries.")
            Text("Tune this in the \(Image(systemName: "slider.horizontal.3")) menu (top-right) or Settings. The \(definition.operations.count) steps:  "
                 + definition.operations.map { "\($0.seq). \($0.title)" }.joined(separator: "  →  "))
                .font(Typography.caption2).foregroundColor(AppColors.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Got it") { markIntroSeen() }
                .buttonStyle(.borderedProminent).controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.small)
        .background(AppColors.primary.opacity(0.06))
        .cornerRadius(CornerRadius.small)
        .padding(.horizontal, Spacing.medium)
        .padding(.top, Spacing.xSmall)
    }

    private func guideLine(_ n: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(n)
                .font(Typography.caption2).fontWeight(.bold).foregroundColor(AppColors.primary)
                .frame(width: 14, height: 14)
                .background(AppColors.primary.opacity(0.15)).clipShape(Circle())
            Text(text).font(Typography.caption1).foregroundColor(AppColors.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func lockedReasons(_ op: WorkflowOperation) -> [String] {
        let state = GatePolicy.RunState(
            confirmed: Set(confirmations.keys),
            fieldValues: savedValues)
        return GatePolicy.lockedReasons(op, state: state)
    }

    // MARK: - Inline step row

    @ViewBuilder
    private func operationRow(_ op: WorkflowOperation) -> some View {
        let conf = confirmations[op.seq]
        let locks = conf == nil ? lockedReasons(op) : []
        let isOpen = expanded.contains(op.seq)
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            // Header line — tap to expand/collapse.
            Button {
                if isOpen { expanded.remove(op.seq) }
                else { prefillDerived(op); expanded.insert(op.seq) }
            } label: {
                HStack(alignment: .top, spacing: Spacing.small) {
                    Image(systemName: conf != nil ? "checkmark.circle.fill" : (locks.isEmpty ? "circle" : "lock.circle"))
                        .foregroundColor(conf != nil ? .green : (locks.isEmpty ? AppColors.secondary : .orange))
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(op.seq). \(op.title)")
                            .font(Typography.callout).fontWeight(.semibold)
                            .foregroundColor(.primary)
                        Text(op.hint)
                            .font(Typography.caption1).foregroundColor(AppColors.secondary)
                            .lineLimit(isOpen ? nil : 1)
                        if let conf {
                            HStack(spacing: Spacing.xxSmall) {
                                Text(conf.confirmedAt.formatted(date: .abbreviated, time: .shortened))
                                if !conf.confirmedBy.isEmpty { Text("· \(conf.confirmedBy)") }
                                if let doc = conf.docNumber {
                                    Text(doc).font(Typography.monoSmall).foregroundColor(AppColors.primary)
                                }
                            }
                            .font(Typography.caption2).foregroundColor(AppColors.secondary)
                        } else if let lock = locks.first {
                            Label(lock, systemImage: "lock.fill")
                                .font(Typography.caption2).foregroundColor(.orange)
                        }
                    }
                    Spacer()
                    if savedFlashSeq == op.seq {
                        Label("Saved", systemImage: "checkmark.circle")
                            .font(Typography.caption2).foregroundColor(.green).transition(.opacity)
                    }
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.caption).foregroundColor(AppColors.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen { stepDetail(op, conf: conf, locks: locks) }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func stepDetail(_ op: WorkflowOperation, conf: SQLiteEmailStore.StoredConfirmation?, locks: [String]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            // What to do here.
            VStack(alignment: .leading, spacing: 4) {
                Label("What to do here", systemImage: "info.circle.fill")
                    .font(Typography.caption1).fontWeight(.semibold).foregroundColor(AppColors.primary)
                Text(stepGuidance(op))
                    .font(Typography.caption1).foregroundColor(AppColors.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.small)
            .background(AppColors.primary.opacity(0.06))
            .cornerRadius(CornerRadius.small)

            if let lock = locks.first {
                Label("Locked — \(lock). You can read and fill this now; it finalizes once the earlier step is done.",
                      systemImage: "lock.fill")
                    .font(Typography.caption1).foregroundColor(.orange)
            }

            ForEach(op.fields) { field in
                fieldEditor(op.seq, field)
            }
            if let filled = derivedKeysBySeq[op.seq], !filled.isEmpty {
                Label("Some fields were filled in from your archive — check and adjust.", systemImage: "wand.and.stars")
                    .font(Typography.caption2).foregroundColor(AppColors.primary)
            }

            // Optional note.
            VStack(alignment: .leading, spacing: 2) {
                Text("Note (optional)").font(Typography.caption2).fontWeight(.semibold)
                TextField("Anything else worth recording", text: noteBinding(op.seq), axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...3)
            }

            if let err = validationBySeq[op.seq] {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(Typography.caption1).foregroundColor(.red)
            }

            // Action row.
            HStack(spacing: Spacing.xSmall) {
                Button { if let p = prevStep(op) { expandStep(p) } } label: {
                    Label("Previous", systemImage: "chevron.left")
                }
                .controlSize(.small).disabled(prevStep(op) == nil)
                .help("Go back a step — nothing is lost")
                Button { if let n = nextStep(op) { expandStep(n) } } label: {
                    Label("Next", systemImage: "chevron.right")
                }
                .controlSize(.small).disabled(nextStep(op) == nil)
                .help("Jump to the next step")

                if op.launches != nil {
                    Button { requestOpen(op) } label: { Label("Open tool", systemImage: "arrow.up.forward.app") }
                        .controlSize(.small)
                        .help("Open the tool to do this step now (opens beside this window)")
                }
                if !autoSave {
                    Button { Task { await saveNow(op) } } label: { Label("Save", systemImage: "square.and.arrow.down") }
                        .controlSize(.small)
                        .disabled(!dirtySeqs.contains(op.seq))
                        .help("Store your entries for this step")
                }
                Spacer()
                if conf == nil {
                    Button(doneLabel) { manualDone(op) }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(!locks.isEmpty || wfNumber.isEmpty)
                        .help(needsSignoff
                              ? "Finalize this step and record who did it and when — the forensic attestation"
                              : "Finalize this step now")
                } else {
                    Label("Done", systemImage: "checkmark.seal.fill")
                        .font(Typography.caption2).foregroundColor(.green)
                }
            }
        }
        .padding(.leading, 30)
        .padding(.trailing, 2)
    }

    @ViewBuilder
    private func fieldEditor(_ seq: Int, _ field: WorkflowField) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(field.label).font(Typography.caption1).fontWeight(.semibold)
                if field.required {
                    Text("required").font(Typography.caption2).foregroundColor(.orange)
                }
            }
            switch field.kind {
            case .text, .number, .date:
                TextField(field.placeholder, text: binding(seq, field.key))
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .keyboardType(field.kind == .number ? .numbersAndPunctuation : .default)
                    #endif
            case .longText:
                TextField(field.placeholder.isEmpty ? "…" : field.placeholder,
                          text: binding(seq, field.key), axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(2...5)
            case .bool:
                Toggle(isOn: boolBinding(seq, field.key)) { Text(field.help).font(Typography.caption2) }
            case .choice:
                Picker("", selection: binding(seq, field.key)) {
                    Text("—").tag("")
                    ForEach(field.options, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu).labelsHidden()
            }
            if field.kind != .bool {
                Text(field.help).font(Typography.caption2).foregroundColor(AppColors.secondary)
            }
        }
    }

    private func binding(_ seq: Int, _ key: String) -> Binding<String> {
        Binding(
            get: { savedValues[seq]?[key] ?? "" },
            set: { newVal in
                var d = savedValues[seq] ?? [:]
                d[key] = newVal
                savedValues[seq] = d
                onFieldEdited(seq)
            })
    }
    private func boolBinding(_ seq: Int, _ key: String) -> Binding<Bool> {
        Binding(
            get: { savedValues[seq]?[key] == "Yes" },
            set: { on in
                var d = savedValues[seq] ?? [:]
                d[key] = on ? "Yes" : ""
                savedValues[seq] = d
                onFieldEdited(seq)
            })
    }
    private func noteBinding(_ seq: Int) -> Binding<String> {
        Binding(get: { notes[seq] ?? "" }, set: { notes[seq] = $0; onFieldEdited(seq) })
    }

    private var summarySheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Stakeholder summary").font(Typography.title3)
                    Text("Plain-language, no jargon — for counsel, a manager, or a prosecutor.")
                        .font(Typography.caption1).foregroundColor(AppColors.secondary)
                }
                Spacer()
                if !wfNumber.isEmpty {
                    Text(wfNumber).font(Typography.monoSmall).foregroundColor(AppColors.secondary)
                }
            }
            .padding(Spacing.medium)
            Divider()
            ScrollView {
                Text(renderSummary())
                    .font(Typography.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.medium)
            }
            Divider()
            HStack {
                Spacer()
                Button("Copy") { PlatformClipboard.copyString(renderSummary()) }
                #if os(macOS)
                Button { printSummary() } label: { Label("Print", systemImage: "printer") }
                    .buttonStyle(.borderedProminent)
                #endif
                Button("Done") { showSummary = false }
            }
            .padding(Spacing.medium)
        }
        .frame(minWidth: 520, minHeight: 480)
    }

    // MARK: - Logic

    @MainActor
    private func bootstrap() async {
        await WorkflowService.seedBuiltins()
        if let resume = resumeWF, let inst = try? await SQLiteEmailStore.shared.instance(wf: resume) {
            wfNumber = inst.wfNumber; title = inst.title; status = inst.status
            if inst.title != definition.name { clientName = inst.title }
            if inst.status == "confirmed" { completedNumber = inst.wfNumber }
        } else {
            title = definition.name
            wfNumber = await WorkflowService.start(definition, title: title) ?? ""
            status = "open"
            if let v = startVariant {
                let expandedVals = VariantCodec.expand(v.values)
                for (seq, fields) in expandedVals {
                    try? await SQLiteEmailStore.shared.saveFieldValues(wf: wfNumber, seq: seq, values: fields)
                }
            }
        }
        await refreshConfirmations()
        showIntro = !introSeen()
        // Open the step the user should be on now.
        if let cur = currentOp {
            prefillDerived(cur)
            expanded = [cur.seq]
            scrollTarget = cur.seq
        }
        isLoading = false
    }

    @MainActor
    private func refreshConfirmations() async {
        guard !wfNumber.isEmpty else { return }
        let confs = (try? await SQLiteEmailStore.shared.confirmations(wf: wfNumber)) ?? []
        confirmations = Dictionary(uniqueKeysWithValues: confs.map { ($0.seq, $0) })
        for c in confs where !(c.note).isEmpty { notes[c.seq] = c.note }
        savedValues = (try? await SQLiteEmailStore.shared.fieldValues(wf: wfNumber)) ?? [:]
        if let inst = try? await SQLiteEmailStore.shared.instance(wf: wfNumber) { status = inst.status }
        await gatherDerivation()
    }

    /// A field/note changed — persist (if auto-save) or mark dirty, and, after a
    /// short dwell, auto-complete the step if it's eligible and the option is on.
    private func onFieldEdited(_ seq: Int) {
        validationBySeq[seq] = nil
        guard let op = definition.operations.first(where: { $0.seq == seq }) else { return }
        if autoSave {
            saveTasks[seq]?.cancel()
            saveTasks[seq] = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { return }
                await saveNow(op)
                guard autoComplete else { return }
                try? await Task.sleep(nanoseconds: 900_000_000)
                if Task.isCancelled { return }
                if canAutoComplete(op) { await complete(op, signedOff: false) }
            }
        } else {
            dirtySeqs.insert(seq)
        }
    }

    @MainActor
    private func saveNow(_ op: WorkflowOperation) async {
        guard !wfNumber.isEmpty else { return }
        try? await SQLiteEmailStore.shared.saveFieldValues(wf: wfNumber, seq: op.seq, values: savedValues[op.seq] ?? [:])
        dirtySeqs.remove(op.seq)
        await refreshSearchText()
        savedFlashSeq = op.seq
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if savedFlashSeq == op.seq { savedFlashSeq = nil }
        }
    }

    /// Eligible for hands-off completion: not done, unlocked, every required
    /// field filled, and — for a tool step — the tool has been opened.
    private func canAutoComplete(_ op: WorkflowOperation) -> Bool {
        guard confirmations[op.seq] == nil, lockedReasons(op).isEmpty else { return false }
        guard op.fields.contains(where: { $0.required }) else { return false }
        guard WorkflowFieldValidation.missingRequired(op.fields, values: savedValues[op.seq] ?? [:]).isEmpty else { return false }
        if op.launches != nil { return openedSteps.contains(op.seq) }
        return true
    }

    /// User pressed the explicit finalize button.
    private func manualDone(_ op: WorkflowOperation) {
        let missing = WorkflowFieldValidation.missingRequired(op.fields, values: savedValues[op.seq] ?? [:])
        if !missing.isEmpty {
            validationBySeq[op.seq] = "Please fill: \(missing.joined(separator: ", "))"
            expanded.insert(op.seq); scrollTarget = op.seq
            return
        }
        Task { await complete(op, signedOff: needsSignoff) }
    }

    /// Finalize a step: persist entries, post its document, record the
    /// confirmation (who/when), advance to the next step.
    @MainActor
    private func complete(_ op: WorkflowOperation, signedOff: Bool) async {
        guard !wfNumber.isEmpty, confirmations[op.seq] == nil, lockedReasons(op).isEmpty else { return }
        let vals = savedValues[op.seq] ?? [:]
        try? await SQLiteEmailStore.shared.saveFieldValues(wf: wfNumber, seq: op.seq, values: vals)
        let note = (notes[op.seq] ?? "").trimmingCharacters(in: .whitespaces)
        var docNumber: String? = nil
        if let docType = op.postsDocType {
            var fields: [CapturedDocument.Field] = [
                .init(key: "Workflow", value: definition.name),
                .init(key: "Step", value: op.title),
                .init(key: "Run", value: wfNumber),
            ]
            for f in op.fields where !(vals[f.key] ?? "").isEmpty {
                fields.append(.init(key: f.label, value: vals[f.key] ?? ""))
            }
            if !note.isEmpty { fields.append(.init(key: "Note", value: note)) }
            docNumber = await DocumentRegistry.captureStructured(
                docType, summary: "\(definition.name): \(op.title)",
                document: CapturedDocument(title: "\(definition.name) — \(op.title)",
                                           sections: [.init(name: op.title, fields: fields)]),
                refs: wfNumber)
        }
        let auto = op.fields.compactMap { vals[$0.key]?.isEmpty == false ? vals[$0.key] : nil }.first
        await WorkflowService.confirm(
            wf: wfNumber, seq: op.seq, totalOps: definition.operations.count,
            result: auto ?? (signedOff ? "signed off" : "done"), note: note, docNumber: docNumber)
        dirtySeqs.remove(op.seq)
        validationBySeq[op.seq] = nil
        await refreshConfirmations()
        await refreshSearchText()
        if status == "confirmed" { completedNumber = wfNumber }
        // Auto-advance to the next available step.
        if let next = definition.operations.first(where: {
            confirmations[$0.seq] == nil && lockedReasons($0).isEmpty
        }) {
            expandStep(next)
        } else {
            expanded.remove(op.seq)
        }
    }

    /// Expand exactly one step, prefill it, and scroll it into view.
    private func expandStep(_ op: WorkflowOperation) {
        prefillDerived(op)
        expanded = [op.seq]
        scrollTarget = op.seq
    }

    /// Fill any archive-derived fields that are still empty (one-time per step).
    private func prefillDerived(_ op: WorkflowOperation) {
        guard confirmations[op.seq] == nil else { return }
        let derived = FieldDerivation.derive(defID: definition.defID, opKey: op.key, ctx: derivation)
        guard !derived.isEmpty else { return }
        var d = savedValues[op.seq] ?? [:]
        var filled: Set<String> = []
        for (k, v) in derived where (d[k] ?? "").isEmpty { d[k] = v; filled.insert(k) }
        if !filled.isEmpty {
            savedValues[op.seq] = d
            derivedKeysBySeq[op.seq] = filled
            if autoSave { onFieldEdited(op.seq) } else { dirtySeqs.insert(op.seq) }
        }
    }

    @MainActor
    private func persistTitle() async {
        guard !wfNumber.isEmpty else { return }
        let t = clientName.trimmingCharacters(in: .whitespaces)
        title = t.isEmpty ? definition.name : t
        await refreshSearchText()
    }

    /// Build one searchable blob = client/matter + every entered value +
    /// confirmation notes, and write it into the WF document's summary/refs
    /// so Documents-tab lookup finds the run by any of them.
    @MainActor
    private func refreshSearchText() async {
        guard !wfNumber.isEmpty else { return }
        var parts: [String] = ["Workflow: \(definition.name)"]
        let client = clientName.trimmingCharacters(in: .whitespaces)
        if !client.isEmpty { parts.append("Client: \(client)") }
        for op in definition.operations {
            for f in op.fields {
                if let v = savedValues[op.seq]?[f.key], !v.isEmpty {
                    parts.append("\(f.label): \(v)")
                }
            }
            if let note = confirmations[op.seq]?.note, !note.isEmpty {
                parts.append("Note: \(note)")
            }
        }
        let summary = parts.joined(separator: " · ")
        try? await SQLiteEmailStore.shared.updateDocumentSearchText(
            wfNumber, summary: summary, refs: client.isEmpty ? definition.defID : client)
        try? await SQLiteEmailStore.shared.attachDocumentPayload(
            wfNumber, contentType: "application/json", body: buildCapturedDocument().jsonString())
    }

    /// The full run captured as structured sections/fields (maximum fidelity).
    private func buildCapturedDocument() -> CapturedDocument {
        var sections: [CapturedDocument.Section] = []
        var runFields: [CapturedDocument.Field] = [
            .init(key: "Document", value: wfNumber),
            .init(key: "Workflow", value: definition.name),
            .init(key: "Status", value: status.capitalized),
            .init(key: "By", value: ForensicManager.shared.examinerName),
        ]
        let client = clientName.trimmingCharacters(in: .whitespaces)
        if !client.isEmpty { runFields.append(.init(key: "Client / matter", value: client)) }
        sections.append(.init(name: "Run", fields: runFields))

        for op in definition.operations {
            var fields: [CapturedDocument.Field] = []
            for f in op.fields {
                if let v = savedValues[op.seq]?[f.key], !v.isEmpty {
                    fields.append(.init(key: f.label, value: v))
                }
            }
            if let c = confirmations[op.seq] {
                fields.append(.init(key: "Confirmed", value: c.confirmedAt.formatted(date: .abbreviated, time: .shortened)))
                if !c.confirmedBy.isEmpty { fields.append(.init(key: "Confirmed by", value: c.confirmedBy)) }
                if let doc = c.docNumber { fields.append(.init(key: "Document posted", value: doc)) }
                if !c.note.isEmpty { fields.append(.init(key: "Note", value: c.note)) }
            }
            if !fields.isEmpty {
                sections.append(.init(name: "\(op.seq). \(op.title)", fields: fields))
            }
        }
        return CapturedDocument(title: client.isEmpty ? definition.name : client, sections: sections)
    }

    @MainActor
    private func gatherDerivation() async {
        var ctx = DerivationContext()
        ctx.caseNumber = ForensicManager.shared.caseNumber
        ctx.examiner = ForensicManager.shared.examinerName
        let tags = ForensicManager.shared.evidenceTags
        ctx.relevantCount = tags.values.filter { $0 == .relevant }.count
        ctx.irrelevantCount = tags.values.filter { $0 == .irrelevant }.count
        let privileged = tags.filter { $0.value == .privileged }.map(\.key)
        ctx.privilegedCount = privileged.count
        let annotated = Set(ForensicManager.shared.annotations.keys)
        ctx.privilegedUnannotated = privileged.filter { !annotated.contains($0) }.count
        ctx.archiveTotal = (try? await ArchiveDataService.shared.count()) ?? 0
        ctx.archiveDuplicateCount = ((try? await SQLiteEmailStore.shared.exactMessageIDDuplicateIDs())?.count) ?? 0
        derivation = ctx
    }

    private func renderReport() -> String {
        WorkflowInstanceReport(
            wfNumber: wfNumber, title: title, status: status,
            createdBy: ForensicManager.shared.examinerName, createdAt: Date(),
            operations: definition.operations,
            confirmations: Dictionary(uniqueKeysWithValues: confirmations.map {
                ($0.key, ($0.value.confirmedAt, $0.value.confirmedBy, $0.value.result, $0.value.note, $0.value.docNumber)) }),
            fieldValues: savedValues
        ).rendered()
    }

    private func renderSummary() -> String {
        StakeholderSummary(
            wfNumber: wfNumber, title: title, persona: definition.persona, status: status,
            preparedBy: ForensicManager.shared.examinerName, preparedAt: Date(),
            operations: definition.operations,
            confirmations: Dictionary(uniqueKeysWithValues: confirmations.map {
                ($0.key, ($0.value.confirmedAt, $0.value.confirmedBy, $0.value.result, $0.value.note, $0.value.docNumber)) }),
            fieldValues: savedValues
        ).rendered()
    }

    #if os(macOS)
    private func printReport() { printText(renderReport(), monospace: true) }
    private func printSummary() { printText(renderSummary(), monospace: false) }

    private func printText(_ text: String, monospace: Bool) {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 468, height: 648))
        textView.string = text
        textView.font = monospace
            ? NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
            : NSFont.systemFont(ofSize: 11)
        let op = NSPrintOperation(view: textView)
        op.jobTitle = wfNumber
        op.run()
    }
    #endif
}
