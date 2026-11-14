//
//  DuplicateCleanup.swift
//  ArchiveCore
//
//  Five jobs DUP-04 / DUP-05: removing a duplicate copy keeps everything the
//  copy carried and stays reversible.
//
//    • Before a copy goes, its folder memberships, source tags, user tags
//      and note are merged into the kept copy (the survivor), so no
//      location, label or annotation is lost with the row.
//    • The copy is moved to the Trash (`email_review_state.trashed`), never
//      deleted here: the Trash restores it; permanent deletion stays the
//      explicit second step it already is.
//    • V4: a removed copy captured from a connected account hands its
//      account link (provider identity, memberships, provenance) to the
//      survivor, so account search, the Mail workspace and provenance still
//      find the mail, and later label changes attach to the survivor. The
//      occurrence remembers which record it came from (`mailinCarriedFrom`).
//    • A copy under a legal hold recorded in the database is kept, whatever
//      the caller and whether or not the Professional interface is on.
//    • `reclaimableBytesEstimate` says what a permanent deletion would free
//      — inline bodies, and a blob-tier file only when no other row still
//      references it. The Trash itself frees nothing, and the UI says so.
//

import Foundation
import SQLite3

extension SQLiteEmailStore {
    struct DuplicateRemovalPlan: Sendable, Equatable {
        /// The copy that stays.
        let survivor: UUID
        /// The copies to move to the Trash after merging into the survivor.
        let removed: [UUID]
    }

    struct DuplicateCleanupResult: Sendable, Equatable {
        var trashed: [UUID] = []
        var heldKept: [UUID] = []
        var membershipsMerged = 0
        var userTagsMerged = 0
        var annotationsMerged = 0
        /// Connected-account occurrences handed from a removed copy to its survivor.
        var accountLinksCarried = 0
    }

    /// Merge, then trash. One transaction: either every copy of every plan is
    /// handled or nothing changed.
    func removeDuplicateCopies(_ plans: [DuplicateRemovalPlan]) throws -> DuplicateCleanupResult {
        var result = DuplicateCleanupResult()
        guard !plans.isEmpty else { return result }
        let db = try ensureDB()
        // Holds are checked here, always — not only when the Professional
        // layer or the store's delete gate is on.
        let held = try legalHeldAmong(plans.flatMap(\.removed))
        let now = Int64(Date().timeIntervalSince1970)
        try exec(db, SQLiteHygiene.beginWrite)
        do {
            for plan in plans {
                for copy in plan.removed where copy != plan.survivor {
                    if held.contains(copy) { result.heldKept.append(copy); continue }
                    result.membershipsMerged += try copyRows(db,
                        "INSERT OR IGNORE INTO email_folders(email_id, folder_id) SELECT ?, folder_id FROM email_folders WHERE email_id = ?;",
                        into: plan.survivor, from: copy)
                    _ = try copyRows(db,
                        "INSERT OR IGNORE INTO email_tags(email_id, tag) SELECT ?, tag FROM email_tags WHERE email_id = ?;",
                        into: plan.survivor, from: copy)
                    result.userTagsMerged += try copyRows(db,
                        "INSERT OR IGNORE INTO email_user_tags(email_id, tag) SELECT ?, tag FROM email_user_tags WHERE email_id = ?;",
                        into: plan.survivor, from: copy)
                    result.accountLinksCarried += try carryConnectedLinks(db, into: plan.survivor, from: copy)
                    if let note = try noteOf(db, copy), !note.isEmpty {
                        let existing = try noteOf(db, plan.survivor) ?? ""
                        if existing != note {
                            let merged = existing.isEmpty ? note : existing + "\n— from a removed duplicate copy: " + note
                            let stmt = try prepare(db, """
                                INSERT INTO email_annotations(email_id, note, updated_at) VALUES (?, ?, ?)
                                ON CONFLICT(email_id) DO UPDATE SET note = excluded.note, updated_at = excluded.updated_at;
                            """)
                            defer { sqlite3_finalize(stmt) }
                            bindText(stmt, 1, plan.survivor.uuidString)
                            bindText(stmt, 2, merged)
                            sqlite3_bind_int64(stmt, 3, now)
                            guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
                            result.annotationsMerged += 1
                        }
                    }
                    result.trashed.append(copy)
                }
            }
            if !result.trashed.isEmpty {
                let stmt = try prepare(db, """
                    INSERT INTO email_review_state(email_id, trashed, updated_at) VALUES (?, 1, ?)
                    ON CONFLICT(email_id) DO UPDATE SET trashed = 1, updated_at = excluded.updated_at;
                """)
                defer { sqlite3_finalize(stmt) }
                for id in result.trashed {
                    sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
                    bindText(stmt, 1, id.uuidString)
                    sqlite3_bind_int64(stmt, 2, now)
                    guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
                }
            }
            try exec(db, "COMMIT;")
        } catch {
            try? exec(db, "ROLLBACK;")
            throw error
        }
        return result
    }

