//
//  VisioBinaryReaderTests.swift
//  ArchiveCoreTests
//
//  Directive 2026-11-07 §6 "Other business formats": binary Visio drawings
//  (.vsd, Visio 5–2010) are read for search — every shape's Text record
//  through the pointer tree and Visio's LZW — on files written by Visio
//  from Apache Tika's and Apache POI's corpora, including POI's malformed
//  NegativeChunkLength.vsd and ShortChunk1.vsd. Before this change .vsd had
//  no DocumentKind and the registry said "not implemented".
//

import XCTest
import Foundation
@testable import ArchiveCore

final class VisioBinaryReaderTests: XCTestCase {

    static func fixture(_ relative: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/opensource/\(relative)")
    }

    /// Tika's VisioParserTest asserts "Some random text, on a page".
    func testREAL_tikaVisio2003_textSniffAndComponent() throws {
        let url = Self.fixture("tika/testVISIO.vsd")
        XCTAssertEqual(DocumentKind.detect(mimeType: "application/octet-stream", filename: "d.vsd"), .vsd)
        XCTAssertEqual(DocumentKind.detect(mimeType: "application/vnd.visio", filename: "d"), .vsd)
        XCTAssertEqual(DocumentKind.detect(mimeType: "application/octet-stream", filename: "d.vsdx"), .vsdx, "the XML format keeps its own reader")
        XCTAssertEqual(DocumentTextExtractor.sniff(fileURL: url), .vsd, "the root CLSID names Visio without the extension")
        let result = try DocumentTextExtractor.extract(fileURL: url, kind: .vsd)
        XCTAssertTrue(result.text.contains("Some random text, on a page"), result.text)
        XCTAssertTrue(result.text.hasPrefix("[Visio text]\n[Shapes]\n"), result.text)
        XCTAssertEqual(result.components, ["Visio text"])
        XCTAssertTrue(result.skipped.isEmpty, "\(result.skipped)")
        XCTAssertTrue(result.notText.contains(where: { $0.contains("document properties") }), "\(result.notText)")
    }

    /// POI's drawings (Visio 2000 and 2003): the shape text of each is read.
    /// SimpleMacro.vsd carries no VBA storage despite its name, so none is
    /// claimed.
    func testREAL_poiDrawings_shapeTextRead() throws {
        let french = try DocumentTextExtractor.extract(fileURL: Self.fixture("poi/44501.vsd"), kind: .vsd)
        XCTAssertTrue(french.text.contains("Penible"), french.text)
        XCTAssertTrue(french.text.contains("Nouveau farine"), french.text)
        XCTAssertTrue(french.skipped.isEmpty, "\(french.skipped)")
        let macro = try DocumentTextExtractor.extract(fileURL: Self.fixture("poi/SimpleMacro.vsd"), kind: .vsd)
        XCTAssertTrue(macro.text.contains("This is a macro vector graphics drawing"), macro.text)
        XCTAssertFalse(macro.notText.contains(where: { $0.contains("VBA") }), "\(macro.notText)")
        let wide = try DocumentTextExtractor.extract(fileURL: Self.fixture("poi/44594.vsd"), kind: .vsd)
        XCTAssertTrue(wide.text.contains("Drag the side handles to change the width of the text block."), wide.text)
        XCTAssertEqual(wide.components, ["Visio text"])
    }

    /// POI's regression files: a chunk declaring an impossible length and a
    /// chunk cut short. Both yield their readable text (POI's tests open them
    /// too) and the damage is recorded by position, not hidden.
    func testREAL_poiMalformed_textReadAndTheDamageNamed() throws {
        let negative = try DocumentTextExtractor.extract(fileURL: Self.fixture("poi/NegativeChunkLength.vsd"), kind: .vsd)
        XCTAssertTrue(negative.text.contains("Feldbreite einstellen, um Absatzbreite festzulegen."), negative.text.prefix(500).description)
        XCTAssertTrue(negative.text.contains("Betätigung des"), negative.text.prefix(500).description)
        XCTAssertFalse(negative.text.contains("\u{FFFC}"), "field placeholders are not words")
        XCTAssertTrue(negative.skipped.contains(where: { $0.contains("declares") && $0.contains("read to the end") }), "\(negative.skipped)")
        let short = try DocumentTextExtractor.extract(fileURL: Self.fixture("poi/ShortChunk1.vsd"), kind: .vsd)
        XCTAssertTrue(!short.text.isEmpty || !short.skipped.isEmpty)
    }

