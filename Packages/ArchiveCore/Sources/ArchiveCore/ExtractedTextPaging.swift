//
//  ExtractedTextPaging.swift
//  ArchiveCore
//
//  R7 (audit bf1a5b9, FIND-05 / FIND-08): "Show text" reads an attachment's
//  extracted text a few chunks at a time, never whole.
//
//   - Existence: one EXISTS on `search_docs` (the chunk table's per-document
//     row, primary key email_id/kind/ordinal) — no chunk text is read to
//     decide whether the button is shown.
//   - Outline: the document's chunk count and size, from the same row.
//   - Pages: the chunks of one range, raw (U+001E boundaries kept, so the
//     viewer matches on exactly what search matched on).
//   - Match counts: one streaming pass over the document's chunks, holding
//     at most three chunks at a time and keeping only a count per chunk, so
//     Next / Previous can step through every match of a multi-gigabyte text.
//
//  Matching is the search's own phrase rule (`mailin_phrase`, FIND-08): ASCII
//  letters fold case, any run of White_Space is one space, U+001E is never
//  crossed, everything else is literal.
//

import Foundation
import SQLite3

/// What the text viewer knows about a document before it reads any text.
struct AttachmentDocumentOutline: Sendable, Equatable {
    let kind: SearchDocKind
    let chunkCount: Int
    /// Characters indexed (boundary characters included).
    let characters: Int
}

extension SectionBoundary {

    /// R7: the phrase rule (`mailin_phrase`) as a pattern — the literal's
    /// words joined by "one or more White_Space characters", ASCII letters in
    /// either case, everything else literal. U+001E is not White_Space, so a
    /// match never crosses a section boundary. Nil for an empty literal.
    static func phraseRegex(_ literal: String) -> NSRegularExpression? {
        let words = literal.split(whereSeparator: { $0.isWhitespace || $0 == character })
        guard !words.isEmpty else { return nil }
        let gap = "[\\t\\n\\u000B\\f\\r \\u0085\\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000]+"
        let pattern = words.map { word in
            word.unicodeScalars.map { s -> String in
                let v = UInt8(truncatingIfNeeded: s.value)
                if s.value < 0x80, (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v) {
                    return "[\(Character(Unicode.Scalar(v | 0x20)))\(Character(Unicode.Scalar(v & 0xDF)))]"
                }
                return NSRegularExpression.escapedPattern(for: String(s))
            }.joined()
        }.joined(separator: gap)
        return try? NSRegularExpression(pattern: pattern, options: [])
    }

    /// Every occurrence of `literal` in `text` under the phrase rule, as
    /// UTF-16 ranges, left to right and not overlapping.
    static func phraseRanges(of literal: String, in text: String) -> [NSRange] {
        guard let regex = phraseRegex(literal) else { return [] }
        return regex.matches(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length)).map(\.range)
    }
}

/// R7: matches inside one chunk of a document whose text is stored in
/// contiguous chunks. A phrase may run from one chunk into the next (chunks
/// split at whitespace), so the end of the previous chunk and the start of
/// the next are read with it. A match belongs to the chunk it STARTS in.
enum PhraseChunks {
    /// How much of each neighbour is read with a chunk: enough for the phrase
    /// with generous whitespace. (A phrase that crosses a chunk join inside a
    /// whitespace run longer than this is not found at the join.)
    static func context(for regex: NSRegularExpression) -> Int { regex.pattern.utf16.count * 2 + 256 }

    struct Matches: Equatable {
        /// Matches that start in the chunk, in the chunk's UTF-16 offsets (one
        /// may run past the chunk's end into the next).
        var starting: [NSRange]
        /// Every match's part inside the chunk (including the end of a match
        /// that started in the previous chunk) — what the viewer marks.
        var marks: [NSRange]
    }

    static func matches(in chunk: String, previous: String?, next: String?, regex: NSRegularExpression) -> Matches {
        let context = context(for: regex)
        let before = previous.map { String(String.UnicodeScalarView($0.unicodeScalars.suffix(context))) } ?? ""
        let after = next.map { String(String.UnicodeScalarView($0.unicodeScalars.prefix(context))) } ?? ""
        let b = before.utf16.count, length = chunk.utf16.count
        let combined = before + chunk + after
        var out = Matches(starting: [], marks: [])
        for m in regex.matches(in: combined, options: [], range: NSRange(location: 0, length: (combined as NSString).length)) {
            let r = m.range
            if r.location >= b && r.location < b + length {
                out.starting.append(NSRange(location: r.location - b, length: r.length))
            }
            let lo = max(r.location, b), hi = min(r.location + r.length, b + length)
            if hi > lo { out.marks.append(NSRange(location: lo - b, length: hi - lo)) }
        }
        return out
    }
}

