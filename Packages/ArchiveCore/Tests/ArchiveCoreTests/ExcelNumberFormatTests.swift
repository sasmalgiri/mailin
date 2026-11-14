//
//  ExcelNumberFormatTests.swift
//  ArchiveCoreTests
//
//  Excel number formats rendered digit for digit (ExcelNumberFormatRenderer).
//
//  Oracles:
//   * Apache POI's format workbooks (test-data/spreadsheet/*FormatTests.xlsx,
//     Apache-2.0, in Fixtures/opensource/poi): column A is `=TEXT(C, B)` with
//     the result Excel cached when it saved the file (in a few rows, e.g. the
//     negative half of FormatConditionTests, the text POI's authors typed from
//     Excel's display), B the format code, C the value. Every row is checked.
//   * Examples from Microsoft's "Number format codes" / "Review guidelines
//     for customizing a number format" support articles (table below).
//   * Real workbooks through the readers: POI's Formatting.xlsx (XLSX) and
//     Tika's testEXCEL_various.xlsb / testEXCEL_dateFormats.xlsx.
//

import XCTest
@testable import ArchiveCore

final class ExcelNumberFormatTests: XCTestCase {

    private static func poi(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/opensource/poi/\(name)")
    }

    /// The Tika corpus: in the repository (maxmailinTests/Fixtures/opensource/tika) or the external fixture root.
    private static func tika(_ name: String) -> URL? {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url = url.deletingLastPathComponent() }
        let inRepo = url.appendingPathComponent("maxmailinTests/Fixtures/opensource/tika/\(name)")
        if FileManager.default.fileExists(atPath: inRepo.path) { return inRepo }
        let external = ExternalFixtures.shared.root.appendingPathComponent("opensource/tika/\(name)")
        return FileManager.default.fileExists(atPath: external.path) ? external : nil
    }

    // MARK: - POI oracle workbooks

    struct OracleRow { let row: Int; let expected: String; let code: String; let value: String; let valueType: String; let category: String }

    /// Rows of sheet 2 of a POI format workbook, and its date system.
    private static func oracleRows(_ name: String) throws -> (rows: [OracleRow], date1904: Bool) {
        let url = poi(name)
        let members = try ZIPArchiveReader.members(of: url)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("nf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        func part(_ path: String) throws -> Data {
            guard let member = members.first(where: { $0.name == path }) else { throw XCTSkip("\(name) has no \(path)") }
            let destination = scratch.appendingPathComponent(UUID().uuidString)
            try ZIPArchiveReader.extract(member, from: url, to: destination)
            return try Data(contentsOf: destination)
        }
        let shared = OOXMLTextCollector(.sharedStrings)
        XCTAssertTrue(shared.parse(try part("xl/sharedStrings.xml")))
        let workbook = OOXMLTextCollector(.raw)
        XCTAssertTrue(workbook.parse(try part("xl/workbook.xml")))
        let cells = CellCollector()
        let parser = XMLParser(data: try part("xl/worksheets/sheet2.xml"))
        parser.delegate = cells
        XCTAssertTrue(parser.parse())
        var rows: [OracleRow] = []
        for row in cells.rows.keys.sorted() where row > 1 {
            let r = cells.rows[row]!
            func text(_ column: String) -> String? {
                guard let cell = r[column] else { return nil }
                return cell.type == "s" ? Int(cell.value).flatMap { $0 < shared.sharedStrings.count ? shared.sharedStrings[$0] : nil } : cell.value
            }
            guard let expected = text("A"), let code = text("B"), let value = text("C") else { continue }
            rows.append(OracleRow(row: row, expected: expected, code: code, value: value, valueType: r["C"]?.type ?? "",
                                  category: text("D") ?? ""))
        }
        return (rows, workbook.date1904)
    }

    final class CellCollector: NSObject, XMLParserDelegate {
        var rows: [Int: [String: (type: String, value: String)]] = [:]
        private var reference = "", type = "", text = "", inValue = false, hasValue = false
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == "c" { reference = attributes["r"] ?? ""; type = attributes["t"] ?? ""; hasValue = false }
            if name == "v" { inValue = true; text = "" }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { if inValue { text += string } }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "v" { inValue = false; hasValue = true }
            if name == "c", hasValue {
                let column = String(reference.prefix { $0.isLetter })
                if let row = Int(reference.dropFirst(column.count)) { rows[row, default: [:]][column] = (type, text) }
            }
        }
    }

    /// Renders every numeric row and returns the disagreements.
    private func numericMismatches(_ name: String, minimumRows: Int) throws -> [String] {
        let (rows, date1904) = try Self.oracleRows(name)
        let numeric = rows.filter { $0.valueType.isEmpty || $0.valueType == "n" }
        XCTAssertGreaterThanOrEqual(numeric.count, minimumRows, "\(name): oracle rows read")
        return numeric.compactMap { row in
            guard let value = Double(row.value) else { return "\(name) row \(row.row): value \(row.value) not a number" }
            let got = ExcelNumberFormatRenderer.render(value, code: row.code, date1904: date1904)
            return got == row.expected ? nil : "\(name) row \(row.row) [\(row.category)] \(row.code) × \(row.value): expected \"\(row.expected)\", got \"\(got ?? "nil")\""
        }
    }

    func testPOI_numberFormatTests_everyRowMatchesExcelsCachedTEXT() throws {
        let mismatches = try numericMismatches("NumberFormatTests.xlsx", minimumRows: 300)
        XCTAssertEqual(mismatches, [], mismatches.joined(separator: "\n"))
    }

    func testPOI_generalFormatTests_everyNumberMatches() throws {
        let mismatches = try numericMismatches("GeneralFormatTests.xlsx", minimumRows: 60)
        XCTAssertEqual(mismatches, [], mismatches.joined(separator: "\n"))
    }

    func testPOI_dateFormatTests_1904Workbook_everyRowMatches() throws {
        let (_, date1904) = try Self.oracleRows("DateFormatTests.xlsx")
        XCTAssertTrue(date1904, "POI's format workbooks were saved by Mac Excel in the 1904 system")
        let mismatches = try numericMismatches("DateFormatTests.xlsx", minimumRows: 40)
        XCTAssertEqual(mismatches, [], mismatches.joined(separator: "\n"))
        let fractions = try numericMismatches("DateFormatNumberTests.xlsx", minimumRows: 10)
        XCTAssertEqual(fractions, [], "fractions of a second rounded at the shown precision: \(fractions.joined(separator: "\n"))")
    }

    func testPOI_elapsedFormatTests_everyRowMatches() throws {
        let mismatches = try numericMismatches("ElapsedFormatTests.xlsx", minimumRows: 50)
        XCTAssertEqual(mismatches, [], mismatches.joined(separator: "\n"))
    }

    func testPOI_formatConditionTests_everyRowMatches() throws {
        let mismatches = try numericMismatches("FormatConditionTests.xlsx", minimumRows: 40)
        XCTAssertEqual(mismatches, [], mismatches.joined(separator: "\n"))
    }

    /// Text rows: a format with a text section (`@`) renders it. The three
    /// literal-only codes (`"hi"`, `"h""I"`, `\h\i`) are where `TEXT()` and the
    /// cell differ: TEXT applies them to text, a cell shows the text as typed
    /// when the format has no text section (Microsoft: "If a number format
    /// does not include a text section, any text you type is not affected").
    func testPOI_textFormatTests_textSectionRows() throws {
        let (rows, _) = try Self.oracleRows("TextFormatTests.xlsx")
        let text = rows.filter { $0.valueType == "s" }
        XCTAssertEqual(text.count, 9)
        var checked = 0
        for row in text {
            let got = ExcelNumberFormatRenderer.renderText(row.value, code: row.code)
            if row.code.contains("@") {
                XCTAssertEqual(got, row.expected, "row \(row.row) \(row.code)"); checked += 1
            } else {
                XCTAssertNil(got, "no text section in \(row.code): the cell shows the text as typed")
            }
        }
        XCTAssertEqual(checked, 6)
    }

    // MARK: - Microsoft's documented examples

    func testDocumentedExamples_formatCodeTimesValue() {
        let cases: [(String, Double, String)] = [
            // Digit placeholders, decimals, thousands, scaling (Number format codes article).
            ("####.#", 1234.59, "1234.6"),
            ("#.000", 8.9, "8.900"),
            ("0.#", 0.631, "0.6"),
            ("#.0#", 12, "12.0"),
            ("#.0#", 1234.568, "1234.57"),
            ("???.???", 44.398, " 44.398"),
            ("#,###", 12000, "12,000"),
            ("#,", 12000, "12"),
            ("0.0,,", 12200000, "12.2"),
            ("#,##0.00", 1234.5, "1,234.50"),
            ("#,##0.00", 0.005, "0.01"),
            ("0.00", 1.005, "1.01"),
            ("0.00", -1.005, "-1.01"),
            ("0", 2.5, "3"),
            ("0", -2.5, "-3"),
            ("00000", 123, "00123"),
            ("000-00-0000", 123456789, "123-45-6789"),
            ("[<=9999999]###-####;(###) ###-####", 5551234, "555-1234"),
            ("[<=9999999]###-####;(###) ###-####", 2065551234, "(206) 555-1234"),
            // Sections.
            ("0.00;[Red]-0.00", -3.5, "-3.50"),
            ("0.00;(0.00)", -3.5, "(3.50)"),
            ("0.00;(0.00);\"zero\"", 0, "zero"),
            ("0.00;(0.00);\"zero\";\"text\"", 0, "zero"),
            ("[Blue]#,##0;[Red]#,##0", -1234, "1,234"),
            ("[>=100]0;0.00", 5, "5.00"),
            // Percent, scientific, fractions.
            ("0%", 0.15, "15%"),
            ("0.00%", 0.125, "12.50%"),
            ("0.00E+00", 12200000, "1.22E+07"),
            ("0.00E+00", 0.000123, "1.23E-04"),
            ("0.00E-00", 12200000, "1.22E07"),
            ("##0.0E+0", 12345, "12.3E+3"),
            ("##0.0E+0", 0.0012345, "1.2E-3"),
            ("0.00E+00", 0, "0.00E+00"),
            ("# ?/?", 5.25, "5 1/4"),
            ("# ?/?", 5.3, "5 2/7"),
            ("# ??/??", 5.3, "5  3/10"),
            ("# ???/???", 3.14159, "3  16/113"),
            ("?/?", 0.75, "3/4"),
            ("# ?/16", 1.5, "1 8/16"),
            ("# ?/8", 2.375, "2 3/8"),
            ("# ?/?", 5, "5    "),
            // Text, literals, padding, fill, currencies, locales.
            ("0.00 \"km\"", 12.5, "12.50 km"),
            ("\\$0.00", 3, "$3.00"),
            ("$#,##0.00", 1234.5, "$1,234.50"),
            ("_(\"$\"* #,##0.00_);_(\"$\"* \\(#,##0.00\\);_(\"$\"* \"-\"??_);_(@_)", 3.03, " $3.03 "),
            ("_(\"$\"* #,##0.00_);_(\"$\"* \\(#,##0.00\\);_(\"$\"* \"-\"??_);_(@_)", -3.03, " $(3.03)"),
            ("_(\"$\"* #,##0.00_);_(\"$\"* \\(#,##0.00\\);_(\"$\"* \"-\"??_);_(@_)", 0, " $-   "),
            ("[$€-407] #,##0.00", 1234.5, "€ 1,234.50"),
            ("#,##0.00 [$€-1]", 1234.5, "1,234.50 €"),
            ("[$-409]0.00", 1.5, "1.50"),
            ("[$USD] 0", 7, "USD 7"),
            ("0.00;-0.00;0.00;\"Text: \"@", 1, "1.00"),
            ("General", 1234.5, "1234.5"),
            ("General\" kg\"", 2.5, "2.5 kg"),
            ("General;-General", -4, "-4"),
            // Dates and times (1900 system, en-US names).
            ("m/d/yyyy", 45672, "1/15/2025"),
            ("mm/dd/yy", 45672, "01/15/25"),
            ("d-mmm-yy", 45672, "15-Jan-25"),
            ("dddd, mmmm d, yyyy", 45672, "Wednesday, January 15, 2025"),
            ("ddd mmm d", 45672, "Wed Jan 15"),
            ("mmmmm", 45672, "J"),
            ("yyyy-mm-dd hh:mm:ss", 45672.5, "2025-01-15 12:00:00"),
            ("h:mm AM/PM", 0.604166666666667, "2:30 PM"),
            ("h:mm:ss A/P", 0.25, "6:00:00 A"),
            ("hh:mm", 0.999999, "00:00"),
            ("h:mm", 0.4375 + 50.0 / 86400, "10:30"),
            ("mm:ss.0", 0.000694444 + 0.05 / 86400, "01:00.0"),
            ("[h]:mm:ss", 1.5, "36:00:00"),
            ("[mm]:ss", 0.0625, "90:00"),
            ("[ss]", 0.0625, "5400"),
            ("m/d/yyyy", 60, "2/29/1900"),
            ("m/d/yyyy", 61, "3/1/1900"),
            ("m/d/yyyy", 59, "2/28/1900"),
            ("m/d/yyyy", 1, "1/1/1900"),
            ("m/d/yyyy", 0, "1/0/1900"),
            ("dddd", 1, "Sunday"),
            ("m/d/yyyy", 2958465, "12/31/9999"),
            ("[$-F800]dddd, mmmm dd, yyyy", 45672, "Wednesday, January 15, 2025"),
            ("[$-F400]h:mm:ss AM/PM", 0.75, "6:00:00 PM"),
            ("[$-409]mmmm d, yyyy;@", 45672, "January 15, 2025"),
        ]
        var failures: [String] = []
        for (code, value, expected) in cases {
            let got = ExcelNumberFormatRenderer.render(value, code: code, date1904: false)
            if got != expected { failures.append("\(code) × \(value): expected \"\(expected)\", got \"\(got ?? "nil")\"") }
        }
        XCTAssertEqual(failures, [], failures.joined(separator: "\n"))
        // Excel shows ##### for what it cannot display; the renderer says nil and the reader keeps the stored value.
        XCTAssertNil(ExcelNumberFormatRenderer.render(-1, code: "m/d/yyyy", date1904: false))
        XCTAssertNil(ExcelNumberFormatRenderer.render(2958466, code: "m/d/yyyy", date1904: false))
        XCTAssertEqual(ExcelNumberFormatRenderer.render(-0.5, code: "[h]:mm", date1904: false), "-12:00", "elapsed time keeps its sign")
        // The 1904 system: serial 0 is 1 January 1904, a Friday.
        XCTAssertEqual(ExcelNumberFormatRenderer.render(0, code: "dddd yyyy-mm-dd", date1904: true), "Friday 1904-01-01")
        XCTAssertEqual(ExcelNumberFormatRenderer.render(44210, code: "m/d/yyyy", date1904: true), "1/15/2025")
        // Text sections.
        XCTAssertEqual(ExcelNumberFormatRenderer.renderText("abc", code: "0;-0;0;\"Text: \"@"), "Text: abc")
        XCTAssertNil(ExcelNumberFormatRenderer.renderText("abc", code: "0.00"))
    }

    func testBuiltinFormatIds_mapToTheirEnUSCodes() {
        let cases: [(Int, Double, String)] = [
            (1, 1234.567, "1235"), (2, 1234.567, "1234.57"), (3, 1234.567, "1,235"), (4, 1234.567, "1,234.57"),
            (5, -1234, "($1,234)"), (7, 1234.5, "$1,234.50 "), (9, 0.256, "26%"), (10, 0.256, "25.60%"),
            (11, 1234.5, "1.23E+03"), (12, 1.25, "1 1/4"), (13, 1.3, "1  3/10"),
            (14, 45672, "1/15/2025"), (15, 45672, "15-Jan-25"), (16, 45672, "15-Jan"), (17, 45672, "Jan-25"),
            (18, 0.6, "2:24 PM"), (19, 0.6, "2:24:00 PM"), (20, 0.6, "14:24"), (21, 0.6, "14:24:00"),
            (22, 45672.6, "1/15/2025 14:24"), (37, -1234, "(1,234)"), (39, 1234.5, "1,234.50"),
            (45, 0.0006944444444, "01:00"), (46, 1.25, "30:00:00"), (47, 0.0006944444444, "0100.0"), (48, 12345, "12.3E+3"),
            (27, 45672, "1/15/2025"), (32, 0.6, "14:24:00"), (50, 45672, "1/15/2025"), (59, 3.5, "4"), (67, 0.5, "50%"),
        ]
        for (id, value, expected) in cases {
            let format = ExcelNumberFormat.classify(id: id, code: nil)
            XCTAssertEqual(ExcelNumberFormatRenderer.render(value, code: format.code, date1904: false), expected, "built-in \(id) \(format.code)")
        }
        XCTAssertEqual(ExcelNumberFormat.classify(id: 27, code: nil).kind, .date)
        XCTAssertEqual(ExcelNumberFormat.classify(id: 32, code: nil).kind, .time)
    }

    // MARK: - Through the readers

    func testXLSX_reader_POIFormattingWorkbook_rendersEachCellAsExcelShowsIt() throws {
        let result = try OfficeTextExtractor.extract(fileURL: Self.poi("Formatting.xlsx"), kind: .xlsx)
        // "Dates, all 24th November 2006" (serial 39045) in six formats; "Numbers, all 10.52" in four.
        for line in ["A2: dd/mm/yyyy\tB2: 11/24/2006 (serial 39045)\n",          // built-in 14, Excel en-US
                     "A3: yyyy/mm/dd\tB3: 2006/11/24 (serial 39045)\n",
                     "A4: yyyy-mm-dd\tB4: 2006-11-24 (serial 39045)\n",
                     "A5: yy/mm/dd\tB5: 06/11/24 (serial 39045)\n",
                     "A6: dd/mm/yy\tB6: 24/11/06 (serial 39045)\n",
                     "A7: dd-mm-yy\tB7: 24-11-06 (serial 39045)\n",
                     "A10: nn.nn\tB10: 10.52\n",
                     "A11: nn.nnn\tB11: 10.520 (raw 10.52)\n",
                     "A12: nn.n\tB12: 10.5 (raw 10.52)\n",
                     "A13: £nn.nn\tB13: £10.52 (raw 10.52)\n"] {
            XCTAssertTrue(result.text.contains(line), "\(line.debugDescription) in \(result.text)")
        }
    }

    func testXLSB_reader_tikaVarious_dateCurrencyPercentRenderedAsExcelShowsThem() throws {
        guard let url = Self.tika("testEXCEL_various.xlsb") else { throw XCTSkip("Tika's testEXCEL_various.xlsb is not in this checkout or the fixture root") }
        let various = try DocumentTextExtractor.extract(fileURL: url, kind: .xlsb)
        XCTAssertTrue(various.text.contains("A10: date\tB10: 3/9/2017 (serial 42803)\n"), various.text)
        XCTAssertTrue(various.text.contains("A5: percent\tB5: 20% (raw 0.2)\n"), various.text)
        XCTAssertTrue(various.text.contains("A4: currency\tB4: $3.03 (raw 3.03)\n"), various.text)
    }

    func testXLSX_reader_tikaDateFormats_builtin14AsExcelEnUSShowsIt() throws {
        guard let url = Self.tika("testEXCEL_dateFormats.xlsx") else { throw XCTSkip("Tika's testEXCEL_dateFormats.xlsx is not in this checkout or the fixture root") }
        let dates = try OfficeTextExtractor.extract(fileURL: url, kind: .xlsx)
        XCTAssertTrue(dates.text.contains("A2: 9/20/2018 (serial 43363)\nA3: 8/10/1996 (serial 35287)\n"), dates.text)
    }
}
