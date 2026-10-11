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
        .task { reload(); await loadCoverage() }
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
