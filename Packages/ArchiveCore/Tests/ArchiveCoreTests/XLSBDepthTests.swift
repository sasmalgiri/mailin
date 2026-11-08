//
//  XLSBDepthTests.swift
//  ArchiveCoreTests
//
//  Excel Binary Workbook depth ([MS-XLSB]):
//
//   • cell comments (comments1.bin: BrtCommentAuthor, BrtBeginComment,
//     BrtCommentText, BrtEndComment) read from Excel-written files from
//     Apache POI's test corpus, author and text checked against POI's own
//     TestXSSFBReader oracle;
//   • structured (table) references — PtgList, 0x18 0x19 — rendered as Excel
//     shows them, with table and column names from a table part; the bytes
//     are built here from the spec (no public .xlsb with a table formula was
//     found), the oracle strings follow [MS-XLSB] 2.2.2 / 2.5.98.52 / 2.5.98.73;
//   • every Ftab / Cetab id named; future functions (_xlfn.) and add-in
//     functions (PtgNameX → BrtPlaceholderName) rendered by name;
//   • PtgExp as Excel writes it (row in the token, column in PtgExtraCol),
//     read from POI's bug66682.xlsb.
//
//  Fixtures: Fixtures/opensource/poi/{comments,testVarious,bug66682}.xlsb —
//  see Fixtures/opensource/MANIFEST.md.
//

import XCTest
@testable import ArchiveCore

final class XLSBDepthTests: XCTestCase {

    // MARK: - Helpers

