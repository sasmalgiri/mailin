//
//  DocumentTextExtractors.swift
//  ArchiveCore
//
//  Owner directive 2026-11-06 (TYPE-01 … TYPE-04): every document type a
//  customer attaches is read for search, not merely kept. One facade,
//  `DocumentTextExtractor`, dispatches by kind:
//
//    docx xlsx pptx      Office Open XML            → OfficeTextExtractor (FIND-01)
//    odt  ods  odp       OpenDocument (zip + XML)   → ODFTextExtractor
//    pages numbers key   iWork: IWA (snappy + protobuf) and iWork '09 XML
//                                                   → IWorkTextExtractor
//    doc  xls  ppt       Office 97–2003 binary (OLE2 compound file)
//                                                   → LegacyOfficeTextExtractor
//    zip                 one level of files inside  → ZIPContainerTextExtractor
//
//  Every reader labels where text came from ("[Sheet: Budget]", "[Slide 3]",
//  "[ZIP: report.docx]"), lists what it could not read, and throws
//  `.encrypted` for password-protected files so the coverage state says
//  "locked" instead of "no match". Readers are bounded by
//  `ExtractionLimits.effective.partBytes` per part and never execute anything.
//

import Foundation

enum DocumentKind: String, Sendable, CaseIterable {
    case docx, xlsx, pptx
    case odt, ods, odp
    case pages, numbers, key
    case doc, xls, ppt
    /// §13.8 step 4: Excel Binary Workbook, Visio drawing, Project XML.
    case xlsb, vsdx, projectXML
    /// Archives (audit 2026-11-06 A04): the files inside are read, nested
    /// archives up to `ContainerTextExtractor.maxDepth` levels, every child
    /// that was not read listed by name.
    case zip, tar, gzip
    /// Directive 2026-11-07 §6: the other business formats — Publisher,
    /// OneNote section (.one) and notebook package (.onepkg, a cabinet),
    /// binary Visio (.vsd/.vss/.vst, Visio 5–2010), Project binary (.mpp/.mpt),
    /// Access databases (.mdb/.accdb, Jet 3/4 and ACE).
    case pub
    case one, onepkg
    case vsd
    case mpp
    case mdb

    var isContainer: Bool { self == .zip || self == .tar || self == .gzip }

    static func detect(mimeType: String, filename: String) -> DocumentKind? {
        if let office = OfficeTextExtractor.Kind.detect(mimeType: mimeType, filename: filename) {
            switch office { case .docx: return .docx; case .xlsx: return .xlsx; case .pptx: return .pptx }
        }
        let mime = mimeType.lowercased()
        let ext = (filename as NSString).pathExtension.lowercased()
        if ext == "xlsb" || mime.contains("ms-excel.sheet.binary") { return .xlsb }
        if ["vsdx", "vsdm", "vstx", "vstm"].contains(ext) || mime.contains("ms-visio.drawing") || mime.contains("ms-visio.template") { return .vsdx }
        switch ext {
        case "odt", "ott": return .odt
        case "ods", "ots": return .ods
        case "odp", "otp": return .odp
        case "pages": return .pages
        case "numbers": return .numbers
        case "key", "keynote": return .key
        case "doc", "dot": return .doc
        case "xls", "xlt": return .xls
        case "ppt", "pps", "pot": return .ppt
        case "zip": return .zip
        case "tar": return .tar
        case "tgz", "gz", "gzip": return .gzip
        case "pub": return .pub
        case "one": return .one
        case "onepkg": return .onepkg
        case "vsd", "vss", "vst": return .vsd
        case "mpp", "mpt": return .mpp
        case "mdb", "accdb", "mde", "accde", "mda", "accda", "accdt", "accdr": return .mdb
        default: break
        }
        if mime.contains("msaccess") || mime.contains("x-msaccess") || mime.contains("vnd.ms-access") { return .mdb }
        if mime.contains("mspublisher") { return .pub }
        if mime.contains("onenote") { return .one }
        if mime == "application/vnd.visio" || mime == "application/vnd.ms-visio" { return .vsd }
        if mime.contains("ms-project") || mime.contains("x-project") { return .mpp }
        if mime.contains("opendocument.text") { return .odt }
        if mime.contains("opendocument.spreadsheet") { return .ods }
        if mime.contains("opendocument.presentation") { return .odp }
        if mime.contains("iwork-pages") || mime.contains("apple.pages") { return .pages }
        if mime.contains("iwork-numbers") || mime.contains("apple.numbers") { return .numbers }
        if mime.contains("iwork-keynote") || mime.contains("apple.keynote") { return .key }
        if mime == "application/msword" { return .doc }
        if mime.contains("ms-excel") { return .xls }
        if mime.contains("ms-powerpoint") { return .ppt }
        if mime == "application/zip" || mime == "application/x-zip-compressed" { return .zip }
        if mime.contains("x-tar") { return .tar }
        if mime.contains("gzip") { return .gzip }
        return nil
    }

    /// The reader's name, recorded per attachment in the coverage store.
    var extractorName: String {
        switch self {
        case .docx, .xlsx, .pptx: return "office"
        case .odt, .ods, .odp: return "odf"
        case .pages, .numbers, .key: return "iwork"
        case .doc, .xls, .ppt: return "ole"
        case .xlsb: return "office"
        case .vsdx: return "visio"
        case .projectXML: return "project"
        case .zip, .tar, .gzip: return "archive"
        case .pub: return "publisher"
        case .one, .onepkg: return "onenote"
        case .vsd: return "visio"
        case .mpp: return "project"
        case .mdb: return "access"
        }
    }
}

enum DocumentTextExtractor {
    /// - Parameter logicalName: R03 — the file's own name (attachment
    ///   filename or archive member path), independent of the temporary
    ///   storage URL, so a gzip payload is named `report.txt` and not after
    ///   a UUID. Falls back to the URL's name.
    /// - Parameter password: §13.8 step 5 — opens an encrypted Office package
    ///   (Standard or Agile) or the encrypted members of a ZIP; used for this
    ///   call only. Without it those are reported locked.
    static func extract(fileURL: URL, kind: DocumentKind, logicalName: String? = nil, password: String? = nil) throws -> OfficeTextExtractor.Result {
        if let password, [.docx, .xlsx, .pptx, .xlsb, .vsdx].contains(kind), OfficeCryptoUnlocker.isEncryptedPackage((try? Data(contentsOf: fileURL)) ?? Data()) {
            let plain: Data
            do { plain = try OfficeCryptoUnlocker.decrypt(data: try Data(contentsOf: fileURL), password: password) }
            catch ProtectedContentError.wrongPassword { throw OfficeTextExtractor.ExtractError.wrongPassword }
            catch { throw OfficeTextExtractor.ExtractError.notAPackage(error.localizedDescription) }
            let scratch = try scratchDirectory("unlocked")
            defer { try? FileManager.default.removeItem(at: scratch) }
            let temp = scratch.appendingPathComponent(UUID().uuidString + "." + kind.rawValue)
            try plain.write(to: temp)
            return try extract(fileURL: temp, kind: kind, logicalName: logicalName ?? fileURL.lastPathComponent, password: nil)
        }
        switch kind {
        case .docx: return try OfficeTextExtractor.extract(fileURL: fileURL, kind: .docx)
        case .xlsx: return try OfficeTextExtractor.extract(fileURL: fileURL, kind: .xlsx)
        case .pptx: return try OfficeTextExtractor.extract(fileURL: fileURL, kind: .pptx)
        case .odt, .ods, .odp: return try ODFTextExtractor.extract(fileURL: fileURL, kind: kind)
        case .pages, .numbers, .key: return try IWorkTextExtractor.extract(fileURL: fileURL, kind: kind)
        case .doc, .xls, .ppt: return try LegacyOfficeTextExtractor.extract(fileURL: fileURL, kind: kind)
        case .xlsb: return try XLSBReader.extract(fileURL: fileURL)
        case .vsdx: return try VisioTextExtractor.extract(fileURL: fileURL)
        case .projectXML: return try ProjectXMLTextExtractor.extract(fileURL: fileURL)
        case .zip, .tar, .gzip: return try ContainerTextExtractor.extract(fileURL: fileURL, kind: kind, logicalName: logicalName ?? fileURL.lastPathComponent, password: password)
        case .pub: return try PublisherTextExtractor.extract(fileURL: fileURL)
        case .one: return try OneNoteTextExtractor.extract(fileURL: fileURL, logicalName: logicalName)
        case .onepkg: return try OneNoteTextExtractor.extractPackage(fileURL: fileURL, logicalName: logicalName)
        case .vsd: return try VisioBinaryTextExtractor.extract(fileURL: fileURL)
        case .mpp: return try ProjectBinaryTextExtractor.extract(fileURL: fileURL)
        case .mdb: return try AccessTextExtractor.extract(fileURL: fileURL)
        }
    }

