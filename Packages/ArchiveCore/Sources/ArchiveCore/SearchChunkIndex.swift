//
//  SearchChunkIndex.swift
//  ArchiveCore
//
//  Five jobs FIND-07 / FIND-03 (plan §5.3.5): the searchable corpus as
//  logical documents in bounded chunks, INSIDE the archive database, so a
//  text condition compiles into the same SQL as every other condition.
//
//  Schema v22 (additive, snapshot first):
//    search_docs(email_id, kind, ordinal, revision, chunk_count, text_chars,
//                state, extractor_version, ocr)
//      one row per searchable document: a message's subject / sender /
//      recipients / body, or one attachment's text (ordinal = position).
//      `state` says what the document's text IS (complete, noText,
//      unsupported, locked, failed, partial) — a missing or non-complete
//      row is "not evaluable", never negative evidence.
//    search_chunks (FTS5: email_id, kind, ordinal, chunk UNINDEXED; text)
//      the text in chunks of `SearchChunker.chunkCharacters` that overlap by
//      `overlapCharacters`, split at word boundaries, so a phrase up to the
//      overlap is found even where it crosses a chunk. No cutoff: the whole
//      text is indexed, chunk by chunk. Tokeniser unicode61 with diacritics
//      folded and NO stemming — word matches are whole tokens; literal
//      phrase/contains tests are verified with instr() on the chunk text.
//
//  Dual write (rule 16): the previous per-year FTS shards keep being
//  written; this index is written next to them when the switch is on and
//  backfilled from the stored bodies for existing archives.
//

import Foundation
import SQLite3

/// Pushed by CapabilityWiring (`searchQueryModel`).
public enum SearchChunkPolicy {
    nonisolated(unsafe) public static var isEnabled = false
}

enum SearchDocKind: String, CaseIterable, Sendable {
    case subject, sender, recipients, body, attachmentName, attachmentText, ocrText

    /// What "anywhere in this message" covers (stated on the summary).
    static let anyText: [SearchDocKind] = [.subject, .sender, .recipients, .body, .attachmentName, .attachmentText, .ocrText]
    static let attachmentContent: [SearchDocKind] = [.attachmentText, .ocrText]
}

enum SearchDocState: String, Sendable {
    /// Every chunk of the text is indexed.
    case complete
    /// The extractor ran and found no text — evaluated, nothing to match.
    case noText
    case unsupported, locked, failed
    /// Some of the text is indexed (an interrupted job); not evaluable.
    case partial

    /// A condition on this document can be answered.
    var isEvaluable: Bool { self == .complete || self == .noText }
}

/// Splits text into overlapping chunks at word boundaries.
enum SearchChunker {
    /// Characters per chunk (about 48 KB of ASCII).
    static let chunkCharacters = 48 * 1024
    /// Characters repeated at the start of the next chunk, so a phrase that
    /// crosses the boundary is wholly inside one chunk.
    static let overlapCharacters = 512

    static func chunks(of text: String, chunk: Int = chunkCharacters, overlap: Int = overlapCharacters) -> [String] {
        guard text.count > chunk else { return text.isEmpty ? [] : [text] }
        precondition(overlap < chunk)
        var out: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            guard let hardEnd = text.index(start, offsetBy: chunk, limitedBy: text.endIndex) else {
                out.append(String(text[start...]))
                break
            }
            // Back up to a whitespace so a word is never cut in two.
            var end = hardEnd
            var probe = hardEnd
            var steps = 0
            while probe > start, steps < 256 {
                probe = text.index(before: probe)
                if text[probe].isWhitespace { end = text.index(after: probe); break }
                steps += 1
            }
            out.append(String(text[start..<end]))
            // Next chunk starts `overlap` characters before this one ended.
            var next = text.index(end, offsetBy: -overlap, limitedBy: start) ?? start
            if next <= start { next = end }   // cannot make progress otherwise
            start = next
            if end == text.endIndex { break }
        }
        return out
    }
}