    private static func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/opensource/poi/\(name)")
    }

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("xlsb-depth-\(UUID().uuidString)", isDirectory: true)
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

    /// A stored ZIP with correct CRCs.
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
    private static func cat(_ parts: Data...) -> Data { parts.reduce(into: Data()) { $0.append($1) } }
    private static func bytes(_ values: UInt8...) -> Data { Data(values) }
    private static func f64(_ v: Double) -> Data { var bits = v.bitPattern; var d = Data(); for _ in 0..<8 { d.append(UInt8(bits & 0xFF)); bits >>= 8 }; return d }
    private static func xlString(_ s: String) -> Data { le32(s.utf16.count) + s.data(using: .utf16LittleEndian)! }
    private static let nullString = le32(-1)

    private static func rowHeader(_ row: Int) -> Data { biff12(0x0000, cat(le32(row), Data(count: 13))) }
    /// BrtFmlaNum: cell (column, style), cached value, flags, CellParsedFormula.
    private static func formulaCell(_ column: Int, _ rgce: Data, rgcb: Data = Data()) -> Data {
        biff12(0x0009, cat(le32(column), le32(0), f64(0), le16(0), le32(rgce.count), rgce, le32(rgcb.count), rgcb))
    }

    /// PtgList: 0x18 0x19, ixti, flags (columns 2 bits, rowType 5 bits, …, type 2 bits, invalid, nonresident), listIndex, colFirst, colLast.
    private static func ptgList(table: Int = 1, rowType: Int, columns: Int, first: Int = 0, last: Int = 0, invalid: Bool = false) -> Data {
        let flags = columns | rowType << 2 | 1 << 10 | (invalid ? 1 << 12 : 0)
        return cat(bytes(0x18, 0x19), le16(0), le16(flags), le32(table), le16(first), le16(last))
    }
    private static func ptgFuncVar(_ argc: Int, _ id: Int, command: Bool = false) -> Data { cat(bytes(0x22, UInt8(argc)), le16(id | (command ? 0x8000 : 0))) }
    private static func ptgFunc(_ id: Int) -> Data { cat(bytes(0x21), le16(id)) }
    private static func ptgRef(_ row: Int, _ col: Int) -> Data { cat(bytes(0x44), le32(row), le16(col | 0xC000)) }
    private static func ptgStr(_ s: String) -> Data { cat(bytes(0x17), le16(s.utf16.count), s.data(using: .utf16LittleEndian)!) }
    private static func ptgName(_ index: Int) -> Data { cat(bytes(0x43), le32(index)) }

    /// BrtBeginList for one table and its BrtBeginListCol records ([MS-XLSB] 2.4.100 / 2.4.101).
    private static func tablePart(id: Int, name: String, rows: ClosedRange<Int>, columns firstColumn: Int, names: [String]) -> Data {
        var part = biff12(0x0157, cat(le32(rows.lowerBound), le32(rows.upperBound), le32(firstColumn), le32(firstColumn + names.count - 1),
                                      le32(0), le32(id), le32(1), le32(0), le32(0), Data(repeating: 0xFF, count: 24), le32(0),
                                      xlString(name), xlString(name), nullString, nullString, nullString, nullString))
        part += biff12(0x0159, le32(names.count))   // BrtBeginListCols
        for (index, column) in names.enumerated() {
            part += biff12(0x015B, cat(le32(index + 1), le32(0), Data(repeating: 0xFF, count: 12), le32(0),
                                       nullString, xlString(column), nullString, nullString, nullString, nullString))
            part += biff12(0x015C, Data())
        }
        part += biff12(0x015A, Data())
        part += biff12(0x0158, Data())
        return part
    }

    /// One sheet "Data" with the given worksheet records, an optional table part and extra workbook records.
    private func package(sheet: Data, workbookExtra: Data = Data(), table: Data? = nil) -> Data {
        var workbook = Self.biff12(0x009C, Self.cat(Self.le32(0), Self.le32(1), Self.xlString("rId1"), Self.xlString("Data")))
        workbook += workbookExtra
        var members: [(String, Data)] = [
            ("xl/workbook.bin", workbook),
            ("xl/_rels/workbook.bin.rels", Data("<Relationships><Relationship Id=\"rId1\" Type=\"x\" Target=\"worksheets/sheet1.bin\"/></Relationships>".utf8)),
            ("xl/worksheets/sheet1.bin", sheet),
        ]
        if let table {
            members.append(("xl/tables/table1.bin", table))
            members.append(("xl/worksheets/_rels/sheet1.bin.rels", Data("<Relationships><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/table\" Target=\"../tables/table1.bin\"/></Relationships>".utf8)))
        }
        return Self.zipPackage(members)
    }

    // MARK: - (a) Comments, real files

    /// POI TestXSSFBReader.testComments: A1 "Sven Nissel" / "comment top row1 (index0)", A2 "Allison, Timothy B." /
    /// "Allison, Timothy B.:\ncomment row2 (index1)", A3 and A4 "Sven Nissel" / "comment top row3 (index2)", "… row4 (index3)".
    func testREAL_poiComments_authorAndTextMatchPOIOracle() throws {
        let result = try DocumentTextExtractor.extract(fileURL: Self.fixture("comments.xlsb"), kind: .xlsb)
        XCTAssertTrue(result.text.contains("""
            [Comments: Sheet1]
            A1: comment top row1 (index0) (author Sven Nissel)
            A2: Allison, Timothy B.:
            comment row2 (index1) (author Allison, Timothy B.)
            A3: comment top row3 (index2) (author Sven Nissel)
            A4: comment top row4 (index3) (author Sven Nissel)

            """), result.text)
        XCTAssertTrue(result.text.contains("[Sheet: Sheet1]\nB1: row1\nA3: row3\tB3: row3\nB4: row4\n"), "cells are read as before: \(result.text)")
        XCTAssertEqual(result.components.filter { $0.hasPrefix("Comments") }, ["Comments: Sheet1"], "\(result.components)")
        XCTAssertEqual(result.components.firstIndex(of: "Comments: Sheet1"), result.components.firstIndex(of: "Sheet: Sheet1").map { $0 + 1 },
                       "the comments section follows its sheet, as in the XLSX reader: \(result.components)")
    }

    /// POI TestXSSFBReader.testBasic on testVarious.xlsb (= Tika's testEXCEL_various.xlsb): C8, B35, I65, I66 by "Allison, Timothy B.".
    func testREAL_poiTestVarious_commentsBesideTheirCells() throws {
        let result = try DocumentTextExtractor.extract(fileURL: Self.fixture("testVarious.xlsb"), kind: .xlsb)
        for line in ["C8: Allison, Timothy B.:\ntest comment2 (author Allison, Timothy B.)\n",
                     "B35: Allison, Timothy B.:\ncomment6 actually in cell (author Allison, Timothy B.)\n",
                     "I65: Allison, Timothy B.:\ncomment7 end of file (author Allison, Timothy B.)\n",
                     "I66: Allison, Timothy B.:\ncomment8 end of file (author Allison, Timothy B.)\n"] {
            XCTAssertTrue(result.text.contains(line), "\(line) — \(result.text)")
        }
        XCTAssertTrue(result.text.contains("[Comments: mySheet1]\nC8: "), result.text)
        XCTAssertEqual(result.components, ["Workbook", "Sheet: mySheet1", "Comments: mySheet1"])
        XCTAssertTrue(result.text.contains("B35: comment6\n"), "the cell under the comment keeps its own value: \(result.text)")
    }

    // MARK: - PtgExp as Excel writes it (real file)

    /// POI's bug66682.xlsb: C3:C10 share =B3 (PtgExp with the column in PtgExtraCol) and C9 holds an array formula
    /// calling the undefined "unknownFunction" (PtgName + PtgFuncVar 255); C8 points into the external book "ab".
    func testREAL_poiBug66682_sharedFormulaColumnFromPtgExtraCol_arrayUserFunction() throws {
        let result = try DocumentTextExtractor.extract(fileURL: Self.fixture("bug66682.xlsb"), kind: .xlsb)
        XCTAssertTrue(result.text.contains("C3: FALSE (formula =B3)\n"), result.text)
        XCTAssertTrue(result.text.contains("C6: abcd (formula =B6)\n"), result.text)
        XCTAssertTrue(result.text.contains("C9: #NAME? (formula =unknownFunction() (array formula))\n"),
                      "the array formula whose top-left cell is C9 wins over the shared formula around it: \(result.text)")
        XCTAssertTrue(result.text.contains("C8: #REF! (formula =[ab]ab!C1)\n"), "the external sheet name comes from the externalLink part's BrtSupTabs: \(result.text)")
        XCTAssertFalse(result.text.contains("not decoded"), result.text)
        XCTAssertFalse(result.text.contains("not resolved"), result.text)
    }

    // MARK: - (b) Structured references (spec-built)

    func testSPEC_structuredReferences_renderedAsExcelShowsThem() throws {
        // Table "Sales" (idList 1) over A1:C4 — header row 1, columns Region, Q1 Total, Amount.
        let table = Self.tablePart(id: 1, name: "Sales", rows: 0...3, columns: 0, names: ["Region", "Q1 Total", "Amount"])
        var sheet = Self.rowHeader(1)
        // C2 = [@Region]&[@[Q1 Total]] — "#This Row" inside the table: no table name.
        sheet += Self.formulaCell(2, Self.cat(Self.ptgList(rowType: 0x10, columns: 1, first: 0, last: 0),
                                              Self.ptgList(rowType: 0x10, columns: 1, first: 1, last: 1), Self.bytes(0x08)))
        sheet += Self.rowHeader(5)
        let formulas: [Data] = [
            Self.cat(Self.ptgList(rowType: 0, columns: 1, first: 2, last: 2), Self.ptgFuncVar(1, 4)),   // A6 SUM(Sales[Amount])
            Self.ptgList(rowType: 0x02, columns: 1, first: 0, last: 0),                                  // B6 Sales[[#Headers],[Region]]
            Self.cat(Self.ptgList(rowType: 0x01, columns: 0), Self.ptgFunc(76)),                          // C6 ROWS(Sales[#All])
            Self.ptgList(rowType: 0x10, columns: 1, first: 2, last: 2),                                  // D6 Sales[@Amount] (outside the table)
            Self.ptgList(rowType: 0, columns: 2, first: 0, last: 2),                                     // E6 Sales[[Region]:[Amount]]
            Self.ptgList(rowType: 0x0C, columns: 1, first: 2, last: 2),                                  // F6 Sales[[#Data],[#Totals],[Amount]]
            Self.ptgList(rowType: 0, columns: 0),                                                         // G6 Sales[]
            Self.ptgList(rowType: 0x08, columns: 0),                                                      // H6 Sales[#Totals]
            Self.ptgList(rowType: 0x10, columns: 1, first: 1, last: 1),                                  // I6 Sales[@[Q1 Total]]
            Self.ptgList(rowType: 0, columns: 1, invalid: true),                                         // J6 #REF!
        ]
        for (column, rgce) in formulas.enumerated() { sheet += Self.formulaCell(column, rgce) }
        let result = try DocumentTextExtractor.extract(fileURL: try write("t.xlsb", package(sheet: sheet, table: table)), kind: .xlsb)
        XCTAssertTrue(result.text.contains("C2: 0 (formula =[@Region]&[@[Q1 Total]])\n"), result.text)
        XCTAssertTrue(result.text.contains(
            "A6: 0 (formula =SUM(Sales[Amount]))\tB6: 0 (formula =Sales[[#Headers],[Region]])\tC6: 0 (formula =ROWS(Sales[#All]))\t"
            + "D6: 0 (formula =Sales[@Amount])\tE6: 0 (formula =Sales[[Region]:[Amount]])\tF6: 0 (formula =Sales[[#Data],[#Totals],[Amount]])\t"
            + "G6: 0 (formula =Sales[])\tH6: 0 (formula =Sales[#Totals])\tI6: 0 (formula =Sales[@[Q1 Total]])\tJ6: 0 (formula =#REF!)\n"), result.text)
        XCTAssertFalse(result.text.contains("not decoded"), result.text)
    }

    func testSPEC_structuredReference_otherWorkbook_fromPtgExtraList_andArrayConstantStaysAligned() {
        // A nonresident PtgList (bit 13) carries its table in PtgExtraList: hasColumns, rowType, cch, name, SxSu with one SxOs.
        let list = Self.cat(Self.bytes(0x18, 0x19), Self.le16(0), Self.le16(1 | 1 << 10 | 1 << 13), Self.le32(0), Self.le16(0), Self.le16(0))
        let extraList = Self.cat(Self.bytes(1), Self.le16(0x02 << 0), Self.le16(6), "Budget".data(using: .utf16LittleEndian)!,
                                 Self.le16(0), Self.bytes(1), Self.bytes(0), Self.le16(2), Self.le16(4), "Cost".data(using: .utf16LittleEndian)!)
        // Followed by an array constant {1,2}: its PtgExtraArray comes after the PtgExtraList in rgcb.
        let array = Self.cat(Self.bytes(0x40), Data(count: 14))
        let extraArray = Self.cat(Self.le32(2), Self.le32(1), Self.bytes(1), Self.f64(1), Self.bytes(1), Self.f64(2))
        var context = XLSBFormulaContext()
        context.supBooks = [.external(target: "Plan.xlsx", tabs: [])]
        context.externSheets = [(0, -2, -2)]
        let text = XLSBFormulaDecoder.decode(rgce: Self.cat(list, array, Self.ptgFuncVar(2, 4)), rgcb: Self.cat(extraList, extraArray),
                                             base: .init(row: 0, column: 0), context: context)
        XCTAssertEqual(text, "SUM(Plan.xlsx!Budget[[#Headers],[Cost]],{1,2})")
    }

    // MARK: - Functions by name

    func testSPEC_everyDocumentedFunctionNamed_macroCommandsAndFutureAndAddInFunctions() throws {
        XCTAssertEqual(XLSBFunctionTable.functionCount, 476, "every Ftab id of [MS-XLSB] 2.5.98.10 except 255, plus CONVERT")
        XCTAssertEqual(XLSBFunctionTable.commandCount, 396, "every Cetab id of [MS-XLSB] 2.5.98.5")
        var sheet = Self.rowHeader(0)
        // A1 = EVALUATE("1+1") — Ftab 257, a macro-sheet function the old table named by number.
        sheet += Self.formulaCell(0, Self.cat(Self.ptgStr("1+1"), Self.ptgFunc(257)))
        // B1 = GET.CELL(48,A1) — Ftab 185 through PtgFuncVar.
        sheet += Self.formulaCell(1, Self.cat(Self.bytes(0x1E), Self.le16(48), Self.ptgRef(0, 0), Self.ptgFuncVar(2, 185)))
        // C1 = ALERT("x",2) — Cetab 118 (fCeFunc set), a macro command.
        sheet += Self.formulaCell(2, Self.cat(Self.ptgStr("x"), Self.bytes(0x1E), Self.le16(2), Self.ptgFuncVar(2, 118, command: true)))
        // D1 = XLOOKUP(A1,A2:A3,B2:B3) — future function: PtgName "_xlfn.XLOOKUP", the arguments, PtgFuncVar(4, 255).
        let area = Self.cat(Self.bytes(0x45), Self.le32(1), Self.le32(2), Self.le16(0xC000), Self.le16(0xC000))
        let areaB = Self.cat(Self.bytes(0x45), Self.le32(1), Self.le32(2), Self.le16(1 | 0xC000), Self.le16(1 | 0xC000))
        sheet += Self.formulaCell(3, Self.cat(Self.ptgName(1), Self.ptgRef(0, 0), area, areaB, Self.ptgFuncVar(4, 255)))
        // E1 = SORT(A2:A3) — "_xlfn._xlws.SORT"; F1 = @A2:A3 — "_xlfn.SINGLE"; G1 = A2# — "_xlfn.ANCHORARRAY".
        sheet += Self.formulaCell(4, Self.cat(Self.ptgName(2), area, Self.ptgFuncVar(2, 255)))
        sheet += Self.formulaCell(5, Self.cat(Self.ptgName(3), area, Self.ptgFuncVar(2, 255)))
        sheet += Self.formulaCell(6, Self.cat(Self.ptgName(4), Self.ptgRef(1, 0), Self.ptgFuncVar(2, 255)))
        // H1 = EUROCONVERT(A1,"DEM","EUR") — an add-in function: PtgNameX (xti 0 → BrtSupAddin, name 1 → BrtPlaceholderName).
        sheet += Self.formulaCell(7, Self.cat(Self.bytes(0x59), Self.le16(0), Self.le32(1), Self.ptgRef(0, 0), Self.ptgStr("DEM"), Self.ptgStr("EUR"), Self.ptgFuncVar(4, 255)))
        func brtName(_ name: String) -> Data {
            Self.biff12(0x0027, Self.cat(Self.le32(0x0B), Self.bytes(0), Self.le32(-1), Self.xlString(name), Self.le32(0), Self.le32(0), Self.le32(-1)))
        }
        let extra = Self.cat(brtName("_xlfn.XLOOKUP"), brtName("_xlfn._xlws.SORT"), brtName("_xlfn.SINGLE"), brtName("_xlfn.ANCHORARRAY"),
                             Self.biff12(0x029B, Data()), Self.biff12(0x0169, Self.xlString("EUROCONVERT")),
                             Self.biff12(0x016A, Self.cat(Self.le32(1), Self.le32(0), Self.le32(-2), Self.le32(-2))))
        let result = try DocumentTextExtractor.extract(fileURL: try write("f.xlsb", package(sheet: sheet, workbookExtra: extra)), kind: .xlsb)
        XCTAssertTrue(result.text.contains("A1: 0 (formula =EVALUATE(\"1+1\"))\tB1: 0 (formula =GET.CELL(48,A1))\tC1: 0 (formula =ALERT(\"x\",2))\t"), result.text)
        XCTAssertTrue(result.text.contains("D1: 0 (formula =XLOOKUP(A1,A2:A3,B2:B3))\tE1: 0 (formula =SORT(A2:A3))\tF1: 0 (formula =@A2:A3)\tG1: 0 (formula =A2#)\t"), result.text)
        XCTAssertTrue(result.text.contains("H1: 0 (formula =EUROCONVERT(A1,\"DEM\",\"EUR\"))\n"), result.text)
        XCTAssertFalse(result.text.contains("not decoded"), result.text)
    }

    func testSPEC_memFuncSubexpression_andPivotName_areRendered() {
        // =SUM(INDIRECT("A1"):A3) — Excel prefixes the reference subexpression with PtgMemFunc (cce).
        let sub = Self.cat(Self.ptgStr("A1"), Self.ptgFuncVar(1, 148), Self.ptgRef(2, 0), Self.bytes(0x11))
        let text = XLSBFormulaDecoder.decode(rgce: Self.cat(Self.bytes(0x29), Self.le16(sub.count), sub, Self.ptgFuncVar(1, 4)), rgcb: Data(),
                                             base: .init(row: 5, column: 0), context: XLSBFormulaContext())
        XCTAssertEqual(text, "SUM(INDIRECT(\"A1\"):A3)")
        let pivot = XLSBFormulaDecoder.decode(rgce: Self.cat(Self.bytes(0x18, 0x1D), Self.le32(0), Self.ptgInt(2), Self.bytes(0x05)), rgcb: Data(),
                                              base: nil, context: XLSBFormulaContext())
        XCTAssertEqual(pivot, "(PivotTable calculated name 1)*2")
    }

    private static func ptgInt(_ v: Int) -> Data { cat(bytes(0x1E), le16(v)) }
}