    /// R03: what the bytes say a file is, when the name says nothing
    /// (ZIP / tar / gzip signatures, the Project XML namespace; an OLE
    /// compound file needs its name to tell .doc from .xls from .ppt and is
    /// reported as nil).
    static func sniff(fileURL: URL) -> DocumentKind? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4096), head.count >= 4 else { return nil }
        return sniff(head: head)
    }

    /// The same decision from the first bytes already in memory.
    static func sniff(head: Data) -> DocumentKind? {
        let bytes = [UInt8](head)
        guard bytes.count >= 4 else { return nil }
        if bytes[0] == 0x3C || (bytes[0] == 0xEF && bytes[1] == 0xBB) || (bytes[0] == 0xFF && bytes[1] == 0xFE) {
            if ProjectXMLTextExtractor.looksLikeProjectXML(head) { return .projectXML }
        }
        if bytes[0] == 0x1F, bytes[1] == 0x8B { return .gzip }
        if bytes[0] == 0x50, bytes[1] == 0x4B, bytes[2] == 0x03 || bytes[2] == 0x05, bytes[3] == 0x04 || bytes[3] == 0x06 { return .zip }
        if bytes.count >= 262, Array(bytes[257..<262]) == [0x75, 0x73, 0x74, 0x61, 0x72] { return .tar }
        // Directive 2026-11-07 §6: Publisher (and the other OLE2 business formats) by the root CLSID;
        // a OneNote section by its file-type GUID; a notebook package by the cabinet signature.
        if Array(bytes[0..<8]) == OfficeTextExtractor.oleSignature { return OLE2CompoundSniff.kind(head: head) }
        if OneNoteTextExtractor.hasSectionSignature(head) { return .one }
        if CabinetReader.hasSignature(head) { return .onepkg }
        if AccessTextExtractor.hasSignature(head) { return .mdb }
        return nil
    }

    /// Shared: extract one ZIP member into scratch and hand its bytes over, bounded.
    static func memberData(_ member: ZIPArchiveReader.Member, from url: URL, scratch: URL) throws -> Data {
        let destination = scratch.appendingPathComponent(UUID().uuidString)
        try ZIPArchiveReader.extract(member, from: url, to: destination)
        defer { try? FileManager.default.removeItem(at: destination) }
        return try Data(contentsOf: destination)
    }

    static func scratchDirectory(_ prefix: String) throws -> URL {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        return scratch
    }
}

// MARK: - OpenDocument

enum ODFTextExtractor {
    static func extract(fileURL: URL, kind: DocumentKind) throws -> OfficeTextExtractor.Result {
        let members: [ZIPArchiveReader.Member]
        do { members = try ZIPArchiveReader.members(of: fileURL) } catch {
            throw OfficeTextExtractor.ExtractError.notAPackage(String(describing: error))
        }
        let byName = Dictionary(members.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let scratch = try DocumentTextExtractor.scratchDirectory("odf")
        defer { try? FileManager.default.removeItem(at: scratch) }
        if let manifest = byName["META-INF/manifest.xml"], manifest.uncompressedSize <= ExtractionLimits.effective.partBytes,
           let text = String(data: try DocumentTextExtractor.memberData(manifest, from: fileURL, scratch: scratch), encoding: .utf8),
           text.contains("encryption-data") {
            throw OfficeTextExtractor.ExtractError.encrypted
        }
        var skipped: [String] = []
        var notText: [String] = []
        for m in members where !m.isDirectory && (m.name.hasPrefix("Pictures/") || m.name.hasPrefix("media/") || m.name.hasPrefix("Thumbnails/")) {
            notText.append(m.name)
        }
        func parse(_ name: String, collector: ODFTextCollector) throws -> Bool {
            guard let member = byName[name] else { return false }
            guard member.uncompressedSize <= ExtractionLimits.effective.partBytes else {
                skipped.append("\(name) (\(member.uncompressedSize) bytes, over the \(ExtractionLimits.effective.partBytes)-byte guard)")
                return false
            }
            let data = try DocumentTextExtractor.memberData(member, from: fileURL, scratch: scratch)
            guard collector.parse(data) else { skipped.append("\(name) (malformed XML)"); return false }
            return true
        }
        var text = ""
        var components: [String] = []
        let content = ODFTextCollector(kind: kind)
        if try parse("content.xml", collector: content) {
            for section in content.sections where !section.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                components.append(section.label)
                text += "[\(section.label)]\n" + section.text + "\n"
            }
        }
        if kind == .odt {
            let styles = ODFTextCollector(kind: kind, headersAndFootersOnly: true)
            if try parse("styles.xml", collector: styles) {
                for section in styles.sections where !section.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    components.append(section.label)
                    text += "[\(section.label)]\n" + section.text + "\n"
                }
            }
        }
        if components.isEmpty && skipped.isEmpty { throw OfficeTextExtractor.ExtractError.noTextParts }
        return OfficeTextExtractor.Result(text: text, components: components, skipped: skipped, notText: notText.sorted())
    }
}

/// Text of an OpenDocument content/styles part, split into labelled sections
/// (document, sheets, slides and their notes, headers and footers).
/// `maxRepeatedSpaces` bounds one `text:s` run (audit A05).
final class ODFTextCollector: NSObject, XMLParserDelegate {
    static let maxRepeatedSpaces = 4_096
    struct Section { var label: String; var text: String }
    private(set) var sections: [Section] = []
    private let kind: DocumentKind
    private let headersAndFootersOnly: Bool
    private var current = Section(label: "Document", text: "")
    private var depthInHeaderFooter = 0
    private var slideIndex = 0
    private var inNotes = false
    private var savedBeforeNotes: Section?
    /// A slide's notes, kept until the slide itself is flushed so they follow it.
    private var pendingAfterCurrent: [Section] = []
    private var cellDepth = 0
    private var ok = true

    init(kind: DocumentKind, headersAndFootersOnly: Bool = false) {
        self.kind = kind
        self.headersAndFootersOnly = headersAndFootersOnly
        if headersAndFootersOnly { current = Section(label: "", text: "") }
    }

    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldResolveExternalEntities = false
        let parsed = parser.parse()
        flush()
        return parsed && ok
    }

    private func flush() {
        if !current.label.isEmpty { sections.append(current) }
        sections.append(contentsOf: pendingAfterCurrent)
        pendingAfterCurrent = []
        current = Section(label: "", text: "")
    }

    private var capturing: Bool { !headersAndFootersOnly || depthInHeaderFooter > 0 }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        switch name {
        case "style:header", "style:footer":
            depthInHeaderFooter += 1
            if headersAndFootersOnly { flush(); current = Section(label: name == "style:header" ? "Header" : "Footer", text: "") }
        case "table:table" where kind == .ods:
            flush(); current = Section(label: "Sheet: " + (attributes["table:name"] ?? "Sheet"), text: "")
        case "draw:page" where kind == .odp:
            slideIndex += 1
            flush(); current = Section(label: "Slide \(slideIndex)", text: "")
        case "presentation:notes" where kind == .odp:
            inNotes = true
            savedBeforeNotes = current
            current = Section(label: "Notes \(slideIndex)", text: "")
        case "table:table-cell" where capturing:
            cellDepth += 1
            // Numbers and dates carry their value as an attribute; text cells have text:p inside.
            if let value = attributes["office:value"], attributes["office:value-type"] != "string" { current.text += value }
        case "text:s" where capturing:
            // Audit A05: the count is untrusted input — never negative, never
            // an allocation the document's own size cannot justify.
            current.text += String(repeating: " ", count: min(max(Int(attributes["text:c"] ?? "1") ?? 1, 0), Self.maxRepeatedSpaces))
        case "text:tab" where capturing: current.text += "\t"
        case "text:line-break" where capturing: current.text += "\n"
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard capturing else { return }
        current.text += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "text:p" where capturing, "text:h" where capturing:
            // Inside a cell, paragraphs stay on the cell's line; the row ends the line.
            current.text += cellDepth > 0 ? " " : "\n"
        case "table:table-cell" where capturing:
            cellDepth = max(0, cellDepth - 1)
            if current.text.hasSuffix(" ") { current.text.removeLast() }
            current.text += "\t"
        case "table:table-row" where capturing: current.text += "\n"
        case "style:header", "style:footer":
            depthInHeaderFooter = max(0, depthInHeaderFooter - 1)
            if headersAndFootersOnly { flush() }
        case "presentation:notes" where inNotes:
            inNotes = false
            pendingAfterCurrent.append(current)
            current = savedBeforeNotes ?? Section(label: "Slide \(slideIndex)", text: "")
            savedBeforeNotes = nil
        default: break
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { ok = false }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { ok = false }
}

