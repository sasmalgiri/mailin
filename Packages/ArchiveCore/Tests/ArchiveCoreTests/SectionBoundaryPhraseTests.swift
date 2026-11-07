//
//  SectionBoundaryPhraseTests.swift
//  ArchiveCoreTests
//
//  Plan v4 §13.3 row 6: "no false phrases across cells / sections / files".
//  Files are separate `childText` documents (WP2). Inside ONE document the
//  extractors write every cell, row, slide, sheet and page with a separator
//  that is never a single space (tab between cells, a newline between rows
//  and paragraphs, a "[Slide n]" / "[Sheet: …]" label line between
//  sections, a newline between PDF pages), and the chunk index verifies a
//  phrase on the stored text with whitespace exact (`literalClause`: the
//  collapsed literal must occur as written). So a phrase never joins the
//  last word of one cell/slide/page to the first word of the next, while
//  "all words" still treats the whole document as one unit.
//
//  These tests run the REAL extractors (XLSX, ODS, PPTX, ODP, and PDFKit's
//  document string, which is what the app's attachment job indexes for a
//  PDF), index their output as attachment documents, and search through
//  `EmailQuery.spec` exactly as the app does.
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
    /// attachment job reads a text-layer PDF (`PDFDocument.string`).
    private func pdf(_ pages: [String]) throws -> String {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        for text in pages {
            context.beginPDFPage(nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
            context.textPosition = CGPoint(x: 20, y: 150)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        let document = try XCTUnwrap(PDFDocument(data: data as Data))
        XCTAssertEqual(document.pageCount, pages.count)
        return try XCTUnwrap(document.string)
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
}
