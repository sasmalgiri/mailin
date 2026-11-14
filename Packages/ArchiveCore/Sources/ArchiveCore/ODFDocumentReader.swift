//
//  ODFDocumentReader.swift
//  ArchiveCore
//
//  Directive 2026-11-07 §6 "OpenDocument/iWork": the OpenDocument reader
//  verified on real OpenOffice.org / NeoOffice / LibreOffice files (Apache
//  Tika's corpus, `TikaODFIWorkFixtureTests`). It replaces `ODFTextExtractor`
//  at the one dispatch seam in `DocumentTextExtractor.extract`; the earlier
//  reader stays in DocumentTextExtractors.swift (rule 14).
//
//  What is read, labelled:
//    content.xml        body text, headings, lists, tables (cells tab-separated,
//                       numbers and dates from office:value / office:date-value),
//                       sheets ("Sheet: name"), slides ("Slide N") and their
//                       notes ("Notes N"), footnotes/endnotes inline as
//                       "[1: …]", comments as "[Comment by …] …", text boxes
//    styles.xml         headers and footers (odt, ods) and the master-page
//                       footer/header/date frames of a presentation
//    X/content.xml      embedded objects (a spreadsheet or chart inside a text
//                       document) as "Embedded: X"
//  Not read and said so: Pictures/, media, ObjectReplacements (previews),
//  Thumbnails, Basic/ (macros — never run, never read). Formula documents
//  (.odf) have no body text and come out as "no text".
//
//  Encrypted packages (`manifest:encryption-data`) are "locked" without a
//  password and opened with one through `ODFEncryption` (§6 "Protected
//  mail/documents"); a wrong password is `wrongPassword`.
//

import Foundation

enum ODFDocumentReader {

    static func extract(fileURL: URL, kind: DocumentKind, password: String? = nil) throws -> OfficeTextExtractor.Result {
        let members: [ZIPArchiveReader.Member]
        do { members = try ZIPArchiveReader.members(of: fileURL) } catch {
            throw OfficeTextExtractor.ExtractError.notAPackage(String(describing: error))
        }
        let byName = Dictionary(members.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let scratch = try DocumentTextExtractor.scratchDirectory("odf")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let partLimit = Int(ExtractionLimits.effective.partBytes)

        // The manifest decides whether members are plain or encrypted.
        var encrypted: [String: ODFEncryption.EntryEncryption] = [:]
        if let manifest = byName["META-INF/manifest.xml"], manifest.uncompressedSize <= ExtractionLimits.effective.partBytes {
            encrypted = ODFEncryption.encryptedEntries(manifest: try DocumentTextExtractor.memberData(manifest, from: fileURL, scratch: scratch))
        }
        if !encrypted.isEmpty, password == nil { throw OfficeTextExtractor.ExtractError.encrypted }

        // Audit R6: LibreOffice 24.2+ "wholesome" encryption — the whole document
        // is one encrypted stream, `encrypted-package`, holding a plain inner
        // package (ZipPackage.cxx). Decrypted, then read as the document itself.
        if let password, let entry = encrypted["encrypted-package"], let member = byName["encrypted-package"] {
            let limit = ExtractionLimits.effective.totalArchiveBytes
            guard member.compressedSize <= limit else {
                throw OfficeTextExtractor.ExtractError.notAPackage("encrypted-package is \(member.compressedSize) bytes, over the \(limit)-byte guard")
            }
            let raw = try DocumentTextExtractor.memberData(member, from: fileURL, scratch: scratch)
            var inner = try ODFEncryption.decryptToDeflated(entry: entry, cipherText: raw, password: password)
            if !inner.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
                do { inner = try RawDeflate.inflate(inner, limit: Int(limit)) } catch { throw OfficeTextExtractor.ExtractError.wrongPassword }
            }
            guard inner.starts(with: [0x50, 0x4B, 0x03, 0x04]) else { throw OfficeTextExtractor.ExtractError.wrongPassword }
            let innerURL = scratch.appendingPathComponent(UUID().uuidString + "." + kind.rawValue)
            try inner.write(to: innerURL)
            return try extract(fileURL: innerURL, kind: kind, password: nil)
        }

        var skipped: [String] = []
        var notText: [String] = []
        for m in members where !m.isDirectory {
            let n = m.name
            if n.hasPrefix("Pictures/") || n.hasPrefix("media/") || n.hasPrefix("Thumbnails/") || n.hasPrefix("ObjectReplacements/") || n.contains("/Pictures/") {
                notText.append(n)
            } else if n.hasPrefix("Basic/") || n.hasPrefix("Scripts/") || n.contains("/Basic/") {
                notText.append(n + " (macro — not run, not read)")
            }
        }

        /// A part's plain bytes, decrypted when the manifest says so; nil when absent.
        func part(_ name: String) throws -> Data? {
            guard let member = byName[name] else { return nil }
            let declared = encrypted[name]?.plainSize.map(Int64.init) ?? member.uncompressedSize
            guard declared <= ExtractionLimits.effective.partBytes else {
                skipped.append("\(name) (\(declared) bytes, over the \(ExtractionLimits.effective.partBytes)-byte guard)")
                return nil
            }
            let raw = try DocumentTextExtractor.memberData(member, from: fileURL, scratch: scratch)
            guard let entry = encrypted[name], let password else { return raw }
            do {
                return try ODFEncryption.decrypt(entry: entry, cipherText: raw, password: password, limit: partLimit)
            } catch RawDeflate.Failure.corrupt {
                // The key opened nothing readable and there was no checksum to say so earlier.
                throw OfficeTextExtractor.ExtractError.wrongPassword
            }
        }

        var text = ""
        var components: [String] = []
        func emit(_ sections: [ODFPartCollector.Section]) {
            for section in sections where !section.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                components.append(section.label)
                text += "[\(section.label)]\n" + section.text.trimmingCharacters(in: .newlines) + "\n"
            }
        }

