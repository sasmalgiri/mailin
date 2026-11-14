//
//  RecoveryModel.swift
//  ArchiveCore
//
//  3.1 R1: how an email was found. Every email that is not plainly "live" carries
//  a recovery record — the kind (deleted folder, unpurged, orphan, carved …) and
//  the evidence that proves it (flag value, folder, byte offset, method). The
//  record lives in its own table (schema v20, additive), so the email's stored
//  bytes and seals are never altered by recovery.
//

import Foundation
import SQLite3

/// How an email was found in its source.
public enum RecoveryState: String, Codable, Sendable, CaseIterable {
    /// An ordinary, visible message.
    case live
    /// In a folder the mail client uses for deleted mail (Deleted Items, Trash,
    /// Recoverable Items, Gmail Trash).
    case deletedFolder
    /// Marked deleted by a flag, still listed (Apple Mail flag, mutt `D`).
    case flaggedDeleted
    /// Removed by the client but still in the file until compaction
    /// (Thunderbird `X-Mozilla-Status` 0x0008).
    case unpurged
    /// Present in the file but linked into no folder (PST/OST orphan node).
    case orphan
    /// Rebuilt from unallocated space or a raw stream.
    case carved
    /// A deletion record without a body (IBM Notes deletion stub).
    case deletionStub

    public var isRecovered: Bool { self != .live }
}

/// The evidence for a recovery state.
public struct RecoveryInfo: Codable, Sendable, Equatable {
    public var state: RecoveryState
    /// Detection method, e.g. "x-mozilla-status", "pst-folder", "pst-orphan",
    /// "pst-amap-scan", "mime-carve", "emlx-flags", "gmail-label", "nsf-stub".
    public var method: String
    /// Human-readable proof: "X-Mozilla-Status 0009", "folder Deleted Items".
    public var evidence: String
    /// Folder the message was found in, when known.
    public var folder: String?
    /// Byte offset in the source file, when known.
    public var offset: Int64?
    /// True when only part of the message could be rebuilt.
    public var partial: Bool

    public init(state: RecoveryState, method: String, evidence: String,
                folder: String? = nil, offset: Int64? = nil, partial: Bool = false) {
        self.state = state
        self.method = method
        self.evidence = evidence
        self.folder = folder
        self.offset = offset
        self.partial = partial
    }
}

/// Folder names mail clients use for deleted mail (lowercased), across the
/// interface languages mailin supports and the common clients.
public enum DeletedFolderNames {
    public static let names: Set<String> = [
        "deleted items", "deleted messages", "trash", "bin", "deleted", "recoverable items",
        "deletions", "purges", "versions", "[gmail]/trash", "[gmail]/bin", "papierkorb",
        "gelöschte elemente", "gelöschte objekte", "elementos eliminados", "papelera", "éléments supprimés",
        "corbeille", "posta eliminata", "cestino", "削除済みアイテム", "ゴミ箱", "지운 편지함", "휴지통",
        "itens excluídos", "lixeira", "已删除邮件", "已刪除的郵件", "垃圾箱", "हटाए गए आइटम",
    ]

    /// True when any component of a folder path is a deleted-mail folder.
    public static func isDeleted(path: String) -> Bool {
        let parts = path.lowercased().split(whereSeparator: { $0 == "/" || $0 == "\\" || $0 == "." })
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.contains { names.contains($0) } || names.contains(path.lowercased())
    }
}

/// Per-kind totals for a receipt or the sidebar.
/// String keys, so `[RecoveryState: Int]` encodes as a JSON object (sorted,
/// stable) — receipts hash their canonical JSON.
extension RecoveryState: CodingKeyRepresentable {}

public struct RecoveryCounts: Codable, Sendable, Equatable {
    public var byState: [RecoveryState: Int] = [:]
    public var partial = 0
    public init() {}
    public var recovered: Int { byState.filter { $0.key.isRecovered }.values.reduce(0, +) }
    public subscript(_ s: RecoveryState) -> Int { byState[s] ?? 0 }

