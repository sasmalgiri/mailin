//
//  SectionBoundaryPhraseTests.swift
//  ArchiveCoreTests
//
//  Plan v4 §13.3 row 6: "no false phrases across cells / sections / files".
//  Files are separate `childText` documents (WP2). Inside ONE document the
//  extractors write every cell, row, slide, sheet and page with a separator
//  with an explicit boundary (FIND-08: U+001E beside the tab between cells,
//  the newline between rows, the "[Slide n]" / "[Sheet: …]" label line
//  between sections, the newline between PDF pages — `SectionBoundary`),
//  and the chunk index verifies a phrase with `mailin_phrase`: any run of
//  whitespace is one space (a wrapped line, a double space left by removed
//  HTML) but a boundary is never crossed. So a phrase never joins the last
//  word of one cell/slide/page to the first word of the next, a phrase that
//  merely wraps is found, and "all words" still treats the whole document
//  as one unit.
//
//  These tests run the REAL extractors (XLSX, ODS, PPTX, ODP, DOCX, and the
//  PDF text layer page by page — `SectionBoundary.pdfText`, which is what the
//  app's attachment job indexes for a PDF), index their output as attachment
//  documents, and search through `EmailQuery.spec` exactly as the app does.
//

import XCTest
import Foundation
import PDFKit
import CoreText
@testable import ArchiveCore

final class SectionBoundaryPhraseTests: XCTestCase {

    private var root: URL!
    private var store: SQLiteEmailStore!
    private var archive: ArchiveDataService!
    private var wasOn = false

