//
//  SQLiteEmailStore+ConnectedLifecycle.swift
//  ArchiveCore
//
//  Plan v4 V4-12 (§7): the archive side of the connected-mail lifecycle.
//
//   • Account removal keeps archived mail by default. The separate, explicit
//     "delete this account's archived mail" is planned first (affected count,
//     held records excluded, blobs shared with other accounts or imports
//     kept — rule 4) and refuses to run when the count changed since it was
//     shown. Only blobs no other record and no other account references are
//     removed; accounts A and C are never touched.
//   • The account's "live cache" (sync cursors and the queue of listed but
//     not yet captured items) can be dropped without touching preserved
//     mail or its provenance; a later reconnect reconciles from scratch
//     without duplicates (the provider identity is the occurrence key).
//   • A clean-profile restore marks every connected account
//     `needsReauthorisation` — credentials are never in a backup.
//   • Earlier, incomplete online captures (pre-v26 Gmail imports with no
//     source, Outlook imports with a pseudo-source built from fields) are
//     identified, page by page, for source-based recapture; the comparison
//     reads both records and never replaces or deletes the old one.
//
//  No schema change: everything reads and writes existing tables.
//

import CryptoKit
import Foundation
import SQLite3

// MARK: - Public types

/// What deleting one account's archived mail would do — shown before it runs.
public struct ConnectedAccountArchiveSummary: Sendable, Equatable {
    public var accountID: UUID
    /// Records of this account in the archive.
    public var records: Int
    /// Of those, under a legal hold: never deleted by the account deletion.
    public var held: Int
    /// What the deletion removes (records − held − keptOnlyCopy).
    public var deletable: Int
    /// Raw-message blobs only these records reference (removed with them).
    public var exclusiveBlobs: Int
    public var exclusiveBytes: Int64
    /// Blobs another account, an imported file or a held record also uses (kept).
    public var sharedBlobs: Int
    /// Records kept because deleting them would remove mail that is visible
    /// nowhere else: a duplicate survivor whose other copies are in the Trash
    /// (duplicate cleanup carried their account link to it), a record of an
    /// imported file or another account that this account's copy was merged
    /// into, or a record another account also holds. Stated apart from `held`.
    public var keptOnlyCopy: Int = 0
}

public struct ConnectedAccountArchiveDeletion: Sendable, Equatable {
    public var accountID: UUID
    /// Archive record ids removed (the caller removes them from the search index).
    public var deletedEmailIDs: [UUID]
    public var heldKept: Int
    /// Records kept as the only visible copy (see `ConnectedAccountArchiveSummary.keptOnlyCopy`).
    public var keptOnlyCopy: Int = 0
    public var blobsRemoved: Int
    public var bytesReclaimed: Int64
    public var blobsKeptShared: Int
}

public enum ConnectedLifecycleError: LocalizedError, Equatable {
    /// The affected count changed between the summary shown and the run.
    case countChanged(shown: Int, now: Int)

    public var errorDescription: String? {
        switch self {
        case .countChanged(let shown, let now):
            return "The account now has \(now) messages to delete, not the \(shown) shown. Nothing was deleted; review the new count."
        }
    }
}

/// One record an earlier (pre-v4) online import left incomplete.
public struct LegacyOnlineCapture: Sendable, Equatable {
    public enum Kind: String, Sendable, Codable {
        /// Old Gmail import: fields only, no message source (rawSource "").
        case gmailWithoutSource
        /// Old Outlook import: a pseudo-source rebuilt from Graph fields.
        case outlookPseudoSource
        /// No source and no provider sign — listed, never matched automatically.
        case noSourceUnknownOrigin
    }
    public var emailID: UUID
    public var kind: Kind
    public var messageID: String?
    public var subject: String
    public var date: Date
}

