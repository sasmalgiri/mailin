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
//          changes labelled inline with their author and date when recorded
//          ({inserted by Ann 2025-01-15: …} / {deleted …: …} / {moved from …: …}
//          / {moved to …: …}), formatting revisions as {formatting changed …}
//          markers at their place, a revised paragraph mark as
//          {paragraph mark deleted …}; every revision is also listed in
//          `Result.revisions` with the part it lives in (body, header N,
//          footer N, footnote N, endnote N, comment N, text box) and its
//          paragraph index; [Header], [Footer], [Footnotes], [Endnotes],
//          [Comments] parts are walked the same way as the body
//    XLSX  [Sheet: <name>] one line per row, each cell as "A1: value"; a
//          formula cell shows its stored result and the formula text
//          ("A1: 42 (formula =SUM(B1:B3))"), shared formulas re-based on the
//          cell; a date-formatted serial is rendered as the ISO date it
//          displays with the serial kept ("B2: 2025-01-15 (serial 45672)");
//          percentages and currencies keep the raw number and name the
//          format; hidden rows, hidden columns and very hidden sheets are
//          labelled and still read; [Workbook] lists defined names (hidden
//          ones marked), external workbook references (never refreshed) and
//          the 1904 date system; [Comments: <sheet>] "A1: text"
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

    /// Directive §6 "Word": one tracked change, located. The inline marker in
    /// `Result.text` carries the same author/date; this record adds the part
    /// and paragraph so a hit can say "deleted by Ann in footnote 2".
    struct Revision: Sendable, Equatable {
        enum Kind: String, Sendable {
            case inserted, deleted
            case movedFrom = "moved from", movedTo = "moved to"
            case formattingChanged = "formatting changed"
            case paragraphMarkInserted = "paragraph mark inserted", paragraphMarkDeleted = "paragraph mark deleted"
            case paragraphMarkMovedFrom = "paragraph mark moved from", paragraphMarkMovedTo = "paragraph mark moved to"
            case tableRowInserted = "table row inserted", tableRowDeleted = "table row deleted"
        }
        let kind: Kind
        /// The inserted / deleted / moved text; empty for formatting and mark revisions.
        let text: String
        /// `w:id` of the revision element, when present.
        let id: String?
        let author: String?
        /// `w:date` as written (ISO 8601).
        let date: String?
        /// "body", "header 1", "footer 2", "footnote 3", "endnote 1", "comment 2", "text box in body".
        let part: String
        /// 1-based paragraph ordinal within `part`.
        let paragraph: Int
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
        /// Word tracked changes, located (empty for the other kinds).
        var revisions: [Revision] = []
        /// CUR-06: statements about how far the reading can be trusted that
        /// are not parts left unread — e.g. an iWork 2013+ document opened
        /// with its password whose payload integrity is not verified.
        var notes: [String] = []
        var partial: Bool { !skipped.isEmpty }

        /// The child row's note: the parts not read, then the reading's notes.
        var childNote: String? {
            let parts = (skipped.isEmpty ? [] : ["not read: " + skipped.joined(separator: "; ")]) + notes
            return parts.isEmpty ? nil : parts.joined(separator: "; ")
        }
    }

    enum ExtractError: Error, LocalizedError, Equatable {
        case notAPackage(String)
        case encrypted
        /// §13.8 step 5: a password was given and did not open the file.
        case wrongPassword
        case noTextParts

        var errorDescription: String? {
            switch self {
            case .notAPackage(let detail): return "not an Office Open XML package: \(detail)"
            case .encrypted: return "password-protected Office file"
            case .wrongPassword: return "the password did not open the file"
            case .noTextParts: return "the package holds none of the parts that carry text"
            }
        }
    }

    /// One XML part is read whole; larger parts are listed as skipped. The
    /// base ceiling (round 0); a Resume round reads `ExtractionLimits.effective`.
    static var maxPartBytes: Int64 { ExtractionLimits.base.partBytes }

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
            let partLimit = ExtractionLimits.effective.partBytes
            guard member.uncompressedSize <= partLimit else {
                skipped.append("\(name) (\(member.uncompressedSize) bytes, over the \(partLimit)-byte guard)")
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
                out[rel.id] = rel.external ? rel.target : rel.target.hasPrefix("/") ? String(rel.target.dropFirst()) : resolve(folder, rel.target)
            }
            return out
        }

        var text = ""
        var components: [String] = []
        var skipped: [String] = []
        var revisions: [Revision] = []

        switch kind {
        case .docx:
            let main = OOXMLTextCollector(.wordprocessing)
            main.partLabel = "body"
            if try read("word/document.xml", into: main, skipped: &skipped) {
                components.append("Document")
                text += "[Document]\n" + main.text + "\n"
                revisions += main.revisions
            }
            let extras: [(prefix: String, label: String, part: String)] = [
                ("word/header", "Header", "header"), ("word/footer", "Footer", "footer"),
                ("word/footnotes", "Footnotes", "footnote"), ("word/endnotes", "Endnotes", "endnote"),
                ("word/comments", "Comments", "comment")]
            for extra in extras {
                for name in parts.keys.filter({ $0.hasPrefix(extra.prefix) && $0.hasSuffix(".xml") }).sorted() {
                    let collector = OOXMLTextCollector(.wordprocessing)
                    let number = sheetNumber(name)
                    collector.partLabel = number > 0 ? "\(extra.part) \(number)" : extra.part
                    if try read(name, into: collector, skipped: &skipped), !collector.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        components.append(extra.label)
                        text += "[\(extra.label)]\n" + collector.text + "\n"
                        revisions += collector.revisions
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
            let styles = OOXMLTextCollector(.styles)
            _ = try read("xl/styles.xml", into: styles, skipped: &ignored)
            let names = try sheetNames(workbook: workbook, parts: parts, read: { name in
                let c = OOXMLTextCollector(.raw)
                var s: [String] = []
                return try read(name, into: c, skipped: &s) ? c : nil
            })
            let sheetFiles = parts.keys.filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }
                .sorted { sheetNumber($0) < sheetNumber($1) }
            if sheetFiles.isEmpty && skipped.isEmpty { throw ExtractError.noTextParts }

            // [Workbook]: the date system, defined names (hidden ones marked), external workbooks (never refreshed).
            var workbookLines: [String] = []
            if workbook.date1904 { workbookLines.append("1904 date system: serial dates count from 1 January 1904") }
            for name in workbook.definedNames {
                let formula = name.formula.trimmingCharacters(in: .whitespacesAndNewlines)
                workbookLines.append((name.hidden ? "[hidden name \(name.name)]" : "name \(name.name)") + (formula.isEmpty ? "" : ": " + formula))
            }
            for link in parts.keys.filter({ $0.hasPrefix("xl/externalLinks/externalLink") && $0.hasSuffix(".xml") }).sorted(by: { sheetNumber($0) < sheetNumber($1) }) {
                let targets = try relationships(of: link).values.sorted()
                workbookLines.append("[external reference: \(targets.isEmpty ? link : targets.joined(separator: ", "))] not refreshed")
            }
            if !workbookLines.isEmpty {
                components.append("Workbook")
                text += "[Workbook]\n" + workbookLines.joined(separator: "\n") + "\n\n"
            }
            for file in sheetFiles {
                let collector = OOXMLTextCollector(.worksheet(sharedStrings: shared.sharedStrings, formats: styles.cellFormats, date1904: workbook.date1904))
                if try read(file, into: collector, skipped: &skipped) {
                    let sheet = names[file]
                    var label = "Sheet: " + (sheet?.name ?? "Sheet \(sheetNumber(file))")
                    if let state = sheet?.state {
                        if state == "veryHidden" { label += " (very hidden)" } else if state == "hidden" { label += " (hidden)" }
                    }
                    components.append(label)
                    text += "[\(label)]\n" + collector.text + "\n"
                    // Comments and drawings (text boxes, shapes) attached to this sheet, by its relationships.
                    for (_, target) in try relationships(of: file).sorted(by: { $0.value < $1.value }) where target.hasSuffix(".xml") {
                        let sheetName = sheet?.name ?? "Sheet \(sheetNumber(file))"
                        if target.contains("comments") {
                            let comments = OOXMLTextCollector(.comments)
                            if try read(target, into: comments, skipped: &skipped), !comments.text.isEmpty {
                                components.append("Comments: " + sheetName)
                                text += "[Comments: \(sheetName)]\n" + comments.text + "\n"
                            }
                        } else if target.contains("/drawings/drawing") {
                            let drawing = OOXMLTextCollector(.drawing)
                            if try read(target, into: drawing, skipped: &skipped), !drawing.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                components.append("Text boxes: " + sheetName)
                                text += "[Text boxes: \(sheetName)]\n" + drawing.text + "\n"
                            }
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
                                              note: inner.childNote, components: inner.components))
                children.append(contentsOf: inner.children.map { child in var nested = child; nested.path = member.name + " › " + child.path; return nested })
            } catch ExtractError.encrypted {
                children.append(ChildDocument(path: member.name, filename: filename, kind: innerKind.rawValue, sha256: sha, bytes: size, text: nil, state: .locked, note: "password-protected"))
            } catch ExtractError.noTextParts {
                children.append(ChildDocument(path: member.name, filename: filename, kind: innerKind.rawValue, sha256: sha, bytes: size, text: nil, state: .noText, note: nil))
            } catch {
                children.append(ChildDocument(path: member.name, filename: filename, kind: innerKind.rawValue, sha256: sha, bytes: size, text: nil, state: .failed, note: "\(error)"))
            }
        }
        return Result(text: text, components: components, skipped: skipped, notText: notText.sorted(), children: children, revisions: revisions)
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

    /// Directive §6 "Word": the inline marker head of a revision —
    /// "{deleted by Ann 2025-01-15: " / "{inserted: " / "{formatting changed by Ann}".
    static func revisionMarker(_ kind: Revision.Kind, author: String?, date: String?, opensText: Bool) -> String {
        var head = "{" + kind.rawValue
        if let author, !author.isEmpty { head += " by " + author }
        if let date, !date.isEmpty { head += " " + revisionDay(date) }
        return head + (opensText ? ": " : "}")
    }

    /// "2026-09-28T20:59:00Z" → "2026-09-28"; anything else as written.
    static func revisionDay(_ date: String) -> String {
        let scalars = Array(date)
        guard scalars.count >= 10, scalars[4] == "-", scalars[7] == "-", scalars.count == 10 || scalars[10] == "T" else { return date }
        return String(scalars[0..<10])
    }

    /// Directive §6 "Excel": one cell's text — the displayed value, then the
    /// raw serial / value / formula in one parenthesis. The displayed value is
    /// Excel's own rendering of the number format, en-US
    /// (`ExcelNumberFormatRenderer`), trimmed of the alignment spaces that
    /// `_)` and `?` add at its ends; "1/15/2025 (serial 45672)",
    /// "15% (raw 0.15)". A General cell keeps its stored text; a value
    /// Excel cannot show in its format (a negative date) keeps the stored
    /// value and names the format.
    static func cellText(value: String, isNumber: Bool, format: ExcelNumberFormat.Format?, date1904: Bool, formulaNote: String?) -> String {
        var shown = value
        var notes: [String] = []
        let raw = value.trimmingCharacters(in: .whitespaces)
        if isNumber, let format, format.kind != .general, let number = Double(raw) {
            let isDate = [.date, .time, .dateTime, .elapsedTime].contains(format.kind)
            if let rendered = ExcelNumberFormatRenderer.render(number, code: format.code, date1904: date1904)?.trimmingCharacters(in: .whitespaces) {
                if isDate {
                    shown = rendered
                    notes.append("serial " + raw)
                    if !date1904, number >= 60, number < 61, format.kind == .date || format.kind == .dateTime {
                        notes.append("29 February 1900 is a day the 1900 date system counts but the calendar does not have")
                    }
                } else if rendered != raw {
                    shown = rendered
                    notes.append("raw " + raw)
                }
            } else {
                notes.append("format " + format.code)
            }
        } else if !isNumber, let format, format.kind != .general, !value.isEmpty,
                  let rendered = ExcelNumberFormatRenderer.renderText(value, code: format.code)?.trimmingCharacters(in: .whitespaces),
                  rendered != value.trimmingCharacters(in: .whitespaces) {
            shown = rendered
            notes.append("text " + value)
        }
        if let formulaNote { notes.append(formulaNote) }
        if notes.isEmpty { return shown }
        return (shown.isEmpty ? "" : shown + " ") + "(" + notes.joined(separator: "; ") + ")"
    }
}

