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
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: Spacing.xxxSmall) {
                Label(definition.name, systemImage: "flowchart")
                    .font(Typography.title2)
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
            }
            Spacer()
            HelpDot(text: "This is one run of the \(definition.name) recipe. Work top to bottom: Confirm each step when done — mailin records who did it, when, and the document number it produced. You can close and reopen; progress is saved. Copy or Print the report for the file.")
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
                resultText = conf?.result ?? ""
                noteText = conf?.note ?? ""
                fieldValues = savedValues[op.seq] ?? [:]
                validationError = nil
                activeOp = op
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
                Spacer()
                Button("Cancel") { activeOp = nil }
                Button("Confirm & Save") { Task { await confirm(op) } }
                    .buttonStyle(.borderedProminent)
            }
            .padding(Spacing.medium)
        }
        .frame(minWidth: 460, minHeight: 380)
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
        } else {
            title = definition.name
            wfNumber = await WorkflowService.start(definition, title: title) ?? ""
            status = "open"
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
        resultText = ""; noteText = ""; fieldValues = [:]; validationError = nil
        await refreshConfirmations()
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

    #if os(macOS)
    private func printReport() {
        let text = renderReport()
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 468, height: 648))
        textView.string = text
        textView.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let op = NSPrintOperation(view: textView)
        op.jobTitle = wfNumber
        op.run()
    }
    #endif
}