/// The fields a recapture comparison shows side by side.
public struct ArchivedMessageSummary: Sendable, Equatable {
    public var emailID: UUID
    public var messageID: String?
    public var subject: String
    public var from: String
    public var date: Date
    /// SHA-256 of the body text with whitespace runs collapsed.
    public var bodyTextSHA256: String
    public var attachmentNames: [String]
    /// SHA-256 of the stored message source; nil when the record has none.
    public var sourceSHA256: String?
}

/// V4-12: whether an archive write failed because the volume is full — the
/// sync engine then pauses the account (`diskFull`) instead of failing it,
/// even when the volume's free-space figure is optimistic.
public enum ArchiveWriteError {
    public static func isOutOfSpace(_ error: Error) -> Bool {
        switch error {
        case ConnectedArchiveError.volumeFull: return true
        case BlobStoreError.outOfSpace: return true
        case let sqlite as SQLiteStoreError:
            // SQLITE_FULL's message (sqlite3_errmsg is not localised).
            return (sqlite.errorDescription ?? "").contains("database or disk is full")
        default:
            return outOfSpace(error as NSError)
        }
    }

    private static func outOfSpace(_ e: NSError) -> Bool {
        if e.domain == NSPOSIXErrorDomain && e.code == Int(ENOSPC) { return true }
        if e.domain == NSCocoaErrorDomain && e.code == NSFileWriteOutOfSpaceError { return true }
        if let underlying = e.userInfo[NSUnderlyingErrorKey] as? NSError { return outOfSpace(underlying) }
        return false
    }
}

// MARK: - Store

extension SQLiteEmailStore {

    private func optionalText(_ stmt: OpaquePointer?, _ i: Int32) -> String? {
        sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : columnText(stmt, i)
    }

    // MARK: Account archive

    /// The deletable set: the account's OWN records (captured under its
    /// source), not under a legal hold, and not the only visible copy of
    /// other mail — no other account links the record, no duplicate copy was
    /// merged into it (its link carried, or a copy with the same Message-ID
    /// sits in the Trash).
    private static let accountRecordsSQL = """
        SELECT r.email_id FROM remote_messages r JOIN emails e ON e.id = r.email_id
        WHERE r.account_id = ?1 AND NOT EXISTS (SELECT 1 FROM legal_holds h WHERE h.email_id = r.email_id)
          AND \(onlyCopyExclusionSQL)
    """

    /// True for a record the account deletion may remove without leaving
    /// other mail visible nowhere (`e`, `r` and `?1` in scope).
    private static let onlyCopyExclusionSQL = """
        e.source_id IS (SELECT a.source_id FROM mail_accounts a WHERE a.account_id = ?1)
          AND NOT EXISTS (SELECT 1 FROM remote_messages o WHERE o.email_id = r.email_id AND o.account_id <> ?1)
          AND NOT EXISTS (SELECT 1 FROM remote_messages c WHERE c.email_id = r.email_id
                          AND json_valid(c.metadata_json) AND json_extract(c.metadata_json, '$.mailinCarriedFrom') IS NOT NULL)
          AND NOT (COALESCE(e.message_id, '') <> '' AND EXISTS (
                SELECT 1 FROM emails t JOIN email_review_state ts ON ts.email_id = t.id AND ts.trashed = 1
                WHERE t.message_id = e.message_id AND t.id <> e.id))
    """

