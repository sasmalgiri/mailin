//
//  OneNoteReaderTests.swift
//  ArchiveCoreTests
//
//  Directive 2026-11-07 §6 "Other business formats": OneNote sections
//  (.one, MS-ONESTORE and the FSSHTTPB packaging) and notebook packages
//  (.onepkg, a cabinet) are read for search, on files written by OneNote
//  2010–2016, OneNote 2007 and Office 365 from Apache Tika's corpus, with
//  the strings Tika's OneNoteParserTest asserts. Before this change .one and
//  .onepkg had no DocumentKind and the registry said "not implemented".
//

import XCTest
import Foundation
@testable import ArchiveCore

final class OneNoteReaderTests: XCTestCase {

    static func fixture(_ relative: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(relative)")
    }

    static func tika(_ name: String) -> URL { fixture("opensource/tika/\(name)") }

    private func extract(_ name: String) throws -> OfficeTextExtractor.Result {
        try DocumentTextExtractor.extract(fileURL: Self.tika(name), kind: .one, logicalName: name)
    }

    /// Tika's testOneNote2013Doc2: the page title, two text areas and two
    /// paragraphs; no font names or property garbage in the text.
    func testREAL_tika2013Doc2_textSniffAndNoJunk() throws {
        XCTAssertEqual(DocumentKind.detect(mimeType: "application/octet-stream", filename: "x.one"), .one)
        XCTAssertEqual(DocumentKind.detect(mimeType: "application/onenote", filename: "x"), .one)
        XCTAssertEqual(DocumentTextExtractor.sniff(fileURL: Self.tika("testOneNote2.one")), .one, "the file-type GUID names a OneNote section without the extension")
        let result = try extract("testOneNote2.one")
        for expected in ["wow this is neat", "neat info about totally killin it bro", "Section1TextArea1", "Section1HeaderTitle", "Section1TextArea2"] {
            XCTAssertTrue(result.text.contains(expected), "missing \(expected) in\n\(result.text)")
        }
        assertNoJunk(result.text)
        XCTAssertTrue(result.text.hasPrefix("[OneNote section: testOneNote2]\n[Page 1]\n"), result.text)
        XCTAssertEqual(result.components, ["OneNote text"], "the structure was followed; nothing had to be recovered by scanning")
        XCTAssertTrue(result.skipped.isEmpty, "\(result.skipped)")
        XCTAssertFalse(result.notText.isEmpty, "the pictures on the pages are embedded files, listed as not text")
    }

    /// Tika's Doc3, Doc4 and OneNote 2016 strings.
    func testREAL_tikaDoc3Doc4And2016() throws {
        let doc3 = try extract("testOneNote3.one")
        for expected in ["awesome information about sports or some crap like that.", "Quit doing horrible things to me. Dang you.", "Section2TextArea1", "Section2HeaderTitle", "Section2TextArea2"] {
            XCTAssertTrue(doc3.text.contains(expected), "missing \(expected) in\n\(doc3.text)")
        }
        assertNoJunk(doc3.text)
        let doc4 = try extract("testOneNote4.one")
        for expected in ["way too much information about poptarts to handle.", "Section3TextArea1", "Section3HeaderTitle", "Section3TextArea2"] {
            XCTAssertTrue(doc4.text.contains(expected), "missing \(expected) in\n\(doc4.text)")
        }
        assertNoJunk(doc4.text)
        let n2016 = try extract("testOneNote2016.one")
        XCTAssertTrue(n2016.text.contains("So good"), n2016.text)
        XCTAssertTrue(n2016.text.contains("This is one note 2016"), n2016.text)
        assertNoJunk(n2016.text)
        let doc1 = try extract("testOneNote1.one")
        assertNoJunk(doc1.text)
        XCTAssertEqual(doc1.components, ["OneNote text"])
    }

    /// TIKA-4303: Chinese text survives (UTF-16LE, not a code page).
    func testREAL_tikaChineseNotes() throws {
        let result = try extract("test-tika-4303-Chinese-notes.one")
        XCTAssertTrue(result.text.contains("中文标题"), result.text)
    }

