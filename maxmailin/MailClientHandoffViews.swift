@testable import ArchiveCore
//
//  MailClientHandoffViews.swift
//  maxmailin
//
//  H3 / H4: guided handoff to and from Apple Mail and Thunderbird.
//
//  Import: explains exactly how each client exports a mailbox (Mail's
//  Mailbox ▸ Export Mailbox… writes an .mbox package; Thunderbird's profile
//  folders hold raw mbox files), auto-detects what is on this Mac, and hands
//  the chosen folders to the ordinary import funnel — the pre-import sheet
//  and the queue apply as for any other source.
//
//  Export: writes the archive (or the current filter) as mbox partitions into
//  a folder the user picks, VERIFIES the export by re-parsing it and
//  comparing counts, and only then shows the exact steps to import it into
//  the chosen client. The receipt names the folder, the partition count and
//  the verification result.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

enum MailClient: String, CaseIterable, Identifiable {
    case appleMail
    case thunderbird
    var id: String { rawValue }
    var name: String { self == .appleMail ? String(localized: "Apple Mail") : String(localized: "Thunderbird") }
    var symbol: String { self == .appleMail ? "envelope" : "bird" }
}

// MARK: - Import

struct MailClientImportSheet: View {
    @ObservedObject var viewModel: ContentViewModel
    let onImport: ([URL]) -> Void
    let onCancel: () -> Void

    @State private var client: MailClient = .appleMail
    @State private var detected: [URL] = []
    @State private var scanned = false
    #if os(iOS)
    @State private var showPicker = false
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Mail client", selection: $client) {
                        ForEach(MailClient.allCases) { Label($0.name, systemImage: $0.symbol).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .onChange(of: client) { _, _ in scanned = false; detected = [] }

                    steps
                    detectedSection
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 440)
        .accessibilityIdentifier("handoff.import")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Import from a mail client").font(.title3.weight(.semibold))
            Text("Nothing is copied or changed in the mail client. mailin reads exported mailboxes.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
    }

    @ViewBuilder
    private var steps: some View {
        switch client {
        case .appleMail:
            stepList("How to export from Apple Mail", [
                "In Mail, select the mailbox (or several) in the sidebar.",
                "Choose Mailbox ▸ Export Mailbox… and pick a folder.",
                "Mail writes one “Name.mbox” package per mailbox into that folder.",
                "Choose that folder below. mailin imports every package inside it."
            ])
            Text("Alternatively, “Detect on this Mac” looks in ~/Library/Mail for mailboxes Mail already stores locally.")
                .font(.caption2).foregroundStyle(.secondary)
        case .thunderbird:
            stepList("How Thunderbird stores mail", [
                "Thunderbird keeps each folder as a raw mbox file inside its profile (Library/Thunderbird/Profiles/…/Mail or ImapMail).",
                "Quit Thunderbird first so the files are not being written to.",
                "Use “Detect on this Mac” to find the profile folders, or choose a profile folder yourself.",
                "Every mbox file in the folder is imported; .msf index files are skipped."
            ])
        }
    }

    private func stepList(_ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            ForEach(Array(items.enumerated()), id: \.offset) { index, text in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1).").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var detectedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Found on this Mac").font(.headline)
                Spacer()
                #if os(macOS)
                Button("Detect on this Mac") { detect() }
                    .controlSize(.small)
                    .accessibilityIdentifier("handoff.import.detect")
                #endif
            }
            if scanned && detected.isEmpty {
                Text("Nothing found for \(client.name). Export a mailbox as described above, then choose its folder.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(detected, id: \.self) { url in
                Label(url.path, systemImage: "folder")
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                    .help(url.path)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
            Spacer()
            Button("Choose a folder…") { chooseFolder() }
                .accessibilityIdentifier("handoff.import.choose")
            Button(detected.count == 1 ? "Import what was found" : "Import all \(detected.count) found") {
                onImport(detected)
            }
            .buttonStyle(.borderedProminent)
            .disabled(detected.isEmpty)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("handoff.import.start")
        }
        .padding(16)
        #if os(iOS)
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result, !urls.isEmpty { onImport(urls) }
        }
        #endif
    }

    private func detect() {
        switch client {
        case .appleMail:
            viewModel.scanForAppleMailBoxes()
            detected = viewModel.appleMailBoxes
        case .thunderbird:
            viewModel.scanForThunderbirdProfiles()
            detected = viewModel.thunderbirdProfiles
        }
        scanned = true
    }

    private func chooseFolder() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.message = client == .appleMail
            ? "Choose the folder Mail exported into (it holds one .mbox package per mailbox)"
            : "Choose a Thunderbird profile folder or one of its mbox files"
        panel.prompt = "Import"
        if panel.runModal() == .OK, !panel.urls.isEmpty { onImport(panel.urls) }
        #else
        showPicker = true
        #endif
    }
}

// MARK: - Export

struct MailClientExportSheet: View {
    /// The scope to hand off — the whole archive or the current filter.
    let scope: ArchiveSelectionScope
    let scopeLabel: String
    let onDone: () -> Void

    @State private var client: MailClient = .appleMail
    @State private var destination: URL?
    @State private var isRunning = false
    @State private var stage = ""
    @State private var result: HandoffExportResult?
    @State private var errorMessage: String?
    #if os(iOS)
    @State private var showPicker = false
    #endif

