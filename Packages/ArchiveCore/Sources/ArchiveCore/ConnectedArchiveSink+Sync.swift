//
//  ConnectedArchiveSink+Sync.swift
//  ArchiveCore
//
//  Plan v4 V4-04 (§5.2–§5.4): what the provider-independent sync engine
//  (MailConnectivity.SyncEngine) needs from the archive beyond `capture`:
//
//   • `recordObservation` — a provider listed (or moved) a message that is
//     already preserved: new memberships + a durable item outcome, no
//     download, no second record (idempotent repeated sync, T17, T28).
//   • `markRemoteAbsent` — the server deleted a preserved message: the
//     connected PROJECTION changes (`remote_present = 0`); the preserved
//     record, bytes and search evidence are untouched (§5.1).
//   • `retryCandidates` — items whose latest outcome is `failed` and that
//     are not preserved, paged, so a failure is retried exactly (T20).
//   • `completeness` — acquisition and preservation computed from the v26
//     tables (§5.4); search coverage and export verification are reported by
//     the existing coverage / receipt code through hooks the caller supplies.
//
//  No schema change: everything reads and writes the v26 tables.
//

import Foundation
import SQLite3

// MARK: - Identity key round trip

extension ProviderMessageIdentity {
    /// Parses a `key()` back into the identity (retry of an exact failure).
    public init(key: String) throws {
        let parts = key.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
        switch (parts.first, parts.count) {
        case ("gmail", 2): self = .gmail(messageID: parts[1])
        case ("graph", 3): self = .graph(mailbox: parts[1], immutableID: parts[2])
        case ("imap", 4):
            guard let validity = UInt32(parts[2]), let uid = UInt32(parts[3]) else {
                throw ConnectedArchiveError.invalidIdentity("the IMAP identity key has a non-numeric UIDVALIDITY or UID")
            }
            self = .imap(mailbox: parts[1], uidValidity: validity, uid: uid)
        case ("imap-gm", 2):
            guard let id = UInt64(parts[1]) else {
                throw ConnectedArchiveError.invalidIdentity("the Gmail IMAP identity key has a non-numeric X-GM-MSGID")
            }
            self = .gmailIMAP(messageID: id)
        default:
            throw ConnectedArchiveError.invalidIdentity("“\(key.replacingOccurrences(of: "\u{1F}", with: "|"))” is not an identity key")
        }
        _ = try self.key()
    }
}

// MARK: - Completeness (§5.4)

/// Acquisition and preservation of one account's connected mail, from the
/// archive's own tables. Never inferred from a run's success alone.
public struct ConnectedCompleteness: Sendable, Equatable {
    public struct Acquisition: Sendable, Equatable {
        /// Provider identities preserved in the archive (one per occurrence key).
        public var captured: Int
        /// Of those, deleted locally by the user (kept deleted, not resurrected).
        public var locallyDeleted: Int
        /// Listed by the provider, durably queued, outcome not yet reached.
        public var remaining: Int
        /// Download failed with a recorded reason; retried on the next sync.
        public var failed: Int
        /// Deleted / moved out of reach on the server before it could be saved.
        public var unavailable: Int
        /// True only once every selected folder was enumerated to its end and
        /// the changes made during that enumeration were reconciled. While
        /// false, the size of the remote inventory is UNKNOWN.
        public var inventoryKnown: Bool
        /// The provider change point the archive is reconciled to (history id,
        /// delta link, MODSEQ …), and when it was committed.
        public var reconciledTo: String?
        public var reconciledAt: Date?
        /// Preserved messages the server no longer shows (projection only).
        public var removedOnServer: Int
    }

    public struct Preservation: Sendable, Equatable {
        /// Preserved records whose bytes are in the blob tier.
        public var recordsWithBytes: Int
        /// Records whose bytes were found missing by restart reconciliation.
        public var recordsMissingBytes: Int
        /// Sum of the captured byte counts (each hashed with SHA-256).
        public var bytes: Int64
        /// Preserved, but the reader could not parse the bytes (not searchable
        /// as text until the parse is retried).
        public var unreadable: Int
    }

    public struct Runs: Sendable, Equatable {
        public var lastAttemptedAt: Date?
        /// The last run that ended with nothing pending and nothing failed.
        public var lastSuccessfulAt: Date?
        /// The interval the last successful run covered (start → end).
        public var lastSuccessfulStartedAt: Date?
    }

    public var accountID: UUID
    public var acquisition: Acquisition
    public var preservation: Preservation
    public var runs: Runs
}

// MARK: - Sink API

extension ConnectedArchiveSink {

