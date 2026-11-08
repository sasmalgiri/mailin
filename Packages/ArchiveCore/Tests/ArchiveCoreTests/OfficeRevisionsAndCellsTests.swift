//
//  OfficeRevisionsAndCellsTests.swift
//  ArchiveCoreTests
//
//  Directive 2026-11-07 §6, rows "Word" and "Excel/XLSB".
//
//  Word: moved text, formatting revisions, revisions in headers / footers /
//  footnotes / endnotes / comments / text boxes, author and date on the
//  marker, deleted paragraph marks — each located (part, paragraph).
//  Excel: cached value vs formula vs displayed value, shared formulas
//  re-based, date serials rendered, hidden rows / columns / sheets / names,
//  external references never refreshed; XLSB formulas decoded from tokens.
//
//  Synthetic packages are built here; the real public files (Tika, POI,
//  the owner's public pack) are read by path when the checkout has them.
//

import XCTest
@testable import ArchiveCore

final class OfficeRevisionsAndCellsTests: XCTestCase {

    // MARK: - Package helpers (same shape as the app tests' zipPackage / biff12)

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

    /// A stored (uncompressed) ZIP with correct CRCs — an Office package is one.
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

    /// A BIFF12 (xlsb) record: type and size as 7-bit groups, then the payload.
    private static func biff12(_ type: Int, _ payload: Data) -> Data {
        var out = Data()
        var t = type
        repeat { var b = UInt8(t & 0x7F); t >>= 7; if t > 0 { b |= 0x80 }; out.append(b) } while t > 0
        var n = payload.count
        repeat { var b = UInt8(n & 0x7F); n >>= 7; if n > 0 { b |= 0x80 }; out.append(b) } while n > 0
        out.append(payload)
        return out
    }
    private static func le16(_ v: Int) -> Data { Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }
    private static func le32(_ v: Int) -> Data { let u = UInt32(truncatingIfNeeded: v); return Data((0..<4).map { UInt8((u >> (8 * $0)) & 0xFF) }) }
    /// Concatenation without a long chain of `+` (which the type-checker struggles with).
    private static func cat(_ parts: Data...) -> Data { parts.reduce(into: Data()) { $0.append($1) } }
    private static func bytes(_ values: UInt8...) -> Data { Data(values) }
    private static func f64(_ v: Double) -> Data { var bits = v.bitPattern; var d = Data(); for _ in 0..<8 { d.append(UInt8(bits & 0xFF)); bits >>= 8 }; return d }
    /// An XLWideString: cch then UTF-16LE.
    private static func xlString(_ s: String) -> Data { le32(s.utf16.count) + s.data(using: .utf16LittleEndian)! }

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("office-rev-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ name: String, _ data: Data) throws -> URL {
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private static let w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

    private func docx(body: String, extraParts: [(String, Data)] = []) -> Data {
        var members: [(String, Data)] = [("word/document.xml", Data("<w:document xmlns:w=\"\(Self.w)\" xmlns:mc=\"http://schemas.openxmlformats.org/markup-compatibility/2006\"><w:body>\(body)</w:body></w:document>".utf8))]
        members += extraParts
        return Self.zipPackage(members)
    }

    private func fixtures(_ relative: String) -> URL? {
        // Tests/ArchiveCoreTests/<file> → Packages/ArchiveCore → the repository root.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url = url.deletingLastPathComponent() }
        url = url.appendingPathComponent("maxmailinTests/Fixtures/opensource").appendingPathComponent(relative)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Word: moved text

    func testWord_movedText_isLabelledMovedFromAndMovedTo_neverAsInsertionOrDeletion() throws {
        let body = """
        <w:p><w:r><w:t>Alpha </w:t></w:r><w:moveFromRangeStart w:id="10" w:name="move1" w:author="Kyle" w:date="2025-06-26T14:17:23Z"/>
        <w:moveFrom w:id="6" w:author="Kyle" w:date="2025-06-26T14:17:23Z"><w:r><w:t>ad litora</w:t></w:r></w:moveFrom><w:moveFromRangeEnd w:id="10"/>
        <w:r><w:t> omega.</w:t></w:r></w:p>
        <w:p><w:moveToRangeStart w:id="11" w:name="move1" w:author="Kyle" w:date="2025-06-26T14:17:23Z"/>
        <w:moveTo w:id="3" w:author="Kyle" w:date="2025-06-26T14:17:23Z"><w:r><w:t>ad litora</w:t></w:r></w:moveTo><w:moveToRangeEnd w:id="11"/>
        <w:r><w:t> now here.</w:t></w:r></w:p>
        """
        let result = try OfficeTextExtractor.extract(fileURL: try write("m.docx", docx(body: body)), kind: .docx)
        XCTAssertTrue(result.text.contains("Alpha {moved from by Kyle 2025-06-26: ad litora} omega.\n"), result.text)
        XCTAssertTrue(result.text.contains("{moved to by Kyle 2025-06-26: ad litora} now here.\n"), result.text)
        XCTAssertFalse(result.text.contains("{inserted") || result.text.contains("{deleted"), "a move is not an insertion or a deletion: \(result.text)")
        XCTAssertEqual(result.revisions.map(\.kind), [.movedFrom, .movedTo])
        XCTAssertEqual(result.revisions.map(\.text), ["ad litora", "ad litora"])
        XCTAssertEqual(result.revisions.map(\.paragraph), [1, 2])
        XCTAssertEqual(result.revisions.map(\.part), ["body", "body"])
        XCTAssertEqual(result.revisions.map(\.id), ["6", "3"])
        XCTAssertEqual(result.components, ["Document"])
    }

    // MARK: - Word: formatting revisions

    func testWord_formattingRevisions_areMarkedOnce_textNotDuplicated() throws {
        let body = """
        <w:p><w:pPr><w:jc w:val="center"/><w:pPrChange w:id="1" w:author="Ann" w:date="2025-01-15T09:00:00Z"><w:pPr><w:jc w:val="left"/></w:pPr></w:pPrChange></w:pPr>
        <w:r><w:rPr><w:b/><w:rPrChange w:id="2" w:author="Ann" w:date="2025-01-15T09:01:00Z"><w:rPr><w:i/></w:rPr></w:rPrChange></w:rPr><w:t>Bold now</w:t></w:r>
        <w:r><w:t> plain</w:t></w:r></w:p>
        <w:tbl><w:tblPr><w:tblPrChange w:id="3" w:author="Bo"><w:tblPr><w:tblW w:w="0"/></w:tblPr></w:tblPrChange></w:tblPr>
        <w:tr><w:tc><w:p><w:r><w:t>cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
        <w:sectPr><w:sectPrChange w:id="4" w:author="Ann" w:date="2025-01-16T09:00:00Z"><w:sectPr><w:pgSz w:w="1" w:h="2"/></w:sectPr></w:sectPrChange></w:sectPr>
        """
        let result = try OfficeTextExtractor.extract(fileURL: try write("f.docx", docx(body: body)), kind: .docx)
        XCTAssertTrue(result.text.contains("{formatting changed by Ann 2025-01-15}{formatting changed by Ann 2025-01-15}Bold now plain\n"), result.text)
        XCTAssertTrue(result.text.contains("{formatting changed by Bo}cell"), result.text)
        XCTAssertTrue(result.text.contains("{formatting changed by Ann 2025-01-16}"), result.text)
        XCTAssertEqual(result.text.components(separatedBy: "Bold now").count - 1, 1, "the text stays in the stream once")
        XCTAssertEqual(result.revisions.map(\.kind), Array(repeating: .formattingChanged, count: 4))
        XCTAssertEqual(result.revisions.map(\.id), ["1", "2", "3", "4"])
        XCTAssertEqual(result.revisions.map(\.paragraph), [1, 1, 1, 2], "the table change sits before the cell's paragraph; the section change after it")
        XCTAssertTrue(result.revisions.allSatisfy { $0.text.isEmpty })
    }

    // MARK: - Word: revisions in headers, footers, footnotes, endnotes, comments

    func testWord_revisionsInHeaderFooterFootnoteEndnoteComment_areLocatedByPart() throws {
        func part(_ rootElement: String, _ inner: String) -> Data {
            Data("<w:\(rootElement) xmlns:w=\"\(Self.w)\">\(inner)</w:\(rootElement)>".utf8)
        }
        let package = docx(body: "<w:p><w:r><w:t>Body only.</w:t></w:r></w:p>", extraParts: [
            ("word/header1.xml", part("hdr", "<w:p><w:r><w:t>Draft </w:t></w:r><w:ins w:id=\"1\" w:author=\"Ann\" w:date=\"2025-01-15T09:00:00Z\"><w:r><w:t>v2</w:t></w:r></w:ins></w:p>")),
            ("word/footer2.xml", part("ftr", "<w:p><w:r><w:t>Page</w:t></w:r></w:p><w:p><w:del w:id=\"2\" w:author=\"Bo\"><w:r><w:delText>old footer</w:delText></w:r></w:del></w:p>")),
            ("word/footnotes.xml", part("footnotes", "<w:footnote w:type=\"separator\" w:id=\"-1\"><w:p><w:r><w:separator/></w:r></w:p></w:footnote><w:footnote w:id=\"1\"><w:p><w:r><w:t>Source </w:t></w:r><w:del w:id=\"3\" w:author=\"Ann\" w:date=\"2025-01-15T10:00:00Z\"><w:r><w:delText>withdrawn</w:delText></w:r></w:del></w:p></w:footnote>")),
            ("word/endnotes.xml", part("endnotes", "<w:endnote w:id=\"1\"><w:p><w:r><w:t>Note one.</w:t></w:r></w:p><w:p><w:moveTo w:id=\"4\" w:author=\"Cy\"><w:r><w:t>moved here</w:t></w:r></w:moveTo></w:p></w:endnote>")),
            ("word/comments.xml", part("comments", "<w:comment w:id=\"7\" w:author=\"Di\"><w:p><w:r><w:t>Please </w:t></w:r><w:ins w:id=\"5\" w:author=\"Di\"><w:r><w:t>reconsider</w:t></w:r></w:ins></w:p></w:comment>")),
        ])
        let result = try OfficeTextExtractor.extract(fileURL: try write("h.docx", package), kind: .docx)
        XCTAssertEqual(result.components, ["Document", "Header", "Footer", "Footnotes", "Endnotes", "Comments"])
        XCTAssertTrue(result.text.contains("[Header]\nDraft {inserted by Ann 2025-01-15: v2}\n"), result.text)
        XCTAssertTrue(result.text.contains("[Footer]\nPage\n{deleted by Bo: old footer}\n"), result.text)
        XCTAssertTrue(result.text.contains("[Footnotes]\n\nSource {deleted by Ann 2025-01-15: withdrawn}\n"), result.text)
        XCTAssertTrue(result.text.contains("[Endnotes]\nNote one.\n{moved to by Cy: moved here}\n"), result.text)
        XCTAssertTrue(result.text.contains("[Comments]\nPlease {inserted by Di: reconsider}\n"), result.text)
        let located = result.revisions.map { "\($0.kind.rawValue)|\($0.part)|¶\($0.paragraph)|\($0.text)" }
        XCTAssertEqual(located, ["inserted|header 1|¶1|v2", "deleted|footer 2|¶2|old footer", "deleted|footnote 1|¶1|withdrawn",
                                 "moved to|endnote 1|¶2|moved here", "inserted|comment 7|¶1|reconsider"])
    }

    // MARK: - Word: author and date on the marker

    func testWord_authorAndDate_appendedToMarker_omittedWhenAbsent() throws {
        let body = """
        <w:p><w:r><w:t>The quick </w:t></w:r><w:del w:id="0" w:author="Ann" w:date="2025-01-15T20:59:00Z"><w:r><w:delText>brown </w:delText></w:r></w:del>
        <w:ins w:id="1" w:author="Ann" w:date="2025-01-15T20:59:00Z"><w:r><w:t>red </w:t></w:r></w:ins><w:r><w:t>fox</w:t></w:r></w:p>
        <w:p><w:ins w:id="2"><w:r><w:t>no author</w:t></w:r></w:ins><w:del w:id="3" w:date="2025-02-01T00:00:00Z"><w:r><w:delText>date only</w:delText></w:r></w:del>
        <w:del w:id="4" w:author="Bo"><w:r><w:delText>author only</w:delText></w:r></w:del></w:p>
        """
        let result = try OfficeTextExtractor.extract(fileURL: try write("a.docx", docx(body: body)), kind: .docx)
        XCTAssertTrue(result.text.contains("The quick {deleted by Ann 2025-01-15: brown }{inserted by Ann 2025-01-15: red }fox\n"), result.text)
        XCTAssertTrue(result.text.contains("{inserted: no author}{deleted 2025-02-01: date only}{deleted by Bo: author only}\n"), result.text)
        XCTAssertEqual(result.revisions.map(\.author), ["Ann", "Ann", nil, nil, "Bo"])
        XCTAssertEqual(result.revisions.map(\.date), ["2025-01-15T20:59:00Z", "2025-01-15T20:59:00Z", nil, "2025-02-01T00:00:00Z", nil])
        XCTAssertEqual(OfficeTextExtractor.revisionDay("2025-01-15T20:59:00Z"), "2025-01-15")
        XCTAssertEqual(OfficeTextExtractor.revisionDay("yesterday"), "yesterday")
    }

    // MARK: - Word: deleted paragraph marks

    func testWord_deletedParagraphMark_isReportedNotSilentlyMerged() throws {
        let body = """
        <w:p><w:pPr><w:rPr><w:del w:id="1" w:author="Ann" w:date="2025-01-15T09:00:00Z"/></w:rPr></w:pPr><w:r><w:t>First paragraph</w:t></w:r></w:p>
        <w:p><w:pPr><w:rPr><w:ins w:id="2" w:author="Bo"/></w:rPr></w:pPr><w:r><w:t>Second paragraph</w:t></w:r></w:p>
        <w:p><w:r><w:t>Third paragraph</w:t></w:r></w:p>
        """
        let result = try OfficeTextExtractor.extract(fileURL: try write("p.docx", docx(body: body)), kind: .docx)
        XCTAssertTrue(result.text.contains("First paragraph{paragraph mark deleted by Ann 2025-01-15}\nSecond paragraph{paragraph mark inserted by Bo}\nThird paragraph\n"), result.text)
        XCTAssertFalse(result.text.contains("{inserted: }") || result.text.contains("{deleted: }"), "a mark revision is not an empty text revision: \(result.text)")
        XCTAssertEqual(result.revisions.map(\.kind), [.paragraphMarkDeleted, .paragraphMarkInserted])
        XCTAssertEqual(result.revisions.map(\.paragraph), [1, 2])
    }

    // MARK: - Word: text boxes and table rows

    func testWord_revisionInsideTextBox_andTableRowRevision_areLocated() throws {
        let body = """
        <w:p><w:r><w:t>Before box</w:t></w:r></w:p>
        <w:p><w:r><w:drawing><w:txbxContent><w:p><w:r><w:t>Box line one</w:t></w:r></w:p><w:p><w:del w:id="1" w:author="Ann"><w:r><w:delText>boxed cut</w:delText></w:r></w:del></w:p></w:txbxContent></w:drawing></w:r></w:p>
        <w:tbl><w:tr><w:trPr><w:ins w:id="2" w:author="Bo"/></w:trPr><w:tc><w:p><w:r><w:t>new row cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
        """
        let result = try OfficeTextExtractor.extract(fileURL: try write("t.docx", docx(body: body)), kind: .docx)
        XCTAssertTrue(result.text.contains("[Text box] Box line one\n{deleted by Ann: boxed cut}\n"), result.text)
        XCTAssertTrue(result.text.contains("{table row inserted by Bo}new row cell"), result.text)
        XCTAssertEqual(result.revisions.map { "\($0.kind.rawValue)|\($0.part)|¶\($0.paragraph)" }, ["deleted|text box in body|¶2", "table row inserted|body|¶2"],
                       "the row revision sits in the row's properties, before the cell's paragraph (¶3) opens")
    }

    // MARK: - Word: real files

    func testWord_publicPack_W0x_structuredExpectationsMatch() throws {
        guard let pack = fixtures("public-pack") else { throw XCTSkip("public-pack fixtures not in this checkout") }
        let expectedData = try Data(contentsOf: pack.appendingPathComponent("expected_results.json"))
        let expected = try XCTUnwrap(try JSONSerialization.jsonObject(with: expectedData) as? [String: Any])
        let word = try XCTUnwrap(expected["word"] as? [[String: Any]])
        XCTAssertEqual(word.count, 4)
        for entry in word {
            let path = try XCTUnwrap(entry["path"] as? String)
            let revisions = try XCTUnwrap(entry["revisions"] as? [[String: Any]])
            let result = try OfficeTextExtractor.extract(fileURL: pack.appendingPathComponent(path), kind: .docx)
            XCTAssertEqual(result.revisions.count, revisions.count, "\(path): \(result.revisions)")
            for want in revisions {
                let id = want["id"] as? String
                let kind: OfficeTextExtractor.Revision.Kind = (want["kind"] as? String) == "ins" ? .inserted : .deleted
                guard let got = result.revisions.first(where: { $0.id == id && $0.kind == kind }) else {
                    XCTFail("\(path): no \(kind.rawValue) revision with id \(id ?? "?") — \(result.revisions)"); continue
                }
                XCTAssertEqual(got.text, want["text"] as? String, path)
                XCTAssertEqual(got.author, want["author"] as? String, path)
                XCTAssertEqual(got.date, want["date"] as? String, path)
                XCTAssertEqual(got.part, "body", path)
                XCTAssertEqual(got.paragraph, 1, path)
            }
            if revisions.isEmpty {
                XCTAssertFalse(result.text.contains("{inserted") || result.text.contains("{deleted"), "\(path): accepted/rejected documents carry no markers")
            }
        }
        let w05 = try OfficeTextExtractor.extract(fileURL: pack.appendingPathComponent("03_word/W05_tracked_retained.docx"), kind: .docx)
        XCTAssertTrue(w05.text.contains("The quick {deleted by Thabang Kubheka 2026-09-28: brown }{inserted by Thabang Kubheka 2026-09-28: red}{inserted by Thabang Kubheka 2026-09-28:  }fox jumps over the dog."), w05.text)
    }

    func testWord_tikaFeatures_realMovesInsertionsDeletions_andWordPartsWalked() throws {
        guard let tika = fixtures("tika") else { throw XCTSkip("tika fixtures not in this checkout") }
        let features = try OfficeTextExtractor.extract(fileURL: tika.appendingPathComponent("testWORD_features.docx"), kind: .docx)
        let byKind = Dictionary(grouping: features.revisions, by: \.kind).mapValues(\.count)
        XCTAssertEqual(byKind[.inserted], 3, "\(features.revisions)")
        XCTAssertEqual(byKind[.deleted], 2)
        XCTAssertEqual(byKind[.movedFrom], 1)
        XCTAssertEqual(byKind[.movedTo], 1)
        let moves = features.revisions.filter { $0.kind == .movedFrom || $0.kind == .movedTo }
        XCTAssertEqual(Set(moves.map(\.text)), ["ad litora"])
        XCTAssertEqual(Set(moves.map(\.author)), ["Kyle Reese"])
        XCTAssertEqual(Set(moves.map(\.date)), ["2025-06-26T14:17:23Z"])
        XCTAssertTrue(features.text.contains("{moved to by Kyle Reese 2025-06-26: ad litora}") && features.text.contains("{moved from by Kyle Reese 2025-06-26: ad litora}"), features.text)
        XCTAssertTrue(features.text.contains("{deleted by Unknown Author 2025-06-26: bibendum }") && features.text.contains("{inserted by Unknown Author 2025-06-26: insert this }"), features.text)
        XCTAssertTrue(features.revisions.allSatisfy { $0.part == "body" && $0.paragraph >= 1 })
        XCTAssertTrue(features.components.contains("Comments"))

        // testWORD.docx: header and footer parts are walked with the body's collector (no revisions in it); its
        // footnotes.xml / endnotes.xml hold only the separators, so no Footnotes / Endnotes component is claimed.
        let plain = try OfficeTextExtractor.extract(fileURL: tika.appendingPathComponent("testWORD.docx"), kind: .docx)
        XCTAssertEqual(plain.components, ["Document", "Header", "Footer"])
        XCTAssertEqual(plain.revisions, [])
    }

    // MARK: - Excel (XLSX): formulas

    private func xlsx(sheetXML: String, styles: String? = nil, workbookExtra: String = "", sharedStrings: [String] = [], extraParts: [(String, Data)] = []) -> Data {
        var members: [(String, Data)] = [
            ("xl/workbook.xml", Data("<workbook xmlns:r=\"r\">\(workbookExtra)<sheets><sheet name=\"Data\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>".utf8)),
            ("xl/_rels/workbook.xml.rels", Data("<Relationships><Relationship Id=\"rId1\" Type=\"x\" Target=\"worksheets/sheet1.xml\"/></Relationships>".utf8)),
            ("xl/worksheets/sheet1.xml", Data("<worksheet>\(sheetXML)</worksheet>".utf8)),
        ]
        if let styles { members.append(("xl/styles.xml", Data("<styleSheet>\(styles)</styleSheet>".utf8))) }
        if !sharedStrings.isEmpty { members.append(("xl/sharedStrings.xml", Data(("<sst>" + sharedStrings.map { "<si><t>\($0)</t></si>" }.joined() + "</sst>").utf8))) }
        members += extraParts
        return Self.zipPackage(members)
    }

    func testXLSX_cachedValueAndFormula_sharedFormulasRebased_anchorsKept_unshiftableNamed() throws {
        let sheet = """
        <sheetData>
        <row r="1"><c r="A1"><v>42</v></c><c r="B1"><f>SUM(B2:B4)</f><v>6</v></c><c r="C1" t="str"><f>"x"&amp;A1</f><v>x42</v></c></row>
        <row r="2"><c r="A2"><f t="shared" ref="A2:A4" si="0">B2*$C$1+Data!B2+LOG10(B2)+B:B+2:2</f><v>1</v></c><c r="B2"><v>1</v></c></row>
        <row r="3"><c r="A3"><f t="shared" si="0"/><v>2</v></c><c r="B3"><v>2</v></c></row>
        <row r="4"><c r="A4"><f t="shared" si="0"/><v>3</v></c><c r="B4"><v>3</v></c><c r="D4"><f t="shared" ref="D4:D5" si="1">A1-1</f><v>41</v></c></row>
        <row r="5"><c r="D5"><f t="shared" si="1"/><v>0</v></c><c r="E5"><f t="shared" si="9"/><v>0</v></c></row>
        </sheetData>
        """
        let result = try OfficeTextExtractor.extract(fileURL: try write("f.xlsx", xlsx(sheetXML: sheet)), kind: .xlsx)
        XCTAssertTrue(result.text.contains("A1: 42\tB1: 6 (formula =SUM(B2:B4))\tC1: x42 (formula =\"x\"&A1)\n"), result.text)
        XCTAssertTrue(result.text.contains("A2: 1 (formula =B2*$C$1+Data!B2+LOG10(B2)+B:B+2:2)\tB2: 1\n"), result.text)
        XCTAssertTrue(result.text.contains("A3: 2 (formula =B3*$C$1+Data!B3+LOG10(B3)+B:B+3:3)\tB3: 2\n"), "relative parts move, anchors stay, LOG10 is a function: \(result.text)")
        XCTAssertTrue(result.text.contains("A4: 3 (formula =B4*$C$1+Data!B4+LOG10(B4)+B:B+4:4)"), result.text)
        XCTAssertTrue(result.text.contains("D4: 41 (formula =A1-1)"), result.text)
        XCTAssertTrue(result.text.contains("D5: 0 (formula =A2-1)"), result.text)
        XCTAssertTrue(result.text.contains("E5: 0 (shared formula 9 without its master cell)"), result.text)
        // A shift that leaves the sheet is named, not invented.
        let up = try OfficeTextExtractor.extract(fileURL: try write("u.xlsx", xlsx(sheetXML: """
        <sheetData><row r="2"><c r="A2"><f t="shared" ref="A1:A2" si="0">B1</f><v>1</v></c></row><row r="1"><c r="A1"><f t="shared" si="0"/><v>2</v></c></row></sheetData>
        """)), kind: .xlsx)
        XCTAssertTrue(up.text.contains("A1: 2 (formula =B1 shared from A2; not shifted: B1 leaves the sheet)"), up.text)
        XCTAssertEqual(try ExcelFormulaText.shift("IF(A1>\"B9\",'My Sheet'!C$3,Table1[Col])", rowDelta: 2, columnDelta: 1), "IF(B3>\"B9\",'My Sheet'!D$3,Table1[Col])")
    }

    // MARK: - Excel (XLSX): displayed vs raw

    func testXLSX_dateFormattedSerials_renderISO_percentAndCurrencyNameTheirFormat() throws {
        let styles = """
        <numFmts count="3"><numFmt numFmtId="164" formatCode="yyyy\\-mm\\-dd"/><numFmt numFmtId="165" formatCode="&quot;$&quot;#,##0.00"/><numFmt numFmtId="166" formatCode="0 &quot;days&quot;"/></numFmts>
        <cellStyleXfs count="1"><xf numFmtId="14"/></cellStyleXfs>
        <cellXfs count="8"><xf numFmtId="0"/><xf numFmtId="14"/><xf numFmtId="164"/><xf numFmtId="20"/><xf numFmtId="22"/><xf numFmtId="9"/><xf numFmtId="165"/><xf numFmtId="166"/></cellXfs>
        """
        let sheet = """
        <sheetData>
        <row r="1"><c r="A1" s="1"><v>45672</v></c><c r="B1" s="2"><v>45672</v></c><c r="C1" s="3"><v>0.604166666666667</v></c><c r="D1" s="4"><v>45672.5</v></c></row>
        <row r="2"><c r="A2" s="5"><v>0.15</v></c><c r="B2" s="6"><v>1234.5</v></c><c r="C2" s="7"><v>30</v></c><c r="D2" s="0"><v>45672</v></c></row>
        <row r="3"><c r="A3" s="1"><f>TODAY()</f><v>45672</v></c><c r="B3" s="1" t="s"><v>0</v></c><c r="C3" s="1"><v>60</v></c><c r="D3" t="b"><v>1</v></c></row>
        </sheetData>
        """
        let result = try OfficeTextExtractor.extract(fileURL: try write("d.xlsx", xlsx(sheetXML: sheet, styles: styles, sharedStrings: ["label"])), kind: .xlsx)
        XCTAssertTrue(result.text.contains("A1: 1/15/2025 (serial 45672)\tB1: 2025-01-15 (serial 45672)\tC1: 14:30 (serial 0.604166666666667)\tD1: 1/15/2025 12:00 (serial 45672.5)\n"), "each serial as its format shows it (14 = m/d/yyyy, 20 = h:mm, 22 = m/d/yyyy h:mm in Excel en-US): \(result.text)")
        XCTAssertTrue(result.text.contains("A2: 15% (raw 0.15)\tB2: $1,234.50 (raw 1234.5)\tC2: 30 days (raw 30)\tD2: 45672\n"), "the 'days' word is quoted, not a day code; General stays raw: \(result.text)")
        XCTAssertTrue(result.text.contains("A3: 1/15/2025 (serial 45672; formula =TODAY())\tB3: label\tC3: 2/29/1900 (serial 60; 29 February 1900 is a day the 1900 date system counts but the calendar does not have)\tD3: TRUE\n"), result.text)
        // The 1904 system shifts every date.
        let mac = try OfficeTextExtractor.extract(fileURL: try write("m.xlsx", xlsx(sheetXML: "<sheetData><row r=\"1\"><c r=\"A1\" s=\"1\"><v>44210</v></c></row></sheetData>", styles: "<cellXfs><xf numFmtId=\"0\"/><xf numFmtId=\"14\"/></cellXfs>", workbookExtra: "<workbookPr date1904=\"1\"/>")), kind: .xlsx)
        XCTAssertTrue(mac.text.contains("A1: 1/15/2025 (serial 44210)"), mac.text)
        XCTAssertEqual(ExcelNumberFormat.classify(id: 170, code: "[h]:mm:ss").kind, .elapsedTime)
        XCTAssertEqual(ExcelNumberFormat.render(serial: 1.5, kind: .elapsedTime, date1904: false), "36:00:00")
        XCTAssertEqual(ExcelNumberFormat.classify(id: 171, code: "[$€-407] #,##0.00").kind, .currency)
        XCTAssertEqual(ExcelNumberFormat.classify(id: 172, code: "[Red]0.00").kind, .other)
        XCTAssertEqual(ExcelNumberFormat.classify(id: 173, code: "mmm-yy").kind, .date)
        XCTAssertEqual(ExcelNumberFormat.classify(id: 174, code: "h:mm AM/PM").kind, .time)
    }

    // MARK: - Excel (XLSX): hidden content and external references

    func testXLSX_hiddenRowsColumnsSheetsNames_labelledAndStillRead_externalLinksListedNotRefreshed() throws {
        let members: [(String, Data)] = [
            ("xl/workbook.xml", Data("""
            <workbook xmlns:r="r"><sheets><sheet name="Data" sheetId="1" r:id="rId1"/><sheet name="Secrets" sheetId="2" state="veryHidden" r:id="rId2"/></sheets>
            <externalReferences><externalReference r:id="rId3"/></externalReferences>
            <definedNames><definedName name="Total">Data!$A$1:$A$3</definedName><definedName name="Secret" hidden="1">Secrets!$B$2</definedName></definedNames></workbook>
            """.utf8)),
            ("xl/_rels/workbook.xml.rels", Data("<Relationships><Relationship Id=\"rId1\" Type=\"x\" Target=\"worksheets/sheet1.xml\"/><Relationship Id=\"rId2\" Type=\"x\" Target=\"worksheets/sheet2.xml\"/><Relationship Id=\"rId3\" Type=\"e\" Target=\"externalLinks/externalLink1.xml\"/></Relationships>".utf8)),
            ("xl/worksheets/sheet1.xml", Data("""
            <worksheet><cols><col min="3" max="3" hidden="1" width="0"/></cols><sheetData>
            <row r="1"><c r="A1"><v>1</v></c><c r="C1"><v>3</v></c></row>
            <row r="5" hidden="1"><c r="A5" t="inlineStr"><is><t>hidden figure</t></is></c><c r="C5"><v>7</v></c></row>
            <row r="6"><c r="A6"><f>[1]Q1!A1</f><v>99</v></c></row>
            </sheetData></worksheet>
            """.utf8)),
            ("xl/worksheets/sheet2.xml", Data("<worksheet><sheetData><row r=\"2\"><c r=\"B2\" t=\"inlineStr\"><is><t>very hidden words</t></is></c></row></sheetData></worksheet>".utf8)),
            ("xl/externalLinks/externalLink1.xml", Data("<externalLink><externalBook r:id=\"rId1\"><sheetNames><sheetName val=\"Q1\"/></sheetNames><sheetDataSet><sheetData sheetId=\"0\"><row r=\"1\"><cell r=\"A1\"><v>CACHED-REMOTE</v></cell></row></sheetData></sheetDataSet></externalBook></externalLink>".utf8)),
            ("xl/externalLinks/_rels/externalLink1.xml.rels", Data("<Relationships><Relationship Id=\"rId1\" Type=\"ext\" Target=\"file:///C:/Books/Other.xlsx\" TargetMode=\"External\"/></Relationships>".utf8)),
        ]
        let result = try OfficeTextExtractor.extract(fileURL: try write("h.xlsx", Self.zipPackage(members)), kind: .xlsx)
        XCTAssertEqual(result.components, ["Workbook", "Sheet: Data", "Sheet: Secrets (very hidden)"])
        XCTAssertTrue(result.text.contains("[Workbook]\nname Total: Data!$A$1:$A$3\n[hidden name Secret]: Secrets!$B$2\n[external reference: file:///C:/Books/Other.xlsx] not refreshed\n"), result.text)
        XCTAssertTrue(result.text.contains("[Sheet: Data]\nA1: 1\t[hidden column C] C1: 3\n[hidden row 5] A5: hidden figure\t[hidden column C] C5: 7\nA6: 99 (formula =[1]Q1!A1)\n"), result.text)
        XCTAssertTrue(result.text.contains("[Sheet: Secrets (very hidden)]\nB2: very hidden words\n"), result.text)
        XCTAssertFalse(result.text.contains("CACHED-REMOTE"), "the external workbook's cached data is not read: \(result.text)")
    }

    // MARK: - Excel (XLSX): real files

    func testXLSX_tikaFixtures_sharedFormulasAndDateFormats() throws {
        guard let tika = fixtures("tika") else { throw XCTSkip("tika fixtures not in this checkout") }
        let formulas = try OfficeTextExtractor.extract(fileURL: tika.appendingPathComponent("testEXCEL.xlsx"), kind: .xlsx)
        XCTAssertTrue(formulas.text.contains("C6: 1 (formula =+B6*B6)"), formulas.text)
        XCTAssertTrue(formulas.text.contains("B7: 2 (formula =+B6+1)\tC7: 4 (formula =+B7*B7)"), "the shared formulas of C6:C20 and B7:B20 re-based on each cell: \(formulas.text)")
        XCTAssertTrue(formulas.text.contains("B20: 15 (formula =+B19+1)\tC20: 225 (formula =+B20*B20)"), formulas.text)
        XCTAssertEqual(formulas.components, ["Sheet: Feuil1", "Sheet: Feuil2", "Sheet: Feuil3"])
        let dates = try OfficeTextExtractor.extract(fileURL: tika.appendingPathComponent("testEXCEL_dateFormats.xlsx"), kind: .xlsx)
        XCTAssertTrue(dates.text.contains("A2: 9/20/2018 (serial 43363)\nA3: 8/10/1996 (serial 35287)\n"), "numFmtId 14 cells show the date they display (Excel en-US), serial kept: \(dates.text)")
    }

    // MARK: - XLSB

    private static func cell(_ column: Int, style: Int = 0, _ tail: Data) -> Data { cat(le32(column), le32(style & 0xFFFFFF), tail) }
    private static func formulaTail(flags: Int = 0, _ rgce: Data, rgcb: Data = Data()) -> Data { cat(le16(flags), le32(rgce.count), rgce, le32(rgcb.count), rgcb) }
    private static func ptgRef(_ row: Int, _ col: Int, rowRel: Bool = true, colRel: Bool = true) -> Data {
        cat(bytes(0x44), le32(row), le16(col | (colRel ? 0x4000 : 0) | (rowRel ? 0x8000 : 0)))
    }
    private static func ptgRef3d(_ xti: Int, _ row: Int, _ col: Int) -> Data { cat(bytes(0x5A), le16(xti), le32(row), le16(col)) }
    private static func ptgArea(_ r1: Int, _ r2: Int, _ c1: Int, _ c2: Int) -> Data { cat(bytes(0x45), le32(r1), le32(r2), le16(c1 | 0xC000), le16(c2 | 0xC000)) }
    private static func ptgInt(_ v: Int) -> Data { cat(bytes(0x1E), le16(v)) }
    private static func ptgStr(_ s: String) -> Data { cat(bytes(0x17), le16(s.utf16.count), s.data(using: .utf16LittleEndian)!) }
    private static func ptgFunc(_ id: Int) -> Data { cat(bytes(0x41), le16(id)) }
    private static func ptgFuncVar(_ argc: Int, _ id: Int) -> Data { cat(bytes(0x42, UInt8(argc)), le16(id)) }
    private static func rowHeader(_ row: Int, hidden: Bool = false) -> Data { var d = cat(le32(row), Data(count: 13)); if hidden { d[11] = 0x10 }; return biff12(0x0000, d) }
    /// BrtName: flags, chKey, itab (none), name, formula, no comment.
    private static func brtName(_ name: String, hidden: Bool, formula: Data) -> Data {
        biff12(0x0027, cat(le32(hidden ? 1 : 0), bytes(0), le32(0xFFFF_FFFF), xlString(name), le32(formula.count), formula, le32(0), le32(0xFFFF_FFFF)))
    }
    /// BrtExternSheet: XTI triples (iSupBook, itabFirst, itabLast).
    private static func externSheet(_ xtis: [(Int, Int, Int)]) -> Data {
        biff12(0x016A, xtis.reduce(into: le32(xtis.count)) { $0.append(cat(le32($1.0), le32($1.1), le32($1.2))) })
    }

    private func xlsbPackage(sheet1: Data, sheet2: Data? = nil, workbookExtra: Data = Data(), styles: Data? = nil, shared: [String] = [],
                             workbookRels: String = "", extraParts: [(String, Data)] = []) -> Data {
        var sst = Data()
        sst += Self.biff12(0x009F, Self.le32(shared.count) + Self.le32(shared.count))
        for s in shared { sst += Self.biff12(0x0013, Data([0]) + Self.xlString(s)) }
        var workbook = Data()
        workbook += Self.biff12(0x009C, Self.le32(0) + Self.le32(1) + Self.xlString("rId1") + Self.xlString("Data"))
        if sheet2 != nil { workbook += Self.biff12(0x009C, Self.le32(2) + Self.le32(2) + Self.xlString("rId2") + Self.xlString("Secrets")) }
        workbook += workbookExtra
        var members: [(String, Data)] = [
            ("xl/workbook.bin", workbook),
            ("xl/_rels/workbook.bin.rels", Data(("<Relationships><Relationship Id=\"rId1\" Type=\"x\" Target=\"worksheets/sheet1.bin\"/>"
                                                 + (sheet2 != nil ? "<Relationship Id=\"rId2\" Type=\"x\" Target=\"worksheets/sheet2.bin\"/>" : "") + workbookRels + "</Relationships>").utf8)),
            ("xl/sharedStrings.bin", sst),
            ("xl/worksheets/sheet1.bin", sheet1),
        ]
        if let sheet2 { members.append(("xl/worksheets/sheet2.bin", sheet2)) }
        if let styles { members.append(("xl/styles.bin", styles)) }
        members += extraParts
        return Self.zipPackage(members)
    }

    func testXLSB_formulaTokens_decodeToA1Text_sharedAndArrayRebased_unknownTokenNamed() throws {
        let mul = Self.bytes(0x05), add = Self.bytes(0x03), gt = Self.bytes(0x0D), neg = Self.bytes(0x13), pct = Self.bytes(0x14)
        var sheet = Self.rowHeader(0)
        // A1 = SUM(B2:C3)*2 → PtgArea, PtgFuncVar(1, SUM), PtgInt 2, PtgMul
        sheet += Self.biff12(0x0009, Self.cell(0, Self.f64(20)) + Self.formulaTail(Self.cat(Self.ptgArea(1, 2, 1, 2), Self.ptgFuncVar(1, 4), Self.ptgInt(2), mul)))
        // B1 = IF(A1>1,"yes","no") → with AttrIf/AttrGoto jump tokens, as Excel writes them
        let ifFormula = Self.cat(Self.ptgRef(0, 0), Self.ptgInt(1), gt, Self.bytes(0x19, 0x02), Self.le16(9), Self.ptgStr("yes"),
                                 Self.bytes(0x19, 0x08), Self.le16(7), Self.ptgStr("no"), Self.ptgFuncVar(3, 1))
        sheet += Self.biff12(0x0008, Self.cell(1, Self.xlString("yes")) + Self.formulaTail(ifFormula))
        // C1 = Secrets!$A$1+-D1 → PtgRef3d (xti 0 → sheet 1), PtgRef, PtgUminus, PtgAdd
        sheet += Self.biff12(0x0009, Self.cell(2, Self.f64(1)) + Self.formulaTail(Self.cat(Self.ptgRef3d(0, 0, 0), Self.ptgRef(0, 3), neg, add)))
        // D1 = Total (PtgName 1), E1 = NOW() (PtgFunc 74), F1 = TRUE (PtgBool), G1 = 1.5% (PtgNum, PtgPercent)
        sheet += Self.biff12(0x0009, Self.cell(3, Self.f64(6)) + Self.formulaTail(Self.cat(Self.bytes(0x43), Self.le32(1))))
        sheet += Self.biff12(0x0009, Self.cell(4, Self.f64(45672)) + Self.formulaTail(Self.ptgFunc(74)))
        sheet += Self.biff12(0x000A, Self.cell(5, Self.bytes(1)) + Self.formulaTail(Self.bytes(0x1D, 0x01)))
        sheet += Self.biff12(0x0009, Self.cell(6, Self.f64(0.015)) + Self.formulaTail(Self.cat(Self.bytes(0x1F), Self.f64(1.5), pct)))
        // H1 = unknown token 0x7F after a valid operand; I1 = #DIV/0! with PtgErr
        sheet += Self.biff12(0x000B, Self.cell(7, Self.bytes(0x07)) + Self.formulaTail(Self.cat(Self.ptgInt(7), Self.bytes(0x7F))))
        sheet += Self.biff12(0x000B, Self.cell(8, Self.bytes(0x07)) + Self.formulaTail(Self.bytes(0x1C, 0x07)))
        // Row 2: shared formula over A2:A3 = B2*2 (master A2 carries the full formula, then BrtShrFmla; A3 points at it with PtgExp)
        sheet += Self.rowHeader(1)
        sheet += Self.biff12(0x0009, Self.cell(0, Self.f64(2)) + Self.formulaTail(Self.cat(Self.ptgRef(1, 1), Self.ptgInt(2), mul)))
        let relative = Self.cat(Self.bytes(0x4C), Self.le32(0), Self.le16(1 | 0xC000), Self.ptgInt(2), mul)   // PtgRefN: same row, one column right
        sheet += Self.biff12(0x01AB, Self.cat(Self.le32(1), Self.le32(2), Self.le32(0), Self.le32(0), Self.le32(relative.count), relative, Self.le32(0)))
        sheet += Self.rowHeader(2)
        sheet += Self.biff12(0x0009, Self.cell(0, Self.f64(4)) + Self.formulaTail(Self.cat(Self.bytes(0x01), Self.le32(1), Self.le16(0))))
        // Row 4: array formula {=B4:B5*2} over A4:A5 — the top-left cell's PtgExp points at itself and the BrtArrFmla follows it
        sheet += Self.rowHeader(3)
        sheet += Self.biff12(0x0009, Self.cell(0, Self.f64(8)) + Self.formulaTail(Self.cat(Self.bytes(0x01), Self.le32(3), Self.le16(0))))
        let arrayFormula = Self.cat(Self.ptgArea(3, 4, 1, 1), Self.ptgInt(2), mul)
        sheet += Self.biff12(0x01AA, Self.cat(Self.le32(3), Self.le32(4), Self.le32(0), Self.le32(0), Self.bytes(0), Self.le32(arrayFormula.count), arrayFormula, Self.le32(0)))
        let secrets = Self.rowHeader(0) + Self.biff12(0x0005, Self.cell(0, Self.f64(1)))
        // Workbook: a defined name Total = Data!$B$2:$B$3 (PtgArea3d), BrtSupSelf and BrtExternSheet with XTI 0 → sheet 1
        let nameFormula = Self.cat(Self.bytes(0x5B), Self.le16(1), Self.le32(1), Self.le32(2), Self.le16(1), Self.le16(1))
        let extra = Self.cat(Self.brtName("Total", hidden: false, formula: nameFormula), Self.biff12(0x0165, Data()), Self.externSheet([(0, 1, 1), (0, 0, 0)]))
        let result = try DocumentTextExtractor.extract(fileURL: try write("f.xlsb", xlsbPackage(sheet1: sheet, sheet2: secrets, workbookExtra: extra)), kind: .xlsb)
        XCTAssertTrue(result.text.contains("[Workbook]\nname Total: Data!$B$2:$B$3\n"), result.text)
        XCTAssertTrue(result.text.contains("A1: 20 (formula =SUM(B2:C3)*2)\t"), result.text)
        XCTAssertTrue(result.text.contains("B1: yes (formula =IF(A1>1,\"yes\",\"no\"))\t"), result.text)
        XCTAssertTrue(result.text.contains("C1: 1 (formula =Secrets!$A$1+-D1)\t"), result.text)
        XCTAssertTrue(result.text.contains("D1: 6 (formula =Total)\tE1: 45672 (formula =NOW())\tF1: TRUE (formula =TRUE)\tG1: 0.015 (formula =1.5%)\t"), result.text)
        XCTAssertTrue(result.text.contains("H1: #DIV/0! (formula =7 (formula not decoded: token 0x7F))\tI1: #DIV/0! (formula =#DIV/0!)\n"), "an unknown token is named, never dropped: \(result.text)")
        XCTAssertTrue(result.text.contains("A2: 2 (formula =B2*2)\nA3: 4 (formula =B3*2)\n"), "the shared formula is re-based on A3: \(result.text)")
        XCTAssertTrue(result.text.contains("A4: 8 (formula =B4:B5*2 (array formula))\n"), result.text)
        XCTAssertEqual(result.components, ["Workbook", "Sheet: Data", "Sheet: Secrets (very hidden)"])
    }

    func testXLSB_displayedVsRaw_hiddenRowsColumnsNames_externalReferenceNotRefreshed() throws {
        func xf(_ format: Int) -> Data { Self.biff12(0x002F, Self.cat(Self.le16(0), Self.le16(format), Data(count: 12))) }
        var styles = Self.biff12(0x0267, Self.le32(1))
        styles += Self.biff12(0x002C, Self.le16(164) + Self.xlString("yyyy-mm-dd"))
        styles += Self.biff12(0x0268, Data())
        styles += Self.cat(Self.biff12(0x0272, Self.le32(1)), xf(9), Self.biff12(0x0273, Data()))   // cellStyleXfs: not cell formats
        styles += Self.biff12(0x0269, Self.le32(4))
        styles += Self.cat(xf(0), xf(14), xf(164), xf(10))   // 0 General, 1 m/d/yy, 2 custom date, 3 0.00%
        styles += Self.biff12(0x026A, Data())
        var sheet = Self.biff12(0x003C, Self.cat(Self.le32(2), Self.le32(2), Self.le32(0), Self.le32(0), Self.le16(0x0001)))   // column C hidden
        sheet += Self.rowHeader(0)
        sheet += Self.biff12(0x0002, Self.cell(0, style: 1, Self.le32((45672 << 2) | 0x2)))   // A1 RK 45672 as m/d/yy
        sheet += Self.biff12(0x0005, Self.cell(1, style: 2, Self.f64(45672.5)))              // B1 custom date
        sheet += Self.biff12(0x0005, Self.cell(2, style: 3, Self.f64(0.125)))                // C1 percent, hidden column
        sheet += Self.rowHeader(4, hidden: true)
        sheet += Self.biff12(0x0006, Self.cell(0, Self.xlString("hidden figure")))
        sheet += Self.rowHeader(5)
        // A6 = [Other.xlsx]Q1!$A$1 through BrtSupBookSrc (rId3 → externalLink1.bin) and XTI 1 → supbook 1, tab 0
        sheet += Self.biff12(0x0009, Self.cell(0, Self.f64(99)) + Self.formulaTail(Self.ptgRef3d(1, 0, 0)))
        let extra = Self.cat(Self.brtName("NA", hidden: true, formula: Data()), Self.biff12(0x0165, Data()), Self.biff12(0x0163, Self.xlString("rId3")),
                             Self.biff12(0x0167, Self.le32(1) + Self.xlString("Q1")), Self.externSheet([(0, 0, 0), (1, 0, 0)]))
        let package = xlsbPackage(sheet1: sheet, workbookExtra: extra, styles: styles,
                                  workbookRels: "<Relationship Id=\"rId3\" Type=\"e\" Target=\"externalLinks/externalLink1.bin\"/>",
                                  extraParts: [("xl/externalLinks/externalLink1.bin", Self.biff12(0x0168, Data())),
                                               ("xl/externalLinks/_rels/externalLink1.bin.rels", Data("<Relationships><Relationship Id=\"rId1\" Type=\"ext\" Target=\"file:///C:/Books/Other.xlsx\" TargetMode=\"External\"/></Relationships>".utf8))])
        let result = try DocumentTextExtractor.extract(fileURL: try write("h.xlsb", package), kind: .xlsb)
        XCTAssertTrue(result.text.contains("[Workbook]\n[hidden name NA]\n[external reference: file:///C:/Books/Other.xlsx] not refreshed\n"), result.text)
        XCTAssertTrue(result.text.contains("A1: 1/15/2025 (serial 45672)\tB1: 2025-01-15 (serial 45672.5)\t[hidden column C] C1: 12.50% (raw 0.125)\n"), result.text)
        XCTAssertTrue(result.text.contains("[hidden row 5] A5: hidden figure\n"), result.text)
        XCTAssertTrue(result.text.contains("A6: 99 (formula ='[file:///C:/Books/Other.xlsx]Q1'!$A$1)\n"), "the external cell is named from the stored reference, never fetched: \(result.text)")
    }

    func testXLSB_tikaFixtures_formulasDecoded_dateAndFormatsShown_hiddenName() throws {
        guard let tika = fixtures("tika") else { throw XCTSkip("tika fixtures not in this checkout") }
        let various = try DocumentTextExtractor.extract(fileURL: tika.appendingPathComponent("testEXCEL_various.xlsb"), kind: .xlsb)
        XCTAssertTrue(various.text.contains("[Workbook]\n[hidden name NA]\n"), "Excel keeps the undefined name of =COS(NA) as a hidden name: \(various.text)")
        XCTAssertTrue(various.text.contains("A13: formula\tB13: 4 (formula =C13*2)\tC13: 2\n"), "cached 4 = C13 (2) × 2: \(various.text)")
        XCTAssertTrue(various.text.contains("A14: formulaErr\tB14: #NAME? (formula =COS(NA))\n"), various.text)
        XCTAssertTrue(various.text.contains("A15: formulaFloat\tB15: 0.5 (formula =1/C13)\t"), "cached 0.5 = 1 / C13 (2): \(various.text)")
        XCTAssertTrue(various.text.contains("A10: date\tB10: 3/9/2017 (serial 42803)\n"), various.text)
        XCTAssertTrue(various.text.contains("A5: percent\tB5: 20% (raw 0.2)\n"), various.text)
        XCTAssertTrue(various.text.contains("A4: currency\tB4: $3.03 (raw 3.03)\n"), various.text)
        XCTAssertEqual(various.components, ["Workbook", "Sheet: mySheet1"])
        XCTAssertFalse(various.text.contains("not decoded"), various.text)
        let plain = try DocumentTextExtractor.extract(fileURL: tika.appendingPathComponent("testEXCEL.xlsb"), kind: .xlsb)
        XCTAssertEqual(plain.components, ["Sheet: Sheet1", "Sheet: Sheet2", "Sheet: Sheet3"])
        XCTAssertFalse(plain.text.contains("formula"), "no formula cells in this workbook: \(plain.text)")
        let charts = try DocumentTextExtractor.extract(fileURL: tika.appendingPathComponent("testEXCEL_charts.xlsb"), kind: .xlsb)
        XCTAssertEqual(charts.components, ["Sheet: Sheet1"])
    }
}