extension SQLiteEmailStore {

    private static let documentKindsSQL = "\(SearchDocKind.attachmentContentSQL), 'childText'"

    /// R7: whether one attachment document (or file inside one) has stored
    /// text — the Show text button. Reads the document row only.
    func attachmentDocumentHasText(emailID: UUID, ordinal: Int) throws -> Bool {
        let db = try ensureDB()
        let stmt = try prepare(db, """
            SELECT EXISTS(SELECT 1 FROM search_docs WHERE email_id = ? AND ordinal = ? AND kind IN (\(Self.documentKindsSQL)) AND chunk_count > 0);
        """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, emailID.uuidString); sqlite3_bind_int64(stmt, 2, Int64(ordinal))
        guard try stepRow(stmt, db) else { return false }
        return sqlite3_column_int64(stmt, 0) != 0
    }

    /// R7: the document's kind, chunk count and size — no text read.
    func attachmentDocumentOutline(emailID: UUID, ordinal: Int) throws -> AttachmentDocumentOutline? {
        let db = try ensureDB()
        let stmt = try prepare(db, """
            SELECT kind, chunk_count, text_chars FROM search_docs
            WHERE email_id = ? AND ordinal = ? AND kind IN (\(Self.documentKindsSQL)) AND chunk_count > 0
            ORDER BY CASE kind WHEN 'attachmentText' THEN 0 WHEN 'ocrText' THEN 1 WHEN 'speechText' THEN 2 ELSE 3 END LIMIT 1;
        """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, emailID.uuidString); sqlite3_bind_int64(stmt, 2, Int64(ordinal))
        guard try stepRow(stmt, db), let kind = SearchDocKind(rawValue: columnText(stmt, 0)) else { return nil }
        return AttachmentDocumentOutline(kind: kind, chunkCount: Int(sqlite3_column_int64(stmt, 1)), characters: Int(sqlite3_column_int64(stmt, 2)))
    }

    /// R7: the chunks `range` of one document, raw (boundaries kept), by chunk number.
    func attachmentDocumentChunks(emailID: UUID, ordinal: Int, kind: SearchDocKind, range: ClosedRange<Int>) throws -> [Int: String] {
        let db = try ensureDB()
        let stmt = try prepare(db, """
            SELECT chunk, text FROM search_chunks WHERE email_id = ? AND kind = ? AND ordinal = ? AND chunk BETWEEN ? AND ?;
        """)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, emailID.uuidString); bindText(stmt, 2, kind.rawValue); sqlite3_bind_int64(stmt, 3, Int64(ordinal))
        sqlite3_bind_int64(stmt, 4, Int64(range.lowerBound)); sqlite3_bind_int64(stmt, 5, Int64(range.upperBound))
        var out: [Int: String] = [:]
        while try stepRow(stmt, db) { out[Int(sqlite3_column_int64(stmt, 0))] = columnText(stmt, 1) }
        return out
    }

    /// R7: how many phrase-rule matches of `literal` start in each chunk of
    /// the document (index = chunk number). One pass in stored order with at
    /// most three chunks held; nil when cancelled.
    func attachmentDocumentMatchCounts(emailID: UUID, ordinal: Int, kind: SearchDocKind, literal: String) throws -> [Int]? {
        guard let regex = SectionBoundary.phraseRegex(literal) else { return [] }
        let db = try ensureDB()
        // Chunks are written in order, so rowid order is chunk order without a sort.
        let stmt = try prepare(db, "SELECT chunk, text FROM search_chunks WHERE email_id = ? AND kind = ? AND ordinal = ? ORDER BY rowid;")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, emailID.uuidString); bindText(stmt, 2, kind.rawValue); sqlite3_bind_int64(stmt, 3, Int64(ordinal))
        var counts: [Int] = []
        func add(_ chunk: Int, _ n: Int) {
            if counts.count <= chunk { counts.append(contentsOf: repeatElement(0, count: chunk + 1 - counts.count)) }
            counts[chunk] += n
        }
        var previous: (index: Int, text: String)? = nil
        var current: (index: Int, text: String)? = nil
        func settle(next: (index: Int, text: String)?) {
            guard let cur = current else { return }
            let before = previous.flatMap { $0.index == cur.index - 1 ? $0.text : nil }
            let after = next.flatMap { $0.index == cur.index + 1 ? $0.text : nil }
            add(cur.index, PhraseChunks.matches(in: cur.text, previous: before, next: after, regex: regex).starting.count)
        }
        while try stepRow(stmt, db) {
            if Task.isCancelled { return nil }
            let next = (index: Int(sqlite3_column_int64(stmt, 0)), text: columnText(stmt, 1))
            settle(next: next)
            previous = current
            current = next
        }
        settle(next: nil)
        return counts
    }
}