    func connectedAccountArchiveSummary(accountID: UUID) throws -> ConnectedAccountArchiveSummary {
        let db = try ensureDB()
        let a = accountID.uuidString
        func count(_ sql: String) throws -> Int {
            let stmt = try prepare(db, sql)
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, a)
            return try stepRow(stmt, db) ? Int(sqlite3_column_int64(stmt, 0)) : 0
        }
        let records = try count("SELECT COUNT(DISTINCT r.email_id) FROM remote_messages r JOIN emails e ON e.id = r.email_id WHERE r.account_id = ?1;")
        let held = try count("""
            SELECT COUNT(DISTINCT r.email_id) FROM remote_messages r JOIN emails e ON e.id = r.email_id
            WHERE r.account_id = ?1 AND EXISTS (SELECT 1 FROM legal_holds h WHERE h.email_id = r.email_id);
            """)
        let deletable = try count("SELECT COUNT(DISTINCT email_id) FROM (\(Self.accountRecordsSQL));")
        var exclusive = 0, shared = 0
        var bytes: Int64 = 0
        for (digest, length) in try accountDigests(db, accountID: accountID) {
            if try digestReferencedOutside(db, digest: digest, accountID: accountID) { shared += 1 } else { exclusive += 1; bytes += length }
        }
        return ConnectedAccountArchiveSummary(accountID: accountID, records: records, held: held, deletable: deletable,
                                              exclusiveBlobs: exclusive, exclusiveBytes: bytes, sharedBlobs: shared,
                                              keptOnlyCopy: max(0, records - held - deletable))
    }

    /// Distinct blob digests of the account's deletable records.
    private func accountDigests(_ db: OpaquePointer, accountID: UUID) throws -> [(String, Int64)] {
        let stmt = try prepare(db, """
            SELECT r.blob_digest, MAX(r.blob_length) FROM remote_messages r JOIN emails e ON e.id = r.email_id
            WHERE r.account_id = ?1 AND NOT EXISTS (SELECT 1 FROM legal_holds h WHERE h.email_id = r.email_id)
              AND \(Self.onlyCopyExclusionSQL)
            GROUP BY r.blob_digest ORDER BY r.blob_digest;
        """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, accountID.uuidString)
        var out: [(String, Int64)] = []
        while try stepRow(stmt, db) { out.append((columnText(stmt, 0), sqlite3_column_int64(stmt, 1))) }
        return out
    }

    /// Whether anything other than this account's deletable records uses the
    /// digest: another account's occurrence, an imported or held record.
    private func digestReferencedOutside(_ db: OpaquePointer, digest: String, accountID: UUID) throws -> Bool {
        let stmt = try prepare(db, """
            SELECT
              EXISTS (SELECT 1 FROM remote_messages r2 WHERE r2.blob_digest = ?1 AND r2.account_id <> ?2)
              OR EXISTS (SELECT 1 FROM email_bodies b WHERE b.raw_blob_digest = ?1 AND b.id NOT IN (\(Self.accountRecordsSQL.replacingOccurrences(of: "?1", with: "?2"))));
        """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, digest); bindText(stmt, 2, accountID.uuidString)
        return try stepRow(stmt, db) && sqlite3_column_int(stmt, 0) != 0
    }

    /// Deletes the account's archived mail (held records excepted) when the
    /// deletable count still equals `confirmedCount`, then the blobs nothing
    /// else references. Records are removed in pages; nothing of any other
    /// account is read for writing.
    func deleteConnectedAccountArchive(accountID: UUID, confirmedCount: Int, pageSize: Int = 1_000) throws -> ConnectedAccountArchiveDeletion {
        let before = try connectedAccountArchiveSummary(accountID: accountID)
        guard before.deletable == confirmedCount else { throw ConnectedLifecycleError.countChanged(shown: confirmedCount, now: before.deletable) }
        let db = try ensureDB()
        let digests = try accountDigests(db, accountID: accountID)
            .filter { try !digestReferencedOutside(db, digest: $0.0, accountID: accountID) }
        var deleted: [UUID] = []
        var after = ""
        while true {
            let stmt = try prepare(db, "SELECT DISTINCT email_id FROM (\(Self.accountRecordsSQL)) WHERE email_id > ?2 ORDER BY email_id LIMIT ?3;")
            bindText(stmt, 1, accountID.uuidString); bindText(stmt, 2, after); sqlite3_bind_int64(stmt, 3, Int64(max(1, pageSize)))
            var page: [UUID] = []
            while try stepRow(stmt, db) {
                after = columnText(stmt, 0)
                if let id = UUID(uuidString: after) { page.append(id) }
            }
            sqlite3_finalize(stmt)
            if page.isEmpty { break }
            // No Message-ID tombstones: removing an account's archive is not
            // "never import this message again" — a later import of the same
            // mail (a file, or the account reconnected) stores it as new.
            let refused = try deleteReportingHeld(ids: Set(page), recordTombstones: false)
            deleted.append(contentsOf: page.filter { !refused.contains($0) })
        }
        // The account's occurrence rows of records that no longer exist.
        try exec(db, SQLiteHygiene.beginWrite)
        do {
            for sql in ["DELETE FROM remote_memberships WHERE account_id = ?1 AND identity_key IN (SELECT identity_key FROM remote_messages r WHERE r.account_id = ?1 AND NOT EXISTS (SELECT 1 FROM emails e WHERE e.id = r.email_id));",
                        "DELETE FROM remote_messages WHERE account_id = ?1 AND NOT EXISTS (SELECT 1 FROM emails e WHERE e.id = remote_messages.email_id);"] {
                let stmt = try prepare(db, sql)
                defer { sqlite3_finalize(stmt) }
                bindText(stmt, 1, accountID.uuidString)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
            }
            try exec(db, "COMMIT;")
        } catch { try? exec(db, "ROLLBACK;"); throw error }
        // Blobs: re-checked against the whole archive after the delete.
        var removed = 0
        var reclaimed: Int64 = 0
        let check = try prepare(db, """
            SELECT EXISTS (SELECT 1 FROM remote_messages WHERE blob_digest = ?1)
                OR EXISTS (SELECT 1 FROM email_bodies WHERE raw_blob_digest = ?1);
        """)
        defer { sqlite3_finalize(check) }
        for (digest, length) in digests {
            sqlite3_reset(check); sqlite3_clear_bindings(check)
            bindText(check, 1, digest)
            guard try stepRow(check, db), sqlite3_column_int(check, 0) == 0 else { continue }
            let url = blobStore.url(for: digest)
            if (try? FileManager.default.removeItem(at: url)) != nil { removed += 1; reclaimed += length }
        }
        return ConnectedAccountArchiveDeletion(accountID: accountID, deletedEmailIDs: deleted, heldKept: before.held,
                                               keptOnlyCopy: before.keptOnlyCopy,
                                               blobsRemoved: removed, bytesReclaimed: reclaimed, blobsKeptShared: before.sharedBlobs)
    }

    /// Drops the account's sync cursors and its queue of listed-but-not-captured
    /// items. Preserved records, occurrences, memberships and receipts stay.
    func removeConnectedLiveCache(accountID: UUID) throws -> Int {
        let db = try ensureDB()
        var removed = 0
        try exec(db, SQLiteHygiene.beginWrite)
        do {
            for sql in ["DELETE FROM sync_checkpoints WHERE account_id = ?1;",
                        "DELETE FROM capture_items WHERE account_id = ?1 AND state = 'pending';"] {
                let stmt = try prepare(db, sql)
                defer { sqlite3_finalize(stmt) }
                bindText(stmt, 1, accountID.uuidString)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
                removed += Int(sqlite3_changes(db))
            }
            try exec(db, "COMMIT;")
        } catch { try? exec(db, "ROLLBACK;"); throw error }
        return removed
    }

    // MARK: Removed accounts in lists

    /// A removed account whose mail is gone: neither its own records nor any
    /// record its occurrences point at remain. (`a` = mail_accounts, `s` = sources.)
    private static let removedAndEmptySQL = """
        (a.account_id IS NULL OR a.connection_state = 'removed')
          AND NOT EXISTS (SELECT 1 FROM emails e WHERE e.source_id = s.source_id)
          AND NOT EXISTS (SELECT 1 FROM remote_messages r JOIN emails e2 ON e2.id = r.email_id WHERE r.account_id = a.account_id)
    """

    /// Archive sources of connected accounts that were removed and have no
    /// record left: the sidebar leaves out their Sources row and their folder
    /// tree (the server-listed folders, all empty). Nothing is deleted — a
    /// reconnect or a later capture shows them again.
    func hiddenConnectedSourceIDs() throws -> Set<Int64> {
        let db = try ensureDB()
        let stmt = try prepare(db, """
            SELECT s.source_id FROM sources s LEFT JOIN mail_accounts a ON a.source_id = s.source_id
            WHERE s.source_kind = 'connected' AND \(Self.removedAndEmptySQL);
        """)
        defer { sqlite3_finalize(stmt) }
        var out = Set<Int64>()
        while try stepRow(stmt, db) { out.insert(sqlite3_column_int64(stmt, 0)) }
        return out
    }

    /// The accounts a search can name: every account except a removed one
    /// with no mail left in the archive.
    func searchableConnectedAccounts() throws -> [ConnectedAccountRecord] {
        let hidden = try hiddenConnectedSourceIDs()
        return try connectedAccounts().filter { record in
            guard record.connectionState == "removed" else { return true }
            guard let source = record.archiveSourceID else { return false }
            return !hidden.contains(source)
        }
    }

    // MARK: Earlier online captures

    static let gmailSystemLabels: Set<String> = ["INBOX", "SENT", "DRAFT", "SPAM", "TRASH", "UNREAD", "STARRED", "IMPORTANT", "CHAT"]

    static func looksLikeGmailLabel(_ tag: String) -> Bool {
        gmailSystemLabels.contains(tag) || tag.hasPrefix("CATEGORY_") || tag.hasPrefix("Label_")
    }

    /// One page of records an earlier online import left without a real
    /// source, in id order (`after` = the last id of the previous page).
    /// Every such record is reached by paging — no cap.
    func legacyOnlineCaptures(after: UUID?, limit: Int) throws -> [LegacyOnlineCapture] {
        let db = try ensureDB()
        var out: [LegacyOnlineCapture] = []
        var cursor = after?.uuidString ?? ""
        // Records with a real source are skipped, so one SQL page may yield
        // fewer than `limit`; read on until `limit` are found or the table
        // ends. Reading stops right after the last returned record, so the
        // caller's next `after` resumes exactly there.
        var exhausted = false
        while out.count < limit && !exhausted {
            let stmt = try prepare(db, """
                SELECT e.id, e.message_id, e.subject, e.date, length(b.raw), b.raw_blob_digest,
                       (SELECT group_concat(t.tag, char(31)) FROM email_tags t WHERE t.email_id = e.id)
                FROM emails e LEFT JOIN email_bodies b ON b.id = e.id
                WHERE e.source_id IS NULL AND (e.account_id IS NULL OR e.account_id = '')
                  AND NOT EXISTS (SELECT 1 FROM remote_messages r WHERE r.email_id = e.id)
                  AND e.id > ?1
                ORDER BY e.id LIMIT ?2;
            """)
            bindText(stmt, 1, cursor); sqlite3_bind_int64(stmt, 2, Int64(max(1, limit)))
            var rows = 0
            while out.count < limit, try stepRow(stmt, db) {
                rows += 1
                cursor = columnText(stmt, 0)
                guard let id = UUID(uuidString: cursor) else { continue }
                let rawLength = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? 0 : sqlite3_column_int64(stmt, 4)
                let hasBlob = !(optionalText(stmt, 5) ?? "").isEmpty
                let tags = (optionalText(stmt, 6) ?? "").split(separator: "\u{1F}").map(String.init)
                let kind: LegacyOnlineCapture.Kind
                if tags.contains("Outlook") {
                    kind = .outlookPseudoSource
                } else if rawLength == 0 && !hasBlob {
                    kind = tags.contains(where: Self.looksLikeGmailLabel) ? .gmailWithoutSource : .noSourceUnknownOrigin
                } else {
                    continue      // a real source (sample data, old file imports): complete
                }
                out.append(LegacyOnlineCapture(emailID: id, kind: kind, messageID: optionalText(stmt, 1), subject: columnText(stmt, 2),
                                               date: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 3)))))
            }
            sqlite3_finalize(stmt)
            if out.count < limit && rows < max(1, limit) { exhausted = true }
        }
        return out
    }

    /// The account's connected records carrying `messageID` (a recapture candidate).
    func connectedRecords(accountID: UUID, messageID: String) throws -> [UUID] {
        let db = try ensureDB()
        let stmt = try prepare(db, """
            SELECT e.id FROM remote_messages r JOIN emails e ON e.id = r.email_id
            WHERE r.account_id = ?1 AND e.message_id = ?2 ORDER BY r.first_captured_at, e.id;
        """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, accountID.uuidString); bindText(stmt, 2, messageID)
        var out: [UUID] = []
        while try stepRow(stmt, db) { if let id = columnUUID(stmt, 0) { out.append(id) } }
        return out
    }

    static func normalisedBodyDigest(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return SHA256.hash(data: Data(collapsed.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func archivedMessageSummary(id: UUID) throws -> ArchivedMessageSummary? {
        guard let email = try fullEmail(id: id) else { return nil }
        let db = try ensureDB()
        let stmt = try prepare(db, "SELECT raw, raw_blob_digest FROM email_bodies WHERE id = ?1;")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, id.uuidString)
        var sourceSHA: String?
        if try stepRow(stmt, db) {
            if let digest = optionalText(stmt, 1), !digest.isEmpty {
                sourceSHA = digest
            } else if sqlite3_column_type(stmt, 0) != SQLITE_NULL, let bytes = sqlite3_column_blob(stmt, 0) {
                let count = Int(sqlite3_column_bytes(stmt, 0))
                if count > 0 {
                    sourceSHA = SHA256.hash(data: Data(bytes: bytes, count: count)).map { String(format: "%02x", $0) }.joined()
                }
            }
        }
        let body = email.plainBody.isEmpty ? email.htmlBody : email.plainBody
        return ArchivedMessageSummary(emailID: id, messageID: email.headers["Message-ID"], subject: email.headers["Subject"] ?? "",
                                      from: email.headers["From"] ?? "", date: MBOXParser.effectiveDate(for: email) ?? .distantPast,
                                      bodyTextSHA256: Self.normalisedBodyDigest(body), attachmentNames: email.attachments.map(\.filename),
                                      sourceSHA256: sourceSHA)
    }
}

// MARK: - Names

/// How connected accounts are named in lists (sidebar Sources, the Advanced
/// Search account picker): the address, and — when two accounts share the
/// address — the provider too, so they are two distinguishable rows.
public enum ConnectedAccountNaming {
    /// Provider names are product names, the same in every language.
    public static func providerName(_ provider: MailProviderKind) -> String {
        switch provider {
        case .gmail: return "Gmail"
        case .microsoftGraph: return "Outlook"
        case .imap: return "IMAP"
        }
    }

    /// The provider of a connected archive source (`connected-<provider>` parser), nil for a file.
    public static func provider(parser: String) -> MailProviderKind? {
        guard parser.hasPrefix("connected-") else { return nil }
        return MailProviderKind(rawValue: String(parser.dropFirst("connected-".count)))
    }

    public struct Item: Sendable, Equatable {
        public var key: String
        public var display: String
        public var provider: MailProviderKind?
        public init(key: String, display: String, provider: MailProviderKind?) {
            self.key = key; self.display = display; self.provider = provider
        }
    }

    /// One name per item. An address shared by several connected accounts
    /// gets " · <provider>"; if that is still shared (two Gmail accounts with
    /// one address), " · <provider> <n>" in list order.
    public static func distinctNames(_ items: [Item]) -> [String: String] {
        func norm(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces).lowercased() }
        var byDisplay: [String: Int] = [:]
        for item in items where item.provider != nil { byDisplay[norm(item.display), default: 0] += 1 }
        var withProvider: [String: Int] = [:]
        for item in items {
            guard let p = item.provider, (byDisplay[norm(item.display)] ?? 0) > 1 else { continue }
            withProvider[norm(item.display) + "\u{1F}" + p.rawValue, default: 0] += 1
        }
        var seen: [String: Int] = [:]
        var out: [String: String] = [:]
        for item in items {
            guard let p = item.provider, (byDisplay[norm(item.display)] ?? 0) > 1 else { out[item.key] = item.display; continue }
            let k = norm(item.display) + "\u{1F}" + p.rawValue
            var name = item.display + " · " + providerName(p)
            if (withProvider[k] ?? 0) > 1 {
                seen[k, default: 0] += 1
                name += " \(seen[k]!)"
            }
            out[item.key] = name
        }
        return out
    }
}

