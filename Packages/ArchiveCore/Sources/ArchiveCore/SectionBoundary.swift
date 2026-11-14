//
//  SectionBoundary.swift
//  ArchiveCore
//
//  Five jobs FIND-08: a phrase that wraps onto a new line is found, and a
//  phrase never crosses a cell, a table row, a slide, a sheet or a page.
//
//  Two halves:
//   - Boundaries. A section break inside one document's indexed text is the
//     explicit character U+001E (RECORD SEPARATOR), written BESIDE the tab
//     or newline already there, so the text still reads the same. PDF pages
//     are joined with it by the PDF reader (`pdfText`); the structured
//     document readers' output is marked when it is indexed (`marked`):
//     every cell (tab) and section label line ("[Slide 2]", "[Sheet: Q3]")
//     in every document format, every row/line in tabular formats
//     (spreadsheets, databases, presentations, diagrams, plans, archive
//     listings, CSV), and every table row in word-processing formats (a line
//     holding a cell tab). The extractors' own `text` is unchanged.
//     Show text and evidence excerpts hide the character.
//   - Matching. `contains` / `phrase` / `equals` literals are verified by the
//     SQLite function `mailin_phrase(text, literal)` registered on the
//     store's connection: case folds ASCII (as `lower()` did), any run of
//     whitespace (space, tab, CR, LF, VT, FF, NBSP and the other Unicode
//     White_Space characters) equals one space, and U+001E is never crossed.
//     Punctuation and everything else stay literal — no pattern syntax.
//     It runs only on the rows the FTS lookup already narrowed to.
//

import Foundation
import SQLite3
#if canImport(PDFKit)
import PDFKit
#endif

enum SectionBoundary {
    /// The boundary character (U+001E RECORD SEPARATOR).
    static let character: Character = "\u{1E}"
    static let scalar: Unicode.Scalar = "\u{1E}"
    static let byte: UInt8 = 0x1E
    /// What sits between two pages of a PDF's text.
    static let pageSeparator = "\n\u{1E}"

    // MARK: Marking

    /// How a document's lines relate to each other.
    enum Layout: Equatable {
        /// Plain text, bodies, HTML: nothing is marked.
        case none
        /// Paragraphs may be crossed; cells (tabs), label lines and table
        /// rows (lines holding a tab) are boundaries.
        case prose
        /// Every line and every cell is its own record.
        case records
    }

    static func layout(kind: DocumentKind?, filename: String) -> Layout {
        if let kind {
            switch kind {
            case .docx, .odt, .pages, .doc, .pub, .one, .onepkg: return .prose
            case .xlsx, .xls, .xlsb, .ods, .numbers, .mdb,
                 .pptx, .ppt, .odp, .key,
                 .vsdx, .vsd, .mpp, .projectXML,
                 .zip, .tar, .gzip, .sevenZip, .rar, .pgp: return .records
            }
        }
        switch (filename as NSString).pathExtension.lowercased() {
        case "csv", "tsv": return .records
        case "rtf": return .prose
        default: return .none
        }
    }

    /// The layout of an attachment (or of a file inside one) by its name and,
    /// for a child, its recorded kind.
    static func layout(filename: String, recordedKind: String? = nil) -> Layout {
        let kind = recordedKind.flatMap { DocumentKind(rawValue: $0) }
            ?? DocumentKind.detect(mimeType: "", filename: filename)
        return layout(kind: kind, filename: filename)
    }

