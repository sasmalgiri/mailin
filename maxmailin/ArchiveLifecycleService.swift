//
//  ArchiveLifecycleService.swift
//  maxmailin
//
//  §11: THE canonical clear/reset authority. Every user-facing "clear",
//  "start fresh" or "erase" flow routes through here so no screen clears a
//  different subset of storage.
//
//  clearArchive() removes (§11.1):
//    • canonical SQLite rows: emails, bodies, derived state, thread keys,
//      predictive records, duplicate/near-dup findings, review state,
//      user tags, annotations, participants, attachments, domains, sources
//    • FTS entries (per-row when legal holds apply, whole-index otherwise)
//    • per-email forensic hashes / evidence tags / forensic annotations
//      (they reference the deleted rows)
//    • Spotlight entries
//    • active import checkpoints (a fresh import must re-ingest)
//    • the legacy v1 JSON store AND the legacy SwiftData store — plus a
//      migration tombstone — so cleared data can NEVER re-migrate on the
//      next launch (§11.3, no data resurrection)
//
//  clearArchive() intentionally KEEPS (historical evidence):
//    • import receipts
//    • the HMAC-chained forensic audit log + source-file hash history
//      (the clear itself is recorded as an audit action)
//
//  eraseAllData() (§11.2) additionally removes receipts, the audit log,
//  source hashes, preferences, keychain material and temp files — the
//  stronger, fully destructive operation.
//

import Foundation
import os.log

@MainActor
final class ArchiveLifecycleService {

    static let shared = ArchiveLifecycleService()

    private static let logger = Logger(subsystem: "com.ecosanskriti.mailin", category: "Lifecycle")

    struct ClearOutcome: Sendable {
        var deleted = 0
        var heldKept = 0
        var warnings: [String] = []
    }

    /// §11.3 tombstone: once the user clears the archive, the SwiftData →
    /// SQLite activation migration must never re-copy old rows.
    nonisolated static let migrationTombstoneKey = "mailin.lifecycle.migrationTombstone"

    /// Test seams.
    static var testStoreOverride: SQLiteEmailStore?
    static var testFTSOverride: FTSSearchIndex?
    private var store: SQLiteEmailStore { Self.testStoreOverride ?? .shared }
    private var fts: FTSSearchIndex { Self.testFTSOverride ?? .shared }

