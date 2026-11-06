//
//  OfficeTextExtractor.swift
//  ArchiveCore
//
//  Five jobs FIND-01: text from DOCX, XLSX and PPTX (Office Open XML).
//  A document is a ZIP of XML parts; the text-bearing parts are read with
//  Foundation's XMLParser (no external entities, nothing executed — macros,
//  formulas and embedded objects are never run) and joined with a label
//  per component so a hit can say where it was:
//
//    DOCX  [Document] body, tables and text boxes; [Header], [Footer],
//          [Footnotes], [Endnotes], [Comments]
//    XLSX  [Sheet: <name>] one line per row, cells tab-separated; a stored
//          formula result is the value, the formula itself follows as
//          {=…} so the two are distinguishable and nothing is evaluated
//    PPTX  [Slide N] text, [Notes N] speaker notes
//
//  Text-bearing parts that were NOT read (a part over the size guard, an
//  unknown layout) are listed in `skipped`, and `partial` is true when any
//  were, so coverage stays honest. Media, charts, embedded objects and
//  vbaProject.bin are inventoried as not text, never read.
//
//  Legacy .doc/.xls/.ppt (OLE compound) and ODF are not this format and are
//  reported as unsupported by the caller; an encrypted OOXML package is an
//  OLE "EncryptedPackage" and is reported as locked.
//

import Foundation

enum OfficeTextExtractor {

    enum Kind: String, Sendable {
        case docx, xlsx, pptx

        static func detect(mimeType: String, filename: String) -> Kind? {
            let mime = mimeType.lowercased()
            let ext = (filename as NSString).pathExtension.lowercased()
            if ext == "docx" || ext == "docm" || mime.contains("wordprocessingml") { return .docx }
            if ext == "xlsx" || ext == "xlsm" || mime.contains("spreadsheetml") { return .xlsx }
            if ext == "pptx" || ext == "pptm" || mime.contains("presentationml") { return .pptx }
            return nil
        }
    }

    struct Result: Sendable, Equatable {
        let text: String
        /// Components read, in document order ("Document", "Header", "Sheet: Budget", "Slide 3").
        let components: [String]
        /// Text-bearing parts not read, with the reason.
        let skipped: [String]
        /// Parts that are not text and were not read (media, charts, embedded objects, macros).
        let notText: [String]
        var partial: Bool { !skipped.isEmpty }
    }

    enum ExtractError: Error, LocalizedError, Equatable {
        case notAPackage(String)
        case encrypted
        case noTextParts

        var errorDescription: String? {
            switch self {
            case .notAPackage(let detail): return "not an Office Open XML package: \(detail)"
            case .encrypted: return "password-protected Office file"
            case .noTextParts: return "the package holds none of the parts that carry text"
            }
        }
    }

    /// One XML part is read whole; larger parts are listed as skipped.
    static let maxPartBytes: Int64 = 64 * 1_048_576

