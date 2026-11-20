//
//  DeferredDeduplication.swift
//  ArchiveCore
//
//  FAST-03 (owner decision 2026-11-20): the fast import stores every message
//  first ("Keep every copy" at insert, no duplicate key), then this pass
//  applies the Duplicates choice the person made — "Skip messages already in
//  the archive" (Message-ID) or "Skip duplicates, including re-encoded
//  copies" (Message-ID, else the content fingerprint) — to the rows of those
//  sources.
//
//  • Keys are exactly the import's (`SQLiteEmailStore.dedupKey` /
//    `canonicalFingerprint`), the fingerprints computed by several workers.
//  • The first copy in import order keeps the key, as at insert: a copy whose
//    key an earlier row (of this run or of the archive) already holds is a
//    duplicate.
//  • A duplicate is not deleted: `removeDuplicateCopies` merges its folders,
//    tags, labels and note into the kept copy and moves it to the Trash, in
//    one transaction, legal holds respected — reversible from the Trash. It
//    is also recorded in `duplicates`, so the receipt counts it as the
//    import does.
//  • A message whose key the person deleted before (a tombstone) goes to the
//    Trash too, as the import would have refused it.
//  • Resumable: the sources waiting for the pass are recorded in
//    `deferred_dedup_pending` before the import writes, removed when the pass
//    finishes; an interrupted pass runs again at the next import and
//    continues — rows already given their key or trashed are not looked at
//    again.
//

import Foundation
import SQLite3

extension SQLiteEmailStore {

    struct DeferredDeduplicationResult: Sendable, Equatable {
        var examined = 0
        var duplicatesTrashed = 0
        var previouslyDeletedTrashed = 0
        var heldKept = 0
        var keysAssigned = 0
        var membershipsMerged = 0
    }

    private func ensureDeferredDedupTable(_ db: OpaquePointer) throws {
        try exec(db, """
            CREATE TABLE IF NOT EXISTS deferred_dedup_pending(
                source_id  INTEGER PRIMARY KEY,
                policy     TEXT NOT NULL,
                created_at INTEGER NOT NULL DEFAULT 0
            );
        """)
    }