    /// Office 365 exports use the FSSHTTPB packaging. The page tree is
    /// followed (storage manifest → data root cell → newest revision →
    /// section's page series → each page's own cell), so the text is grouped
    /// exactly like the revision-store path: "[Page 1]" is the section's own
    /// object space (the cached page titles, in page order), then one
    /// "[Page N]" per page holding that page's title and content and nothing
    /// of another page's, then "[Earlier revisions and other objects]".
    func testREAL_tikaOffice365_pagesGroupedWithTheirTitles() throws {
        for name in ["testOneNoteFromOffice365.one", "testOneNoteFromOffice365-2.one"] {
            let result = try extract(name)
            let stem = (name as NSString).deletingPathExtension
            XCTAssertTrue(result.text.hasPrefix("[OneNote section: \(stem)]\n[Page 1]\n"), "\(name)\n\(result.text)")
            XCTAssertFalse(result.text.contains("Packaged layout (FSSHTTPB)"), "\(name): the pages were separated\n\(result.text)")
            let b = blocks(result.text)
            XCTAssertGreaterThanOrEqual(b.count, 4, "\(name)\n\(result.text)")
            guard b.count >= 4 else { continue }
            XCTAssertEqual(b.prefix(3).map(\.heading), ["Page 1", "Page 2", "Page 3"], name)
            XCTAssertEqual(b[0].lines, ["Section1Page1", "Section1Page2"], "\(name): the section lists its page titles in order")
            XCTAssertEqual(b[1].lines.prefix(2), ["Section1Page1Content", "Section1Page1"], "\(name): page 1's content, then its title")
            XCTAssertFalse(b[1].lines.contains("Section1Page2Content"), name)
            XCTAssertFalse(b[1].lines.contains("Section1Page2"), name)
            XCTAssertEqual(b[2].lines.prefix(2), ["Section1Page2Content", "Section1Page2"], "\(name): page 2's content, then its title")
            XCTAssertFalse(b[2].lines.contains("Section1Page1Content"), name)
            XCTAssertFalse(b[2].lines.contains("Section1Page1"), name)
            XCTAssertEqual(b.last?.heading, "Earlier revisions and other objects", name)
            XCTAssertEqual(result.components, ["OneNote text"], "\(name): structure followed, nothing scanned — \(result.skipped)")
            XCTAssertTrue(result.skipped.isEmpty, "\(name): \(result.skipped)")
            assertNoJunk(result.text)
        }
        // The second export also carries "Nick's Page": its title and note sit together on one page.
        let second = blocks(try extract("testOneNoteFromOffice365-2.one").text)
        func isNicksTitle(_ line: String) -> Bool { line.hasPrefix("Nick") && line.hasSuffix("s Page") }
        let nick = second.first { $0.heading.hasPrefix("Page ") && $0.lines.contains(where: isNicksTitle) }
        XCTAssertEqual(nick?.lines.count, 2, "\(second)")
        XCTAssertEqual(nick?.lines.first, "There are some really fricking cool notes here. Dude.", "\(second)")

        let tables = try extract("testOneNoteTablesLists.one")
        let t = blocks(tables.text)
        XCTAssertGreaterThanOrEqual(t.count, 3, tables.text)
        guard t.count >= 3 else { return }
        XCTAssertEqual(t[0].heading, "Page 1")
        XCTAssertEqual(t[0].lines, ["Page 1", "Page sdskgjhsdlf"], "the section lists its two page titles")
        XCTAssertEqual(t[1].heading, "Page 2")
        XCTAssertTrue(t[1].lines.contains("Page 1") && t[1].lines.contains("Bold Text"), "\(t[1])")
        XCTAssertEqual(t[2].heading, "Page 3")
        XCTAssertTrue(t[2].lines.contains("Page sdskgjhsdlf"), "\(t[2])")
        for expected in ["Table cell 1a", "Table cell 4b", "Bullet 2", "Indented bullet", "Number 2", "Letter a", "Numeral I", "Outdented number"] {
            XCTAssertTrue(t[2].lines.contains(expected), "missing \(expected) on the second page\n\(tables.text)")
            XCTAssertFalse(t[1].lines.contains(expected), "\(expected) leaked onto the first page")
        }
        XCTAssertTrue(tables.skipped.isEmpty, "\(tables.skipped)")
    }

    /// When the page tree cannot be followed (here the storage manifest's data
    /// root GUID is damaged) the text still comes, in storage order, under a
    /// label that says the pages were not separated.
    func testREAL_tikaOffice365_damagedPageTree_fallsBackToStorageOrder() throws {
        var bytes = [UInt8](try Data(contentsOf: Self.tika("testOneNoteFromOffice365.one")))
        let dataRoot: [UInt8] = [0xB9, 0xFA, 0xDE, 0x84, 0xA3, 0xAA, 0x0D, 0x4A, 0xA3, 0xA8, 0x52, 0x0C, 0x77, 0xAC, 0x70, 0x73]
        var hits = 0
        var i = 0
        while i + dataRoot.count <= bytes.count {
            if Array(bytes[i..<(i + dataRoot.count)]) == dataRoot { bytes[i + 15] ^= 0xFF; hits += 1; i += dataRoot.count } else { i += 1 }
        }
        XCTAssertGreaterThan(hits, 0, "the storage manifest names the data root cell")
        let result = try OneNoteTextExtractor.extract(data: Data(bytes), name: "damaged.one")
        XCTAssertTrue(result.text.contains("[Packaged layout (FSSHTTPB) — text in storage order, pages not separated]"), result.text)
        XCTAssertFalse(result.text.contains("[Page 1]"), result.text)
        XCTAssertTrue(result.text.contains("Section1Page1Content"), result.text)
        XCTAssertTrue(result.text.contains("Section1Page2Content"), result.text)
        XCTAssertEqual(result.components, ["OneNote text"])
    }

