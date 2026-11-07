//
//  VisioBinaryTextExtractor.swift
//  ArchiveCore
//
//  Directive 2026-11-07 §6 "Other business formats": binary Visio drawings,
//  stencils and templates (.vsd/.vss/.vst, Visio 5 – 2010). The OLE2 file
//  holds a VisioDocument stream: "Visio (TM) Drawing\r\n", the version at
//  0x1A and, at 0x24, the pointer to the trailer. Pointers (16 bytes in
//  Visio 5, 18 from Visio 2000) carry type, offset, length and a format
//  byte: bit 1 says the destination is compressed with Visio's LZW variant
//  (12-bit codes, flag bit set = literal, offsets shifted by 18); formats
//  0x1D–0x1E / 0x50–0x5F (and type 20, the trailer) point at further
//  pointer tables, 0xD0–0xDF at chunk streams, 0x40–0x4F at string tables.
//  A chunk stream is a sequence of records (19-byte header from Visio 2000,
//  12-byte in Visio 5; optional 8-byte trailer and 4-byte separator by type
//  and flags) and the record of type 14 is a shape's Text: the string from
//  byte 8 to the first 00 00, UTF-16LE from Visio 2003 (version 11) and
//  8-bit before. Layout after Apache POI's HDGF and vsdump's command table.
//
//  Every Text record is emitted once, in document order, one line per
//  paragraph, under "[Shapes]". The binary format keeps page names in
//  string tables the public documentation does not map to pages, so text
//  is not grouped by page here (the Visio 2013+ .vsdx reader does that).
//  VBA storages are listed as not text and never executed; other OLE
//  streams (summary information) are not read as drawing text. A pointer
//  outside the stream, a chunk that runs past its stream, a corrupt
//  compressed block: each is recorded by position and the rest is read.
//

import Foundation

enum VisioBinaryTextExtractor {

    static let component = "Visio text"
    static let header: [UInt8] = Array("Visio (TM) Drawing\r\n".utf8)

    struct Issue: Error { let text: String; init(_ text: String) { self.text = text } }

    struct Pointer {
        let type: Int
        let offset: Int
        let length: Int
        let format: Int
        var isCompressed: Bool { format & 2 != 0 }
    }

    static func extract(fileURL: URL) throws -> OfficeTextExtractor.Result {
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        guard data.count >= 8, Array(data.prefix(8)) == OfficeTextExtractor.oleSignature else {
            throw OfficeTextExtractor.ExtractError.notAPackage("not an OLE2 compound file")
        }
        let limit = ExtractionLimits.effective.partBytes
        guard Int64(data.count) <= limit else {
            return OfficeTextExtractor.Result(text: "", components: [], skipped: ["\(fileURL.lastPathComponent) (\(data.count) bytes, over the \(limit)-byte guard)"], notText: [])
        }
        let ole: OLE2Reader
        do { ole = try OLE2Reader(data: data) } catch { throw OfficeTextExtractor.ExtractError.notAPackage(String(describing: error)) }
        guard let document = ole.streamNames.first(where: { $0.lowercased() == "visiodocument" }).flatMap({ ole.streamData(named: $0) }) else {
            throw OfficeTextExtractor.ExtractError.notAPackage("no VisioDocument stream — not a binary Visio drawing")
        }
        var notText: [String] = []
        if ole.entries(at: ["VBA"]) != nil || ole.entries(at: ["Macros"]) != nil || ole.streamNames.contains(where: { $0.lowercased().hasPrefix("_vba") }) {
            notText.append("VBA macros (not executed)")
        }
        for name in ole.streamNames where name.lowercased().hasSuffix("summaryinformation") {
            notText.append("\(name.filter { $0.isLetter || $0.isNumber }) (document properties)")
        }
        return try extract(visioDocument: [UInt8](document), name: fileURL.lastPathComponent, notText: notText)
    }