    /// The LZW variant on a known vector: literals, then a back-reference
    /// into the shifted dictionary.
    func testLZW_literalsAndBackReference() {
        // flag 0xFF → 8 literals "ABCDEFGH"; flag 0x00 → code (b1 = 0, b2 = 0x05) → pos 0 → +18, length 8:
        // dictionary positions 18–25 are still zero in a fresh dictionary.
        let literal: [UInt8] = [0xFF] + Array("ABCDEFGH".utf8)
        XCTAssertEqual(VisioBinaryTextExtractor.lzwDecompress(literal[...]), Array("ABCDEFGH".utf8))
        // 18 literals fill dictionary slots 0–17; the code b1 = 0xEE, b2 = 0xF0 names position 0xFEE = 4078,
        // which is not above 4078 so it is shifted by 18 → 4096 → wraps to slot 0; length (0xF0 & 0x0F) + 3 = 3 → "ABC".
        let eighteen = Array("ABCDEFGHIJKLMNOPQR".utf8)
        let input: [UInt8] = [0xFF] + Array(eighteen[0..<8]) + [0xFF] + Array(eighteen[8..<16]) + [0x03] + Array(eighteen[16..<18]) + [0xEE, 0xF0]
        XCTAssertEqual(VisioBinaryTextExtractor.lzwDecompress(input[...]), eighteen + Array("ABC".utf8))
        XCTAssertEqual(VisioBinaryTextExtractor.lzwDecompress([][...]), [])
    }

    /// Over the per-part guard the file is skipped with the stated reason.
    func testOverTheGuard_isSkippedWithTheReason() throws {
        ExtractionLimits.baseOverride = ExtractionLimits(partBytes: 1024, totalArchiveBytes: 1_073_741_824, archiveDepth: 3)
        defer { ExtractionLimits.baseOverride = nil }
        let result = try DocumentTextExtractor.extract(fileURL: Self.fixture("tika/testVISIO.vsd"), kind: .vsd)
        XCTAssertEqual(result.skipped.count, 1)
        XCTAssertTrue(result.skipped[0].contains("over the 1024-byte guard"), "\(result.skipped)")
    }

    /// A Publisher file is an OLE2 file too — refused by name, not read as Visio.
    func testNotVisio_isRefusedWithTheReason() throws {
        XCTAssertThrowsError(try DocumentTextExtractor.extract(fileURL: Self.fixture("tika/testPUBLISHER.pub"), kind: .vsd)) { error in
            guard case OfficeTextExtractor.ExtractError.notAPackage(let reason) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(reason.contains("VisioDocument"), reason)
        }
        let junk = FileManager.default.temporaryDirectory.appendingPathComponent("junk-\(UUID().uuidString).vsd")
        try Data(repeating: 0x41, count: 2048).write(to: junk)
        defer { try? FileManager.default.removeItem(at: junk) }
        XCTAssertThrowsError(try DocumentTextExtractor.extract(fileURL: junk, kind: .vsd))
    }

    /// 200 random mutations of each real fixture: a result or an error, never a trap.
    func testFuzz_mutatedFixturesNeverTrap() throws {
        var generator = SystemRandomNumberGenerator()
        for name in ["tika/testVISIO.vsd", "poi/44594.vsd", "poi/SimpleMacro.vsd", "poi/ShortChunk1.vsd"] {
            let original = try Data(contentsOf: Self.fixture(name))
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("fuzz-\(UUID().uuidString).vsd")
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
                do { _ = try VisioBinaryTextExtractor.extract(fileURL: scratch); outcomes.results += 1 } catch { outcomes.errors += 1 }
            }
            XCTAssertEqual(outcomes.results + outcomes.errors, 200, name)
        }
    }
}