    public mutating func add(_ info: RecoveryInfo?) {
        let s = info?.state ?? .live
        byState[s, default: 0] += 1
        if info?.partial == true { partial += 1 }
    }

    /// "312 live · 41 in deleted folders · 9 unpurged · 3 carved (1 partial)".
    public var summary: String {
        var parts: [String] = []
        for s in RecoveryState.allCases where self[s] > 0 {
            parts.append("\(self[s]) \(Self.label(s))")
        }
        if partial > 0 { parts.append("\(partial) partial") }
        return parts.isEmpty ? "0 emails" : parts.joined(separator: " · ")
    }

    public static func label(_ s: RecoveryState) -> String {
        switch s {
        case .live: return "live"
        case .deletedFolder: return "in deleted folders"
        case .flaggedDeleted: return "flagged deleted"
        case .unpurged: return "unpurged"
        case .orphan: return "orphaned"
        case .carved: return "carved"
        case .deletionStub: return "deletion stubs"
        }
    }
}

// MARK: - Store (schema v20 table `email_recovery`)

extension SQLiteEmailStore {
    /// v20 tables (additive, IF NOT EXISTS).
    func createSchemaV20(_ handle: OpaquePointer) throws {
        try exec(handle, """
            CREATE TABLE IF NOT EXISTS email_recovery(
                email_id TEXT PRIMARY KEY,
                state    TEXT NOT NULL,
                method   TEXT NOT NULL DEFAULT '',
                evidence TEXT NOT NULL DEFAULT '',
                folder   TEXT,
                offset   INTEGER,
                partial  INTEGER NOT NULL DEFAULT 0
            );
        """)
        try exec(handle, "CREATE INDEX IF NOT EXISTS idx_email_recovery_state ON email_recovery(state);")
        // S5: values a script adds to an email ("custom columns").
        try exec(handle, """
            CREATE TABLE IF NOT EXISTS email_custom_values(
                email_id TEXT NOT NULL,
                key      TEXT NOT NULL,
                value    TEXT NOT NULL,
                set_by   TEXT NOT NULL DEFAULT '',
                PRIMARY KEY(email_id, key)
            );
        """)
        try exec(handle, "CREATE INDEX IF NOT EXISTS idx_email_custom_key ON email_custom_values(key);")
        // S7: every script run, provable.
        try exec(handle, """
            CREATE TABLE IF NOT EXISTS script_runs(
                run_id       TEXT PRIMARY KEY,
                script_name  TEXT NOT NULL,
                script_sha   TEXT NOT NULL,
                script_ver   TEXT NOT NULL DEFAULT '',
                scope_json   TEXT NOT NULL DEFAULT '',
                fingerprint  TEXT NOT NULL DEFAULT '',
                processed    INTEGER NOT NULL DEFAULT 0,
                changes_json TEXT NOT NULL DEFAULT '',
                started_at   INTEGER NOT NULL,
                finished_at  INTEGER,
                started_by   TEXT NOT NULL DEFAULT ''
            );
        """)
    }

    /// Writes recovery records (only non-live ones are stored).
    func insertRecovery(_ db: OpaquePointer, emailID: String, info: RecoveryInfo) throws {
        guard info.state != .live else { return }
        let stmt = try prepare(db, """
            INSERT OR REPLACE INTO email_recovery(email_id, state, method, evidence, folder, offset, partial)
            VALUES (?,?,?,?,?,?,?);
        """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, emailID)
        bindText(stmt, 2, info.state.rawValue)
        bindText(stmt, 3, info.method)
        bindText(stmt, 4, info.evidence)
        bindTextOrNull(stmt, 5, info.folder)
        if let o = info.offset { sqlite3_bind_int64(stmt, 6, o) } else { sqlite3_bind_null(stmt, 6) }
        sqlite3_bind_int(stmt, 7, info.partial ? 1 : 0)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
    }