/// One attachment's text for the chunk index.
struct AttachmentSearchDocument: Sendable {
    let ordinal: Int
    let filename: String
    /// The whole extracted text (nil when `state` says there is none).
    let text: String?
    let state: SearchDocState
    let extractorVersion: Int
    let ocr: Bool
}

extension SQLiteEmailStore {

    /// The chunk tokeniser. unicode61 with diacritics folded and NO stemming;
    /// `categories` adds the mark classes (M*) to the token characters, which
    /// the default leaves out — without them a Hindi or Bengali word is split
    /// at every vowel sign and can never be matched whole.
    static let chunkTokenizer = "unicode61 remove_diacritics 2 categories 'L* N* Co M*'"

    /// v23: the v22 tables were created with the default tokeniser (marks as
    /// separators); v22 never shipped, so they are dropped and recreated and
    /// the backfill refills them.
    func createSchemaV23(_ handle: OpaquePointer) throws {
        try exec(handle, "DROP TABLE IF EXISTS search_chunks;")
        try exec(handle, "DROP TABLE IF EXISTS search_docs;")
        try createSchemaV22(handle)
    }

    /// v22 tables (additive, IF NOT EXISTS).
    func createSchemaV22(_ handle: OpaquePointer) throws {
        try exec(handle, """
            CREATE TABLE IF NOT EXISTS search_docs(
                email_id          TEXT NOT NULL,
                kind              TEXT NOT NULL,
                ordinal           INTEGER NOT NULL DEFAULT 0,
                revision          INTEGER NOT NULL DEFAULT 1,
                chunk_count       INTEGER NOT NULL DEFAULT 0,
                text_chars        INTEGER NOT NULL DEFAULT 0,
                state             TEXT NOT NULL,
                extractor_version INTEGER NOT NULL DEFAULT 0,
                ocr               INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY(email_id, kind, ordinal)
            );
        """)
        try exec(handle, "CREATE INDEX IF NOT EXISTS idx_search_docs_kind_state ON search_docs(kind, state);")
        try exec(handle, """
            CREATE VIRTUAL TABLE IF NOT EXISTS search_chunks USING fts5(
                email_id UNINDEXED,
                kind UNINDEXED,
                ordinal UNINDEXED,
                chunk UNINDEXED,
                text,
                tokenize="\(Self.chunkTokenizer)"
            );
        """)
    }

    // MARK: Writing documents

    /// Replace one document's chunks and state. `text` nil = no chunks; the
    /// state says why. Runs inside the caller's transaction.
    func indexSearchDocument(_ db: OpaquePointer, emailID: String, kind: SearchDocKind, ordinal: Int,
                             text: String?, state: SearchDocState, extractorVersion: Int = 0, ocr: Bool = false) throws {
        let clear = try prepare(db, "DELETE FROM search_chunks WHERE email_id = ? AND kind = ? AND ordinal = ?;")
        defer { sqlite3_finalize(clear) }
        bindText(clear, 1, emailID); bindText(clear, 2, kind.rawValue); sqlite3_bind_int64(clear, 3, Int64(ordinal))
        guard sqlite3_step(clear) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }

