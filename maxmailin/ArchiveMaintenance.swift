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
import SwiftUI
import SQLite3

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

    /// What the person is asked before a snapshot replaces the live
    /// database (rule 4: the count first).
    struct RestoreRequest: Identifiable, Equatable {
        let id = UUID()
        let snapshot: ArchiveSnapshot
        /// Messages in the snapshot; nil when the file could not be read.
        let messages: Int?
        var title: String { ArchiveSnapshots.confirmationTitle(date: snapshot.date, messages: messages) }
        var message: String { ArchiveSnapshots.confirmationExplanation }
    }

    /// Review C4: the question, with the snapshot's message count and date.
    nonisolated static func confirmationTitle(date: Date, messages: Int?) -> String {
        let when = date.formatted(date: .abbreviated, time: .shortened)
        guard let messages else { return String(localized: "Restore the archive from the snapshot of \(when)?") }
        return String(localized: "Restore the archive from the snapshot of \(when) (\(CountPhrase.messages(messages)))?")
    }

    nonisolated static var confirmationExplanation: String {
        String(localized: "The current archive database is kept as a separate snapshot first, so this can be undone. Emails imported after the snapshot will need to be imported again, and the search index should be rebuilt afterwards.")
    }

    /// Messages in a snapshot file, read without changing it (immutable,
    /// read-only — no journal files are created beside the snapshot).
    nonisolated static func messageCount(in url: URL) -> Int? {
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        comps?.scheme = "file"
        comps?.queryItems = [URLQueryItem(name: "immutable", value: "1"), URLQueryItem(name: "mode", value: "ro")]
        guard let uri = comps?.string else { return nil }
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { return nil }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM emails;", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// User-initiated restore of the newest snapshot, after confirmation.
    /// Returns a one-line status for the screen that asked.
    ///
    /// Review C4: confirmation is required on every platform — `confirm`
    /// shows the snapshot's date and message count and returns false on
    /// Cancel (the default button). It used to confirm only on the Mac, so
    /// one tap on iPhone/iPad replaced the live database.
    static func restoreLatestInteractively(
        confirm: @MainActor (RestoreRequest) async -> Bool,
        snapshot: ArchiveSnapshot? = nil,
        perform: ((URL) async throws -> Void)? = nil
    ) async -> String {
        if let why = OrgPolicy.denial(.restoreSnapshot) { return why }   // enterprise role (OrgPolicy)
        guard let snap = snapshot ?? latest() else { return String(localized: "There is no snapshot to restore.") }
        let request = RestoreRequest(snapshot: snap, messages: messageCount(in: snap.url))
        guard await confirm(request) else { return String(localized: "Restore cancelled.") }
        do {
            if let perform {
                try await perform(snap.url)
            } else {
                try await SQLiteEmailStore.shared.restore(from: snap.url)
            }
            ScopeJobEnvironment.logAction("Archive restored from snapshot",
                                          detail: "\(snap.url.lastPathComponent) (\(request.messages.map(String.init) ?? "unknown") messages); the previous database was kept as a before-restore snapshot")
            return String(localized: "Restored from the snapshot of \(snap.date.formatted(date: .abbreviated, time: .shortened)). Rebuild the search index next.")
        } catch {
            return error.localizedDescription
        }
    }
}

/// Review C4: asks the restore question in SwiftUI on every platform and
/// waits for the answer. Cancel is the default; dismissing is Cancel.
@MainActor
@Observable
final class SnapshotRestoreAsker {
    var pending: ArchiveSnapshots.RestoreRequest?
    private var continuation: CheckedContinuation<Bool, Never>?
    /// Which question is open, so a deferred dismissal never answers a later one.
    private var question = 0

    func ask(_ request: ArchiveSnapshots.RestoreRequest) async -> Bool {
        answer(false)   // a question still open is cancelled, never left hanging
        question += 1
        return await withCheckedContinuation { c in
            continuation = c
            pending = request
        }
    }

    /// The Restore / Cancel button's answer. One-shot: the first answer to a
    /// question wins and any later call is ignored.
    func answer(_ restore: Bool) {
        pending = nil
        guard let c = continuation else { return }
        continuation = nil
        c.resume(returning: restore)
    }

    /// The alert closed (its binding went false). SwiftUI does not promise
    /// whether that comes before or after the tapped button's action, so the
    /// "cancel" for a dismissal with no button is deferred to the next
    /// main-actor turn — a Restore action arriving after the binding still wins.
    func alertDismissed() {
        pending = nil
        guard continuation != nil else { return }
        let open = question
        Task { @MainActor [weak self] in
            guard let self, self.question == open else { return }
            self.answer(false)
        }
    }

    /// The alert's `isPresented` binding.
    var isPresentedBinding: Binding<Bool> {
        Binding(get: { self.pending != nil }, set: { if !$0 { self.alertDismissed() } })
    }
}

extension View {
    /// The restore question for `asker` (Restore is destructive; Cancel is the default).
    func snapshotRestoreConfirmation(_ asker: SnapshotRestoreAsker) -> some View {
        alert(asker.pending?.title ?? "",
              isPresented: asker.isPresentedBinding,
              presenting: asker.pending) { _ in
            Button(String(localized: "Restore"), role: .destructive) { asker.answer(true) }
            Button(String(localized: "Cancel"), role: .cancel) { asker.answer(false) }
        } message: { request in
            Text(request.message)
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