    /// The text of one VisioDocument stream (exposed for tests).
    static func extract(visioDocument doc: [UInt8], name: String, notText: [String]) throws -> OfficeTextExtractor.Result {
        guard doc.count >= 0x40, Array(doc[0..<20]) == header else {
            throw OfficeTextExtractor.ExtractError.notAPackage("VisioDocument does not start with the Visio header")
        }
        let version = Int(Int16(bitPattern: UInt16(doc[0x1A]) | UInt16(doc[0x1B]) << 8))
        guard version >= 5 else {
            throw OfficeTextExtractor.ExtractError.notAPackage("Visio \(version) files (before Visio 5) use an undocumented layout and are not read")
        }
        var walker = Walker(doc: doc, version: version)
        do {
            let trailer = try walker.pointer(at: 0x24)
            guard trailer.type == 20 else { throw Issue("the trailer pointer at 0x24 has type \(trailer.type), not 20") }
            walker.walk(trailer, depth: 0)
        } catch let issue as Issue {
            walker.issues.append(issue.text)
        } catch { walker.issues.append(String(describing: error)) }

        let skipped = walker.issues.map { "\(name): \($0)" }
        guard !walker.lines.isEmpty else {
            if skipped.isEmpty { throw OfficeTextExtractor.ExtractError.noTextParts }
            return OfficeTextExtractor.Result(text: "", components: [], skipped: skipped, notText: notText)
        }
        let text = "[\(component)]\n[Shapes]\n" + walker.lines.joined(separator: "\n") + "\n"
        return OfficeTextExtractor.Result(text: text, components: [component], skipped: skipped, notText: notText)
    }

    // MARK: - Pointer and stream walk

    struct Walker {
        static let maxDepth = 500
        let doc: [UInt8]
        let version: Int
        var lines: [String] = []
        var issues: [String] = []
        private var visited: Set<Int> = []
        private var depthLimitNoted = false

        init(doc: [UInt8], version: Int) { self.doc = doc; self.version = version }

        var pointerSize: Int { version >= 6 ? 18 : 16 }

        func pointer(at o: Int, in b: [UInt8]? = nil) throws -> Pointer {
            let b = b ?? doc
            guard o >= 0, o + pointerSize <= b.count else { throw Issue("pointer at \(o) lies outside its stream") }
            if version >= 6 {
                return Pointer(type: Int(Int32(bitPattern: le32(b, o))), offset: Int(le32(b, o + 8)), length: Int(le32(b, o + 12)),
                               format: Int(Int16(bitPattern: le16(b, o + 16))))
            }
            return Pointer(type: Int(Int16(bitPattern: le16(b, o))), offset: Int(le32(b, o + 8)), length: Int(le32(b, o + 12)),
                           format: Int(Int16(bitPattern: le16(b, o + 2))))
        }

        func hasPointers(_ p: Pointer) -> Bool {
            if version >= 6 { return p.type == 20 || (0x1D..<0x1F).contains(p.format) || (0x50..<0x60).contains(p.format) }
            switch p.type { case 20: return true; case 22: return false; default: return (0x1D..<0x1F).contains(p.format) || (0x50..<0x60).contains(p.format) }
        }

        func hasChunks(_ p: Pointer) -> Bool {
            if version < 6, p.type == 21 || p.type == 24 { return true }
            return (0xD0..<0xDF).contains(p.format)
        }

        /// The stream's bytes: decompressed when the pointer says so, the
        /// 4-byte block header of a compressed store returned separately.
        func store(_ p: Pointer) throws -> (contents: [UInt8], blockHeader: [UInt8]) {
            guard p.offset >= 0, p.length >= 0, p.offset <= doc.count, p.length <= doc.count - p.offset else {
                throw Issue("stream at \(p.offset) (\(p.length) bytes) lies outside the VisioDocument stream")
            }
            let raw = doc[p.offset..<(p.offset + p.length)]
            guard p.isCompressed else { return (Array(raw), []) }
            let inflated = VisioBinaryTextExtractor.lzwDecompress(raw)
            guard inflated.count >= 4 else { throw Issue("compressed stream at \(p.offset) holds no block header") }
            return (Array(inflated[4...]), Array(inflated[0..<4]))
        }