/// Collects the text of one OOXML part. Mode decides which elements carry
/// text and how rows, cells, paragraphs and formulas are separated.
final class OOXMLTextCollector: NSObject, XMLParserDelegate {
    enum Mode {
        case wordprocessing
        case drawing
        case sharedStrings
        /// A worksheet: shared strings, the cell formats by style index, the workbook's date system.
        case worksheet(sharedStrings: [String], formats: [Int: ExcelNumberFormat.Format], date1904: Bool)
        /// Excel comments part: "A1: text" per comment.
        case comments
        /// DrawingML chart: titles, labels and plotted values.
        case chart
        /// styles.xml: number formats and the cell style table.
        case styles
        /// Only structure (sheet names, relationships, workbook properties, defined names).
        case raw
    }

    struct Sheet { let name: String; let relationshipID: String; let state: String? }
    struct Relationship {
        let id: String
        let target: String
        /// `TargetMode="External"`: the target is outside the package (another workbook, a URL) and is never followed.
        let external: Bool
    }
    struct DefinedName { let name: String; let hidden: Bool; let formula: String }

    private let mode: Mode
    private(set) var text = ""
    private(set) var sharedStrings: [String] = []
    private(set) var sheets: [Sheet] = []
    private(set) var relationships: [Relationship] = []
    private(set) var definedNames: [DefinedName] = []
    /// `<workbookPr date1904="1"/>`: serial dates start in 1904.
    private(set) var date1904 = false
    /// `<p:sld show="0">`: the slide is hidden in the show.
    private(set) var hiddenSlide = false
    /// styles.xml: cellXfs index → number format.
    private(set) var cellFormats: [Int: ExcelNumberFormat.Format] = [:]
    /// Word: tracked changes found in this part, located.
    private(set) var revisions: [OfficeTextExtractor.Revision] = []
    /// Word: the part this collector reads ("body", "header 1", "footnote", "comment"); set before `parse`.
    var partLabel = "body"

