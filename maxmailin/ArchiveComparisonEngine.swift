@testable import ArchiveCore
//
//  ArchiveComparisonEngine.swift
//  maxmailin
//
//  Streamed full-archive comparison (v2.1 backlog #3). Compares the WHOLE
//  current archive with a second mailbox file without holding either side in
//  memory: each side is reduced to one small key row per message (Message-ID,
//  a fuzzy subject|sender|minute key, and the fields the list shows) in a
//  scratch SQLite database, the match is two set operations in SQL, and the
//  difference lists are read back in keyset pages.
//
//  Why a scratch database and not two dictionaries: the previous view held two
//  `[RawEmail]` arrays and was therefore capped at 2,000 messages per side,
//  with a notice that "full-archive comparison is not included". A 500 K
//  message archive against a 500 K mailbox is a few hundred megabytes of key
//  rows on disk and a constant amount of memory here.
//
//  Matching rules (unchanged from the array algorithm they replace):
//   1. Exact Message-ID, one-to-one.
//   2. Among the still-unmatched, subject + sender + date-minute, one-to-one.
//  A message with neither is "only in" its side. Sentiment is NOT computed —
//  it needs bodies, which this deliberately never reads.
//

import Foundation
import SQLite3
import os

final class ArchiveComparisonEngine: @unchecked Sendable {

    enum Side: String, Sendable { case a, b }

    enum Source: String, Sendable, CaseIterable {
        case onlyInA = "A"
        case onlyInB = "B"
        case common = "Both"
    }

    struct Totals: Sendable, Equatable {
        var countA = 0
        var countB = 0
        var common = 0
        var byMessageID = 0
        var byFuzzy = 0
        var onlyInA: Int { countA - common }
        var onlyInB: Int { countB - common }
    }

    struct SideStats: Sendable, Equatable {
        var total = 0
        var earliest: Date?
        var latest: Date?
        var uniqueSenders = 0
    }

    struct Row: Identifiable, Sendable, Equatable {
        let id: String
        let source: Source
        let subject: String
        let sender: String
        let date: Date
        let matchedSubject: String?
        let matchKind: String?
    }

    struct Cursor: Sendable, Equatable {
        let date: Date
        let id: String
    }

    enum EngineError: Error, CustomStringConvertible {
        case sqlite(String)
        var description: String {
            switch self { case .sqlite(let m): return "comparison scratch store: \(m)" }
        }
    }

    /// Up to this many second-archive messages are kept in full, so the AI
    /// summary can look at real text from side B; everything else is keys.
    static let sampleCap = 200

    private static let log = Logger(subsystem: "com.ecosanskriti.mailin", category: "ArchiveComparison")
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private let dataService: ArchiveDataService
    private let scratchURL: URL
    private var db: OpaquePointer?
    private(set) var sampleB: [MBOXParser.RawEmail] = []

    init(dataService: ArchiveDataService = .shared, scratchDirectory: URL? = nil) throws {
        self.dataService = dataService
        let dir = scratchDirectory ?? FileManager.default.temporaryDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        scratchURL = dir.appendingPathComponent("mailin-compare-\(UUID().uuidString).sqlite")
        var handle: OpaquePointer?
        guard sqlite3_open(scratchURL.path, &handle) == SQLITE_OK, let handle else {
            throw EngineError.sqlite("could not create \(scratchURL.lastPathComponent)")
        }
        db = handle
        try exec("""
            PRAGMA journal_mode = OFF; PRAGMA synchronous = OFF; PRAGMA temp_store = FILE;
            CREATE TABLE a(id TEXT PRIMARY KEY, mid TEXT, fuzzy TEXT NOT NULL, subject TEXT NOT NULL, sender TEXT NOT NULL, date INTEGER NOT NULL);
            CREATE TABLE b(id TEXT PRIMARY KEY, mid TEXT, fuzzy TEXT NOT NULL, subject TEXT NOT NULL, sender TEXT NOT NULL, date INTEGER NOT NULL);
            CREATE TABLE m(a_id TEXT PRIMARY KEY, b_id TEXT UNIQUE NOT NULL, kind TEXT NOT NULL);
            """)
    }

    deinit { close() }

    /// Closes and deletes the scratch database. Safe to call twice.
    func close() {
        if let db { sqlite3_close(db) }
        db = nil
        try? FileManager.default.removeItem(at: scratchURL)
    }

    // MARK: - Indexing

