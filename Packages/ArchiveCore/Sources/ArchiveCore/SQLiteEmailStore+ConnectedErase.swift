//
//  SQLiteEmailStore+ConnectedErase.swift
//  ArchiveCore
//
//  Lifecycle audit 2026-11-14:
//   • Delete All Data clears the archive's mail rows but used to leave the
//     connected-mail tables behind: the removed accounts were listed again
//     after the restart, and an account added again found its old provider
//     identities ("already saved" / "deleted here") and its sync cursors, so
//     it never captured its mail again. `eraseConnectedMailRows` empties every
//     connected-mail table in one transaction (erase-all only — the per-account
//     paths keep using their own, narrower deletes).
//   • Deleting one account's archived mail removes the records from the
//     search index FIRST (like every other delete): `connectedDeletableRecordIDs`
//     lists exactly the records `deleteConnectedAccountArchive` would delete.
//
//  No schema change.
//

import Foundation
import SQLite3

extension SQLiteEmailStore {

    /// Every connected-mail table, emptied together by an erase-all.
    nonisolated static let connectedMailTables = ["mail_accounts", "remote_folders", "remote_messages", "remote_memberships",
                                                  "sync_checkpoints", "capture_runs", "capture_items"]

    /// Deletes every row of the connected-mail tables (Delete All Data).
    /// Returns how many rows were removed. One transaction: all or nothing.
    @discardableResult
    func eraseConnectedMailRows() throws -> Int {
        let db = try ensureDB()
        var removed = 0
        try exec(db, SQLiteHygiene.beginWrite)
        do {
            for table in Self.connectedMailTables {
                try exec(db, "DELETE FROM \(table);")
                removed += Int(sqlite3_changes(db))
            }
            try exec(db, "COMMIT;")
        } catch { try? exec(db, "ROLLBACK;"); throw error }
        return removed
    }

    /// The account's archived records that "delete this account's archived
    /// mail" removes: its records in the archive, legal holds excepted (the
    /// same set `deleteConnectedAccountArchive` deletes). Every record, in id order.
    func connectedDeletableRecordIDs(accountID: UUID) throws -> [UUID] {
        let db = try ensureDB()
        let stmt = try prepare(db, """
            SELECT DISTINCT r.email_id FROM remote_messages r JOIN emails e ON e.id = r.email_id
            WHERE r.account_id = ?1 AND NOT EXISTS (SELECT 1 FROM legal_holds h WHERE h.email_id = r.email_id)
            ORDER BY r.email_id;
        """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, accountID.uuidString)
        var out: [UUID] = []
        while try stepRow(stmt, db) { if let id = columnUUID(stmt, 0) { out.append(id) } }
        return out
    }
}

extension ConnectedArchiveSink {
    /// Delete All Data: every connected-mail row (accounts, folders,
    /// occurrences, memberships, cursors, runs and item outcomes).
    @discardableResult
    public func eraseAllConnectedRows() async throws -> Int {
        try await store.eraseConnectedMailRows()
    }

    /// The records `deleteAccountArchive` would remove now (for the search index, first).
    public func deletableRecordIDs(accountID: UUID) async throws -> [UUID] {
        try await store.connectedDeletableRecordIDs(accountID: accountID)
    }
}
