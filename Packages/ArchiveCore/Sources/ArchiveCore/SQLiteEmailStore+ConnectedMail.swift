//
//  SQLiteEmailStore+ConnectedMail.swift
//  ArchiveCore
//
//  Plan v4 V4-03 (§5.1, §5.2): the archive side of connected mail.
//
//  Schema v26 is ADDITIVE (rule 1): seven new tables, no existing column or
//  row changes, so every offline path reads the archive exactly as before and
//  a v25 build can still read the pre-upgrade snapshot (rule 2 snapshot is
//  taken by `ensureDB` before the migration runs).
//
//    mail_accounts       one row per connected account (UUID). Provider,
//                        issuer/tenant or host, display identity, granted
//                        scopes, enabled modes. NO SECRETS — credentials live
//                        in the Keychain keyed by the account UUID.
//    remote_folders      account-qualified server folders / labels.
//    remote_messages     account-qualified PROVIDER identity → archive record.
//                        Gmail: message id. Graph: mailbox + immutable id.
//                        IMAP: mailbox + UIDVALIDITY + UID. This is the
//                        occurrence key; Message-ID never is.
//    remote_memberships  folder / label observations of one remote message.
//    sync_checkpoints    per account + scope cursor, advanced only when every
//                        item of the run is terminal.
//    capture_runs        one capture run (selection, start/end, state).
//    capture_items       the durable per-item outcome of a run.
//
//  Every write in this file runs inside a transaction on the store's single
//  actor connection; the record, its occurrence and its item outcome commit
//  together (they share `insertBatch`'s transaction through `beforeCommit`).
//

import CryptoKit
import Foundation
import SQLite3

extension SQLiteEmailStore {

    // MARK: Schema v26

    func createSchemaV26(_ handle: OpaquePointer) throws {
        try exec(handle, """
            CREATE TABLE IF NOT EXISTS mail_accounts(
                account_id       TEXT PRIMARY KEY,
                provider         TEXT NOT NULL,
                issuer           TEXT NOT NULL DEFAULT '',
                tenant           TEXT,
                host             TEXT,
                port             INTEGER,
                login_name       TEXT,
                display_identity TEXT NOT NULL DEFAULT '',
                granted_scopes   TEXT NOT NULL DEFAULT '[]',
                enabled_modes    TEXT NOT NULL DEFAULT '[]',
                connection_state TEXT NOT NULL DEFAULT 'disconnected',
                source_id        INTEGER,
                created_at       INTEGER NOT NULL,
                updated_at       INTEGER NOT NULL
            );
        """)
        try exec(handle, """
            CREATE TABLE IF NOT EXISTS remote_folders(
                account_id   TEXT NOT NULL,
                server_id    TEXT NOT NULL,
                path         TEXT NOT NULL,
                name         TEXT NOT NULL,
                kind         TEXT NOT NULL DEFAULT 'folder',
                special_use  TEXT,
                uid_validity INTEGER,
                selected     INTEGER NOT NULL DEFAULT 1,
                observed_at  INTEGER NOT NULL,
                PRIMARY KEY(account_id, server_id)
            );
        """)
        try exec(handle, """
            CREATE TABLE IF NOT EXISTS remote_messages(
                account_id          TEXT NOT NULL,
                identity_key        TEXT NOT NULL,
                provider            TEXT NOT NULL,
                mailbox             TEXT,
                provider_message_id TEXT,
                uid_validity        INTEGER,
                uid                 INTEGER,
                email_id            TEXT,
                blob_digest         TEXT NOT NULL,
                blob_length         INTEGER NOT NULL,
                representation      TEXT NOT NULL,
                internal_date       INTEGER,
                revision            TEXT,
                flags_json          TEXT NOT NULL DEFAULT '[]',
                metadata_json       TEXT NOT NULL DEFAULT '{}',
                remote_present      INTEGER NOT NULL DEFAULT 1,
                first_captured_at   INTEGER NOT NULL,
                last_seen_at        INTEGER NOT NULL,
                PRIMARY KEY(account_id, identity_key)
            );
        """)
        try exec(handle, "CREATE INDEX IF NOT EXISTS idx_remote_messages_email ON remote_messages(email_id);")
        try exec(handle, """
            CREATE TABLE IF NOT EXISTS remote_memberships(
                account_id       TEXT NOT NULL,
                identity_key     TEXT NOT NULL,
                folder_server_id TEXT NOT NULL,
                observed_at      INTEGER NOT NULL,
                PRIMARY KEY(account_id, identity_key, folder_server_id)
            );
        """)
        try exec(handle, """
            CREATE TABLE IF NOT EXISTS sync_checkpoints(
                account_id      TEXT NOT NULL,
                scope           TEXT NOT NULL,
                cursor          TEXT NOT NULL,
                bootstrap_state TEXT NOT NULL DEFAULT '',
                run_id          TEXT,
                committed_at    INTEGER NOT NULL,
                PRIMARY KEY(account_id, scope)
            );
        """)
        try exec(handle, """
            CREATE TABLE IF NOT EXISTS capture_runs(
                run_id      TEXT PRIMARY KEY,
                account_id  TEXT NOT NULL,
                selection   TEXT NOT NULL DEFAULT '',
                state       TEXT NOT NULL,
                started_at  INTEGER NOT NULL,
                finished_at INTEGER
            );
        """)
        try exec(handle, """
            CREATE TABLE IF NOT EXISTS capture_items(
                run_id         TEXT NOT NULL,
                account_id     TEXT NOT NULL,
                identity_key   TEXT NOT NULL,
                state          TEXT NOT NULL,
                email_id       TEXT,
                sha256         TEXT,
                bytes          INTEGER,
                representation TEXT,
                error          TEXT,
                recorded_at    INTEGER NOT NULL,
                PRIMARY KEY(run_id, identity_key)
            );
        """)
    }

