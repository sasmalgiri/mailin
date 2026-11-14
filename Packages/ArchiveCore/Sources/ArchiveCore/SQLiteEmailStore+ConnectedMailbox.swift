//
//  SQLiteEmailStore+ConnectedMailbox.swift
//  ArchiveCore
//
//  Plan v4 V4-13 (§6 "unified inbox … individual account/folder views,
//  unread/flagged filters"): what the Mail workspace reads about captured
//  mail — every account's folders / labels with their counts, and pages of
//  captured messages with their account, folders and the read / flag state
//  the provider reported AT CAPTURE (shown as such; the live server state is
//  not claimed). Read-only; nothing here contacts a server.
//
//  Paging is keyset (date, account, identity) with the total counted
//  separately, so the UI states "N of M" and loads the next page on request —
//  no hidden cap (rule 6).
//

import Foundation
import SQLite3

/// One remote folder or label of an account, with what the archive holds for it.
public struct ConnectedFolderSummary: Sendable, Equatable, Identifiable {
    public var accountID: UUID
    public var serverID: String
    public var path: String
    public var kind: RemoteFolderOccurrence.Kind
    public var specialUse: String?
    /// Captured messages observed in this folder (archived records only).
    public var messages: Int
    /// Of those, unread when captured.
    public var unread: Int
    /// The user's capture selection (all folders are selected until changed).
    public var selected: Bool
    public var id: String { accountID.uuidString + "\u{1F}" + serverID }
}

/// One captured message as the Mail workspace lists it.
public struct ConnectedMailboxRow: Sendable, Equatable, Identifiable {
    public var emailID: UUID
    public var accountID: UUID
    public var identity: ProviderMessageIdentity
    public var subject: String
    public var from: String
    public var date: Date
    public var hasAttachments: Bool
    /// Read state reported by the provider when the message was captured (nil = not reported).
    public var isRead: Bool?
    public var isFlagged: Bool?
    /// False once a later sync found it gone from the server (the archived copy stays).
    public var onServer: Bool
    public var folderServerIDs: [String]
    /// Keyset cursor component.
    public var identityKey: String
    public var id: UUID { emailID }
}

public struct ConnectedMailboxQuery: Sendable, Equatable {
    /// nil = every account (the unified inbox).
    public var accountIDs: Set<UUID>?
    /// One folder / label of one account; nil = all of the accounts' mail.
    public var folderServerID: String?
    public var unreadOnly: Bool
    public var flaggedOnly: Bool
    public var pageSize: Int
    public init(accountIDs: Set<UUID>? = nil, folderServerID: String? = nil, unreadOnly: Bool = false,
                flaggedOnly: Bool = false, pageSize: Int = 200) {
        self.accountIDs = accountIDs; self.folderServerID = folderServerID; self.unreadOnly = unreadOnly
        self.flaggedOnly = flaggedOnly; self.pageSize = max(1, pageSize)
    }
}

public struct ConnectedMailboxCursor: Sendable, Equatable {
    public var date: Date
    public var accountID: UUID
    public var identityKey: String
}

public struct ConnectedMailboxPage: Sendable, Equatable {
    public var rows: [ConnectedMailboxRow]
    /// Every message matching the query (not just this page).
    public var total: Int
    /// nil = this was the last page.
    public var next: ConnectedMailboxCursor?
}

/// The provider's capture-time flags → read / flagged.
public enum ConnectedMessageFlags {
    public static func isRead(provider: MailProviderKind, flags: [String]) -> Bool? {
        switch provider {
        case .imap: return flags.contains { $0.caseInsensitiveCompare("\\Seen") == .orderedSame }
        case .microsoftGraph: return flags.contains("isRead")
        case .gmail: return !flags.contains("UNREAD")
        }
    }

    public static func isFlagged(provider: MailProviderKind, flags: [String]) -> Bool? {
        switch provider {
        case .imap: return flags.contains { $0.caseInsensitiveCompare("\\Flagged") == .orderedSame }
        case .microsoftGraph: return flags.contains("flagged")
        case .gmail: return flags.contains("STARRED")
        }
    }
}