    /// A listed message that is ALREADY preserved for this account: records
    /// the new memberships and the item outcome (`alreadyPreserved`, or
    /// `locallyDeleted` when the user deleted it) in one transaction, without
    /// bytes. Returns nil when the identity is not preserved — the caller
    /// must download it.
    public func recordObservation(runID: String, accountID: UUID, identity: ProviderMessageIdentity,
                                  occurrences: [RemoteFolderOccurrence],
                                  metadata: ProviderMetadata? = nil) async throws -> CaptureOutcome? {
        try await store.recordConnectedObservation(runID: runID, accountID: accountID, identity: identity,
                                                   occurrences: occurrences, metadata: metadata)
    }

    /// The server deleted a message. A preserved message is only marked
    /// absent in the connected projection — never deleted. Returns false when
    /// the identity was never preserved (the caller records it unavailable).
    @discardableResult
    public func markRemoteAbsent(accountID: UUID, identity: ProviderMessageIdentity) async throws -> Bool {
        try await store.markConnectedRemoteAbsent(accountID: accountID, key: identity.key())
    }

    /// Identities whose latest outcome is `failed` and that are not
    /// preserved, in key order, one page at a time (`after` = last key seen).
    public func retryCandidates(accountID: UUID, after: String?, limit: Int) async throws -> [ProviderMessageIdentity] {
        try await store.connectedRetryCandidates(accountID: accountID, after: after, limit: limit)
    }

    /// Marks a finished run as stopped before its end (paused, cancelled,
    /// sign-in needed). A stopped run is never a "successful sync", even
    /// when it had listed nothing yet.
    public func markRunStopped(_ runID: String, reason: String) async throws {
        try await store.markCaptureRunStopped(runID: runID, reason: reason)
    }

    public func completeness(accountID: UUID) async throws -> ConnectedCompleteness {
        try await store.connectedCompleteness(accountID: accountID)
    }

    /// The parse failures of preserved connected records (retry list, T20).
    public func unreadableCaptures(accountID: UUID) async throws -> [(identity: ProviderMessageIdentity, reason: String)] {
        try await store.connectedUnreadable(accountID: accountID)
    }
}

// MARK: - Store

extension SQLiteEmailStore {

    func recordConnectedObservation(runID: String, accountID: UUID, identity: ProviderMessageIdentity,
                                    occurrences: [RemoteFolderOccurrence], metadata: ProviderMetadata?) throws -> CaptureOutcome? {
        let key = try identity.key()
        let db = try ensureDB()
        let run = try captureRunAccount(db, runID: runID)
        guard run.account == accountID else { throw ConnectedArchiveError.accountMismatch }
        guard run.state == "running" else { throw ConnectedArchiveError.runNotRunning(runID) }
        guard let existing = try existingRemoteMessage(accountID: accountID, key: key) else { return nil }
        let sourceID = try accountSourceID(db, accountID: accountID)
        let now = Int64(Date().timeIntervalSince1970)
        let state: CaptureItemState = existing.emailExists ? .alreadyPreserved : .locallyDeleted
        // writeMemberships reads only the account, identity and occurrences.
        let carrier = CaptureItem(accountID: accountID, identity: identity, occurrences: occurrences,
                                  raw: StagedRawMessage(fileURL: URL(fileURLWithPath: "/dev/null"), sha256: existing.digest,
                                                        byteCount: existing.length),
                                  metadata: metadata ?? ProviderMetadata(representation: .gmailRaw))
        try exec(db, SQLiteHygiene.beginWrite)
        do {
            try upsertRemoteFolders(db, accountID: accountID, folders: occurrences, now: now)
            let added = try writeMemberships(db, item: carrier, key: key, emailID: existing.emailExists ? existing.emailID : nil,
                                             sourceID: sourceID, now: now)
            let touch = try prepare(db, """
                UPDATE remote_messages SET last_seen_at = ?, remote_present = 1, revision = COALESCE(?, revision)
                WHERE account_id = ? AND identity_key = ?;
            """)
            defer { sqlite3_finalize(touch) }
            sqlite3_bind_int64(touch, 1, now); bindTextOrNull(touch, 2, metadata?.revision)
            bindText(touch, 3, accountID.uuidString); bindText(touch, 4, key)
            guard sqlite3_step(touch) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
            // A `stored` outcome of this run stays `stored` (the same message
            // listed in a second folder is not a second capture).
            let item = try prepare(db, """
                INSERT INTO capture_items(run_id, account_id, identity_key, state, email_id, sha256, bytes, representation, error, recorded_at)
                VALUES (?,?,?,?,?,?,?,NULL,NULL,?)
                ON CONFLICT(run_id, identity_key) DO UPDATE SET state = excluded.state, email_id = excluded.email_id,
                    sha256 = excluded.sha256, bytes = excluded.bytes, error = NULL, recorded_at = excluded.recorded_at
                WHERE capture_items.state NOT IN ('stored', 'alreadyPreserved', 'locallyDeleted');
            """)
            defer { sqlite3_finalize(item) }
            bindText(item, 1, runID); bindText(item, 2, accountID.uuidString); bindText(item, 3, key)
            bindText(item, 4, state.rawValue); bindTextOrNull(item, 5, existing.emailID?.uuidString)
            bindText(item, 6, existing.digest); sqlite3_bind_int64(item, 7, existing.length); sqlite3_bind_int64(item, 8, now)
            guard sqlite3_step(item) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
            try exec(db, "COMMIT;")
            return CaptureOutcome(identity: identity, state: state, emailID: existing.emailID, sha256: existing.digest,
                                  byteCount: existing.length, newMemberships: added)
        } catch { try? exec(db, "ROLLBACK;"); throw error }
    }

