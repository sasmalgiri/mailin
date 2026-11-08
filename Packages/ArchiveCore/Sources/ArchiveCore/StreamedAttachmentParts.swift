//
//  StreamedAttachmentParts.swift
//  ArchiveCore
//
//  R5b (audit bf1a5b9; owner 2026-11-08: "there should be no limit at all"):
//  the attachments of a message kept by its byte range — a message above the
//  full-parse ceiling — have their CONTENTS searched, not only their names.
//
//  1. `StreamingMIMETextReader` records, for every attachment part it walks
//     past, the absolute byte range of the part's still-encoded content in the
//     original file (a `PartLocator`), and counts its decoded size.
//  2. When the body stream finishes, `registerStreamedAttachments` writes those
//     ranges to `part_locators`, lists the attachments in the message's
//     attachment table (so attachment conditions, the "has attachments" filter
//     and Open address them like any other), and puts the message on the
//     attachment job's work list.
//  3. The attachment job (`streamedAttachmentWorkList`) streams each part's
//     decoded bytes from its range to a temp file with `StreamedPartDecoder`
//     — base64 and quoted-printable decoded on the fly, memory bounded by one
//     slice and one carry, never by the attachment — and runs the normal
//     reader (and its children) on the file.
//

import Foundation
import SQLite3

/// One attachment part of a streamed message.
struct StreamedAttachmentPart: Sendable, Equatable {
    var locator: PartLocator
    /// The decoded size: exact for base64, the content length otherwise.
    var decodedBytes: Int64
    var isInline: Bool
}

/// Streams one part's content from its byte range in the original file to a
/// file, decoding its transfer encoding as it goes.
enum StreamedPartDecoder {

    struct Result: Sendable, Equatable {
        var bytesWritten: Int64 = 0
        var bytesRead: Int64 = 0
        /// High-water mark of the slice plus the decoder's carry plus one decoded slice.
        var peakBufferedBytes = 0
    }

    /// A quoted-printable line longer than this is decoded in pieces.
    static let lineCarryBytes = 64 * 1024

    static func decode(part: PartLocator, sourcePath: String, to url: URL, sliceBytes: Int = 1 << 20) throws -> Result {
        guard FileManager.default.fileExists(atPath: sourcePath) else { throw LocatorReadError.sourceMissing(sourcePath) }
        let size = (try? FileManager.default.attributesOfItem(atPath: sourcePath)[.size] as? NSNumber)?.int64Value ?? 0
        let range = part.contentRange
        guard range.offset >= 0, range.end <= size else { throw LocatorReadError.rangeUnresolvable(range, fileSize: size) }
        guard let input = FileHandle(forReadingAtPath: sourcePath) else { throw LocatorReadError.ioError("cannot open \(sourcePath)") }
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let output = try? FileHandle(forWritingTo: url) else {
            throw LocatorReadError.ioError("cannot write \(url.lastPathComponent)")
        }
        defer { try? output.close() }
        do { try input.seek(toOffset: UInt64(range.offset)) } catch { throw LocatorReadError.ioError(error.localizedDescription) }

        enum Transfer { case identity, base64, quotedPrintable }
        let transfer: Transfer
        switch (part.contentTransferEncoding ?? "").lowercased() {
        case "base64": transfer = .base64
        case "quoted-printable": transfer = .quotedPrintable
        default: transfer = .identity
        }
        var result = Result()
        var remaining = range.length
        var carry = Data()
        let step = max(4_096, sliceBytes)

        func write(_ data: Data) throws {
            guard !data.isEmpty else { return }
            try output.write(contentsOf: data)
            result.bytesWritten += Int64(data.count)
        }

        while remaining > 0 {
            try Task.checkCancellation()
            let want = Int(min(Int64(step), remaining))
            let slice: Data
            do {
                guard let read = try autoreleasepool(invoking: { try input.read(upToCount: want) }), !read.isEmpty else {
                    throw LocatorReadError.rangeUnresolvable(range, fileSize: range.offset + (range.length - remaining))
                }
                slice = read
            } catch let error as LocatorReadError { throw error } catch { throw LocatorReadError.ioError(error.localizedDescription) }
            remaining -= Int64(slice.count)
            result.bytesRead += Int64(slice.count)
            var decoded = Data()
            switch transfer {
            case .identity:
                decoded = slice
            case .base64:
                for byte in slice where TextPartDecoder.isBase64Data(byte) || byte == 0x3D { carry.append(byte) }
                let whole = carry.count - carry.count % 4
                if whole > 0 {
                    decoded = base64Groups(carry.prefix(whole))
                    carry = Data(carry.dropFirst(whole))
                }
            case .quotedPrintable:
                carry.append(slice)
                // Decode up to the last line break; a line longer than the carry is cut
                // where no `=XY` escape or soft break can straddle the cut.
                var cut = carry.lastIndex(of: 0x0A).map { carry.distance(from: carry.startIndex, to: $0) + 1 } ?? 0
                if cut == 0, carry.count >= lineCarryBytes {
                    let bytes = [UInt8](carry.suffix(2))
                    cut = carry.count
                    if bytes.last == 0x3D { cut -= 1 } else if bytes.first == 0x3D { cut -= 2 }
                }
                if cut > 0 {
                    decoded = QuotedPrintableDecoder.decodeBytes(Data(carry.prefix(cut)))
                    carry = Data(carry.dropFirst(cut))
                }
            }
            result.peakBufferedBytes = max(result.peakBufferedBytes, slice.count + carry.count + decoded.count)
            try write(decoded)
        }
        switch transfer {
        case .identity: break
        case .base64:
            if !carry.isEmpty {
                while carry.count % 4 != 0 { carry.append(0x3D) }
                try write(base64Groups(carry))
            }
        case .quotedPrintable:
            if !carry.isEmpty { try write(QuotedPrintableDecoder.decodeBytes(carry)) }
        }
        return result
    }

