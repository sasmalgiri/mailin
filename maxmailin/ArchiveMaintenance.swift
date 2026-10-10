@testable import ArchiveCore
//
//  ArchiveMaintenance.swift
//  maxmailin
//
//  App-side archive maintenance for 3.0 (SCALE_TODO_3_0.md §3-S1, §3-S6):
//  scheduled snapshots, restore, and a streamed search-index rebuild.
//  Everything here is user-initiated or switch-gated (`v3Snapshots`), and
//  nothing destroys data: a restore first saves the current database.
//

import Foundation
#if os(macOS)
import AppKit
#endif

@MainActor
enum ArchiveSnapshots {
    private static let lastScheduledKey = "archiveSnapshots.lastScheduled"
    static let scheduleInterval: TimeInterval = 24 * 60 * 60

    static func all() -> [ArchiveSnapshot] { SQLiteEmailStore.shared.snapshots() }
    static func latest() -> ArchiveSnapshot? { all().first }

    /// Takes the daily rolling snapshot if the switch is on, the app is not in
    /// Safe Mode and the last one is older than a day. Runs after launch has
    /// settled so it never competes with startup.
    static func scheduleIfDue() {
        guard ArchiveSnapshotPolicy.isEnabled, SafeMode.shared.allowsBackgroundWork else { return }
        let last = UserDefaults.standard.double(forKey: lastScheduledKey)
        guard Date().timeIntervalSince1970 - last > scheduleInterval else { return }
        Task.detached(priority: .background) {
            try? await Task.sleep(for: .seconds(60))
            do {
                let snap = try await SQLiteEmailStore.shared.snapshot(reason: "scheduled")
                await MainActor.run {
                    UserDefaults.standard.set(snap.date.timeIntervalSince1970, forKey: lastScheduledKey)
                }
            } catch {
                await MainActor.run {
                    ForensicManager.shared.logAction("Scheduled archive snapshot skipped", detail: error.localizedDescription)
                }
            }
        }
    }

    /// User-initiated restore of the newest snapshot, after confirmation.
    /// Returns a one-line status for the screen that asked.
    static func restoreLatestInteractively() async -> String {
        guard let snap = latest() else { return String(localized: "There is no snapshot to restore.") }
        #if os(macOS)
        let alert = NSAlert()
        alert.messageText = String(localized: "Restore the archive from the snapshot of \(snap.date.formatted(date: .abbreviated, time: .shortened))?")
        alert.informativeText = String(localized: "The current archive database is kept as a separate snapshot first, so this can be undone. Emails imported after the snapshot will need to be imported again, and the search index should be rebuilt afterwards.")
        alert.addButton(withTitle: String(localized: "Restore"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return String(localized: "Restore cancelled.") }
        #endif
        do {
            try await SQLiteEmailStore.shared.restore(from: snap.url)
            ForensicManager.shared.logAction("Archive restored from snapshot",
                                             detail: "\(snap.url.lastPathComponent); the previous database was kept as a before-restore snapshot")
            return String(localized: "Restored from the snapshot of \(snap.date.formatted(date: .abbreviated, time: .shortened)). Rebuild the search index next.")
        } catch {
            return error.localizedDescription
        }
    }
}

extension ArchiveDataService {
    /// Rebuilds the full-text index from the stored emails, batch by batch —
    /// memory stays flat at any archive size (the old `rebuild(from:)` took
    /// every email at once). The archive itself is not modified.
    func rebuildSearchIndex(batchSize: Int = 200) async throws {
        try await FTSSearchIndex.shared.clear()
        for try await batch in streamFullEmails(query: .all, batchSize: batchSize) {
            try Task.checkCancellation()
            try await FTSSearchIndex.shared.indexBatch(batch)
        }
    }
}