    /// Records (or replaces) the recovery state of existing emails.
    public func recoveryUpsert(_ rows: [UUID: RecoveryInfo]) throws {
        guard !rows.isEmpty else { return }
        let db = try ensureDB()
        try exec(db, SQLiteHygiene.beginWrite)
        do {
            for (id, info) in rows {
                if info.state == .live {
                    let del = try prepare(db, "DELETE FROM email_recovery WHERE email_id = ?;")
                    bindText(del, 1, id.uuidString)
                    _ = sqlite3_step(del)
                    sqlite3_finalize(del)
                } else {
                    try insertRecovery(db, emailID: id.uuidString, info: info)
                }
            }
            try exec(db, "COMMIT;")
        } catch { try? exec(db, "ROLLBACK;"); throw error }
    }

    /// Recovery records for the given emails (live emails have none).
    public func recovery(for ids: [UUID]) throws -> [UUID: RecoveryInfo] {
        guard !ids.isEmpty else { return [:] }
        let db = try ensureDB()
        var out: [UUID: RecoveryInfo] = [:]
        for chunk in ids.recoveryBatches(500) {
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let stmt = try prepare(db, "SELECT email_id, state, method, evidence, folder, offset, partial FROM email_recovery WHERE email_id IN (\(marks));")
            defer { sqlite3_finalize(stmt) }
            for (i, id) in chunk.enumerated() { bindText(stmt, Int32(i + 1), id.uuidString) }
            while try stepRow(stmt, db) {
                guard let id = columnUUID(stmt, 0),
                      let state = RecoveryState(rawValue: columnText(stmt, 1)) else { continue }
                let folder = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : columnText(stmt, 4)
                let offset = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 5)
                out[id] = RecoveryInfo(state: state, method: columnText(stmt, 2), evidence: columnText(stmt, 3),
                                       folder: folder, offset: offset, partial: sqlite3_column_int(stmt, 6) != 0)
            }
        }
        return out
    }

    /// Totals per recovery kind over the whole archive (live = everything else).
    public func recoveryCounts() throws -> RecoveryCounts {
        let db = try ensureDB()
        var c = RecoveryCounts()
        let stmt = try prepare(db, "SELECT state, COUNT(*), SUM(partial) FROM email_recovery WHERE email_id IN (SELECT id FROM emails) GROUP BY state;")
        defer { sqlite3_finalize(stmt) }
        var recovered = 0
        while try stepRow(stmt, db) {
            guard let s = RecoveryState(rawValue: columnText(stmt, 0)) else { continue }
            let n = Int(sqlite3_column_int64(stmt, 1))
            c.byState[s] = n
            c.partial += Int(sqlite3_column_int64(stmt, 2))
            recovered += n
        }
        let total = (try? scalarInt(db, "SELECT COUNT(*) FROM emails;")) ?? 0
        c.byState[.live] = max(0, total - recovered)
        return c
    }

    /// Ids of every email in one recovery state (or any recovered state).
    public func recoveryIDs(state: RecoveryState?) throws -> [UUID] {
        let db = try ensureDB()
        let sql = state == nil
            ? "SELECT email_id FROM email_recovery WHERE email_id IN (SELECT id FROM emails);"
            : "SELECT email_id FROM email_recovery WHERE state = ? AND email_id IN (SELECT id FROM emails);"
        let stmt = try prepare(db, sql)
        defer { sqlite3_finalize(stmt) }
        if let state { bindText(stmt, 1, state.rawValue) }
        var out: [UUID] = []
        while try stepRow(stmt, db) { if let id = columnUUID(stmt, 0) { out.append(id) } }
        return out
    }

    // MARK: Custom values (S5)

    public func customValuesSet(_ values: [UUID: [String: String]], setBy: String) throws {
        guard !values.isEmpty else { return }
        let db = try ensureDB()
        let stmt = try prepare(db, "INSERT OR REPLACE INTO email_custom_values(email_id, key, value, set_by) VALUES (?,?,?,?);")
        defer { sqlite3_finalize(stmt) }
        try exec(db, SQLiteHygiene.beginWrite)
        do {
            for (id, kv) in values {
                for (k, v) in kv {
                    sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
                    bindText(stmt, 1, id.uuidString); bindText(stmt, 2, k); bindText(stmt, 3, v); bindText(stmt, 4, setBy)
                    guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
                }
            }
            try exec(db, "COMMIT;")
        } catch { try? exec(db, "ROLLBACK;"); throw error }
    }

    public func customValues(for ids: [UUID]) throws -> [UUID: [String: String]] {
        guard !ids.isEmpty else { return [:] }
        let db = try ensureDB()
        var out: [UUID: [String: String]] = [:]
        for chunk in ids.recoveryBatches(500) {
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let stmt = try prepare(db, "SELECT email_id, key, value FROM email_custom_values WHERE email_id IN (\(marks));")
            defer { sqlite3_finalize(stmt) }
            for (i, id) in chunk.enumerated() { bindText(stmt, Int32(i + 1), id.uuidString) }
            while try stepRow(stmt, db) {
                guard let id = columnUUID(stmt, 0) else { continue }
                out[id, default: [:]][columnText(stmt, 1)] = columnText(stmt, 2)
            }
        }
        return out
    }

    // MARK: Script runs (S7)

    public struct ScriptRunRow: Sendable, Equatable {
        public var runID: String, name: String, sha256: String, version: String
        public var scopeJSON: String, fingerprint: String, processed: Int, changesJSON: String
        public var startedAt: Date, finishedAt: Date?, startedBy: String
        public init(runID: String, name: String, sha256: String, version: String, scopeJSON: String,
                    fingerprint: String, processed: Int, changesJSON: String, startedAt: Date,
                    finishedAt: Date?, startedBy: String) {
            self.runID = runID; self.name = name; self.sha256 = sha256; self.version = version
            self.scopeJSON = scopeJSON; self.fingerprint = fingerprint; self.processed = processed
            self.changesJSON = changesJSON; self.startedAt = startedAt; self.finishedAt = finishedAt
            self.startedBy = startedBy
        }
    }

    public func scriptRunRecord(_ r: ScriptRunRow) throws {
        let db = try ensureDB()
        let stmt = try prepare(db, """
            INSERT OR REPLACE INTO script_runs(run_id, script_name, script_sha, script_ver, scope_json, fingerprint,
                processed, changes_json, started_at, finished_at, started_by) VALUES (?,?,?,?,?,?,?,?,?,?,?);
        """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, r.runID); bindText(stmt, 2, r.name); bindText(stmt, 3, r.sha256); bindText(stmt, 4, r.version)
        bindText(stmt, 5, r.scopeJSON); bindText(stmt, 6, r.fingerprint); sqlite3_bind_int64(stmt, 7, Int64(r.processed))
        bindText(stmt, 8, r.changesJSON); sqlite3_bind_int64(stmt, 9, Int64(r.startedAt.timeIntervalSince1970))
        if let f = r.finishedAt { sqlite3_bind_int64(stmt, 10, Int64(f.timeIntervalSince1970)) } else { sqlite3_bind_null(stmt, 10) }
        bindText(stmt, 11, r.startedBy)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
    }

    public func scriptRuns(limit: Int = 200) throws -> [ScriptRunRow] {
        let db = try ensureDB()
        let stmt = try prepare(db, "SELECT run_id, script_name, script_sha, script_ver, scope_json, fingerprint, processed, changes_json, started_at, finished_at, started_by FROM script_runs ORDER BY started_at DESC LIMIT ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(limit))
        var out: [ScriptRunRow] = []
        while try stepRow(stmt, db) {
            let fin = sqlite3_column_type(stmt, 9) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 9)))
            out.append(ScriptRunRow(runID: columnText(stmt, 0), name: columnText(stmt, 1), sha256: columnText(stmt, 2),
                                    version: columnText(stmt, 3), scopeJSON: columnText(stmt, 4), fingerprint: columnText(stmt, 5),
                                    processed: Int(sqlite3_column_int64(stmt, 6)), changesJSON: columnText(stmt, 7),
                                    startedAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 8))),
                                    finishedAt: fin, startedBy: columnText(stmt, 10)))
        }
        return out
    }
}

private extension Array {
    func recoveryBatches(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: Swift.max(1, size)).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