    func markConnectedRemoteAbsent(accountID: UUID, key: String) throws -> Bool {
        let db = try ensureDB()
        let stmt = try prepare(db, "UPDATE remote_messages SET remote_present = 0, last_seen_at = ? WHERE account_id = ? AND identity_key = ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(Date().timeIntervalSince1970))
        bindText(stmt, 2, accountID.uuidString); bindText(stmt, 3, key)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
        return sqlite3_changes(db) > 0
    }

    /// Latest outcome per identity of the account's unpreserved items, folded
    /// in key order (rowid = insertion order; a later run's row is newer).
    private func foldLatestUnpreserved(_ db: OpaquePointer, accountID: UUID, after: String?,
                                       _ body: (String, String) throws -> Bool) throws {
        let stmt = try prepare(db, """
            SELECT ci.identity_key, ci.state FROM capture_items ci
            LEFT JOIN remote_messages r ON r.account_id = ci.account_id AND r.identity_key = ci.identity_key
            WHERE ci.account_id = ? AND r.identity_key IS NULL AND (? IS NULL OR ci.identity_key > ?)
            ORDER BY ci.identity_key, ci.rowid;
        """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, accountID.uuidString); bindTextOrNull(stmt, 2, after); bindTextOrNull(stmt, 3, after)
        var currentKey: String?
        var currentState = ""
        while try stepRow(stmt, db) {
            let key = columnText(stmt, 0)
            if let k = currentKey, k != key {
                guard try body(k, currentState) else { return }
            }
            currentKey = key
            currentState = columnText(stmt, 1)
        }
        if let k = currentKey { _ = try body(k, currentState) }
    }

    func connectedRetryCandidates(accountID: UUID, after: String?, limit: Int) throws -> [ProviderMessageIdentity] {
        let db = try ensureDB()
        var out: [ProviderMessageIdentity] = []
        try foldLatestUnpreserved(db, accountID: accountID, after: after) { key, state in
            if state == CaptureItemState.failed.rawValue { out.append(try ProviderMessageIdentity(key: key)) }
            return out.count < max(1, limit)
        }
        return out
    }

    func markCaptureRunStopped(runID: String, reason: String) throws {
        let db = try ensureDB()
        let stmt = try prepare(db, "UPDATE capture_runs SET state = 'stopped', selection = selection || ? , finished_at = COALESCE(finished_at, ?) WHERE run_id = ?;")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, " — stopped: \(reason)"); sqlite3_bind_int64(stmt, 2, Int64(Date().timeIntervalSince1970))
        bindText(stmt, 3, runID)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
    }

