//
//  IWorkDocumentReader.swift
//  ArchiveCore
//
//  Directive 2026-11-07 §6 "OpenDocument/iWork": the Pages / Numbers / Keynote
//  reader verified on real files written by iWork '09, 2013 and 2018 (Apache
//  Tika's corpus, `TikaODFIWorkFixtureTests`). It replaces `IWorkTextExtractor`
//  at the one dispatch seam in `DocumentTextExtractor.extract`; the earlier
//  reader stays in DocumentTextExtractors.swift (rule 14) and its IWA, snappy
//  and protobuf pieces are reused here.
//
//  Three generations of the format:
//    iWork '09        one XML document: index.xml / index.apxl, plain or
//                     gzip-compressed (index.xml.gz / index.apxl.gz)
//    iWork 2013+      Index/*.iwa (snappy-framed protobuf objects)
//    iWork 2018+      the same, but the document is a ZIP of a bundle whose
//                     Index/ lives inside an inner Index.zip
//  Password-protected '09 documents store their members under Apple's own ZIP
//  methods 25451/25452: reported locked without a password, opened with one
//  (audit R6, IWork09Encryption.swift). IWA tables are decoded cell by cell
//  by IWATableDecoder.swift (audit R6).
//
//  What the '09 collector reads (the elements Tika's handlers read, plus
//  numbers and dates): paragraphs (sf:p, placeholder "ghost text" excluded),
//  table cells row by row (text, numbers, formula results, dates, pop-up
//  menus), table and chart names with chart row/column labels, Pages
//  headers and footers per page with the auto page number in the document's
//  format, footnotes, comments, text boxes; Keynote slides, notes and master
//  slides; Numbers sheets.
//

import Foundation

enum IWorkDocumentReader {

    /// Apple's ZIP methods for password-protected iWork '09 members.
    static let protectedMethods: Set<UInt16> = [25451, 25452]

    /// - Parameter password: audit R6 — opens a password-protected iWork '09
    ///   document (`IWork09Encryption`) for this call only; without it the
    ///   document is reported locked.
    static func extract(fileURL: URL, kind: DocumentKind, password: String? = nil) throws -> OfficeTextExtractor.Result {
        let members: [ZIPArchiveReader.Member]
        do { members = try ZIPArchiveReader.members(of: fileURL) } catch {
            throw OfficeTextExtractor.ExtractError.notAPackage(String(describing: error))
        }
        let scratch = try DocumentTextExtractor.scratchDirectory("iwork")
        defer { try? FileManager.default.removeItem(at: scratch) }
        if let password, members.contains(where: { protectedMethods.contains($0.method) }) {
            let unlocked: (url: URL, leftOut: [String])
            do {
                unlocked = try IWork09Encryption.unlock(fileURL: fileURL, members: members, password: password, scratch: scratch,
                                                        limit: ExtractionLimits.effective.partBytes)
            } catch let error as ProtectedContentError {
                throw OfficeTextExtractor.ExtractError.notAPackage(error.localizedDescription)
            }
            let plainMembers = try ZIPArchiveReader.members(of: unlocked.url)
            let result = try extract(members: plainMembers, archive: unlocked.url, kind: kind, scratch: scratch, nested: false)
            return OfficeTextExtractor.Result(text: result.text, components: result.components, skipped: result.skipped,
                                              notText: (result.notText + unlocked.leftOut).sorted())
        }
        return try extract(members: members, archive: fileURL, kind: kind, scratch: scratch, nested: false)
    }