    /// Bytes a PERMANENT deletion of these rows would free: inline raw, plain,
    /// HTML and headers, plus a blob-tier file only when no row outside the
    /// set still references its digest. Index space and page slack are not
    /// counted; a VACUUM is what returns space to the file system.
    func reclaimableBytesEstimate(ids: [UUID]) throws -> Int64 {
        guard !ids.isEmpty else { return 0 }
        let db = try ensureDB()
        var total: Int64 = 0
        var blobs: [String: Int64] = [:]
        for start in stride(from: 0, to: ids.count, by: 500) {
            let chunk = Array(ids[start..<min(start + 500, ids.count)])
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let stmt = try prepare(db, """
                SELECT COALESCE(length(raw), 0) + COALESCE(length(plain), 0) + COALESCE(length(html), 0) + COALESCE(length(headers_json), 0),
                       raw_blob_digest, COALESCE(raw_blob_length, 0)
                FROM email_bodies WHERE id IN (\(marks));
            """)
            defer { sqlite3_finalize(stmt) }
            for (i, id) in chunk.enumerated() { bindText(stmt, Int32(i + 1), id.uuidString) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                total += sqlite3_column_int64(stmt, 0)
                if sqlite3_column_type(stmt, 1) != SQLITE_NULL {
                    let digest = columnText(stmt, 1)
                    if !digest.isEmpty { blobs[digest] = sqlite3_column_int64(stmt, 2) }
                }
            }
        }
        let set = Set(ids.map(\.uuidString))
        for (digest, length) in blobs {
            let stmt = try prepare(db, "SELECT id FROM email_bodies WHERE raw_blob_digest = ?;")
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, digest)
            var referencedOutside = false
            while !referencedOutside, sqlite3_step(stmt) == SQLITE_ROW {
                if !set.contains(columnText(stmt, 0)) { referencedOutside = true }
            }
            if !referencedOutside { total += length }
        }
        return total
    }

    // MARK: Helpers

    private func copyRows(_ db: OpaquePointer, _ sql: String, into survivor: UUID, from copy: UUID) throws -> Int {
        let stmt = try prepare(db, sql)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, survivor.uuidString)
        bindText(stmt, 2, copy.uuidString)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
        return Int(sqlite3_changes(db))
    }

    /// Every connected occurrence of `copy` now names the survivor (the
    /// occurrence key is the provider identity, so nothing else changes);
    /// the first record it named is kept in its metadata.
    private func carryConnectedLinks(_ db: OpaquePointer, into survivor: UUID, from copy: UUID) throws -> Int {
        let stmt = try prepare(db, """
            UPDATE remote_messages SET email_id = ?1,
                metadata_json = json_set(CASE WHEN json_valid(metadata_json) THEN metadata_json ELSE '{}' END,
                                         '$.mailinCarriedFrom',
                                         COALESCE(CASE WHEN json_valid(metadata_json) THEN json_extract(metadata_json, '$.mailinCarriedFrom') END, ?2))
            WHERE email_id = ?2;
        """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, survivor.uuidString)
        bindText(stmt, 2, copy.uuidString)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
        return Int(sqlite3_changes(db))
    }

    private func noteOf(_ db: OpaquePointer, _ id: UUID) throws -> String? {
        let stmt = try prepare(db, "SELECT note FROM email_annotations WHERE email_id = ?;")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, id.uuidString)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return columnText(stmt, 0)
    }
}
