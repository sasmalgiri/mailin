//
//  SQLiteEmailStore+Entities.swift
//  ArchiveCore
//
//  3.0 B5: the lists Shortcuts shows as entities — every user tag and every
//  legal-hold matter with its exact email count, in one grouped query each
//  (never a loaded window).
//

import Foundation
import SQLite3

extension SQLiteEmailStore {
    struct TagCount: Sendable, Equatable { let tag: String; let count: Int }
    struct MatterCount: Sendable, Equatable { let matter: String; let count: Int; let firstPlaced: Date }

    /// Every user tag with the number of emails carrying it, A→Z.
    func userTagCounts() throws -> [TagCount] {
        let db = try ensureDB()
        let stmt = try prepare(db, "SELECT tag, COUNT(*) FROM email_user_tags GROUP BY tag ORDER BY tag;")
        defer { sqlite3_finalize(stmt) }
        var out: [TagCount] = []
        while try stepRow(stmt, db) { out.append(TagCount(tag: columnText(stmt, 0), count: Int(sqlite3_column_int64(stmt, 1)))) }
        return out
    }

    /// Every legal-hold matter with its held emails ("" = holds placed without
    /// a matter name), oldest first.
    func legalHoldMatters() throws -> [MatterCount] {
        let db = try ensureDB()
        let stmt = try prepare(db, "SELECT matter, COUNT(*), MIN(placed_at) FROM legal_holds GROUP BY matter ORDER BY MIN(placed_at);")
        defer { sqlite3_finalize(stmt) }
        var out: [MatterCount] = []
        while try stepRow(stmt, db) {
            out.append(MatterCount(matter: columnText(stmt, 0), count: Int(sqlite3_column_int64(stmt, 1)),
                                   firstPlaced: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 2)))))
        }
        return out
    }
}