    private static func extract(members: [ZIPArchiveReader.Member], archive: URL, kind: DocumentKind, scratch: URL, nested: Bool) throws -> OfficeTextExtractor.Result {
        if members.contains(where: { protectedMethods.contains($0.method) }) {
            throw OfficeTextExtractor.ExtractError.encrypted
        }
        var notText: [String] = []
        for m in members where !m.isDirectory {
            let base = (m.name as NSString).lastPathComponent.lowercased()
            if m.name.contains("Data/") || m.name.contains("QuickLook/") || m.name.contains("thumbs/") || m.name.contains("Metadata/")
                || base.hasSuffix(".pdf") || base.hasSuffix(".png") || base.hasSuffix(".jpg") || base.hasSuffix(".jpeg") || base.hasSuffix(".tiff") {
                notText.append(m.name)
            }
        }
        let limit = ExtractionLimits.effective.partBytes

        // iWork '09: one XML document, plain or gzip-compressed.
        let legacyNames = ["index.xml", "index.apxl", "index.xml.gz", "index.apxl.gz"]
        if let xml = members.first(where: { legacyNames.contains(($0.name as NSString).lastPathComponent) && !$0.isDirectory }) {
            guard xml.uncompressedSize <= limit else {
                throw OfficeTextExtractor.ExtractError.notAPackage("\(xml.name) is \(xml.uncompressedSize) bytes, over the \(limit)-byte guard")
            }
            var data = try DocumentTextExtractor.memberData(xml, from: archive, scratch: scratch)
            if xml.name.hasSuffix(".gz") {
                let packed = scratch.appendingPathComponent(UUID().uuidString + ".gz")
                let plain = scratch.appendingPathComponent(UUID().uuidString + ".xml")
                try data.write(to: packed)
                do { try ZIPArchiveReader.gunzip(packed, to: plain, maxOutputBytes: limit) } catch {
                    throw OfficeTextExtractor.ExtractError.notAPackage("\(xml.name): \(error)")
                }
                data = try Data(contentsOf: plain)
                try? FileManager.default.removeItem(at: packed); try? FileManager.default.removeItem(at: plain)
            }
            let collector = IWork09Collector(kind: kind)
            guard collector.parse(data) else { throw OfficeTextExtractor.ExtractError.notAPackage("\(xml.name) is not well-formed XML") }
            var text = ""
            var components: [String] = []
            for section in collector.sections where !section.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                components.append(section.label)
                text += "[\(section.label)]\n" + section.text.trimmingCharacters(in: .newlines) + "\n"
            }
            if components.isEmpty { throw OfficeTextExtractor.ExtractError.noTextParts }
            return OfficeTextExtractor.Result(text: text, components: components, skipped: [], notText: notText.sorted())
        }

        // iWork 2018+: a ZIP of the bundle, Index/ inside an inner Index.zip.
        if !nested, let inner = members.first(where: { ($0.name as NSString).lastPathComponent == "Index.zip" && !$0.isDirectory }) {
            guard inner.uncompressedSize <= ExtractionLimits.effective.totalArchiveBytes else {
                throw OfficeTextExtractor.ExtractError.notAPackage("\(inner.name) is \(inner.uncompressedSize) bytes, over the \(ExtractionLimits.effective.totalArchiveBytes)-byte guard")
            }
            let innerURL = scratch.appendingPathComponent(UUID().uuidString + ".zip")
            try ZIPArchiveReader.extract(inner, from: archive, to: innerURL)
            let innerMembers: [ZIPArchiveReader.Member]
            do { innerMembers = try ZIPArchiveReader.members(of: innerURL) } catch {
                throw OfficeTextExtractor.ExtractError.notAPackage("\(inner.name): \(error)")
            }
            var result = try extract(members: innerMembers, archive: innerURL, kind: kind, scratch: scratch, nested: true)
            result = OfficeTextExtractor.Result(text: result.text, components: result.components, skipped: result.skipped,
                                                notText: (result.notText + notText).sorted())
            return result
        }