    func connectedCompleteness(accountID: UUID) throws -> ConnectedCompleteness {
        let db = try ensureDB()
        let account = accountID.uuidString
        func count(_ sql: String) throws -> Int {
            let stmt = try prepare(db, sql)
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, account)
            guard try stepRow(stmt, db) else { return 0 }
            return Int(sqlite3_column_int64(stmt, 0))
        }
        func date(_ sql: String) throws -> Date? {
            let stmt = try prepare(db, sql)
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, account)
            guard try stepRow(stmt, db), sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
            return Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 0)))
        }
        let captured = try count("SELECT COUNT(*) FROM remote_messages WHERE account_id = ?;")
        let locallyDeleted = try count("SELECT COUNT(*) FROM remote_messages r WHERE r.account_id = ? AND NOT EXISTS (SELECT 1 FROM emails e WHERE e.id = r.email_id);")
        let removed = try count("SELECT COUNT(*) FROM remote_messages WHERE account_id = ? AND remote_present = 0;")
        let missing = try count("SELECT COUNT(*) FROM remote_messages WHERE account_id = ? AND json_extract(metadata_json, '$.mailinBytesMissing') = 'true';")
        let unreadable = try count("SELECT COUNT(*) FROM remote_messages WHERE account_id = ? AND json_extract(metadata_json, '$.\(ConnectedArchiveSink.parseErrorKey)') IS NOT NULL;")
        let bytesStmt = try prepare(db, "SELECT COALESCE(SUM(blob_length), 0) FROM remote_messages WHERE account_id = ?;")
        bindText(bytesStmt, 1, account)
        let bytes = try stepRow(bytesStmt, db) ? sqlite3_column_int64(bytesStmt, 0) : 0
        sqlite3_finalize(bytesStmt)

        var remaining = 0, failed = 0, unavailable = 0
        try foldLatestUnpreserved(db, accountID: accountID, after: nil) { _, state in
            switch state {
            case CaptureItemState.pending.rawValue: remaining += 1
            case CaptureItemState.failed.rawValue: failed += 1
            case CaptureItemState.unavailable.rawValue: unavailable += 1
            default: break
            }
            return true
        }

        // Inventory known: every change-tracking scope of the account is
        // `ready` (bootstrap enumerated AND reconciled), and there is one.
        var states: [(cursor: String, state: String, at: Int64)] = []
        let cp = try prepare(db, """
            SELECT cursor, bootstrap_state, committed_at FROM sync_checkpoints
            WHERE account_id = ? AND (scope = 'sync' OR scope LIKE 'changes:%');
        """)
        bindText(cp, 1, account)
        while try stepRow(cp, db) { states.append((columnText(cp, 0), columnText(cp, 1), sqlite3_column_int64(cp, 2))) }
        sqlite3_finalize(cp)
        let known = !states.isEmpty && states.allSatisfy { $0.state.hasPrefix("ready") }
        let newest = states.max { $0.at < $1.at }

        let lastAttempt = try date("SELECT MAX(started_at) FROM capture_runs WHERE account_id = ?;")
        let success = try prepare(db, """
            SELECT started_at, finished_at FROM capture_runs r
            WHERE r.account_id = ? AND r.state IN ('completed', 'partial') AND r.finished_at IS NOT NULL
              AND NOT EXISTS (SELECT 1 FROM capture_items i WHERE i.run_id = r.run_id AND i.state IN ('pending', 'failed'))
            ORDER BY r.finished_at DESC, r.rowid DESC LIMIT 1;
        """)
        bindText(success, 1, account)
        var lastSuccess: Date?, lastSuccessStart: Date?
        if try stepRow(success, db) {
            lastSuccessStart = Date(timeIntervalSince1970: Double(sqlite3_column_int64(success, 0)))
            lastSuccess = Date(timeIntervalSince1970: Double(sqlite3_column_int64(success, 1)))
        }
        sqlite3_finalize(success)

        return ConnectedCompleteness(
            accountID: accountID,
            acquisition: .init(captured: captured, locallyDeleted: locallyDeleted, remaining: remaining, failed: failed,
                               unavailable: unavailable, inventoryKnown: known,
                               reconciledTo: known ? newest?.cursor : nil,
                               reconciledAt: known ? newest.map { Date(timeIntervalSince1970: Double($0.at)) } : nil,
                               removedOnServer: removed),
            preservation: .init(recordsWithBytes: captured - missing, recordsMissingBytes: missing, bytes: bytes,
                                unreadable: unreadable),
            runs: .init(lastAttemptedAt: lastAttempt, lastSuccessfulAt: lastSuccess, lastSuccessfulStartedAt: lastSuccessStart))
    }

    func connectedUnreadable(accountID: UUID) throws -> [(identity: ProviderMessageIdentity, reason: String)] {
        let db = try ensureDB()
        let stmt = try prepare(db, """
            SELECT identity_key, json_extract(metadata_json, '$.\(ConnectedArchiveSink.parseErrorKey)') FROM remote_messages
            WHERE account_id = ? AND json_extract(metadata_json, '$.\(ConnectedArchiveSink.parseErrorKey)') IS NOT NULL
            ORDER BY identity_key;
        """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, accountID.uuidString)
        var out: [(ProviderMessageIdentity, String)] = []
        while try stepRow(stmt, db) { out.append((try ProviderMessageIdentity(key: columnText(stmt, 0)), columnText(stmt, 1))) }
        return out
    }
}