    /// Tika's testOneNote2007OrEarlier: a 2007-era file carries the packaging
    /// GUID but not a readable revision store; its text is still indexed,
    /// and the result says how it was obtained.
    func testREAL_tika2007_textIsReadAndTheMethodStated() throws {
        let result = try extract("testOneNote2007OrEarlier.one")
        XCTAssertTrue(result.text.contains("One note is the application.  The notebooks are the files within the application."), result.text.prefix(2000).description)
        XCTAssertTrue(result.text.contains("you can work on it and it will sync when you go back online."), result.text.prefix(2000).description)
        XCTAssertTrue(result.text.contains("Correlation between Outlook and OneNote"), result.text.prefix(2000).description)
        if result.components.contains("Recovered text") {
            XCTAssertTrue(result.skipped.contains(where: { $0.contains("scanning") }), "\(result.skipped)")
        }
    }

    /// An embedded Word document is counted as not text, not read as notes.
    func testREAL_tikaEmbeddedWordDoc_listedAsNotText() throws {
        let result = try extract("testOneNoteEmbeddedWordDoc.one")
        XCTAssertTrue(result.notText.contains(where: { $0.contains("embedded file") }), "\(result.notText)")
        assertNoJunk(result.text)
    }

    /// Tika's fuzzer regressions: a result or an error, never a trap. fuzz1
    /// (a revision's dependent is missing) and fuzz2 (an impossible property
    /// count) damage structures this reader follows, so the result says so;
    /// fuzz3's damage is in an external-file GUID string this reader does not
    /// interpret.
    func testREAL_tikaFuzzRegressions_neverTrap() throws {
        for (name, mustReport) in [("testOneNote-fuzz1.one", true), ("testOneNote-fuzz2.one", true), ("testOneNote-fuzz3.one", false)] {
            do {
                let result = try extract(name)
                if mustReport { XCTAssertFalse(result.skipped.isEmpty, "\(name): a damaged file must say so\n\(result.text.prefix(300))") }
            } catch {
                // an error is an acceptable outcome; a trap is not
            }
        }
    }

    /// The .onepkg fixture (built by Fixtures/derived/make_onepkg.py from two
    /// Tika sections): one MSZIP folder in 15 blocks, so the DEFLATE history
    /// carries across blocks; a stored table of contents listed as not text;
    /// an LZX folder named and not opened.
    func testOnepkg_cabinetOfSections() throws {
        let url = Self.fixture("derived/testOneNote.onepkg")
        XCTAssertEqual(DocumentKind.detect(mimeType: "application/octet-stream", filename: "n.onepkg"), .onepkg)
        XCTAssertEqual(DocumentTextExtractor.sniff(fileURL: url), .onepkg)
        let cabinet = try CabinetReader(data: try Data(contentsOf: url))
        XCTAssertEqual(cabinet.members.map(\.name), ["Notebook/Section 1.one", "Notebook/Section 2.one", "Notebook/Open Notebook.onetoc2", "Notebook/Locked Section.one"])
        XCTAssertEqual(cabinet.folders.map(\.compression), [.mszip, .none, .lzx])
        XCTAssertEqual(cabinet.folders[0].blockCount, 15)
        let section1 = try cabinet.extract(cabinet.members[0]), section2 = try cabinet.extract(cabinet.members[1])
        XCTAssertEqual(Data(section1), try Data(contentsOf: Self.tika("testOneNote2.one")), "byte-identical after 14 block boundaries")
        XCTAssertEqual(Data(section2), try Data(contentsOf: Self.tika("testOneNote3.one")))
        XCTAssertTrue(cabinet.notes.isEmpty, "\(cabinet.notes)")

        let result = try DocumentTextExtractor.extract(fileURL: url, kind: .onepkg, logicalName: "testOneNote.onepkg")
        XCTAssertTrue(result.text.hasPrefix("[OneNote notebook: testOneNote]\n"), result.text)
        XCTAssertTrue(result.text.contains("[OneNote section: Notebook/Section 1]"), result.text)
        XCTAssertTrue(result.text.contains("[OneNote section: Notebook/Section 2]"), result.text)
        XCTAssertTrue(result.text.contains("wow this is neat"), result.text)
        XCTAssertTrue(result.text.contains("Section2HeaderTitle"), result.text)
        XCTAssertTrue(result.notText.contains("Notebook/Open Notebook.onetoc2 (table of contents)"), "\(result.notText)")
        XCTAssertEqual(result.skipped, ["Notebook/Locked Section.one (LZX-compressed cabinet folder, not opened)"])
    }