        // iWork 2013+: IWA objects (the earlier reader's object walk).
        // "Slide.iwa" is the first slide, "Slide-1.iwa" the second, and so on.
        func order(_ name: String) -> String { stripBundlePrefix(name).replacingOccurrences(of: "Slide.iwa", with: "Slide-0.iwa") }
        let textMembers = members.filter { carriesText(stripBundlePrefix($0.name)) }
            .sorted { order($0.name).localizedStandardCompare(order($1.name)) == .orderedAscending }
        guard !textMembers.isEmpty else {
            throw OfficeTextExtractor.ExtractError.notAPackage("no Index/*.iwa members — not an iWork document")
        }
        var skipped: [String] = []
        var text = ""
        var components: [String] = []
        var sheetNames: [String] = []
        var slideIndex = 0
        var cellStrings: [String] = []
        for member in textMembers {
            guard member.uncompressedSize <= limit else {
                skipped.append("\(member.name) (\(member.uncompressedSize) bytes, over the \(limit)-byte guard)")
                continue
            }
            let data = try DocumentTextExtractor.memberData(member, from: archive, scratch: scratch)
            let objects: [IWAFile.Object]
            do { objects = try IWAFile.objects(in: data, limit: Int(limit)) } catch {
                skipped.append("\(member.name) (\(error))"); continue
            }
            let base = String(stripBundlePrefix(member.name).dropFirst("Index/".count))
            var storages: [String] = []
            for object in objects {
                switch object.type {
                case IWorkTextExtractor.storageArchiveType:
                    for s in ProtobufWalker.strings(field: 3, in: object.payload) where !s.isEmpty { storages.append(s) }
                case IWorkTextExtractor.tableDataListType:
                    for entry in ProtobufWalker.messages(field: 3, in: object.payload) {
                        for s in ProtobufWalker.strings(field: 3, in: entry) where !s.isEmpty { cellStrings.append(s) }
                    }
                case IWorkTextExtractor.sheetArchiveType where kind == .numbers:
                    sheetNames.append(contentsOf: ProtobufWalker.strings(field: 1, in: object.payload))
                default: break
                }
            }
            if base.hasPrefix("Slide-") || base == "Slide.iwa" {
                slideIndex += 1
                if !storages.isEmpty {
                    let label = "Slide \(slideIndex)"
                    components.append(label)
                    text += "[\(label)]\n" + storages.joined(separator: "\n") + "\n"
                }
            } else if !storages.isEmpty {
                let label = kind == .key ? "Presentation" : "Document"
                if !components.contains(label) { components.append(label) }
                text += "[\(label)]\n" + storages.joined(separator: "\n") + "\n"
            }
        }
        // Audit R6: the tables cell by cell (numbers, dates, durations,
        // booleans, formula results, text), from every Index/*.iwa object.
        var placed: Set<String> = []
        for table in try decodedTables(members: members, archive: archive, scratch: scratch, limit: limit, skipped: &skipped) {
            // "Table cells: …" — the earlier section's label, now one per table.
            var label = "Table cells: " + (table.name.isEmpty ? "Table" : table.name)
            if let sheet = table.sheet, !sheet.isEmpty { label += " (sheet: \(sheet))" }
            components.append(label)
            text += "[\(label)]\n" + table.rows.map { $0.joined(separator: "\t") }.joined(separator: "\n") + "\n"
            placed.formUnion(table.strings)
        }
        // Strings of the table lists that no decoded cell showed (all of them
        // when no table could be decoded) keep the earlier section.
        let unplaced = cellStrings.filter { !placed.contains($0) }
        if !unplaced.isEmpty {
            let label = sheetNames.isEmpty ? "Table cells" : "Table cells (sheets: \(sheetNames.joined(separator: ", ")))"
            components.append(label)
            text += "[\(label)]\n" + unplaced.joined(separator: "\n") + "\n"
        }
        if components.isEmpty && skipped.isEmpty { throw OfficeTextExtractor.ExtractError.noTextParts }
        return OfficeTextExtractor.Result(text: text, components: components, skipped: skipped, notText: notText.sorted())
    }

    /// Audit R6: tables with at least one cell, decoded from the objects of
    /// every Index/*.iwa member (tables, tiles and lists live in Document,
    /// CalculationEngine, Slide and Tables/* members). A member over the part
    /// guard is named in `skipped`, never read partly.
    private static func decodedTables(members: [ZIPArchiveReader.Member], archive: URL, scratch: URL, limit: Int64,
                                      skipped: inout [String]) throws -> [IWATableDecoder.Table] {
        var objects: [Int: IWAFile.Object] = [:]
        var sawTableModel = false
        for member in members where !member.isDirectory {
            let name = stripBundlePrefix(member.name)
            guard name.hasPrefix("Index/"), name.hasSuffix(".iwa") else { continue }
            guard member.uncompressedSize <= limit else {
                let note = "\(member.name) (\(member.uncompressedSize) bytes, over the \(limit)-byte guard)"
                if !skipped.contains(note) { skipped.append(note) }
                continue
            }
            let data = try DocumentTextExtractor.memberData(member, from: archive, scratch: scratch)
            guard let found = try? IWAFile.identifiedObjects(in: data, limit: Int(limit)) else { continue }
            for (id, object) in found where objects[id] == nil {
                objects[id] = object
                if object.type == IWATableDecoder.tableModelType { sawTableModel = true }
            }
        }
        guard sawTableModel else { return [] }
        return IWATableDecoder.tables(objects: objects).filter { !$0.rows.isEmpty }
    }

    /// IWA members that carry user text: the document, every slide (not the
    /// masters), and table cell strings. Stylesheets, view state, metadata and
    /// calculation tokens are not read.
    static func carriesText(_ name: String) -> Bool {
        guard name.hasPrefix("Index/"), name.hasSuffix(".iwa") else { return false }
        let base = String(name.dropFirst("Index/".count))
        if base.hasPrefix("Document") { return true }
        if base == "Slide.iwa" || base.hasPrefix("Slide-") { return true }
        if base.hasPrefix("Tables/DataList") { return true }
        return false
    }

    /// "Presentation.key/Index/Slide-1.iwa" → "Index/Slide-1.iwa".
    private static func stripBundlePrefix(_ name: String) -> String {
        if let range = name.range(of: "Index/") { return String(name[range.lowerBound...]) }
        return name
    }
}

