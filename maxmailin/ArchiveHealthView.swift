@testable import ArchiveCore
//
//  ArchiveHealthView.swift
//  maxmailin
//
//  §3-S7: Settings ▸ Health — one place that says whether the archive is
//  healthy and recoverable: database integrity, snapshots, analysis-index
//  coverage, free disk, 3.0 engine trips and fallbacks, and on-device crash
//  diagnostics. "Run full check" runs SQLite's integrity check on demand.
//  Read-only except for the actions the user presses.
//

import SwiftUI
import UniformTypeIdentifiers

struct ArchiveHealthView: View {
    /// WP4: the evidence behind a format row, in the person's words.
    static func evidenceLabel(_ evidence: FormatCapability.Evidence) -> String {
        switch evidence {
        case .realFixtures: return String(localized: "Tested on real files")
        case .syntheticFixtures: return String(localized: "Tested on spec-built fixtures")
        case .notExecuted: return String(localized: "Implemented, not yet run on a file")
        case .notImplemented: return String(localized: "Not implemented")
        }
    }

    @Environment(ModuleRegistry.self) private var modules
    @State private var integrity: String?
    @State private var checking = false
    @State private var snapshots: [ArchiveSnapshot] = []
    @State private var coverage: (analyzed: Int, total: Int) = (0, 0)
    @State private var freeBytes: Int64?
    @State private var note: String?
    @State private var working = false
    @State private var featureCoverage: (indexed: Int, total: Int) = (0, 0)
    @State private var fingerprintRoot: String?
    @State private var legalCounts: SQLiteEmailStore.LegalStateCounts?
    @State private var choosingSnapshotFolder = false
    @State private var snapshotFolder: URL?
    /// LIFE-01: original files that locator-backed messages still need and that are not where they were.
    @State private var missingSources: [MissingLocatorSource] = []
    @State private var relinking: MissingLocatorSource?
    @State private var sourceCopyBytes: Int64 = 0

    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    private static let lastIntegrityKey = "archiveHealth.lastIntegrity"
    private static let lastIntegrityDateKey = "archiveHealth.lastIntegrityDate"

