//
//  RecoveryReport.swift
//  ArchiveCore
//
//  3.1 R10/R11: what recovery found, provably.
//
//  R10 — the recovery report streams every recovered email (no cap) with how
//  it was found and the evidence, in pages of `pageSize` rows.
//  R11 — deletion analysis: recovered mail set against the legal-hold dates.
//  The archive cannot know *when* a message was deleted (no mail format records
//  that reliably), so the analysis states only what the data proves: how many
//  recovered emails are dated before a hold on the same matter was placed (the
//  duty to preserve already covered them) and how many recovered emails are
//  themselves on hold. The report says this limit in words.
//

import Foundation
import SQLite3

public struct RecoveryReportRow: Sendable, Equatable {
    public var id: UUID
    public var date: Date
    public var from: String
    public var subject: String
    public var info: RecoveryInfo
}

public struct DeletionAnalysis: Sendable, Equatable {
    public struct Matter: Sendable, Equatable {
        public var matter: String
        public var holdPlacedAt: Date
        /// Recovered emails dated before the hold was placed.
        public var recoveredBeforeHold: Int
    }
    public var recovered = 0
    public var recoveredOnHold = 0
    public var matters: [Matter] = []
    /// Recovered emails per month of their Date header ("2024-03" → n).
    public var byMonth: [String: Int] = [:]

    /// R11: recovered mail per custodian and the week that holds most of it.
    public struct Custodian: Sendable, Equatable {
        public var custodian: String
        public var recovered: Int
        /// ISO year-week ("2024-09") of the busiest week and its count.
        public var busiestWeek: String
        public var busiestWeekCount: Int
        /// A burst: the busiest week holds at least half of this custodian's
        /// recovered mail, and at least `burstMinimum` emails.
        public var isBurst: Bool
    }
    public static let burstMinimum = 10
    public var custodians: [Custodian] = []
}

extension SQLiteEmailStore {
    /// One page of recovered emails, ordered by date then id (keyset paging).
    public func recoveryReportPage(state: RecoveryState?, after: (date: Int64, id: String)?,
                                   pageSize: Int = 1_000) throws -> [RecoveryReportRow] {
        let db = try ensureDB()
        var sql = """
            SELECT e.id, e.date, e.from_addr, e.subject, r.state, r.method, r.evidence, r.folder, r.offset, r.partial
            FROM email_recovery r JOIN emails e ON e.id = r.email_id
            WHERE 1 = 1
            """
        if state != nil { sql += " AND r.state = ?" }
        if after != nil { sql += " AND (e.date > ? OR (e.date = ? AND e.id > ?))" }
        sql += " ORDER BY e.date, e.id LIMIT ?;"
        let stmt = try prepare(db, sql)
        defer { sqlite3_finalize(stmt) }
        var i: Int32 = 1
        if let state { bindText(stmt, i, state.rawValue); i += 1 }
        if let after {
            sqlite3_bind_int64(stmt, i, after.date); sqlite3_bind_int64(stmt, i + 1, after.date)
            bindText(stmt, i + 2, after.id); i += 3
        }
        sqlite3_bind_int(stmt, i, Int32(pageSize))
        var out: [RecoveryReportRow] = []
        while try stepRow(stmt, db) {
            guard let id = columnUUID(stmt, 0), let s = RecoveryState(rawValue: columnText(stmt, 4)) else { continue }
            let folder = sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : columnText(stmt, 7)
            let offset = sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 8)
            out.append(RecoveryReportRow(
                id: id, date: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 1))),
                from: columnText(stmt, 2), subject: columnText(stmt, 3),
                info: RecoveryInfo(state: s, method: columnText(stmt, 5), evidence: columnText(stmt, 6),
                                   folder: folder, offset: offset, partial: sqlite3_column_int(stmt, 9) != 0)))
        }
        return out
    }

    /// Streams every recovered email through `body`, page by page.
    public func forEachRecovered(state: RecoveryState? = nil, pageSize: Int = 1_000,
                                 _ body: ([RecoveryReportRow]) throws -> Void) throws {
        var cursor: (date: Int64, id: String)?
        while true {
            let page = try recoveryReportPage(state: state, after: cursor, pageSize: pageSize)
            if page.isEmpty { return }
            try body(page)
            guard let last = page.last else { return }
            cursor = (Int64(last.date.timeIntervalSince1970), last.id.uuidString)
            if page.count < pageSize { return }
        }
    }

    /// R11: recovered mail against legal-hold dates, all counted in SQL.
    public func deletionAnalysis() throws -> DeletionAnalysis {
        let db = try ensureDB()
        var a = DeletionAnalysis()
        a.recovered = try scalarInt(db, "SELECT COUNT(*) FROM email_recovery WHERE email_id IN (SELECT id FROM emails);")
        a.recoveredOnHold = try scalarInt(db, """
            SELECT COUNT(*) FROM email_recovery r JOIN legal_holds h ON h.email_id = r.email_id
            WHERE r.email_id IN (SELECT id FROM emails);
            """)
        // Earliest hold per matter, and recovered mail dated before it.
        let m = try prepare(db, """
            WITH holds AS (SELECT matter, MIN(placed_at) AS t FROM legal_holds GROUP BY matter)
            SELECT holds.matter, holds.t,
                   (SELECT COUNT(*) FROM email_recovery r JOIN emails e ON e.id = r.email_id
                    WHERE e.date < holds.t)
            FROM holds ORDER BY holds.t;
            """)
        defer { sqlite3_finalize(m) }
        while try stepRow(m, db) {
            a.matters.append(.init(matter: columnText(m, 0),
                                   holdPlacedAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(m, 1))),
                                   recoveredBeforeHold: Int(sqlite3_column_int64(m, 2))))
        }
        let t = try prepare(db, """
            SELECT strftime('%Y-%m', e.date, 'unixepoch'), COUNT(*)
            FROM email_recovery r JOIN emails e ON e.id = r.email_id GROUP BY 1;
            """)
        defer { sqlite3_finalize(t) }
        while try stepRow(t, db) { a.byMonth[columnText(t, 0)] = Int(sqlite3_column_int64(t, 1)) }

        let w = try prepare(db, """
            SELECT c.custodian, strftime('%Y-%W', e.date, 'unixepoch') AS wk, COUNT(*)
            FROM email_recovery r JOIN emails e ON e.id = r.email_id
            JOIN custodian_assignments c ON c.email_id = r.email_id
            GROUP BY c.custodian, wk ORDER BY c.custodian, wk;
            """)
        defer { sqlite3_finalize(w) }
        var per: [String: (total: Int, week: String, top: Int)] = [:]
        while try stepRow(w, db) {
            let name = columnText(w, 0), week = columnText(w, 1), n = Int(sqlite3_column_int64(w, 2))
            var v = per[name] ?? (0, week, 0)
            v.total += n
            if n > v.top { v.top = n; v.week = week }
            per[name] = v
        }
        a.custodians = per.keys.sorted().map { k in
            let v = per[k]!
            return .init(custodian: k, recovered: v.total, busiestWeek: v.week, busiestWeekCount: v.top,
                         isBurst: v.top >= DeletionAnalysis.burstMinimum && v.top * 2 >= v.total)
        }
        return a
    }
}