    /// Side A: every message in the current archive, from summary pages —
    /// never bodies. `progress` receives the running count.
    func indexCurrentArchive(progress: @Sendable (Int) -> Void = { _ in }) async throws {
        var count = 0
        // The service is main-actor bound; the stream it hands back is not,
        // so the key rows are built and inserted off the main actor.
        let service = dataService
        let stream = await MainActor.run { service.streamSummaries(batchSize: 500) }
        for try await batch in stream {
            try insert(side: .a, rows: batch.map { s in
                (s.id.uuidString, Self.normalisedMessageID(s.messageID),
                 Self.fuzzyKey(subject: s.subject, from: s.from, date: s.date),
                 s.subject, s.from, s.date)
            })
            count += batch.count
            progress(count)
        }
    }

    /// Side B: the second mailbox, streamed through the ordinary parser so
    /// every supported format (and container) works. Keeps the first
    /// `sampleCap` messages in full for the optional AI summary.
    func indexSecondArchive(url: URL, senderEmail: String,
                            progress: @Sendable (Int) -> Void = { _ in }) async throws {
        var count = 0
        _ = try await ParserFactory.parseStreamingCallback(
            fileURL: url, senderEmail: senderEmail, batchSize: 500
        ) { batch in
            try self.insert(side: .b, rows: batch.map { e in
                let subject = e.headers["Subject"] ?? ""
                let from = e.headers["From"] ?? ""
                let date = MBOXParser.parseDate(e.headers["Date"]) ?? Date(timeIntervalSince1970: 0)
                return (e.id.uuidString,
                        Self.normalisedMessageID(e.headers["Message-ID"] ?? e.headers["Message-Id"]),
                        Self.fuzzyKey(subject: subject, from: from, date: date),
                        subject, from, date)
            })
            if self.sampleB.count < Self.sampleCap {
                self.sampleB += batch.prefix(Self.sampleCap - self.sampleB.count)
            }
            count += batch.count
            progress(count)
        }
    }

    // MARK: - Matching

    /// Two passes, both one-to-one: exact Message-ID, then fuzzy among the
    /// rest. Idempotent — the match table is cleared first.
    func match() throws -> Totals {
        try exec("DELETE FROM m;")
        try exec("""
            CREATE INDEX IF NOT EXISTS a_mid ON a(mid) WHERE mid IS NOT NULL;
            CREATE INDEX IF NOT EXISTS b_mid ON b(mid) WHERE mid IS NOT NULL;
            CREATE INDEX IF NOT EXISTS a_fuzzy ON a(fuzzy);
            CREATE INDEX IF NOT EXISTS b_fuzzy ON b(fuzzy);
            CREATE INDEX IF NOT EXISTS a_date ON a(date DESC, id DESC);
            CREATE INDEX IF NOT EXISTS b_date ON b(date DESC, id DESC);
            """)
        try exec("""
            INSERT OR IGNORE INTO m(a_id, b_id, kind)
            SELECT a.id, b.id, 'message-id' FROM a JOIN b ON b.mid = a.mid WHERE a.mid IS NOT NULL;
            """)
        let byMessageID = try scalar("SELECT COUNT(*) FROM m;")
        try exec("""
            INSERT OR IGNORE INTO m(a_id, b_id, kind)
            SELECT a.id, b.id, 'fuzzy' FROM a JOIN b ON b.fuzzy = a.fuzzy
            WHERE a.id NOT IN (SELECT a_id FROM m) AND b.id NOT IN (SELECT b_id FROM m);
            """)
        let common = try scalar("SELECT COUNT(*) FROM m;")
        return Totals(countA: try scalar("SELECT COUNT(*) FROM a;"),
                      countB: try scalar("SELECT COUNT(*) FROM b;"),
                      common: common,
                      byMessageID: byMessageID,
                      byFuzzy: common - byMessageID)
    }

    // MARK: - Reading back