        if let content = try part("content.xml") {
            let collector = ODFPartCollector(kind: kind, part: .content)
            if collector.parse(content) { emit(collector.sections) } else { skipped.append("content.xml (malformed XML)") }
        }
        if let styles = try part("styles.xml") {
            let collector = ODFPartCollector(kind: kind, part: .styles)
            if collector.parse(styles) { emit(collector.sections) } else { skipped.append("styles.xml (malformed XML)") }
        }
        // Embedded objects: "Object 1/content.xml" and the like, in name order.
        let embeddedNames = members.map(\.name).filter { $0.hasSuffix("/content.xml") && !$0.hasPrefix("META-INF/") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        for name in embeddedNames {
            guard let data = try part(name) else { continue }
            let objectName = String(name.dropLast("/content.xml".count))
            let collector = ODFPartCollector(kind: .odt, part: .content, label: "Embedded: \(objectName)")
            if collector.parse(data) { emit(collector.sections) } else { skipped.append("\(name) (malformed XML)") }
        }

        if components.isEmpty && skipped.isEmpty { throw OfficeTextExtractor.ExtractError.noTextParts }
        return OfficeTextExtractor.Result(text: text, components: components, skipped: skipped, notText: notText.sorted())
    }
}

/// The text of one OpenDocument XML part, split into labelled sections.
/// `maxRepeatedSpaces` bounds one `text:s` run (audit A05).
final class ODFPartCollector: NSObject, XMLParserDelegate {
    static let maxRepeatedSpaces = 4_096
    enum Part { case content, styles }
    struct Section { var label: String; var text: String }

    private(set) var sections: [Section] = []
    private let kind: DocumentKind
    private let part: Part
    private var current: Section
    private var pending: [Section] = []
    private var ok = true

    // Context
    private var depth = 0
    private var captureDepths: [Int] = []      // depths at which a capturing region opened (styles.xml)
    private var slideIndex = 0
    private var cellDepth = 0
    private var inNotes = false
    private var savedBeforeNotes: Section?
    private var skipDepths: [Int] = []         // dc:creator/dc:date, text:page-number in master pages, tracked-change deletions
    private var annotationStack: [(creator: String, text: String, saved: Section)] = []
    private var creatorDepth: Int?
    private var noteStack: [(citation: String, body: String, inBody: Bool, inCitation: Bool, saved: Section)] = []
    private var masterPageName: String?

    init(kind: DocumentKind, part: Part, label: String? = nil) {
        self.kind = kind
        self.part = part
        let base = label ?? (part == .styles ? "" : "Document")
        current = Section(label: base, text: "")
        if part == .styles { current = Section(label: "", text: "") }
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
        sections.append(contentsOf: pending)
        pending = []
        current = Section(label: "", text: "")
    }

    /// Styles parts capture only inside headers/footers/master-page frames; content parts always.
    private var capturing: Bool { part == .content || !captureDepths.isEmpty }
    private var skipping: Bool { !skipDepths.isEmpty }

