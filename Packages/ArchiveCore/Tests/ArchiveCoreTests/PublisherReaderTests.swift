//
//  PublisherReaderTests.swift
//  ArchiveCoreTests
//
//  Directive 2026-11-07 §6 "Other business formats": Microsoft Publisher
//  files are read for search — the Quill text of every text box, the
//  hyperlink targets — on files written by Publisher itself (Apache Tika's
//  testPUBLISHER.pub, Apache POI's Sample.pub with its Sample.txt ground
//  truth and LinkAt10.pub). Before this change `.pub` had no DocumentKind
//  and the registry said "not implemented".
//

import XCTest
import Foundation
@testable import ArchiveCore

final class PublisherReaderTests: XCTestCase {

    static func fixture(_ relative: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/opensource/\(relative)")
    }

    /// Tika's PublisherParserTest asserts "0123456789" and "abcdef".
    func testREAL_tikaPublisher_textAndComponent() throws {
        let url = Self.fixture("tika/testPUBLISHER.pub")
        XCTAssertEqual(DocumentKind.detect(mimeType: "application/octet-stream", filename: "testPUBLISHER.pub"), .pub)
        XCTAssertEqual(DocumentTextExtractor.sniff(fileURL: url), .pub, "the root CLSID names Publisher without the extension")
        let result = try DocumentTextExtractor.extract(fileURL: url, kind: .pub)
        XCTAssertTrue(result.text.contains("0123456789"), result.text)
        XCTAssertTrue(result.text.contains("abcdef"), result.text)
        XCTAssertEqual(result.components.first, "Publisher text")
        XCTAssertTrue(result.text.hasPrefix("[Publisher text]\n"))
        XCTAssertTrue(result.skipped.isEmpty, "\(result.skipped)")
        XCTAssertFalse(result.notText.isEmpty, "Escher drawing records are listed as not text")
    }

    /// POI's Sample.txt is the author's record of every line in Sample.pub:
    /// two pages of text boxes, a table, hyperlinks. Every non-empty line of
    /// the record must appear in the extracted text, and the four link
    /// targets the file carries are listed under [Links].
    func testREAL_poiSample_everyRecordedLineIsRead_andLinksListed() throws {
        let result = try DocumentTextExtractor.extract(fileURL: Self.fixture("poi/Sample.pub"), kind: .pub)
        let record = try String(contentsOf: Self.fixture("poi/Sample.txt"), encoding: .utf8)
        let normalized = result.text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        var missing: [String] = []
        for rawLine in record.components(separatedBy: .newlines) {
            let line = rawLine.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            // A table row in the record is its cells side by side; the reader keeps each cell as its own line.
            let cells = rawLine.components(separatedBy: "  ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if !normalized.contains(line) && !cells.allSatisfy({ normalized.contains($0) }) { missing.append(line) }
        }
        XCTAssertTrue(missing.isEmpty, "lines of Sample.txt not found: \(missing)\n\n\(result.text)")
        XCTAssertTrue(result.components.contains("Links"), "\(result.components)")
        XCTAssertTrue(result.text.contains("http://poi.apache.org/"), result.text)
        XCTAssertTrue(result.text.contains("mailto:dev@poi.apache.org"), result.text)
    }

    /// LinkAt10.pub: one hyperlink at character 10.
    func testREAL_poiLinkAt10_oneLink() throws {
        let result = try DocumentTextExtractor.extract(fileURL: Self.fixture("poi/LinkAt10.pub"), kind: .pub)
        XCTAssertTrue(result.components.contains("Links"), "\(result.components)")
        XCTAssertTrue(result.text.contains("http://poi.apache.org/"), result.text)
    }

    /// A Word document is an OLE2 file too — it is refused by name, not read as Publisher.
    func testNotPublisher_isRefusedWithTheReason() throws {
        let word = Self.fixture("poi/LinkAt10.pub").deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("maxmailinTests/Fixtures/opensource/tika/testWORD_protected_passtika.doc")
        if FileManager.default.fileExists(atPath: word.path) {
            XCTAssertThrowsError(try DocumentTextExtractor.extract(fileURL: word, kind: .pub)) { error in
                guard case OfficeTextExtractor.ExtractError.notAPackage(let reason) = error else { return XCTFail("\(error)") }
                XCTAssertTrue(reason.contains("Quill"), reason)
            }
        }
        let junk = FileManager.default.temporaryDirectory.appendingPathComponent("junk-\(UUID().uuidString).pub")
        try Data(repeating: 0x41, count: 2048).write(to: junk)
        defer { try? FileManager.default.removeItem(at: junk) }
        XCTAssertThrowsError(try DocumentTextExtractor.extract(fileURL: junk, kind: .pub))
    }

    /// Over the per-part guard the file is skipped with the stated reason, never read half-way.
    func testOverTheGuard_isSkippedWithTheReason() throws {
        ExtractionLimits.baseOverride = ExtractionLimits(partBytes: 1024, totalArchiveBytes: 1_073_741_824, archiveDepth: 3)
        defer { ExtractionLimits.baseOverride = nil }
        let result = try DocumentTextExtractor.extract(fileURL: Self.fixture("tika/testPUBLISHER.pub"), kind: .pub)
        XCTAssertEqual(result.skipped.count, 1)
        XCTAssertTrue(result.skipped[0].contains("over the 1024-byte guard"), "\(result.skipped)")
        XCTAssertTrue(ExtractionLimits.noteNamesALimit(result.skipped[0]))
    }

    /// 200 random mutations of each real fixture: the reader returns a result
    /// or throws, and never traps.
    func testFuzz_mutatedFixturesNeverTrap() throws {
        var generator = SystemRandomNumberGenerator()
        for name in ["tika/testPUBLISHER.pub", "poi/Sample.pub", "poi/LinkAt10.pub"] {
            let original = try Data(contentsOf: Self.fixture(name))
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("fuzz-\(UUID().uuidString).pub")
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
                do { _ = try PublisherTextExtractor.extract(fileURL: scratch); outcomes.results += 1 } catch { outcomes.errors += 1 }
            }
            XCTAssertEqual(outcomes.results + outcomes.errors, 200, name)
        }
    }
}