    func stats(_ side: Side) throws -> SideStats {
        let stmt = try prepare("SELECT COUNT(*), MIN(date), MAX(date), COUNT(DISTINCT lower(trim(sender))) FROM \(side.rawValue);")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return SideStats() }
        let total = Int(sqlite3_column_int64(stmt, 0))
        guard total > 0 else { return SideStats() }
        return SideStats(total: total,
                         earliest: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 1))),
                         latest: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 2))),
                         uniqueSenders: Int(sqlite3_column_int64(stmt, 3)))
    }

    /// One keyset page of the difference list, newest first. `filter == nil`
    /// interleaves all three sources by date.
    func page(filter: Source?, after cursor: Cursor?, limit: Int) throws -> [Row] {
        var sql = """
            SELECT id, source, subject, sender, date, matched_subject, kind FROM (
                SELECT a.id AS id, 'A' AS source, a.subject, a.sender, a.date, NULL AS matched_subject, NULL AS kind
                  FROM a WHERE a.id NOT IN (SELECT a_id FROM m)
                UNION ALL
                SELECT a.id, 'Both', a.subject, a.sender, a.date, b.subject, m.kind
                  FROM m JOIN a ON a.id = m.a_id JOIN b ON b.id = m.b_id
                UNION ALL
                SELECT b.id, 'B', b.subject, b.sender, b.date, NULL, NULL
                  FROM b WHERE b.id NOT IN (SELECT b_id FROM m)
            )
            WHERE 1 = 1
            """
        if filter != nil { sql += " AND source = ?" }
        if cursor != nil { sql += " AND (date < ? OR (date = ? AND id < ?))" }
        sql += " ORDER BY date DESC, id DESC LIMIT ?;"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        var idx: Int32 = 1
        if let filter { sqlite3_bind_text(stmt, idx, filter.rawValue, -1, Self.transient); idx += 1 }
        if let cursor {
            let d = Int64(cursor.date.timeIntervalSince1970)
            sqlite3_bind_int64(stmt, idx, d); idx += 1
            sqlite3_bind_int64(stmt, idx, d); idx += 1
            sqlite3_bind_text(stmt, idx, cursor.id, -1, Self.transient); idx += 1
        }
        sqlite3_bind_int(stmt, idx, Int32(limit))

        var rows: [Row] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(Row(
                id: text(stmt, 0),
                source: Source(rawValue: text(stmt, 1)) ?? .common,
                subject: text(stmt, 2),
                sender: text(stmt, 3),
                date: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 4))),
                matchedSubject: sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : text(stmt, 5),
                matchKind: sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : text(stmt, 6)))
        }
        return rows
    }

    /// IDs of "only in A" messages, newest first, for a bounded full-text
    /// sample (the AI summary); the caller hydrates them from the archive.
    func onlyInAIDs(limit: Int) throws -> [UUID] {
        let stmt = try prepare("SELECT id FROM a WHERE id NOT IN (SELECT a_id FROM m) ORDER BY date DESC, id DESC LIMIT ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        var ids: [UUID] = []
        while sqlite3_step(stmt) == SQLITE_ROW { if let u = UUID(uuidString: text(stmt, 0)) { ids.append(u) } }
        return ids
    }

    /// The retained side-B sample, reduced to messages that did not match.
    func onlyInBSample() throws -> [MBOXParser.RawEmail] {
        let stmt = try prepare("SELECT b_id FROM m;")
        defer { sqlite3_finalize(stmt) }
        var matched = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW { matched.insert(text(stmt, 0)) }
        return sampleB.filter { !matched.contains($0.id.uuidString) }
    }

    // MARK: - Keys

    static func normalisedMessageID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// subject | sender | minute — the same shape the array comparison used,
    /// with the date reduced to a minute bucket so both sides derive it from
    /// a parsed `Date` rather than from the raw header text.
    static func fuzzyKey(subject: String, from: String, date: Date) -> String {
        let s = subject.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let f = from.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let minute = Int64(date.timeIntervalSince1970) / 60
        return "\(s)|\(f)|\(minute)"
    }

    // MARK: - SQLite plumbing

    private typealias KeyRow = (id: String, mid: String?, fuzzy: String, subject: String, sender: String, date: Date)

    private func insert(side: Side, rows: [KeyRow]) throws {
        guard !rows.isEmpty else { return }
        try exec("BEGIN;")
        let stmt = try prepare("INSERT OR REPLACE INTO \(side.rawValue)(id, mid, fuzzy, subject, sender, date) VALUES (?,?,?,?,?,?);")
        defer { sqlite3_finalize(stmt) }
        for r in rows {
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, r.id, -1, Self.transient)
            if let mid = r.mid { sqlite3_bind_text(stmt, 2, mid, -1, Self.transient) } else { sqlite3_bind_null(stmt, 2) }
            sqlite3_bind_text(stmt, 3, r.fuzzy, -1, Self.transient)
            sqlite3_bind_text(stmt, 4, r.subject, -1, Self.transient)
            sqlite3_bind_text(stmt, 5, r.sender, -1, Self.transient)
            sqlite3_bind_int64(stmt, 6, Int64(r.date.timeIntervalSince1970))
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                try? exec("ROLLBACK;")
                throw EngineError.sqlite(message())
            }
        }
        try exec("COMMIT;")
    }

    private func exec(_ sql: String) throws {
        guard let db else { throw EngineError.sqlite("closed") }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw EngineError.sqlite(message()) }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let db else { throw EngineError.sqlite("closed") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw EngineError.sqlite(message())
        }
        return stmt
    }

    private func scalar(_ sql: String) throws -> Int {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func text(_ stmt: OpaquePointer, _ i: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, i) else { return "" }
        return String(cString: c)
    }

    private func message() -> String {
        guard let db, let c = sqlite3_errmsg(db) else { return "unknown SQLite error" }
        return String(cString: c)
    }
}
