//
//  SQLiteEmailStore+ChildContinuation.swift
//  ArchiveCore
//
//  R5 (audit bf1a5b9): the store side of a continuing Resume round
//  (`ExtractionContinuation`). The round re-reads only the files inside the
//  attachment that stopped; the files an earlier round read whole are
//  CARRIED: their recorded row and their indexed text move to their place in
//  the new list unchanged, copied inside SQLite (never through memory), in the
//  same transaction that writes the newly read files. Nothing that was
//  searchable before the round can stop being searchable because of it.
//

import Foundation
import SQLite3

extension SQLiteEmailStore {

    /// Replaces the children of attachment `position`, like
    /// `recordAttachmentChildren`, except that a child listed in `carriedFrom`
    /// (new child index → its child index in the previous record) keeps its
    /// previous `childText` document — chunks, state, counts — under its new
    /// ordinal. Its row in `children` should carry the previous row's facts.
    func recordAttachmentChildrenContinuing(emailID: UUID, position: Int, children: [AttachmentChildRow],
                                            carriedFrom: [Int: Int], texts: [Int: String?], states: [Int: SearchDocState],
                                            extractorVersion: Int) throws {
        let db = try ensureDB()
        try exec(db, SQLiteHygiene.beginWrite)
        do {
            let id = emailID.uuidString
            try exec(db, "CREATE TEMP TABLE IF NOT EXISTS r5_carried_chunks(new_ordinal INTEGER, chunk INTEGER, text TEXT);")
            try exec(db, "CREATE TEMP TABLE IF NOT EXISTS r5_carried_docs(new_ordinal INTEGER, chunk_count INTEGER, text_chars INTEGER, state TEXT, extractor_version INTEGER);")
            try exec(db, "DELETE FROM temp.r5_carried_chunks; DELETE FROM temp.r5_carried_docs;")
            // 1. The carried documents, set aside under their new ordinals.
            let copyChunks = try prepare(db, """
                INSERT INTO temp.r5_carried_chunks(new_ordinal, chunk, text)
                SELECT ?, chunk, text FROM search_chunks WHERE email_id = ? AND kind = 'childText' AND ordinal = ?;
            """)
            defer { sqlite3_finalize(copyChunks) }
            let copyDoc = try prepare(db, """
                INSERT INTO temp.r5_carried_docs(new_ordinal, chunk_count, text_chars, state, extractor_version)
                SELECT ?, chunk_count, text_chars, state, extractor_version FROM search_docs WHERE email_id = ? AND kind = 'childText' AND ordinal = ?;
            """)
            defer { sqlite3_finalize(copyDoc) }
            for (newIndex, oldIndex) in carriedFrom {
                let newOrdinal = Int64(SearchDocKind.childOrdinal(parent: position, child: newIndex))
                let oldOrdinal = Int64(SearchDocKind.childOrdinal(parent: position, child: oldIndex))
                for stmt in [copyChunks, copyDoc] {
                    sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
                    sqlite3_bind_int64(stmt, 1, newOrdinal); bindText(stmt, 2, id); sqlite3_bind_int64(stmt, 3, oldOrdinal)
                    guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
                }
            }
            // 2. The previous record of this attachment's children, cleared.
            let low = Int64(SearchDocKind.childOrdinal(parent: position, child: 0))
            let high = Int64(SearchDocKind.childOrdinal(parent: position + 1, child: 0))
            for sql in ["DELETE FROM search_chunks WHERE email_id = ? AND kind = 'childText' AND ordinal >= ? AND ordinal < ?;",
                        "DELETE FROM search_docs WHERE email_id = ? AND kind = 'childText' AND ordinal >= ? AND ordinal < ?;"] {
                let clear = try prepare(db, sql)
                defer { sqlite3_finalize(clear) }
                bindText(clear, 1, id); sqlite3_bind_int64(clear, 2, low); sqlite3_bind_int64(clear, 3, high)
                guard sqlite3_step(clear) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
            }
            let clearRows = try prepare(db, "DELETE FROM attachment_children WHERE email_id = ? AND position = ?;")
            defer { sqlite3_finalize(clearRows) }
            bindText(clearRows, 1, id); sqlite3_bind_int64(clearRows, 2, Int64(position))
            guard sqlite3_step(clearRows) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
            // 3. The new record: carried documents moved back, new ones indexed.
            let insert = try prepare(db, """
                INSERT INTO attachment_children(email_id, position, child_index, path, filename, kind, sha256, bytes, state, note)
                VALUES (?,?,?,?,?,?,?,?,?,?);
            """)
            defer { sqlite3_finalize(insert) }
            let restoreChunks = try prepare(db, """
                INSERT INTO search_chunks(email_id, kind, ordinal, chunk, text)
                SELECT ?, 'childText', new_ordinal, chunk, text FROM temp.r5_carried_chunks WHERE new_ordinal = ? ORDER BY chunk;
            """)
            defer { sqlite3_finalize(restoreChunks) }
            let restoreDoc = try prepare(db, """
                INSERT INTO search_docs(email_id, kind, ordinal, revision, chunk_count, text_chars, state, extractor_version, ocr)
                SELECT ?, 'childText', new_ordinal, 1, chunk_count, text_chars, state, extractor_version, 0
                FROM temp.r5_carried_docs WHERE new_ordinal = ?;
            """)
            defer { sqlite3_finalize(restoreDoc) }
            for child in children {
                sqlite3_reset(insert); sqlite3_clear_bindings(insert)
                bindText(insert, 1, id); sqlite3_bind_int64(insert, 2, Int64(position)); sqlite3_bind_int64(insert, 3, Int64(child.childIndex))
                bindText(insert, 4, child.path); bindText(insert, 5, child.filename); bindText(insert, 6, child.kind)
                bindText(insert, 7, child.sha256); sqlite3_bind_int64(insert, 8, Int64(child.bytes)); bindText(insert, 9, child.state)
                if let note = child.note { bindText(insert, 10, note) } else { sqlite3_bind_null(insert, 10) }
                guard sqlite3_step(insert) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
                if carriedFrom[child.childIndex] != nil {
                    for stmt in [restoreChunks, restoreDoc] {
                        sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
                        bindText(stmt, 1, id); sqlite3_bind_int64(stmt, 2, Int64(child.ordinal))
                        guard sqlite3_step(stmt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
                    }
                    continue
                }
                let text = (texts[child.childIndex] ?? nil).map {
                    SectionBoundary.marked($0, layout: SectionBoundary.layout(filename: child.filename, recordedKind: child.kind))   // FIND-08
                }
                try indexSearchDocument(db, emailID: id, kind: .childText, ordinal: child.ordinal, text: text,
                                        state: states[child.childIndex] ?? .unsupported, extractorVersion: extractorVersion, ocr: false)
            }
            try exec(db, "DELETE FROM temp.r5_carried_chunks; DELETE FROM temp.r5_carried_docs;")
            try exec(db, "COMMIT;")
        } catch { try? exec(db, "ROLLBACK;"); throw error }
    }
}
