//
//  MailinStoreMigration.swift
//  maxmailin
//
//  Stage 4B.3 (v2-core-cutover): one-time, NON-DESTRUCTIVE migration of the
//  canonical email store from SwiftData (`EmailStore`) to direct SQLite
//  (`SQLiteEmailStore`), chosen after the stress harness proved SwiftData can't
//  scale on the shipping deployment target (see V2_STORAGE_DECISION.md).
//
//  Guarantees:
//    • Non-destructive — the SwiftData store is only READ; never deleted or
//      mutated. It remains an intact rollback until the cutover is trusted.
//    • Bounded memory — a keyset page walk copies one bounded page at a time.
//    • Resumable — each page skips ids already present in the destination, so an
//      interrupted migration continues where it left off.
//    • Count-gated — marked complete only when the SQLite count reaches the
//      SwiftData count (mirrors the v1→v2 migration's distinct-count gate).
//    • Idempotent — once complete (or once the destination already holds every
//      row) it is a fast no-op.
//

import Foundation

enum MailinStoreMigration {
    struct Result: Sendable, Equatable {
        var copied: Int
        var sourceCount: Int
        var destCount: Int
        var completed: Bool
    }

    private static let completedKey = "mailin.migration.swiftdata_to_sqlite.completed"

    static var isCompleted: Bool { UserDefaults.standard.bool(forKey: completedKey) }

    /// Copy every email from the SwiftData `source` into the SQLite `dest`.
    /// See file header for the guarantees. `source` is never modified.
    @discardableResult
    static func migrate(
        from source: EmailStore,
        to dest: SQLiteEmailStore,
        pageSize: Int = 2_000,
        maxPages: Int? = nil,
        markCompleteFlag: Bool = true
    ) async throws -> Result {
        let sourceCount = try await source.totalCount()

        // Fast path: destination already holds everything.
        var destCount = try await dest.totalCount()
        if sourceCount == 0 || destCount >= sourceCount {
            if markCompleteFlag { UserDefaults.standard.set(true, forKey: completedKey) }
            return Result(copied: 0, sourceCount: sourceCount, destCount: destCount, completed: true)
        }

        var copied = 0
        var beforeDate: Date? = nil
        var beforeID: UUID? = nil
        var pages = 0
        while true {
            if let maxPages, pages >= maxPages { break }
            if Task.isCancelled { break }
            // (id, date) keyset page over the source — bounded, ordered.
            let page = try await source.reconcilePage(beforeDate: beforeDate, beforeID: beforeID, limit: pageSize)
            if page.isEmpty { break }
            let ids = page.map(\.id)
            // Resume-safe: only copy ids not already in the destination.
            let existing = try await dest.existingIDs(among: ids)
            let missing = ids.filter { !existing.contains($0) }
            if !missing.isEmpty {
                let emails = try await source.emails(withIDs: missing)   // full bodies
                // §10.2: migration PRESERVES existing user state exactly —
                // legitimate v1 rows that share a Message-ID must not be
                // dropped by the import-time dedup policy. Resume-idempotency
                // comes from the preserved v1 UUIDs (id PRIMARY KEY), not
                // from Message-ID uniqueness.
                try await dest.insertBatch(
                    emails, sourceFileHash: nil, accountID: nil,
                    sourceID: nil, firstOrdinal: nil, dedupPolicy: .preserveAll,
                    batchSize: 1_000, progress: nil)
                copied += emails.count
            }
            beforeDate = page.last!.date
            beforeID = page.last!.id
            pages += 1
            if page.count < pageSize { break }
        }

        destCount = try await dest.totalCount()
        let completed = destCount >= sourceCount
        if completed && markCompleteFlag { UserDefaults.standard.set(true, forKey: completedKey) }
        return Result(copied: copied, sourceCount: sourceCount, destCount: destCount, completed: completed)
    }

    /// Production entry: migrate the real SwiftData store into the shared SQLite
    /// store, once. Safe to call on every launch — a fast no-op once complete.
    @discardableResult
    static func migrateProductionIfNeeded() async throws -> Result {
        guard !isCompleted else {
            return Result(copied: 0, sourceCount: 0, destCount: 0, completed: true)
        }
        return try await migrate(from: .shared, to: .shared)
    }

    #if DEBUG
    static func resetCompletionForTesting() { UserDefaults.standard.removeObject(forKey: completedKey) }
    #endif
}
