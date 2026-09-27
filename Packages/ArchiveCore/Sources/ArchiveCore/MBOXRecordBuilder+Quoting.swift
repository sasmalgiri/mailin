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

import Foundation

extension MBOXRecordBuilder {

    /// Quote every line that begins with `From ` (and lines already quoted,
    /// `>From `, `>>From `…, so unquoting on import stays reversible). Line
    /// endings are preserved: LF, CRLF and bare CR all count as boundaries.
    static func quoteFromLines(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        var out = String()
        out.reserveCapacity(raw.utf8.count + 64)
        var atLineStart = true
        var lineBuffer = Substring()
        var index = raw.startIndex
        // Walk by lines, keeping the terminator with the line so nothing is
        // normalised.
        while index < raw.endIndex {
            let lineEnd = raw[index...].firstIndex(where: { $0 == "\n" || $0 == "\r" }) ?? raw.endIndex
            var terminatorEnd = lineEnd
            if lineEnd < raw.endIndex {
                terminatorEnd = raw.index(after: lineEnd)
                // Swift treats "\r\n" as a single Character, so this already
                // covers CRLF; a bare CR is its own Character.
            }
            lineBuffer = raw[index..<lineEnd]
            if atLineStart && needsQuoting(lineBuffer) { out.append(">") }
            out.append(contentsOf: raw[index..<terminatorEnd])
            atLineStart = true
            index = terminatorEnd
        }
        return out
    }

    /// `From ` with any number of leading `>` — RFC 4155's mboxrd rule.
    static func needsQuoting(_ line: Substring) -> Bool {
        var rest = line
        while rest.first == ">" { rest = rest.dropFirst() }
        return rest.hasPrefix("From ")
    }
}
