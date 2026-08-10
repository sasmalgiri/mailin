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
    var onClose: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var wfNumber: String = ""
    @State private var title: String = ""
    @State private var status: String = "open"
    @State private var confirmations: [Int: SQLiteEmailStore.StoredConfirmation] = [:]
    @State private var activeOp: WorkflowOperation? = nil
    @State private var resultText = ""
    @State private var noteText = ""
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

    private func operationRow(_ op: WorkflowOperation) -> some View {
        let conf = confirmations[op.seq]
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
            }
            Spacer()
            Button(conf != nil ? "Reconfirm" : "Confirm") {
                resultText = conf?.result ?? ""
                noteText = conf?.note ?? ""
                activeOp = op
            }
            .controlSize(.small)
            .disabled(wfNumber.isEmpty)
            .help(op.postsDocType != nil
                  ? "Confirm this step — it posts a \(op.postsDocType!.displayName) document you can quote later"
                  : "Confirm this step — records who did it and when")
        }
        .padding(.vertical, 2)
    }

    private func confirmSheet(_ op: WorkflowOperation) -> some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            Text("Confirm: \(op.title)").font(Typography.title3)
            Text(op.hint).font(Typography.callout).foregroundColor(AppColors.secondary)
            if let doc = op.postsDocType {
                Label("Posts a \(doc.displayName) document on confirm", systemImage: doc.icon)
                    .font(Typography.caption1).foregroundColor(AppColors.primary)
            }
            TextField("Result (e.g. done, produced, 23 docs)", text: $resultText)
                .textFieldStyle(.roundedBorder)
            TextField("Note (optional)", text: $noteText, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(2...4)
            HStack {
                Spacer()
                Button("Cancel") { activeOp = nil }
                Button("Confirm") { Task { await confirm(op) } }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(Spacing.large)
        .frame(minWidth: 420)
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
        if let inst = try? await SQLiteEmailStore.shared.instance(wf: wfNumber) { status = inst.status }
    }

    @MainActor
    private func confirm(_ op: WorkflowOperation) async {
        // The step posts its document type (if any) as evidence it happened.
        var docNumber: String? = nil
        if let docType = op.postsDocType {
            docNumber = await DocumentRegistry.post(
                docType, summary: "\(definition.name): \(op.title)", refs: wfNumber)
        }
        await WorkflowService.confirm(
            wf: wfNumber, seq: op.seq, totalOps: definition.operations.count,
            result: resultText.isEmpty ? "done" : resultText, note: noteText, docNumber: docNumber)
        activeOp = nil
        resultText = ""; noteText = ""
        await refreshConfirmations()
    }

    private func renderReport() -> String {
        WorkflowInstanceReport(
            wfNumber: wfNumber, title: title, status: status,
            createdBy: ForensicManager.shared.examinerName, createdAt: Date(),
            operations: definition.operations,
            confirmations: Dictionary(uniqueKeysWithValues: confirmations.map {
                ($0.key, ($0.value.confirmedAt, $0.value.confirmedBy, $0.value.result, $0.value.note, $0.value.docNumber)) })
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
