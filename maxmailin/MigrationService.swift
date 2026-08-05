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

        // Read the REAL v1 store. EmailPersistence.load() already resolves the
        // correct path (…/mailin/saved_emails.json[.lz]) and decompresses LZFSE.
        let (legacyEmails, _) = EmailPersistence.load()

        guard !legacyEmails.isEmpty else {
            // Distinguish "no v1 data" (safe to mark complete) from "v1 data is
            // present but could not be read" (must NOT mark complete — otherwise
            // a transient/corrupt read silently orphans the user's archive).
            if EmailPersistence.legacyStoreExists {
                logger.error("Legacy v1 store exists but yielded 0 emails — not marking complete; will retry next launch.")
                status = .failed("Could not read your previous data. Will retry on next launch.")
                return
            }
            logger.info("No legacy archive found; nothing to migrate.")
            UserDefaults.standard.set(true, forKey: completionKey)
            status = .completed
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
            // Verify the write actually landed before marking complete. The v1
            // store is left UNTOUCHED on disk (non-destructive); the completion
            // flag is the sole idempotency guard.
            // Meaningful count-verification: EmailStore dedupes by Message-ID,
            // so the expected post-migration count is (distinct Message-IDs) +
            // (emails that have no Message-ID, which are never deduped). Compare
            // against that, NOT against legacyEmails.count — a Gmail export with
            // the same message under multiple labels legitimately lands fewer
            // rows, and comparing to the raw count would fail forever.
            let distinctMIDs = Set(legacyEmails.compactMap { m -> String? in
                let mid = m.headers["Message-ID"] ?? ""
                return mid.isEmpty ? nil : mid
            }).count
            let noMIDCount = legacyEmails.filter { ($0.headers["Message-ID"] ?? "").isEmpty }.count
            let expected = distinctMIDs + noMIDCount
            let stored = try await EmailStore.shared.count()
            guard stored >= expected else {
                logger.error("Post-migration count \(stored) < expected \(expected) — not marking complete; will retry next launch.")
                status = .failed("Migrated \(stored) of \(expected) emails — will retry on next launch.")
                return
            }
            UserDefaults.standard.set(true, forKey: completionKey)
            status = .completed
            logger.info("Migration complete: \(legacyEmails.count) legacy emails; expected \(expected) after dedup; store now holds \(stored).")
        } catch {
            logger.error("Migration failed: \(error.localizedDescription)")
            status = .failed(error.localizedDescription)
        }
    }

}