extension SQLiteEmailStore {

    func connectedFolderSummaries(accountID: UUID) throws -> [ConnectedFolderSummary] {
        let db = try ensureDB()
        ensureConnectedMailboxIndexes(db)
        let stmt = try prepare(db, """
            SELECT f.server_id, f.path, f.kind, f.special_use, f.selected
            FROM remote_folders f WHERE f.account_id = ?1 ORDER BY f.path COLLATE NOCASE, f.server_id;
        """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, accountID.uuidString)
        var folders: [ConnectedFolderSummary] = []
        while try stepRow(stmt, db) {
            folders.append(ConnectedFolderSummary(
                accountID: accountID, serverID: columnText(stmt, 0), path: columnText(stmt, 1),
                kind: RemoteFolderOccurrence.Kind(rawValue: columnText(stmt, 2)) ?? .folder,
                specialUse: sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : columnText(stmt, 3),
                messages: 0, unread: 0, selected: sqlite3_column_int64(stmt, 4) != 0))
        }
        // Counts: archived records per folder, with their capture-time
        // flags — one SQL aggregate (50k messages: no row is decoded in Swift).
        let counts = try prepare(db, """
            SELECT m.folder_server_id, COUNT(*), SUM(CASE WHEN \(Self.unreadSQL) THEN 1 ELSE 0 END)
            FROM remote_memberships m
            JOIN remote_messages r ON r.account_id = m.account_id AND r.identity_key = m.identity_key
            JOIN emails e ON e.id = r.email_id
            WHERE m.account_id = ?1
            GROUP BY m.folder_server_id;
        """)
        defer { sqlite3_finalize(counts) }
        bindText(counts, 1, accountID.uuidString)
        var total: [String: Int] = [:], unread: [String: Int] = [:]
        while try stepRow(counts, db) {
            let folder = columnText(counts, 0)
            total[folder] = Int(sqlite3_column_int64(counts, 1))
            unread[folder] = Int(sqlite3_column_int64(counts, 2))
        }
        for i in folders.indices {
            folders[i].messages = total[folders[i].serverID] ?? 0
            folders[i].unread = unread[folders[i].serverID] ?? 0
        }
        return folders
    }