        mutating func walk(_ p: Pointer, depth: Int) {
            guard depth < Self.maxDepth else {
                if !depthLimitNoted { issues.append("pointer tables nested deeper than \(Self.maxDepth) levels were not followed"); depthLimitNoted = true }
                return
            }
            guard p.length > 0 else { return }
            guard visited.insert(p.offset).inserted else { return }
            do {
                let (contents, blockHeader) = try store(p)
                if hasPointers(p) {
                    for child in try containerPointers(p, contents) { walk(child, depth: depth + 1) }
                } else if hasChunks(p) {
                    let bytes = p.isCompressed ? blockHeader + contents : contents
                    readChunks(bytes, streamOffset: p.offset)
                }
            } catch let issue as Issue {
                issues.append(issue.text)
            } catch { issues.append(String(describing: error)) }
        }

        func containerPointers(_ parent: Pointer, _ contents: [UInt8]) throws -> [Pointer] {
            let countOffset: Int, count: Int, skip: Int
            if version >= 6 {
                guard contents.count >= 4 else { throw Issue("pointer table at \(parent.offset) is shorter than its count") }
                countOffset = Int(le32(contents, 0))
                guard countOffset >= 0, countOffset + 4 <= contents.count else { throw Issue("pointer table at \(parent.offset) names a count outside itself") }
                count = Int(le32(contents, countOffset))
                skip = 8
            } else {
                switch parent.type { case 0x1D, 0x4E: countOffset = 30; case 0x1E: countOffset = 54; case 0x14: countOffset = 130; default: countOffset = 10 }
                guard countOffset + 2 <= contents.count else { throw Issue("pointer table at \(parent.offset) is shorter than its count") }
                count = Int(Int16(bitPattern: le16(contents, countOffset)))
                skip = 2
            }
            guard count >= 0 else { throw Issue("pointer table at \(parent.offset) has a negative count") }
            var pointers: [Pointer] = []
            var at = countOffset + skip
            for _ in 0..<count {
                guard at + pointerSize <= contents.count else {
                    throw Issue("pointer table at \(parent.offset) declares \(count) pointers but holds \(pointers.count)")
                }
                pointers.append(try pointer(at: at, in: contents))
                at += pointerSize
            }
            return pointers
        }

        // MARK: Chunks

        mutating func readChunks(_ b: [UInt8], streamOffset: Int) {
            let headerSize = version >= 6 ? 19 : 12
            var pos = 0
            while pos + headerSize <= b.count {
                let type: Int, unknown1: Int, length: Int, u2: Int, u3: Int
                if version >= 6 {
                    type = Int(le32(b, pos)); unknown1 = Int(le32(b, pos + 8)); length = Int(le32(b, pos + 12))
                    u2 = Int(Int16(bitPattern: le16(b, pos + 16))); u3 = Int(b[pos + 18])
                } else {
                    type = Int(Int16(bitPattern: le16(b, pos))); u2 = Int(b[pos + 4]); u3 = Int(b[pos + 5])
                    unknown1 = Int(Int16(bitPattern: le16(b, pos + 6))); length = Int(le32(b, pos + 8))
                }
                let hasTrailer: Bool, hasSeparator: Bool
                if version >= 6 {
                    hasTrailer = [0x2C, 0x65, 0x66, 0x69, 0x6A, 0x6B, 0x70, 0x71].contains(type) || unknown1 != 0
                    hasSeparator = version > 6 ? Self.v11HasSeparator(type: type, u2: u2, u3: u3, hasTrailer: hasTrailer) : false
                } else {
                    hasTrailer = false; hasSeparator = false
                }
                var dataEnd = pos + headerSize + length
                var contentLength = length
                if length > b.count - pos - headerSize {
                    // POI reads such a chunk to the end of its stream; the declared length is recorded.
                    issues.append("chunk at \(streamOffset)+\(pos) declares \(length) bytes but its stream has \(b.count - pos - headerSize) left; read to the end")
                    dataEnd = b.count
                    contentLength = b.count - pos - headerSize
                    if hasTrailer { contentLength -= 8; dataEnd -= 8 }
                    if hasSeparator { contentLength -= 4; dataEnd -= 4 }
                    guard contentLength >= 0 else { return }
                }
                if type == 14, contentLength > 8 {
                    let start = pos + headerSize + 8
                    var end = start
                    while end + 1 < pos + headerSize + contentLength {
                        if b[end] == 0 && b[end + 1] == 0 { break }
                        end += version > 6 ? 2 : 1
                    }
                    if end > start {
                        let slice = b[start..<end]
                        let s = version > 6
                            ? String(bytes: slice.count % 2 == 0 ? slice : slice.dropLast(), encoding: .utf16LittleEndian)
                            : String(bytes: slice.prefix { $0 != 0 }, encoding: .windowsCP1252)
                        if let s { appendText(s) }
                    }
                }
                var next = dataEnd
                if hasTrailer { next += 8 }
                if hasSeparator { next += 4 }
                guard next > pos else { return }
                pos = next
            }
        }