    // MARK: Accounts

    /// The `sources.sha256` key of an account's pseudo-source: the SHA-256 of
    /// a fixed prefix and the account UUID. Stable, unique per account, and
    /// never mistaken for a file hash (the prefix is not a file).
    nonisolated static func connectedSourceKey(accountID: UUID) -> String {
        SHA256.hash(data: Data("mailin-connected-account:\(accountID.uuidString)".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    func saveConnectedAccount(_ r: ConnectedAccountRecord) throws {
        let db = try ensureDB()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let scopes = String(decoding: try encoder.encode(r.grantedScopes), as: UTF8.self)
        let modes = String(decoding: try encoder.encode(r.enabledModes), as: UTF8.self)
        try exec(db, SQLiteHygiene.beginWrite)
        do {
            // The account's messages hang under one archive source, so the
            // folder sidebar and the source list name the account.
            let sourceID = try registerSourceRow(db, SourceDescriptor(
                sha256: Self.connectedSourceKey(accountID: r.accountID), filename: r.displayIdentity,
                byteSize: 0, parser: "connected-\(r.provider.rawValue)", parserVersion: 1,
                accountID: r.accountID.uuidString, sourceKind: "connected"))
            let stmt = try prepare(db, """
                INSERT INTO mail_accounts(account_id, provider, issuer, tenant, host, port, login_name, display_identity,
                                          granted_scopes, enabled_modes, connection_state, source_id, created_at, updated_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(account_id) DO UPDATE SET
                    provider = excluded.provider, issuer = excluded.issuer, tenant = excluded.tenant,
                    host = excluded.host, port = excluded.port, login_name = excluded.login_name,
                    display_identity = excluded.display_identity, granted_scopes = excluded.granted_scopes,
                    enabled_modes = excluded.enabled_modes, connection_state = excluded.connection_state,
                    source_id = excluded.source_id, updated_at = excluded.updated_at;
            """)
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, r.accountID.uuidString)
            bindText(stmt, 2, r.provider.rawValue)
            bindText(stmt, 3, r.issuer)
            bindTextOrNull(stmt, 4, r.tenant)
            bindTextOrNull(stmt, 5, r.host)
            if let port = r.port { sqlite3_bind_int64(stmt, 6, Int64(port)) } else { sqlite3_bind_null(stmt, 6) }
            bindTextOrNull(stmt, 7, r.loginName)
            bindText(stmt, 8, r.displayIdentity)
            bindText(stmt, 9, scopes)
            bindText(stmt, 10, modes)
            bindText(stmt, 11, r.connectionState)
            sqlite3_bind_int64(stmt, 12, sourceID)
            sqlite3_bind_int64(stmt, 13, Int64(r.createdAt.timeIntervalSince1970))
            sqlite3_bind_int64(stmt, 14, Int64(r.updatedAt.timeIntervalSince1970))
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
            try exec(db, "COMMIT;")
        } catch {
            try? exec(db, "ROLLBACK;")
            throw error
        }
    }

    /// `registerSource` without its own statement boundary, for use inside a transaction.
    private func registerSourceRow(_ db: OpaquePointer, _ s: SourceDescriptor) throws -> Int64 {
        let upsert = try prepare(db, """
            INSERT INTO sources(sha256, filename, byte_size, parser, parser_version, account_id, imported_at, source_kind)
            VALUES (?,?,?,?,?,?,?,?)
            ON CONFLICT(sha256) DO UPDATE SET filename = excluded.filename;
        """)
        defer { sqlite3_finalize(upsert) }
        bindText(upsert, 1, s.sha256); bindText(upsert, 2, s.filename)
        sqlite3_bind_int64(upsert, 3, Int64(s.byteSize)); bindText(upsert, 4, s.parser)
        sqlite3_bind_int64(upsert, 5, Int64(s.parserVersion)); bindTextOrNull(upsert, 6, s.accountID)
        sqlite3_bind_int64(upsert, 7, Int64(Date().timeIntervalSince1970)); bindText(upsert, 8, s.sourceKind)
        guard sqlite3_step(upsert) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
        let lookup = try prepare(db, "SELECT source_id FROM sources WHERE sha256 = ?;")
        defer { sqlite3_finalize(lookup) }
        bindText(lookup, 1, s.sha256)
        guard try stepRow(lookup, db) else { throw SQLiteStoreError.step("source row vanished after upsert") }
        return sqlite3_column_int64(lookup, 0)
    }

    func connectedAccounts() throws -> [ConnectedAccountRecord] {
        let db = try ensureDB()
        let stmt = try prepare(db, """
            SELECT account_id, provider, issuer, tenant, host, port, login_name, display_identity,
                   granted_scopes, enabled_modes, connection_state, created_at, updated_at, source_id
            FROM mail_accounts ORDER BY created_at, account_id;
        """)
        defer { sqlite3_finalize(stmt) }
        let decoder = JSONDecoder()
        var out: [ConnectedAccountRecord] = []
        while try stepRow(stmt, db) {
            guard let id = columnUUID(stmt, 0) else { throw SQLiteStoreError.step("mail_accounts row with an invalid account id") }
            guard let provider = MailProviderKind(rawValue: columnText(stmt, 1)) else {
                throw SQLiteStoreError.step("mail_accounts row \(id) names an unknown provider “\(columnText(stmt, 1))”")
            }
            func optional(_ i: Int32) -> String? { sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : columnText(stmt, i) }
            var record = ConnectedAccountRecord(
                accountID: id, provider: provider, issuer: columnText(stmt, 2), tenant: optional(3), host: optional(4),
                port: sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 5)),
                loginName: optional(6), displayIdentity: columnText(stmt, 7),
                grantedScopes: try decoder.decode([String].self, from: Data(columnText(stmt, 8).utf8)),
                enabledModes: try decoder.decode([String].self, from: Data(columnText(stmt, 9).utf8)),
                connectionState: columnText(stmt, 10),
                createdAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 11))),
                updatedAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 12))))
            record.archiveSourceID = sqlite3_column_type(stmt, 13) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 13)
            out.append(record)
        }
        return out
    }

    // MARK: Folders

    func upsertRemoteFolders(_ db: OpaquePointer, accountID: UUID, folders: [RemoteFolderOccurrence], now: Int64) throws {
        let stmt = try prepare(db, """
            INSERT INTO remote_folders(account_id, server_id, path, name, kind, special_use, uid_validity, observed_at)
            VALUES (?,?,?,?,?,?,?,?)
            ON CONFLICT(account_id, server_id) DO UPDATE SET
                path = excluded.path, name = excluded.name, kind = excluded.kind,
                special_use = COALESCE(excluded.special_use, remote_folders.special_use),
                uid_validity = COALESCE(excluded.uid_validity, remote_folders.uid_validity),
                observed_at = excluded.observed_at;
        """)
        defer { sqlite3_finalize(stmt) }
        for f in folders {
            sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
            bindText(stmt, 1, accountID.uuidString); bindText(stmt, 2, f.serverID)
            bindText(stmt, 3, f.displayPath)
            bindText(stmt, 4, f.displayPath.split(separator: "/").last.map(String.init) ?? f.displayPath)
            bindText(stmt, 5, f.kind.rawValue); bindTextOrNull(stmt, 6, f.specialUse)
            if let v = f.uidValidity { sqlite3_bind_int64(stmt, 7, Int64(v)) } else { sqlite3_bind_null(stmt, 7) }
            sqlite3_bind_int64(stmt, 8, now)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
        }
    }

    /// Records folders a provider listed (empty ones included) and declares
    /// them in the archive folder tree under the account's source.
    func recordRemoteFolders(accountID: UUID, folders: [RemoteFolderOccurrence]) throws {
        let db = try ensureDB()
        let sourceID = try accountSourceID(db, accountID: accountID)
        try exec(db, SQLiteHygiene.beginWrite)
        do {
            try upsertRemoteFolders(db, accountID: accountID, folders: folders, now: Int64(Date().timeIntervalSince1970))
            var cache: [String: Int64] = [:]
            for f in folders where !f.cleanPath.isEmpty {
                _ = try folderID(db, sourceID: sourceID, path: f.cleanPath, declared: true, cache: &cache)
            }
            try exec(db, "COMMIT;")
        } catch { try? exec(db, "ROLLBACK;"); throw error }
    }

    func accountSourceID(_ db: OpaquePointer, accountID: UUID) throws -> Int64 {
        let stmt = try prepare(db, "SELECT source_id FROM mail_accounts WHERE account_id = ?;")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, accountID.uuidString)
        guard try stepRow(stmt, db), sqlite3_column_type(stmt, 0) != SQLITE_NULL else {
            throw ConnectedArchiveError.unknownAccount(accountID)
        }
        return sqlite3_column_int64(stmt, 0)
    }

    // MARK: Runs and items

    func beginCaptureRun(accountID: UUID, selection: String) throws -> String {
        let db = try ensureDB()
        _ = try accountSourceID(db, accountID: accountID)
        let runID = UUID().uuidString
        let stmt = try prepare(db, "INSERT INTO capture_runs(run_id, account_id, selection, state, started_at) VALUES (?,?,?,'running',?);")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, runID); bindText(stmt, 2, accountID.uuidString); bindText(stmt, 3, selection)
        sqlite3_bind_int64(stmt, 4, Int64(Date().timeIntervalSince1970))
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
        return runID
    }

    func captureRunAccount(_ db: OpaquePointer, runID: String) throws -> (account: UUID, state: String) {
        let stmt = try prepare(db, "SELECT account_id, state FROM capture_runs WHERE run_id = ?;")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, runID)
        guard try stepRow(stmt, db), let id = columnUUID(stmt, 0) else { throw ConnectedArchiveError.runNotFound(runID) }
        return (id, columnText(stmt, 1))
    }

    /// Items the provider listed: `pending` until they reach a terminal state.
    /// An item already terminal in this run is left as it is.
    func recordDiscovered(runID: String, identities: [ProviderMessageIdentity]) throws {
        let db = try ensureDB()
        let run = try captureRunAccount(db, runID: runID)
        try exec(db, SQLiteHygiene.beginWrite)
        do {
            let stmt = try prepare(db, """
                INSERT OR IGNORE INTO capture_items(run_id, account_id, identity_key, state, recorded_at)
                VALUES (?,?,?,'pending',?);
            """)
            defer { sqlite3_finalize(stmt) }
            let now = Int64(Date().timeIntervalSince1970)
            for identity in identities {
                sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
                bindText(stmt, 1, runID); bindText(stmt, 2, run.account.uuidString)
                bindText(stmt, 3, try identity.key()); sqlite3_bind_int64(stmt, 4, now)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
            }
            try exec(db, "COMMIT;")
        } catch { try? exec(db, "ROLLBACK;"); throw error }
    }

    func writeCaptureItem(_ db: OpaquePointer, runID: String, accountID: UUID, key: String, state: String,
                          emailID: UUID?, sha256: String?, bytes: Int64?, representation: String?, error: String?) throws {
        let stmt = try prepare(db, """
            INSERT INTO capture_items(run_id, account_id, identity_key, state, email_id, sha256, bytes, representation, error, recorded_at)
            VALUES (?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(run_id, identity_key) DO UPDATE SET
                state = excluded.state, email_id = excluded.email_id, sha256 = excluded.sha256, bytes = excluded.bytes,
                representation = excluded.representation, error = excluded.error, recorded_at = excluded.recorded_at;
        """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, runID); bindText(stmt, 2, accountID.uuidString); bindText(stmt, 3, key); bindText(stmt, 4, state)
        bindTextOrNull(stmt, 5, emailID?.uuidString); bindTextOrNull(stmt, 6, sha256)
        if let bytes { sqlite3_bind_int64(stmt, 7, bytes) } else { sqlite3_bind_null(stmt, 7) }
        bindTextOrNull(stmt, 8, representation); bindTextOrNull(stmt, 9, error)
        sqlite3_bind_int64(stmt, 10, Int64(Date().timeIntervalSince1970))
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
    }

    func recordCaptureFailure(runID: String, identity: ProviderMessageIdentity, state: CaptureItemState, reason: String) throws {
        guard state == .failed || state == .unavailable else {
            throw ConnectedArchiveError.invalidIdentity("a failure must be recorded as failed or unavailable, not \(state.rawValue)")
        }
        let db = try ensureDB()
        let run = try captureRunAccount(db, runID: runID)
        let key = try identity.key()
        try exec(db, SQLiteHygiene.beginWrite)
        do {
            try writeCaptureItem(db, runID: runID, accountID: run.account, key: key, state: state.rawValue, emailID: nil,
                                 sha256: nil, bytes: nil, representation: nil, error: reason)
            try exec(db, "COMMIT;")
        } catch { try? exec(db, "ROLLBACK;"); throw error }
    }

    func finishCaptureRun(runID: String) throws -> CaptureRunReceipt {
        let db = try ensureDB()
        let run = try captureRunAccount(db, runID: runID)
        var counts: [String: Int] = [:]
        let stmt = try prepare(db, "SELECT state, COUNT(*) FROM capture_items WHERE run_id = ? GROUP BY state;")
        bindText(stmt, 1, runID)
        while try stepRow(stmt, db) { counts[columnText(stmt, 0)] = Int(sqlite3_column_int64(stmt, 1)) }
        sqlite3_finalize(stmt)
        var receipt = CaptureRunReceipt(runID: runID, accountID: run.account,
                                        stored: counts[CaptureItemState.stored.rawValue] ?? 0,
                                        alreadyPreserved: counts[CaptureItemState.alreadyPreserved.rawValue] ?? 0,
                                        locallyDeleted: counts[CaptureItemState.locallyDeleted.rawValue] ?? 0,
                                        failed: counts[CaptureItemState.failed.rawValue] ?? 0,
                                        unavailable: counts[CaptureItemState.unavailable.rawValue] ?? 0,
                                        pending: counts[CaptureItemState.pending.rawValue] ?? 0,
                                        state: .completed)
        receipt.state = receipt.pending == 0 && receipt.failed == 0 && receipt.unavailable == 0 ? .completed : .partial
        let update = try prepare(db, "UPDATE capture_runs SET state = ?, finished_at = ? WHERE run_id = ?;")
        defer { sqlite3_finalize(update) }
        bindText(update, 1, receipt.state.rawValue); sqlite3_bind_int64(update, 2, Int64(Date().timeIntervalSince1970))
        bindText(update, 3, runID)
        guard sqlite3_step(update) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
        return receipt
    }

    // MARK: Existing occurrence

    struct ExistingRemoteMessage {
        var emailID: UUID?
        var emailExists: Bool
        var digest: String
        var length: Int64
    }

    func existingRemoteMessage(accountID: UUID, key: String) throws -> ExistingRemoteMessage? {
        let db = try ensureDB()
        let stmt = try prepare(db, """
            SELECT r.email_id, r.blob_digest, r.blob_length, (SELECT 1 FROM emails e WHERE e.id = r.email_id)
            FROM remote_messages r WHERE r.account_id = ? AND r.identity_key = ?;
        """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, accountID.uuidString); bindText(stmt, 2, key)
        guard try stepRow(stmt, db) else { return nil }
        return ExistingRemoteMessage(emailID: columnUUID(stmt, 0), emailExists: sqlite3_column_type(stmt, 3) != SQLITE_NULL,
                                     digest: columnText(stmt, 1), length: sqlite3_column_int64(stmt, 2))
    }

    /// New memberships of an occurrence already preserved, and its item
    /// outcome, in one transaction. Returns how many memberships were new.
    func recordRepeatObservation(_ item: CaptureItem, key: String, runID: String, existing: ExistingRemoteMessage,
                                 state: CaptureItemState) throws -> Int {
        let db = try ensureDB()
        let sourceID = try accountSourceID(db, accountID: item.accountID)
        let now = Int64(Date().timeIntervalSince1970)
        try exec(db, SQLiteHygiene.beginWrite)
        do {
            try upsertRemoteFolders(db, accountID: item.accountID, folders: item.occurrences, now: now)
            let added = try writeMemberships(db, item: item, key: key, emailID: existing.emailExists ? existing.emailID : nil,
                                             sourceID: sourceID, now: now)
            let touch = try prepare(db, """
                UPDATE remote_messages SET last_seen_at = ?, remote_present = 1,
                    revision = COALESCE(?, revision), flags_json = ?
                WHERE account_id = ? AND identity_key = ?;
            """)
            defer { sqlite3_finalize(touch) }
            sqlite3_bind_int64(touch, 1, now); bindTextOrNull(touch, 2, item.metadata.revision)
            bindText(touch, 3, Self.json(item.metadata.flags)); bindText(touch, 4, item.accountID.uuidString); bindText(touch, 5, key)
            guard sqlite3_step(touch) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
            try writeCaptureItem(db, runID: runID, accountID: item.accountID, key: key, state: state.rawValue,
                                 emailID: existing.emailID, sha256: existing.digest, bytes: existing.length,
                                 representation: item.metadata.representation.rawValue, error: nil)
            try exec(db, "COMMIT;")
            return added
        } catch { try? exec(db, "ROLLBACK;"); throw error }
    }

    /// remote_memberships rows, plus archive folder memberships (and the
    /// legacy tag, FOLD-02 dual write) when the record exists.
    private func writeMemberships(_ db: OpaquePointer, item: CaptureItem, key: String, emailID: UUID?,
                                  sourceID: Int64, now: Int64) throws -> Int {
        let insert = try prepare(db, """
            INSERT OR IGNORE INTO remote_memberships(account_id, identity_key, folder_server_id, observed_at) VALUES (?,?,?,?);
        """)
        let folder = try prepare(db, "INSERT OR IGNORE INTO email_folders(email_id, folder_id) VALUES (?,?);")
        let tag = try prepare(db, "INSERT OR IGNORE INTO email_tags(email_id, tag) VALUES (?,?);")
        defer { sqlite3_finalize(insert); sqlite3_finalize(folder); sqlite3_finalize(tag) }
        var added = 0
        var cache: [String: Int64] = [:]
        for occurrence in item.occurrences {
            sqlite3_reset(insert); sqlite3_clear_bindings(insert)
            bindText(insert, 1, item.accountID.uuidString); bindText(insert, 2, key)
            bindText(insert, 3, occurrence.serverID); sqlite3_bind_int64(insert, 4, now)
            guard sqlite3_step(insert) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
            guard sqlite3_changes(db) == 1 else { continue }
            added += 1
            guard let emailID, !occurrence.cleanPath.isEmpty else { continue }
            let fid = try folderID(db, sourceID: sourceID, path: occurrence.cleanPath, declared: false, cache: &cache)
            sqlite3_reset(folder); sqlite3_clear_bindings(folder)
            bindText(folder, 1, emailID.uuidString); sqlite3_bind_int64(folder, 2, fid)
            guard sqlite3_step(folder) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
            sqlite3_reset(tag); sqlite3_clear_bindings(tag)
            bindText(tag, 1, emailID.uuidString); bindText(tag, 2, occurrence.cleanPath)
            guard sqlite3_step(tag) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
        }
        return added
    }

    nonisolated static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    // MARK: New record

    /// The record, its blob reference, the provider occurrence, its
    /// memberships and the item outcome — ONE transaction (insertBatch's,
    /// through `beforeCommit`). Message-ID never decides: `.preserveAll`, and
    /// Message-ID tombstones are not consulted (the provider identity is the
    /// occurrence key; a locally deleted occurrence stays deleted through its
    /// remote_messages row).
    func commitConnectedCapture(_ email: MBOXParser.RawEmail, blob: BlobReference, item: CaptureItem,
                                key: String, runID: String) throws -> Int {
        let db = try ensureDB()
        let sourceID = try accountSourceID(db, accountID: item.accountID)
        let sourceKey = Self.connectedSourceKey(accountID: item.accountID)
        var added = 0
        _ = try insertBatch([email], sourceFileHash: sourceKey, accountID: item.accountID.uuidString,
                            sourceID: sourceID, firstOrdinal: nil, dedupPolicy: .preserveAll,
                            respectTombstones: false, batchSize: 1, progress: nil,
                            rawBlobs: [email.id: blob]) { db, result in
            guard result.insertedIDs == [email.id] else {
                throw SQLiteStoreError.step("the connected record \(email.id) was not inserted")
            }
            added = try self.writeConnectedRows(db, emailID: email.id, blob: blob, item: item, key: key, runID: runID)
        }
        return added
    }

    /// The connected rows of a new record, inside insertBatch's transaction.
    private func writeConnectedRows(_ db: OpaquePointer, emailID: UUID, blob: BlobReference, item: CaptureItem,
                                    key: String, runID: String) throws -> Int {
        let now = Int64(Date().timeIntervalSince1970)
        var added = 0
        do {
            try upsertRemoteFolders(db, accountID: item.accountID, folders: item.occurrences, now: now)
            let row = try prepare(db, """
                INSERT INTO remote_messages(account_id, identity_key, provider, mailbox, provider_message_id, uid_validity, uid,
                    email_id, blob_digest, blob_length, representation, internal_date, revision, flags_json, metadata_json,
                    remote_present, first_captured_at, last_seen_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,1,?,?);
            """)
            defer { sqlite3_finalize(row) }
            let fields = item.identity.fields
            bindText(row, 1, item.accountID.uuidString); bindText(row, 2, key); bindText(row, 3, item.identity.provider.rawValue)
            bindTextOrNull(row, 4, fields.mailbox); bindTextOrNull(row, 5, fields.messageID)
            if let v = fields.uidValidity { sqlite3_bind_int64(row, 6, Int64(v)) } else { sqlite3_bind_null(row, 6) }
            if let v = fields.uid { sqlite3_bind_int64(row, 7, Int64(v)) } else { sqlite3_bind_null(row, 7) }
            bindText(row, 8, emailID.uuidString); bindText(row, 9, blob.digest); sqlite3_bind_int64(row, 10, blob.length)
            bindText(row, 11, item.metadata.representation.rawValue)
            if let d = item.metadata.internalDate { sqlite3_bind_int64(row, 12, Int64(d.timeIntervalSince1970)) } else { sqlite3_bind_null(row, 12) }
            bindTextOrNull(row, 13, item.metadata.revision)
            bindText(row, 14, Self.json(item.metadata.flags)); bindText(row, 15, Self.json(item.metadata.extra))
            sqlite3_bind_int64(row, 16, now); sqlite3_bind_int64(row, 17, now)
            guard sqlite3_step(row) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
            // The record's own folder memberships were written by insertBatch
            // from folderPath/tags; only the remote observations remain.
            let insert = try prepare(db, """
                INSERT OR IGNORE INTO remote_memberships(account_id, identity_key, folder_server_id, observed_at) VALUES (?,?,?,?);
            """)
            defer { sqlite3_finalize(insert) }
            for occurrence in item.occurrences {
                sqlite3_reset(insert); sqlite3_clear_bindings(insert)
                bindText(insert, 1, item.accountID.uuidString); bindText(insert, 2, key)
                bindText(insert, 3, occurrence.serverID); sqlite3_bind_int64(insert, 4, now)
                guard sqlite3_step(insert) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
                added += Int(sqlite3_changes(db))
            }
            try writeCaptureItem(db, runID: runID, accountID: item.accountID, key: key, state: CaptureItemState.stored.rawValue,
                                 emailID: emailID, sha256: blob.digest, bytes: blob.length,
                                 representation: item.metadata.representation.rawValue, error: nil)
        }
        return added
    }

    // MARK: Checkpoints

    func pendingItemCount(runID: String) throws -> Int {
        let db = try ensureDB()
        let stmt = try prepare(db, "SELECT COUNT(*) FROM capture_items WHERE run_id = ? AND state = 'pending';")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, runID)
        guard try stepRow(stmt, db) else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    func writeCheckpoint(accountID: UUID, scope: String, cursor: String, bootstrapState: String, runID: String) throws {
        let db = try ensureDB()
        let run = try captureRunAccount(db, runID: runID)
        guard run.account == accountID else { throw ConnectedArchiveError.accountMismatch }
        try exec(db, SQLiteHygiene.beginWrite)
        do {
            // Re-checked inside the write transaction: nothing can turn pending in between.
            let pending = try prepare(db, "SELECT COUNT(*) FROM capture_items WHERE run_id = ? AND state = 'pending';")
            bindText(pending, 1, runID)
            let count = try stepRow(pending, db) ? Int(sqlite3_column_int64(pending, 0)) : 0
            sqlite3_finalize(pending)
            guard count == 0 else { throw ConnectedArchiveError.itemsNotTerminal(runID: runID, pending: count) }
            let stmt = try prepare(db, """
                INSERT INTO sync_checkpoints(account_id, scope, cursor, bootstrap_state, run_id, committed_at)
                VALUES (?,?,?,?,?,?)
                ON CONFLICT(account_id, scope) DO UPDATE SET cursor = excluded.cursor,
                    bootstrap_state = excluded.bootstrap_state, run_id = excluded.run_id, committed_at = excluded.committed_at;
            """)
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, accountID.uuidString); bindText(stmt, 2, scope); bindText(stmt, 3, cursor)
            bindText(stmt, 4, bootstrapState); bindText(stmt, 5, runID); sqlite3_bind_int64(stmt, 6, Int64(Date().timeIntervalSince1970))
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
            try exec(db, "COMMIT;")
        } catch { try? exec(db, "ROLLBACK;"); throw error }
    }

    func readCheckpoint(accountID: UUID, scope: String) throws -> SyncCheckpoint? {
        let db = try ensureDB()
        let stmt = try prepare(db, "SELECT cursor, bootstrap_state, run_id, committed_at FROM sync_checkpoints WHERE account_id = ? AND scope = ?;")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, accountID.uuidString); bindText(stmt, 2, scope)
        guard try stepRow(stmt, db) else { return nil }
        return SyncCheckpoint(accountID: accountID, scope: scope, cursor: columnText(stmt, 0), bootstrapState: columnText(stmt, 1),
                              runID: columnText(stmt, 2), committedAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 3))))
    }

    // MARK: Restart reconciliation

    /// Runs left `running` by a process that ended become `interrupted`.
    func markRunningRunsInterrupted() throws -> Int {
        let db = try ensureDB()
        let stmt = try prepare(db, "UPDATE capture_runs SET state = 'interrupted', finished_at = ? WHERE state = 'running';")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(Date().timeIntervalSince1970))
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
        return Int(sqlite3_changes(db))
    }

    /// Every (account, identity, digest) a connected record vouches for —
    /// what restart reconciliation checks against the blob tier.
    func remoteMessageDigests() throws -> [(account: UUID, key: String, digest: String, emailID: UUID?)] {
        let db = try ensureDB()
        let stmt = try prepare(db, "SELECT account_id, identity_key, blob_digest, email_id FROM remote_messages;")
        defer { sqlite3_finalize(stmt) }
        var out: [(UUID, String, String, UUID?)] = []
        while try stepRow(stmt, db) {
            guard let account = columnUUID(stmt, 0) else { continue }
            out.append((account, columnText(stmt, 1), columnText(stmt, 2), columnUUID(stmt, 3)))
        }
        return out
    }

    func markRemotePresence(accountID: UUID, key: String, bytesMissing: Bool) throws {
        let db = try ensureDB()
        let stmt = try prepare(db, "UPDATE remote_messages SET metadata_json = json_set(metadata_json, '$.mailinBytesMissing', ?) WHERE account_id = ? AND identity_key = ?;")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, bytesMissing ? "true" : "false"); bindText(stmt, 2, accountID.uuidString); bindText(stmt, 3, key)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
    }

    // MARK: Provenance

    func connectedProvenance(emailID: UUID) throws -> ConnectedProvenance? {
        let db = try ensureDB()
        let stmt = try prepare(db, """
            SELECT r.account_id, r.identity_key, r.provider, r.mailbox, r.provider_message_id, r.uid_validity, r.uid,
                   r.blob_digest, r.blob_length, r.representation, r.internal_date, r.first_captured_at,
                   a.issuer, a.tenant, a.host, a.display_identity
            FROM remote_messages r LEFT JOIN mail_accounts a ON a.account_id = r.account_id
            WHERE r.email_id = ?;
        """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, emailID.uuidString)
        guard try stepRow(stmt, db), let account = columnUUID(stmt, 0) else { return nil }
        func optional(_ i: Int32) -> String? { sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : columnText(stmt, i) }
        let key = columnText(stmt, 1)
        var provenance = ConnectedProvenance(
            emailID: emailID, accountID: account, provider: columnText(stmt, 2), identityKey: key,
            mailbox: optional(3), providerMessageID: optional(4),
            uidValidity: sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : UInt32(truncatingIfNeeded: sqlite3_column_int64(stmt, 5)),
            uid: sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : UInt32(truncatingIfNeeded: sqlite3_column_int64(stmt, 6)),
            sha256: columnText(stmt, 7), byteCount: sqlite3_column_int64(stmt, 8), representation: columnText(stmt, 9),
            internalDate: sqlite3_column_type(stmt, 10) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 10))),
            firstCapturedAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 11))),
            issuer: optional(12) ?? "", tenant: optional(13), host: optional(14), displayIdentity: optional(15) ?? "",
            memberships: [])
        let members = try prepare(db, """
            SELECT m.folder_server_id, COALESCE(f.path, m.folder_server_id) FROM remote_memberships m
            LEFT JOIN remote_folders f ON f.account_id = m.account_id AND f.server_id = m.folder_server_id
            WHERE m.account_id = ? AND m.identity_key = ? ORDER BY 2;
        """)
        defer { sqlite3_finalize(members) }
        bindText(members, 1, account.uuidString); bindText(members, 2, key)
        while try stepRow(members, db) { provenance.memberships.append(columnText(members, 1)) }
        return provenance
    }

    /// Row counts of the v26 tables (tests, Health).
    func connectedTableCounts() throws -> [String: Int] {
        let db = try ensureDB()
        var out: [String: Int] = [:]
        for t in ["mail_accounts", "remote_folders", "remote_messages", "remote_memberships",
                  "sync_checkpoints", "capture_runs", "capture_items"] {
            out[t] = try scalarInt(db, "SELECT COUNT(*) FROM \(t);")
        }
        return out
    }
}