// MARK: - Restore

extension ArchiveBackup {
    /// A clean-profile restore: every connected account that was `connected`
    /// becomes `needsReauthorisation` in the restored database — the backup
    /// holds no credential, so the new device must sign in again (§7, T45).
    /// Returns how many accounts were marked. A database without the v26
    /// tables (an older backup) is left as it is.
    @discardableResult
    static func markConnectedAccountsNeedSignIn(databaseAt url: URL) throws -> Int {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let handle else {
            throw ArchiveBackupError.copyFailed("\(url.lastPathComponent) could not be opened to mark its accounts")
        }
        defer { sqlite3_close(handle) }
        var exists: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'mail_accounts';", -1, &exists, nil) == SQLITE_OK else {
            throw ArchiveBackupError.copyFailed(String(cString: sqlite3_errmsg(handle)))
        }
        let hasTable = sqlite3_step(exists) == SQLITE_ROW
        sqlite3_finalize(exists)
        guard hasTable else { return 0 }
        guard sqlite3_exec(handle, "UPDATE mail_accounts SET connection_state = 'needsReauthorisation' WHERE connection_state = 'connected';", nil, nil, nil) == SQLITE_OK else {
            throw ArchiveBackupError.copyFailed(String(cString: sqlite3_errmsg(handle)))
        }
        return Int(sqlite3_changes(handle))
    }
}

