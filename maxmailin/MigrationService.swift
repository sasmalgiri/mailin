//
//  MigrationService.swift
//  maxmailin
//
//  One-time migration from the legacy JSON-backed EmailPersistence store
//  (inherited from mailin) into the new SwiftData-backed EmailStore.
//
//  Migration is idempotent: safe to call multiple times. Tracks completion
//  via a UserDefaults flag so it only runs once per archive version.
//
//  Strictly on-device, no network, no telemetry.
//

import Foundation
import SwiftData
import os.log

@MainActor
final class MigrationService: ObservableObject {

    static let shared = MigrationService()

    private let logger = Logger(subsystem: "com.ecosanskriti.mailin",
                                category: "Migration")
    private let completionKey = "maxmailin.legacyJSONMigrationCompletedV1"

    @Published private(set) var status: Status = .idle
    @Published private(set) var progressFraction: Double = 0
    @Published private(set) var migratedCount: Int = 0
    @Published private(set) var totalCount: Int = 0

    enum Status: Equatable {
        case idle
        case checking
        case migrating
        case completed
        case skipped
        case failed(String)
    }

    private init() {}

    // MARK: - Public API

    /// Returns true if the legacy JSON migration has already been performed.
    var hasMigrated: Bool {
        UserDefaults.standard.bool(forKey: completionKey)
    }

    /// Runs the migration if it hasn't been done. Safe to call on every app
    /// launch — returns immediately if already complete.
    func migrateIfNeeded() async {
        guard !hasMigrated else {
            status = .skipped
            return
        }
        await performMigration()
    }

    /// Force a re-migration. Used for "restore from backup" flows. Caller
    /// should warn the user since this will append duplicates if the SwiftData
    /// store already has matching emails (idempotency is messageID-based, so
    /// emails without a Message-ID header will duplicate).
    func forceMigrate() async {
        UserDefaults.standard.set(false, forKey: completionKey)
        await performMigration()
    }

    // MARK: - Migration logic

    private func performMigration() async {
        status = .checking
        progressFraction = 0
        migratedCount = 0
        totalCount = 0

        let legacyEmails: [MBOXParser.RawEmail]
        do {
            legacyEmails = try loadLegacyArchive()
        } catch {
            logger.info("No legacy archive found or unreadable: \(error.localizedDescription)")
            status = .completed
            UserDefaults.standard.set(true, forKey: completionKey)
            return
        }

        guard !legacyEmails.isEmpty else {
            logger.info("Legacy archive is empty; nothing to migrate.")
            status = .completed
            UserDefaults.standard.set(true, forKey: completionKey)
            return
        }

        totalCount = legacyEmails.count
        status = .migrating
        logger.info("Migrating \(legacyEmails.count) legacy emails into SwiftData…")

        do {
            try await EmailStore.shared.insertBatch(legacyEmails) { processed, total in
                Task { @MainActor in
                    self.migratedCount = processed
                    self.totalCount = total
                    self.progressFraction = Double(processed) / Double(max(total, 1))
                }
            }
            try archiveLegacyAsBackup()
            UserDefaults.standard.set(true, forKey: completionKey)
            status = .completed
            logger.info("Migration complete: \(legacyEmails.count) emails imported.")
        } catch {
            logger.error("Migration failed: \(error.localizedDescription)")
            status = .failed(error.localizedDescription)
        }
    }

    // MARK: - Legacy JSON archive I/O

    /// Read the legacy `EmailPersistence` JSON archive, if present.
    private func loadLegacyArchive() throws -> [MBOXParser.RawEmail] {
        let url = try legacyArchiveURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MigrationError.notFound
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        if let direct = try? decoder.decode([MBOXParser.RawEmail].self, from: data) {
            return direct
        }
        // Some EmailPersistence variants wrap the array in a top-level dict.
        if let envelope = try? decoder.decode(LegacyEnvelope.self, from: data) {
            return envelope.emails
        }
        throw MigrationError.unrecognizedFormat
    }

    /// Rename the legacy JSON to `.backup` so we don't accidentally migrate
    /// the same data twice if the user clears UserDefaults.
    private func archiveLegacyAsBackup() throws {
        let url = try legacyArchiveURL()
        let backup = url.appendingPathExtension("backup")
        if FileManager.default.fileExists(atPath: backup.path) {
            try? FileManager.default.removeItem(at: backup)
        }
        try FileManager.default.moveItem(at: url, to: backup)
        logger.info("Archived legacy JSON to \(backup.lastPathComponent)")
    }

    private func legacyArchiveURL() throws -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = appSupport.appendingPathComponent("com.ecosanskriti.mailin", isDirectory: true)
        return dir.appendingPathComponent("email_archive.json")
    }

    // MARK: - Supporting types

    private struct LegacyEnvelope: Codable {
        let emails: [MBOXParser.RawEmail]
    }

    enum MigrationError: LocalizedError {
        case notFound
        case unrecognizedFormat

        var errorDescription: String? {
            switch self {
            case .notFound:
                return "No legacy archive was found to migrate."
            case .unrecognizedFormat:
                return "Legacy archive format is not recognized."
            }
        }
    }
}