    struct HandoffExportResult: Equatable {
        var folder: URL
        var records: Int
        var partitions: Int
        var bytes: Int64
        var reparsed: Int
        var reparseFailed: Int
        var verified: Bool { reparsed == records && reparseFailed == 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Export to a mail client").font(.title3.weight(.semibold))
                Text("\(scopeLabel) as standard mbox files, verified by reading them back before you import them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Mail client", selection: $client) {
                        ForEach(MailClient.allCases) { Label($0.name, systemImage: $0.symbol).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()

                    destinationRow
                    if isRunning { runningRow }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red)
                    }
                    if let result { resultSection(result) }
                }
                .padding(20)
            }
            Divider()
            HStack {
                Button(result == nil ? String(localized: "Cancel") : String(localized: "Done"), role: .cancel, action: onDone).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Choose a folder…") { chooseFolder() }.disabled(isRunning)
                Button("Export and verify") { Task { await run() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(destination == nil || isRunning)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("handoff.export.start")
            }
            .padding(16)
        }
        .frame(minWidth: 560, minHeight: 460)
        .accessibilityIdentifier("handoff.export")
        #if os(iOS)
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.folder]) { r in
            if case .success(let url) = r { destination = url }
        }
        #endif
    }

    private var destinationRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            Text(destination?.path ?? "No folder chosen — the mbox files are written into a “mailin-handoff” folder inside it")
                .font(.system(.caption, design: .monospaced))
                .lineLimit(2).truncationMode(.middle)
                .foregroundStyle(destination == nil ? .secondary : .primary)
        }
    }

    private var runningRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(stage).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func resultSection(_ r: HandoffExportResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(r.verified
                  ? "Verified: \(r.records) messages written in \(r.partitions) file\(r.partitions == 1 ? "" : "s") (\(ByteCountFormatter.string(fromByteCount: r.bytes, countStyle: .file))) and read back exactly."
                  : "Written \(r.records) messages but read back \(r.reparsed) (\(r.reparseFailed) damaged) — do not import this until the difference is understood.",
                  systemImage: r.verified ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(r.verified ? .green : .orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("handoff.export.verdict")
            if r.verified {
                Text("Now, in \(client.name):").font(.headline)
                ForEach(Array(importSteps.enumerated()), id: \.offset) { index, text in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }
                #if os(macOS)
                Button("Reveal the folder in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([r.folder])
                }
                .controlSize(.small)
                #endif
            }
        }
    }

    private var importSteps: [String] {
        switch client {
        case .appleMail:
            return [
                "Choose File ▸ Import Mailboxes…",
                "Select “Files in mbox format” and click Continue.",
                "Choose the “mailin-handoff” folder (or the individual .mbox files inside it) and click Choose.",
                "Mail creates an “Import” mailbox with one folder per file. Move them where you want them.",
                "Compare the message count with the number above; they must match."
            ]
        case .thunderbird:
            return [
                "Quit Thunderbird, or use the ImportExportTools NG add-on (Tools ▸ ImportExportTools NG ▸ Import mbox file).",
                "Without the add-on: copy each .mbox file into the profile's Local Folders directory, removing the “.mbox” extension.",
                "Start Thunderbird; each file appears as a folder under Local Folders.",
                "Compare the message count with the number above; they must match."
            ]
        }
    }

    private func chooseFolder() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose where to write the mbox files"
        panel.prompt = "Export here"
        if panel.runModal() == .OK { destination = panel.url }
        #else
        showPicker = true
        #endif
    }

    private func run() async {
        guard let destination else { return }
        isRunning = true
        errorMessage = nil
        result = nil
        defer { isRunning = false }
        let folder = destination.appendingPathComponent("mailin-handoff", isDirectory: true)
        do {
            stage = "Writing mbox files…"
            let service = ArchiveExportService.shared
            let results = try await service.exportMBOXPartitions(scope: scope, toDirectory: folder, baseName: "mailin-handoff")
            let records = results.last?.recordsWritten ?? 0
            let bytes = results.reduce(Int64(0)) { $0 + Int64($1.bytesWritten) }
            stage = "Reading the files back…"
            let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "mbox" }
            var reparsed = 0, failed = 0
            for file in files {
                let report = try await ParserFactory.parseStreamingCallback(fileURL: file, senderEmail: "", batchSize: 500) { reparsed += $0.count }
                failed += report.failed
            }
            let outcome = HandoffExportResult(folder: folder, records: records, partitions: files.count,
                                              bytes: bytes, reparsed: reparsed, reparseFailed: failed)
            result = outcome
            // A8: the handoff is an export like any other — it ends in a receipt.
            ExportRunCenter.shared.record(ExportReceipt(
                title: "Export to \(client.name)", destination: folder.path, isFolder: true,
                requested: records, written: records, bytesWritten: Int(bytes),
                outcome: outcome.verified ? .complete : .failed,
                errorMessage: outcome.verified ? nil : "Read-back returned \(reparsed) of \(records) messages",
                startedAt: Date(), completedAt: Date()))
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Presentation

/// Attached once at the ContentView root, like the import surfaces.
struct HandoffSurfacesModifier: ViewModifier {
    @Binding var showImport: Bool
    @Binding var showExport: Bool
    @ObservedObject var viewModel: ContentViewModel
    let exportScope: () -> ArchiveSelectionScope
    let exportScopeLabel: () -> String
    let onImport: ([URL]) -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showImport) {
                MailClientImportSheet(viewModel: viewModel,
                                      onImport: { urls in showImport = false; onImport(urls) },
                                      onCancel: { showImport = false })
            }
            .sheet(isPresented: $showExport) {
                MailClientExportSheet(scope: exportScope(), scopeLabel: exportScopeLabel(), onDone: { showExport = false })
            }
    }
}
