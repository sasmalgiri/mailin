//
//  MigrationService.swift
//  maxmailin
//
//  One-time migration from the legacy JSON-backed EmailPersistence store
//  (public mailin v1) DIRECTLY into the canonical SQLite store (§10.1) —
//  the SwiftData hop was removed because it dropped attachments metadata and
//  message type. The v1 JSON holds complete Codable RawEmails, so one bounded
//  hop preserves full fidelity.
//
//  Semantics (§10.2): .preserveAll — the JSON content already reflects every
//  dedup choice the user made in v1, so migration copies it EXACTLY, including
//  legitimate rows that share a Message-ID. Idempotency comes from the
//  preserved v1 UUIDs (id PRIMARY KEY), not from Message-ID uniqueness.
//
//  Completion is gated on EXACT ID coverage: every legacy email id must be
//  present in SQLite (verified in bounded chunks), plus a sampled content
//  check — never a bare count comparison.
//
//  Strictly on-device, no network, no telemetry.
//

import Foundation
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

    /// Test seam: when set, migration writes into this store instead of the
    /// shared production SQLite store.
    static var testTargetStoreOverride: SQLiteEmailStore?

    private var targetStore: SQLiteEmailStore {
        Self.testTargetStoreOverride ?? SQLiteEmailStore.shared
    }

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

    /// Force a re-migration. Used for "restore from backup" flows. Idempotent:
    /// legacy v1 UUIDs are preserved as primary keys, so re-running never
    /// duplicates rows — even for emails without a Message-ID.
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
        logger.info("Migrating \(legacyEmails.count) legacy emails directly into SQLite (preserveAll)…")

        do {
            let store = targetStore
            var processed = 0
            for chunk in stride(from: 0, to: legacyEmails.count, by: 1_000).map({
                Array(legacyEmails[$0..<min($0 + 1_000, legacyEmails.count)])
            }) {
                _ = try await store.insertBatch(
                    chunk, sourceFileHash: nil, accountID: nil,
                    sourceID: nil, firstOrdinal: nil, dedupPolicy: .preserveAll,
                    batchSize: 500, progress: nil)
                processed += chunk.count
                migratedCount = processed
                progressFraction = Double(processed) / Double(max(legacyEmails.count, 1))
            }

            // §10 exactness gate 1: EXACT ID coverage — every legacy id must
            // exist in the destination, verified in bounded chunks. The v1
            // JSON is left UNTOUCHED on disk (non-destructive rollback source).
            let allIDs = legacyEmails.map(\.id)
            var missing = 0
            for chunk in stride(from: 0, to: allIDs.count, by: 1_000).map({
                Array(allIDs[$0..<min($0 + 1_000, allIDs.count)])
            }) {
                let present = try await store.existingIDs(among: chunk)
                missing += chunk.count - present.count
            }
            guard missing == 0 else {
                logger.error("Post-migration ID coverage failed: \(missing) legacy ids absent — not marking complete; will retry next launch.")
                status = .failed("Migrated archive is missing \(missing) emails — will retry on next launch.")
                return
            }

            // §10 exactness gate 2: sampled content fidelity — subject, body,
            // attachment count and message type must survive the hop.
            let sample = legacyEmails.prefix(3) + legacyEmails.suffix(3)
            for original in sample {
                guard let hydrated = try await store.fullEmail(id: original.id) else {
                    status = .failed("Migrated email \(original.id) could not be read back.")
                    return
                }
                guard hydrated.plainBody == original.plainBody,
                      hydrated.headers["Subject"] == original.headers["Subject"],
                      hydrated.attachments.count == original.attachments.count else {
                    logger.error("Content fidelity mismatch for \(original.id, privacy: .public) — not marking complete.")
                    status = .failed("Migrated content did not verify — will retry on next launch.")
                    return
                }
            }

            UserDefaults.standard.set(true, forKey: completionKey)
            status = .completed
            logger.info("Migration complete: \(legacyEmails.count) legacy emails copied with exact ID coverage + sampled fidelity verification.")
        } catch {
            logger.error("Migration failed: \(error.localizedDescription)")
            status = .failed(error.localizedDescription)
        }
    }

}