// MARK: - Sink API

extension ConnectedArchiveSink {
    /// V4-12: after the archive's drive came back, the open connection still
    /// points at the vanished mount — close it; the next call reopens against
    /// the remounted file. Check `ArchiveDriveGuard` first (MailConnectivity).
    public func reopenAfterDriveReturned() async {
        await store.reopenConnection()
    }

    public func accountArchiveSummary(accountID: UUID) async throws -> ConnectedAccountArchiveSummary {
        try await store.connectedAccountArchiveSummary(accountID: accountID)
    }

    /// The explicit, separate "delete this account's archived mail":
    /// `confirmedCount` is the deletable count the user was shown.
    public func deleteAccountArchive(accountID: UUID, confirmedCount: Int) async throws -> ConnectedAccountArchiveDeletion {
        try await store.deleteConnectedAccountArchive(accountID: accountID, confirmedCount: confirmedCount)
    }

    @discardableResult
    public func removeLiveCache(accountID: UUID) async throws -> Int {
        try await store.removeConnectedLiveCache(accountID: accountID)
    }

    public func legacyOnlineCaptures(after: UUID?, limit: Int) async throws -> [LegacyOnlineCapture] {
        try await store.legacyOnlineCaptures(after: after, limit: limit)
    }

    public func connectedRecords(accountID: UUID, messageID: String) async throws -> [UUID] {
        try await store.connectedRecords(accountID: accountID, messageID: messageID)
    }

    public func messageSummary(emailID: UUID) async throws -> ArchivedMessageSummary? {
        try await store.archivedMessageSummary(id: emailID)
    }

    /// Accounts a search can name (a removed account with no mail left is not one).
    public func searchableAccounts() async throws -> [ConnectedAccountRecord] {
        try await store.searchableConnectedAccounts()
    }
}