    private var current = ""
    private var capturing = false
    private var cellType = ""
    private var cellValue = ""
    private var cellFormula = ""
    private var cellReference = ""
    private var cellStyle = ""
    private var inFormula = false
    private var inValue = false
    private var inInlineString = false
    private var rowCells: [String] = []
    private var rowHidden = false
    private var rowNumber = ""
    private var hiddenColumns = Set<Int>()
    private var formulaAttributes: [String: String] = [:]
    /// Shared formulas by `si`: the master cell and its text.
    private var sharedFormulas: [String: (cell: String, text: String)] = [:]
    private var sharedCurrent = ""
    private var cellInRow = 0
    private var cellDepth = 0
    private var failed = false
    private var depth = 0
    /// Depth at which a subtree whose text must not be read started (`mc:Fallback`
    /// duplicates the Choice; `w:rPrChange` and the other *PrChange elements
    /// hold the previous formatting, no text).
    private var suppressedDepth: Int?
    private var commentReference = ""
    private var chartValues: [String] = []
    private var inChartPoint = false
    private var rootSeen = false
    // styles.xml
    private var numberFormatCodes: [Int: String] = [:]
    private var inCellXfs = false
    private var cellXfIndex = 0
    private var definedNameAttributes: [String: String]?
    // Word revisions
    private var elementStack: [String] = []
    private struct Location { var part: String; var paragraphs: Int }
    private var locations: [Location] = []
    private struct OpenRevision { let kind: OfficeTextExtractor.Revision.Kind; let id: String?; let author: String?; let date: String?; let part: String; let paragraph: Int; var text: String; let depth: Int }
    private var openRevisions: [OpenRevision] = []
    /// Markers to emit when the current paragraph ends (a revised paragraph mark), one frame per open paragraph.
    private var paragraphMarkNotes: [[String]] = []

