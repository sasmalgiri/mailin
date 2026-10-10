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

struct ArchiveHealthView: View {
    @Environment(ModuleRegistry.self) private var modules
    @State private var integrity: String?
    @State private var checking = false
    @State private var snapshots: [ArchiveSnapshot] = []
    @State private var coverage: (analyzed: Int, total: Int) = (0, 0)
    @State private var freeBytes: Int64?
    @State private var note: String?
    @State private var working = false

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
            }

            Section("Analysis index") {
                let pct = coverage.total > 0 ? Double(coverage.analyzed) / Double(coverage.total) : 0
                LabeledContent(String(localized: "Emails analysed"),
                               value: "\(coverage.analyzed.formatted()) of \(coverage.total.formatted())")
                ProgressView(value: pct)
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
                    Label(String(localized: "This launch is in Safe Mode."), systemImage: "lifepreserver")
                        .foregroundStyle(.orange)
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
        freeBytes = (try? SQLiteEmailStore.shared.snapshotDirectory.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    private func loadCoverage() async {
        coverage = (try? await SQLiteEmailStore.shared.derivedAnalysisCoverage()) ?? (0, 0)
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
