//
//  HostileDocumentInputTests.swift
//  ArchiveCoreTests
//
//  Review 2026-11-16 (CODE_REVIEW_2026-11-16.md) A5–A10, A16, A17: one
//  hostile input per crash or exhaustion path in the Office / iWork /
//  OneNote / XLSB / Excel readers, built here byte by byte. Before the fix
//  each of these trapped the process (overflow, "Range requires lowerBound
//  <= upperBound", Int(1e300)), recursed without bound, or walked 2^n paths;
//  now each is read, refused with a named reason, or stopped at a stated
//  limit.
//

import XCTest
@testable import ArchiveCore

final class HostileDocumentInputTests: XCTestCase {

    // MARK: - Helpers

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("hostile-doc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func write(_ name: String, _ data: Data) throws -> URL {
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

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

    private static func le16(_ v: Int) -> Data { Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }
    private static func le32(_ v: Int) -> Data { let u = UInt32(truncatingIfNeeded: v); return Data((0..<4).map { UInt8((u >> (8 * $0)) & 0xFF) }) }
    private static func cat(_ parts: Data...) -> Data { parts.reduce(into: Data()) { $0.append($1) } }
    private static func bytes(_ values: UInt8...) -> Data { Data(values) }

    /// A stored ZIP with correct CRCs (an Office package is one).
    private static func zipPackage(_ members: [(String, Data)]) -> Data {
        var local = Data(), central = Data()
        for (memberName, data) in members {
            let name = Data(memberName.utf8)
            let crc = Int(crc32(data))
            let offset = local.count
            local += cat(le32(0x04034b50), le16(20), le16(0), le16(0), le16(0), le16(0), le32(crc), le32(data.count), le32(data.count), le16(name.count), le16(0), name, data)
            central += cat(le32(0x02014b50), le16(20), le16(20), le16(0), le16(0), le16(0), le16(0), le32(crc), le32(data.count), le32(data.count),
                           le16(name.count), le16(0), le16(0), le16(0), le16(0), le32(0), le32(offset), name)
        }
        return cat(local, central, le32(0x06054b50), le16(0), le16(0), le16(members.count), le16(members.count), le32(central.count), le32(local.count), le16(0))
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
    private static func xlString(_ s: String) -> Data { le32(s.utf16.count) + s.data(using: .utf16LittleEndian)! }

    private static func xlsx(sheetXML: String) -> Data {
        zipPackage([
            ("xl/workbook.xml", Data("<workbook xmlns:r=\"r\"><sheets><sheet name=\"Data\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>".utf8)),
            ("xl/_rels/workbook.xml.rels", Data("<Relationships><Relationship Id=\"rId1\" Type=\"x\" Target=\"worksheets/sheet1.xml\"/></Relationships>".utf8)),
            ("xl/worksheets/sheet1.xml", Data("<worksheet>\(sheetXML)</worksheet>".utf8)),
        ])
    }

    private static func xlsb(sheet: Data) -> Data {
        zipPackage([
            ("xl/workbook.bin", biff12(0x009C, cat(le32(0), le32(1), xlString("rId1"), xlString("Data")))),
            ("xl/_rels/workbook.bin.rels", Data("<Relationships><Relationship Id=\"rId1\" Type=\"x\" Target=\"worksheets/sheet1.bin\"/></Relationships>".utf8)),
            ("xl/worksheets/sheet1.bin", sheet),
        ])
    }

    private static let w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

    /// A .docx whose body says `text`, with `embedded` (if any) under word/embeddings/.
    private static func docx(_ text: String, embedded: [(String, Data)] = []) -> Data {
        let document = "<w:document xmlns:w=\"\(w)\"><w:body><w:p><w:r><w:t>\(text)</w:t></w:r></w:p></w:body></w:document>"
        return zipPackage([("word/document.xml", Data(document.utf8))] + embedded.map { ("word/embeddings/" + $0.0, $0.1) })
    }

    /// Protobuf wire format.
    private static func varint(_ v: UInt64) -> [UInt8] {
        var v = v, out: [UInt8] = []
        repeat { var b = UInt8(v & 0x7F); v >>= 7; if v > 0 { b |= 0x80 }; out.append(b) } while v > 0
        return out
    }
    private static func pbVarint(_ field: Int, _ v: UInt64) -> [UInt8] { varint(UInt64(field << 3)) + varint(v) }
    private static func pbBytes(_ field: Int, _ payload: [UInt8]) -> [UInt8] { varint(UInt64(field << 3 | 2)) + varint(UInt64(payload.count)) + payload }

    /// One IWA chunk holding `raw` as a single snappy literal (≤ 60 bytes).
    private static func iwaChunk(_ raw: [UInt8]) -> Data {
        precondition(!raw.isEmpty && raw.count <= 60)
        let block = varint(UInt64(raw.count)) + [UInt8((raw.count - 1) << 2)] + raw
        return Data([0x00, UInt8(block.count & 0xFF), UInt8((block.count >> 8) & 0xFF), UInt8((block.count >> 16) & 0xFF)] + block)
    }

    /// Varints that decode to Int.min (`80×9 01`) and Int.max (`FF×8 7F`).
    private static let intMinVarint: [UInt8] = Array(repeating: 0x80, count: 9) + [0x01]
    private static let intMaxVarint: [UInt8] = Array(repeating: 0xFF, count: 8) + [0x7F]

    // MARK: - A5: hidden column range starting past the sheet's last column

    func testA5_xlsxHiddenColumnRangePastTheSheet_isReadNotTrapped() throws {
        let sheet = """
        <cols><col min="20000" max="30000" hidden="1"/><col min="2" max="2" hidden="1"/></cols>
        <sheetData><row r="1"><c r="A1"><v>7</v></c><c r="B1"><v>8</v></c></row></sheetData>
        """
        let result = try OfficeTextExtractor.extract(fileURL: try write("cols.xlsx", Self.xlsx(sheetXML: sheet)), kind: .xlsx)
        XCTAssertTrue(result.text.contains("A1: 7"), result.text)
        XCTAssertTrue(result.text.contains("B1: 8"), "the in-range hidden column is still read: \(result.text)")
    }

    func testA5_xlsbHiddenColInfoPastTheSheet_isReadNotTrapped() throws {
        // BrtColInfo: colFirst 20000, colLast 30000, coldx, ixfe, flags (fHidden).
        var sheet = Self.biff12(0x003C, Self.cat(Self.le32(20_000), Self.le32(30_000), Self.le32(0), Self.le32(0), Self.le16(1)))
        sheet += Self.biff12(0x0000, Self.cat(Self.le32(0), Data(count: 13)))                       // row 1
        sheet += Self.biff12(0x0002, Self.cat(Self.le32(0), Self.le32(0), Self.le32(Int(42 << 2 | 2))))   // A1 = RK 42
        let result = try DocumentTextExtractor.extract(fileURL: try write("cols.xlsb", Self.xlsb(sheet: sheet)), kind: .xlsb)
        XCTAssertTrue(result.text.contains("A1: 42"), result.text)
    }

    // MARK: - A6: protobuf lengths that decode to Int.min / Int.max

    func testA6_protobufFieldLengthIntMinOrIntMax_endsTheFieldList() {
        for hostile in [Self.intMinVarint, Self.intMaxVarint] {
            let data = Data([0x0A] + hostile + [0x41, 0x42])   // field 1, wire 2, then the length
            XCTAssertTrue(ProtobufWalker.fields(in: data).isEmpty)
            XCTAssertTrue(ProtobufWalker.messages(field: 1, in: data).isEmpty)
        }
        XCTAssertEqual(ProtobufWalker.strings(field: 1, in: Data([0x0A, 0x02, 0x68, 0x69])), ["hi"], "a well-formed field still reads")
    }

    func testA6_iwaArchiveInfoLengthIntMinOrIntMax_readsNoObjectInsteadOfTrapping() throws {
        for hostile in [Self.intMinVarint, Self.intMaxVarint] {
            let chunk = Self.iwaChunk(hostile + [0x00, 0x00])
            XCTAssertTrue(try IWAFile.objects(in: chunk, limit: 1 << 20).isEmpty)
            XCTAssertTrue(try IWAFile.identifiedObjects(in: chunk, limit: 1 << 20).isEmpty)
        }
        // A MessageInfo whose length (field 3) is Int.max: the object is not read, nothing traps.
        let message = Self.pbVarint(1, 2) + Self.pbVarint(3, UInt64(Int.max))
        let info = Self.pbVarint(1, 5) + Self.pbBytes(2, message)
        let chunk = Self.iwaChunk(Self.varint(UInt64(info.count)) + info + [0x01])
        XCTAssertTrue(try IWAFile.objects(in: chunk, limit: 1 << 20).isEmpty)
        XCTAssertTrue(try IWAFile.identifiedObjects(in: chunk, limit: 1 << 20).isEmpty)
    }

    // MARK: - A7: Numbers tile row arithmetic and raw doubles

    func testA7_tileIDTimesTileSizeOverflow_rowIsNotPlaced() {
        let tileRef = Self.pbVarint(1, 99)
        let tileEntry = Self.pbVarint(1, 1 << 40) + Self.pbBytes(2, tileRef)
        let tileStorage = Self.pbBytes(1, tileEntry) + Self.pbVarint(2, 1 << 40)
        let model = Self.pbBytes(8, Array("T".utf8)) + Self.pbBytes(4, Self.pbBytes(3, tileStorage))
        let tile = IWAFile.Object(type: IWATableDecoder.tileType, payload: Data(Self.pbBytes(5, Self.pbVarint(1, 3))))
        let table = IWATableDecoder.table(model: Data(model), objects: [99: tile])
        XCTAssertEqual(table?.name, "T")
        XCTAssertEqual(table?.rows, [], "a row number that overflows names no row")
    }

    func testA7_durationAndDateOfNonFiniteOrHugeDoubles_areShownNotConverted() {
        XCTAssertEqual(IWATableDecoder.duration(.infinity), "infs")
        XCTAssertEqual(IWATableDecoder.duration(-.infinity), "-infs")
        XCTAssertEqual(IWATableDecoder.duration(.nan), "nans")
        XCTAssertTrue(IWATableDecoder.duration(1e300).contains("e+"), IWATableDecoder.duration(1e300))
        XCTAssertEqual(IWATableDecoder.duration(90_061), "1d 1h 1m 1s", "ordinary durations are unchanged")
        XCTAssertEqual(IWATableDecoder.date(.infinity), "inf")
        // A duration cell (type 7, v5) whose double is +inf, through the cell reader.
        var cell: [UInt8] = [5, 7, 0, 0, 0, 0, 0, 0, 0x02, 0, 0, 0]
        cell += withUnsafeBytes(of: Double.infinity.bitPattern.littleEndian) { Array($0) }
        XCTAssertEqual(IWATableDecoder.cell(cell, strings: [:], rich: [:]), .duration("infs"))
    }

    // MARK: - A8: OneNote 64-bit offsets and lengths

    func testA8_cursorSkipAndChunkEndOfInt64Max_failWithoutOverflow() {
        var c = OneNoteTextExtractor.Cursor([0, 1, 2, 3], pos: 2, end: 4)
        XCTAssertThrowsError(try c.skip(Int.max))
        XCTAssertThrowsError(try c.bytes(Int.max))
        var far = OneNoteTextExtractor.Cursor([0, 1, 2, 3], pos: Int.max, end: 4)
        XCTAssertThrowsError(try far.u32())
        XCTAssertEqual(far.remaining, 0)
        XCTAssertEqual(OneNoteTextExtractor.OneStoreFile.ChunkRef(stp: Int.max, cb: 256).end, Int.max)
        XCTAssertEqual(OneNoteTextExtractor.OneStoreFile.ChunkRef(stp: 100, cb: 36).end, 136)
    }

    func testA8_revisionStoreHeaderRootListAtInt64Max_isNamedNotTrapped() throws {
        var b = [UInt8](repeating: 0, count: 256)
        b.replaceSubrange(0..<16, with: OneNoteTextExtractor.sectionFileTypeGUID)
        b.replaceSubrange(48..<64, with: OneNoteTextExtractor.oneStoreFormatGUID)
        b.replaceSubrange(172..<180, with: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F])           // stp = Int64.max
        b.replaceSubrange(180..<184, with: [0x00, 0x01, 0x00, 0x00])                                   // cb = 256
        let result = try OneNoteTextExtractor.extract(data: Data(b), name: "hostile.one")
        XCTAssertTrue(result.skipped.contains { $0.contains("lies outside the file") }, "\(result.skipped)")
    }

    func testA8_packagedStreamObjectLengthOfInt64Max_isNamedNotTrapped() throws {
        var b = [UInt8](repeating: 0, count: 64)
        b.replaceSubrange(0..<16, with: OneNoteTextExtractor.sectionFileTypeGUID)
        b.replaceSubrange(48..<64, with: OneNoteTextExtractor.packagingFormatGUID)
        b += [0, 0, 0, 0]                                     // rgbReserved
        b += [0xD2, 0x03, 0x00, 0x00]                          // 32-bit header: start 0x7A, length 0
        b += [0x00]                                            // storage index ExGUID (nil)
        b += [UInt8](repeating: 0, count: 16)                  // cell schema GUID
        b += [0xA8, 0x02]                                      // 16-bit header: start 0x15, length 1
        b += [0x00]                                            // reserved
        b += [0x0A, 0x00, 0xFE, 0xFF]                          // 32-bit header: start 0x01, length 32767 → compact length follows
        b += [0x80] + [UInt8](repeating: 0xFF, count: 7) + [0x7F]   // compact UInt64 = Int64.max
        b += [UInt8](repeating: 0, count: 32)
        let result = try OneNoteTextExtractor.extract(data: Data(b), name: "hostile.one")
        XCTAssertTrue(result.skipped.contains { $0.contains("past the end of the file") }, "\(result.skipped)")
    }

    // MARK: - A9: XLSB array constant rows × columns

    func testA9_arrayConstantDimensionsOverflowingInt_areNotDecodedNotTrapped() {
        let rgce = Self.cat(Self.bytes(0x40), Data(count: 14))
        let rgcb = Self.cat(Self.le32(-1), Self.le32(-1))          // 0xFFFFFFFF columns × 0xFFFFFFFF rows
        let text = XLSBFormulaDecoder.decode(rgce: rgce, rgcb: rgcb, base: .init(row: 0, column: 0), context: XLSBFormulaContext())
        XCTAssertTrue(text.contains("array constant not decoded"), text)
        let ok = XLSBFormulaDecoder.decode(rgce: rgce, rgcb: Self.cat(Self.le32(1), Self.le32(1), Self.bytes(0x04), Self.bytes(1), Data(count: 7)),
                                           base: .init(row: 0, column: 0), context: XLSBFormulaContext())
        XCTAssertEqual(ok, "{TRUE}")
    }

    // MARK: - A10: shared-formula rows and fraction denominators

    func testA10_sharedFormulaShiftPastInt64_isOutOfRangeNotTrapped() throws {
        XCTAssertThrowsError(try ExcelFormulaText.shift("B9223372036854775807", rowDelta: 1, columnDelta: 0))
        XCTAssertThrowsError(try ExcelFormulaText.shift("SUM(9223372036854775807:9223372036854775807)", rowDelta: 1, columnDelta: 0))
        XCTAssertEqual(try ExcelFormulaText.shift("B2", rowDelta: 1, columnDelta: 0), "B3", "ordinary shifts are unchanged")
        // The review's file: a shared formula used by a cell at row 9223372036854775807.
        let sheet = """
        <sheetData><row r="1"><c r="A1"><f t="shared" ref="A1:A2" si="0">B2</f><v>1</v></c></row>
        <row r="9223372036854775807"><c r="A9223372036854775807"><f t="shared" si="0"/><v>2</v></c></row></sheetData>
        """
        let result = try OfficeTextExtractor.extract(fileURL: try write("rows.xlsx", Self.xlsx(sheetXML: sheet)), kind: .xlsx)
        XCTAssertTrue(result.text.contains("not shifted"), result.text)
    }

    func testA10_hugeSerialAndNineteenDigitDenominator_renderWithoutTrapping() {
        XCTAssertNil(ExcelNumberFormat.render(serial: 1e300, kind: .date, date1904: false))
        XCTAssertNil(ExcelNumberFormat.render(serial: -1e300, kind: .elapsedTime, date1904: false))
        XCTAssertEqual(ExcelNumberFormat.render(serial: 1.5, kind: .elapsedTime, date1904: false), "36:00:00")
        let rendered = ExcelNumberFormatRenderer.render(0.5, code: "0/0000000000000000000", date1904: false)
        XCTAssertNotNil(rendered)
        XCTAssertTrue(rendered?.contains("/") == true, "\(rendered ?? "nil")")
        XCTAssertNotNil(ExcelNumberFormatRenderer.render(0.25, code: "# ?/????????????????????", date1904: false))
    }

    // MARK: - A16: embedded documents continue the attachment's depth and budget

    func testA16_docxInsideDocxChain_stopsAtTheArchiveDepthWithItsNamedReason() throws {
        var inner = Self.docx("LEVEL6")
        for level in stride(from: 5, through: 1, by: -1) { inner = Self.docx("LEVEL\(level)", embedded: [("level\(level + 1).docx", inner)]) }
        let result = try DocumentTextExtractor.extract(fileURL: try write("chain.docx", inner), kind: .docx)
        let depth = ExtractionLimits.effective.archiveDepth
        XCTAssertEqual(depth, 3)
        let texts = result.children.compactMap(\.text).joined(separator: "\n")
        XCTAssertTrue(texts.contains("LEVEL2") && texts.contains("LEVEL3"), "levels within the depth are read: \(texts)")
        XCTAssertFalse(texts.contains("LEVEL4"), "level 4 lies deeper than \(depth) levels: \(texts)")
        let stopped = result.children.first { $0.path.hasSuffix("level4.docx") }
        XCTAssertEqual(stopped?.state, .unsupported, "\(result.children.map { ($0.path, $0.state, $0.note ?? "") })")
        XCTAssertEqual(stopped?.note, "an archive nested deeper than \(depth) levels")
        XCTAssertTrue(ExtractionLimits.noteNamesALimit(stopped?.note), "the stop is a stated, resumable limit")
        // A Resume round opens one more level.
        let resumed = try ExtractionLimits.$current.withValue(ExtractionLimits.round(1)) {
            try DocumentTextExtractor.extract(fileURL: try write("chain2.docx", inner), kind: .docx)
        }
        XCTAssertTrue(resumed.children.compactMap(\.text).joined().contains("LEVEL4"))
        XCTAssertFalse(resumed.children.compactMap(\.text).joined().contains("LEVEL5"))
    }

    func testA16_zipEmbeddedInDocx_spendsTheSameBudgetAndDepth() throws {
        let member = Data(repeating: 0x41, count: 1_200)
        let zip = Self.zipPackage([("a.txt", member), ("b.txt", member)])
        let docx = Self.docx("OUTER", embedded: [("bundle.zip", zip)])
        let limits = ExtractionLimits(partBytes: 1 << 20, totalArchiveBytes: 3_000, archiveDepth: 3)
        let result = try ExtractionLimits.$current.withValue(limits) {
            try DocumentTextExtractor.extract(fileURL: try write("budget.docx", docx), kind: .docx)
        }
        // The docx spent the zip's own bytes; what is left does not hold both members.
        let notes = result.children.compactMap(\.note)
        XCTAssertTrue(notes.contains { $0.contains("budget for one attachment's archives is used up") },
                      "\(result.children.map { ($0.path, $0.state, $0.note ?? "") })")
        XCTAssertLessThan(result.children.filter { $0.state == .extracted && $0.path.hasSuffix(".txt") }.count, 2)

        // Depth: a zip in a zip in a zip, embedded in a docx — the embedded zip is level 2, not level 1 again.
        let z3 = Self.zipPackage([("deep.txt", Data("DEEP".utf8))])
        let z2 = Self.zipPackage([("z3.zip", z3)])
        let z1 = Self.zipPackage([("z2.zip", z2)])
        let nested = try DocumentTextExtractor.extract(fileURL: try write("nested.docx", Self.docx("OUTER", embedded: [("z1.zip", z1)])), kind: .docx)
        XCTAssertFalse(nested.children.compactMap(\.text).joined().contains("DEEP"), "\(nested.children.map { ($0.path, $0.state, $0.note ?? "") })")
        XCTAssertTrue(nested.children.contains { $0.note == "an archive nested deeper than 3 levels" })
    }

    // MARK: - A17: OneNote object graph with doubled references

    func testA17_objectGraphWithDoubledReferences_isWalkedOncePerObject() {
        typealias Store = OneNoteTextExtractor.OneStoreFile
        final class Box: @unchecked Sendable { var pages: [[String]]? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let text = Array("Leaf text of the page".utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
            let store = Store(bytes: text)
            func oid(_ i: Int) -> OneNoteTextExtractor.ObjectID { .init(guid: [UInt8](repeating: UInt8(i & 0xFF), count: 16), n: UInt32(i)) }
            let levels = 60
            for i in 0...levels {
                let node = Store.Node(id: 0xA4, baseType: 0)
                if i == levels {
                    node.propertySet = .init(entries: [(OneNoteTextExtractor.richEditTextUnicode, .data(0..<text.count))])
                } else {
                    // Each object references the next one twice: 2^60 paths, 61 objects.
                    let next = OneNoteTextExtractor.ObjectRef(raw: 0, resolved: oid(i + 1))
                    node.propertySet = .init(entries: [(0x2400_1C1F, .references([next, next]))])
                }
                store.objects[oid(i)] = node
            }
            let revision = oid(1_000)
            let start = Store.Node(id: 0x1B, baseType: 0); start.gosid = revision
            let rootNode = Store.Node(id: 0x59, baseType: 0); rootNode.gosid = oid(0); rootNode.rootRole = 1
            let list = Store.Node(id: 0x10, baseType: 2); list.children = [start, rootNode]
            store.revisionRoles[revision] = Store.Role(role: 1, context: nil)
            store.revisionLists = [(gosid: oid(2_000), list: list)]
            box.pages = store.collectText().pages
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 20), .success, "the walk of 61 objects did not finish in 20 s")
        XCTAssertEqual(box.pages, [["Leaf text of the page"]])
    }
}
