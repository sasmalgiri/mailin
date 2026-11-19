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
//      phrase/contains tests are verified with mailin_phrase() on the chunk
//      text (FIND-08, SectionBoundary.swift).
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
    /// TYPE-05: words recognised in an audio or video attachment, on the device.
    case speechText
    /// Plan v4 §13.3 (5): the text of ONE file inside an archive or message
    /// attachment — its own document, so a phrase never bridges two files
    /// and a type/name/content condition can address that file. Ordinal =
    /// parent position × `childOrdinalBase` + child index.
    case childText

    static let childOrdinalBase = 1_000_000
    static func childOrdinal(parent: Int, child: Int) -> Int { parent * childOrdinalBase + child }

    /// What "anywhere in this message" covers (stated on the summary).
    static let anyText: [SearchDocKind] = [.subject, .sender, .recipients, .body, .attachmentName, .attachmentText, .ocrText, .speechText, .childText]
    /// Attachment content: the attachment's own text kinds. A child's text
    /// belongs to the child (`childText`), addressed through `attachment_children`.
    static let attachmentContent: [SearchDocKind] = [.attachmentText, .ocrText, .speechText]
    /// SQL list of the attachment-content kinds.
    static let attachmentContentSQL = "'attachmentText','ocrText','speechText'"
}

/// One file inside an attachment (archive member, message attachment,
/// embedded object), as the store records it — plan v4 §13.3 (5).
struct AttachmentChildRow: Sendable, Equatable {
    let emailID: UUID
    /// The top-level attachment's position.
    let position: Int
    /// Index of this child among the attachment's children (depth-first).
    let childIndex: Int
    /// Container chain, "outer.zip › inner/minutes.docx".
    let path: String
    let filename: String
    /// Detected kind (document kind raw value or lower-cased extension).
    let kind: String
    let sha256: String
    let bytes: Int
    let state: String
    let note: String?

    var ordinal: Int { SearchDocKind.childOrdinal(parent: position, child: childIndex) }
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
    /// R02 (handoff 7481852): chunks are CONTIGUOUS — a document is exactly
    /// its chunks in order, nothing repeated. A literal of any length is then
    /// verified on the chunks joined as stored (`c1.text || c2.text || …`),
    /// with no offset arithmetic and so no Character-versus-code-point
    /// mismatch between Swift and SQLite. Until 2026-11-06 chunk k ≥ 1
    /// repeated the last `legacyOverlapCharacters` Characters of chunk k−1;
    /// `SQLiteEmailStore.migrateSearchChunksToContiguous` (schema v24)
    /// rewrites those documents.
    static let legacyOverlapCharacters = 512

