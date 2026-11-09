//
//  ArchiveBackups.swift
//  maxmailin
//
//  LIFE-02: the user-facing side of `ArchiveBackup` — choose a folder, back
//  the archive up with its receipts, or restore from a backup folder. A
//  restore into the running archive snapshots the current database first
//  (rule 1: nothing is destroyed), verifies every file of the backup, swaps
//  the database and sidecars, adds missing blob and source files, and never
//  deletes anything that was already there.
//
//  IPAD-06 (owner 2026-11-08): on iPad the backup goes to a folder the person
//  chooses in Files (security-scoped), never the app's temporary folder, and a
//  restore runs from a chosen backup folder with the same verify-then-confirm
//  flow as the Mac. The Health screen hosts the iOS pickers and confirmation.
//

@testable import ArchiveCore
import Foundation
#if os(macOS)
import AppKit
#endif

@MainActor
enum ArchiveBackups {
    static var receiptDirectories: [(name: String, url: URL)] {
        [("import", ImportReceiptStore.production.directory), ("export", ExportReceiptStore.production.directory)]
    }

    /// The folder a backup is written into: `mailin-backup-<date>` inside the
    /// folder the person chose. IPAD-06: never the app's temporary folder.
    nonisolated static func backupDestination(parent: URL, date: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return parent.appendingPathComponent("mailin-backup-\(formatter.string(from: date))", isDirectory: true)
    }

    /// Asks for a destination folder and writes `mailin-backup-<date>` inside it (macOS).
    /// iOS: the Health screen asks with a Files folder picker and calls
    /// `backUp(intoChosenFolder:)`.
    static func backUpInteractively() async -> String {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = String(localized: "Choose where to save the backup. A new folder named mailin-backup-<date> is created there.")
        panel.prompt = String(localized: "Back Up Here")
        guard panel.runModal() == .OK, let parent = panel.url else {
            RecipeJobBroker.shared.report(.backup, outcome: .cancelled, receipt: .init(kind: .none, id: ""), summary: "Backup cancelled")
            return String(localized: "Backup cancelled.")
        }
        return await backUp(intoChosenFolder: parent)
        #else
        return String(localized: "Choose a folder in Files for the backup.")
        #endif
    }

    /// Writes the backup into `parent` — a folder the person chose (on iOS a
    /// security-scoped Files location) — and reports what really happened.
    /// The audit entry is written only after the backup exists (rule 5).
    static func backUp(intoChosenFolder parent: URL) async -> String {
        let access = parent.startAccessingSecurityScopedResource()
        defer { if access { parent.stopAccessingSecurityScopedResource() } }
        let destination = backupDestination(parent: parent)
        do {
            let inventory = try await ArchiveBackup.create(store: SQLiteEmailStore.shared, to: destination,
                                                           receiptDirectories: receiptDirectories)
            ForensicManager.shared.logAction("Archive backed up",
                                             detail: "\(destination.lastPathComponent): \(inventory.files.count) files, \(inventory.counts.emails) emails")
            // v4.0 REC-02: verified now, while the chosen folder is still reachable.
            RecipeJobBroker.shared.reportInventory(.backup, folder: destination)
            let size = ByteCountFormatter.string(fromByteCount: inventory.totalBytes, countStyle: .file)
            var line = String(localized: "Backed up \(CountPhrase.emails(inventory.counts.emails)), \(CountPhrase.files(inventory.files.count)) (\(size)) to \(destination.lastPathComponent). Every file is listed with its SHA-256 in the inventory.")
            #if os(iOS)
            line += " " + String(localized: "Saved in the folder \(parent.lastPathComponent) in Files.")
            #endif
            if !inventory.linkedSources.isEmpty {
                line += " " + String(localized: "\(inventory.linkedSources.count) original files are still read from outside the archive (linked mode); they are listed in the inventory, not copied.")
            }
            return line
        } catch {
            RecipeJobBroker.shared.report(.backup, outcome: .failed, receipt: .init(kind: .none, id: ""),
                                          summary: "Backup failed: \(error.localizedDescription)")
            return String(localized: "Backup failed: \(error.localizedDescription)")
        }
    }

    /// Asks for a backup folder, verifies it fully, confirms, then restores
    /// into the running archive (macOS). iOS: the Health screen asks with a
    /// Files folder picker, calls `verifyForRestore`, confirms with
    /// `restoreConfirmation`, then `restoreVerified`.
    static func restoreInteractively() async -> String {
        if let why = OrgPolicy.denial(.restoreSnapshot) { return why }
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = String(localized: "Choose a mailin backup folder (it contains mailin-backup-inventory.json).")
        panel.prompt = String(localized: "Verify and Restore")
        guard panel.runModal() == .OK, let backup = panel.url else {
            RecipeJobBroker.shared.report(.restore, outcome: .cancelled, receipt: .init(kind: .none, id: ""), summary: "Restore cancelled")
            return String(localized: "Restore cancelled.")
        }
        return await restore(from: backup)
        #else
        return String(localized: "Choose a mailin backup folder in Files.")
        #endif
    }