    func setConnectedFolderSelected(accountID: UUID, serverID: String, selected: Bool) throws {
        let db = try ensureDB()
        let stmt = try prepare(db, "UPDATE remote_folders SET selected = ?1 WHERE account_id = ?2 AND server_id = ?3;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, selected ? 1 : 0)
        bindText(stmt, 2, accountID.uuidString); bindText(stmt, 3, serverID)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
    }

    private static let mailboxDateSQL = "COALESCE(r.internal_date, e.date)"

    /// The capture-time flags as SQL, exactly `ConnectedMessageFlags`: the
    /// flag list is `r.flags_json` (an unreadable list reads as no flags).
    private static func hasFlagSQL(_ flag: String, caseInsensitive: Bool = false) -> String {
        let value = caseInsensitive ? "lower(fj.value)" : "fj.value"
        return "EXISTS (SELECT 1 FROM json_each(CASE WHEN json_valid(r.flags_json) THEN r.flags_json ELSE '[]' END) fj WHERE \(value) = '\(flag)')"
    }
    /// Unread when captured (`isRead == false`).
    static let unreadSQL = """
        (CASE r.provider WHEN 'gmail' THEN \(hasFlagSQL("UNREAD"))
                         WHEN 'graph' THEN NOT \(hasFlagSQL("isRead"))
                         ELSE NOT \(hasFlagSQL("\\seen", caseInsensitive: true)) END)
        """
    /// Flagged when captured (`isFlagged == true`).
    static let flaggedSQL = """
        (CASE r.provider WHEN 'gmail' THEN \(hasFlagSQL("STARRED"))
                         WHEN 'graph' THEN \(hasFlagSQL("flagged"))
                         ELSE \(hasFlagSQL("\\flagged", caseInsensitive: true)) END)
        """

    /// WHERE clause + bindings shared by the page and the count.
    private func mailboxFilter(_ q: ConnectedMailboxQuery) -> (sql: String, binds: [String]) {
        var clauses = ["r.email_id IS NOT NULL"]
        var binds: [String] = []
        if let ids = q.accountIDs {
            if ids.isEmpty { clauses.append("0") } else {
                clauses.append("r.account_id IN (\(Array(repeating: "?", count: ids.count).joined(separator: ",")))")
                binds += ids.map(\.uuidString).sorted()
            }
        }
        if let folder = q.folderServerID {
            clauses.append("EXISTS (SELECT 1 FROM remote_memberships m WHERE m.account_id = r.account_id AND m.identity_key = r.identity_key AND m.folder_server_id = ?)")
            binds.append(folder)
        }
        // In SQL, so a page reads only matching rows and the total is a COUNT.
        if q.unreadOnly { clauses.append(Self.unreadSQL) }
        if q.flaggedOnly { clauses.append(Self.flaggedSQL) }
        return (clauses.joined(separator: " AND "), binds)
    }

    func connectedMailboxPage(_ q: ConnectedMailboxQuery, after cursor: ConnectedMailboxCursor?) throws -> ConnectedMailboxPage {
        let db = try ensureDB()
        ensureConnectedMailboxIndexes(db)
        let filter = mailboxFilter(q)
        var sql = """
            SELECT r.email_id, r.account_id, r.identity_key, r.provider, r.mailbox, r.provider_message_id,
                   r.uid_validity, r.uid, r.flags_json, r.remote_present, \(Self.mailboxDateSQL),
                   e.subject, e.from_addr, e.has_attach
            FROM remote_messages r JOIN emails e ON e.id = r.email_id
            WHERE \(filter.sql)
        """
        var binds = filter.binds
        if let cursor {
            sql += " AND (\(Self.mailboxDateSQL) < ? OR (\(Self.mailboxDateSQL) = ? AND (r.account_id > ? OR (r.account_id = ? AND r.identity_key > ?))))"
            let t = String(Int64(cursor.date.timeIntervalSince1970))
            binds += [t, t, cursor.accountID.uuidString, cursor.accountID.uuidString, cursor.identityKey]
        }
        sql += " ORDER BY \(Self.mailboxDateSQL) DESC, r.account_id, r.identity_key;"
        let stmt = try prepare(db, sql)
        defer { sqlite3_finalize(stmt) }
        for (i, b) in binds.enumerated() {
            if i >= filter.binds.count, i < filter.binds.count + 2, let n = Int64(b) { sqlite3_bind_int64(stmt, Int32(i + 1), n) }
            else { bindText(stmt, Int32(i + 1), b) }
        }
        let decoder = JSONDecoder()
        var rows: [ConnectedMailboxRow] = []
        var more = false
        while try stepRow(stmt, db) {
            guard let emailID = columnUUID(stmt, 0), let accountID = columnUUID(stmt, 1) else { continue }
            let provider = MailProviderKind(rawValue: columnText(stmt, 3)) ?? .imap
            let flags = (try? decoder.decode([String].self, from: Data(columnText(stmt, 8).utf8))) ?? []
            let read = ConnectedMessageFlags.isRead(provider: provider, flags: flags)
            let flagged = ConnectedMessageFlags.isFlagged(provider: provider, flags: flags)
            if rows.count == q.pageSize { more = true; break }
            let mailbox = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : columnText(stmt, 4)
            let providerID = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : columnText(stmt, 5)
            var identity: ProviderMessageIdentity
            switch provider {
            case .gmail: identity = .gmail(messageID: providerID ?? "")
            case .microsoftGraph: identity = .graph(mailbox: mailbox ?? "me", immutableID: providerID ?? "")
            case .imap: identity = .imap(mailbox: mailbox ?? "", uidValidity: UInt32(clamping: sqlite3_column_int64(stmt, 6)),
                                         uid: UInt32(clamping: sqlite3_column_int64(stmt, 7)))
            }
            // V4-16: a Gmail-over-IMAP row has no mailbox / UID columns; its
            // identity is its key (X-GM-MSGID).
            if let keyed = try? ProviderMessageIdentity(key: columnText(stmt, 2)) { identity = keyed }
            rows.append(ConnectedMailboxRow(
                emailID: emailID, accountID: accountID, identity: identity, subject: columnText(stmt, 11),
                from: columnText(stmt, 12), date: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 10))),
                hasAttachments: sqlite3_column_int64(stmt, 13) != 0, isRead: read, isFlagged: flagged,
                onServer: sqlite3_column_int64(stmt, 9) != 0, folderServerIDs: [], identityKey: columnText(stmt, 2)))
        }
        // Folder memberships of the page's rows.
        if !rows.isEmpty {
            let m = try prepare(db, "SELECT folder_server_id FROM remote_memberships WHERE account_id = ? AND identity_key = ? ORDER BY folder_server_id;")
            defer { sqlite3_finalize(m) }
            for i in rows.indices {
                sqlite3_reset(m); sqlite3_clear_bindings(m)
                bindText(m, 1, rows[i].accountID.uuidString); bindText(m, 2, rows[i].identityKey)
                while try stepRow(m, db) { rows[i].folderServerIDs.append(columnText(m, 0)) }
            }
        }
        let next = more ? rows.last.map { ConnectedMailboxCursor(date: $0.date, accountID: $0.accountID, identityKey: $0.identityKey) } : nil
        return ConnectedMailboxPage(rows: rows, total: try connectedMailboxCount(q, db: db), next: next)
    }

    private func connectedMailboxCount(_ q: ConnectedMailboxQuery, db: OpaquePointer) throws -> Int {
        let filter = mailboxFilter(q)
        let stmt = try prepare(db, "SELECT COUNT(*) FROM remote_messages r JOIN emails e ON e.id = r.email_id WHERE \(filter.sql);")
        defer { sqlite3_finalize(stmt) }
        for (i, b) in filter.binds.enumerated() { bindText(stmt, Int32(i + 1), b) }
        return try stepRow(stmt, db) ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    /// V4-13 at 50k messages: the mailbox's lookups by account and date
    /// (the keyset sort's leading columns), by record, and memberships by
    /// folder. `CREATE INDEX IF NOT EXISTS` — additive and idempotent (no
    /// table or row changes, so no schema version); a read-only (Safe Mode)
    /// archive simply reads without them.
    func ensureConnectedMailboxIndexes(_ db: OpaquePointer) {
        for sql in Self.connectedMailboxIndexSQL { try? exec(db, sql) }
    }

    static let connectedMailboxIndexSQL = [
        "CREATE INDEX IF NOT EXISTS idx_remote_messages_mailbox ON remote_messages(account_id, internal_date DESC, identity_key);",
        "CREATE INDEX IF NOT EXISTS idx_remote_messages_date ON remote_messages(internal_date DESC, account_id, identity_key);",
        "CREATE INDEX IF NOT EXISTS idx_remote_memberships_folder ON remote_memberships(account_id, folder_server_id, identity_key);",
    ]
}

extension ConnectedArchiveSink {
    /// Every folder / label of the account with its captured and unread counts.
    public func folderSummaries(accountID: UUID) async throws -> [ConnectedFolderSummary] {
        try await store.connectedFolderSummaries(accountID: accountID)
    }

    /// Records the user's folder selection for capture (the next sync reads it).
    public func setFolderSelected(accountID: UUID, serverID: String, selected: Bool) async throws {
        try await store.setConnectedFolderSelected(accountID: accountID, serverID: serverID, selected: selected)
    }

    /// One page of captured mail (newest first) and the total that matches.
    public func mailboxPage(_ query: ConnectedMailboxQuery, after cursor: ConnectedMailboxCursor? = nil) async throws -> ConnectedMailboxPage {
        try await store.connectedMailboxPage(query, after: cursor)
    }
}