// MARK: - iWork '09 XML

/// Pages / Numbers / Keynote '09 `index.xml` / `index.apxl`, read into labelled sections.
final class IWork09Collector: NSObject, XMLParserDelegate {
    struct Section { var label: String; var text: String }

    private let kind: DocumentKind
    private(set) var sections: [Section] = []
    private var ok = true

    // Document order output
    private var body = Section(label: "Document", text: "")
    private var current: Section
    private var finished: [Section] = []

    // Element context
    private var depth = 0
    private var paragraphDepth = 0
    private var ghostDepth: Int?
    private var skipDepths: [Int] = []

    // Headers / footers / footnotes / comments (Pages)
    private enum Region { case body, header(String), footer(String), footnotes, annotations, notes, masterSlide }
    private var regionStack: [(region: Region, depth: Int, saved: Section)] = []
    private var headerTexts: [String: String] = [:]   // sf:name → text (with page-number marker)
    private var footerTexts: [String: String] = [:]
    private var pageNumberFormat: String?
    private var pageCount = 0
    private var footnotes = Section(label: "Footnotes", text: "")
    private var annotations = Section(label: "Comments", text: "")
    private var hfTarget: String?                     // current header/footer identifier while inside it
    private var hfText = ""
    static let pageNumberMarker = "\u{E000}"

    // Slides (Keynote)
    private var slideIndex = 0
    private var notesText = ""
    private var slideStack: [Int] = []
    private var masterSlides = Section(label: "Master slides", text: "")

    // Tables
    private var datasourceDepth: Int?
    private var columns = 0
    private var columnIndex = 0
    private var cellValueDepth: Int?
    private var cellText = ""
    private var tableName: String?
    private var menuItems: [String: String] = [:]
    private var menuItemID: String?
    private var inChartNames = false

