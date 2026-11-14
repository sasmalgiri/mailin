//
//  ConnectedArchiveSink+RunItems.swift
//  ArchiveCore
//
//  v4.0 REC-07: what a recipe reads back after a capture — every item of a
//  run with its durable outcome and reason (`capture_items`), and whether an
//  identity is already preserved (the selective-capture preview). Reads only;
//  no schema change.
//

import Foundation
import SQLite3

/// One listed message of a capture run, as the archive recorded it.
public struct CaptureRunItem: Sendable, Equatable, Codable {
    public var identityKey: String
    public var state: CaptureItemState
    /// The archive record (stored / already preserved / locally deleted).
    public var emailID: UUID?
    public var sha256: String?
    public var byteCount: Int64?
    /// Why it failed or is unavailable.
    public var reason: String?

    public var identity: ProviderMessageIdentity? { try? ProviderMessageIdentity(key: identityKey) }
}

extension SQLiteEmailStore {
    func captureRunItems(runID: String) throws -> [CaptureRunItem] {
        let db = try ensureDB()
        let stmt = try prepare(db, """
            SELECT identity_key, state, email_id, sha256, bytes, error FROM capture_items
            WHERE run_id = ? ORDER BY identity_key;
        """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, runID)
        var out: [CaptureRunItem] = []
        while try stepRow(stmt, db) {
            func optional(_ i: Int32) -> String? { sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : columnText(stmt, i) }
            out.append(CaptureRunItem(
                identityKey: columnText(stmt, 0),
                state: CaptureItemState(rawValue: columnText(stmt, 1)) ?? .pending,
                emailID: optional(2).flatMap(UUID.init(uuidString:)),
                sha256: optional(3),
                byteCount: sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 4),
                reason: optional(5)))
        }
        return out
    }
}

extension ConnectedArchiveSink {
    /// Every item of `runID` with its outcome and reason, in key order.
    public func runItems(_ runID: String) async throws -> [CaptureRunItem] {
        try await store.captureRunItems(runID: runID)
    }

    /// The archive record of an identity this account already preserved
    /// (nil = not preserved, or the user deleted the record).
    public func preservedEmailID(accountID: UUID, identity: ProviderMessageIdentity) async throws -> UUID? {
        guard let existing = try await store.existingRemoteMessage(accountID: accountID, key: identity.key()),
              existing.emailExists else { return nil }
        return existing.emailID
    }
}