    /// Clear the archive. Legal holds (CustodianManager) are preserved unless
    /// `respectLegalHolds` is false. Throws on storage failure — the caller
    /// must NOT pretend the archive is empty when it is not.
    @discardableResult
    func clearArchive(respectLegalHolds: Bool = true, auditTheClear: Bool = true) async throws -> ClearOutcome {
        var outcome = ClearOutcome()

        // 1. Which rows survive (bounded user-curated set).
        var held: Set<UUID> = []
        if respectLegalHolds {
            let holdIDs = Array(CustodianManager.shared.legalHolds)
            held = try await store.existingIDs(among: holdIDs)
            outcome.heldKept = held.count
        }

        let totalBefore = try await store.totalCount()

        if held.isEmpty {
            // Fast path. FTS FIRST (mirrors the repository's delete order):
            // a crash between the two leaves store rows the reconciler can
            // re-index — never ghost FTS rows over an empty store.
            try await fts.clear()
            try await store.clearAll()
            outcome.deleted = totalBefore
        } else {
            // Paged deletes; (date,id) keyset is delete-stable.
            var cursorDate: Date? = nil
            var cursorID: UUID? = nil
            while true {
                let page = try await store.reconcilePage(beforeDate: cursorDate, beforeID: cursorID, limit: 500)
                if page.isEmpty { break }
                let deletable = page.map(\.id).filter { !held.contains($0) }
                if !deletable.isEmpty {
                    for id in deletable { try await fts.delete(id: id) }
                    try await store.delete(ids: Set(deletable))
                    // M6: the deleted rows' forensic state goes with them;
                    // held rows keep theirs.
                    try await store.forensicPerEmailDelete(ids: deletable)
                    outcome.deleted += deletable.count
                }
                guard let last = page.last else { break }
                cursorDate = last.date
                cursorID = last.id
                if page.count < 500 { break }
            }
        }

        // 2. Per-email forensic state (references deleted rows). The audit
        //    log + source-hash history are historical evidence and REMAIN.
        if held.isEmpty {
            do { try await clearPerEmailForensicState() }
            catch { outcome.warnings.append("Forensic per-email state could not be fully cleared: \(error.localizedDescription)") }
        } else {
            // Held path already deleted per-row forensic state above; reset
            // the in-memory caches so stale entries don't linger.
            let fm = ForensicManager.shared
            fm.perEmailHashes = [:]
            await fm.bootstrapFromStore()
        }

        // 3. Spotlight.
        SpotlightIndexer.shared.removeAllIndexedEmails()

        // 4. Active import checkpoints — a fresh import must re-ingest.
        do { try await ImportCheckpointStore.shared.reset() }
        catch { outcome.warnings.append("Import checkpoints could not be cleared: \(error.localizedDescription)") }

        // 5. Legacy stores + tombstone (§11.3): remove the v1 JSON archive and
        //    the legacy SwiftData rows, then stamp the tombstone so activation
        //    never re-migrates old state into the cleared archive.
        EmailPersistence.clear()
        do { try await EmailStore.shared.clearAll() }
        catch { outcome.warnings.append("Legacy SwiftData store could not be cleared: \(error.localizedDescription)") }
        UserDefaults.standard.set(true, forKey: Self.migrationTombstoneKey)

        // 6. Record the clear in the audit chain (kept as evidence) — skipped
        //    during erase-all, whose next step destroys the chain (an append
        //    racing that destruction would orphan a row and read as tamper).
        if auditTheClear {
            ForensicManager.shared.logAction(
                "Archive Cleared",
                detail: "\(outcome.deleted) email(s) removed; \(outcome.heldKept) preserved under legal hold"
            )
        }
        Self.logger.info("archive cleared: \(outcome.deleted) removed, \(outcome.heldKept) held")
        return outcome
    }

    private func clearPerEmailForensicState() async throws {
        // Tags/annotations/hashes reference deleted rows; the audit log and
        // source hashes remain. (forensicClearAll would drop those too, so
        // clear the three per-email tables specifically via the manager cache
        // reset + targeted deletes.)
        try await store.forensicPerEmailClear()
        let fm = ForensicManager.shared
        fm.evidenceTags = [:]
        fm.tagTimestamps = [:]
        fm.annotations = [:]
        fm.perEmailHashes = [:]
    }

    /// §11.2: the stronger destructive operation — everything clearArchive
    /// removes PLUS receipts, forensic history, preferences, keychain
    /// material, temp files. Never silent: failures surface in the outcome.
    @discardableResult
    func eraseAllData() async -> ClearOutcome {
        var outcome = ClearOutcome()
        do {
            outcome = try await clearArchive(respectLegalHolds: false, auditTheClear: false)
        } catch {
            outcome.warnings.append("Archive clear failed during erase: \(error.localizedDescription)")
        }
        do { try await store.forensicClearAll() }
        catch { outcome.warnings.append("Forensic history could not be erased: \(error.localizedDescription)") }
        // H3: the review JSON is normally KEPT as migration rollback evidence —
        // an erase-all must destroy it, or the wiped 'migrated' flag would
        // re-import the user's pins/tags/annotations on next launch.
        try? FileManager.default.removeItem(at: ReviewStateService.legacyJSONURL)
        // Receipts, legacy JSON remnants, preferences, keychain, temp files.
        // NOTE: this wipes the whole defaults domain — including the §11.3
        // tombstone and migration flags — so they are re-stamped below.
        LegalComplianceManager.shared.deleteAllUserData()
        UserDefaults.standard.set(true, forKey: Self.migrationTombstoneKey)
        return outcome
    }
}