    init(kind: DocumentKind) {
        self.kind = kind
        current = body
    }

    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldResolveExternalEntities = false
        let parsed = parser.parse()
        finish()
        return parsed && ok
    }

    private func finish() {
        finished.append(current)
        // Pages: headers and footers once per page, like the printed document.
        if !headerTexts.isEmpty || !footerTexts.isEmpty {
            let pages = max(pageCount, 1)
            var header = Section(label: "Header", text: ""), footer = Section(label: "Footer", text: "")
            for page in 1...pages {
                if let h = headerFooter(headerTexts, page: page), !h.isEmpty { header.text += (pages > 1 ? "Page \(page): " : "") + h + "\n" }
                if let f = headerFooter(footerTexts, page: page), !f.isEmpty { footer.text += (pages > 1 ? "Page \(page): " : "") + f + "\n" }
            }
            finished.append(header); finished.append(footer)
        }
        finished.append(footnotes)
        finished.append(annotations)
        finished.append(masterSlides)
        sections = finished.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Tika's rule: first page uses the "First" variant when set, even pages "Even", otherwise "Odd".
    private func headerFooter(_ texts: [String: String], page: Int) -> String? {
        func pick(_ suffix: String) -> String? {
            texts.first { $0.key.hasPrefix("SFWPDefault" + suffix) }.map(\.value)
        }
        var text: String?
        if page == 1, let first = pick("First"), !first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text = first }
        else if page % 2 == 0, let even = pick("Even"), !even.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text = even }
        else { text = pick("Odd") ?? texts.values.first }
        guard let chosen = text else { return nil }
        return chosen.replacingOccurrences(of: Self.pageNumberMarker, with: AutoPageNumber.format(page, style: pageNumberFormat))
            .trimmingCharacters(in: .newlines)
    }

    private var capturing: Bool { paragraphDepth > 0 && ghostDepth == nil && skipDepths.isEmpty }

    private func append(_ s: String) {
        if cellValueDepth != nil { cellText += s; return }
        if hfTarget != nil { hfText += s; return }
        if let top = regionStack.last {
            switch top.region {
            case .footnotes: footnotes.text += s; return
            case .annotations: annotations.text += s; return
            case .notes: notesText += s; return
            case .masterSlide: masterSlides.text += s; return
            default: break
            }
        }
        current.text += s
    }

    private func startSlide(_ label: String) {
        finished.append(current)
        current = Section(label: label, text: "")
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        depth += 1
        switch name {
        // Pages regions
        case "sf:page-start": pageCount += 1
        case "sf:headers": regionStack.append((.header(""), depth, current))
        case "sf:footers": regionStack.append((.footer(""), depth, current))
        case "sf:header", "sf:footer":
            if let top = regionStack.last, case .header = top.region, name == "sf:header" { hfTarget = attributes["sf:name"] ?? "SFWPDefaultOddHeaderIdentifier"; hfText = "" }
            if let top = regionStack.last, case .footer = top.region, name == "sf:footer" { hfTarget = attributes["sf:name"] ?? "SFWPDefaultOddFooterIdentifier"; hfText = "" }
        case "sf:page-number":
            if hfTarget != nil {
                pageNumberFormat = attributes["sf:format"] ?? pageNumberFormat
                hfText += Self.pageNumberMarker
            } else if capturing, let value = attributes["sf:value"] {
                append(value)
            }
        case "sf:footnotes": regionStack.append((.footnotes, depth, current))
        case "sf:footnote-mark":
            if let mark = attributes["sf:mark"], regionStack.last.map({ if case .footnotes = $0.region { return true }; return false }) == true { footnotes.text += "\(mark) " }
        case "sf:annotations": regionStack.append((.annotations, depth, current))
        case "sf:annotation" where regionStack.last.map({ if case .annotations = $0.region { return true }; return false }) == true:
            annotations.text += "[Comment] "
        case "sf:ghost-text": ghostDepth = depth
        case "sf:metadata", "sl:publication-info", "key:metadata", "sf:calc-engine", "sf:calc-engine-entities": skipDepths.append(depth)

        // Keynote
        case "key:slide":
            slideIndex += 1
            slideStack.append(depth)
            startSlide("Slide \(slideIndex)")
        case "key:master-slide":
            regionStack.append((.masterSlide, depth, current))
            if let title = attributes["key:name"] { masterSlides.text += "\n[\(title)]\n" }
        case "key:notes": regionStack.append((.notes, depth, current))

        // Numbers
        case "ls:workspace":
            finished.append(current)
            current = Section(label: "Sheet: " + (attributes["ls:workspace-name"] ?? "Sheet"), text: "")

        // Tables
        case "sf:tabular-model":
            tableName = attributes["sf:name"]
            if let n = tableName, !n.isEmpty { append("\nTable: \(n)\n") }
        case "sf:grid":
            columns = Int(attributes["sf:numcols"] ?? "") ?? 0
        case "sf:columns" where columns == 0:
            columns = Int(attributes["sf:count"] ?? "") ?? 0
        case "sf:datasource":
            datasourceDepth = depth
            columnIndex = 0
        case "sf:menu-choices": menuItems = [:]
        case "sf:chart-name":
            if let n = attributes["sfa:string"], !n.isEmpty { append("\nChart: \(n)\n") }
        case "sf:chart-row_names", "sf:chart-column_names": inChartNames = true
        case "sf:string" where inChartNames:
            if let s = attributes["sfa:string"], !s.isEmpty { append(s + "\t") }

        // Text
        case "sf:p": paragraphDepth += 1
        case "sf:br" where capturing, "sf:lnbr" where capturing, "sf:footnotebr" where capturing: append("\n")
        case "sf:tab" where capturing: append("\t")
        case "sf:text" where kind == .numbers && datasourceDepth == nil: break
        default: break
        }
        // Table cells: the direct children of sf:datasource.
        if let ds = datasourceDepth, depth == ds + 1 {
            cellValueDepth = depth
            cellText = ""
            switch name {
            case "sf:n", "sf:rn": cellText = attributes["sf:v"] ?? ""
            case "sf:d", "sf:rd": cellText = attributes["sf:cell-date"].flatMap(Self.date) ?? ""
            case "sf:b", "sf:rb": cellText = attributes["sf:value"].map { $0 == "true" || $0 == "1" ? "TRUE" : "FALSE" } ?? ""
            default: break
            }
        } else if cellValueDepth != nil {
            // Inside a cell: its text, a formula's result, or a pop-up menu
            // whose choices (sf:t by ID) are resolved through proxied-cell-ref.
            switch name {
            case "sf:t": if let id = attributes["sfa:ID"] { menuItemID = id }
            case "sf:ct":
                if let s = attributes["sfa:s"] { if let id = menuItemID { menuItems[id] = s } else { cellText += s } }
            case "sf:rn", "sf:n": if let v = attributes["sf:v"] { cellText += v }
            case "sf:rd", "sf:d": if let d = attributes["sf:cell-date"].flatMap(Self.date) { cellText += d }
            case "sf:proxied-cell-ref": if let ref = attributes["sfa:IDREF"], let s = menuItems[ref] { cellText += s }
            default: break
            }
        }
    }

    static func date(_ seconds: String) -> String? {
        guard let s = Double(seconds) else { return nil }
        let date = Date(timeIntervalSinceReferenceDate: s)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard capturing else { return }
        append(string)
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        defer { depth -= 1 }
        if let last = skipDepths.last, last == depth { skipDepths.removeLast() }
        if ghostDepth == depth { ghostDepth = nil }
        if let cell = cellValueDepth, depth == cell {
            // One cell closed: emit it, break the row at the column count.
            appendCell(cellText)
            cellValueDepth = nil
            cellText = ""
            menuItemID = nil
        } else if cellValueDepth != nil, name == "sf:t" {
            menuItemID = nil
        }
        if let top = regionStack.last, top.depth == depth {
            regionStack.removeLast()
            switch top.region {
            case .notes:
                if !notesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    finished.append(current)
                    current = Section(label: "Notes \(slideIndex)", text: notesText)
                    finished.append(current)
                    current = Section(label: "Slide \(slideIndex) (continued)", text: "")
                }
                notesText = ""
            default: break
            }
        }
        switch name {
        case "sf:header", "sf:footer":
            if let target = hfTarget {
                if name == "sf:header" { headerTexts[target] = hfText } else { footerTexts[target] = hfText }
                hfTarget = nil; hfText = ""
            }
        case "sf:p":
            paragraphDepth = max(0, paragraphDepth - 1)
            if ghostDepth == nil && skipDepths.isEmpty { append("\n") }
        case "sf:datasource":
            if columnIndex != 0 { append("\n") }
            datasourceDepth = nil; columns = 0; columnIndex = 0
        case "sf:tabular-model": tableName = nil; columns = 0
        case "sf:chart-row_names", "sf:chart-column_names":
            inChartNames = false; append("\n")
        case "key:slide":
            if slideStack.last == depth { slideStack.removeLast() }
        default: break
        }
    }

    private func appendCell(_ value: String) {
        if hfTarget != nil { return }
        var target: ((String) -> Void) = { [weak self] s in self?.current.text += s }
        if let top = regionStack.last, case .masterSlide = top.region { target = { [weak self] s in self?.masterSlides.text += s } }
        target(value)
        columnIndex += 1
        if columns > 0 && columnIndex >= columns { target("\n"); columnIndex = 0 } else { target("\t") }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { ok = false }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { ok = false }
}

/// Pages' automatic page numbers in the footer's declared style.
enum AutoPageNumber {
    static func format(_ page: Int, style: String?) -> String {
        switch style {
        case "upper-roman": return roman(page)
        case "lower-roman": return roman(page).lowercased()
        case "upper-alpha": return alpha(page)
        case "lower-alpha": return alpha(page).lowercased()
        default: return String(page)
        }
    }

    static func roman(_ n: Int) -> String {
        guard n > 0, n < 4000 else { return String(n) }
        let table: [(Int, String)] = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"), (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var value = n, out = ""
        for (v, s) in table { while value >= v { out += s; value -= v } }
        return out
    }

    /// A, B, … Z, AA, BB, … (Pages repeats the letter after Z).
    static func alpha(_ n: Int) -> String {
        guard n > 0 else { return String(n) }
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var index = n % 26, repeats = n / 26
        if index == 0 { repeats -= 1; index = 26 }
        return String(repeating: String(letters[index - 1]), count: repeats + 1)
    }
}
