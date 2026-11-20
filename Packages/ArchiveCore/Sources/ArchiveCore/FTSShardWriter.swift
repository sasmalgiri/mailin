//
//  FTSShardWriter.swift
//  ArchiveCore
//
//  FAST-01 (owner decision 2026-11-20): the search-index write of one batch.
//
//  • The old per-email write (`FTSSearchIndex.insertWithHandle`) first ran
//    `DELETE FROM email_search WHERE email_id = ?`. `email_id` is an FTS5
//    UNINDEXED column, so that delete reads the whole year shard for every
//    message — the same fault as CLOSE-08 — and the import got slower the
//    larger the archive grew. Here the delete runs only when the shard's
//    register (`indexed_message`, primary key `email_id`, written in the same
//    transaction as every FTS row) says the message is already indexed, or
//    when the shard holds rows the register does not know (a legacy shard),
//    so re-indexing stays idempotent.
//  • The four statements are prepared once per shard group, not once per
//    message.
//  • Each year shard is its own SQLite file with its own handle (opened
//    FULLMUTEX), so groups for different years can be written at the same
//    time: one writer per shard, as many as the caller allows.
//

import Foundation
import SQLite3

enum FTSShardWriter {
    /// A shard handle handed to a parallel writer. Each handle is used by
    /// exactly one writer at a time; the box only states that to the compiler.
    struct Handle: @unchecked Sendable { let db: OpaquePointer }

    struct WriteError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Writes `emails` into one shard in one transaction (all or nothing).
    /// `shardHasUnregisteredRows`: the shard holds FTS rows without a register
    /// entry, so any id may already be present and the delete runs for every
    /// message (the behaviour of before).
    static func write(_ emails: [MBOXParser.RawEmail], into db: OpaquePointer,
                      shardHasUnregisteredRows: Bool) throws {
        func failure() -> WriteError {
            WriteError(message: sqlite3_errmsg(db).map { String(cString: $0) } ?? "unknown error")
        }
        func prepare(_ sql: String) throws -> OpaquePointer {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw failure() }
            return stmt
        }
        func exec(_ sql: String) throws {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        func bind(_ stmt: OpaquePointer, _ index: Int32, _ value: String) {
            sqlite3_bind_text(stmt, index, value, -1, transient)
        }

        let registered = try prepare("SELECT 1 FROM indexed_message WHERE email_id = ? LIMIT 1;")
        defer { sqlite3_finalize(registered) }
        let delete = try prepare("DELETE FROM email_search WHERE email_id = ?;")
        defer { sqlite3_finalize(delete) }
        let insert = try prepare("""
            INSERT INTO email_search (email_id, subject, sender, recipients, body)
            VALUES (?, ?, ?, ?, ?);
        """)
        defer { sqlite3_finalize(insert) }
        let register = try prepare("""
            INSERT OR REPLACE INTO indexed_message(
                email_id, indexed_revision, content_hash, indexed_at,
                indexed_text_bytes, total_text_bytes)
            VALUES (?, 1, NULL, ?, ?, ?);
        """)
        defer { sqlite3_finalize(register) }

        try exec(SQLiteHygiene.beginWrite)
        do {
            let now = Int64(Date().timeIntervalSince1970)
            for email in emails {
                let idString = email.id.uuidString

                // Idempotent: clear a prior row for this id — only when one can exist.
                var mayExist = shardHasUnregisteredRows
                if !mayExist {
                    sqlite3_reset(registered); sqlite3_clear_bindings(registered)
                    bind(registered, 1, idString)
                    switch sqlite3_step(registered) {
                    case SQLITE_ROW: mayExist = true
                    case SQLITE_DONE: mayExist = false
                    default: throw failure()
                    }
                }
                if mayExist {
                    sqlite3_reset(delete); sqlite3_clear_bindings(delete)
                    bind(delete, 1, idString)
                    guard sqlite3_step(delete) == SQLITE_DONE else { throw failure() }
                }

                // Same columns and text as `insertWithHandle`.
                let subject = email.headers["Subject"] ?? ""
                let sender = email.headers["From"] ?? ""
                let recipients = (email.headers["To"] ?? "") + " " + (email.headers["Cc"] ?? "")
                let body = email.plainBody.isEmpty
                    ? FTSSearchIndex.stripHTMLText(email.htmlBody)
                    : email.plainBody
                let coverage = FTSSearchIndex.indexableText(body)

                sqlite3_reset(insert); sqlite3_clear_bindings(insert)
                bind(insert, 1, idString)
                bind(insert, 2, subject)
                bind(insert, 3, sender)
                bind(insert, 4, recipients)
                bind(insert, 5, coverage.indexed)
                guard sqlite3_step(insert) == SQLITE_DONE else { throw failure() }

                sqlite3_reset(register); sqlite3_clear_bindings(register)
                bind(register, 1, idString)
                sqlite3_bind_int64(register, 2, now)
                sqlite3_bind_int64(register, 3, Int64(coverage.indexedBytes))
                sqlite3_bind_int64(register, 4, Int64(coverage.totalBytes))
                guard sqlite3_step(register) == SQLITE_DONE else { throw failure() }
            }
            try exec("COMMIT;")
        } catch {
            _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            throw error
        }
    }

    /// True when the shard holds FTS rows its register does not list — a shard
    /// written before the register existed. Checked once per opened shard.
    static func hasUnregisteredRows(_ db: OpaquePointer) -> Bool {
        var stmt: OpaquePointer?
        let sql = "SELECT (SELECT COUNT(*) FROM email_search) > (SELECT COUNT(*) FROM indexed_message);"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return true }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return true }   // unknown: keep the safe delete
        return sqlite3_column_int(stmt, 0) != 0
    }

    /// Writes several shard groups, up to `writers` at the same time. Every
    /// group commits or rolls back on its own; the first error is rethrown
    /// after all groups have finished, so no writer is left running.
    static func writeGroups(_ groups: [(handle: Handle, emails: [MBOXParser.RawEmail], unregistered: Bool)],
                            writers: Int) throws {
        guard groups.count > 1, writers > 1 else {
            for group in groups {
                try write(group.emails, into: group.handle.db, shardHasUnregisteredRows: group.unregistered)
            }
            return
        }
        final class Errors: @unchecked Sendable {
            private let lock = NSLock()
            private var first: Error?
            func record(_ error: Error) { lock.lock(); if first == nil { first = error }; lock.unlock() }
            var error: Error? { lock.lock(); defer { lock.unlock() }; return first }
        }
        struct Work: @unchecked Sendable { let groups: [(handle: Handle, emails: [MBOXParser.RawEmail], unregistered: Bool)] }
        let errors = Errors()
        let work = Work(groups: groups)
        let lanes = min(writers, groups.count)
        // Lane i writes groups i, i + lanes, i + 2·lanes …, so at most
        // `lanes` shards are written at once and no shard by two lanes.
        DispatchQueue.concurrentPerform(iterations: lanes) { lane in
            var index = lane
            while index < work.groups.count {
                let group = work.groups[index]
                do {
                    try write(group.emails, into: group.handle.db, shardHasUnregisteredRows: group.unregistered)
                } catch {
                    errors.record(error)
                }
                index += lanes
            }
        }
        if let error = errors.error { throw error }
    }
}