    static func chunks(of text: String, chunk: Int = chunkCharacters) -> [String] {
        guard text.count > chunk else { return text.isEmpty ? [] : [text] }
        var out: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            guard let hardEnd = text.index(start, offsetBy: chunk, limitedBy: text.endIndex) else {
                out.append(String(text[start...]))
                break
            }
            // Back up to a whitespace so a word is never cut in two; the next
            // chunk begins exactly where this one ends.
            var end = hardEnd
            var probe = hardEnd
            var steps = 0
            while probe > start, steps < 256 {
                probe = text.index(before: probe)
                if text[probe].isWhitespace { end = text.index(after: probe); break }
                steps += 1
            }
            out.append(String(text[start..<end]))
            start = end
            if end == text.endIndex { break }
        }
        return out
    }

    /// The text of a document stored in the overlapped layout (before v24):
    /// every chunk after the first began with the previous chunk's last
    /// `legacyOverlapCharacters` Characters, which are dropped here.
    static func joinLegacyOverlapped(_ chunks: [String]) -> String {
        var text = chunks.first ?? ""
        for chunk in chunks.dropFirst() { text += String(chunk.dropFirst(legacyOverlapCharacters)) }
        return text
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
    /// TYPE-05: the text is speech recognised from audio or video.
    var speech: Bool = false
    /// §13.3 (5): the document is one file INSIDE the attachment; `ordinal`
    /// is then `SearchDocKind.childOrdinal(parent:child:)`.
    var child: Bool = false

    var kind: SearchDocKind { child ? .childText : (speech ? .speechText : (ocr ? .ocrText : .attachmentText)) }
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
    /// v24 (R02): every multi-chunk document is rewritten from the overlapped
    /// layout to the contiguous one; single-chunk documents are already
    /// contiguous and are left alone. States, revisions and extractor
    /// versions are kept; only the chunk rows and the counts change. Runs
    /// inside the migration's exclusive transaction.
    func migrateSearchChunksToContiguous(_ handle: OpaquePointer) throws {
        var targets: [(emailID: String, kind: String, ordinal: Int)] = []
        let docs = try prepare(handle, "SELECT email_id, kind, ordinal FROM search_docs WHERE chunk_count > 1;")
        while try stepRow(docs, handle) {
            targets.append((columnText(docs, 0), columnText(docs, 1), Int(sqlite3_column_int64(docs, 2))))
        }
        sqlite3_finalize(docs)
        for target in targets {
            let read = try prepare(handle, "SELECT text FROM search_chunks WHERE email_id = ? AND kind = ? AND ordinal = ? ORDER BY chunk;")
            bindText(read, 1, target.emailID); bindText(read, 2, target.kind); sqlite3_bind_int64(read, 3, Int64(target.ordinal))
            var chunks: [String] = []
            while try stepRow(read, handle) { chunks.append(columnText(read, 0)) }
            sqlite3_finalize(read)
            try rewriteChunks(handle, emailID: target.emailID, kind: target.kind, ordinal: target.ordinal,
                              text: SearchChunker.joinLegacyOverlapped(chunks))
        }
    }

    /// Replaces one document's chunk rows with the contiguous chunks of `text`.
    func rewriteChunks(_ handle: OpaquePointer, emailID: String, kind: String, ordinal: Int, text: String) throws {
        let clear = try prepare(handle, "DELETE FROM search_chunks WHERE email_id = ? AND kind = ? AND ordinal = ?;")
        defer { sqlite3_finalize(clear) }
        bindText(clear, 1, emailID); bindText(clear, 2, kind); sqlite3_bind_int64(clear, 3, Int64(ordinal))
        guard sqlite3_step(clear) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(handle)) }
        let insert = try prepare(handle, "INSERT INTO search_chunks(email_id, kind, ordinal, chunk, text) VALUES (?,?,?,?,?);")
        defer { sqlite3_finalize(insert) }
        var count = 0
        for (index, chunk) in SearchChunker.chunks(of: text).enumerated() {
            sqlite3_reset(insert); sqlite3_clear_bindings(insert)
            bindText(insert, 1, emailID); bindText(insert, 2, kind)
            sqlite3_bind_int64(insert, 3, Int64(ordinal)); sqlite3_bind_int64(insert, 4, Int64(index))
            bindText(insert, 5, chunk)
            guard sqlite3_step(insert) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(handle)) }
            count += 1
        }
        let update = try prepare(handle, "UPDATE search_docs SET chunk_count = ?, text_chars = ? WHERE email_id = ? AND kind = ? AND ordinal = ?;")
        defer { sqlite3_finalize(update) }
        sqlite3_bind_int64(update, 1, Int64(count)); sqlite3_bind_int64(update, 2, Int64(text.count))
        bindText(update, 3, emailID); bindText(update, 4, kind); sqlite3_bind_int64(update, 5, Int64(ordinal))
        guard sqlite3_step(update) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(handle)) }
    }

    // MARK: Test seams for the v24 migration (plant the old layout, migrate, read back)

    func plantLegacyChunksForTesting(emailID: String, kind: String, chunks: [String]) throws {
        let db = try ensureDB()
        try exec(db, SQLiteHygiene.beginWrite)
        do {
            let clear = try prepare(db, "DELETE FROM search_chunks WHERE email_id = ? AND kind = ? AND ordinal = 0;")
            bindText(clear, 1, emailID); bindText(clear, 2, kind)
            _ = sqlite3_step(clear); sqlite3_finalize(clear)
            let insert = try prepare(db, "INSERT INTO search_chunks(email_id, kind, ordinal, chunk, text) VALUES (?,?,0,?,?);")
            for (index, chunk) in chunks.enumerated() {
                sqlite3_reset(insert); sqlite3_clear_bindings(insert)
                bindText(insert, 1, emailID); bindText(insert, 2, kind); sqlite3_bind_int64(insert, 3, Int64(index)); bindText(insert, 4, chunk)
                guard sqlite3_step(insert) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
            }
            sqlite3_finalize(insert)
            let doc = try prepare(db, """
                INSERT INTO search_docs(email_id, kind, ordinal, revision, chunk_count, text_chars, state, extractor_version, ocr)
                VALUES (?,?,0,1,?,0,'complete',0,0)
                ON CONFLICT(email_id, kind, ordinal) DO UPDATE SET chunk_count = excluded.chunk_count, state = 'complete';
            """)
            bindText(doc, 1, emailID); bindText(doc, 2, kind); sqlite3_bind_int64(doc, 3, Int64(chunks.count))
            guard sqlite3_step(doc) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
            sqlite3_finalize(doc)
            try exec(db, "COMMIT;")
        } catch { try? exec(db, "ROLLBACK;"); throw error }
    }

    // MARK: Test seams for the chunk runs (2026-11-19)

    /// Indexes the messages' own documents in one transaction, as the import does.
    func indexEmailSearchDocumentsForTesting(_ emails: [MBOXParser.RawEmail]) throws {
        let db = try ensureDB()
        try exec(db, SQLiteHygiene.beginWrite)
        do {
            for email in emails { try indexEmailSearchDocuments(db, email: email) }
            try exec(db, "COMMIT;")
        } catch { try? exec(db, "ROLLBACK;"); throw error }
    }

    /// Rewrites one document with `text` (nil = no chunks), in its own transaction.
    func reindexDocumentForTesting(emailID: String, kind: SearchDocKind, ordinal: Int = 0, text: String?) throws {
        let db = try ensureDB()
        try exec(db, SQLiteHygiene.beginWrite)
        do {
            try indexSearchDocument(db, emailID: emailID, kind: kind, ordinal: ordinal, text: text,
                                    state: text == nil ? .noText : .complete)
            try exec(db, "COMMIT;")
        } catch { try? exec(db, "ROLLBACK;"); throw error }
    }

    /// The recorded rowid run of one document; nil when the row has none (legacy) or does not exist.
    func searchDocumentRunForTesting(emailID: String, kind: SearchDocKind, ordinal: Int = 0) throws -> ChunkRun? {
        let db = try ensureDB()
        if case .run(let run) = try existingSearchDocument(db, emailID: emailID, kind: kind.rawValue, ordinal: ordinal) { return run }
        return nil
    }

    /// The columns of `search_docs`, as SQLite reports them.
    func searchDocColumnsForTesting() throws -> [String] {
        let db = try ensureDB()
        let info = try prepare(db, "PRAGMA table_info(search_docs);")
        defer { sqlite3_finalize(info) }
        var out: [String] = []
        while try stepRow(info, db) { out.append(columnText(info, 1)) }
        return out
    }

    func rechunkOverlappedDocumentsForTesting() throws {
        let db = try ensureDB()
        try exec(db, SQLiteHygiene.beginWrite)
        do { try migrateSearchChunksToContiguous(db); try exec(db, "COMMIT;") } catch { try? exec(db, "ROLLBACK;"); throw error }
    }

    func chunkTextsForTesting(emailID: String, kind: String) throws -> [String] {
        let db = try ensureDB()
        let read = try prepare(db, "SELECT text FROM search_chunks WHERE email_id = ? AND kind = ? AND ordinal = 0 ORDER BY chunk;")
        defer { sqlite3_finalize(read) }
        bindText(read, 1, emailID); bindText(read, 2, kind)
        var out: [String] = []
        while try stepRow(read, db) { out.append(columnText(read, 0)) }
        return out
    }

    func createSchemaV23(_ handle: OpaquePointer) throws {
        try exec(handle, "DROP TABLE IF EXISTS search_chunks;")
        try exec(handle, "DROP TABLE IF EXISTS search_docs;")
        try createSchemaV22(handle)
    }

    /// v22 tables (additive, IF NOT EXISTS). `first_rowid` / `last_rowid`
    /// (2026-11-19, see "Chunk runs" below) are added on open for stores
    /// created before them.
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
                first_rowid       INTEGER,
                last_rowid        INTEGER,
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

    // MARK: Chunk runs (2026-11-19)
    //
    // `search_chunks` is an FTS5 table and its email_id / kind / ordinal
    // columns are UNINDEXED, so `DELETE … WHERE email_id = ? AND kind = ? AND
    // ordinal = ?` visits EVERY chunk row. The import wrote five documents per
    // message and cleared each one first, so indexing cost grew with the size
    // of the table: a 56,699-message mailbox that the engine stores in 12
    // minutes sat for hours (found 2026-11-19 on the owner's Mac; the batch
    // controller then shrank the commits to its 8-message floor because each
    // commit was slow, which multiplied the checkpoints as well).
    //
    // A document's chunks are written in one go inside one transaction, so
    // they occupy one contiguous run of rowids. `search_docs` remembers that
    // run (`first_rowid`, `last_rowid`); clearing a document is then a rowid
    // range delete, which FTS5 serves from the rowid index without a scan,
    // and a document that has no row yet is not cleared at all. A row written
    // before the columns existed (NULL run) is still cleared by the old scan,
    // so nothing is ever left behind.

    /// The two columns, added on open to stores created before them.
    static let searchDocRunColumns = ["first_rowid", "last_rowid"]

    /// Adds `first_rowid` / `last_rowid` to `search_docs` when missing. Called
    /// at the end of every schema migration (so a store of any age has them
    /// before the first write) — no `user_version` change, no snapshot.
    func ensureSearchDocRunColumns(_ db: OpaquePointer) throws {
        let info = try prepare(db, "PRAGMA table_info(search_docs);")
        defer { sqlite3_finalize(info) }
        var present = Set<String>()
        while try stepRow(info, db) { present.insert(columnText(info, 1)) }
        guard !present.isEmpty else { return }   // the table is created later in the chain
        for column in Self.searchDocRunColumns where !present.contains(column) {
            try exec(db, "ALTER TABLE search_docs ADD COLUMN \(column) INTEGER;")
        }
    }

    /// The rowid run one document's chunks occupy.
    struct ChunkRun: Equatable { var first: Int64; var last: Int64 }

    /// What `search_docs` knows about a document before it is rewritten.
    enum ExistingSearchDocument: Equatable {
        /// No row: a fresh document, nothing to clear.
        case none
        /// A row with its chunk run recorded.
        case run(ChunkRun)
        /// A row written before the run columns, or with no chunks: cleared
        /// the old way (a scan) only when it may own chunk rows.
        case legacy(chunkCount: Int)
    }

    func existingSearchDocument(_ db: OpaquePointer, emailID: String, kind: String, ordinal: Int) throws -> ExistingSearchDocument {
        let stmt = try prepare(db, "SELECT chunk_count, first_rowid, last_rowid FROM search_docs WHERE email_id = ? AND kind = ? AND ordinal = ?;")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, emailID); bindText(stmt, 2, kind); sqlite3_bind_int64(stmt, 3, Int64(ordinal))
        guard try stepRow(stmt, db) else { return .none }
        if sqlite3_column_type(stmt, 1) != SQLITE_NULL, sqlite3_column_type(stmt, 2) != SQLITE_NULL {
            return .run(ChunkRun(first: sqlite3_column_int64(stmt, 1), last: sqlite3_column_int64(stmt, 2)))
        }
        return .legacy(chunkCount: Int(sqlite3_column_int64(stmt, 0)))
    }

    /// Removes the chunk rows of one document: by rowid run when known, by
    /// the old scan when the row predates the run columns. Still filtered on
    /// the document's identity, so a run can never take another document's rows.
    func clearSearchChunks(_ db: OpaquePointer, emailID: String, kind: String, ordinal: Int, existing: ExistingSearchDocument) throws {
        switch existing {
        case .none:
            return
        case .run(let run):
            let clear = try prepare(db, """
                DELETE FROM search_chunks WHERE rowid >= ? AND rowid <= ? AND email_id = ? AND kind = ? AND ordinal = ?;
            """)
            defer { sqlite3_finalize(clear) }
            sqlite3_bind_int64(clear, 1, run.first); sqlite3_bind_int64(clear, 2, run.last)
            bindText(clear, 3, emailID); bindText(clear, 4, kind); sqlite3_bind_int64(clear, 5, Int64(ordinal))
            guard sqlite3_step(clear) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
        case .legacy:
            // A legacy row may own chunk rows whatever its chunk_count says (a
            // streamed body appends chunks before its count is written), so the
            // scan is kept for it. Legacy rows are rewritten with a run below.
            let clear = try prepare(db, "DELETE FROM search_chunks WHERE email_id = ? AND kind = ? AND ordinal = ?;")
            defer { sqlite3_finalize(clear) }
            bindText(clear, 1, emailID); bindText(clear, 2, kind); sqlite3_bind_int64(clear, 3, Int64(ordinal))
            guard sqlite3_step(clear) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
        }
    }

    /// Removes one document entirely (chunks and row).
    func removeSearchDocument(_ db: OpaquePointer, emailID: String, kind: String, ordinal: Int) throws {
        let existing = try existingSearchDocument(db, emailID: emailID, kind: kind, ordinal: ordinal)
        guard existing != .none else { return }
        try clearSearchChunks(db, emailID: emailID, kind: kind, ordinal: ordinal, existing: existing)
        let clearDoc = try prepare(db, "DELETE FROM search_docs WHERE email_id = ? AND kind = ? AND ordinal = ?;")
        defer { sqlite3_finalize(clearDoc) }
        bindText(clearDoc, 1, emailID); bindText(clearDoc, 2, kind); sqlite3_bind_int64(clearDoc, 3, Int64(ordinal))
        guard sqlite3_step(clearDoc) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
    }

    /// Removes every document of `kind` whose ordinal lies in `ordinals`
    /// (children of one attachment): each by its run; one scan for all of them
    /// only when some row predates the run columns.
    func removeSearchDocuments(_ db: OpaquePointer, emailID: String, kind: String, ordinals: Range<Int>) throws {
        let list = try prepare(db, """
            SELECT ordinal, chunk_count, first_rowid, last_rowid FROM search_docs
            WHERE email_id = ? AND kind = ? AND ordinal >= ? AND ordinal < ?;
        """)
        bindText(list, 1, emailID); bindText(list, 2, kind)
        sqlite3_bind_int64(list, 3, Int64(ordinals.lowerBound)); sqlite3_bind_int64(list, 4, Int64(ordinals.upperBound))
        var runs: [(ordinal: Int, run: ChunkRun)] = []
        var needsScan = false
        var any = false
        while try stepRow(list, db) {
            any = true
            if sqlite3_column_type(list, 2) != SQLITE_NULL, sqlite3_column_type(list, 3) != SQLITE_NULL {
                runs.append((Int(sqlite3_column_int64(list, 0)), ChunkRun(first: sqlite3_column_int64(list, 2), last: sqlite3_column_int64(list, 3))))
            } else {
                needsScan = true
            }
        }
        sqlite3_finalize(list)
        guard any else { return }
        if needsScan {
            let clear = try prepare(db, "DELETE FROM search_chunks WHERE email_id = ? AND kind = ? AND ordinal >= ? AND ordinal < ?;")
            defer { sqlite3_finalize(clear) }
            bindText(clear, 1, emailID); bindText(clear, 2, kind)
            sqlite3_bind_int64(clear, 3, Int64(ordinals.lowerBound)); sqlite3_bind_int64(clear, 4, Int64(ordinals.upperBound))
            guard sqlite3_step(clear) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
        } else {
            for entry in runs {
                try clearSearchChunks(db, emailID: emailID, kind: kind, ordinal: entry.ordinal, existing: .run(entry.run))
            }
        }
        let clearDocs = try prepare(db, "DELETE FROM search_docs WHERE email_id = ? AND kind = ? AND ordinal >= ? AND ordinal < ?;")
        defer { sqlite3_finalize(clearDocs) }
        bindText(clearDocs, 1, emailID); bindText(clearDocs, 2, kind)
        sqlite3_bind_int64(clearDocs, 3, Int64(ordinals.lowerBound)); sqlite3_bind_int64(clearDocs, 4, Int64(ordinals.upperBound))
        guard sqlite3_step(clearDocs) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
    }

    /// Extends a document's recorded run to cover rows appended after it was
    /// written (the streamed body path). The first rowid is kept once set.
    func extendSearchDocumentRun(_ db: OpaquePointer, emailID: String, kind: String, ordinal: Int, first: Int64, last: Int64) throws {
        let update = try prepare(db, """
            UPDATE search_docs SET first_rowid = COALESCE(first_rowid, ?), last_rowid = ?
            WHERE email_id = ? AND kind = ? AND ordinal = ?;
        """)
        defer { sqlite3_finalize(update) }
        sqlite3_bind_int64(update, 1, first); sqlite3_bind_int64(update, 2, last)
        bindText(update, 3, emailID); bindText(update, 4, kind); sqlite3_bind_int64(update, 5, Int64(ordinal))
        guard sqlite3_step(update) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
    }

    // MARK: Writing documents

    /// Replace one document's chunks and state. `text` nil = no chunks; the
    /// state says why. Runs inside the caller's transaction.
    func indexSearchDocument(_ db: OpaquePointer, emailID: String, kind: SearchDocKind, ordinal: Int,
                             text: String?, state: SearchDocState, extractorVersion: Int = 0, ocr: Bool = false) throws {
        let existing = try existingSearchDocument(db, emailID: emailID, kind: kind.rawValue, ordinal: ordinal)
        try clearSearchChunks(db, emailID: emailID, kind: kind.rawValue, ordinal: ordinal, existing: existing)

        var chunkCount = 0
        var chars = 0
        var run: ChunkRun?
        if let text, !text.isEmpty {
            let insert = try prepare(db, "INSERT INTO search_chunks(email_id, kind, ordinal, chunk, text) VALUES (?,?,?,?,?);")
            defer { sqlite3_finalize(insert) }
            for (index, chunk) in SearchChunker.chunks(of: text).enumerated() {
                sqlite3_reset(insert); sqlite3_clear_bindings(insert)
                bindText(insert, 1, emailID); bindText(insert, 2, kind.rawValue)
                sqlite3_bind_int64(insert, 3, Int64(ordinal)); sqlite3_bind_int64(insert, 4, Int64(index))
                bindText(insert, 5, chunk)
                guard sqlite3_step(insert) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
                let rowid = sqlite3_last_insert_rowid(db)
                if run == nil { run = ChunkRun(first: rowid, last: rowid) } else { run?.last = rowid }
                chunkCount += 1
            }
            chars = text.count
        }
        let doc = try prepare(db, """
            INSERT INTO search_docs(email_id, kind, ordinal, revision, chunk_count, text_chars, state, extractor_version, ocr, first_rowid, last_rowid)
            VALUES (?,?,?,1,?,?,?,?,?,?,?)
            ON CONFLICT(email_id, kind, ordinal) DO UPDATE SET
                revision = search_docs.revision + 1, chunk_count = excluded.chunk_count, text_chars = excluded.text_chars,
                state = excluded.state, extractor_version = excluded.extractor_version, ocr = excluded.ocr,
                first_rowid = excluded.first_rowid, last_rowid = excluded.last_rowid;
        """)
        defer { sqlite3_finalize(doc) }
        bindText(doc, 1, emailID); bindText(doc, 2, kind.rawValue); sqlite3_bind_int64(doc, 3, Int64(ordinal))
        sqlite3_bind_int64(doc, 4, Int64(chunkCount)); sqlite3_bind_int64(doc, 5, Int64(chars))
        bindText(doc, 6, state.rawValue); sqlite3_bind_int64(doc, 7, Int64(extractorVersion)); sqlite3_bind_int(doc, 8, ocr ? 1 : 0)
        if let run {
            sqlite3_bind_int64(doc, 9, run.first); sqlite3_bind_int64(doc, 10, run.last)
        } else {
            // No chunks: an empty run (first > last) rather than NULL, so the
            // row is never mistaken for a legacy one and never scanned for.
            sqlite3_bind_int64(doc, 9, 1); sqlite3_bind_int64(doc, 10, 0)
        }
        guard sqlite3_step(doc) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
    }

    /// The message's own documents: subject, sender, recipients (To, Cc and
    /// Bcc), body (plain text, or the HTML's text). Whole text, no budget.
    /// R5: a message stored from its headers only (`deferredBody`) has its body
    /// in the original file — its body document is `partial` ("may match", not
    /// "no text") until `StreamedBodyIndexer` streams it in.
    func indexEmailSearchDocuments(_ db: OpaquePointer, email: MBOXParser.RawEmail, deferredBody: Bool = false) throws {
        let id = email.id.uuidString
        try indexSearchDocument(db, emailID: id, kind: .subject, ordinal: 0, text: email.headers["Subject"], state: .complete)
        try indexSearchDocument(db, emailID: id, kind: .sender, ordinal: 0, text: email.headers["From"], state: .complete)
        let recipients = [email.headers["To"], email.headers["Cc"] ?? email.headers["CC"], email.headers["Bcc"] ?? email.headers["BCC"]]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        try indexSearchDocument(db, emailID: id, kind: .recipients, ordinal: 0, text: recipients, state: .complete)
        let body = email.plainBody.isEmpty ? FTSSearchIndex.stripHTMLText(email.htmlBody) : email.plainBody
        if deferredBody, body.isEmpty {
            try indexSearchDocument(db, emailID: id, kind: .body, ordinal: 0, text: nil, state: .partial)
        } else {
            try indexSearchDocument(db, emailID: id, kind: .body, ordinal: 0, text: body,
                                    state: body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .noText : .complete)
        }
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
                let kind = document.kind
                // One document per attachment: whichever extractor produced it
                // (children keep their own kind and never clear the parent's).
                for other in SearchDocKind.attachmentContent where other != kind && kind != .childText {
                    try removeSearchDocument(db, emailID: id, kind: other.rawValue, ordinal: document.ordinal)
                }
                // FIND-08: cells, rows, slides, sheets and pages carry an explicit boundary.
                let text = document.text.map { SectionBoundary.marked($0, layout: SectionBoundary.layout(filename: document.filename)) }
                try indexSearchDocument(db, emailID: id, kind: kind, ordinal: document.ordinal, text: text,
                                        state: document.state, extractorVersion: document.extractorVersion, ocr: document.ocr)
            }
            try exec(db, "COMMIT;")
        } catch { try? exec(db, "ROLLBACK;"); throw error }
    }

    // MARK: Children of attachments (plan v4 §13.3 (5))

    /// v25: one row per file inside an attachment, so a search condition can
    /// address the child, evidence can name its path and the detail view can
    /// list and open it. Rewritten whole per parent attachment.
    func createSchemaV25(_ handle: OpaquePointer) throws {
        try exec(handle, """
            CREATE TABLE IF NOT EXISTS attachment_children(
                email_id    TEXT NOT NULL,
                position    INTEGER NOT NULL,
                child_index INTEGER NOT NULL,
                path        TEXT NOT NULL,
                filename    TEXT NOT NULL,
                kind        TEXT NOT NULL DEFAULT '',
                sha256      TEXT NOT NULL DEFAULT '',
                bytes       INTEGER NOT NULL DEFAULT 0,
                state       TEXT NOT NULL,
                note        TEXT,
                PRIMARY KEY(email_id, position, child_index)
            );
        """)
        try exec(handle, "CREATE INDEX IF NOT EXISTS idx_attachment_children_email ON attachment_children(email_id);")
    }

    /// Replaces the recorded children of attachment `position` and indexes
    /// each child's text as its own `childText` document (or its state).
    func recordAttachmentChildren(emailID: UUID, position: Int, children: [AttachmentChildRow],
                                  texts: [Int: String?], states: [Int: SearchDocState], extractorVersion: Int) throws {
        let db = try ensureDB()
        try exec(db, SQLiteHygiene.beginWrite)
        do {
            let id = emailID.uuidString
            try removeSearchDocuments(db, emailID: id, kind: SearchDocKind.childText.rawValue,
                                      ordinals: SearchDocKind.childOrdinal(parent: position, child: 0)..<SearchDocKind.childOrdinal(parent: position + 1, child: 0))
            let clearRows = try prepare(db, "DELETE FROM attachment_children WHERE email_id = ? AND position = ?;")
            bindText(clearRows, 1, id); sqlite3_bind_int64(clearRows, 2, Int64(position))
            _ = sqlite3_step(clearRows); sqlite3_finalize(clearRows)
            let insert = try prepare(db, """
                INSERT INTO attachment_children(email_id, position, child_index, path, filename, kind, sha256, bytes, state, note)
                VALUES (?,?,?,?,?,?,?,?,?,?);
            """)
            defer { sqlite3_finalize(insert) }
            for child in children {
                sqlite3_reset(insert); sqlite3_clear_bindings(insert)
                bindText(insert, 1, id); sqlite3_bind_int64(insert, 2, Int64(position)); sqlite3_bind_int64(insert, 3, Int64(child.childIndex))
                bindText(insert, 4, child.path); bindText(insert, 5, child.filename); bindText(insert, 6, child.kind)
                bindText(insert, 7, child.sha256); sqlite3_bind_int64(insert, 8, Int64(child.bytes)); bindText(insert, 9, child.state)
                if let note = child.note { bindText(insert, 10, note) } else { sqlite3_bind_null(insert, 10) }
                guard sqlite3_step(insert) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
                let text = (texts[child.childIndex] ?? nil).map {
                    SectionBoundary.marked($0, layout: SectionBoundary.layout(filename: child.filename, recordedKind: child.kind))   // FIND-08
                }
                let state = states[child.childIndex] ?? .unsupported
                try indexSearchDocument(db, emailID: id, kind: .childText, ordinal: child.ordinal, text: text, state: state,
                                        extractorVersion: extractorVersion, ocr: false)
            }
            try exec(db, "COMMIT;")
        } catch { try? exec(db, "ROLLBACK;"); throw error }
    }

    /// §13.3 (8): how many files inside attachments are in each state, archive-wide.
    func attachmentChildStateCounts() throws -> [String: Int] {
        let db = try ensureDB()
        let stmt = try prepare(db, "SELECT state, COUNT(*) FROM attachment_children GROUP BY state;")
        defer { sqlite3_finalize(stmt) }
        var out: [String: Int] = [:]
        while try stepRow(stmt, db) { out[columnText(stmt, 0)] = Int(sqlite3_column_int64(stmt, 1)) }
        return out
    }

    /// §13.3 (9): the whole extracted text of one attachment document (or of
    /// one file inside it, by its child ordinal), joined from its chunks —
    /// for reading, so the FIND-08 boundary characters are hidden.
    func attachmentDocumentText(emailID: UUID, ordinal: Int) throws -> String? {
        let db = try ensureDB()
        let stmt = try prepare(db, """
            SELECT text FROM search_chunks WHERE email_id = ? AND ordinal = ? AND kind IN (\(SearchDocKind.attachmentContentSQL), 'childText') ORDER BY chunk;
        """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, emailID.uuidString); sqlite3_bind_int64(stmt, 2, Int64(ordinal))
        var pieces: [String] = []
        while try stepRow(stmt, db) { pieces.append(columnText(stmt, 0)) }
        return pieces.isEmpty ? nil : SectionBoundary.hidden(pieces.joined())
    }

    /// The recorded children of every attachment of one message.
    func attachmentChildren(forEmailID emailID: UUID) throws -> [AttachmentChildRow] {
        let db = try ensureDB()
        let stmt = try prepare(db, """
            SELECT position, child_index, path, filename, kind, sha256, bytes, state, note
            FROM attachment_children WHERE email_id = ? ORDER BY position, child_index;
        """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, emailID.uuidString)
        var out: [AttachmentChildRow] = []
        while try stepRow(stmt, db) {
            out.append(AttachmentChildRow(
                emailID: emailID, position: Int(sqlite3_column_int64(stmt, 0)), childIndex: Int(sqlite3_column_int64(stmt, 1)),
                path: columnText(stmt, 2), filename: columnText(stmt, 3), kind: columnText(stmt, 4), sha256: columnText(stmt, 5),
                bytes: Int(sqlite3_column_int64(stmt, 6)), state: columnText(stmt, 7),
                note: sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : columnText(stmt, 8)))
        }
        return out
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
            for email in emails {
                try indexEmailSearchDocuments(db, email: email, deferredBody: try isDeferredBody(db, emailID: email.id.uuidString))
            }
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
              AND NOT EXISTS (SELECT 1 FROM search_docs d WHERE d.email_id = e.id AND d.kind IN (\(SearchDocKind.attachmentContentSQL)))
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
            attachmentsEvaluable: try scalarInt(db, "SELECT COUNT(*) FROM search_docs WHERE kind IN (\(SearchDocKind.attachmentContentSQL)) AND state IN ('complete','noText');"),
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