    var body: some View {
        Form {
            Section("Database") {
                LabeledContent(String(localized: "Integrity")) {
                    if checking { ProgressView().controlSize(.small) }
                    else { Text(integrityText).foregroundStyle(integrity == "ok" ? .green : .orange) }
                }
                Button(String(localized: "Run full check")) { Task { await runCheck() } }
                    .disabled(checking)
                if let freeBytes {
                    LabeledContent(String(localized: "Free disk space"),
                                   value: ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file))
                }
            }

            // LIFE-05: every recovery action in one place, each saying what it
            // does before it runs; none of them deletes data.
            Section("Recovery") {
                Text("What to do when something went wrong — each action keeps the archive as it is until it has finished, and nothing here deletes data.")
                    .font(.caption).foregroundStyle(.secondary)
                #if os(macOS)
                Button(String(localized: "Retry failed imports…")) { openWindow(id: "import-receipt") }
                    .help("Opens the latest import receipt; its “Retry failed sources” imports again only the files that failed, from their checkpoints")
                    .accessibilityIdentifier("health.retryFailedImports")
                #endif
                Button(String(localized: "Rebuild search index")) {
                    Task { @MainActor in
                        working = true; defer { working = false }
                        note = await SafeModeActions.rebuildSearchIndex()
                    }
                }
                .disabled(working)
                .help("Rebuilds the full-text index from the stored emails, batch by batch; the archive itself is not modified")
                .accessibilityIdentifier("health.rebuildIndex")
                Text("Original files that moved: use “Relink…” in Original files below. A detached archive volume: reconnect it and relaunch (Archive location).")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            // CAP-06: every limit the app enforces, named, with its kind —
            // and the five jobs listed as having no cap of the app's own.
            // WP4: the one registry of formats, with its evidence — the same list the support table is generated from.
            Section("Formats") {
                Text("What mailin reads, and on what evidence. “Spec-built” means tested on fixtures written from the format description, not on files from the program itself.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(FormatCapabilityRegistry.all) { capability in
                    VStack(alignment: .leading, spacing: 2) {
                        LabeledContent(capability.name) { Text(Self.evidenceLabel(capability.evidence)) }
                        if !capability.extensions.isEmpty {
                            Text(capability.extensions.joined(separator: ", "))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                // FIND-02: the recogniser's own list, read at run time — never a typed list.
                let ocrLanguages = AttachmentOCR.supportedLanguages()
                Text(ocrLanguages.isEmpty
                     ? String(localized: "Text recognition (OCR): this device did not report its languages.")
                     : String(localized: "Text recognition (OCR) languages on this device: \(ocrLanguages.joined(separator: ", "))"))
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("health.formats.ocrLanguages")
                // §13.3 (11): what the last reader upgrade re-read.
                if let rebuild = AttachmentTextIndexJob.rebuildReportText(AttachmentTextIndexJob.rebuildRecord()) {
                    Text(rebuild).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("health.formats.rebuild")
                }
            }
            .accessibilityIdentifier("health.formats")

            Section("Limits") {
                Text("Every limit mailin enforces, and what kind of limit it is. The five archive jobs have no cap of the app's own; plan rules are shown on the purchase screen too.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(AppLimits.all) { limit in
                    VStack(alignment: .leading, spacing: 2) {
                        LabeledContent(limit.what) { Text(limit.value) }
                        Text("\(limit.kind.label) — \(limit.why)")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .accessibilityIdentifier("health.limits")

            Section("Snapshots") {
                if !modules.isOn(.v3Snapshots) {
                    Text("Archive snapshots are off. Turn on “Archive snapshots (3.0)” in Modules to keep a restorable copy before every upgrade and once a day.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let failure = ArchiveSnapshotPolicy.upgradeSnapshotFailure {
                    Label(String(localized: "No snapshot could be taken before the last upgrade: \(failure)"),
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if snapshots.isEmpty {
                    Text("No snapshots yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(snapshots) { snap in
                        LabeledContent("\(snap.date.formatted(date: .abbreviated, time: .shortened)) — \(snap.reason)",
                                       value: ByteCountFormatter.string(fromByteCount: snap.bytes, countStyle: .file))
                    }
                }
                HStack {
                    Button(String(localized: "Take snapshot now")) {
                        Task { @MainActor in
                            working = true; defer { working = false }
                            do {
                                _ = try await SQLiteEmailStore.shared.snapshot(reason: "manual")
                                note = String(localized: "Snapshot saved.")
                            } catch { note = error.localizedDescription }
                            reload()
                        }
                    }
                    .disabled(working)
                    Button(String(localized: "Restore latest…")) {
                        Task { @MainActor in
                            working = true; defer { working = false }
                            note = await ArchiveSnapshots.restoreLatestInteractively()
                            reload()
                        }
                    }
                    .disabled(working || snapshots.isEmpty)
                }
                // LIFE-02: a full backup — database, attachment-text states,
                // message files, source copies, receipts — with an inventory;
                // restorable on a clean Mac.
                HStack {
                    Button(String(localized: "Back up archive…")) {
                        Task { @MainActor in
                            working = true; defer { working = false }
                            note = await ArchiveBackups.backUpInteractively()
                        }
                    }
                    .disabled(working)
                    .help("Writes the database, attachment-text states, message files, source copies and receipts into a new folder with an inventory of every file's SHA-256. The search index is rebuilt on restore, not copied.")
                    .accessibilityIdentifier("health.backup")
                    Button(String(localized: "Restore from backup…")) {
                        Task { @MainActor in
                            working = true; defer { working = false }
                            note = await ArchiveBackups.restoreInteractively()
                            reload()
                        }
                    }
                    .disabled(working)
                    .help("Verifies every file of a backup folder against its inventory, keeps the current database as a snapshot, then restores. Nothing already in the archive is deleted.")
                    .accessibilityIdentifier("health.restoreBackup")
                }
                // §3-S1: an external location, e.g. a backup disk.
                LabeledContent(String(localized: "Snapshot folder")) {
                    if let snapshotFolder {
                        Text(ArchiveSnapshotPolicy.reachableExternalDirectory == nil
                             ? String(localized: "\(snapshotFolder.lastPathComponent) (not connected — saving beside the archive)")
                             : snapshotFolder.lastPathComponent)
                    } else {
                        Text("Beside the archive")
                    }
                }
                HStack {
                    Button(String(localized: "Choose snapshot folder…")) { choosingSnapshotFolder = true }
                        .disabled(working)
                    if snapshotFolder != nil {
                        Button(String(localized: "Save beside the archive")) {
                            SnapshotLocation.clear()
                            note = String(localized: "Snapshots will be saved beside the archive. Snapshots already in the other folder stay there.")
                            reload()
                        }
                        .disabled(working)
                    }
                }
                .fileImporter(isPresented: $choosingSnapshotFolder, allowedContentTypes: [.folder]) { result in
                    if case .success(let url) = result { note = SnapshotLocation.choose(url) }
                    reload()
                }
            }

            Section("Original files") {
                // LIFE-01: what the archive still depends on outside itself.
                if modules.isOn(.selfContainedArchive) {
                    LabeledContent(String(localized: "Copies of imported files"),
                                   value: ByteCountFormatter.string(fromByteCount: sourceCopyBytes, countStyle: .file))
                    Text("New imports are copied into the archive and checked byte for byte, so the archive stays complete when the original file is moved or deleted.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Messages above the full-parse ceiling are read from the original file. Turn on “Self-contained archive” in Modules to copy imported files into the archive instead.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if missingSources.isEmpty {
                    LabeledContent(String(localized: "Original files not found"), value: String(localized: "None"))
                } else {
                    ForEach(missingSources) { missing in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(missing.filename)
                                Text("\(missing.messages) messages are read from this file, \(missing.deferredMessages) have no other copy — \(missing.sourcePath)")
                                    .font(.caption).foregroundStyle(.orange)
                                    .lineLimit(2).truncationMode(.middle)
                            }
                            Spacer()
                            Button(String(localized: "Relink…")) { relinking = missing }
                                .accessibilityIdentifier("health.relink")
                                .disabled(working || missing.sourceDigest.isEmpty)
                                .help(missing.sourceDigest.isEmpty
                                      ? String(localized: "Imported before file digests were recorded; the file cannot be verified.")
                                      : String(localized: "Choose the moved file. It is accepted only if its contents match what was imported."))
                        }
                    }
                }
            }
            .fileImporter(isPresented: Binding(get: { relinking != nil }, set: { if !$0 { relinking = nil } }),
                          allowedContentTypes: [.data, .item]) { result in
                guard let missing = relinking else { return }
                relinking = nil
                guard case .success(let url) = result else { return }
                Task { @MainActor in
                    working = true; defer { working = false }
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    do {
                        let moved = try await SQLiteEmailStore.shared.relinkLocators(sourceDigest: missing.sourceDigest, to: url)
                        note = String(localized: "\(missing.filename) relinked: \(moved) messages read from \(url.lastPathComponent) again.")
                    } catch {
                        note = error.localizedDescription
                    }
                    await loadSources()
                }
            }

            Section("Analysis index") {
                let pct = coverage.total > 0 ? Double(coverage.analyzed) / Double(coverage.total) : 0
                LabeledContent(String(localized: "Emails analysed"),
                               value: "\(coverage.analyzed.formatted()) of \(coverage.total.formatted())")
                ProgressView(value: pct)
                    .accessibilityLabel(String(localized: "Emails analysed"))
                if modules.isOn(.v3FeatureIndex) {
                    let fp = featureCoverage.total > 0 ? Double(featureCoverage.indexed) / Double(featureCoverage.total) : 0
                    LabeledContent(String(localized: "Per-email analysis index (3.0)"),
                                   value: "\(featureCoverage.indexed.formatted()) of \(featureCoverage.total.formatted())")
                    ProgressView(value: fp)
                        .accessibilityLabel(String(localized: "Per-email analysis index (3.0)"))
                }
                if modules.isOn(.v3Fingerprints) {
                    LabeledContent(String(localized: "Archive fingerprint")) {
                        Text(fingerprintRoot.map { String($0.prefix(16)) + "…" } ?? String(localized: "Not built yet"))
                            .font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                if modules.isOn(.v3LegalState), let legalCounts {
                    LabeledContent(String(localized: "Legal data in the database"),
                                   value: String(localized: "\(legalCounts.holds) holds, \(legalCounts.seals) seals, \(legalCounts.custodians) custodian assignments"))
                }
            }

            Section("3.0 engines") {
                let running = Capability.v3Engines.filter { modules.isOn($0) }
                LabeledContent(String(localized: "Switched on"), value: "\(running.count) of \(Capability.v3Engines.count)")
                let trips = EngineGuard.loadTrips()
                LabeledContent(String(localized: "Switched off after an unexpected stop"), value: "\(trips.count)")
                ForEach(trips.suffix(5).reversed()) { trip in
                    Text("\(trip.date.formatted(date: .abbreviated, time: .shortened)) — \(Capability(rawValue: trip.capability)?.displayName ?? trip.capability)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent(String(localized: "Calls that fell back to the previous engine"),
                               value: "\(EngineGuard.loadFallbacks().count)")
                if SafeMode.shared.isActive {
                    Label(String(localized: "This launch is in Safe Mode: the archive is read-only and background work is paused."), systemImage: "lifepreserver")
                        .foregroundStyle(.orange)
                }
            }

            if modules.isOn(.v3AIAnswers), ModelVersionWatch.needsRecheck {
                Section("AI") {
                    Label {
                        Text("The system or its on-device model changed since the AI answer checks last passed (\(ModelVersionWatch.checkedBuild ?? String(localized: "never recorded"))). Re-run the AI answer checks on \(ModelVersionWatch.currentBuild).")
                            .font(.caption)
                    } icon: { Image(systemName: "sparkles") }
                }
            }

            Section("Diagnostics (kept on this device)") {
                let d = DiagnosticsCenter.shared.summary()
                LabeledContent(String(localized: "Crash reports"), value: "\(d.crashes)")
                LabeledContent(String(localized: "Hang reports"), value: "\(d.hangs)")
                LabeledContent(String(localized: "Disk-write reports"), value: "\(d.diskWrites)")
                Button(String(localized: "Copy diagnostics")) {
                    PlatformClipboard.copyString(EngineTripCenter.shared.diagnosticsText()
                        + "\n\n" + DiagnosticsCenter.shared.latestReportsText())
                    note = String(localized: "Diagnostics copied. Nothing was sent anywhere.")
                }
            }

            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { reload(); await loadCoverage(); await loadSources() }
    }

    /// LIFE-01: which originals are missing, and how much the archive's own copies hold.
    private func loadSources() async {
        let store = SQLiteEmailStore.shared
        missingSources = (try? await store.missingLocatorSources()) ?? []
        sourceCopyBytes = SourceCopies.totalBytes(storeDirectory: store.storeDirectory)
    }

    private var integrityText: String {
        guard let integrity else {
            if let last = UserDefaults.standard.string(forKey: Self.lastIntegrityKey) {
                let date = Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: Self.lastIntegrityDateKey))
                return "\(last == "ok" ? String(localized: "OK") : last) — \(date.formatted(date: .abbreviated, time: .shortened))"
            }
            return String(localized: "Not checked yet")
        }
        return integrity == "ok" ? String(localized: "OK") : integrity
    }

    private func reload() {
        snapshots = ArchiveSnapshots.all()
        snapshotFolder = SnapshotLocation.chosen
        freeBytes = (try? SQLiteEmailStore.shared.snapshotDirectory.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    private func loadCoverage() async {
        let store = SQLiteEmailStore.shared
        coverage = (try? await store.derivedAnalysisCoverage()) ?? (0, 0)
        featureCoverage = (try? await store.featureCoverage(version: FeatureExtractor.version)) ?? (0, 0)
        fingerprintRoot = FingerprintJob.shared.root
        if fingerprintRoot == nil, let tree = try? await store.fingerprintTree(), tree.leaves > 0 { fingerprintRoot = tree.root }
        legalCounts = try? await store.legalStateCounts()
    }

    private func runCheck() async {
        checking = true
        defer { checking = false }
        do {
            let result = try await SQLiteEmailStore.shared.integrityCheck()
            integrity = result
            UserDefaults.standard.set(result, forKey: Self.lastIntegrityKey)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastIntegrityDateKey)
            ForensicManager.shared.logAction("Archive integrity check", detail: result)
        } catch {
            integrity = error.localizedDescription
        }
    }
}