    override func setUp() async throws {
        wasOn = SearchChunkPolicy.isEnabled
        SearchChunkPolicy.isEnabled = true
        root = FileManager.default.temporaryDirectory.appendingPathComponent("row6-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = SQLiteEmailStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts", isDirectory: true))
        archive = ArchiveDataService(repository: EmailStoreRepository(store: store, fts: fts))
    }

    override func tearDown() async throws {
        SearchChunkPolicy.isEnabled = wasOn
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixture plumbing

    private static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
            table[i] = c
        }
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFFFFFF
    }

    /// A stored (uncompressed) ZIP with correct CRCs.
    private static func zipPackage(_ members: [(name: String, data: Data)]) -> Data {
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }
        var local = Data(), central = Data()
        for m in members {
            let name = Array(m.name.utf8)
            let crc = crc32(m.data)
            let size = UInt32(m.data.count)
            let offset = UInt32(local.count)
            local.append(contentsOf: le32(0x04034b50) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0)
                         + le32(crc) + le32(size) + le32(size) + le16(name.count) + le16(0) + name)
            local.append(m.data)
            central.append(contentsOf: le32(0x02014b50) + le16(20) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0)
                           + le32(crc) + le32(size) + le32(size) + le16(name.count) + le16(0) + le16(0) + le16(0) + le16(0)
                           + le32(0) + le32(offset) + name)
        }
        var file = local
        file.append(central)
        file.append(contentsOf: le32(0x06054b50) + le16(0) + le16(0) + le16(members.count) + le16(members.count)
                    + le32(UInt32(central.count)) + le32(UInt32(local.count)) + le16(0))
        return file
    }

    private func write(_ name: String, _ data: Data) throws -> URL {
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// One sheet; `rows` are rows of inline-string cells.
    private func xlsx(_ rows: [[String]]) throws -> String {
        let sheetData = rows.enumerated().map { r, cells in
            "<row r=\"\(r + 1)\">" + cells.enumerated().map { c, value in
                "<c r=\"\(OfficeTextExtractor.columnName(c))\(r + 1)\" t=\"inlineStr\"><is><t>\(value)</t></is></c>"
            }.joined() + "</row>"
        }.joined()
        let package = Self.zipPackage([
            ("xl/workbook.xml", Data("<workbook xmlns:r=\"r\"><sheets><sheet name=\"Votes\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>".utf8)),
            ("xl/_rels/workbook.xml.rels", Data("<Relationships><Relationship Id=\"rId1\" Type=\"x\" Target=\"worksheets/sheet1.xml\"/></Relationships>".utf8)),
            ("xl/worksheets/sheet1.xml", Data("<worksheet><sheetData>\(sheetData)</sheetData></worksheet>".utf8)),
        ])
        return try OfficeTextExtractor.extract(fileURL: try write(UUID().uuidString + ".xlsx", package), kind: .xlsx).text
    }

    /// One slide per entry, each slide one paragraph.
    private func pptx(_ slides: [String]) throws -> String {
        var members: [(String, Data)] = []
        for (i, text) in slides.enumerated() {
            members.append(("ppt/slides/slide\(i + 1).xml", Data("""
            <p:sld xmlns:p="p" xmlns:a="a"><p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>\(text)</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>
            """.utf8)))
        }
        return try OfficeTextExtractor.extract(fileURL: try write(UUID().uuidString + ".pptx", Self.zipPackage(members)), kind: .pptx).text
    }

    private static let odfNamespaces = """
    xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" \
    xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0" \
    xmlns:presentation="urn:oasis:names:tc:opendocument:xmlns:presentation:1.0"
    """

    private func ods(_ rows: [[String]]) throws -> String {
        let table = rows.map { cells in
            "<table:table-row>" + cells.map { "<table:table-cell><text:p>\($0)</text:p></table:table-cell>" }.joined() + "</table:table-row>"
        }.joined()
        let content = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content \(Self.odfNamespaces) office:version="1.2"><office:body><office:spreadsheet>\
        <table:table table:name="Votes">\(table)</table:table></office:spreadsheet></office:body></office:document-content>
        """
        let package = Self.zipPackage([("mimetype", Data("application/vnd.oasis.opendocument.spreadsheet".utf8)), ("content.xml", Data(content.utf8))])
        return try ODFDocumentReader.extract(fileURL: try write(UUID().uuidString + ".ods", package), kind: .ods).text
    }

    private func odp(_ slides: [String]) throws -> String {
        let pages = slides.enumerated().map { i, text in
            "<draw:page draw:name=\"page\(i + 1)\"><draw:frame><draw:text-box><text:p>\(text)</text:p></draw:text-box></draw:frame></draw:page>"
        }.joined()
        let content = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content \(Self.odfNamespaces) office:version="1.2"><office:body><office:presentation>\(pages)</office:presentation></office:body></office:document-content>
        """
        let package = Self.zipPackage([("mimetype", Data("application/vnd.oasis.opendocument.presentation".utf8)), ("content.xml", Data(content.utf8))])
        return try ODFDocumentReader.extract(fileURL: try write(UUID().uuidString + ".odp", package), kind: .odp).text
    }

    /// A PDF with one line of text per page, read the way the app's
    /// attachment job reads a text-layer PDF (`SectionBoundary.pdfText`).
    private func pdf(_ pages: [String]) throws -> String {
        try pdf(lines: pages.map { [$0] })
    }

    /// A PDF whose pages hold these lines, one under the other.
    private func pdf(lines pages: [[String]]) throws -> String {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        for lines in pages {
            context.beginPDFPage(nil)
            for (i, text) in lines.enumerated() {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
                context.textPosition = CGPoint(x: 20, y: 200 - CGFloat(i) * 30)
                CTLineDraw(line, context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        let document = try XCTUnwrap(PDFDocument(data: data as Data))
        XCTAssertEqual(document.pageCount, pages.count)
        return try XCTUnwrap(SectionBoundary.pdfText(document))
    }

    private static let w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

    /// A DOCX body (WordprocessingML inside <w:body>), read by the real extractor.
    private func docx(_ body: String) throws -> String {
        let package = Self.zipPackage([("word/document.xml", Data("<w:document xmlns:w=\"\(Self.w)\"><w:body>\(body)</w:body></w:document>".utf8))])
        return try DocumentTextExtractor.extract(fileURL: try write(UUID().uuidString + ".docx", package), kind: .docx).text
    }

    /// One message per document, its subject the label; the document is the
    /// message's attachment text (ordinal 0), as the attachment job writes it.
    private func index(_ documents: [String: String], filename: String) async throws {
        var n = 0
        for (subject, text) in documents.sorted(by: { $0.key < $1.key }) {
            n += 1
            let email = MBOXParser.RawEmail(
                headers: ["Message-ID": "<row6-\(subject)-\(UUID().uuidString)@test>", "Subject": subject, "From": "a@test", "To": "b@test",
                          "Date": "Wed, 01 Mar 2023 12:00:0\(n % 10) +0000"],
                rawSource: "", messageType: "email",
                attachments: [AttachmentMetadata(filename: filename, mimeType: "application/octet-stream", size: text.utf8.count)],
                timestamp: "", domains: [], plainBody: "cover note", htmlBody: "")
            try await store.insertBatch([email], batchSize: 10)
            try await store.indexAttachmentSearchDocuments(emailID: email.id, documents: [
                AttachmentSearchDocument(ordinal: 0, filename: filename, text: text, state: .complete, extractorVersion: 1, ocr: false)])
        }
    }

    /// Subjects found by `match value` both as an "anywhere" condition and
    /// as an attachment content condition (one file); the two must agree.
    @MainActor
    private func found(_ match: SearchCondition.Match, _ value: String, file: StaticString = #filePath, line: UInt = #line) async throws -> Set<String> {
        func run(_ spec: SearchSpec) async throws -> Set<String> {
            var query = EmailQuery()
            query.spec = spec
            var subjects = Set<String>()
            for try await batch in archive.streamFullEmails(query: query, batchSize: 50) {
                for e in batch { subjects.insert(e.headers["Subject"] ?? "") }
            }
            let count = try await archive.count(query: query)
            XCTAssertEqual(count, subjects.count, "count and rows agree", file: file, line: line)
            return subjects
        }
        let anywhere = try await run(SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.anyText, match, value)])]))
        let oneFile = try await run(SearchSpec(groups: [SearchGroup(.all, attachments: [AttachmentConditionGroup(contentMatch: match, content: value)])]))
        XCTAssertEqual(anywhere, oneFile, "anywhere and one-attachment agree for \(match) \(value)", file: file, line: line)
        return anywhere
    }

    // MARK: - Spreadsheet cells and rows

    @MainActor
    func testRow6_spreadsheetCells_phraseNeverCrossesACellOrRow_allWordsStillMatch() async throws {
        // Cell A1 "quorum", B1 "clause"; A2 "settlement", A3 "terms" (rows); one cell "quorum clause" elsewhere.
        let split = try xlsx([["quorum", "clause"], ["settlement"], ["terms"]])
        let whole = try xlsx([["quorum clause"], ["settlement terms"]])
        let splitODS = try ods([["quorum", "clause"], ["settlement"], ["terms"]])
        let wholeODS = try ods([["quorum clause"], ["settlement terms"]])
        for text in [split, splitODS] {
            XCTAssertTrue(text.contains("quorum"), text); XCTAssertTrue(text.contains("clause"), text)
        }
        try await index(["XLSX cells": split, "XLSX one cell": whole], filename: "votes.xlsx")
        try await index(["ODS cells": splitODS, "ODS one cell": wholeODS], filename: "votes.ods")

        let phrase = try await found(.phrase, "quorum clause")
        XCTAssertEqual(phrase, ["XLSX one cell", "ODS one cell"], "a phrase never joins two cells (XLSX: \(split.debugDescription); ODS: \(splitODS.debugDescription))")
        let contains = try await found(.contains, "quorum cl")
        XCTAssertEqual(contains, ["XLSX one cell", "ODS one cell"], "a 'contains' literal never joins two cells")
        let rows = try await found(.phrase, "settlement terms")
        XCTAssertEqual(rows, ["XLSX one cell", "ODS one cell"], "a phrase never joins two rows")
        let all = try await found(.allWords, "quorum clause")
        XCTAssertEqual(all, ["XLSX cells", "XLSX one cell", "ODS cells", "ODS one cell"], "all words still read the whole document")
        let any = try await found(.anyWords, "clause nothingelse")
        XCTAssertEqual(any, ["XLSX cells", "XLSX one cell", "ODS cells", "ODS one cell"])
    }

    // MARK: - Slides

    @MainActor
    func testRow6_slides_phraseNeverCrossesASlide_allWordsStillMatch() async throws {
        let split = try pptx(["agenda quorum", "clause review"])
        let whole = try pptx(["agenda quorum clause review"])
        let splitODP = try odp(["agenda quorum", "clause review"])
        let wholeODP = try odp(["agenda quorum clause review"])
        XCTAssertTrue(split.contains("[Slide 2]"), split)
        XCTAssertTrue(splitODP.contains("[Slide 2]"), splitODP)
        try await index(["PPTX slides": split, "PPTX one slide": whole], filename: "deck.pptx")
        try await index(["ODP slides": splitODP, "ODP one slide": wholeODP], filename: "deck.odp")

        let phrase = try await found(.phrase, "quorum clause")
        XCTAssertEqual(phrase, ["PPTX one slide", "ODP one slide"], "a phrase never joins two slides (PPTX: \(split.debugDescription); ODP: \(splitODP.debugDescription))")
        let inside = try await found(.phrase, "agenda quorum")
        XCTAssertEqual(inside, ["PPTX slides", "PPTX one slide", "ODP slides", "ODP one slide"], "a phrase inside one slide is found")
        let all = try await found(.allWords, "quorum clause")
        XCTAssertEqual(all, ["PPTX slides", "PPTX one slide", "ODP slides", "ODP one slide"])
    }

    // MARK: - PDF pages

    @MainActor
    func testRow6_pdfPages_phraseNeverCrossesAPage_allWordsStillMatch() async throws {
        let split = try pdf(["alpha quorum", "clause omega"])
        let whole = try pdf(["alpha quorum clause omega"])
        XCTAssertTrue(split.contains("quorum") && split.contains("clause"), split)
        try await index(["PDF pages": split, "PDF one page": whole], filename: "minutes.pdf")

        let phrase = try await found(.phrase, "quorum clause")
        XCTAssertEqual(phrase, ["PDF one page"], "a phrase never joins two pages (\(split.debugDescription))")
        let inside = try await found(.phrase, "alpha quorum")
        XCTAssertEqual(inside, ["PDF pages", "PDF one page"], "a phrase inside one page is found")
        let all = try await found(.allWords, "quorum clause")
        XCTAssertEqual(all, ["PDF pages", "PDF one page"])
    }

    // MARK: - FIND-08: wrapped phrases are found, boundaries still hold

    /// Plain-text / HTML messages, no attachments.
    private func indexBodies(_ bodies: [String: (plain: String, html: String)]) async throws {
        var n = 0
        for (subject, body) in bodies.sorted(by: { $0.key < $1.key }) {
            n += 1
            let email = MBOXParser.RawEmail(
                headers: ["Message-ID": "<find08-\(subject)-\(UUID().uuidString)@test>", "Subject": subject, "From": "a@test", "To": "b@test",
                          "Date": "Wed, 01 Mar 2023 12:00:0\(n % 10) +0000"],
                rawSource: "", messageType: "email", attachments: [], timestamp: "", domains: [],
                plainBody: body.plain, htmlBody: body.html)
            try await store.insertBatch([email], batchSize: 10)
        }
    }

    @MainActor
    private func subjects(_ condition: SearchCondition) async throws -> Set<String> {
        var query = EmailQuery()
        query.spec = SearchSpec(groups: [SearchGroup(.all, [condition])])
        var out = Set<String>()
        for try await batch in archive.streamFullEmails(query: query, batchSize: 50) {
            for e in batch { out.insert(e.headers["Subject"] ?? "") }
        }
        let count = try await archive.count(query: query)
        XCTAssertEqual(count, out.count, "count and rows agree")
        return out
    }

    @MainActor
    private func idOf(_ subject: String) async throws -> UUID? {
        var query = EmailQuery()
        query.spec = SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.subject, .equals, subject)])])
        for try await batch in archive.streamFullEmails(query: query, batchSize: 5) { if let e = batch.first { return e.id } }
        return nil
    }

    /// Filler that ends `tail` exactly at the first chunk join, then more filler.
    private static func acrossTheJoin(_ tail: String, then rest: String) -> String {
        let filler = String(repeating: "lorem ipsum dolor sit amet ", count: 2_400)   // > one chunk
        let head = String(filler.prefix(SearchChunker.chunkCharacters - tail.count - 1)) + " "
        return head + tail + rest + " " + filler
    }

    @MainActor
    func testFIND08_wrappedPhraseInABody_isFound_includingCRLFAndHTMLDoubleSpaces() async throws {
        try await indexBodies([
            "Wrapped LF": ("The members agreed the quorum\nclause applies to every meeting.", ""),
            "Wrapped CRLF": ("The members agreed the quorum\r\nclause applies.", ""),
            "Wrapped indent": ("> the quorum\n>   clause", ""),
            "HTML": ("", "<p>the <b>quorum</b>&nbsp;<i>clause</i></p>"),
            "Scattered": ("quorum is reached; this clause is separate", ""),
        ])
        let phrase = try await subjects(SearchCondition(.body, .phrase, "quorum clause"))
        XCTAssertEqual(phrase, ["Wrapped LF", "Wrapped CRLF", "HTML"], "a line wrap or a double space is one space; '>' quoting is text")
        let anywhere = try await subjects(SearchCondition(.anyText, .phrase, "the quorum clause"))
        XCTAssertEqual(anywhere, ["Wrapped LF", "Wrapped CRLF", "HTML"], "the HTML's tags left double spaces")
        let contains = try await subjects(SearchCondition(.body, .contains, "agreed the quorum cl"))
        XCTAssertEqual(contains, ["Wrapped LF", "Wrapped CRLF"])
        let all = try await subjects(SearchCondition(.body, .allWords, "quorum clause"))
        XCTAssertEqual(all, ["Wrapped LF", "Wrapped CRLF", "Wrapped indent", "HTML", "Scattered"], "all words unchanged")
    }

    @MainActor
    func testFIND08_wrappedPhraseInAnAttachment_isFound_textPDFAndDOCX_tableRowsAndCellsAreNot() async throws {
        let pdfWrapped = try pdf(lines: [["the members agreed the quorum", "clause applies"]])
        XCTAssertTrue(pdfWrapped.contains("quorum") && pdfWrapped.contains("clause"), pdfWrapped)
        let docxWrapped = try docx("<w:p><w:r><w:t>the quorum</w:t><w:br/><w:t>clause applies</w:t></w:r></w:p>")
        let docxParagraphs = try docx("<w:p><w:r><w:t>agreed the quorum</w:t></w:r></w:p><w:p><w:r><w:t>clause applies</w:t></w:r></w:p>")
        let docxTableRows = try docx("""
            <w:tbl><w:tr><w:tc><w:p><w:r><w:t>minutes</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>quorum</w:t></w:r></w:p></w:tc></w:tr>\
            <w:tr><w:tc><w:p><w:r><w:t>clause</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>agenda</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
            """)
        let docxTableCells = try docx("<w:tbl><w:tr><w:tc><w:p><w:r><w:t>quorum</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>clause</w:t></w:r></w:p></w:tc></w:tr></w:tbl>")
        try await index(["TXT wrapped": "the quorum\nclause applies", "TXT double space": "the  quorum \t clause"], filename: "notes.txt")
        try await index(["PDF wrapped": pdfWrapped], filename: "minutes.pdf")
        try await index(["DOCX wrapped": docxWrapped, "DOCX paragraphs": docxParagraphs,
                         "DOCX table rows": docxTableRows, "DOCX table cells": docxTableCells], filename: "minutes.docx")

        let phrase = try await found(.phrase, "quorum clause")
        XCTAssertEqual(phrase, ["TXT wrapped", "TXT double space", "PDF wrapped", "DOCX wrapped", "DOCX paragraphs"],
                       "wraps are found (PDF \(pdfWrapped.debugDescription)); DOCX table rows \(docxTableRows.debugDescription) and cells \(docxTableCells.debugDescription) are not joined")
        let all = try await found(.allWords, "quorum clause")
        XCTAssertEqual(all, ["TXT wrapped", "TXT double space", "PDF wrapped", "DOCX wrapped", "DOCX paragraphs", "DOCX table rows", "DOCX table cells"])
    }

    @MainActor
    func testFIND08_bodyPhraseAcrossTheChunkJoinWithANewline_isFound() async throws {
        let body = Self.acrossTheJoin("agreed quorum\n", then: "clause applies")
        XCTAssertTrue(SearchChunker.chunks(of: body)[0].hasSuffix("agreed quorum\n"), "the join falls right after the wrap")
        try await indexBodies(["Body across join": (body, ""), "Other": ("agreed quorum elsewhere; clause applies apart", "")])
        let maybeID = try await idOf("Body across join")
        let id = try XCTUnwrap(maybeID)
        let stored = try await store.searchChunks(emailID: id, kind: .body, ordinal: 0)
        XCTAssertGreaterThan(stored.count, 1)
        XCTAssertTrue(stored[0].hasSuffix("quorum\n") && stored[1].hasPrefix("clause applies"), "the phrase is split between chunk 0 and chunk 1")
        let phrase = try await subjects(SearchCondition(.body, .phrase, "agreed quorum clause applies"))
        XCTAssertEqual(phrase, ["Body across join"], "a wrapped phrase across two chunks is found on the join")
        let contains = try await subjects(SearchCondition(.anyText, .contains, "quorum clause appl"))
        XCTAssertEqual(contains, ["Body across join"])
    }

    @MainActor
    func testFIND08_attachmentAcrossTheChunkJoin_wrapsInTextButNeverAcrossARowOrSheet() async throws {
        let wrapped = Self.acrossTheJoin("agreed quorum\n", then: "clause applies")
        let sheet = Self.acrossTheJoin("agreed quorum\n", then: "[Sheet: Two]\nclause applies")
        try await index(["Sheet across join": sheet, "Rows across join": wrapped], filename: "book.xlsx")
        let rows = try await found(.phrase, "quorum clause")
        XCTAssertEqual(rows, [], "in a spreadsheet every line is a row: the join never makes a phrase across rows or sheets")
        let inside = try await found(.phrase, "agreed quorum")
        XCTAssertEqual(inside, ["Sheet across join", "Rows across join"])
        try await index(["Text across join": wrapped], filename: "long.txt")
        let maybeID = try await idOf("Text across join")
        let id = try XCTUnwrap(maybeID)
        let stored = try await store.searchChunks(emailID: id, kind: .attachmentText, ordinal: 0)
        XCTAssertTrue(stored.count > 1 && stored[0].hasSuffix("quorum\n"), "split at the wrap")
        let text = try await found(.phrase, "agreed quorum clause applies")
        XCTAssertEqual(text, ["Text across join"], "a plain-text attachment wraps across the join")
    }

    @MainActor
    func testFIND08_punctuationAndSQLLookingLiteralsStayLiteral() async throws {
        try await indexBodies([
            "Invoice": ("Reference PO-4471 for O'Brien;\nDROP TABLE emails;-- 100% done (see_also)", ""),
            "Spaced": ("Reference PO 4471 for OBrien DROP TABLE emails 100x done seeXalso", ""),
        ])
        let hyphen = try await subjects(SearchCondition(.body, .phrase, "PO-4471"))
        XCTAssertEqual(hyphen, ["Invoice"], "punctuation the tokeniser drops is still required")
        let sql = try await subjects(SearchCondition(.body, .contains, "O'Brien; DROP TABLE emails;--"))
        XCTAssertEqual(sql, ["Invoice"], "quotes and SQL are text, across the wrap")
        let percent = try await subjects(SearchCondition(.body, .contains, "100% done"))
        XCTAssertEqual(percent, ["Invoice"], "% is not a wildcard")
        let underscore = try await subjects(SearchCondition(.body, .contains, "see_also"))
        XCTAssertEqual(underscore, ["Invoice"], "_ is not a wildcard")
        let spaced = try await subjects(SearchCondition(.body, .phrase, "PO 4471"))
        XCTAssertEqual(spaced, ["Spaced"], "a space does not match a hyphen")
        let symbols = try await subjects(SearchCondition(.body, .contains, "-- 100%"))
        XCTAssertEqual(symbols, ["Invoice"])
        let all = try await subjects(SearchCondition(.body, .allWords, "Reference"))
        XCTAssertEqual(all, ["Invoice", "Spaced"], "nothing was executed")
    }

    func testFIND08_matcherRule() {
        XCTAssertTrue(SectionBoundary.contains("quorum\nclause", literal: "quorum clause"))
        XCTAssertTrue(SectionBoundary.contains("QUORUM \r\n\t clause", literal: "quorum  CLAUSE"))
        XCTAssertTrue(SectionBoundary.contains("quorum\u{00A0}clause", literal: "quorum clause"), "NBSP")
        XCTAssertTrue(SectionBoundary.contains("quorum\u{2028}clause", literal: "quorum\nclause"))
        XCTAssertFalse(SectionBoundary.contains("quorum\t\u{1E}clause", literal: "quorum clause"), "a boundary is never crossed")
        XCTAssertFalse(SectionBoundary.contains("quorum\u{1E}clause", literal: "quorum clause"))
        XCTAssertTrue(SectionBoundary.contains("quorum\t\u{1E}clause", literal: "clause"))
        XCTAssertFalse(SectionBoundary.contains("quorumclause", literal: "quorum clause"), "whitespace is required where the literal has it")
        XCTAssertFalse(SectionBoundary.contains("C+ +", literal: "C++"))
        XCTAssertTrue(SectionBoundary.contains("été QUORUM", literal: "été quorum"))
        // Marking: cells, rows, labels; prose paragraphs stay crossable.
        let sheet = SectionBoundary.marked("[Sheet: A]\nA1: x\tB1: y\nA2: z\n", layout: .records)
        XCTAssertEqual(sheet, "[Sheet: A]\n\u{1E}A1: x\t\u{1E}B1: y\n\u{1E}A2: z\n\u{1E}")
        XCTAssertEqual(SectionBoundary.marked(sheet, layout: .records), sheet, "idempotent")
        let prose = SectionBoundary.marked("[Document]\nthe quorum\nclause\ncell\tcell\nafter", layout: .prose)
        XCTAssertEqual(prose, "[Document]\n\u{1E}the quorum\nclause\n\u{1E}cell\t\u{1E}cell\n\u{1E}after")
        XCTAssertEqual(SectionBoundary.marked("a\r\nb", layout: .records), "a\r\n\u{1E}b", "CRLF lines are lines")
        XCTAssertEqual(SectionBoundary.marked("a\tb\nc", layout: .none), "a\tb\nc")
        XCTAssertEqual(SectionBoundary.hidden(sheet), "[Sheet: A]\nA1: x\tB1: y\nA2: z\n")
        XCTAssertEqual(SectionBoundary.layout(filename: "a.xlsx"), .records)
        XCTAssertEqual(SectionBoundary.layout(filename: "a.docx"), .prose)
        XCTAssertEqual(SectionBoundary.layout(filename: "a.txt"), .none)
        XCTAssertEqual(SectionBoundary.layout(filename: "inner", recordedKind: "ods"), .records)
    }

    @MainActor
    func testFIND08_evidenceExcerptAndShowText_followTheRule_andHideBoundaries() async throws {
        let split = try xlsx([["quorum", "clause"]])
        try await index(["Sheet": split], filename: "votes.xlsx")
        try await index(["Wrapped": "minutes say the quorum\nclause applies"], filename: "minutes.txt")
        let maybeSheet = try await idOf("Sheet"), maybeWrapped = try await idOf("Wrapped")
        let sheetID = try XCTUnwrap(maybeSheet), wrappedID = try XCTUnwrap(maybeWrapped)
        let maybeShown = try await store.attachmentDocumentText(emailID: sheetID, ordinal: 0)
        let shown = try XCTUnwrap(maybeShown)
        XCTAssertFalse(shown.contains("\u{1E}"), "Show text hides the boundary")
        XCTAssertEqual(shown, split, "Show text is the extracted text")
        let stored = try await store.searchChunks(emailID: sheetID, kind: .attachmentText, ordinal: 0).joined()
        XCTAssertTrue(stored.contains("\u{1E}"), "the index holds the boundary: \(stored.debugDescription)")

        let spec = SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.anyText, .phrase, "quorum clause")])])
        let evidence = try await archive.matchEvidence(emailID: wrappedID, spec: spec, freeText: nil)
        let excerpt = try XCTUnwrap(evidence.first?.excerpt, "\(evidence)")
        let mark = try XCTUnwrap(excerpt.marks.first)
        let marked = (excerpt.text as NSString).substring(with: NSRange(location: mark.lowerBound, length: mark.count))
        XCTAssertEqual(marked, "quorum clause", "the whole wrapped phrase is marked (newline shown as a space)")

        let cellEvidence = try await archive.matchEvidence(emailID: sheetID, spec: SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.anyText, .allWords, "quorum clause")])]), freeText: nil)
        XCTAssertFalse(cellEvidence.compactMap(\.excerpt).isEmpty, "\(cellEvidence)")
        for e in cellEvidence {
            guard let x = e.excerpt else { continue }
            XCTAssertFalse(x.text.contains("\u{1E}"), "excerpts hide the boundary")
            for m in x.marks {
                let word = (x.text as NSString).substring(with: NSRange(location: m.lowerBound, length: m.count))
                XCTAssertTrue(["quorum", "clause"].contains(word.lowercased()), "marks move with the hidden boundaries: \(word)")
            }
        }
    }

    /// Perf: the matcher runs on the FTS candidates only; a 5 MB hard-wrapped
    /// body with a wrapped phrase across the first chunk join, as in testFIND07.
    @MainActor
    func testFIND08_fiveMegabyteBody_wrappedPhraseAcrossTheJoin_isFoundQuickly() async throws {
        let filler = String(repeating: "lorem ipsum dolor sit amet\n", count: 190_000)   // ~5.1 M characters, hard-wrapped
        let tail = "zephyr quantum\n"
        let body = String(filler.prefix(SearchChunker.chunkCharacters - tail.count - 1)) + "\n" + tail + "ledger\n" + filler
        XCTAssertTrue(SearchChunker.chunks(of: body)[0].hasSuffix(tail), "the phrase really crosses the first join")
        try await indexBodies(["Long": (body, ""), "Short": ("zephyr elsewhere, quantum apart, ledger alone", "")])
        let started = Date()
        let phrase = try await subjects(SearchCondition(.body, .phrase, "zephyr quantum ledger"))
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(phrase, ["Long"])
        let everyStarted = Date()
        let every = try await subjects(SearchCondition(.body, .phrase, "sit amet lorem ipsum"))
        let everyElapsed = Date().timeIntervalSince(everyStarted)
        XCTAssertEqual(every, ["Long"])
        let longLiteral = (0..<2_200).map { _ in "lorem ipsum dolor sit amet" }.joined(separator: " ")   // > one chunk: the whole-document form
        let longStarted = Date()
        let long = try await subjects(SearchCondition(.body, .phrase, longLiteral))
        let longElapsed = Date().timeIntervalSince(longStarted)
        XCTAssertEqual(long, ["Long"])
        let allStarted = Date()
        let all = try await subjects(SearchCondition(.body, .allWords, "zephyr quantum ledger"))
        let allElapsed = Date().timeIntervalSince(allStarted)
        XCTAssertEqual(all, ["Long", "Short"])
        print("FIND-08 perf: phrase across the join \(String(format: "%.3f", elapsed)) s; phrase in every chunk \(String(format: "%.3f", everyElapsed)) s; literal longer than a chunk \(String(format: "%.3f", longElapsed)) s; all words \(String(format: "%.3f", allElapsed)) s")
        XCTAssertLessThan(elapsed, 5, "phrase verification on candidates only")
    }
}