// MARK: - iWork

enum IWorkTextExtractor {
    /// IWA members that carry user text. Everything else in Index/ is
    /// stylesheets, view state, metadata, calculation tokens or template
    /// placeholders ("Body Level One") and is not read.
    static func carriesText(_ name: String) -> Bool {
        guard name.hasPrefix("Index/"), name.hasSuffix(".iwa") else { return false }
        let base = String(name.dropFirst("Index/".count))
        if base.hasPrefix("Document") { return true }
        if base.hasPrefix("Slide-") { return true }
        if base.hasPrefix("Tables/DataList") { return true }
        return false
    }

    /// TSWP.StorageArchive (text storages) and TST.TableDataList (cell strings).
    static let storageArchiveType = 2001
    static let tableDataListType = 6005
    static let sheetArchiveType = 2

    static func extract(fileURL: URL, kind: DocumentKind) throws -> OfficeTextExtractor.Result {
        let members: [ZIPArchiveReader.Member]
        do { members = try ZIPArchiveReader.members(of: fileURL) } catch {
            throw OfficeTextExtractor.ExtractError.notAPackage(String(describing: error))
        }
        let scratch = try DocumentTextExtractor.scratchDirectory("iwork")
        defer { try? FileManager.default.removeItem(at: scratch) }
        var skipped: [String] = []
        var notText: [String] = []
        for m in members where !m.isDirectory && (m.name.hasPrefix("Data/") || m.name.hasPrefix("QuickLook/") || m.name.hasSuffix(".pdf") || m.name.hasSuffix(".png") || m.name.hasSuffix(".jpg") || m.name.hasSuffix(".jpeg")) {
            notText.append(m.name)
        }

        // iWork '09: one XML document (index.xml / index.apxl).
        if let xml = members.first(where: { ["index.xml", "index.apxl"].contains($0.name) }) {
            guard xml.uncompressedSize <= ExtractionLimits.effective.partBytes else {
                throw OfficeTextExtractor.ExtractError.notAPackage("\(xml.name) is \(xml.uncompressedSize) bytes, over the \(ExtractionLimits.effective.partBytes)-byte guard")
            }
            let data = try DocumentTextExtractor.memberData(xml, from: fileURL, scratch: scratch)
            let collector = IWork09TextCollector()
            guard collector.parse(data) else { throw OfficeTextExtractor.ExtractError.notAPackage("\(xml.name) is not well-formed XML") }
            let label = kind == .numbers ? "Sheets and tables" : (kind == .key ? "Slides" : "Document")
            let text = collector.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { throw OfficeTextExtractor.ExtractError.noTextParts }
            return OfficeTextExtractor.Result(text: "[\(label)]\n" + text + "\n", components: [label], skipped: [], notText: notText.sorted())
        }
        if members.contains(where: { $0.name == "index.xml.gz" || $0.name == "index.apxl.gz" }) {
            throw OfficeTextExtractor.ExtractError.notAPackage("compressed iWork '09 index (index.xml.gz) is not read")
        }

        // Modern iWork: IWA objects.
        let textMembers = members.filter { carriesText($0.name) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard !textMembers.isEmpty else {
            throw OfficeTextExtractor.ExtractError.notAPackage("no Index/*.iwa members — not an iWork document")
        }
        var text = ""
        var components: [String] = []
        var sheetNames: [String] = []
        var slideIndex = 0
        var cellStrings: [String] = []
        for member in textMembers {
            guard member.uncompressedSize <= ExtractionLimits.effective.partBytes else {
                skipped.append("\(member.name) (\(member.uncompressedSize) bytes, over the \(ExtractionLimits.effective.partBytes)-byte guard)")
                continue
            }
            let data = try DocumentTextExtractor.memberData(member, from: fileURL, scratch: scratch)
            let objects: [IWAFile.Object]
            do { objects = try IWAFile.objects(in: data, limit: Int(ExtractionLimits.effective.partBytes)) } catch {
                skipped.append("\(member.name) (\(error))"); continue
            }
            let base = String(member.name.dropFirst("Index/".count))
            var storages: [String] = []
            for object in objects {
                switch object.type {
                case storageArchiveType:
                    for s in ProtobufWalker.strings(field: 3, in: object.payload) where !s.isEmpty { storages.append(s) }
                case tableDataListType:
                    for entry in ProtobufWalker.messages(field: 3, in: object.payload) {
                        for s in ProtobufWalker.strings(field: 3, in: entry) where !s.isEmpty { cellStrings.append(s) }
                    }
                case sheetArchiveType where kind == .numbers:
                    sheetNames.append(contentsOf: ProtobufWalker.strings(field: 1, in: object.payload))
                default: break
                }
            }
            if base.hasPrefix("Slide-") {
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
        if !cellStrings.isEmpty {
            let label = sheetNames.isEmpty ? "Table cells" : "Table cells (sheets: \(sheetNames.joined(separator: ", ")))"
            components.append(label)
            text += "[\(label)]\n" + cellStrings.joined(separator: "\n") + "\n"
        }
        if components.isEmpty && skipped.isEmpty { throw OfficeTextExtractor.ExtractError.noTextParts }
        return OfficeTextExtractor.Result(text: text, components: components, skipped: skipped, notText: notText.sorted())
    }
}

/// iWork '09 XML: paragraphs (`sf:p`) and Numbers cell text (`sf:ct` `sfa:s`).
final class IWork09TextCollector: NSObject, XMLParserDelegate {
    private(set) var text = ""
    private var paragraphDepth = 0
    private var ok = true

    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldResolveExternalEntities = false
        return parser.parse() && ok
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        switch name {
        case "sf:p": paragraphDepth += 1
        case "sf:ct":
            if let s = attributes["sfa:s"], !s.isEmpty { text += s + "\t" }
        case "sf:br" where paragraphDepth > 0, "sf:lnbr" where paragraphDepth > 0: text += "\n"
        case "sf:tab" where paragraphDepth > 0: text += "\t"
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard paragraphDepth > 0 else { return }
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "sf:p" { paragraphDepth = max(0, paragraphDepth - 1); text += "\n" }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { ok = false }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { ok = false }
}

/// An IWA file: chunks of `0x00 + 3-byte little-endian length + raw snappy
/// block`, concatenated into a stream of `varint length + TSP.ArchiveInfo`
/// followed by the payloads its MessageInfos describe.
enum IWAFile {
    struct Object { let type: Int; let payload: Data }

    enum ReadError: Error, CustomStringConvertible {
        case badChunk(Int), badSnappy(String), tooLarge
        var description: String {
            switch self {
            case .badChunk(let o): return "IWA chunk header at \(o) is not snappy"
            case .badSnappy(let why): return "snappy block: \(why)"
            case .tooLarge: return "decompressed size over the guard"
            }
        }
    }

    static func objects(in data: Data, limit: Int) throws -> [Object] {
        let raw = try decompress(data, limit: limit)
        var objects: [Object] = []
        var pos = 0
        while pos < raw.count {
            guard let (length, next) = ProtobufWalker.varint(raw, at: pos), next + length <= raw.count else { break }
            let info = raw.subdata(in: next..<(next + length))
            pos = next + length
            // ArchiveInfo.message_infos (field 2) → MessageInfo.type (1), .length (3)
            for message in ProtobufWalker.messages(field: 2, in: info) {
                let type = Int(ProtobufWalker.varints(field: 1, in: message).first ?? 0)
                let size = Int(ProtobufWalker.varints(field: 3, in: message).first ?? 0)
                guard size >= 0, pos + size <= raw.count else { return objects }
                objects.append(Object(type: type, payload: raw.subdata(in: pos..<(pos + size))))
                pos += size
            }
        }
        return objects
    }

    static func decompress(_ data: Data, limit: Int) throws -> Data {
        var out = Data()
        var pos = 0
        let bytes = [UInt8](data)
        while pos + 4 <= bytes.count {
            guard bytes[pos] == 0 else { throw ReadError.badChunk(pos) }
            let length = Int(bytes[pos + 1]) | (Int(bytes[pos + 2]) << 8) | (Int(bytes[pos + 3]) << 16)
            pos += 4
            guard pos + length <= bytes.count else { throw ReadError.badSnappy("chunk runs past the end") }
            out.append(try SnappyBlock.decompress(bytes[pos..<(pos + length)], limit: limit - out.count))
            guard out.count <= limit else { throw ReadError.tooLarge }
            pos += length
        }
        return out
    }
}

/// A raw snappy block (no stream framing): literals and back-references.
enum SnappyBlock {
    static func decompress(_ input: ArraySlice<UInt8>, limit: Int) throws -> Data {
        var pos = input.startIndex
        func byte() throws -> UInt8 {
            guard pos < input.endIndex else { throw IWAFile.ReadError.badSnappy("truncated") }
            defer { pos += 1 }
            return input[pos]
        }
        var expected = 0, shift = 0
        while true {
            let b = try byte()
            expected |= Int(b & 0x7F) << shift
            shift += 7
            if b & 0x80 == 0 { break }
            if shift > 35 { throw IWAFile.ReadError.badSnappy("bad length") }
        }
        guard expected <= limit else { throw IWAFile.ReadError.tooLarge }
        var out = [UInt8]()
        out.reserveCapacity(expected)
        while pos < input.endIndex {
            let tag = try byte()
            switch tag & 3 {
            case 0:
                var n = Int(tag >> 2)
                if n >= 60 {
                    let extra = n - 59
                    n = 0
                    for i in 0..<extra { n |= Int(try byte()) << (8 * i) }
                }
                n += 1
                guard pos + n <= input.endIndex else { throw IWAFile.ReadError.badSnappy("literal runs past the end") }
                out.append(contentsOf: input[pos..<(pos + n)])
                pos += n
            default:
                let n: Int, offset: Int
                switch tag & 3 {
                case 1:
                    n = Int((tag >> 2) & 7) + 4
                    offset = (Int(tag >> 5) << 8) | Int(try byte())
                case 2:
                    n = Int(tag >> 2) + 1
                    let lo = Int(try byte()), hi = Int(try byte())
                    offset = lo | (hi << 8)
                default:
                    n = Int(tag >> 2) + 1
                    var o = 0
                    for i in 0..<4 { o |= Int(try byte()) << (8 * i) }
                    offset = o
                }
                guard offset > 0, offset <= out.count else { throw IWAFile.ReadError.badSnappy("copy before start") }
                let start = out.count - offset
                for i in 0..<n { out.append(out[start + i]) }
            }
            guard out.count <= expected else { throw IWAFile.ReadError.badSnappy("output over declared length") }
        }
        return Data(out)
    }
}

/// Just enough protobuf wire-format reading to pull strings and
/// sub-messages out of iWork objects without their schemas.
enum ProtobufWalker {
    static func varint(_ data: Data, at start: Int) -> (Int, Int)? {
        var value = 0, shift = 0, pos = start
        while pos < data.count {
            let b = data[data.startIndex + pos]
            value |= Int(b & 0x7F) << shift
            pos += 1
            if b & 0x80 == 0 { return (value, pos) }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }

    /// (field number, wire type, value range or varint value) for every field, in order.
    static func fields(in data: Data) -> [(field: Int, wire: Int, value: Int, bytes: Range<Int>?)] {
        var out: [(Int, Int, Int, Range<Int>?)] = []
        var pos = 0
        while pos < data.count {
            guard let (key, next) = varint(data, at: pos) else { return out }
            let field = key >> 3, wire = key & 7
            pos = next
            switch wire {
            case 0:
                guard let (v, n) = varint(data, at: pos) else { return out }
                out.append((field, wire, v, nil)); pos = n
            case 1: pos += 8; out.append((field, wire, 0, nil))
            case 2:
                guard let (length, n) = varint(data, at: pos), n + length <= data.count else { return out }
                out.append((field, wire, 0, n..<(n + length))); pos = n + length
            case 5: pos += 4; out.append((field, wire, 0, nil))
            default: return out
            }
        }
        return out
    }

    static func strings(field number: Int, in data: Data) -> [String] {
        fields(in: data).compactMap { f in
            guard f.field == number, let r = f.bytes else { return nil }
            return String(data: data.subdata(in: (data.startIndex + r.lowerBound)..<(data.startIndex + r.upperBound)), encoding: .utf8)
        }
    }

    static func messages(field number: Int, in data: Data) -> [Data] {
        fields(in: data).compactMap { f in
            guard f.field == number, let r = f.bytes else { return nil }
            return data.subdata(in: (data.startIndex + r.lowerBound)..<(data.startIndex + r.upperBound))
        }
    }

    static func varints(field number: Int, in data: Data) -> [Int] {
        fields(in: data).compactMap { $0.field == number && $0.wire == 0 ? $0.value : nil }
    }
}

// MARK: - Office 97–2003 (OLE2)

enum LegacyOfficeTextExtractor {
    static func extract(fileURL: URL, kind: DocumentKind) throws -> OfficeTextExtractor.Result {
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        guard data.count >= 8, Array(data.prefix(8)) == OfficeTextExtractor.oleSignature else {
            throw OfficeTextExtractor.ExtractError.notAPackage("not an OLE2 compound file")
        }
        let ole: OLE2Reader
        do { ole = try OLE2Reader(data: data) } catch { throw OfficeTextExtractor.ExtractError.notAPackage(String(describing: error)) }
        switch kind {
        case .doc: return try word(ole)
        case .xls: return try excel(ole)
        case .ppt: return try powerPoint(ole)
        default: throw OfficeTextExtractor.ExtractError.notAPackage("not a legacy Office kind")
        }
    }

    // MARK: Word (.doc) — the piece table in the table stream maps CPs to text runs.

    private static func word(_ ole: OLE2Reader) throws -> OfficeTextExtractor.Result {
        guard let fib = ole.streamData(named: "WordDocument"), fib.count >= 0x20 else {
            throw OfficeTextExtractor.ExtractError.notAPackage("no WordDocument stream")
        }
        let flags = le16(fib, 0x0A)
        if flags & 0x0100 != 0 { throw OfficeTextExtractor.ExtractError.encrypted }
        var text = ""
        if fib.count >= 0x01AA {
            let tableName = (flags & 0x0200) != 0 ? "1Table" : "0Table"
            let fcClx = Int(le32(fib, 0x01A2)), lcbClx = Int(le32(fib, 0x01A6))
            if lcbClx > 0, let table = ole.streamData(named: tableName), fcClx + lcbClx <= table.count {
                text = pieceTableText(clx: table.subdata(in: fcClx..<(fcClx + lcbClx)), document: fib)
            }
        }
        if text.isEmpty {
            // Word 6/95 or a document without a piece table: the text run between fcMin and fcMac.
            let fcMin = Int(le32(fib, 0x18)), fcMac = Int(le32(fib, 0x1C))
            if fcMin >= 0, fcMac > fcMin, fcMac <= fib.count {
                text = String(data: fib.subdata(in: fcMin..<fcMac), encoding: .windowsCP1252) ?? ""
            }
        }
        let cleaned = cleanWordText(text)
        if cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw OfficeTextExtractor.ExtractError.noTextParts }
        return OfficeTextExtractor.Result(text: "[Document]\n" + cleaned + "\n", components: ["Document"], skipped: [], notText: [])
    }

    private static func pieceTableText(clx: Data, document: Data) -> String {
        var pos = 0
        while pos < clx.count {
            let tag = clx[clx.startIndex + pos]
            if tag == 0x01 {   // Prc: skip
                guard pos + 3 <= clx.count else { return "" }
                pos += 3 + Int(le16(clx, pos + 1))
            } else if tag == 0x02 {   // Pcdt
                guard pos + 5 <= clx.count else { return "" }
                let lcb = Int(le32(clx, pos + 1))
                let plc = pos + 5
                guard lcb >= 4, plc + lcb <= clx.count else { return "" }
                let n = (lcb - 4) / 12
                var out = ""
                for i in 0..<n {
                    let cpStart = Int(le32(clx, plc + i * 4)), cpEnd = Int(le32(clx, plc + (i + 1) * 4))
                    let pcd = plc + (n + 1) * 4 + i * 8
                    let fc = le32(clx, pcd + 2)
                    let count = cpEnd - cpStart
                    guard count > 0 else { continue }
                    if fc & 0x4000_0000 != 0 {
                        let start = Int(fc & 0x3FFF_FFFF) / 2
                        guard start >= 0, start + count <= document.count else { continue }
                        out += String(data: document.subdata(in: start..<(start + count)), encoding: .windowsCP1252) ?? ""
                    } else {
                        let start = Int(fc)
                        guard start >= 0, start + count * 2 <= document.count else { continue }
                        out += String(data: document.subdata(in: start..<(start + count * 2)), encoding: .utf16LittleEndian) ?? ""
                    }
                }
                return out
            } else {
                return ""
            }
        }
        return ""
    }

    /// Word's control characters → text: paragraph (CR) and page/line breaks
    /// to newlines, cell marks to tabs, field and object markers dropped.
    static func cleanWordText(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        for scalar in raw.unicodeScalars {
            switch scalar.value {
            case 0x0D, 0x0B, 0x0C, 0x0E: out.unicodeScalars.append("\n")
            case 0x07: out.unicodeScalars.append("\t")
            case 0x01, 0x02, 0x05, 0x08, 0x13, 0x14, 0x15: break
            case 0x00...0x06, 0x0F...0x1F: break
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    // MARK: Excel (.xls) — BIFF5/BIFF8: sheets, shared strings, every cell with its address, formula results, comments.

    /// Audit 2026-11-06 A03: a workbook's values live in cell records, not
    /// only in the shared-string table. Each sheet is a labelled section and
    /// each cell a line "A1<tab>value": LABELSST / LABEL / RSTRING (text),
    /// NUMBER / RK / MULRK (numbers), FORMULA with its cached result (a
    /// number; text through the STRING record that follows; TRUE/FALSE;
    /// #ERROR), BOOLERR, and TXO note text ("Comment: …"). Sheets are mapped
    /// by the stream offsets BOUNDSHEET declares; hidden sheets are labelled.
    /// Numbers appear as stored — a date is its serial number, number
    /// formats are not applied — and the text says so.
    private static func excel(_ ole: OLE2Reader) throws -> OfficeTextExtractor.Result {
        guard let stream = ole.streamData(named: "Workbook") ?? ole.streamData(named: "Book") else {
            throw OfficeTextExtractor.ExtractError.notAPackage("no Workbook stream")
        }
        struct Sheet { var name: String; var offset: Int; var hidden: Bool; var cells: [String] = []; var notes: [String] = [] }
        var sheets: [Sheet] = []
        var sst: [String] = []
        var sstSegments: [Data] = []
        var collectingSST = false
        var biff8 = true
        var sawBOF = false
        var current: Int? = nil                 // the sheet whose substream we are in
        var orphans: [String] = []              // cells met outside any declared sheet
        var formulaWaitingForString: (row: Int, col: Int)? = nil
        var noteWaitingForText = false
        var noteCharacters = 0
        var skipped: [String] = []
        var numbersSeen = false

        func reference(_ row: Int, _ col: Int) -> String {
            var c = col, letters = ""
            repeat { letters = String(UnicodeScalar(UInt8(65 + c % 26))) + letters; c = c / 26 - 1 } while c >= 0
            return letters + String(row + 1)
        }
        func put(_ row: Int, _ col: Int, _ value: String) {
            guard !value.isEmpty else { return }
            let line = reference(row, col) + "\t" + value
            if let current { sheets[current].cells.append(line) } else { orphans.append(line) }
        }
        func number(_ d: Double) -> String {
            numbersSeen = true
            if d.isFinite, d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
            return String(d)
        }
        func rk(_ v: UInt32) -> Double {
            let value: Double = v & 0x02 != 0 ? Double(Int32(bitPattern: v) >> 2) : Double(bitPattern: UInt64(v & ~UInt32(3)) << 32)
            return v & 0x01 != 0 ? value / 100 : value
        }
        func le64(_ d: Data, _ o: Int) -> UInt64 { UInt64(le32(d, o)) | (UInt64(le32(d, o + 4)) << 32) }
        /// A BIFF string: cch, then (BIFF8) an option byte and 8- or 16-bit characters, (BIFF5) bytes.
        func string(_ record: Data, cchAt: Int, cchBytes: Int) -> String {
            guard record.count >= cchAt + cchBytes else { return "" }
            let cch = cchBytes == 2 ? Int(le16(record, cchAt)) : Int(record[record.startIndex + cchAt])
            var start = cchAt + cchBytes
            var wide = false
            if biff8 {
                guard record.count > start else { return "" }
                let flags = record[record.startIndex + start]; start += 1
                wide = flags & 0x01 != 0
                if flags & 0x08 != 0 { start += 2 }      // rich-text run count
                if flags & 0x04 != 0 { start += 4 }      // extended-string byte count
            }
            let end = min(record.count, start + (wide ? cch * 2 : cch))
            guard end > start else { return "" }
            let bytes = record.subdata(in: start..<end)
            return (wide ? String(data: bytes, encoding: .utf16LittleEndian) : String(data: bytes, encoding: .windowsCP1252)) ?? ""
        }

        var pos = 0
        while pos + 4 <= stream.count {
            let id = le16(stream, pos), length = Int(le16(stream, pos + 2))
            let body = pos + 4
            guard body + length <= stream.count else { break }
            let record = stream.subdata(in: body..<(body + length))
            if id != 0x003C { collectingSST = false }
            switch id {
            case 0x0809:   // BOF: the first tells the version; a sheet's own BOF is found by its declared offset
                if !sawBOF {
                    sawBOF = true
                    if record.count >= 2 { let version = le16(record, 0); biff8 = version == 0 || version >= 0x0600 }
                }
                if let index = sheets.firstIndex(where: { $0.offset == pos }) { current = index }
            case 0x000A:   // EOF: the substream ends
                current = nil
            case 0x002F: throw OfficeTextExtractor.ExtractError.encrypted   // FILEPASS
            case 0x0085:   // BOUNDSHEET: lbPlyPos (4), options (2; low bits = hidden state), cch (1), [BIFF8 flags (1)], name
                if record.count >= 7 {
                    sheets.append(Sheet(name: string(record, cchAt: 6, cchBytes: 1), offset: Int(le32(record, 0)),
                                        hidden: record[record.startIndex + 4] & 0x03 != 0))
                }
            case 0x00FC:   // SST
                sstSegments = [record]; collectingSST = true
            case 0x003C:   // CONTINUE: of the SST, or the text of a note
                if collectingSST {
                    sstSegments.append(record)
                } else if noteWaitingForText, record.count >= 1 {
                    let wide = record[record.startIndex] & 0x01 != 0
                    let end = min(record.count, 1 + (wide ? noteCharacters * 2 : noteCharacters))
                    let bytes = record.subdata(in: 1..<end)
                    let text = (wide ? String(data: bytes, encoding: .utf16LittleEndian) : String(data: bytes, encoding: .windowsCP1252)) ?? ""
                    let line = "Comment: " + text.replacingOccurrences(of: "\n", with: " ")
                    if let current { sheets[current].notes.append(line) } else { orphans.append(line) }
                    noteWaitingForText = false
                }
            case 0x00FD where record.count >= 10:   // LABELSST
                if sst.isEmpty, !sstSegments.isEmpty { sst = sharedStrings(segments: sstSegments) }
                let index = Int(le32(record, 6))
                if index >= 0, index < sst.count { put(Int(le16(record, 0)), Int(le16(record, 2)), sst[index]) }
            case 0x0204, 0x00D6:   // LABEL, RSTRING
                if record.count >= 8 { put(Int(le16(record, 0)), Int(le16(record, 2)), string(record, cchAt: 6, cchBytes: 2)) }
            case 0x0203 where record.count >= 14:   // NUMBER
                put(Int(le16(record, 0)), Int(le16(record, 2)), number(Double(bitPattern: le64(record, 6))))
            case 0x027E where record.count >= 10:   // RK
                put(Int(le16(record, 0)), Int(le16(record, 2)), number(rk(le32(record, 6))))
            case 0x00BD where record.count >= 12:   // MULRK: row, first col, (xf, rk)*, last col
                let row = Int(le16(record, 0))
                var offset = 4, col = Int(le16(record, 2))
                while offset + 6 <= record.count - 2 {
                    put(row, col, number(rk(le32(record, offset + 2))))
                    offset += 6; col += 1
                }
            case 0x0006 where record.count >= 14:   // FORMULA: the cached result in bytes 6…13
                let row = Int(le16(record, 0)), col = Int(le16(record, 2))
                if le16(record, 12) == 0xFFFF {
                    switch record[record.startIndex + 6] {
                    case 0: formulaWaitingForString = (row, col)     // a STRING record follows
                    case 1: put(row, col, record[record.startIndex + 8] != 0 ? "TRUE" : "FALSE")
                    case 2: put(row, col, "#ERROR")
                    default: break                                     // an empty-string result
                    }
                } else {
                    put(row, col, number(Double(bitPattern: le64(record, 6))))
                }
            case 0x0207:   // STRING: the text result of the formula before it
                if let cell = formulaWaitingForString {
                    put(cell.row, cell.col, string(record, cchAt: 0, cchBytes: 2))
                    formulaWaitingForString = nil
                }
            case 0x0205 where record.count >= 8:   // BOOLERR
                let value = record[record.startIndex + 6], isError = record[record.startIndex + 7] != 0
                put(Int(le16(record, 0)), Int(le16(record, 2)), isError ? "#ERROR" : (value != 0 ? "TRUE" : "FALSE"))
            case 0x01B6 where record.count >= 12:   // TXO: a note's text follows in a CONTINUE record
                noteCharacters = Int(le16(record, 10))
                noteWaitingForText = noteCharacters > 0
            default:
                break
            }
            pos = body + length
        }
        if let cell = formulaWaitingForString { skipped.append("formula result text missing for \(reference(cell.row, cell.col))") }
        if sst.isEmpty, !sstSegments.isEmpty { sst = sharedStrings(segments: sstSegments) }

        var text = ""
        var components: [String] = []
        if !sheets.isEmpty {
            components.append("Workbook")
            text += "[Workbook]\n" + sheets.map { $0.name + ($0.hidden ? " (hidden)" : "") }.joined(separator: "\n") + "\n"
        }
        for sheet in sheets where !sheet.cells.isEmpty || !sheet.notes.isEmpty {
            let label = "Sheet: " + sheet.name + (sheet.hidden ? " (hidden)" : "")
            components.append(label)
            text += "[\(label)]\n" + (sheet.cells + sheet.notes).joined(separator: "\n") + "\n"
        }
        if !orphans.isEmpty { components.append("Cells"); text += "[Cells]\n" + orphans.joined(separator: "\n") + "\n" }
        // Shared strings no cell referenced (an unusual sheet map): kept, so nothing is lost.
        if sheets.allSatisfy({ $0.cells.isEmpty }), orphans.isEmpty, !sst.isEmpty {
            components.append("Shared strings")
            text += "[Shared strings]\n" + sst.joined(separator: "\n") + "\n"
        }
        if numbersSeen { text += "[Numbers are shown as stored: a date is its serial number]\n" }
        if components.isEmpty { throw OfficeTextExtractor.ExtractError.noTextParts }
        return OfficeTextExtractor.Result(text: text, components: components, skipped: skipped, notText: [])
    }

    /// The SST: a count, then strings whose characters may run across a
    /// CONTINUE boundary — where a fresh option byte says whether the rest is
    /// one or two bytes per character.
    private static func sharedStrings(segments: [Data]) -> [String] {
        var segmentIndex = 0
        var offset = 8   // cstTotal + cstUnique
        guard let first = segments.first, first.count >= 8 else { return [] }
        let unique = Int(le32(first, 4))
        var out: [String] = []
        func remaining() -> Int { segmentIndex < segments.count ? segments[segmentIndex].count - offset : 0 }
        func nextSegment() -> Bool { segmentIndex += 1; offset = 0; return segmentIndex < segments.count }
        func readByte() -> UInt8? {
            while remaining() <= 0 { if !nextSegment() { return nil } }
            defer { offset += 1 }
            return segments[segmentIndex][segments[segmentIndex].startIndex + offset]
        }
        func readU16() -> Int? { guard let a = readByte(), let b = readByte() else { return nil }; return Int(a) | (Int(b) << 8) }
        func readU32() -> Int? { guard let a = readU16(), let b = readU16() else { return nil }; return a | (b << 16) }
        func skip(_ n: Int) -> Bool {
            var left = n
            while left > 0 {
                while remaining() <= 0 { if !nextSegment() { return false } }
                let take = min(left, remaining()); offset += take; left -= take
            }
            return true
        }
        for _ in 0..<unique {
            guard let cch = readU16(), let flags = readByte() else { break }
            var wide = flags & 0x01 != 0
            let rich = flags & 0x08 != 0, ext = flags & 0x04 != 0
            var runs = 0, extBytes = 0
            if rich { guard let r = readU16() else { break }; runs = r }
            if ext { guard let e = readU32() else { break }; extBytes = e }
            var chars = ""
            var left = cch
            while left > 0 {
                if remaining() <= 0 {
                    // A continued string restarts with its own option byte.
                    guard nextSegment(), let f = readByte() else { break }
                    wide = f & 0x01 != 0
                }
                let available = remaining()
                let take = min(left, wide ? available / 2 : available)
                guard take > 0 else { if !nextSegment() { break }; continue }
                let seg = segments[segmentIndex]
                let start = seg.startIndex + offset
                let bytes = seg.subdata(in: start..<(start + (wide ? take * 2 : take)))
                chars += (wide ? String(data: bytes, encoding: .utf16LittleEndian) : String(data: bytes, encoding: .windowsCP1252)) ?? ""
                offset += wide ? take * 2 : take
                left -= take
            }
            out.append(chars)
            if !skip(runs * 4 + extBytes) { break }
        }
        return out
    }

    // MARK: PowerPoint (.ppt) — text atoms inside slide containers.

    private static func powerPoint(_ ole: OLE2Reader) throws -> OfficeTextExtractor.Result {
        if ole.streamData(named: "EncryptedSummary") != nil { throw OfficeTextExtractor.ExtractError.encrypted }
        guard let stream = ole.streamData(named: "PowerPoint Document") else {
            throw OfficeTextExtractor.ExtractError.notAPackage("no PowerPoint Document stream")
        }
        var slides: [[String]] = []
        var other: [String] = []
        var slideIndex = -1
        func walk(_ start: Int, _ end: Int, depth: Int) throws {
            var pos = start
            while pos + 8 <= end {
                let verInstance = le16(stream, pos), type = le16(stream, pos + 2), length = Int(le32(stream, pos + 4))
                let body = pos + 8
                guard length >= 0, body + length <= end else { return }
                if type == 0x2F14 { throw OfficeTextExtractor.ExtractError.encrypted }   // CryptSession10Container
                if verInstance & 0x0F == 0x0F, depth < 32 {
                    if type == 0x03EE { slides.append([]); slideIndex = slides.count - 1 }   // SlideContainer
                    try walk(body, body + length, depth: depth + 1)
                } else if type == 0x0FA0 || type == 0x0FA8 {   // TextCharsAtom / TextBytesAtom
                    let bytes = stream.subdata(in: body..<(body + length))
                    let s = (type == 0x0FA0 ? String(data: bytes, encoding: .utf16LittleEndian) : String(data: bytes, encoding: .windowsCP1252)) ?? ""
                    let cleaned = s.replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\u{0B}", with: "\n")
                    if !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if slideIndex >= 0 && slideIndex < slides.count && depth > 0 { slides[slideIndex].append(cleaned) } else { other.append(cleaned) }
                    }
                }
                pos = body + length
            }
        }
        try walk(0, stream.count, depth: 0)
        var text = ""
        var components: [String] = []
        for (i, slide) in slides.enumerated() where !slide.isEmpty {
            let label = "Slide \(i + 1)"
            components.append(label)
            text += "[\(label)]\n" + slide.joined(separator: "\n") + "\n"
        }
        if !other.isEmpty { components.append("Other text"); text += "[Other text]\n" + other.joined(separator: "\n") + "\n" }
        if components.isEmpty { throw OfficeTextExtractor.ExtractError.noTextParts }
        return OfficeTextExtractor.Result(text: text, components: components, skipped: [], notText: [])
    }

    // MARK: Byte helpers

    private static func le16(_ d: Data, _ o: Int) -> UInt16 {
        guard o + 2 <= d.count else { return 0 }
        return UInt16(d[d.startIndex + o]) | (UInt16(d[d.startIndex + o + 1]) << 8)
    }
    private static func le32(_ d: Data, _ o: Int) -> UInt32 {
        guard o + 4 <= d.count else { return 0 }
        return UInt32(d[d.startIndex + o]) | (UInt32(d[d.startIndex + o + 1]) << 8) | (UInt32(d[d.startIndex + o + 2]) << 16) | (UInt32(d[d.startIndex + o + 3]) << 24)
    }
}

// MARK: - Archive attachments: the files inside ZIP / tar / gzip, nested, with what was not read

/// What the app's own reader made of an archive child the package cannot
/// read itself (PDF, image, audio, video, message): its text, or why it was
/// not read. Installed by the indexing job (`ContainerTextExtractor.childReader`).
struct ArchiveChildReading: Sendable {
    var text: String?
    var notRead: String?
    /// Children of the child (a message's attachments), already read.
    var children: [ChildDocument] = []
    init(text: String?, notRead: String?, children: [ChildDocument] = []) { self.text = text; self.notRead = notRead; self.children = children }
}

/// One file inside an attachment, with its own text, identity and state —
/// plan v4 §13.3 (5): "message → documents.zip → budget.xls" keeps each
/// link distinct, same-named files stay apart, and no phrase bridges files.
struct ChildDocument: Sendable, Equatable {
    enum State: String, Sendable {
        case extracted, noText, partial, unsupported, locked, failed
        var isSearchable: Bool { self == .extracted || self == .partial }
    }
    /// Container chain inside the attachment, "inner.zip › dir/minutes.docx".
    var path: String
    var filename: String
    /// Detected kind (DocumentKind raw value, or the lower-cased extension).
    var kind: String
    var sha256: String
    var bytes: Int
    var text: String?
    var state: State
    var note: String?
    /// Sections read inside the child ("Sheet: Q3", "Slide 2"), for evidence.
    var components: [String] = []
}

/// Audit 2026-11-06 A04. Every child of an archive attachment is accounted
/// for: documents through the document facade, text files directly, every
/// other kind through the app's reader when one is installed (PDF text
/// layer, OCR, speech) — and a child nothing could read is LISTED as not
/// read, so the attachment is partial, never silently "complete". Archives
/// inside archives are opened to `maxDepth` levels; what lies deeper is
/// listed too. Extraction is bounded per part (`OfficeTextExtractor.maxPartBytes`)
/// and per attachment across all levels (`maxTotalBytes`), and each bound
/// that bites is named in the result.
enum ContainerTextExtractor {
    /// Plain-text children read directly. R04: `.eml` and `.rtf` are NOT
    /// here — a message has MIME parts and encodings, RTF has its own
    /// encoding; both go to the app's reader through `childReader`.
    static let textualExtensions: Set<String> = ["txt", "csv", "log", "md", "json", "xml", "html", "htm", "ics", "vcf", "yml", "yaml"]
    /// Archive inside archive inside archive: this many levels are opened (round 0; Resume adds a level per round).
    static var maxDepth: Int { ExtractionLimits.base.archiveDepth }
    /// Bytes extracted from one attachment's archives, all levels together (round 0; Resume doubles it per round).
    static var maxTotalBytes: Int64 { ExtractionLimits.base.totalArchiveBytes }
    /// The app's reader for children the package cannot read itself.
    nonisolated(unsafe) static var childReader: (@Sendable (URL, String) -> ArchiveChildReading)?

    private struct Child {
        let name: String
        let size: Int64?
        let encrypted: Bool
        let extract: (URL) throws -> Void
    }

    static func extract(fileURL: URL, kind: DocumentKind, logicalName: String? = nil, password: String? = nil) throws -> OfficeTextExtractor.Result {
        var budget = ExtractionLimits.effective.totalArchiveBytes
        return try extract(fileURL: fileURL, kind: kind, logicalName: logicalName ?? fileURL.lastPathComponent, depth: 1, prefix: "", budget: &budget, password: password)
    }

    /// R03: the gzip payload's name comes from the archive's LOGICAL name
    /// (`report.txt.gz` → `report.txt`, `backup.tgz` → `backup.tar`), never
    /// from the temporary file it was spooled to.
    static func gzipPayloadName(for logicalName: String) -> String {
        let name = (logicalName as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        if ext == "tgz" { return (name as NSString).deletingPathExtension + ".tar" }
        if ext == "gz" || ext == "gzip" {
            let stripped = (name as NSString).deletingPathExtension
            return stripped.isEmpty ? "payload" : stripped
        }
        return name.isEmpty ? "payload" : name
    }

    private static func children(of url: URL, kind: DocumentKind, logicalName: String, budget: Int64, password: String?) throws -> [Child] {
        switch kind {
        case .tar:
            let members: [TARReader.Member]
            do { members = try TARReader.members(of: url) } catch { throw OfficeTextExtractor.ExtractError.notAPackage(String(describing: error)) }
            return members.filter { $0.isRegularFile && !$0.isDirectory && !$0.isJunk }
                .map { member in Child(name: member.name, size: member.size, encrypted: false) { try TARReader.extract(member, from: url, to: $0) } }
        case .gzip:
            // R05: the uncompressed size is unknown in advance, so the budget
            // is enforced inside the inflate sink.
            let limit = min(ExtractionLimits.effective.partBytes, max(0, budget))
            return [Child(name: gzipPayloadName(for: logicalName), size: nil, encrypted: false) {
                try ZIPArchiveReader.gunzip(url, to: $0, maxOutputBytes: limit)
            }]
        default:
            let members: [ZIPArchiveReader.Member]
            do { members = try ZIPArchiveReader.members(of: url) } catch { throw OfficeTextExtractor.ExtractError.notAPackage(String(describing: error)) }
            return members.filter { !$0.isDirectory && !$0.isJunk }
                .map { member in Child(name: member.name, size: member.uncompressedSize, encrypted: member.isEncrypted) { try ZIPArchiveReader.extract(member, from: url, to: $0, password: password) } }
        }
    }

    /// Plan v4 §13.3 (5): every member becomes a `ChildDocument` with its own
    /// text, hash and state — nothing is joined into the parent's text. The
    /// parent's own text is the listing of its members. Nested containers
    /// contribute their members with the chain in `path`; a member nothing
    /// can read is a child in a named state, never dropped.
    private static func extract(fileURL: URL, kind: DocumentKind, logicalName: String, depth: Int, prefix: String, budget: inout Int64, password: String? = nil) throws -> OfficeTextExtractor.Result {
        let members = try children(of: fileURL, kind: kind, logicalName: logicalName, budget: budget, password: password)
        let scratch = try DocumentTextExtractor.scratchDirectory("archive")
        defer { try? FileManager.default.removeItem(at: scratch) }
        var listing: [String] = []
        var documents: [ChildDocument] = []
        var skipped: [String] = []
        var notText: [String] = []
        var unextractable = 0
        func record(_ name: String, _ member: Child, _ state: ChildDocument.State, text: String? = nil, note: String? = nil,
                    components: [String] = [], sha256: String = "", bytes: Int = 0, detected: String? = nil) {
            let ext = (member.name as NSString).pathExtension.lowercased()
            documents.append(ChildDocument(path: name, filename: (member.name as NSString).lastPathComponent, kind: detected ?? ext,
                                           sha256: sha256, bytes: bytes, text: text, state: state, note: note, components: components))
        }
        for member in members {
            let name = prefix + member.name
            let ext = (member.name as NSString).pathExtension.lowercased()
            listing.append(name)
            if member.encrypted, password == nil {
                skipped.append("\(name) (password-protected)"); record(name, member, .locked, note: "password-protected"); continue
            }
            if let size = member.size, size > ExtractionLimits.effective.partBytes {
                let why = "\(size) bytes, over the \(ExtractionLimits.effective.partBytes)-byte guard"
                skipped.append("\(name) (\(why))"); record(name, member, .unsupported, note: why, bytes: Int(size)); continue
            }
            if let size = member.size, size > budget {
                let why = "the \(ExtractionLimits.effective.totalArchiveBytes)-byte budget for one attachment's archives is used up"
                skipped.append("\(name) (\(why))"); record(name, member, .unsupported, note: why, bytes: Int(size)); continue
            }
            let destination = scratch.appendingPathComponent(UUID().uuidString + (ext.isEmpty ? "" : "." + ext))
            do { try member.extract(destination) } catch ZIPArchiveReader.ReadError.budgetExceeded(_, let limit) {
                // R05: stopped inside decompression at the budget — stated, not failed.
                let why = "decompression stopped at the \(limit)-byte budget"
                skipped.append("\(name) (\(why))"); record(name, member, .unsupported, note: why); continue
            } catch ZIPArchiveReader.ReadError.wrongPassword {
                // §13.8 step 5: the password did not open this member — still locked, said so.
                skipped.append("\(name) (the password did not open it)"); record(name, member, .locked, note: "the password did not open it"); continue
            } catch {
                unextractable += 1
                skipped.append("\(name) (\(error))"); record(name, member, .failed, note: "\(error)"); continue
            }
            defer { try? FileManager.default.removeItem(at: destination) }
            let written = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
            budget -= written
            if budget < 0 {
                let why = "the \(ExtractionLimits.effective.totalArchiveBytes)-byte budget for one attachment's archives is used up"
                skipped.append("\(name) (\(why))"); record(name, member, .unsupported, note: why, bytes: Int(written)); continue
            }
            let sha = (try? ExportInventory.sha256(of: destination)) ?? ""
            let size = Int(written)
            // R03: the logical name decides; when it says nothing, the bytes do.
            if let innerKind = DocumentKind.detect(mimeType: "", filename: member.name) ?? DocumentTextExtractor.sniff(fileURL: destination) {
                if innerKind.isContainer {
                    guard depth < ExtractionLimits.effective.archiveDepth else {
                        let why = "an archive nested deeper than \(ExtractionLimits.effective.archiveDepth) levels"
                        skipped.append("\(name) (\(why))"); record(name, member, .unsupported, note: why, sha256: sha, bytes: size, detected: innerKind.rawValue); continue
                    }
                    do {
                        let inner = try extract(fileURL: destination, kind: innerKind, logicalName: member.name, depth: depth + 1, prefix: name + " › ", budget: &budget, password: password)
                        documents.append(contentsOf: inner.children)
                        skipped.append(contentsOf: inner.skipped)
                        notText.append(contentsOf: inner.notText)
                    } catch OfficeTextExtractor.ExtractError.noTextParts {
                        notText.append(name); record(name, member, .noText, sha256: sha, bytes: size, detected: innerKind.rawValue)
                    } catch OfficeTextExtractor.ExtractError.encrypted {
                        skipped.append("\(name) (password-protected)"); record(name, member, .locked, note: "password-protected", sha256: sha, bytes: size, detected: innerKind.rawValue)
                    } catch {
                        skipped.append("\(name) (\(error))"); record(name, member, .failed, note: "\(error)", sha256: sha, bytes: size, detected: innerKind.rawValue)
                    }
                    continue
                }
                do {
                    let inner = try DocumentTextExtractor.extract(fileURL: destination, kind: innerKind, logicalName: member.name, password: password)
                    skipped.append(contentsOf: inner.skipped.map { "\(name): \($0)" })
                    record(name, member, inner.partial ? .partial : .extracted, text: inner.text,
                           note: inner.skipped.isEmpty ? nil : "not read: " + inner.skipped.joined(separator: "; "),
                           components: inner.components, sha256: sha, bytes: size, detected: innerKind.rawValue)
                    documents.append(contentsOf: inner.children.map { child in
                        var nested = child; nested.path = name + " › " + child.path; return nested
                    })
                } catch OfficeTextExtractor.ExtractError.encrypted {
                    skipped.append("\(name) (password-protected)"); record(name, member, .locked, note: "password-protected", sha256: sha, bytes: size, detected: innerKind.rawValue)
                } catch OfficeTextExtractor.ExtractError.wrongPassword {
                    skipped.append("\(name) (the password did not open it)"); record(name, member, .locked, note: "the password did not open it", sha256: sha, bytes: size, detected: innerKind.rawValue)
                } catch OfficeTextExtractor.ExtractError.noTextParts {
                    notText.append(name); record(name, member, .noText, sha256: sha, bytes: size, detected: innerKind.rawValue)
                } catch {
                    skipped.append("\(name) (\(error))"); record(name, member, .failed, note: "\(error)", sha256: sha, bytes: size, detected: innerKind.rawValue)
                }
            } else if textualExtensions.contains(ext) {
                let data = (try? Data(contentsOf: destination)) ?? Data()
                var body = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
                if ext == "html" || ext == "htm" { body = body.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression) }
                if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    notText.append(name); record(name, member, .noText, sha256: sha, bytes: size)
                } else {
                    record(name, member, .extracted, text: body, sha256: sha, bytes: size)
                }
            } else if let reader = childReader {
                let reading = reader(destination, member.name)
                if let body = reading.text, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if let why = reading.notRead { skipped.append("\(name): \(why)") }
                    record(name, member, reading.notRead == nil ? .extracted : .partial, text: body, note: reading.notRead, sha256: sha, bytes: size)
                } else if let why = reading.notRead {
                    skipped.append("\(name) (\(why))"); record(name, member, .unsupported, note: why, sha256: sha, bytes: size)
                } else {
                    notText.append(name); record(name, member, .noText, sha256: sha, bytes: size)
                }
                // A message's own attachments are children too, under the message's name.
                documents.append(contentsOf: reading.children.map { child in
                    var nested = child; nested.path = name + " › " + child.path; return nested
                })
            } else {
                let why = "not read inside archives: .\(ext.isEmpty ? "?" : ext)"
                skipped.append("\(name) (\(why))"); record(name, member, .unsupported, note: why, sha256: sha, bytes: size)
            }
        }
        // Not one member could even be extracted: the file is not the archive
        // its name claims (a bogus .gz, a truncated .zip) — a failure, not "partly read".
        if !members.isEmpty, unextractable == members.count {
            throw OfficeTextExtractor.ExtractError.notAPackage(skipped.joined(separator: "; "))
        }
        if members.isEmpty { throw OfficeTextExtractor.ExtractError.noTextParts }
        let text = "[Contents]\n" + listing.joined(separator: "\n") + "\n"
        return OfficeTextExtractor.Result(text: text, components: ["Contents"], skipped: skipped, notText: notText.sorted(), children: documents)
    }

    /// §13.3 (9): the bytes of one child, by its recorded path ("a.zip › b/c.docx"),
    /// extracted level by level into `scratch`. An attached message along the
    /// chain is opened by its MIME parts. Returns the child's file URL.
    static func materialize(childPath: String, in fileURL: URL, kind: DocumentKind?, logicalName: String, scratch: URL, password: String? = nil) throws -> URL {
        var segments = childPath.components(separatedBy: " › ")
        var currentURL = fileURL
        var currentName = logicalName
        var currentKind: DocumentKind? = kind ?? DocumentKind.detect(mimeType: "", filename: logicalName) ?? DocumentTextExtractor.sniff(fileURL: fileURL)
        while !segments.isEmpty {
            let segment = segments.removeFirst()
            let ext = (currentName as NSString).pathExtension.lowercased()
            // §13.8 step 3: a TNEF wrapper or an Outlook message along the chain.
            if TNEFReader.isTNEF(fileURL: currentURL) {
                let content = try TNEFReader.read(Data(contentsOf: currentURL))
                guard let file = content.attachments.first(where: { $0.filename == segment }), !file.isEmbeddedMessage else {
                    throw OfficeTextExtractor.ExtractError.notAPackage("\(currentName) has no file named \(segment)")
                }
                let destination = scratch.appendingPathComponent(UUID().uuidString + "-" + (segment as NSString).lastPathComponent)
                try file.data.write(to: destination)
                currentURL = destination; currentName = segment
                currentKind = DocumentKind.detect(mimeType: file.mimeType, filename: segment) ?? DocumentTextExtractor.sniff(fileURL: destination)
                continue
            }
            if ext == "msg" || ext == "oft" {
                let email = try MSGParser.parse(data: Data(contentsOf: currentURL))
                guard let attachment = email.attachments.first(where: { $0.filename == segment }),
                      let base64 = attachment.base64, let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
                    throw OfficeTextExtractor.ExtractError.notAPackage("\(currentName) has no attachment named \(segment)")
                }
                let destination = scratch.appendingPathComponent(UUID().uuidString + "-" + (segment as NSString).lastPathComponent)
                try data.write(to: destination)
                currentURL = destination; currentName = segment
                currentKind = DocumentKind.detect(mimeType: attachment.mimeType, filename: segment) ?? DocumentTextExtractor.sniff(fileURL: destination)
                continue
            }
            if ext == "eml" || currentKind == nil {
                // A message: the child is one of its attachments.
                let bytes = try Data(contentsOf: currentURL)
                guard let raw = String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .isoLatin1) else {
                    throw OfficeTextExtractor.ExtractError.notAPackage("\(currentName) is not readable text")
                }
                let email = try MBOXParser.processRawMessage(raw, senderEmail: "")
                defer { for attachment in email.attachments { if let url = attachment.fileURL { try? FileManager.default.removeItem(at: url) } } }
                guard let attachment = email.attachments.first(where: { $0.filename == segment }),
                      let data = AttachmentHydrator.data(for: attachment, index: email.attachments.firstIndex { $0.filename == segment } ?? 0, email: email) else {
                    throw OfficeTextExtractor.ExtractError.notAPackage("\(currentName) has no attachment named \(segment)")
                }
                let destination = scratch.appendingPathComponent(UUID().uuidString + "-" + (segment as NSString).lastPathComponent)
                try data.write(to: destination)
                currentURL = destination; currentName = segment
            } else {
                guard let containerKind = currentKind, containerKind.isContainer else {
                    throw OfficeTextExtractor.ExtractError.notAPackage("\(currentName) is not an archive")
                }
                let members = try children(of: currentURL, kind: containerKind, logicalName: currentName, budget: ExtractionLimits.effective.totalArchiveBytes, password: password)
                guard let member = members.first(where: { $0.name == segment }) else {
                    throw OfficeTextExtractor.ExtractError.notAPackage("\(currentName) has no member named \(segment)")
                }
                let destination = scratch.appendingPathComponent(UUID().uuidString + "-" + (segment as NSString).lastPathComponent)
                try member.extract(destination)
                currentURL = destination; currentName = member.name
            }
            currentKind = DocumentKind.detect(mimeType: "", filename: currentName) ?? DocumentTextExtractor.sniff(fileURL: currentURL)
        }
        return currentURL
    }
}

/// The name the ZIP-only reader had before archives were generalised (TYPE-04).
typealias ZIPContainerTextExtractor = ContainerTextExtractor