    /// Over the per-part guard the file is skipped with the stated reason.
    func testOverTheGuard_isSkippedWithTheReason() throws {
        ExtractionLimits.baseOverride = ExtractionLimits(partBytes: 1024, totalArchiveBytes: 1_073_741_824, archiveDepth: 3)
        defer { ExtractionLimits.baseOverride = nil }
        let one = try extract("testOneNote2016.one")
        XCTAssertEqual(one.skipped.count, 1)
        XCTAssertTrue(one.skipped[0].contains("over the 1024-byte guard"), "\(one.skipped)")
        XCTAssertTrue(ExtractionLimits.noteNamesALimit(one.skipped[0]))
        let pkg = try DocumentTextExtractor.extract(fileURL: Self.fixture("derived/testOneNote.onepkg"), kind: .onepkg)
        XCTAssertEqual(pkg.skipped.count, 1)
        XCTAssertTrue(pkg.skipped[0].contains("over the 1024-byte guard"), "\(pkg.skipped)")
    }

    /// Not a OneNote file: refused by the bytes, with the reason.
    func testNotOneNote_isRefused() throws {
        let junk = FileManager.default.temporaryDirectory.appendingPathComponent("junk-\(UUID().uuidString).one")
        try Data(repeating: 0x41, count: 2048).write(to: junk)
        defer { try? FileManager.default.removeItem(at: junk) }
        XCTAssertThrowsError(try DocumentTextExtractor.extract(fileURL: junk, kind: .one)) { error in
            guard case OfficeTextExtractor.ExtractError.notAPackage(let reason) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(reason.contains("not a OneNote section"), reason)
        }
        XCTAssertThrowsError(try DocumentTextExtractor.extract(fileURL: junk, kind: .onepkg))
        // A truncated section (header plus a sliver): the structure is unreachable and the result says so.
        let truncated = FileManager.default.temporaryDirectory.appendingPathComponent("short-\(UUID().uuidString).one")
        try Data(contentsOf: Self.tika("testOneNote1.one")).prefix(2048).write(to: truncated)
        defer { try? FileManager.default.removeItem(at: truncated) }
        do {
            let result = try DocumentTextExtractor.extract(fileURL: truncated, kind: .one)
            XCTAssertTrue(result.skipped.contains(where: { $0.contains("outside the file") || $0.contains("scanning") }), "\(result.skipped)")
        } catch OfficeTextExtractor.ExtractError.noTextParts {
        }
    }

    /// 200 random mutations of each fixture (sections of both layouts and the
    /// package): a result or an error, never a trap.
    func testFuzz_mutatedFixturesNeverTrap() throws {
        var generator = SystemRandomNumberGenerator()
        let cases: [(URL, DocumentKind)] = [
            (Self.tika("testOneNote2016.one"), .one), (Self.tika("testOneNote.one"), .one),
            (Self.tika("testOneNoteFromOffice365.one"), .one), (Self.fixture("derived/testOneNote.onepkg"), .onepkg),
        ]
        for (url, kind) in cases {
            let original = try Data(contentsOf: url)
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("fuzz-\(UUID().uuidString).\(kind.rawValue)")
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
                do { _ = try DocumentTextExtractor.extract(fileURL: scratch, kind: kind); outcomes.results += 1 } catch { outcomes.errors += 1 }
            }
            XCTAssertEqual(outcomes.results + outcomes.errors, 200, url.lastPathComponent)
        }
    }

    /// The "[heading]" blocks of a section's text, in order.
    private func blocks(_ text: String) -> [(heading: String, lines: [String])] {
        var out: [(heading: String, lines: [String])] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            if line.hasPrefix("[") && line.hasSuffix("]") && !line.hasPrefix("[OneNote section:") {
                out.append((String(line.dropFirst().dropLast()), []))
            } else if !out.isEmpty {
                out[out.count - 1].lines.append(line)
            }
        }
        return out
    }

    private func assertNoJunk(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(text.contains("Calibri"), "font names are not notes", file: file, line: line)
        for scalar in ["\u{5902}", "\u{83F2}", "\u{432F}", "\u{01E1}"] {
            XCTAssertFalse(text.contains(scalar), "binary property read as UTF-16", file: file, line: line)
        }
    }
}
