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

/// §3-S9: folds the write-ahead log into the archive while nothing is
/// running — no import in the queue, no whole-archive job — every two
/// minutes, with the hygiene switch on. Passive: it never waits for or
/// blocks anyone.
@MainActor
enum IdleCheckpoint {
    private static var task: Task<Void, Never>?

    static func start() {
        guard task == nil else { return }
        task = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(120))
                guard SQLiteHygiene.isEnabled, SafeMode.shared.allowsBackgroundWork,
                      !ImportQueue.shared.isActive, ScopeJobCenter.shared.running.isEmpty,
                      !ExportRunCenter.shared.isActive else { continue }
                try? await SQLiteEmailStore.shared.checkpointPassive()
            }
        }
    }
}

/// §3-S1 external location: the folder the user chose for snapshots, kept
/// as a security-scoped bookmark so access survives relaunch. When the
/// folder is not reachable (disk detached) snapshots go beside the store.
@MainActor
enum SnapshotLocation {
    private static let bookmarkKey = "archiveSnapshots.externalBookmark"
    private static var accessed: URL?

    /// The chosen folder, reachable or not; nil = beside the archive.
    static var chosen: URL? { ArchiveSnapshotPolicy.externalDirectory }

    /// Resolves the saved bookmark at launch.
    static func restoreAtLaunch() {
        guard accessed == nil, let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: resolveOptions, relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return }
        activate(url)
        if stale, let fresh = try? url.bookmarkData(options: creationOptions, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
        }
    }

    /// Uses `url` for snapshots after checking it. Returns the line to show.
    static func choose(_ url: URL) -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        let verdict = ArchiveSnapshotPolicy.verdict(for: url)
        guard verdict.isUsable else {
            if scoped { url.stopAccessingSecurityScopedResource() }
            return verdict.message ?? String(localized: "That folder cannot hold snapshots.")
        }
        guard let data = try? url.bookmarkData(options: creationOptions, includingResourceValuesForKeys: nil, relativeTo: nil) else {
            if scoped { url.stopAccessingSecurityScopedResource() }
            return String(localized: "mailin could not keep access to that folder. Choose it again.")
        }
        if scoped { url.stopAccessingSecurityScopedResource() }
        UserDefaults.standard.set(data, forKey: bookmarkKey)
        activate(url)
        ForensicManager.shared.logAction("Snapshot folder chosen", detail: url.path)
        let line = String(localized: "Snapshots will be saved in “\(url.lastPathComponent)”.")
        return verdict.message.map { line + " " + $0 } ?? line
    }

    /// Back to beside the archive. Snapshots already in the folder stay there.
    static func clear() {
        accessed?.stopAccessingSecurityScopedResource()
        accessed = nil
        ArchiveSnapshotPolicy.externalDirectory = nil
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        ForensicManager.shared.logAction("Snapshot folder reset", detail: "snapshots are saved beside the archive")
    }

    private static func activate(_ url: URL) {
        accessed?.stopAccessingSecurityScopedResource()
        accessed = url.startAccessingSecurityScopedResource() ? url : nil
        ArchiveSnapshotPolicy.externalDirectory = url
    }

    #if os(macOS)
    private static let creationOptions: URL.BookmarkCreationOptions = .withSecurityScope
    private static let resolveOptions: URL.BookmarkResolutionOptions = .withSecurityScope
    #else
    private static let creationOptions: URL.BookmarkCreationOptions = []
    private static let resolveOptions: URL.BookmarkResolutionOptions = []
    #endif
}

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