    /// A password-protected Office file is an OLE compound document, not a ZIP.
    static let oleSignature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]

    static func extract(fileURL: URL, kind: Kind) throws -> Result {
        if let handle = FileHandle(forReadingAtPath: fileURL.path) {
            let head = try? handle.read(upToCount: 8)
            try? handle.close()
            if let head, Array(head) == oleSignature { throw ExtractError.encrypted }
        }
        let members: [ZIPArchiveReader.Member]
        do { members = try ZIPArchiveReader.members(of: fileURL) } catch {
            throw ExtractError.notAPackage(String(describing: error))
        }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("office-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        var parts: [String: ZIPArchiveReader.Member] = [:]
        var notText: [String] = []
        for member in members where !member.isDirectory {
            let name = member.name
            if name.hasSuffix(".xml") || name.hasSuffix(".rels") {
                parts[name] = member
            } else if name.hasPrefix("word/media/") || name.hasPrefix("xl/media/") || name.hasPrefix("ppt/media/")
                        || name.contains("/embeddings/") || name.contains("/charts/") || name.hasSuffix("vbaProject.bin")
                        || name.hasSuffix(".bin") {
                notText.append(name)
            }
        }

        /// Reads one XML part's text through `collector`; nil when absent.
        func read(_ name: String, into collector: OOXMLTextCollector, skipped: inout [String]) throws -> Bool {
            guard let member = parts[name] else { return false }
            guard member.uncompressedSize <= maxPartBytes else {
                skipped.append("\(name) (\(member.uncompressedSize) bytes, over the \(maxPartBytes)-byte guard)")
                return false
            }
            let destination = scratch.appendingPathComponent(UUID().uuidString)
            try ZIPArchiveReader.extract(member, from: fileURL, to: destination)
            defer { try? FileManager.default.removeItem(at: destination) }
            let data = try Data(contentsOf: destination, options: .mappedIfSafe)
            guard collector.parse(data) else {
                skipped.append("\(name) (malformed XML)")
                return false
            }
            return true
        }

        var text = ""
        var components: [String] = []
        var skipped: [String] = []

        switch kind {
        case .docx:
            let main = OOXMLTextCollector(.wordprocessing)
            if try read("word/document.xml", into: main, skipped: &skipped) {
                components.append("Document")
                text += "[Document]\n" + main.text + "\n"
            }
            let extras: [(prefix: String, label: String)] = [("word/header", "Header"), ("word/footer", "Footer"),
                                                             ("word/footnotes", "Footnotes"), ("word/endnotes", "Endnotes"),
                                                             ("word/comments", "Comments")]
            for extra in extras {
                for name in parts.keys.filter({ $0.hasPrefix(extra.prefix) && $0.hasSuffix(".xml") }).sorted() {
                    let collector = OOXMLTextCollector(.wordprocessing)
                    if try read(name, into: collector, skipped: &skipped), !collector.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        components.append(extra.label)
                        text += "[\(extra.label)]\n" + collector.text + "\n"
                    }
                }
            }
            if components.isEmpty && skipped.isEmpty { throw ExtractError.noTextParts }

        case .xlsx:
            let shared = OOXMLTextCollector(.sharedStrings)
            _ = try read("xl/sharedStrings.xml", into: shared, skipped: &skipped)
            let names = try sheetNames(parts: parts, read: { name in
                let c = OOXMLTextCollector(.raw)
                var s: [String] = []
                return try read(name, into: c, skipped: &s) ? c : nil
            })
            let sheetFiles = parts.keys.filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }
                .sorted { sheetNumber($0) < sheetNumber($1) }
            if sheetFiles.isEmpty && skipped.isEmpty { throw ExtractError.noTextParts }
            for file in sheetFiles {
                let collector = OOXMLTextCollector(.worksheet(sharedStrings: shared.sharedStrings))
                if try read(file, into: collector, skipped: &skipped) {
                    let label = "Sheet: " + (names[file] ?? "Sheet \(sheetNumber(file))")
                    components.append(label)
                    text += "[\(label)]\n" + collector.text + "\n"
                }
            }

        case .pptx:
            let slides = parts.keys.filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
                .sorted { sheetNumber($0) < sheetNumber($1) }
            if slides.isEmpty && skipped.isEmpty { throw ExtractError.noTextParts }
            for file in slides {
                let collector = OOXMLTextCollector(.drawing)
                if try read(file, into: collector, skipped: &skipped) {
                    let label = "Slide \(sheetNumber(file))"
                    components.append(label)
                    text += "[\(label)]\n" + collector.text + "\n"
                }
            }
            let notes = parts.keys.filter { $0.hasPrefix("ppt/notesSlides/notesSlide") && $0.hasSuffix(".xml") }
                .sorted { sheetNumber($0) < sheetNumber($1) }
            for file in notes {
                let collector = OOXMLTextCollector(.drawing)
                if try read(file, into: collector, skipped: &skipped), !collector.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let label = "Notes \(sheetNumber(file))"
                    components.append(label)
                    text += "[\(label)]\n" + collector.text + "\n"
                }
            }
        }
        return Result(text: text, components: components, skipped: skipped, notText: notText.sorted())
    }

    /// "xl/worksheets/sheet12.xml" → 12.
    private static func sheetNumber(_ name: String) -> Int {
        let base = (name as NSString).lastPathComponent
        let digits = base.drop(while: { !$0.isNumber }).prefix(while: { $0.isNumber })
        return Int(digits) ?? 0
    }

    /// Sheet names by worksheet file, through workbook.xml and its .rels.
    private static func sheetNames(parts: [String: ZIPArchiveReader.Member],
                                   read: (String) throws -> OOXMLTextCollector?) throws -> [String: String] {
        guard let workbook = try read("xl/workbook.xml"), let rels = try read("xl/_rels/workbook.xml.rels") else { return [:] }
        var targetByID: [String: String] = [:]
        for rel in rels.relationships { targetByID[rel.id] = rel.target }
        var out: [String: String] = [:]
        for sheet in workbook.sheets {
            guard let target = targetByID[sheet.relationshipID] else { continue }
            let path = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
            out[path] = sheet.name
        }
        return out
    }
}

