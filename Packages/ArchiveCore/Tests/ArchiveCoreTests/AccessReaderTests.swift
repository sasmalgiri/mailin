//
//  AccessReaderTests.swift
//  ArchiveCoreTests
//
//  Directive 2026-11-07 §6 "Other business formats": Microsoft Access
//  databases (Jet 3 .mdb, Jet 4 .mdb, ACE .accdb) are read for search —
//  every user table's rows as column=value — on files written by Access 97,
//  2000, 2002–2003, 2007 and 2010 from Apache Tika's corpus, with the
//  values Tika's JackcessParserTest asserts. Before this change .mdb/.accdb
//  had no DocumentKind and the registry said "not implemented".
//

import XCTest
import Foundation
@testable import ArchiveCore

final class AccessReaderTests: XCTestCase {

    static func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/opensource/tika/\(name)")
    }

    private func extract(_ name: String) throws -> OfficeTextExtractor.Result {
        try DocumentTextExtractor.extract(fileURL: Self.fixture(name), kind: .mdb)
    }

    /// Tika's JackcessParserTest on the same database saved three ways
    /// (Access 2007 .accdb, Access 2000 .mdb, Access 2002–2003 .mdb): the
    /// ShortTextField column, the 2015-06-24 date, the rich-text memo, the
    /// Chinese text, the plain memo; the OLE column is listed as not text.
    func testREAL_tikaAccess2_threeSaves_sameRows() throws {
        for name in ["testAccess2.accdb", "testAccess2_2000.mdb", "testAccess2_2002-2003.mdb"] {
            let result = try extract(name)
            XCTAssertEqual(result.components, ["Access tables"], name)
            XCTAssertTrue(result.text.contains("[Table: Table1]\n"), "\(name)\n\(result.text)")
            XCTAssertTrue(result.text.contains("ShortTextField=the quick\t"), "\(name)\n\(result.text)")
            XCTAssertTrue(result.text.contains("DateField=2015-06-24"), "\(name)\n\(result.text)")
            XCTAssertTrue(result.text.contains("over the <strong>bold </strong><em>italic</em> dog"), "\(name)\n\(result.text)")
            XCTAssertTrue(result.text.contains("ShortTextField=普林斯顿大学"), "\(name)\n\(result.text)")
            XCTAssertTrue(result.text.contains("PlainTextMemo=red and brown"), "\(name)\n\(result.text)")
            XCTAssertTrue(result.text.contains("CurrencyField=6.23"), "\(name)\n\(result.text)")
            XCTAssertTrue(result.text.contains("YesNoField=Yes"), "\(name)\n\(result.text)")
            XCTAssertTrue(result.text.contains("NumberField=3"), "\(name)\n\(result.text)")
            XCTAssertTrue(result.text.contains("HyperLinkField=#http://tika.apach.org#"), "\(name)\n\(result.text)")
            XCTAssertTrue(result.text.contains("[Table: Table2]\nID=1\tLongDateTime=2015-06-29\n"), "\(name)\n\(result.text)")
            XCTAssertEqual(result.notText, ["Table1.OLEObject (OLE objects in 1 rows)"], name)
            XCTAssertTrue(result.skipped.isEmpty, "\(name): \(result.skipped)")
            XCTAssertFalse(result.text.contains("MSys"), "system tables are not dumped")
        }
        XCTAssertEqual(DocumentKind.detect(mimeType: "application/octet-stream", filename: "d.mdb"), .mdb)
        XCTAssertEqual(DocumentKind.detect(mimeType: "application/octet-stream", filename: "d.accdb"), .mdb)
        XCTAssertEqual(DocumentKind.detect(mimeType: "application/x-msaccess", filename: "d"), .mdb)
        XCTAssertEqual(DocumentTextExtractor.sniff(fileURL: Self.fixture("testAccess2.accdb")), .mdb)
        XCTAssertEqual(DocumentTextExtractor.sniff(fileURL: Self.fixture("testAccess_V1997.mdb")), .mdb)
    }

    /// Access 97 (Jet 3: 2 KiB pages, code-page text, the jump-table row
    /// layout): Tika asserts "hijklmnop"; the whole second row is checked —
    /// byte, integer, long, single, date, double and Yes/No columns.
    func testREAL_tikaAccess97_jet3Rows() throws {
        let result = try extract("testAccess_V1997.mdb")
        XCTAssertTrue(result.text.hasPrefix("[Access database: testAccess_V1997 — Access 97 (Jet 3)]\n[Table: Table1]\n"), result.text)
        XCTAssertTrue(result.text.contains("A=abcdefg\tB=hijklmnop\tC=2\tD=222\tE=333333333\tF=444.555\tG=1974-09-21\tH=3.5\tI=Yes\n"), result.text)
        XCTAssertTrue(result.text.contains("A=a\tB=b\tC=0\tD=0\tE=0\tF=0\tG=1981-12-12\tH=0\tI=No\n"), result.text)
        for table in ["Table2", "Table3", "Table4"] { XCTAssertTrue(result.text.contains("[Table: \(table)]\n(no rows)\n"), result.text) }
        XCTAssertTrue(result.skipped.isEmpty, "\(result.skipped)")
    }

    /// An Access 2000 database whose four user tables hold no rows is
    /// listed table by table, with nothing invented.
    func testREAL_tikaAccess2000_emptyTablesListed() throws {
        let result = try extract("testACCESS.mdb")
        for table in ["Titles", "Tracks", "Menus", "Batch"] { XCTAssertTrue(result.text.contains("[Table: \(table)]\n"), result.text) }
        XCTAssertEqual(result.components, ["Access tables"])
    }

    /// An encrypted .accdb (Tika's, password "tika") is reported locked;
    /// nothing is read and nothing is bypassed.
    func testREAL_tikaEncrypted_isLocked() throws {
        XCTAssertThrowsError(try extract("testAccess2_encrypted.accdb")) { error in
            guard case OfficeTextExtractor.ExtractError.encrypted = error else { return XCTFail("\(error)") }
        }
    }

    /// Value decoding on vectors: compressed Unicode toggling, currency
    /// scaling, NUMERIC words, Access dates with and without a time.
    func testValueDecoding() throws {
        XCTAssertEqual(AccessTextExtractor.scaled(62300, scale: 4), "6.23")
        XCTAssertEqual(AccessTextExtractor.scaled(-5, scale: 4), "-0.0005")
        XCTAssertEqual(AccessTextExtractor.scaled(1_000_000, scale: 4), "100")
        XCTAssertEqual(AccessTextExtractor.dateString(42179), "2015-06-24")
        XCTAssertEqual(AccessTextExtractor.dateString(42179.5), "2015-06-24 12:00:00")
        XCTAssertEqual(AccessTextExtractor.dateString(-1.75), "1899-12-29 18:00:00")
        var numeric = [UInt8](repeating: 0, count: 17)
        numeric[13] = 0xD2; numeric[14] = 0x04                            // 1234 in the last (least significant) little-endian word
        XCTAssertEqual(AccessTextExtractor.numeric(numeric, scale: 2), "12.34")
        numeric[0] = 1
        XCTAssertEqual(AccessTextExtractor.numeric(numeric, scale: 0), "-1234")
        let db = AccessTextExtractor.Database(bytes: [UInt8](repeating: 0, count: 4096), format: .init(jet3: false, version: "test"))
        let table = try AccessTextExtractor.Table(db: db, definition: syntheticDefinition(), definitionPage: 2, name: "t")
        XCTAssertEqual(table.decodeText([0xFF, 0xFE, 0x61, 0x62, 0x00, 0x2E, 0x4E, 0x00, 0x63]), "ab丮c", "8-bit run, toggle, 16-bit run, toggle, 8-bit run")
        XCTAssertEqual(table.decodeText([0x61, 0x00, 0x62, 0x00]), "ab")
    }

    /// A minimal Jet 4 table definition with no columns and no indexes.
    private func syntheticDefinition() -> [UInt8] {
        var d = [UInt8](repeating: 0, count: 4096)
        d[0] = 0x02
        return d
    }

    /// Over the per-part guard the file is skipped with the stated reason;
    /// a non-Access file is refused with the reason.
    func testGuardAndRefusal() throws {
        ExtractionLimits.baseOverride = ExtractionLimits(partBytes: 1024, totalArchiveBytes: 1_073_741_824, archiveDepth: 3)
        let guarded = try extract("testAccess2.accdb")
        ExtractionLimits.baseOverride = nil
        XCTAssertEqual(guarded.skipped.count, 1)
        XCTAssertTrue(guarded.skipped[0].contains("over the 1024-byte guard"), "\(guarded.skipped)")
        XCTAssertThrowsError(try DocumentTextExtractor.extract(fileURL: Self.fixture("testVISIO.vsd"), kind: .mdb)) { error in
            guard case OfficeTextExtractor.ExtractError.notAPackage(let reason) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(reason.contains("not an Access database"), reason)
        }
    }

    /// 200 random mutations of each real fixture: a result or an error, never a trap.
    func testFuzz_mutatedFixturesNeverTrap() throws {
        var generator = SystemRandomNumberGenerator()
        for name in ["testAccess2.accdb", "testAccess2_2000.mdb", "testAccess_V1997.mdb", "testACCESS.mdb"] {
            let original = try Data(contentsOf: Self.fixture(name))
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("fuzz-\(UUID().uuidString).mdb")
            defer { try? FileManager.default.removeItem(at: scratch) }
            var outcomes = (results: 0, errors: 0)
            for _ in 0..<200 {
                var mutated = original
                let flips = Int.random(in: 1...32, using: &generator)
                for _ in 0..<flips {
                    let i = Int.random(in: 0..<mutated.count, using: &generator)
                    mutated[i] = UInt8.random(in: 0...255, using: &generator)
                }
                if Bool.random(using: &generator) { mutated = mutated.prefix(Int.random(in: 1..<mutated.count, using: &generator)) }
                try mutated.write(to: scratch)
                do { _ = try AccessTextExtractor.extract(fileURL: scratch); outcomes.results += 1 } catch { outcomes.errors += 1 }
            }
            XCTAssertEqual(outcomes.results + outcomes.errors, 200, name)
        }
    }
}
