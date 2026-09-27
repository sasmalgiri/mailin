//
//  MBOXRecordBuilder+Quoting.swift
//  ArchiveCore
//
//  H1: mbox `>From ` quoting that survives every line ending and a message
//  whose very first line starts with "From ". The previous rule replaced
//  "\nFrom " only, so a body line beginning "From " at byte 0 of the record,
//  or a CR-only file, could be read back as a message boundary by the next
//  importer.
//
//  Everything here works on UTF-8 BYTES, not Characters: Swift folds "\r\n"
//  into one Character, so a Character-level search for "\n" or "\r" walks
//  straight past a CRLF line ending and misses the line that follows it
//  (found 2026-09-27 by the executed quoting test).
//

import Foundation

extension MBOXRecordBuilder {

    static let lf: UInt8 = 0x0A
    static let cr: UInt8 = 0x0D

    /// Quote every line that begins with `From ` (and lines already quoted,
    /// `>From `, `>>From `…, so unquoting on import stays reversible). Line
    /// endings are preserved: LF, CRLF and bare CR all count as boundaries.
    static func quoteFromLines(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        return String(decoding: quoteFromLines(bytes: Array(raw.utf8)), as: UTF8.self)
    }

    /// Byte-level form; `bytes` must start at a line boundary.
    static func quoteFromLines(bytes: [UInt8]) -> [UInt8] {
        guard !bytes.isEmpty else { return bytes }
        var out = [UInt8]()
        out.reserveCapacity(bytes.count + 64)
        var index = 0
        while index < bytes.count {
            // Find the end of this line's content.
            var lineEnd = index
            while lineEnd < bytes.count, bytes[lineEnd] != lf, bytes[lineEnd] != cr { lineEnd += 1 }
            // The terminator: LF, CR, or CRLF as one unit.
            var terminatorEnd = lineEnd
            if terminatorEnd < bytes.count {
                if bytes[terminatorEnd] == cr, terminatorEnd + 1 < bytes.count, bytes[terminatorEnd + 1] == lf {
                    terminatorEnd += 2
                } else {
                    terminatorEnd += 1
                }
            }
            if needsQuoting(bytes[index..<lineEnd]) { out.append(UInt8(ascii: ">")) }
            out.append(contentsOf: bytes[index..<terminatorEnd])
            index = terminatorEnd
        }
        return out
    }

    /// The inverse of `quoteFromLines` — RFC 4155 mboxrd reading: every line
    /// matching `^>+From ` loses exactly one `>`. Applied by both import
    /// engines to a record that arrived WITH an mbox envelope (a bare .eml
    /// has no container escaping to undo). Without it a Takeout / Apple Mail /
    /// Thunderbird mailbox's quoted body lines stayed `>From …` in the archive
    /// and came back `>>From …` from mailin's own export (found 2026-09-27 by
    /// the executed round trip).
    static func unquoteFromLines(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        let bytes = Array(raw.utf8)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            var lineEnd = index
            while lineEnd < bytes.count, bytes[lineEnd] != lf, bytes[lineEnd] != cr { lineEnd += 1 }
            var terminatorEnd = lineEnd
            if terminatorEnd < bytes.count {
                if bytes[terminatorEnd] == cr, terminatorEnd + 1 < bytes.count, bytes[terminatorEnd + 1] == lf {
                    terminatorEnd += 2
                } else {
                    terminatorEnd += 1
                }
            }
            let line = bytes[index..<lineEnd]
            if line.first == UInt8(ascii: ">"), needsQuoting(line) {
                out.append(contentsOf: bytes[(index + 1)..<terminatorEnd])
            } else {
                out.append(contentsOf: bytes[index..<terminatorEnd])
            }
            index = terminatorEnd
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// The leading mbox envelope line of `raw` (without its terminator) when
    /// it has one. Only a line that is envelope-SHAPED counts (`From `
    /// followed by text containing a four-digit year), never a `From:` header.
    static func envelopeLine(in raw: String) -> String? {
        guard raw.hasPrefix("From ") else { return nil }
        let bytes = Array(raw.utf8)
        var lineEnd = 0
        while lineEnd < bytes.count, bytes[lineEnd] != lf, bytes[lineEnd] != cr { lineEnd += 1 }
        let first = String(decoding: bytes[0..<lineEnd], as: UTF8.self)
        guard first.count > 5, first.range(of: #"\d{4}"#, options: .regularExpression) != nil else { return nil }
        return first
    }

    /// The message without its leading mbox envelope line, when it has one.
    static func strippingEnvelopeLine(_ raw: String) -> String {
        guard envelopeLine(in: raw) != nil else { return raw }
        let bytes = Array(raw.utf8)
        var lineEnd = 0
        while lineEnd < bytes.count, bytes[lineEnd] != lf, bytes[lineEnd] != cr { lineEnd += 1 }
        var next = lineEnd
        if next < bytes.count {
            if bytes[next] == cr, next + 1 < bytes.count, bytes[next + 1] == lf { next += 2 } else { next += 1 }
        }
        return String(decoding: bytes[next...], as: UTF8.self)
    }

    /// `From ` with any number of leading `>` — RFC 4155's mboxrd rule.
    static func needsQuoting(_ line: Substring) -> Bool {
        needsQuoting(ArraySlice(Array(line.utf8)))
    }

    static func needsQuoting(_ line: ArraySlice<UInt8>) -> Bool {
        var start = line.startIndex
        while start < line.endIndex, line[start] == UInt8(ascii: ">") { start += 1 }
        let from: [UInt8] = Array("From ".utf8)
        guard line.endIndex - start >= from.count else { return false }
        return Array(line[start..<start + from.count]) == from
    }
}