/// Collects the text of one OOXML part. Mode decides which elements carry
/// text and how rows, cells, paragraphs and formulas are separated.
final class OOXMLTextCollector: NSObject, XMLParserDelegate {
    enum Mode {
        case wordprocessing
        case drawing
        case sharedStrings
        case worksheet(sharedStrings: [String])
        /// Only structure (sheet names, relationships).
        case raw
    }

    struct Sheet { let name: String; let relationshipID: String }
    struct Relationship { let id: String; let target: String }

    private let mode: Mode
    private(set) var text = ""
    private(set) var sharedStrings: [String] = []
    private(set) var sheets: [Sheet] = []
    private(set) var relationships: [Relationship] = []

    private var current = ""
    private var capturing = false
    private var cellType = ""
    private var cellValue = ""
    private var cellFormula = ""
    private var inFormula = false
    private var inValue = false
    private var inInlineString = false
    private var rowCells: [String] = []
    private var sharedCurrent = ""
    private var cellInRow = 0
    private var cellDepth = 0
    private var failed = false

    init(_ mode: Mode) {
        self.mode = mode
    }

    /// False when the XML could not be parsed.
    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        let ok = parser.parse()
        return ok && !failed
    }

    private func local(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        let name = local(elementName)
        switch mode {
        case .wordprocessing:
            switch name {
            case "t": capturing = true; current = ""
            case "tab": text += "\t"
            case "br", "cr": text += "\n"
            case "tr": cellInRow = 0
            case "tc":
                if cellInRow > 0 { text += "\t" }   // cells of one row on one line
                cellInRow += 1
                cellDepth += 1
            default: break
            }
        case .drawing:
            if name == "t" { capturing = true; current = "" }
            if name == "br" { text += "\n" }
        case .sharedStrings:
            if name == "si" { sharedCurrent = "" }
            if name == "t" { capturing = true; current = "" }
        case .worksheet:
            switch name {
            case "row": rowCells = []
            case "c":
                cellType = attributes["t"] ?? ""
                cellValue = ""; cellFormula = ""
            case "v": inValue = true; current = ""
            case "f": inFormula = true; current = ""
            case "is": inInlineString = true; cellValue = ""
            case "t": if inInlineString { capturing = true; current = "" }
            default: break
            }
        case .raw:
            if name == "sheet" {
                let rid = attributes["r:id"] ?? attributes.first { $0.key.hasSuffix(":id") }?.value ?? ""
                sheets.append(Sheet(name: attributes["name"] ?? "", relationshipID: rid))
            }
            if name == "Relationship", let id = attributes["Id"], let target = attributes["Target"] {
                relationships.append(Relationship(id: id, target: target))
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing || inValue || inFormula { current += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = local(elementName)
        switch mode {
        case .wordprocessing:
            if name == "t" { text += current; capturing = false }
            if name == "p" { text += cellDepth > 0 ? " " : "\n" }   // paragraphs inside a cell stay on the row's line
            if name == "tc" { cellDepth = max(0, cellDepth - 1) }
            if name == "tr" { text += "\n" }
        case .drawing:
            if name == "t" { text += current; capturing = false }
            if name == "p" { text += "\n" }
        case .sharedStrings:
            if name == "t" { sharedCurrent += current; capturing = false }
            if name == "si" { sharedStrings.append(sharedCurrent) }
        case .worksheet(let shared):
            switch name {
            case "v":
                inValue = false
                // Audit A05: a shared-string index is untrusted; only 0..<count reads the table.
                if cellType == "s", let index = Int(current.trimmingCharacters(in: .whitespaces)), index >= 0, index < shared.count {
                    cellValue = shared[index]
                } else {
                    cellValue = current
                }
            case "f": inFormula = false; cellFormula = current
            case "t": if inInlineString { cellValue += current; capturing = false }
            case "is": inInlineString = false
            case "c":
                var cell = cellValue
                if !cellFormula.isEmpty { cell += " {=" + cellFormula + "}" }
                rowCells.append(cell)
            case "row":
                let line = rowCells.joined(separator: "\t").trimmingCharacters(in: .whitespaces)
                if !line.isEmpty { text += line + "\n" }
            default: break
            }
        case .raw:
            break
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        failed = true
    }
}
