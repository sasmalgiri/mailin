@testable import ArchiveCore
//
//  RawSourceRecoveryView.swift
//  maxmailin
//
//  Settings ▸ Health ▸ Recovery ▸ "Recover missing imported attachments…"
//  (owner-approved 2026-11-07; hardened per the completion directive §2).
//  Shows, before anything runs, how many messages of each PST/MSG/NSF import
//  have no stored source or no retrievable attachment bytes, and how many are
//  already intact; backs the archive up; re-reads the files it can find or
//  the person points at; writes only corroborated matches; lists ambiguous
//  rows with both sides for review; shows and saves the six-count receipt.
//  Nothing else in a message changes; the attachment index is told to read
//  the recovered ones again.
//

import SwiftUI
import UniformTypeIdentifiers

struct RawSourceRecoveryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var plan: RawSourceRecovery.Plan?
    @State private var chosenFiles: [String: URL] = [:]
    @State private var choosingFor: String?
    @State private var working = false
    @State private var progress: String?
    @State private var receipt: RawSourceRecovery.Receipt?
    @State private var receiptURL: URL?
    @State private var runTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            Text(String(localized: "Recover missing imported attachments")).font(Typography.headline)
            Text(String(localized: "Messages imported from PST, MSG or NSF files before 7 November 2026 were stored without their source, so their attachments cannot be opened or searched. This backs the archive up, reads those files again and stores a reconstructed source for each message that matches on Message-ID and content. Headers, bodies, tags, notes, holds, folders and Trash are not changed; uncertain matches are listed, not written."))
                .font(Typography.caption1).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let plan {
                if plan.total == 0 {
                    Label(String(localized: "Every imported message has its source and attachment bytes. Nothing to do."), systemImage: "checkmark.circle")
                        .accessibilityIdentifier("recovery.rawSource.none")
                } else {
                    Text(String(localized: "\(plan.total) messages from \(plan.affectedGroups.count) sources are affected; \(plan.recoverable) can be re-read now; \(plan.alreadyIntact) messages of the same sources are already intact."))
                        .font(Typography.caption1).bold()
                        .accessibilityIdentifier("recovery.rawSource.count")
                    ForEach(plan.affectedGroups) { group in
                        HStack(spacing: Spacing.small) {
                            Image(systemName: (group.fileURL ?? chosenFiles[group.id]) != nil ? "doc.fill" : "doc.badge.ellipsis")
                                .foregroundStyle((group.fileURL ?? chosenFiles[group.id]) != nil ? Color.accentColor : Color.orange)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(group.filename).font(Typography.caption1)
                                Text(group.fileURL != nil
                                     ? String(localized: "\(group.count) affected, \(group.alreadyIntact) intact · copy inside the archive")
                                     : chosenFiles[group.id] != nil
                                        ? String(localized: "\(group.count) affected, \(group.alreadyIntact) intact · file chosen: \(chosenFiles[group.id]!.lastPathComponent)")
                                        : String(localized: "\(group.count) affected, \(group.alreadyIntact) intact · file not found — choose the original to re-read them"))
                                    .font(Typography.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if group.fileURL == nil {
                                Button(String(localized: "Choose file…")) { choosingFor = group.id }
                                    .font(Typography.caption1)
                                    .accessibilityIdentifier("recovery.rawSource.choose.\(group.id)")
                            }
                        }
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
            if let progress, working { Text(String(localized: "Reading \(progress)…")).font(Typography.caption2).foregroundStyle(.secondary) }
            if let receipt {
                Text(Self.receiptText(receipt)).font(Typography.caption1).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("recovery.rawSource.report")
                if !receipt.ambiguousItems.isEmpty {
                    Text(String(localized: "Not written — review these \(receipt.ambiguousItems.count) rows:")).font(Typography.caption1).bold()
                    ScrollView {
                        VStack(alignment: .leading, spacing: Spacing.xSmall) {
                            ForEach(Array(receipt.ambiguousItems.prefix(200).enumerated()), id: \.offset) { _, item in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(String(localized: "Archive: \(item.storedSubject) · \(item.storedDate.formatted(date: .abbreviated, time: .shortened)) · \(item.storedFrom)"))
                                    Text(String(localized: "File: \(item.fileSubject) · \(item.fileDate?.formatted(date: .abbreviated, time: .shortened) ?? "—") · \(item.fileFrom)"))
                                    Text(item.reason).foregroundStyle(.orange)
                                }
                                .font(Typography.caption2)
                            }
                            if receipt.ambiguousItems.count > 200 {
                                Text(String(localized: "The receipt file lists all \(receipt.ambiguousItems.count).")).font(Typography.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxHeight: 160)
                    .accessibilityIdentifier("recovery.rawSource.ambiguous")
                }
                if let receiptURL {
                    Text(String(localized: "Receipt saved: \(receiptURL.lastPathComponent)")).font(Typography.caption2).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button(String(localized: "Close")) { runTask?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                if working {
                    Button(String(localized: "Stop")) { runTask?.cancel() }
                        .accessibilityIdentifier("recovery.rawSource.stop")
                }
                Spacer()
                if let plan, plan.total > 0 {
                    let runnable = plan.affectedGroups.filter { ($0.fileURL ?? chosenFiles[$0.id]) != nil }.reduce(0) { $0 + $1.count }
                    Button(working ? String(localized: "Recovering…") : String(localized: "Back up and recover \(runnable) messages")) {
                        runTask = Task { await run() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || runnable == 0 || receipt != nil)
                    .accessibilityIdentifier("recovery.rawSource.run")
                }
            }
        }
        .padding(Spacing.large)
        .frame(minWidth: 620)
        .task { plan = try? await RawSourceRecovery.plan(store: .shared) }
        .fileImporter(isPresented: Binding(get: { choosingFor != nil }, set: { if !$0 { choosingFor = nil } }),
                      allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            if let id = choosingFor, case .success(let urls) = result, let url = urls.first {
                _ = url.startAccessingSecurityScopedResource()   // released when the sheet goes away with the process' scope
                chosenFiles[id] = url
            }
            choosingFor = nil
        }
    }

    /// "Affected 14 · recovered 11 · already intact 120 · ambiguous 1 · missing source 1 · failed 1. Backup: emails-….db …"
    static func receiptText(_ receipt: RawSourceRecovery.Receipt) -> String {
        var line = String(localized: "Affected \(receipt.affected) · recovered \(receipt.recovered) · already intact \(receipt.alreadyIntact) · ambiguous \(receipt.ambiguous) · missing source \(receipt.missingSource) · failed \(receipt.failed).")
        if receipt.recovered > 0 { line += " " + String(localized: "Recovered attachments are being indexed again.") }
        if let snapshot = receipt.snapshotPath { line += " " + String(localized: "Backup before the repair: \((snapshot as NSString).lastPathComponent).") }
        if receipt.cancelled { line += " " + String(localized: "Stopped after \(receipt.sourcesRead) of \(receipt.sourcesWithWork) sources; the file being read was not written.") }
        if !receipt.missingSources.isEmpty { line += " " + String(localized: "Source not found: \(receipt.missingSources.joined(separator: ", ")).") }
        if !receipt.wrongSources.isEmpty { line += " " + String(localized: "Wrong source (hash differs from the registered file): \(receipt.wrongSources.joined(separator: ", ")).") }
        let failures = receipt.sources.compactMap(\.failure)
        if !failures.isEmpty { line += " " + String(localized: "Failed: \(failures.joined(separator: "; "))") }
        return line
    }

    @MainActor
    private func run() async {
        guard let plan else { return }
        working = true
        defer { working = false; runTask = nil }
        let files = chosenFiles
        let receipts = RawSourceRecoveryReceiptStore.production
        let result = await RawSourceRecovery.run(store: .shared, plan: plan, files: files, receipts: receipts) { name in
            Task { @MainActor in progress = name }
        }
        receipt = result
        receiptURL = receipts.list().first
        ForensicManager.shared.logAction("Recover missing imported attachments", detail: result.line)
        if !result.recoveredIDs.isEmpty { AttachmentTextIndexJob.shared.kickIfNeeded() }
    }
}
