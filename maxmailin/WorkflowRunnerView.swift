//
//  WorkflowRunnerView.swift
//  maxmailin
//
//  Runs one workflow instance: the operation checklist for a WF-####. Each
//  step shows its hint, a Confirm control that records who/when/result and
//  the document it posted, and stays reopenable until every operation is
//  confirmed. A finished (or in-progress) run renders to a printable report.
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
    @State private var activeOp: WorkflowOperation? = nil
    @State private var resultText = ""
    @State private var noteText = ""
    @State private var fieldValues: [String: String] = [:]
    @State private var savedValues: [Int: [String: String]] = [:]
    @State private var validationError: String? = nil
    @State private var derivation = DerivationContext()
    @State private var derivedKeys: Set<String> = []
    @State private var showSaveVariant = false
    @State private var variantName = ""
    @State private var completedNumber: String? = nil
    @State private var clientName = ""
    @State private var showSummary = false
    @State private var draftSaved = false
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if isLoading {
                Spacer(); HStack { Spacer(); ProgressView(); Spacer() }; Spacer()
            } else {
                List {
                    Section {
                        ForEach(definition.operations) { op in
                            operationRow(op)
                        }
                    } header: {
                        Text("\(confirmations.count)/\(definition.operations.count) operations confirmed")
                    } footer: {
                        Text("Each confirmation records who, when, and the document it posted. Reopen any time — the run resumes where you left off.")
                            .font(Typography.caption2)
                    }
                }
            }
        }
        .toolWindowFrame()
        .task { await bootstrap() }
        .sheet(item: $activeOp) { op in
            confirmSheet(op)
        }
        .sheet(isPresented: $showSummary) {
            summarySheet
        }
        .alert("Save as Variant", isPresented: $showSaveVariant) {
            TextField("Variant name", text: $variantName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { Task { await saveVariant() } }
        } message: {
            Text("Reuse this run's field entries next time by starting from this variant.")
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
            HelpDot(text: "This is one run of the \(definition.name) recipe. Work top to bottom: Confirm each step when done — mailin records who did it, when, and the document number it produced. You can close and reopen; progress is saved. Copy or Print the report for the file.")
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

    private func lockedReasons(_ op: WorkflowOperation) -> [String] {
        let state = GatePolicy.RunState(
            confirmed: Set(confirmations.keys),
            fieldValues: savedValues)
        return GatePolicy.lockedReasons(op, state: state)
    }

    private func operationRow(_ op: WorkflowOperation) -> some View {
        let conf = confirmations[op.seq]
        let locks = conf == nil ? lockedReasons(op) : []   // confirmed steps show no lock
        return HStack(alignment: .top, spacing: Spacing.small) {
            Image(systemName: conf != nil ? "checkmark.circle.fill" : "circle")
                .foregroundColor(conf != nil ? .green : AppColors.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(op.seq). \(op.title)")
                    .font(Typography.callout).fontWeight(.semibold)
                Text(op.hint)
                    .font(Typography.caption1).foregroundColor(AppColors.secondary)
                if let conf {
                    HStack(spacing: Spacing.xxSmall) {
                        Text(conf.confirmedAt.formatted(date: .abbreviated, time: .shortened))
                        if !conf.confirmedBy.isEmpty { Text("· \(conf.confirmedBy)") }
                        if !conf.result.isEmpty { Text("· \(conf.result)") }
                        if let doc = conf.docNumber {
                            Text(doc).font(Typography.monoSmall).foregroundColor(AppColors.primary)
                        }
                    }
                    .font(Typography.caption2).foregroundColor(AppColors.secondary)
                }
                if let lock = locks.first {
                    Label(lock, systemImage: "lock.fill")
                        .font(Typography.caption2).foregroundColor(.orange)
                }
            }
            Spacer()
            if let dest = op.launches {
                Button {
                    onOpenDestination?(dest)
                } label: { Label("Open", systemImage: "arrow.up.forward.app") }
                .controlSize(.small)
                .disabled(!locks.isEmpty)
                .help(locks.isEmpty ? "Open the tool this step is done in — do the work, then come back and Confirm"
                                    : "Locked — \(locks.first ?? "")")
            }
            Button(conf != nil ? "Reconfirm" : "Confirm") {
                openStep(op)
            }
            .disabled(!locks.isEmpty)
            .controlSize(.small)
            .disabled(wfNumber.isEmpty)
            .help(op.postsDocType != nil
                  ? "Confirm this step — it posts a \(op.postsDocType!.displayName) document you can quote later"
                  : "Confirm this step — records who did it and when")
        }
        .padding(.vertical, 2)
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

    private func confirmSheet(_ op: WorkflowOperation) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Confirm: \(op.title)").font(Typography.title3)
                    Text(op.hint).font(Typography.caption1).foregroundColor(AppColors.secondary)
                }
                Spacer()
                if let doc = op.postsDocType {
                    Label(doc.displayName, systemImage: doc.icon)
                        .font(Typography.caption2).foregroundColor(AppColors.primary)
                        .help("Confirming posts a \(doc.displayName) document — a number you can quote later")
                }
            }
            .padding(Spacing.medium)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.medium) {
                    ForEach(op.fields) { field in
                        fieldEditor(field)
                    }
                    if !derivedKeys.isEmpty {
                        Label("Some fields were filled in from your archive — check and adjust before confirming.",
                              systemImage: "wand.and.stars")
                            .font(Typography.caption2).foregroundColor(AppColors.primary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Note (optional)").font(Typography.caption1).fontWeight(.semibold)
                        TextField("Anything else worth recording", text: $noteText, axis: .vertical)
                            .textFieldStyle(.roundedBorder).lineLimit(2...4)
                    }
                    if let err = validationError {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(Typography.caption1).foregroundColor(.red)
                    }
                }
                .padding(Spacing.medium)
            }
            Divider()
            HStack {
                if let dest = op.launches {
                    Button {
                        onOpenDestination?(dest)
                    } label: { Label("Open tool", systemImage: "arrow.up.forward.app") }
                    .help("Open the tool to do this step now")
                }
                if draftSaved {
                    Label("Draft saved", systemImage: "checkmark.circle")
                        .font(Typography.caption2).foregroundColor(.green)
                        .transition(.opacity)
                }
                Spacer()
                Button("Cancel") { activeOp = nil }
                Button("Confirm & Save") { Task { await confirm(op) } }
                    .buttonStyle(.borderedProminent)
            }
            .padding(Spacing.medium)
        }
        .frame(minWidth: 460, minHeight: 380)
        .onChange(of: fieldValues) {
            Task { await autosaveDraft(op) }
        }
    }

    @ViewBuilder
    private func fieldEditor(_ field: WorkflowField) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(field.label).font(Typography.caption1).fontWeight(.semibold)
                if field.required {
                    Text("required").font(Typography.caption2).foregroundColor(.orange)
                }
            }
            switch field.kind {
            case .text, .number, .date:
                TextField(field.placeholder, text: binding(field.key))
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .keyboardType(field.kind == .number ? .numbersAndPunctuation : .default)
                    #endif
            case .longText:
                TextField(field.placeholder.isEmpty ? "…" : field.placeholder,
                          text: binding(field.key), axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(2...5)
            case .bool:
                Toggle(isOn: boolBinding(field.key)) { Text(field.help).font(Typography.caption2) }
            case .choice:
                Picker("", selection: binding(field.key)) {
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

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { fieldValues[key] ?? "" }, set: { fieldValues[key] = $0 })
    }
    private func boolBinding(_ key: String) -> Binding<Bool> {
        Binding(get: { fieldValues[key] == "Yes" },
                set: { fieldValues[key] = $0 ? "Yes" : "" })
    }

    // MARK: logic

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
                let expanded = VariantCodec.expand(v.values)
                for (seq, fields) in expanded {
                    try? await SQLiteEmailStore.shared.saveFieldValues(wf: wfNumber, seq: seq, values: fields)
                }
            }
        }
        await refreshConfirmations()
        isLoading = false
    }

    @MainActor
    private func refreshConfirmations() async {
        guard !wfNumber.isEmpty else { return }
        let confs = (try? await SQLiteEmailStore.shared.confirmations(wf: wfNumber)) ?? []
        confirmations = Dictionary(uniqueKeysWithValues: confs.map { ($0.seq, $0) })
        savedValues = (try? await SQLiteEmailStore.shared.fieldValues(wf: wfNumber)) ?? [:]
        if let inst = try? await SQLiteEmailStore.shared.instance(wf: wfNumber) { status = inst.status }
        await gatherDerivation()
    }

    private func openStep(_ op: WorkflowOperation) {
        var values = savedValues[op.seq] ?? [:]
        let derived = FieldDerivation.derive(defID: definition.defID, opKey: op.key, ctx: derivation)
        var filled: Set<String> = []
        for (k, v) in derived where (values[k] ?? "").isEmpty {
            values[k] = v; filled.insert(k)
        }
        fieldValues = values
        derivedKeys = filled
        resultText = confirmations[op.seq]?.result ?? ""
        noteText = confirmations[op.seq]?.note ?? ""
        validationError = nil
        draftSaved = false
        activeOp = op
    }

    @MainActor
    private func confirm(_ op: WorkflowOperation) async {
        // Required fields must be filled — a defensible record can't have holes.
        let missing = WorkflowFieldValidation.missingRequired(op.fields, values: fieldValues)
        guard missing.isEmpty else {
            validationError = "Please fill: \(missing.joined(separator: ", "))"
            return
        }
        // Persist the data the user entered (reusable in the completion doc).
        try? await SQLiteEmailStore.shared.saveFieldValues(wf: wfNumber, seq: op.seq, values: fieldValues)
        // The step posts its document type (if any) as evidence it happened.
        var docNumber: String? = nil
        if let docType = op.postsDocType {
            docNumber = await DocumentRegistry.post(
                docType, summary: "\(definition.name): \(op.title)", refs: wfNumber)
        }
        // A concise result line from the first meaningful field, else "done".
        let auto = op.fields.compactMap { fieldValues[$0.key]?.isEmpty == false ? fieldValues[$0.key] : nil }.first
        await WorkflowService.confirm(
            wf: wfNumber, seq: op.seq, totalOps: definition.operations.count,
            result: auto ?? "done", note: noteText, docNumber: docNumber)
        activeOp = nil
        resultText = ""; noteText = ""; fieldValues = [:]; validationError = nil; derivedKeys = []
        await refreshConfirmations()
        await refreshSearchText()
        if status == "confirmed" { completedNumber = wfNumber }
        // Auto-advance: jump straight to the next step that's now unlocked and
        // not yet confirmed — no hunting for "what's next".
        if let next = definition.operations.first(where: {
            confirmations[$0.seq] == nil && lockedReasons($0).isEmpty
        }) {
            openStep(next)
        }
    }

    /// Persist in-progress entries the moment they change — so closing the
    /// window, or an interruption, never loses what was typed (the Relativity
    /// "times out and loses your place in the queue" complaint). Reopening the
    /// step restores the draft; refreshSearchText keeps it findable meanwhile.
    @MainActor
    private func autosaveDraft(_ op: WorkflowOperation) async {
        guard !wfNumber.isEmpty, activeOp?.seq == op.seq else { return }
        try? await SQLiteEmailStore.shared.saveFieldValues(wf: wfNumber, seq: op.seq, values: fieldValues)
        savedValues[op.seq] = fieldValues
        await refreshSearchText()
        draftSaved = true
    }

    @MainActor
    private func persistTitle() async {
        guard !wfNumber.isEmpty else { return }
        let t = clientName.trimmingCharacters(in: .whitespaces)
        title = t.isEmpty ? definition.name : t
        // Fold into the document's searchable text immediately.
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
        // Attach the full run so opening WF-… reproduces the entire job —
        // every step, field value, who/when, and the documents it posted.
        try? await SQLiteEmailStore.shared.attachDocumentPayload(wfNumber, body: renderReport())
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