    private func append(_ s: String) {
        if var note = noteStack.popLast() {
            if note.inCitation { note.citation += s } else if note.inBody { note.body += s }
            noteStack.append(note)
            return
        }
        if var annotation = annotationStack.popLast() {
            if creatorDepth != nil { annotation.creator += s } else { annotation.text += s }
            annotationStack.append(annotation)
            return
        }
        current.text += s
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        depth += 1
        switch name {
        // Headers and footers (styles.xml, every kind) and master-page frames of a presentation.
        case "style:header", "style:footer", "style:header-left", "style:footer-left", "style:header-first", "style:footer-first":
            guard part == .styles else { return }
            if attributes["style:display"] == "false" { skipDepths.append(depth); return }
            captureDepths.append(depth)
            flush()
            current = Section(label: name.contains("header") ? "Header" : "Footer", text: "")
        case "style:master-page":
            masterPageName = attributes["style:name"]
        case "draw:frame" where part == .styles && masterPageName != nil && captureDepths.isEmpty:
            // Presentation master pages: footer / header / date-time frames carry fixed text.
            if let cls = attributes["presentation:class"], ["footer", "header", "date-time"].contains(cls) {
                captureDepths.append(depth)
                flush()
                current = Section(label: "Master page \(masterPageName ?? "")", text: "")
            }
        case "text:page-number" where part == .styles && captureDepths.isEmpty:
            skipDepths.append(depth)   // "<number>" placeholders of presentation master pages; a page footer's "Page 1" is kept
        case "text:sheet-name" where part == .styles, "text:title" where part == .styles, "text:date" where part == .styles, "text:time" where part == .styles:
            skipDepths.append(depth)   // field placeholders ("???") in sheet headers

        // Content structure.
        case "table:table" where kind == .ods && part == .content && annotationStack.isEmpty:
            flush(); current = Section(label: "Sheet: " + (attributes["table:name"] ?? "Sheet"), text: "")
        case "draw:page" where (kind == .odp) && part == .content:
            slideIndex += 1
            flush(); current = Section(label: "Slide \(slideIndex)", text: "")
        case "presentation:notes" where kind == .odp && part == .content:
            inNotes = true
            savedBeforeNotes = current
            current = Section(label: "Notes \(slideIndex)", text: "")
        case "table:table-cell" where capturing, "table:covered-table-cell" where capturing:
            cellDepth += 1
            // Numbers, dates and times carry their value as an attribute and
            // usually a formatted text:p too; the text wins, the attribute is
            // the fallback when the cell closes without any.
            pendingCellValue = attributes["office:value-type"] == "string" ? nil
                : (attributes["office:date-value"] ?? attributes["office:time-value"] ?? attributes["office:value"])
            cellHadText = false
        case "text:s" where capturing:
            append(String(repeating: " ", count: min(max(Int(attributes["text:c"] ?? "1") ?? 1, 0), Self.maxRepeatedSpaces)))
        case "text:tab" where capturing: append("\t")
        case "text:line-break" where capturing: append("\n")
        case "text:soft-page-break": break

        // Comments and notes.
        case "office:annotation" where capturing:
            annotationStack.append((creator: "", text: "", saved: current))
        case "dc:creator" where !annotationStack.isEmpty:
            creatorDepth = depth
        case "dc:date" where !annotationStack.isEmpty, "meta:date-string" where !annotationStack.isEmpty:
            skipDepths.append(depth)
        case "text:note" where capturing:
            noteStack.append((citation: "", body: "", inBody: false, inCitation: false, saved: current))
        case "text:note-citation" where !noteStack.isEmpty:
            noteStack[noteStack.count - 1].inCitation = true
        case "text:note-body" where !noteStack.isEmpty:
            noteStack[noteStack.count - 1].inBody = true
        case "text:tracked-changes", "office:event-listeners", "office:forms", "text:bibliography-source":
            skipDepths.append(depth)
        default: break
        }
    }

    private var pendingCellValue: String?
    private var cellHadText = false

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard capturing, !skipping else { return }
        if cellDepth > 0, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { cellHadText = true }
        append(string)
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        defer { depth -= 1 }
        if let last = skipDepths.last, last == depth { skipDepths.removeLast() }
        if creatorDepth == depth { creatorDepth = nil }
        if let last = captureDepths.last, last == depth {
            captureDepths.removeLast()
            if part == .styles { flush() }
            return
        }
        switch name {
        case "style:master-page": masterPageName = nil
        case "text:p" where capturing, "text:h" where capturing:
            append(cellDepth > 0 ? " " : "\n")
        case "table:table-cell" where capturing, "table:covered-table-cell" where capturing:
            cellDepth = max(0, cellDepth - 1)
            if !cellHadText, let value = pendingCellValue { append(value) }
            pendingCellValue = nil; cellHadText = false
            if current.text.hasSuffix(" ") { current.text.removeLast() }
            append("\t")
        case "table:table-row" where capturing: append("\n")
        case "presentation:notes" where inNotes:
            inNotes = false
            pending.append(current)
            current = savedBeforeNotes ?? Section(label: "Slide \(slideIndex)", text: "")
            savedBeforeNotes = nil
        case "text:note-citation" where !noteStack.isEmpty:
            noteStack[noteStack.count - 1].inCitation = false
        case "text:note-body" where !noteStack.isEmpty:
            noteStack[noteStack.count - 1].inBody = false
        case "text:note" where !noteStack.isEmpty:
            let note = noteStack.removeLast()
            let citation = note.citation.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
            append(" [\(citation.isEmpty ? "note" : citation): \(body)] ")
        case "office:annotation" where !annotationStack.isEmpty:
            let annotation = annotationStack.removeLast()
            let creator = annotation.creator.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = annotation.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                append("\n[Comment\(creator.isEmpty ? "" : " by \(creator)")] \(body)\n")
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { ok = false }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { ok = false }
}
