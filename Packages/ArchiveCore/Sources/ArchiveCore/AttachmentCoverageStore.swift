//
//  AttachmentCoverageStore.swift
//  ArchiveCore
//
//  Five jobs FIND-03: what the attachment-text job did with EACH attachment,
//  not just "attempted" per email. An attempted email whose only attachment
//  is a DOCX has no searchable text, and the person must be able to see that.
//
//  States recorded here:
//    extracted    searchable text was indexed
//    truncated    searchable text was indexed but cut at the per-attachment cap
//    noText       the extractor ran and found nothing (an empty document, a
//                 scan with OCR off records `unsupported`, see note)
//    unsupported  no extractor for this kind (DOCX/XLSX/PPTX/ZIP/…, or an image
//                 while OCR is off)
//    locked       password-protected or encrypted
//    failed       the extractor threw, or the message's source is not stored
//  "queued" is derived (an email with attachments and no attempt yet) and
//  "processing" is the job's in-flight email; neither is persisted.
//
//  Each row carries the extractor version that produced it. When a new
//  extractor arrives (FIND-01 adds Office files, FIND-07 removes the cap) the
//  version is bumped and rows below it in unsupported/failed/truncated are
//  re-queued — no reimport.
//
//  Like `AttachmentOCRState`, a small SQLite file beside the archive, not a
//  table in `emails.db`: the archive schema is unchanged, an earlier build
//  ignores the file, and losing it costs only a repeat of the indexing work.
//

import Foundation
import SQLite3

enum AttachmentCoverageState: String, CaseIterable, Sendable {
    case extracted, truncated, noText, unsupported, locked, failed
    /// FIND-01: some text-bearing parts of the file were read, others not
    /// (listed in the note) — searchable, but not whole.
    case partial

    /// Text that can be searched exists for this attachment.
    var isSearchable: Bool { self == .extracted || self == .truncated || self == .partial }
    /// A newer extractor may do better; the retry pass takes these.
    var retriesOnNewExtractor: Bool { self == .unsupported || self == .failed || self == .truncated || self == .partial }
}

struct AttachmentCoverageRow: Sendable, Equatable {
    let emailID: UUID
    /// Position within the message's attachment list, so two attachments
    /// with the same filename stay distinct.
    let ordinal: Int
    let filename: String
    let mimeType: String
    let state: AttachmentCoverageState
    let extractor: String
    let extractorVersion: Int
    /// Characters indexed (0 unless extracted/truncated).
    let characters: Int
    let note: String?
    /// §13.3 (10) / A10: how many Resume rounds this attachment has had (0 = the ordinary pass).
    var resumeRound: Int = 0
    /// R5: the stored text came from an Unlock with "keep searchable" — a later
    /// round without the password must keep it, never re-read it as locked.
    var unlockedWithPassword: Bool = false
}

struct AttachmentCoverageSummary: Sendable, Equatable {
    var counts: [AttachmentCoverageState: Int] = [:]
    /// Unsupported attachments by file extension (lower-cased, "" for none), most first.
    var unsupportedKinds: [(kind: String, count: Int)] = []
    /// Rows a newer extractor would retry.
    var staleRows = 0
    /// §13.3 (8): files INSIDE attachments by state ("locked", "unsupported", …), filled by the job from the archive.
    var childCounts: [String: Int] = [:]

    var total: Int { counts.values.reduce(0, +) }
    var searchable: Int { (counts[.extracted] ?? 0) + (counts[.truncated] ?? 0) }

    static func == (a: AttachmentCoverageSummary, b: AttachmentCoverageSummary) -> Bool {
        a.counts == b.counts && a.staleRows == b.staleRows
            && a.unsupportedKinds.map(\.kind) == b.unsupportedKinds.map(\.kind)
            && a.unsupportedKinds.map(\.count) == b.unsupportedKinds.map(\.count)
    }
}