    /// `text` with U+001E beside every boundary of `layout`. Idempotent:
    /// a boundary already marked is not marked twice.
    static func marked(_ text: String, layout: Layout) -> String {
        guard layout != .none, !text.isEmpty else { return text }
        // Scalars, not Characters: "\r\n" is one Character and would hide the line break.
        let tab: Unicode.Scalar = "\t", newline: Unicode.Scalar = "\n"
        let lines = text.unicodeScalars.split(separator: newline, omittingEmptySubsequences: false)
        let trim = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\r\u{1E}"))
        func isLabel(_ line: Substring.UnicodeScalarView) -> Bool {
            guard line.contains("[") else { return false }
            let t = String(String.UnicodeScalarView(line)).trimmingCharacters(in: trim)
            return t.count >= 2 && t.hasPrefix("[") && t.hasSuffix("]")
        }
        let structural = lines.map { line in isLabel(line) || (layout == .prose && line.contains(tab)) }
        var out = String.UnicodeScalarView()
        out.reserveCapacity(text.unicodeScalars.underestimatedCount)
        for (i, line) in lines.enumerated() {
            if i > 0 {
                out.append(newline)
                let boundary = layout == .records || structural[i] || structural[i - 1]
                if boundary && line.first != scalar { out.append(scalar) }
            }
            if line.contains(tab) {
                var previousWasTab = false
                for s in line {
                    if previousWasTab && s != scalar { out.append(scalar) }
                    out.append(s)
                    previousWasTab = s == tab
                }
                if previousWasTab { out.append(scalar) }
            } else {
                out.append(contentsOf: line)
            }
        }
        return String(out)
    }

    /// Text for display: the boundary characters removed.
    static func hidden(_ text: String) -> String {
        text.contains(character) ? text.replacingOccurrences(of: "\u{1E}", with: "") : text
    }

    #if canImport(PDFKit)
    /// The text layer of a PDF, page by page, the pages joined with a
    /// boundary so a phrase never runs from one page onto the next. Nil when
    /// PDFKit has no text for it.
    static func pdfText(_ document: PDFDocument) -> String? {
        guard document.pageCount > 1 else { return document.string }
        var pages: [String] = []
        for index in 0..<document.pageCount {
            pages.append(document.page(at: index)?.string ?? "")
        }
        let joined = pages.joined(separator: pageSeparator)
        return joined.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{1E}"))).isEmpty
            ? document.string : joined
    }
    #endif

    // MARK: Matching

    /// The UTF-8 length of a White_Space character starting at `i`, or 0.
    @inline(__always)
    static func whitespaceLength(_ p: UnsafePointer<UInt8>, _ i: Int, _ n: Int) -> Int {
        let b = p[i]
        if b == 0x20 || (b >= 0x09 && b <= 0x0D) { return 1 }
        if b < 0xC2 { return 0 }
        if b == 0xC2, i + 1 < n, p[i + 1] == 0xA0 || p[i + 1] == 0x85 { return 2 }
        guard i + 2 < n else { return 0 }
        let b1 = p[i + 1], b2 = p[i + 2]
        switch b {
        case 0xE1: return b1 == 0x9A && b2 == 0x80 ? 3 : 0                 // U+1680
        case 0xE2:
            if b1 == 0x80, (b2 >= 0x80 && b2 <= 0x8A) || b2 == 0xA8 || b2 == 0xA9 || b2 == 0xAF { return 3 }   // U+2000–200A, 2028, 2029, 202F
            return b1 == 0x81 && b2 == 0x9F ? 3 : 0                        // U+205F
        case 0xE3: return b1 == 0x80 && b2 == 0x80 ? 3 : 0                 // U+3000
        default: return 0
        }
    }