    /// A backup folder that verified clean, waiting for the person's confirmation.
    struct VerifiedBackup: Identifiable {
        let id = UUID()
        let folder: URL
        let emails: Int
        let files: Int
        let createdAt: Date
    }

    struct RestoreRefusal: Error, Equatable { let message: String }

    /// Step 1 of a restore (both platforms): verify every file of `backup`
    /// against its inventory. Nothing is changed.
    static func verifyForRestore(_ backup: URL) -> Result<VerifiedBackup, RestoreRefusal> {
        if let why = OrgPolicy.denial(.restoreSnapshot) { return .failure(RestoreRefusal(message: why)) }
        let access = backup.startAccessingSecurityScopedResource()
        defer { if access { backup.stopAccessingSecurityScopedResource() } }
        let verification: ArchiveBackup.Verification
        do { verification = try ArchiveBackup.verify(backup: backup) } catch {
            return .failure(RestoreRefusal(message: error.localizedDescription))
        }
        guard verification.isClean else {
            return .failure(RestoreRefusal(message: String(localized: "The backup did not verify: \(verification.problems.prefix(3).joined(separator: "; ")). Nothing was changed.")))
        }
        return .success(VerifiedBackup(folder: backup, emails: verification.inventory.counts.emails,
                                       files: verification.inventory.files.count,
                                       createdAt: verification.inventory.createdAt))
    }

    /// Rule 4: the confirmation names what the restore brings back before it runs.
    nonisolated static func restoreConfirmation(emails: Int, files: Int, createdAt: Date) -> String {
        String(localized: "Restore the archive from this backup (\(CountPhrase.emails(emails)), \(CountPhrase.files(files)), made \(createdAt.formatted(date: .abbreviated, time: .shortened)))?")
    }

    nonisolated static var restoreExplanation: String {
        String(localized: "The current database is kept as a before-restore snapshot first. The database and attachment-text states are replaced by the backup's; message files the backup has and the archive lacks are added; nothing already here is deleted. Rebuild the search index afterwards.")
    }

    /// Step 2, after the person confirmed: restore a backup that verified.
    static func restoreVerified(_ backup: VerifiedBackup) async -> String {
        let access = backup.folder.startAccessingSecurityScopedResource()
        defer { if access { backup.folder.stopAccessingSecurityScopedResource() } }
        return await performRestore(from: backup.folder)
    }

    /// Verifies `backup` fully, confirms, then restores into the running archive (macOS path).
    private static func restore(from backup: URL) async -> String {
        let verified: VerifiedBackup
        switch verifyForRestore(backup) {
        case .failure(let refusal): return refusal.message
        case .success(let v): verified = v
        }
        #if os(macOS)
        let alert = NSAlert()
        alert.messageText = restoreConfirmation(emails: verified.emails, files: verified.files, createdAt: verified.createdAt)
        alert.informativeText = restoreExplanation
        alert.addButton(withTitle: String(localized: "Restore"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else {
            RecipeJobBroker.shared.report(.restore, outcome: .cancelled, receipt: .init(kind: .none, id: ""), summary: "Restore cancelled")
            return String(localized: "Restore cancelled.")
        }
        #endif
        return await performRestore(from: verified.folder)
    }

    private static func performRestore(from backup: URL) async -> String {
        do {
            let store = SQLiteEmailStore.shared
            _ = try await store.snapshot(reason: "before-restore")
            await store.reopenConnection()
            let target = store.storeDirectory
            let inventory = try ArchiveBackup.restore(backup: backup, intoStoreDirectory: target, mode: .replaceDatabaseKeepFiles,
                                                      receiptDirectories: receiptDirectories)
            _ = try await store.schemaVersion()   // reopens; runs migrations if the backup predates an upgrade
            // Self-contained copies now live under THIS store's sources/; point the locators there.
            let relocated = try await store.relocateSelfContainedLocators()
            // R07 (LIFE-06): the restored archive carries its own paid-tier record; read it now so a
            // clean installation keeps the imported mail open without waiting for the next launch.
            await StoreManager.live?.refreshArchiveAccessRecord()
            RecipeJobBroker.shared.reportInventory(.restore, folder: backup)
            ForensicManager.shared.logAction("Archive restored from backup",
                                             detail: "\(backup.lastPathComponent); the previous database was kept as a before-restore snapshot; \(relocated) locator paths moved to the restored copies")
            return String(localized: "Restored \(CountPhrase.emails(inventory.counts.emails)) from \(backup.lastPathComponent). Rebuild the search index next.")
        } catch {
            RecipeJobBroker.shared.report(.restore, outcome: .failed, receipt: .init(kind: .none, id: ""),
                                          summary: "Restore failed: \(error.localizedDescription)")
            return error.localizedDescription
        }
    }
}
