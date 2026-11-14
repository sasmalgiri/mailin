//
//  PublisherTextExtractor.swift
//  ArchiveCore
//
//  Directive 2026-11-07 §6 "Other business formats": Microsoft Publisher
//  (.pub, Publisher 2000 and later). The file is an OLE2 compound document;
//  the words live in the stream Quill/QuillSub/CONTENTS, which begins with
//  "CHNKINK " and, at 0x20, a table of twenty 24-byte slots. A slot that
//  starts 0x18 0x00 describes one "bit": a four-letter thing type, three
//  options, a four-letter bit type, then the bit's offset and length within
//  the stream. The bit typed "TEXT" is the document's text — every text
//  box in reading order as UTF-16LE, paragraphs separated by CR. The "PLC "
//  bits index that text; the one of type 12 carries the hyperlink targets,
//  which are listed after the text so a brochure's web addresses are
//  searchable too. (Layout of the bits after Apache POI's HPBF, verified on
//  Publisher-written files from the Tika and POI corpora.)
//
//  Escher streams (shapes, pictures) and the root Contents stream (page
//  layout) carry no words of their own and are listed as not text. Nothing
//  is executed and no link is followed.
//

import Foundation

enum PublisherTextExtractor {

    static let quillPath = ["Quill", "QuillSub", "CONTENTS"]
    static let component = "Publisher text"

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
        guard let contents = ole.streamData(at: quillPath) else {
            if ole.streamNames.contains(where: { $0.lowercased() == "contents" }) {
                throw OfficeTextExtractor.ExtractError.notAPackage("no Quill/QuillSub/CONTENTS stream — a Publisher 97/98 file keeps its text in an undocumented layout and is not read")
            }
            throw OfficeTextExtractor.ExtractError.notAPackage("no Quill/QuillSub/CONTENTS stream — not a Publisher document")
        }
        return try extract(quillContents: contents, ole: ole)
    }

    /// The text of one Quill CONTENTS stream (exposed for tests).
    static func extract(quillContents contents: Data, ole: OLE2Reader?) throws -> OfficeTextExtractor.Result {
        let bytes = [UInt8](contents)
        guard bytes.count >= 0x20 + 20 * 24, String(bytes: bytes[0..<8], encoding: .windowsCP1252) == "CHNKINK " else {
            throw OfficeTextExtractor.ExtractError.notAPackage("Quill CONTENTS does not start with CHNKINK — not a Publisher document")
        }
        var skipped: [String] = []
        var paragraphs: [String] = []
        var links: [String] = []
        for slot in 0..<20 {
            let o = 0x20 + slot * 24
            guard bytes[o] == 0x18, bytes[o + 1] == 0x00 else { continue }
            let bitType = String(bytes: bytes[(o + 12)..<(o + 16)], encoding: .windowsCP1252) ?? ""
            let from = Int(le32(bytes, o + 16)), length = Int(le32(bytes, o + 20))
            guard from >= 0, length >= 0, from <= bytes.count, length <= bytes.count - from else {
                skipped.append("Quill bit \(slot) (\(bitType.trimmingCharacters(in: .whitespaces))) points outside the stream (\(from) + \(length) of \(bytes.count) bytes)")
                continue
            }
            let bit = Array(bytes[from..<(from + length)])
            switch bitType {
            case "TEXT":
                let text = String(bytes: bit.count % 2 == 0 ? bit : Array(bit.dropLast()), encoding: .utf16LittleEndian) ?? ""
                for paragraph in text.split(whereSeparator: { $0 == "\r" || $0 == "\n" }) {
                    let line = cleanParagraph(String(paragraph))
                    if !line.isEmpty { paragraphs.append(line) }
                }
            case "PLC ":
                guard bit.count >= 8, le32(bit, 4) == 12 else { continue }
                links.append(contentsOf: hyperlinks(in: bit))
            default:
                break
            }
        }
        var notText: [String] = []
        if let ole {
            if let escher = ole.entries(at: ["Escher"]) {
                for e in escher where !e.isStorage { notText.append("Escher/\(e.name) (drawing records)") }
            }
            if ole.entries(at: [])?.contains(where: { !$0.isStorage && $0.name.lowercased() == "contents" }) == true {
                notText.append("Contents (page layout)")
            }
        }
        guard !paragraphs.isEmpty || !links.isEmpty else {
            if skipped.isEmpty { throw OfficeTextExtractor.ExtractError.noTextParts }
            return OfficeTextExtractor.Result(text: "", components: [], skipped: skipped, notText: notText)
        }
        var text = "[\(component)]\n" + paragraphs.joined(separator: "\n") + "\n"
        var components = [component]
        let uniqueLinks = Array(NSOrderedSet(array: links)) as? [String] ?? links
        if !uniqueLinks.isEmpty {
            components.append("Links")
            text += "\n[Links]\n" + uniqueLinks.joined(separator: "\n") + "\n"
        }
        return OfficeTextExtractor.Result(text: text, components: components, skipped: skipped, notText: notText)
    }

    /// Publisher's field and object placeholders (U+0001–U+0008, U+000B,
    /// U+000C, U+000E–U+001F) are dropped; a cell mark becomes a tab.
    static func cleanParagraph(_ raw: String) -> String {
        var out = ""
        for scalar in raw.unicodeScalars {
            switch scalar.value {
            case 0x09, 0x07: out.append("\t")
            case 0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F: break
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// The hyperlink targets of a type-12 PLC bit (POI `QCPLCBit.Type12`):
    /// after a count-dependent preamble come `count` entries of a 16-bit
    /// length and the UTF-16LE address.
    static func hyperlinks(in bit: [UInt8]) -> [String] {
        guard bit.count > 0x34 else { return [] }          // 0x34 bytes = zero hyperlinks
        let count = Int(le32(bit, 0))
        guard count >= 1, count <= bit.count / 4 else { return [] }
        var at = count == 1 ? 0x4C : 0x68 + (count - 2) * 22
        var result: [String] = []
        for _ in 0..<count {
            guard at + 4 <= bit.count else { break }
            let length = Int(bit[at]) | Int(bit[at + 1]) << 8
            let first = Int(bit[at + 2]) | Int(bit[at + 3]) << 8
            if first == 0 {
                at += max(length, 4)
            } else {
                guard at + 2 + 2 * length <= bit.count else { break }
                if let s = String(bytes: bit[(at + 2)..<(at + 2 + 2 * length)], encoding: .utf16LittleEndian), !s.isEmpty { result.append(s) }
                at += 2 + 2 * length
            }
        }
        return result
    }

    private static func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
        guard i >= 0, i + 4 <= b.count else { return 0 }
        return UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
}