    init(_ mode: Mode) {
        self.mode = mode
    }

    /// False when the XML could not be parsed.
    func parse(_ data: Data) -> Bool {
        locations = [Location(part: partLabel, paragraphs: 0)]
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

    private var currentLocation: Location { locations.last ?? Location(part: partLabel, paragraphs: 0) }

    private func record(_ kind: OfficeTextExtractor.Revision.Kind, text: String, attributes: [String: String]) {
        let where_ = currentLocation
        revisions.append(OfficeTextExtractor.Revision(kind: kind, text: text, id: attributes["w:id"] ?? attributes["id"],
                                                      author: attributes["w:author"] ?? attributes["author"],
                                                      date: attributes["w:date"] ?? attributes["date"], part: where_.part, paragraph: where_.paragraphs))
    }

    private func marker(_ kind: OfficeTextExtractor.Revision.Kind, attributes: [String: String], opensText: Bool) -> String {
        OfficeTextExtractor.revisionMarker(kind, author: attributes["w:author"] ?? attributes["author"], date: attributes["w:date"] ?? attributes["date"], opensText: opensText)
    }

    /// Text that belongs to the current text stream and to the innermost open revision.
    private func emit(_ piece: String) {
        text += piece
        if !openRevisions.isEmpty { openRevisions[openRevisions.count - 1].text += piece }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        let name = local(elementName)
        depth += 1
        if !rootSeen {
            rootSeen = true
            if case .drawing = mode, name == "sld", attributes["show"] == "0" { hiddenSlide = true }
        }
        if name == "Fallback", suppressedDepth == nil, elementName.lowercased().hasPrefix("mc:") { suppressedDepth = depth }
        if suppressedDepth != nil { elementStack.append(name); return }
        switch mode {
        case .wordprocessing:
            let parent = elementStack.last ?? ""
            let grandparent = elementStack.count >= 2 ? elementStack[elementStack.count - 2] : ""
            switch name {
            case "t", "delText": capturing = true; current = ""
            case "tab": emit("\t")
            case "br", "cr": emit("\n")
            case "p":
                locations[locations.count - 1].paragraphs += 1
                paragraphMarkNotes.append([])
            case "tr": cellInRow = 0
            case "tc":
                if cellInRow > 0 { text += "\t" }   // cells of one row on one line
                cellInRow += 1
                cellDepth += 1
            case "ins", "del", "moveFrom", "moveTo":
                let containerKind: OfficeTextExtractor.Revision.Kind = name == "ins" ? .inserted : name == "del" ? .deleted : name == "moveFrom" ? .movedFrom : .movedTo
                if parent == "rPr" {
                    // The paragraph mark itself was revised (w:pPr/w:rPr/w:del): say so at the paragraph's end
                    // instead of silently merging the paragraphs. A run-level rPr never carries these.
                    guard grandparent == "pPr" else { break }
                    let markKind: OfficeTextExtractor.Revision.Kind = name == "ins" ? .paragraphMarkInserted : name == "del" ? .paragraphMarkDeleted
                        : name == "moveFrom" ? .paragraphMarkMovedFrom : .paragraphMarkMovedTo
                    record(markKind, text: "", attributes: attributes)
                    if !paragraphMarkNotes.isEmpty { paragraphMarkNotes[paragraphMarkNotes.count - 1].append(marker(markKind, attributes: attributes, opensText: false)) }
                } else if parent == "trPr" {
                    let rowKind: OfficeTextExtractor.Revision.Kind = name == "del" ? .tableRowDeleted : .tableRowInserted
                    record(rowKind, text: "", attributes: attributes)
                    text += marker(rowKind, attributes: attributes, opensText: false)
                } else if parent == "numPr" || parent == "tcPr" || parent == "tblPr" {
                    // Numbering / cell-level revision: the formatting changed, the text is not duplicated.
                    record(.formattingChanged, text: "", attributes: attributes)
                    text += marker(.formattingChanged, attributes: attributes, opensText: false)
                } else {
                    let where_ = currentLocation
                    openRevisions.append(OpenRevision(kind: containerKind, id: attributes["w:id"] ?? attributes["id"],
                                                      author: attributes["w:author"] ?? attributes["author"], date: attributes["w:date"] ?? attributes["date"],
                                                      part: where_.part, paragraph: where_.paragraphs, text: "", depth: depth))
                    text += marker(containerKind, attributes: attributes, opensText: true)
                }
            case "rPrChange", "pPrChange", "sectPrChange", "tblPrChange", "tblPrExChange", "trPrChange", "tcPrChange", "tblGridChange", "numberingChange":
                record(.formattingChanged, text: "", attributes: attributes)
                text += marker(.formattingChanged, attributes: attributes, opensText: false)
                suppressedDepth = depth   // the previous formatting inside holds no text
            case "txbxContent":
                text += "\n[Text box] "
                locations.append(Location(part: "text box in " + currentLocation.part, paragraphs: 0))
            case "footnote", "endnote", "comment":
                let id = attributes["w:id"] ?? attributes["id"] ?? ""
                locations.append(Location(part: id.isEmpty ? name : "\(name) \(id)", paragraphs: 0))
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
            case "col":
                if let flag = attributes["hidden"], flag == "1" || flag.lowercased() == "true",
                   let first = Int(attributes["min"] ?? ""), let last = Int(attributes["max"] ?? ""), first >= 1, last >= first {
                    // Column indexes are 1-based in the part; at most the sheet's width is ever named.
                    for column in first...min(last, ExcelFormulaText.maxColumn) { hiddenColumns.insert(column - 1) }
                }
            case "row":
                rowCells = []
                rowNumber = attributes["r"] ?? ""
                rowHidden = attributes["hidden"].map { $0 == "1" || $0.lowercased() == "true" } ?? false
            case "c":
                cellType = attributes["t"] ?? ""
                cellReference = attributes["r"] ?? ""
                cellStyle = attributes["s"] ?? ""
                cellValue = ""; cellFormula = ""; formulaAttributes = [:]
            case "v": inValue = true; current = ""
            case "f": inFormula = true; current = ""; formulaAttributes = attributes
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
        case .styles:
            switch name {
            case "numFmt":
                if let id = Int(attributes["numFmtId"] ?? ""), let code = attributes["formatCode"] { numberFormatCodes[id] = code }
            case "cellXfs": inCellXfs = true; cellXfIndex = 0
            case "xf":
                guard inCellXfs else { break }
                let id = Int(attributes["numFmtId"] ?? "") ?? 0
                cellFormats[cellXfIndex] = ExcelNumberFormat.classify(id: id, code: numberFormatCodes[id])
                cellXfIndex += 1
            default: break
            }
        case .raw:
            if name == "sheet" {
                let rid = attributes["r:id"] ?? attributes.first { $0.key.hasSuffix(":id") }?.value ?? ""
                sheets.append(Sheet(name: attributes["name"] ?? "", relationshipID: rid, state: attributes["state"]))
            }
            if name == "Relationship", let id = attributes["Id"], let target = attributes["Target"] {
                relationships.append(Relationship(id: id, target: target, external: attributes["TargetMode"]?.lowercased() == "external"))
            }
            if name == "workbookPr", let flag = attributes["date1904"], flag == "1" || flag.lowercased() == "true" { date1904 = true }
            if name == "definedName" { definedNameAttributes = attributes; capturing = true; current = "" }
        }
        elementStack.append(name)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if suppressedDepth != nil { return }
        if capturing || inValue || inFormula { current += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = local(elementName)
        defer { depth -= 1 }
        if !elementStack.isEmpty { elementStack.removeLast() }
        if let suppressed = suppressedDepth {
            if depth == suppressed { suppressedDepth = nil }
            return
        }
        switch mode {
        case .wordprocessing:
            if name == "t" || name == "delText" { emit(current); capturing = false }
            if name == "p" {
                let notes = paragraphMarkNotes.popLast() ?? []
                if !notes.isEmpty { text += notes.joined() }
                text += cellDepth > 0 ? " " : "\n"   // paragraphs inside a cell stay on the row's line
            }
            if name == "tc" { cellDepth = max(0, cellDepth - 1) }
            if name == "tr" { text += "\n" }
            if name == "ins" || name == "del" || name == "moveFrom" || name == "moveTo", let open = openRevisions.last, open.depth == depth {
                openRevisions.removeLast()
                text += "}"
                revisions.append(OfficeTextExtractor.Revision(kind: open.kind, text: open.text, id: open.id, author: open.author, date: open.date,
                                                              part: open.part, paragraph: open.paragraph))
            }
            if name == "txbxContent" { text += "\n"; if locations.count > 1 { locations.removeLast() } }
            if name == "footnote" || name == "endnote" || name == "comment" { if locations.count > 1 { locations.removeLast() } }
        case .drawing:
            if name == "t" { text += current; capturing = false }
            if name == "text", elementName.lowercased().hasPrefix("p:") { text += current + "\n"; capturing = false }
            if name == "p" { text += "\n" }
        case .sharedStrings:
            if name == "t" { sharedCurrent += current; capturing = false }
            if name == "si" { sharedStrings.append(sharedCurrent) }
        case .worksheet(let shared, let formats, let date1904):
            switch name {
            case "v":
                inValue = false
                // Audit A05: a shared-string index is untrusted; only 0..<count reads the table.
                if cellType == "s", let index = Int(current.trimmingCharacters(in: .whitespaces)), index >= 0, index < shared.count {
                    cellValue = shared[index]
                } else {
                    cellValue = current
                }
            case "f":
                inFormula = false
                cellFormula = current
                if formulaAttributes["t"] == "shared", let si = formulaAttributes["si"], !current.isEmpty, sharedFormulas[si] == nil {
                    sharedFormulas[si] = (cellReference, current)
                }
            case "t": if inInlineString { cellValue += current; capturing = false }
            case "is": inInlineString = false
            case "c":
                let isNumber = cellType.isEmpty || cellType == "n"
                if cellType == "b" { let flag = cellValue.trimmingCharacters(in: .whitespaces); if flag == "1" || flag == "0" { cellValue = flag == "1" ? "TRUE" : "FALSE" } }
                let format = Int(cellStyle).flatMap { formats[$0] }
                let cell = OfficeTextExtractor.cellText(value: cellValue, isNumber: isNumber, format: format, date1904: date1904, formulaNote: formulaNote())
                guard !cell.isEmpty else { break }   // an empty cell carries no address worth a word
                var line = cellReference.isEmpty ? cell : cellReference + ": " + cell
                if let position = ExcelFormulaText.parseA1(cellReference), hiddenColumns.contains(position.column) {
                    line = "[hidden column \(OfficeTextExtractor.columnName(position.column))] " + line
                }
                rowCells.append(line)
            case "row":
                let line = rowCells.joined(separator: "\t").trimmingCharacters(in: .whitespaces)
                if !line.isEmpty { text += (rowHidden ? "[hidden row \(rowNumber)] " : "") + line + "\n" }
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
        case .styles:
            if name == "cellXfs" { inCellXfs = false }
        case .raw:
            if name == "definedName", let attributes = definedNameAttributes {
                let hidden = attributes["hidden"].map { $0 == "1" || $0.lowercased() == "true" } ?? false
                definedNames.append(DefinedName(name: attributes["name"] ?? "", hidden: hidden, formula: current))
                definedNameAttributes = nil; capturing = false
            }
        }
    }

    /// "formula =SUM(A1:A2)" for the cell just closed; a shared formula's
    /// dependent cell gets the master text re-based on this cell, or a note
    /// naming what could not be shifted. Nil when the cell has no formula.
    private func formulaNote() -> String? {
        if !cellFormula.isEmpty { return "formula =" + cellFormula }
        guard formulaAttributes["t"] == "shared", let si = formulaAttributes["si"] else {
            return formulaAttributes.isEmpty ? nil : "formula not stored"
        }
        guard let master = sharedFormulas[si] else { return "shared formula \(si) without its master cell" }
        guard let from = ExcelFormulaText.parseA1(master.cell), let to = ExcelFormulaText.parseA1(cellReference) else {
            return "formula =\(master.text) shared from \(master.cell); not shifted"
        }
        do {
            return "formula =" + (try ExcelFormulaText.shift(master.text, rowDelta: to.row - from.row, columnDelta: to.column - from.column))
        } catch ExcelFormulaText.ShiftError.outOfRange(let reference) {
            return "formula =\(master.text) shared from \(master.cell); not shifted: \(reference) leaves the sheet"
        } catch {
            return "formula =\(master.text) shared from \(master.cell); not shifted"
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        failed = true
    }
}