final class AttachmentCoverageStore {
    private var db: OpaquePointer?

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw SQLiteStoreError.open(message)
        }
        sqlite3_busy_timeout(db, 5_000)
        try exec("""
            CREATE TABLE IF NOT EXISTS coverage(
                email_id          TEXT NOT NULL,
                ordinal           INTEGER NOT NULL,
                filename          TEXT NOT NULL,
                mime_type         TEXT NOT NULL,
                state             TEXT NOT NULL,
                extractor         TEXT NOT NULL,
                extractor_version INTEGER NOT NULL,
                characters        INTEGER NOT NULL DEFAULT 0,
                note              TEXT,
                updated_at        INTEGER NOT NULL,
                PRIMARY KEY(email_id, ordinal)
            );
        """)
        try exec("CREATE INDEX IF NOT EXISTS coverage_state ON coverage(state, extractor_version);")
        // A10: the Resume round per row — added 2026-11-07; older files gain the column here.
        let columns = try prepare("PRAGMA table_info(coverage);")
        var hasRound = false
        while sqlite3_step(columns) == SQLITE_ROW { if text(columns, 1) == "resume_round" { hasRound = true } }
        sqlite3_finalize(columns)
        if !hasRound { try exec("ALTER TABLE coverage ADD COLUMN resume_round INTEGER NOT NULL DEFAULT 0;") }
        // R5: whether the stored text came from a kept Unlock — added 2026-11-08, same additive pattern.
        let columns2 = try prepare("PRAGMA table_info(coverage);")
        var hasUnlocked = false
        while sqlite3_step(columns2) == SQLITE_ROW { if text(columns2, 1) == "unlocked" { hasUnlocked = true } }
        sqlite3_finalize(columns2)
        if !hasUnlocked { try exec("ALTER TABLE coverage ADD COLUMN unlocked INTEGER NOT NULL DEFAULT 0;") }
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

    private func text(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        sqlite3_column_text(stmt, index).map { String(cString: $0) }
    }

    /// Replace what is known about one email's attachments. An email with
    /// attachments but no rows (e.g. its source is not stored) gets none;
    /// pass the rows the job could determine.
    func record(emailID: UUID, rows: [AttachmentCoverageRow]) throws {
        try exec("BEGIN IMMEDIATE;")
        do {
            let clear = try prepare("DELETE FROM coverage WHERE email_id = ?;")
            defer { sqlite3_finalize(clear) }
            sqlite3_bind_text(clear, 1, emailID.uuidString, -1, Self.transient)
            guard sqlite3_step(clear) == SQLITE_DONE else { throw SQLiteStoreError.step(String(cString: sqlite3_errmsg(db))) }

            let insert = try prepare("""
                INSERT INTO coverage(email_id, ordinal, filename, mime_type, state, extractor, extractor_version, characters, note, updated_at, resume_round, unlocked)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?);
            """)
            defer { sqlite3_finalize(insert) }
            let now = Int64(Date().timeIntervalSince1970)
            for row in rows {
                sqlite3_reset(insert); sqlite3_clear_bindings(insert)
                sqlite3_bind_text(insert, 1, emailID.uuidString, -1, Self.transient)
                sqlite3_bind_int64(insert, 2, Int64(row.ordinal))
                sqlite3_bind_text(insert, 3, row.filename, -1, Self.transient)
                sqlite3_bind_text(insert, 4, row.mimeType, -1, Self.transient)
                sqlite3_bind_text(insert, 5, row.state.rawValue, -1, Self.transient)
                sqlite3_bind_text(insert, 6, row.extractor, -1, Self.transient)
                sqlite3_bind_int64(insert, 7, Int64(row.extractorVersion))
                sqlite3_bind_int64(insert, 8, Int64(row.characters))
                if let note = row.note { sqlite3_bind_text(insert, 9, note, -1, Self.transient) } else { sqlite3_bind_null(insert, 9) }
                sqlite3_bind_int64(insert, 10, now)
                sqlite3_bind_int64(insert, 11, Int64(row.resumeRound))
                sqlite3_bind_int(insert, 12, row.unlockedWithPassword ? 1 : 0)
                guard sqlite3_step(insert) == SQLITE_DONE else { throw SQLiteStoreError.step(String(cString: sqlite3_errmsg(db))) }
            }
            try exec("COMMIT;")
        } catch { try? exec("ROLLBACK;"); throw error }
    }

    /// §13.8 step 5: one attachment's row replaced on its own (an Unlock),
    /// the other attachments of the message left exactly as they were.
    func record(row: AttachmentCoverageRow) throws {
        let upsert = try prepare("""
            INSERT OR REPLACE INTO coverage(email_id, ordinal, filename, mime_type, state, extractor, extractor_version, characters, note, updated_at, resume_round, unlocked)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?);
        """)
        defer { sqlite3_finalize(upsert) }
        sqlite3_bind_text(upsert, 1, row.emailID.uuidString, -1, Self.transient)
        sqlite3_bind_int64(upsert, 2, Int64(row.ordinal))
        sqlite3_bind_text(upsert, 3, row.filename, -1, Self.transient)
        sqlite3_bind_text(upsert, 4, row.mimeType, -1, Self.transient)
        sqlite3_bind_text(upsert, 5, row.state.rawValue, -1, Self.transient)
        sqlite3_bind_text(upsert, 6, row.extractor, -1, Self.transient)
        sqlite3_bind_int64(upsert, 7, Int64(row.extractorVersion))
        sqlite3_bind_int64(upsert, 8, Int64(row.characters))
        if let note = row.note { sqlite3_bind_text(upsert, 9, note, -1, Self.transient) } else { sqlite3_bind_null(upsert, 9) }
        sqlite3_bind_int64(upsert, 10, Int64(Date().timeIntervalSince1970))
        sqlite3_bind_int64(upsert, 11, Int64(row.resumeRound))
        sqlite3_bind_int(upsert, 12, row.unlockedWithPassword ? 1 : 0)
        guard sqlite3_step(upsert) == SQLITE_DONE else { throw SQLiteStoreError.step(String(cString: sqlite3_errmsg(db))) }
    }

    /// Every attachment's state for one email, in attachment order.
    func rows(for emailID: UUID) throws -> [AttachmentCoverageRow] {
        let stmt = try prepare("""
            SELECT ordinal, filename, mime_type, state, extractor, extractor_version, characters, note, resume_round, unlocked
            FROM coverage WHERE email_id = ? ORDER BY ordinal;
        """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, emailID.uuidString, -1, Self.transient)
        var out: [AttachmentCoverageRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let state = AttachmentCoverageState(rawValue: text(stmt, 3) ?? "") else { continue }
            out.append(AttachmentCoverageRow(
                emailID: emailID, ordinal: Int(sqlite3_column_int64(stmt, 0)),
                filename: text(stmt, 1) ?? "", mimeType: text(stmt, 2) ?? "", state: state,
                extractor: text(stmt, 4) ?? "", extractorVersion: Int(sqlite3_column_int64(stmt, 5)),
                characters: Int(sqlite3_column_int64(stmt, 6)), note: text(stmt, 7), resumeRound: Int(sqlite3_column_int64(stmt, 8)),
                unlockedWithPassword: sqlite3_column_int(stmt, 9) != 0))
        }
        return out
    }

    /// Archive-wide picture: how many attachments are in each state, which
    /// kinds are unsupported, and how many rows a newer extractor would retry.
    func summary(currentExtractorVersion: Int) throws -> AttachmentCoverageSummary {
        var summary = AttachmentCoverageSummary()
        let counts = try prepare("SELECT state, COUNT(*) FROM coverage GROUP BY state;")
        defer { sqlite3_finalize(counts) }
        while sqlite3_step(counts) == SQLITE_ROW {
            if let state = AttachmentCoverageState(rawValue: text(counts, 0) ?? "") {
                summary.counts[state] = Int(sqlite3_column_int64(counts, 1))
            }
        }
        let kinds = try prepare("""
            SELECT lower(CASE WHEN instr(filename, '.') > 0 THEN replace(filename, rtrim(filename, replace(filename, '.', '')), '') ELSE '' END) AS ext, COUNT(*)
            FROM coverage WHERE state = 'unsupported' GROUP BY ext ORDER BY COUNT(*) DESC, ext ASC;
        """)
        defer { sqlite3_finalize(kinds) }
        while sqlite3_step(kinds) == SQLITE_ROW {
            summary.unsupportedKinds.append((text(kinds, 0) ?? "", Int(sqlite3_column_int64(kinds, 1))))
        }
        let stale = try prepare("""
            SELECT COUNT(*) FROM coverage WHERE extractor_version < ? AND state IN ('unsupported', 'failed', 'truncated', 'partial');
        """)
        defer { sqlite3_finalize(stale) }
        sqlite3_bind_int64(stale, 1, Int64(currentExtractorVersion))
        if sqlite3_step(stale) == SQLITE_ROW { summary.staleRows = Int(sqlite3_column_int64(stale, 0)) }
        return summary
    }

    /// Emails holding an attachment a newer extractor should retry, oldest
    /// version first; `limit` bounds one page of the retry pass.
    /// Emails whose attachments were read by one of `extractors` below
    /// `version`, in any state (§13.3: a re-read that changes what a document IS).
    func emailIDs(extractors: [String], below version: Int, limit: Int) throws -> [UUID] {
        let list = extractors.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" }.joined(separator: ",")
        let stmt = try prepare("""
            SELECT DISTINCT email_id FROM coverage
            WHERE extractor_version < ? AND extractor IN (\(list))
            ORDER BY extractor_version, email_id LIMIT ?;
        """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(version))
        sqlite3_bind_int(stmt, 2, Int32(clamping: limit))
        var out: [UUID] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let id = text(stmt, 0).flatMap(UUID.init(uuidString:)) { out.append(id) }
        }
        return out
    }

    func emailIDs(staleBelow version: Int, limit: Int) throws -> [UUID] {
        let stmt = try prepare("""
            SELECT DISTINCT email_id FROM coverage
            WHERE extractor_version < ? AND state IN ('unsupported', 'failed', 'truncated', 'partial')
            ORDER BY extractor_version, email_id LIMIT ?;
        """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(version))
        sqlite3_bind_int(stmt, 2, Int32(clamping: limit))
        var out: [UUID] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let id = text(stmt, 0).flatMap(UUID.init(uuidString:)) { out.append(id) }
        }
        return out
    }

    /// Forget emails (deleted, or about to be re-indexed).
    func remove(emailIDs: [UUID]) throws {
        guard !emailIDs.isEmpty else { return }
        let marks = Array(repeating: "?", count: emailIDs.count).joined(separator: ",")
        let stmt = try prepare("DELETE FROM coverage WHERE email_id IN (\(marks));")
        defer { sqlite3_finalize(stmt) }
        for (i, id) in emailIDs.enumerated() { sqlite3_bind_text(stmt, Int32(i + 1), id.uuidString, -1, Self.transient) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteStoreError.step(String(cString: sqlite3_errmsg(db))) }
    }
}