        static func v11HasSeparator(type: Int, u2: Int, u3: Int, hasTrailer: Bool) -> Bool {
            switch type {
            case 0x1F, 0xC9: return false
            case 0x69: return true
            case 0xA9, 0xAA, 0xB4, 0xB6: if u2 == 2 && u3 == 0x54 { return true }
            default: break
            }
            if (u2 == 2 && u3 == 0x55) || (u2 == 3 && u3 != 0x50) { return true }
            return hasTrailer
        }

        private mutating func appendText(_ raw: String) {
            for piece in raw.split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\u{000B}" }) {
                // Control characters and U+FFFC (a text field's placeholder) are not words.
                let line = String(piece.unicodeScalars.filter { ($0.value >= 0x20 || $0 == "\t") && $0.value != 0xFFFC }.map(Character.init)).trimmingCharacters(in: .whitespaces)
                if !line.isEmpty { lines.append(line) }
            }
        }
    }

    // MARK: - Visio LZW (POI HDGFLZW)

    /// 12-bit LZW with a 4,096-byte zeroed dictionary: a flag byte governs
    /// the next eight codes (bit set = literal byte); a code is two bytes —
    /// position = b1 + ((b2 & 0xF0) << 4), length = (b2 & 0x0F) + 3 — and
    /// the position is shifted by 18 (positions above 4078 wrap).
    static func lzwDecompress(_ input: ArraySlice<UInt8>) -> [UInt8] {
        var dictionary = [UInt8](repeating: 0, count: 4096)
        var out: [UInt8] = []
        out.reserveCapacity(input.count * 3)
        var pos = 0
        var i = input.startIndex
        while i < input.endIndex {
            let flag = input[i]; i += 1
            var mask: UInt8 = 1
            while mask != 0 {
                if flag & mask != 0 {
                    guard i < input.endIndex else { return out }
                    let byte = input[i]; i += 1
                    dictionary[pos & 0xFFF] = byte
                    pos += 1
                    out.append(byte)
                } else {
                    guard i + 1 < input.endIndex else { return out }
                    let b1 = Int(input[i]), b2 = Int(input[i + 1]); i += 2
                    let length = (b2 & 0x0F) + 3
                    var pointer = b1 + ((b2 & 0xF0) << 4)
                    pointer = pointer > 4078 ? pointer - 4078 : pointer + 18
                    for k in 0..<length {
                        let byte = dictionary[(pointer + k) & 0xFFF]
                        dictionary[(pos + k) & 0xFFF] = byte
                        out.append(byte)
                    }
                    pos += length
                }
                mask = mask == 0x80 ? 0 : mask << 1
            }
        }
        return out
    }

    private static func le16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
    private static func le32(_ b: [UInt8], _ i: Int) -> UInt32 { UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24 }
}

private func le16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
private func le32(_ b: [UInt8], _ i: Int) -> UInt32 { UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24 }
