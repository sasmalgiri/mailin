@testable import ArchiveCore
//
//  RawSourceRecoveryView.swift
//  maxmailin
//
//  Settings ▸ Health ▸ Recovery ▸ "Re-read attachments from the original
//  files…" (owner-approved 2026-11-07). Shows, before anything runs, how
//  many messages have no stored source and from which files; runs the
//  re-read for the sources it can find or the person points at; reports
//  recovered / unmatched / not found per source. Nothing else in a message
//  changes; the attachment index is told to read the recovered ones again.
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
    @State private var report: RawSourceRecovery.Report?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            Text(String(localized: "Re-read attachments from the original files")).font(Typography.headline)
            Text(String(localized: "Messages imported from PST, MSG or NSF files before 7 November 2026 were stored without their source, so their attachments cannot be opened or searched. This reads those files again and stores the source for each message. Headers, bodies, tags, notes, holds and folders are not changed."))
                .font(Typography.caption1).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let plan {
                if plan.total == 0 {
                    Label(String(localized: "Every message in this archive has its source stored. Nothing to do."), systemImage: "checkmark.circle")
                        .accessibilityIdentifier("recovery.rawSource.none")
                } else {
                    Text(String(localized: "\(plan.total) messages from \(plan.groups.count) sources have no stored source; \(plan.recoverable) can be re-read now."))
                        .font(Typography.caption1).bold()
                        .accessibilityIdentifier("recovery.rawSource.count")
                    ForEach(plan.groups) { group in
                        HStack(spacing: Spacing.small) {
                            Image(systemName: (group.fileURL ?? chosenFiles[group.id]) != nil ? "doc.fill" : "doc.badge.ellipsis")
                                .foregroundStyle((group.fileURL ?? chosenFiles[group.id]) != nil ? Color.accentColor : Color.orange)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(group.filename).font(Typography.caption1)
                                Text(group.fileURL != nil
                                     ? String(localized: "\(group.count) messages · copy inside the archive")
                                     : chosenFiles[group.id] != nil
                                        ? String(localized: "\(group.count) messages · file chosen: \(chosenFiles[group.id]!.lastPathComponent)")
                                        : String(localized: "\(group.count) messages · file not found — choose the original to re-read them"))
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
            if let report {
                Text(Self.reportText(report)).font(Typography.caption1).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("recovery.rawSource.report")
            }
            if let failure { Text(failure).font(Typography.caption2).foregroundStyle(.orange) }
            HStack {
                Button(String(localized: "Close")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if let plan, plan.total > 0 {
                    let runnable = plan.groups.filter { ($0.fileURL ?? chosenFiles[$0.id]) != nil }.reduce(0) { $0 + $1.count }
                    Button(working ? String(localized: "Re-reading…") : String(localized: "Re-read \(runnable) messages")) { Task { await run() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(working || runnable == 0 || report != nil)
                        .accessibilityIdentifier("recovery.rawSource.run")
                }
            }
        }
        .padding(Spacing.large)
        .frame(minWidth: 560)
        .task { plan = try? await RawSourceRecovery.plan(store: .shared) }
        .fileImporter(isPresented: Binding(get: { choosingFor != nil }, set: { if !$0 { choosingFor = nil } }),
                      allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            if let id = choosingFor, case .success(let urls) = result, let url = urls.first { chosenFiles[id] = url }
            choosingFor = nil
        }
    }

    /// "Recovered 12 of 14 messages · 2 unmatched · source not found: old.pst"
    static func reportText(_ report: RawSourceRecovery.Report) -> String {
        var line = String(localized: "Recovered \(report.recovered) messages; their attachments are being indexed again.")
        if report.unmatched > 0 { line += " " + String(localized: "\(report.unmatched) could not be matched to a message in the file.") }
        if !report.missingSources.isEmpty { line += " " + String(localized: "Source not found: \(report.missingSources.joined(separator: ", ")).") }
        let failures = report.sources.compactMap(\.failure)
        if !failures.isEmpty { line += " " + String(localized: "Failed: \(failures.joined(separator: "; "))") }
        return line
    }

    @MainActor
    private func run() async {
        guard let plan else { return }
        working = true
        defer { working = false }
        let files = chosenFiles
        let result = await RawSourceRecovery.run(store: .shared, plan: plan, files: files) { name in
            Task { @MainActor in progress = name }
        }
        report = result
        if !result.recoveredIDs.isEmpty { AttachmentTextIndexJob.shared.kickIfNeeded() }
    }
}