    /// UTF-8 bytes with ASCII folded to lower case and every whitespace run
    /// as one space. U+001E is kept (a boundary in the text) or, for a
    /// literal (`literal: true`), counted as whitespace — a literal never
    /// asks for a boundary. A literal is also trimmed.
    static func normalized(_ p: UnsafePointer<UInt8>, count n: Int, literal: Bool) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(n)
        var i = 0
        var pendingSpace = false
        while i < n {
            var w = whitespaceLength(p, i, n)
            if w == 0, literal, p[i] == byte { w = 1 }
            if w > 0 {
                pendingSpace = true
                i += w
                continue
            }
            if pendingSpace {
                if !(literal && out.isEmpty) { out.append(0x20) }
                pendingSpace = false
            }
            let b = p[i]
            out.append(b >= 0x41 && b <= 0x5A ? b | 0x20 : b)
            i += 1
        }
        if pendingSpace && !literal { out.append(0x20) }
        return out
    }

    /// True when `literal` occurs in `text` under the FIND-08 rule.
    static func contains(_ text: UnsafePointer<UInt8>, count textCount: Int, literal: UnsafePointer<UInt8>, count literalCount: Int) -> Bool {
        let needle = normalized(literal, count: literalCount, literal: true)
        let m = needle.count
        guard m > 0 else { return true }
        guard textCount >= m else { return false }
        // KMP over the text normalised on the fly: no copy of the text, and
        // the scan stops at the first occurrence.
        var fail = [Int](repeating: 0, count: m)
        var k = 0
        var i = 1
        while i < m {
            while k > 0 && needle[i] != needle[k] { k = fail[k - 1] }
            if needle[i] == needle[k] { k += 1 }
            fail[i] = k
            i += 1
        }
        return needle.withUnsafeBufferPointer { nd in
            fail.withUnsafeBufferPointer { fl in
                var q = 0
                @inline(__always) func feed(_ b: UInt8) -> Bool {
                    while q > 0 && nd[q] != b { q = fl[q - 1] }
                    if nd[q] == b { q += 1 }
                    if q == m { return true }
                    return false
                }
                var j = 0
                var pendingSpace = false
                while j < textCount {
                    let w = whitespaceLength(text, j, textCount)
                    if w > 0 { pendingSpace = true; j += w; continue }
                    if pendingSpace { pendingSpace = false; if feed(0x20) { return true } }
                    let b = text[j]
                    if feed(b >= 0x41 && b <= 0x5A ? b | 0x20 : b) { return true }
                    j += 1
                }
                return false
            }
        }
    }

    static func contains(_ text: String, literal: String) -> Bool {
        let t = Array(text.utf8) + [0], l = Array(literal.utf8) + [0]
        return t.withUnsafeBufferPointer { tb in
            l.withUnsafeBufferPointer { lb in
                contains(tb.baseAddress!, count: tb.count - 1, literal: lb.baseAddress!, count: lb.count - 1)
            }
        }
    }

    /// The first occurrence of `literal` in `text` under the same rule, as a
    /// UTF-16 range (for excerpts). Case-insensitive.
    static func range(of literal: String, in text: String) -> NSRange? {
        let words = literal.split(whereSeparator: { $0.isWhitespace || $0 == character })
        guard !words.isEmpty else { return nil }
        let gap = "[\\t\\n\\u000B\\f\\r \\u0085\\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000]+"
        let pattern = words.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: gap)
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let r = regex.rangeOfFirstMatch(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length))
        return r.location == NSNotFound ? nil : r
    }

    // MARK: SQLite

    /// SQL name of the matcher: `mailin_phrase(text, literal)` → 1 / 0.
    static let sqlFunction = "mailin_phrase"

    /// Registers `mailin_phrase` on one connection.
    static func register(on db: OpaquePointer) {
        sqlite3_create_function_v2(db, sqlFunction, 2, SQLITE_UTF8 | SQLITE_DETERMINISTIC | SQLITE_INNOCUOUS, nil, { context, argc, argv in
            guard argc == 2, let argv, let a = argv[0], let b = argv[1] else { sqlite3_result_null(context); return }
            if sqlite3_value_type(a) == SQLITE_NULL || sqlite3_value_type(b) == SQLITE_NULL { sqlite3_result_null(context); return }
            let textCount = Int(sqlite3_value_bytes(a))
            let textPointer = sqlite3_value_text(a)
            let literalCount = Int(sqlite3_value_bytes(b))
            let literalPointer = sqlite3_value_text(b)
            guard let literalPointer else { sqlite3_result_int(context, 1); return }
            guard let textPointer else {
                sqlite3_result_int(context, SectionBoundary.normalized(literalPointer, count: literalCount, literal: true).isEmpty ? 1 : 0)
                return
            }
            let found = SectionBoundary.contains(textPointer, count: textCount, literal: literalPointer, count: literalCount)
            sqlite3_result_int(context, found ? 1 : 0)
        }, nil, nil, nil)
    }
}
