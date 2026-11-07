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

    /// Asks for a destination folder and writes `mailin-backup-<date>` inside it.
    static func backUpInteractively() async -> String {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = String(localized: "Choose where to save the backup. A new folder named mailin-backup-<date> is created there.")
        panel.prompt = String(localized: "Back Up Here")
        guard panel.runModal() == .OK, let parent = panel.url else { return String(localized: "Backup cancelled.") }
        #else
        let parent = FileManager.default.temporaryDirectory
        #endif
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let destination = parent.appendingPathComponent("mailin-backup-\(formatter.string(from: Date()))", isDirectory: true)
        do {
            let inventory = try await ArchiveBackup.create(store: SQLiteEmailStore.shared, to: destination,
                                                           receiptDirectories: receiptDirectories)
            ForensicManager.shared.logAction("Archive backed up",
                                             detail: "\(destination.lastPathComponent): \(inventory.files.count) files, \(inventory.counts.emails) emails")
            let size = ByteCountFormatter.string(fromByteCount: inventory.totalBytes, countStyle: .file)
            var line = String(localized: "Backed up \(inventory.counts.emails) emails, \(inventory.files.count) files (\(size)) to \(destination.lastPathComponent). Every file is listed with its SHA-256 in the inventory.")
            if !inventory.linkedSources.isEmpty {
                line += " " + String(localized: "\(inventory.linkedSources.count) original files are still read from outside the archive (linked mode); they are listed in the inventory, not copied.")
            }
            return line
        } catch {
            return error.localizedDescription
        }
    }

    /// Asks for a backup folder, verifies it fully, confirms, then restores
    /// into the running archive.
    static func restoreInteractively() async -> String {
        if let why = OrgPolicy.denial(.restoreSnapshot) { return why }
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = String(localized: "Choose a mailin backup folder (it contains mailin-backup-inventory.json).")
        panel.prompt = String(localized: "Verify and Restore")
        guard panel.runModal() == .OK, let backup = panel.url else { return String(localized: "Restore cancelled.") }
        return await restore(from: backup)
        #else
        return String(localized: "Restoring from a backup folder is done on the Mac.")
        #endif
    }

    /// Verifies `backup` fully, confirms (Mac), then restores into the running archive.
    /// Split out of `restoreInteractively` so iOS, which has no folder picker here, compiles.
    private static func restore(from backup: URL) async -> String {
        let verification: ArchiveBackup.Verification
        do { verification = try ArchiveBackup.verify(backup: backup) } catch { return error.localizedDescription }
        guard verification.isClean else {
            return String(localized: "The backup did not verify: \(verification.problems.prefix(3).joined(separator: "; ")). Nothing was changed.")
        }
        #if os(macOS)
        let alert = NSAlert()
        let counts = verification.inventory.counts
        alert.messageText = String(localized: "Restore the archive from this backup (\(counts.emails) emails, \(verification.inventory.files.count) files, made \(verification.inventory.createdAt.formatted(date: .abbreviated, time: .shortened)))?")
        alert.informativeText = String(localized: "The current database is kept as a before-restore snapshot first. The database and attachment-text states are replaced by the backup's; message files the backup has and the archive lacks are added; nothing already here is deleted. Rebuild the search index afterwards.")
        alert.addButton(withTitle: String(localized: "Restore"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return String(localized: "Restore cancelled.") }
        #endif
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
            ForensicManager.shared.logAction("Archive restored from backup",
                                             detail: "\(backup.lastPathComponent); the previous database was kept as a before-restore snapshot; \(relocated) locator paths moved to the restored copies")
            return String(localized: "Restored \(inventory.counts.emails) emails from \(backup.lastPathComponent). Rebuild the search index next.")
        } catch {
            return error.localizedDescription
        }
    }
}