        var chunkCount = 0
        var chars = 0
        if let text, !text.isEmpty {
            let insert = try prepare(db, "INSERT INTO search_chunks(email_id, kind, ordinal, chunk, text) VALUES (?,?,?,?,?);")
            defer { sqlite3_finalize(insert) }
            for (index, chunk) in SearchChunker.chunks(of: text).enumerated() {
                sqlite3_reset(insert); sqlite3_clear_bindings(insert)
                bindText(insert, 1, emailID); bindText(insert, 2, kind.rawValue)
                sqlite3_bind_int64(insert, 3, Int64(ordinal)); sqlite3_bind_int64(insert, 4, Int64(index))
                bindText(insert, 5, chunk)
                guard sqlite3_step(insert) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
                chunkCount += 1
            }
            chars = text.count
        }
        let doc = try prepare(db, """
            INSERT INTO search_docs(email_id, kind, ordinal, revision, chunk_count, text_chars, state, extractor_version, ocr)
            VALUES (?,?,?,1,?,?,?,?,?)
            ON CONFLICT(email_id, kind, ordinal) DO UPDATE SET
                revision = search_docs.revision + 1, chunk_count = excluded.chunk_count, text_chars = excluded.text_chars,
                state = excluded.state, extractor_version = excluded.extractor_version, ocr = excluded.ocr;
        """)
        defer { sqlite3_finalize(doc) }
        bindText(doc, 1, emailID); bindText(doc, 2, kind.rawValue); sqlite3_bind_int64(doc, 3, Int64(ordinal))
        sqlite3_bind_int64(doc, 4, Int64(chunkCount)); sqlite3_bind_int64(doc, 5, Int64(chars))
        bindText(doc, 6, state.rawValue); sqlite3_bind_int64(doc, 7, Int64(extractorVersion)); sqlite3_bind_int(doc, 8, ocr ? 1 : 0)
        guard sqlite3_step(doc) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
    }

    /// The message's own documents: subject, sender, recipients (To, Cc and
    /// Bcc), body (plain text, or the HTML's text). Whole text, no budget.
    func indexEmailSearchDocuments(_ db: OpaquePointer, email: MBOXParser.RawEmail) throws {
        let id = email.id.uuidString
        try indexSearchDocument(db, emailID: id, kind: .subject, ordinal: 0, text: email.headers["Subject"], state: .complete)
        try indexSearchDocument(db, emailID: id, kind: .sender, ordinal: 0, text: email.headers["From"], state: .complete)
        let recipients = [email.headers["To"], email.headers["Cc"] ?? email.headers["CC"], email.headers["Bcc"] ?? email.headers["BCC"]]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        try indexSearchDocument(db, emailID: id, kind: .recipients, ordinal: 0, text: recipients, state: .complete)
        let body = email.plainBody.isEmpty ? FTSSearchIndex.stripHTMLText(email.htmlBody) : email.plainBody
        try indexSearchDocument(db, emailID: id, kind: .body, ordinal: 0, text: body,
                                state: body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .noText : .complete)
        if !email.attachments.isEmpty {
            let names = email.attachments.map(\.filename).joined(separator: "\n")
            try indexSearchDocument(db, emailID: id, kind: .attachmentName, ordinal: 0, text: names, state: .complete)
        }
    }

    /// One email's attachment documents, from the attachment text job.
    func indexAttachmentSearchDocuments(emailID: UUID, documents: [AttachmentSearchDocument]) throws {
        let db = try ensureDB()
        try exec(db, SQLiteHygiene.beginWrite)
        do {
            let id = emailID.uuidString
            for document in documents {
                let kind: SearchDocKind = document.ocr ? .ocrText : .attachmentText
                let other: SearchDocKind = document.ocr ? .attachmentText : .ocrText
                // One document per attachment: whichever extractor produced it.
                let clear = try prepare(db, "DELETE FROM search_chunks WHERE email_id = ? AND kind = ? AND ordinal = ?;")
                bindText(clear, 1, id); bindText(clear, 2, other.rawValue); sqlite3_bind_int64(clear, 3, Int64(document.ordinal))
                _ = sqlite3_step(clear); sqlite3_finalize(clear)
                let clearDoc = try prepare(db, "DELETE FROM search_docs WHERE email_id = ? AND kind = ? AND ordinal = ?;")
                bindText(clearDoc, 1, id); bindText(clearDoc, 2, other.rawValue); sqlite3_bind_int64(clearDoc, 3, Int64(document.ordinal))
                _ = sqlite3_step(clearDoc); sqlite3_finalize(clearDoc)
                try indexSearchDocument(db, emailID: id, kind: kind, ordinal: document.ordinal, text: document.text,
                                        state: document.state, extractorVersion: document.extractorVersion, ocr: document.ocr)
            }
            try exec(db, "COMMIT;")
        } catch { try? exec(db, "ROLLBACK;"); throw error }
    }

    // MARK: Backfill for existing archives

    /// Emails with no body document yet, in id order after `cursor`.
    func searchDocsBackfillPage(after cursor: UUID?, limit: Int) throws -> [UUID] {
        let db = try ensureDB()
        let stmt = try prepare(db, """
            SELECT e.id FROM emails e
            WHERE e.id > ? AND NOT EXISTS (SELECT 1 FROM search_docs d WHERE d.email_id = e.id AND d.kind = 'body')
            ORDER BY e.id LIMIT ?;
        """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, cursor?.uuidString ?? "")
        sqlite3_bind_int(stmt, 2, Int32(clamping: limit))
        var out: [UUID] = []
        while try stepRow(stmt, db) { if let id = columnUUID(stmt, 0) { out.append(id) } }
        return out
    }

    /// Index the message documents of stored emails (bodies read from the
    /// store, never from the original file). One transaction per call.
    func backfillSearchDocuments(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        let emails = try self.emails(withIDs: ids)
        let db = try ensureDB()
        try exec(db, SQLiteHygiene.beginWrite)
        do {
            for email in emails { try indexEmailSearchDocuments(db, email: email) }
            try exec(db, "COMMIT;")
        } catch { try? exec(db, "ROLLBACK;"); throw error }
    }

    /// How many emails still lack a body document (the backfill's remaining work).
    func searchDocsBackfillRemaining() throws -> Int {
        try scalarInt(try ensureDB(), """
            SELECT COUNT(*) FROM emails e
            WHERE NOT EXISTS (SELECT 1 FROM search_docs d WHERE d.email_id = e.id AND d.kind = 'body');
        """)
    }

    /// Emails whose attachments were indexed by the attachment job before
    /// the chunk index existed: no attachment document although attempted.
    func attachmentEmailsWithoutSearchDocs(limit: Int) throws -> [UUID] {
        let db = try ensureDB()
        let stmt = try prepare(db, """
            SELECT e.id FROM emails e
            WHERE e.has_attach = 1
              AND EXISTS (SELECT 1 FROM attachment_text_state s WHERE s.email_id = e.id)
              AND NOT EXISTS (SELECT 1 FROM search_docs d WHERE d.email_id = e.id AND d.kind IN ('attachmentText','ocrText'))
            ORDER BY e.id LIMIT ?;
        """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(clamping: limit))
        var out: [UUID] = []
        while try stepRow(stmt, db) { if let id = columnUUID(stmt, 0) { out.append(id) } }
        return out
    }

    struct SearchDocCoverage: Sendable, Equatable {
        /// Emails whose body document is complete or evaluated (noText).
        var bodiesEvaluable: Int
        var emails: Int
        /// Attachments with an evaluable text document / all attachments.
        var attachmentsEvaluable: Int
        var attachments: Int
        var bodyChunks: Int
    }

    func searchDocCoverage() throws -> SearchDocCoverage {
        let db = try ensureDB()
        return SearchDocCoverage(
            bodiesEvaluable: try scalarInt(db, "SELECT COUNT(*) FROM search_docs WHERE kind = 'body' AND state IN ('complete','noText');"),
            emails: try scalarInt(db, "SELECT COUNT(*) FROM emails;"),
            attachmentsEvaluable: try scalarInt(db, "SELECT COUNT(*) FROM search_docs WHERE kind IN ('attachmentText','ocrText') AND state IN ('complete','noText');"),
            attachments: try scalarInt(db, "SELECT COUNT(*) FROM attachments;"),
            bodyChunks: try scalarInt(db, "SELECT COALESCE(SUM(chunk_count), 0) FROM search_docs WHERE kind = 'body';"))
    }

    /// Chunk rows of one document in order — the verifier's view of the text.
    func searchChunks(emailID: UUID, kind: SearchDocKind, ordinal: Int) throws -> [String] {
        let db = try ensureDB()
        let stmt = try prepare(db, "SELECT text FROM search_chunks WHERE email_id = ? AND kind = ? AND ordinal = ? ORDER BY chunk;")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, emailID.uuidString); bindText(stmt, 2, kind.rawValue); sqlite3_bind_int64(stmt, 3, Int64(ordinal))
        var out: [String] = []
        while try stepRow(stmt, db) { out.append(columnText(stmt, 0)) }
        return out
    }
}