    /// Records that `sourceID` was (or is being) imported without duplicate
    /// keys and still owes the pass for `policy`. `.preserveAll` owes nothing.
    func markDeferredDeduplication(sourceID: Int64, policy: DedupPolicy) throws {
        guard policy != .preserveAll else { return }
        let db = try ensureDB()
        try ensureDeferredDedupTable(db)
        let stmt = try prepare(db, "INSERT OR REPLACE INTO deferred_dedup_pending(source_id, policy, created_at) VALUES (?, ?, ?);")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, sourceID)
        bindText(stmt, 2, policy.rawValue)
        sqlite3_bind_int64(stmt, 3, Int64(Date().timeIntervalSince1970))
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
    }

    /// Sources still waiting for the pass, with their policy.
    func pendingDeferredDeduplication() throws -> [(sourceID: Int64, policy: DedupPolicy)] {
        let db = try ensureDB()
        try ensureDeferredDedupTable(db)
        let stmt = try prepare(db, "SELECT source_id, policy FROM deferred_dedup_pending ORDER BY source_id;")
        defer { sqlite3_finalize(stmt) }
        var out: [(Int64, DedupPolicy)] = []
        while try stepRow(stmt, db) {
            if let policy = DedupPolicy(rawValue: columnText(stmt, 1)) {
                out.append((sqlite3_column_int64(stmt, 0), policy))
            }
        }
        return out
    }

    /// One row the pass looks at: what it needs to compute the key.
    private struct DedupCandidate: Sendable {
        let id: UUID
        let rowid: Int64
        let messageID: String?
        let headersJSON: Data?
        let plain: Data?
    }

    /// Runs the pass for every pending source. `workers` is asked before every
    /// page how many fingerprint hashes may run at the same time; `pageSize`
    /// rows are read, keyed and resolved per step, so memory stays bounded
    /// whatever the archive size.
    func runDeferredDeduplication(workers: @Sendable () -> Int, pageSize: Int = 2_000) async throws -> DeferredDeduplicationResult {
        var result = DeferredDeduplicationResult()
        let pending = try pendingDeferredDeduplication()
        guard !pending.isEmpty else { return result }
        let db = try ensureDB()
        let byPolicy = Dictionary(grouping: pending, by: \.policy)

        for (policy, entries) in byPolicy.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let sourceIDs = entries.map(\.sourceID)
            let placeholders = sourceIDs.map { _ in "?" }.joined(separator: ",")
            // Numbered explicitly: ?1 = fingerprint flag, ?2 = last rowid, ?3… = sources.
            let numbered = sourceIDs.indices.map { "?\($0 + 3)" }.joined(separator: ",")
            let wantsFingerprint = policy == .messageIDOrCanonicalFingerprint
            // Keyset paging by rowid (= import order). Bodies are read only
            // where a fingerprint is needed (fingerprint policy, no Message-ID).
            let select = try prepare(db, """
                SELECT e.id, e.rowid, e.message_id,
                       CASE WHEN ?1 = 1 AND (e.message_id IS NULL OR trim(e.message_id) = '') THEN b.headers_json END,
                       CASE WHEN ?1 = 1 AND (e.message_id IS NULL OR trim(e.message_id) = '') THEN b.plain END
                FROM emails e LEFT JOIN email_bodies b ON b.id = e.id
                WHERE e.source_id IN (\(numbered))
                  AND e.dedup_key IS NULL
                  AND e.rowid > ?2
                  AND NOT EXISTS (SELECT 1 FROM email_review_state r WHERE r.email_id = e.id AND r.trashed = 1)
                ORDER BY e.rowid
                LIMIT \(max(1, pageSize));
            """)
            defer { sqlite3_finalize(select) }
            let holder = try prepare(db, "SELECT id FROM emails WHERE dedup_key = ? LIMIT 1;")
            defer { sqlite3_finalize(holder) }
            let claim = try prepare(db, "UPDATE emails SET dedup_key = ? WHERE id = ? AND dedup_key IS NULL;")
            defer { sqlite3_finalize(claim) }
            let tombstoned = try prepare(db, "SELECT 1 FROM deletion_tombstones WHERE dedup_key = ? LIMIT 1;")
            defer { sqlite3_finalize(tombstoned) }
            let anyTombstone = try scalarInt(db, "SELECT EXISTS(SELECT 1 FROM deletion_tombstones);") != 0

            var lastRowid: Int64 = 0
            while true {
                try Task.checkCancellation()
                // 1. Read one page.
                sqlite3_reset(select); sqlite3_clear_bindings(select)
                sqlite3_bind_int(select, 1, wantsFingerprint ? 1 : 0)
                sqlite3_bind_int64(select, 2, lastRowid)
                for (i, sourceID) in sourceIDs.enumerated() { sqlite3_bind_int64(select, Int32(i + 3), sourceID) }
                var page: [DedupCandidate] = []
                page.reserveCapacity(pageSize)
                while try stepRow(select, db) {
                    guard let id = UUID(uuidString: columnText(select, 0)) else { continue }
                    let mid = sqlite3_column_type(select, 2) == SQLITE_NULL ? nil : columnText(select, 2)
                    page.append(DedupCandidate(id: id, rowid: sqlite3_column_int64(select, 1), messageID: mid,
                                               headersJSON: Self.columnData(select, 3), plain: Self.columnData(select, 4)))
                }
                guard let last = page.last else { break }
                lastRowid = last.rowid
                result.examined += page.count

                // 2. Keys, the fingerprints on several workers.
                let keys = await Self.dedupKeys(for: page, policy: policy, workers: max(1, workers()))

                // 3. Resolve in import order: first holder keeps the key.
                var plans: [UUID: [UUID]] = [:]
                var planOrder: [UUID] = []
                var refused: [UUID] = []
                try exec(db, SQLiteHygiene.beginWrite)
                do {
                    for (candidate, key) in zip(page, keys) {
                        guard let key else { continue }   // no key under this policy: kept, as at insert
                        if anyTombstone {
                            sqlite3_reset(tombstoned); sqlite3_clear_bindings(tombstoned)
                            bindText(tombstoned, 1, key)
                            if try stepRow(tombstoned, db) { refused.append(candidate.id); continue }
                        }
                        sqlite3_reset(holder); sqlite3_clear_bindings(holder)
                        bindText(holder, 1, key)
                        if try stepRow(holder, db), let survivor = UUID(uuidString: columnText(holder, 0)), survivor != candidate.id {
                            if plans[survivor] == nil { planOrder.append(survivor) }
                            plans[survivor, default: []].append(candidate.id)
                            continue
                        }
                        sqlite3_reset(claim); sqlite3_clear_bindings(claim)
                        bindText(claim, 1, key)
                        bindText(claim, 2, candidate.id.uuidString)
                        guard sqlite3_step(claim) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
                        result.keysAssigned += Int(sqlite3_changes(db))
                    }
                    try exec(db, "COMMIT;")
                } catch {
                    try? exec(db, "ROLLBACK;")
                    throw error
                }

                // 4. Merge each duplicate into its kept copy, then Trash it (one transaction).
                if !planOrder.isEmpty {
                    let cleanup = try removeDuplicateCopies(planOrder.map { DuplicateRemovalPlan(survivor: $0, removed: plans[$0] ?? []) })
                    result.duplicatesTrashed += cleanup.trashed.count
                    result.heldKept += cleanup.heldKept.count
                    result.membershipsMerged += cleanup.membershipsMerged
                    try recordDeferredDuplicates(db, cleanup.trashed)
                }
                // 5. Previously deleted by the person: to the Trash, as the import would have refused it.
                if !refused.isEmpty {
                    let held = try legalHeldAmong(refused)
                    let trash = refused.filter { !held.contains($0) }
                    result.heldKept += refused.count - trash.count
                    try trashRows(db, trash)
                    result.previouslyDeletedTrashed += trash.count
                }
                await Task.yield()
            }

            // 6. Done for these sources.
            let done = try prepare(db, "DELETE FROM deferred_dedup_pending WHERE source_id IN (\(placeholders));")
            defer { sqlite3_finalize(done) }
            for (i, sourceID) in sourceIDs.enumerated() { sqlite3_bind_int64(done, Int32(i + 1), sourceID) }
            guard sqlite3_step(done) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
        }
        return result
    }

    private static func columnData(_ stmt: OpaquePointer?, _ index: Int32) -> Data? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, index))
        guard count > 0, let bytes = sqlite3_column_blob(stmt, index) else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    /// The import's key for each candidate, in page order. Fingerprints (the
    /// CPU work) are split across `workers` tasks.
    private static func dedupKeys(for page: [DedupCandidate], policy: DedupPolicy, workers: Int) async -> [String?] {
        func key(_ c: DedupCandidate) -> String? {
            let mid = c.messageID?.trimmingCharacters(in: .whitespacesAndNewlines)
            switch policy {
            case .preserveAll:
                return nil
            case .messageID:
                return (mid?.isEmpty == false) ? mid : nil
            case .messageIDOrCanonicalFingerprint:
                if let mid, !mid.isEmpty { return mid }
                let headers = c.headersJSON.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
                let plain = c.plain.map { String(decoding: $0, as: UTF8.self) } ?? ""
                return "fp:" + canonicalFingerprint(headers: headers, plainBody: plain)
            }
        }
        let lanes = max(1, min(workers, page.count))
        guard lanes > 1, policy == .messageIDOrCanonicalFingerprint else { return page.map(key) }
        var keys = [String?](repeating: nil, count: page.count)
        await withTaskGroup(of: [(Int, String?)].self) { group in
            for lane in 0..<lanes {
                group.addTask {
                    var out: [(Int, String?)] = []
                    var index = lane
                    while index < page.count { out.append((index, key(page[index]))); index += lanes }
                    return out
                }
            }
            for await part in group { for (index, value) in part { keys[index] = value } }
        }
        return keys
    }

    /// The trashed copies, in `duplicates` as the import records a skipped one.
    private func recordDeferredDuplicates(_ db: OpaquePointer, _ ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        let stmt = try prepare(db, """
            INSERT INTO duplicates(duplicate_id, message_id, source_hash, created_at)
            SELECT id, message_id, source_hash, date FROM emails WHERE id = ?;
        """)
        defer { sqlite3_finalize(stmt) }
        try exec(db, SQLiteHygiene.beginWrite)
        do {
            for id in ids {
                sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
                bindText(stmt, 1, id.uuidString)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
            }
            try exec(db, "COMMIT;")
        } catch {
            try? exec(db, "ROLLBACK;")
            throw error
        }
    }

    private func trashRows(_ db: OpaquePointer, _ ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        let now = Int64(Date().timeIntervalSince1970)
        let stmt = try prepare(db, """
            INSERT INTO email_review_state(email_id, trashed, updated_at) VALUES (?, 1, ?)
            ON CONFLICT(email_id) DO UPDATE SET trashed = 1, updated_at = excluded.updated_at;
        """)
        defer { sqlite3_finalize(stmt) }
        try exec(db, SQLiteHygiene.beginWrite)
        do {
            for id in ids {
                sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
                bindText(stmt, 1, id.uuidString)
                sqlite3_bind_int64(stmt, 2, now)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
            }
            try exec(db, "COMMIT;")
        } catch {
            try? exec(db, "ROLLBACK;")
            throw error
        }
    }
}
