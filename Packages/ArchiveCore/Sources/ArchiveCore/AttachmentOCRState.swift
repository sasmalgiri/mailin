//
//  AttachmentOCRState.swift
//  ArchiveCore
//
//  E1 (FINAL_TODO_3_0_MAJOR.md Phase E): which emails the OCR pass has already read, so each
//  email with a scan is read once and an interrupted pass resumes. A small SQLite file beside
//  the archive (`SQLiteEmailStore.attachmentOCRStateURL`), not a table in `emails.db`: the
//  archive schema is unchanged, so an earlier build opens the archive as before (rules 14, 16)
//  and simply ignores this file. Losing the file costs only a repeat of the OCR work.
//

import Foundation
import SQLite3

final class AttachmentOCRState {
    private var db: OpaquePointer?

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw SQLiteStoreError.open(message)
        }
        sqlite3_busy_timeout(db, 5_000)
        try exec("CREATE TABLE IF NOT EXISTS done(email_id TEXT PRIMARY KEY);")
        try exec("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);")
    }

    deinit { sqlite3_close(db) }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteStoreError.step(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteStoreError.prepare(String(cString: sqlite3_errmsg(db)))
        }
        return stmt
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// The subset of `ids` already read.
    func done(among ids: [UUID]) throws -> Set<UUID> {
        guard !ids.isEmpty else { return [] }
        let stmt = try prepare("SELECT email_id FROM done WHERE email_id IN (\(Array(repeating: "?", count: ids.count).joined(separator: ",")));")
        defer { sqlite3_finalize(stmt) }
        for (i, id) in ids.enumerated() { sqlite3_bind_text(stmt, Int32(i + 1), id.uuidString, -1, Self.transient) }
        var out = Set<UUID>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0), let id = UUID(uuidString: String(cString: c)) { out.insert(id) }
        }
        return out
    }

    func markDone(_ ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        try exec("BEGIN IMMEDIATE;")
        do {
            let stmt = try prepare("INSERT OR IGNORE INTO done(email_id) VALUES (?);")
            defer { sqlite3_finalize(stmt) }
            for id in ids {
                sqlite3_reset(stmt)
                sqlite3_bind_text(stmt, 1, id.uuidString, -1, Self.transient)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteStoreError.step(String(cString: sqlite3_errmsg(db))) }
            }
            try exec("COMMIT;")
        } catch { try? exec("ROLLBACK;"); throw error }
    }

    func doneCount() throws -> Int {
        let stmt = try prepare("SELECT COUNT(*) FROM done;")
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    /// Where the second pass stopped (an email ID), so an interrupted pass resumes there.
    var cursor: String? {
        get {
            guard let stmt = try? prepare("SELECT value FROM meta WHERE key = 'cursor';") else { return nil }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
            return String(cString: c)
        }
        set {
            if let newValue {
                guard let stmt = try? prepare("INSERT INTO meta(key, value) VALUES ('cursor', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value;") else { return }
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_text(stmt, 1, newValue, -1, Self.transient)
                _ = sqlite3_step(stmt)
            } else {
                try? exec("DELETE FROM meta WHERE key = 'cursor';")
            }
        }
    }
}