    /// Whole groups; a group padded in the middle (two encodings run together) is decoded group by group.
    private static func base64Groups(_ groups: Data) -> Data {
        if let whole = Data(base64Encoded: groups) { return whole }
        var out = Data()
        var index = groups.startIndex
        while groups.distance(from: index, to: groups.endIndex) >= 4 {
            let next = groups.index(index, offsetBy: 4)
            if let group = Data(base64Encoded: Data(groups[index..<next])) { out.append(group) }
            index = next
        }
        return out
    }
}

// MARK: - The store side

extension SQLiteEmailStore {

    /// Registers the attachment parts a body stream met (inside the stream's
    /// transaction): their byte ranges, the message's attachment list, its
    /// has-attachments flag — and clears its attachment-text attempt, so the
    /// attachment job reads their contents (again, after a re-stream).
    func registerStreamedAttachments(_ db: OpaquePointer, emailID: UUID, parts: [StreamedAttachmentPart]) throws {
        let id = emailID.uuidString
        try writePartLocators(db, parts.map(\.locator), emailID: emailID)
        let clear = try prepare(db, "DELETE FROM attachments WHERE email_id = ?;")
        bindText(clear, 1, id)
        let cleared = sqlite3_step(clear) == SQLITE_DONE
        sqlite3_finalize(clear)
        guard cleared else { throw SQLiteStoreError.step(lastError(db)) }
        let insert = try prepare(db, """
            INSERT INTO attachments(email_id, position, filename, mime_type, size_bytes, content_id, is_inline)
            VALUES (?,?,?,?,?,?,?);
        """)
        defer { sqlite3_finalize(insert) }
        for (position, part) in parts.enumerated() {
            sqlite3_reset(insert); sqlite3_clear_bindings(insert)
            bindText(insert, 1, id)
            sqlite3_bind_int64(insert, 2, Int64(position))
            bindText(insert, 3, part.locator.filename ?? "")
            bindText(insert, 4, part.locator.mimeType)
            sqlite3_bind_int64(insert, 5, part.decodedBytes)
            bindTextOrNull(insert, 6, part.locator.contentID)
            sqlite3_bind_int(insert, 7, part.isInline ? 1 : 0)
            guard sqlite3_step(insert) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
        }
        let flag = try prepare(db, "UPDATE emails SET has_attach = ?, attachment_count = ? WHERE id = ?;")
        defer { sqlite3_finalize(flag) }
        sqlite3_bind_int(flag, 1, parts.isEmpty ? 0 : 1)
        sqlite3_bind_int64(flag, 2, Int64(parts.count))
        bindText(flag, 3, id)
        guard sqlite3_step(flag) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
        let attempt = try prepare(db, "DELETE FROM attachment_text_state WHERE email_id = ?;")
        defer { sqlite3_finalize(attempt) }
        bindText(attempt, 1, id)
        guard sqlite3_step(attempt) == SQLITE_DONE else { throw SQLiteStoreError.step(lastError(db)) }
    }

    /// The attachment job's work list for streamed messages: stored from their
    /// headers, body streamed (so their parts are registered), attachments not
    /// yet attempted.
    func streamedAttachmentWorkList(limit: Int) throws -> [UUID] {
        let db = try ensureDB()
        let stmt = try prepare(db, """
            SELECT l.email_id FROM message_locators l
            WHERE l.body_decoded = 0
              AND EXISTS (SELECT 1 FROM part_locators p WHERE p.email_id = l.email_id)
              AND NOT EXISTS (SELECT 1 FROM attachment_text_state s WHERE s.email_id = l.email_id)
              AND NOT EXISTS (SELECT 1 FROM search_docs d WHERE d.email_id = l.email_id AND d.kind = 'body'
                              AND (d.state = 'partial' OR d.extractor_version < ?))
            ORDER BY l.ordinal LIMIT ?;
        """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(StreamedBodyIndexer.version))
        sqlite3_bind_int(stmt, 2, Int32(clamping: limit))
        var out: [UUID] = []
        while try stepRow(stmt, db) { if let id = columnUUID(stmt, 0) { out.append(id) } }
        return out
    }

    /// Of `ids`, the messages whose attachments are read from registered byte
    /// ranges (stored from their headers, parts recorded).
    func streamedAttachmentMessages(among ids: [UUID]) throws -> Set<UUID> {
        guard !ids.isEmpty else { return [] }
        let db = try ensureDB()
        var out = Set<UUID>()
        for start in stride(from: 0, to: ids.count, by: 500) {
            let chunk = ids[start..<min(start + 500, ids.count)]
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let stmt = try prepare(db, """
                SELECT l.email_id FROM message_locators l
                WHERE l.body_decoded = 0 AND l.email_id IN (\(marks))
                  AND EXISTS (SELECT 1 FROM part_locators p WHERE p.email_id = l.email_id);
            """)
            defer { sqlite3_finalize(stmt) }
            for (i, id) in chunk.enumerated() { bindText(stmt, Int32(i + 1), id.uuidString) }
            while try stepRow(stmt, db) { if let id = columnUUID(stmt, 0) { out.insert(id) } }
        }
        return out
    }

    /// One streamed message's attachment parts (in attachment order) and the file they are in.
    func streamedAttachmentParts(emailID: UUID) throws -> (sourcePath: String, parts: [PartLocator])? {
        guard let locator = try locator(forEmailID: emailID) else { return nil }
        return (locator.sourcePath, try partLocators(forEmailID: emailID))
    }
}
