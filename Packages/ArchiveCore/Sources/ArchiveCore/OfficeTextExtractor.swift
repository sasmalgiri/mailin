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
//    DOCX  [Document] body, tables, text boxes ("[Text box] …"); tracked
//          changes labelled inline ({inserted: …} / {deleted: …});
//          [Header], [Footer], [Footnotes], [Endnotes], [Comments]
//    XLSX  [Sheet: <name>] one line per row, each cell as "A1: value";
//          a stored formula result is the value, the formula itself follows
//          as {=…} so the two are distinguishable and nothing is evaluated;
//          hidden sheets labelled "(hidden)"; [Comments: <sheet>] "A1: text";
//          the 1904 date system is stated when the workbook uses it
//    PPTX  [Slide N] text (hidden slides labelled), [Notes N] speaker notes,
//          [Comments N]
//    all   [Chart N] titles, labels and plotted values of embedded charts;
//          embedded documents (word/embeddings, …) are CHILD documents
//          (plan v4 §13.3 (5)), read when their kind is known
//
//  Both the Transitional and the Strict OOXML namespaces are read: elements
//  are matched by local name, parts by their package paths.
//
//  Text-bearing parts that were NOT read (a part over the size guard, an
//  unknown layout) are listed in `skipped`, and `partial` is true when any
//  were, so coverage stays honest. Media and vbaProject.bin are inventoried
//  as not text, never read.
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
            if ["docx", "docm", "dotx", "dotm"].contains(ext) || mime.contains("wordprocessingml") { return .docx }
            if ["xlsx", "xlsm", "xltx", "xltm"].contains(ext) || mime.contains("spreadsheetml") { return .xlsx }
            if ["pptx", "pptm", "potx", "potm", "ppsx", "ppsm"].contains(ext) || mime.contains("presentationml") { return .pptx }
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
        /// Plan v4 §13.3 (5): files INSIDE this attachment (archive members,
        /// a message's attachments, embedded documents), each its own
        /// document with its own state — never joined into this text.
        var children: [ChildDocument] = []
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
        var embedded: [ZIPArchiveReader.Member] = []
        for member in members where !member.isDirectory {
            let name = member.name
            if name.contains("/embeddings/") {
                embedded.append(member)
            } else if name.hasSuffix(".xml") || name.hasSuffix(".rels") {
                parts[name] = member
            } else if name.hasPrefix("word/media/") || name.hasPrefix("xl/media/") || name.hasPrefix("ppt/media/")
                        || name.hasSuffix("vbaProject.bin") || name.hasSuffix(".bin") {
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
        /// The relationships of one part ("xl/worksheets/sheet1.xml" → its .rels), resolved to package paths.
        func relationships(of part: String) throws -> [String: String] {
            let folder = (part as NSString).deletingLastPathComponent
            let relsName = folder + "/_rels/" + (part as NSString).lastPathComponent + ".rels"
            let collector = OOXMLTextCollector(.raw)
            var ignored: [String] = []
            guard try read(relsName, into: collector, skipped: &ignored) else { return [:] }
            var out: [String: String] = [:]
            for rel in collector.relationships {
                out[rel.id] = rel.target.hasPrefix("/") ? String(rel.target.dropFirst()) : resolve(folder, rel.target)
            }
            return out
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
            let workbook = OOXMLTextCollector(.raw)
            var ignored: [String] = []
            _ = try read("xl/workbook.xml", into: workbook, skipped: &ignored)
            let names = try sheetNames(workbook: workbook, parts: parts, read: { name in
                let c = OOXMLTextCollector(.raw)
                var s: [String] = []
                return try read(name, into: c, skipped: &s) ? c : nil
            })
            let sheetFiles = parts.keys.filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }
                .sorted { sheetNumber($0) < sheetNumber($1) }
            if sheetFiles.isEmpty && skipped.isEmpty { throw ExtractError.noTextParts }
            if workbook.date1904 {
                components.append("Workbook")
                text += "[Workbook]\n1904 date system: serial dates count from 1 January 1904\n\n"
            }
            for file in sheetFiles {
                let collector = OOXMLTextCollector(.worksheet(sharedStrings: shared.sharedStrings))
                if try read(file, into: collector, skipped: &skipped) {
                    let sheet = names[file]
                    var label = "Sheet: " + (sheet?.name ?? "Sheet \(sheetNumber(file))")
                    if let state = sheet?.state, state == "hidden" || state == "veryHidden" { label += " (hidden)" }
                    components.append(label)
                    text += "[\(label)]\n" + collector.text + "\n"
                    // Comments attached to this sheet, by its relationships.
                    for (_, target) in try relationships(of: file).sorted(by: { $0.value < $1.value }) where target.contains("comments") && target.hasSuffix(".xml") {
                        let comments = OOXMLTextCollector(.comments)
                        if try read(target, into: comments, skipped: &skipped), !comments.text.isEmpty {
                            let commentsLabel = "Comments: " + (sheet?.name ?? "Sheet \(sheetNumber(file))")
                            components.append(commentsLabel)
                            text += "[\(commentsLabel)]\n" + comments.text + "\n"
                        }
                    }
                }
            }

        case .pptx:
            let slides = parts.keys.filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
                .sorted { sheetNumber($0) < sheetNumber($1) }
            if slides.isEmpty && skipped.isEmpty { throw ExtractError.noTextParts }
            for file in slides {
                let collector = OOXMLTextCollector(.drawing)
                if try read(file, into: collector, skipped: &skipped) {
                    let label = "Slide \(sheetNumber(file))" + (collector.hiddenSlide ? " (hidden)" : "")
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
            let comments = parts.keys.filter { $0.hasPrefix("ppt/comments/comment") && $0.hasSuffix(".xml") }
                .sorted { sheetNumber($0) < sheetNumber($1) }
            for file in comments {
                let collector = OOXMLTextCollector(.drawing)
                if try read(file, into: collector, skipped: &skipped), !collector.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let label = "Comments \(sheetNumber(file))"
                    components.append(label)
                    text += "[\(label)]\n" + collector.text + "\n"
                }
            }
        }

        // Charts of any of the three: titles, axis and series labels, plotted values.
        let charts = parts.keys.filter { $0.contains("/charts/chart") && $0.hasSuffix(".xml") }
            .sorted { sheetNumber($0) < sheetNumber($1) }
        for file in charts {
            let collector = OOXMLTextCollector(.chart)
            if try read(file, into: collector, skipped: &skipped), !collector.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let label = "Chart \(sheetNumber(file))"
                components.append(label)
                text += "[\(label)]\n" + collector.text + "\n"
            }
        }

        // §13.3 (5): embedded documents are children with their own state.
        var children: [ChildDocument] = []
        for member in embedded.sorted(by: { $0.name < $1.name }) {
            let filename = (member.name as NSString).lastPathComponent
            let ext = (filename as NSString).pathExtension.lowercased()
            let destination = scratch.appendingPathComponent(UUID().uuidString + (ext.isEmpty ? "" : "." + ext))
            do { try ZIPArchiveReader.extract(member, from: fileURL, to: destination) } catch {
                children.append(ChildDocument(path: member.name, filename: filename, kind: ext, sha256: "", bytes: Int(member.uncompressedSize),
                                              text: nil, state: .failed, note: "\(error)"))
                continue
            }
            defer { try? FileManager.default.removeItem(at: destination) }
            let sha = (try? ExportInventory.sha256(of: destination)) ?? ""
            let size = Int(member.uncompressedSize)
            guard let innerKind = DocumentKind.detect(mimeType: "", filename: filename) ?? DocumentTextExtractor.sniff(fileURL: destination) else {
                children.append(ChildDocument(path: member.name, filename: filename, kind: ext, sha256: sha, bytes: size, text: nil, state: .unsupported,
                                              note: ext == "bin" ? "embedded OLE object; not read" : "embedded object of a kind not read: .\(ext)"))
                continue
            }
            do {
                let inner = try DocumentTextExtractor.extract(fileURL: destination, kind: innerKind, logicalName: filename)
                children.append(ChildDocument(path: member.name, filename: filename, kind: innerKind.rawValue, sha256: sha, bytes: size, text: inner.text,
                                              state: inner.partial ? .partial : .extracted,
                                              note: inner.skipped.isEmpty ? nil : "not read: " + inner.skipped.joined(separator: "; "), components: inner.components))
                children.append(contentsOf: inner.children.map { child in var nested = child; nested.path = member.name + " › " + child.path; return nested })
            } catch ExtractError.encrypted {
                children.append(ChildDocument(path: member.name, filename: filename, kind: innerKind.rawValue, sha256: sha, bytes: size, text: nil, state: .locked, note: "password-protected"))
            } catch ExtractError.noTextParts {
                children.append(ChildDocument(path: member.name, filename: filename, kind: innerKind.rawValue, sha256: sha, bytes: size, text: nil, state: .noText, note: nil))
            } catch {
                children.append(ChildDocument(path: member.name, filename: filename, kind: innerKind.rawValue, sha256: sha, bytes: size, text: nil, state: .failed, note: "\(error)"))
            }
        }
        return Result(text: text, components: components, skipped: skipped, notText: notText.sorted(), children: children)
    }

    /// "xl/worksheets/sheet12.xml" → 12.
    static func sheetNumber(_ name: String) -> Int {
        let base = (name as NSString).lastPathComponent
        let digits = base.drop(while: { !$0.isNumber }).prefix(while: { $0.isNumber })
        return Int(digits) ?? 0
    }

    /// "xl/worksheets" + "../comments1.xml" → "xl/comments1.xml".
    static func resolve(_ folder: String, _ target: String) -> String {
        var components = folder.split(separator: "/").map(String.init)
        for piece in target.split(separator: "/") {
            if piece == ".." { if !components.isEmpty { components.removeLast() } }
            else if piece != "." { components.append(String(piece)) }
        }
        return components.joined(separator: "/")
    }

    /// Sheet names and visibility by worksheet file, through workbook.xml and its .rels.
    private static func sheetNames(workbook: OOXMLTextCollector, parts: [String: ZIPArchiveReader.Member],
                                   read: (String) throws -> OOXMLTextCollector?) throws -> [String: OOXMLTextCollector.Sheet] {
        guard let rels = try read("xl/_rels/workbook.xml.rels") else { return [:] }
        var targetByID: [String: String] = [:]
        for rel in rels.relationships { targetByID[rel.id] = rel.target }
        var out: [String: OOXMLTextCollector.Sheet] = [:]
        for sheet in workbook.sheets {
            guard let target = targetByID[sheet.relationshipID] else { continue }
            let path = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
            out[path] = sheet
        }
        return out
    }

    /// Column letters for a zero-based index: 0 → A, 26 → AA.
    static func columnName(_ index: Int) -> String {
        var n = index + 1
        var out = ""
        while n > 0 {
            let r = (n - 1) % 26
            out = String(UnicodeScalar(UInt8(65 + r))) + out
            n = (n - 1) / 26
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
        /// Excel comments part: "A1: text" per comment.
        case comments
        /// DrawingML chart: titles, labels and plotted values.
        case chart
        /// Only structure (sheet names, relationships, workbook properties).
        case raw
    }

    struct Sheet { let name: String; let relationshipID: String; let state: String? }
    struct Relationship { let id: String; let target: String }

    private let mode: Mode
    private(set) var text = ""
    private(set) var sharedStrings: [String] = []
    private(set) var sheets: [Sheet] = []
    private(set) var relationships: [Relationship] = []
    /// `<workbookPr date1904="1"/>`: serial dates start in 1904.
    private(set) var date1904 = false
    /// `<p:sld show="0">`: the slide is hidden in the show.
    private(set) var hiddenSlide = false

    private var current = ""
    private var capturing = false
    private var cellType = ""
    private var cellValue = ""
    private var cellFormula = ""
    private var cellReference = ""
    private var inFormula = false
    private var inValue = false
    private var inInlineString = false
    private var rowCells: [String] = []
    private var sharedCurrent = ""
    private var cellInRow = 0
    private var cellDepth = 0
    private var failed = false
    private var depth = 0
    /// Depth at which an `mc:Fallback` subtree started (its text duplicates the Choice's).
    private var fallbackDepth: Int?
    private var commentReference = ""
    private var chartValues: [String] = []
    private var inChartPoint = false
    private var rootSeen = false

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
        depth += 1
        if !rootSeen {
            rootSeen = true
            if case .drawing = mode, name == "sld", attributes["show"] == "0" { hiddenSlide = true }
        }
        if name == "Fallback", fallbackDepth == nil, elementName.lowercased().hasPrefix("mc:") { fallbackDepth = depth }
        if fallbackDepth != nil { return }
        switch mode {
        case .wordprocessing:
            switch name {
            case "t", "delText": capturing = true; current = ""
            case "tab": text += "\t"
            case "br", "cr": text += "\n"
            case "tr": cellInRow = 0
            case "tc":
                if cellInRow > 0 { text += "\t" }   // cells of one row on one line
                cellInRow += 1
                cellDepth += 1
            case "ins": text += "{inserted: "
            case "del": text += "{deleted: "
            case "txbxContent": text += "\n[Text box] "
            default: break
            }
        case .drawing:
            if name == "t" { capturing = true; current = "" }
            if name == "br" { text += "\n" }
            if name == "text", elementName.lowercased().hasPrefix("p:") { capturing = true; current = "" }   // p:cm/p:text (comments)
        case .sharedStrings:
            if name == "si" { sharedCurrent = "" }
            if name == "t" { capturing = true; current = "" }
        case .worksheet:
            switch name {
            case "row": rowCells = []
            case "c":
                cellType = attributes["t"] ?? ""
                cellReference = attributes["r"] ?? ""
                cellValue = ""; cellFormula = ""
            case "v": inValue = true; current = ""
            case "f": inFormula = true; current = ""
            case "is": inInlineString = true; cellValue = ""
            case "t": if inInlineString { capturing = true; current = "" }
            default: break
            }
        case .comments:
            if name == "comment" { commentReference = attributes["ref"] ?? ""; cellValue = "" }
            if name == "t" { capturing = true; current = "" }
        case .chart:
            switch name {
            case "t": capturing = true; current = ""
            case "pt": inChartPoint = true
            case "v": if inChartPoint { inValue = true; current = "" }
            case "ser": chartValues = []
            default: break
            }
        case .raw:
            if name == "sheet" {
                let rid = attributes["r:id"] ?? attributes.first { $0.key.hasSuffix(":id") }?.value ?? ""
                sheets.append(Sheet(name: attributes["name"] ?? "", relationshipID: rid, state: attributes["state"]))
            }
            if name == "Relationship", let id = attributes["Id"], let target = attributes["Target"] {
                relationships.append(Relationship(id: id, target: target))
            }
            if name == "workbookPr", let flag = attributes["date1904"], flag == "1" || flag.lowercased() == "true" { date1904 = true }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if fallbackDepth != nil { return }
        if capturing || inValue || inFormula { current += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = local(elementName)
        defer { depth -= 1 }
        if let fallback = fallbackDepth {
            if depth == fallback { fallbackDepth = nil }
            return
        }
        switch mode {
        case .wordprocessing:
            if name == "t" || name == "delText" { text += current; capturing = false }
            if name == "p" { text += cellDepth > 0 ? " " : "\n" }   // paragraphs inside a cell stay on the row's line
            if name == "tc" { cellDepth = max(0, cellDepth - 1) }
            if name == "tr" { text += "\n" }
            if name == "ins" || name == "del" { text += "}" }
            if name == "txbxContent" { text += "\n" }
        case .drawing:
            if name == "t" { text += current; capturing = false }
            if name == "text", elementName.lowercased().hasPrefix("p:") { text += current + "\n"; capturing = false }
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
                guard !cell.isEmpty else { break }   // an empty cell carries no address worth a word
                rowCells.append(cellReference.isEmpty ? cell : cellReference + ": " + cell)
            case "row":
                let line = rowCells.joined(separator: "\t").trimmingCharacters(in: .whitespaces)
                if !line.isEmpty { text += line + "\n" }
            default: break
            }
        case .comments:
            if name == "t" { cellValue += current; capturing = false }
            if name == "comment" {
                let body = cellValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty { text += (commentReference.isEmpty ? body : commentReference + ": " + body) + "\n" }
            }
        case .chart:
            switch name {
            case "t": if !current.isEmpty { text += current + "\n" }; capturing = false
            case "v": if inChartPoint { chartValues.append(current.trimmingCharacters(in: .whitespaces)); inValue = false }
            case "pt": inChartPoint = false
            case "ser": if !chartValues.isEmpty { text += chartValues.joined(separator: "\t") + "\n" }
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
