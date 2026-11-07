//
//  ProjectBinaryReaderTests.swift
//  ArchiveCoreTests
//
//  Directive 2026-11-07 §6 "Other business formats": Microsoft Project
//  binary files (.mpp, Project 2000–2013) are read for search — the
//  document properties, every task's and resource's name and notes — on
//  files written by Project from Apache Tika's and MPXJ's corpora, including
//  MPXJ's password-protected files. Before this change .mpp had no
//  DocumentKind and the registry said "not implemented".
//

import XCTest
import Foundation
@testable import ArchiveCore

final class ProjectBinaryReaderTests: XCTestCase {

    static func fixture(_ relative: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/opensource/\(relative)")
    }

    private func extract(_ relative: String) throws -> OfficeTextExtractor.Result {
        try DocumentTextExtractor.extract(fileURL: Self.fixture(relative), kind: .mpp)
    }

    /// Tika's ProjectParserTest asserts the document properties of both
    /// files (title, subject, author, keywords, comments, company, manager,
    /// category); this reader also lists the tasks and resources Tika
    /// leaves unread.
    func testREAL_tikaProject2003And2007_propertiesTasksResources() throws {
        for name in ["tika/testPROJECT2003.mpp", "tika/testPROJECT2007.mpp"] {
            let result = try extract(name)
            XCTAssertTrue(result.text.hasPrefix("[Project: The quick brown fox jumps over the lazy dog]\n"), "\(name)\n\(result.text)")
            for line in ["Subject: Gym class featuring a brown fox and lazy dog", "Author: Nevin Nollop", "Keywords: Pangram, fox, dog",
                         "Comments: Comment Vulpes vulpes comment", "Company: CompanyA", "Manager: Mr Burns", "Category: Category1"] {
                XCTAssertTrue(result.text.contains(line + "\n"), "\(name): missing \(line)\n\(result.text)")
            }
            XCTAssertTrue(result.text.contains("[Tasks]\n1\tAquire fox\t\n2\tObtain Dog\t\n3\tFox does his jump\t\n"), "\(name)\n\(result.text)")
            XCTAssertTrue(result.text.contains("[Resources]\n1\tFox\t\n2\tDog\t\n"), "\(name)\n\(result.text)")
            XCTAssertEqual(result.components, ["Project data", "Tasks", "Resources"], name)
            XCTAssertTrue(result.skipped.isEmpty, "\(name): \(result.skipped)")
        }
        let url = Self.fixture("tika/testPROJECT2003.mpp")
        XCTAssertEqual(DocumentKind.detect(mimeType: "application/octet-stream", filename: "p.mpp"), .mpp)
        XCTAssertEqual(DocumentKind.detect(mimeType: "application/octet-stream", filename: "p.mpt"), .mpp)
        XCTAssertEqual(DocumentKind.detect(mimeType: "application/vnd.ms-project", filename: "p"), .mpp)
        XCTAssertEqual(DocumentTextExtractor.sniff(fileURL: url), .mpp, "the root CLSID names Project without the extension")
    }

    /// MPXJ's files across the three layouts: MPP12 (Project 2007) with its
    /// own field maps, MPP14 (Project 2010/2013) with a project summary task
    /// and resources whose IDs differ from their unique ids.
    func testREAL_mpxjMPP12AndMPP14_namesRead() throws {
        let columns = try extract("mpxj/mpp12columns.mpp")
        XCTAssertTrue(columns.text.contains("[Tasks]\n1\tTask One\t\n"), columns.text)
        XCTAssertTrue(columns.text.contains("[Resources]\n1\tResource One\t\n"), columns.text)
        let mpp14 = try extract("mpxj/ResourceIdAndUniqueId-project2013-mpp14.mpp")
        XCTAssertTrue(mpp14.text.hasPrefix("[Project: ResourceIdAndUniqueId]\n"), mpp14.text)
        XCTAssertTrue(mpp14.text.contains("\tResourceIdAndUniqueId\t"), mpp14.text)
        XCTAssertTrue(mpp14.text.contains("[Resources]\n11\tResource One\t\n12\tResource Two\t\n13\tResource Three\t\n"), mpp14.text)
        let sub = try extract("mpxj/SubprojectA-9.mpp")
        XCTAssertTrue(sub.text.contains("Author: Wade Golden\n"), sub.text)
        XCTAssertTrue(sub.text.contains("[Tasks]\n1\tSubproject Task A\t\n2\tSubproject Task A1\t\n3\tSubproject Task A2\t\n"), sub.text)
        XCTAssertTrue(sub.skipped.isEmpty, "\(sub.skipped)")
    }

    /// MPXJ's password fixtures: a read password locks the file (nothing
    /// read, nothing bypassed); a write-reservation password only encodes
    /// the blocks, which are decoded with the file's own code and said so.
    func testREAL_mpxjPasswords_lockedOrDecoded() throws {
        for name in ["mpxj/readpassword9.mpp", "mpxj/bothpassword9.mpp"] {
            XCTAssertThrowsError(try extract(name), name) { error in
                guard case OfficeTextExtractor.ExtractError.encrypted = error else { return XCTFail("\(name): \(error)") }
            }
        }
        let write = try extract("mpxj/writepassword9.mpp")
        XCTAssertTrue(write.text.contains("[Tasks]\n1\tTask One\t\n"), write.text)
        XCTAssertTrue(write.notText.contains(where: { $0.contains("write-reservation password") }), "\(write.notText)")
    }

    /// Project 98 (MPP8): recognised, properties given, tasks honestly not read.
    func testREAL_mpxjProject98_isAnHonestPartial() throws {
        let result = try extract("mpxj/DurationTest8.mpp")
        XCTAssertTrue(result.text.hasPrefix("[Project: DurationTest8]\n"), result.text)
        XCTAssertTrue(result.text.contains("Author: Jon Iles\n"), result.text)
        XCTAssertEqual(result.components, ["Project data"])
        XCTAssertEqual(result.skipped.count, 1)
        XCTAssertTrue(result.skipped[0].contains("Project 98") && result.skipped[0].contains("not read"), "\(result.skipped)")
        XCTAssertFalse(result.text.contains("[Tasks]"))
    }

    /// Notes are RTF: plain text through the MSG RTF reader (no public
    /// fixture carries notes, so the decoding is checked on a vector).
    func testNotes_rtfToPlainText() {
        let rtf = Array("{\\rtf1\\ansi\\deff0{\\fonttbl{\\f0 Arial;}}\\f0\\fs20 Order the \\b fox\\b0  food\\par Second line\\par}\u{0}".utf8)
        XCTAssertEqual(ProjectBinaryTextExtractor.notesText(rtf), "Order the fox food Second line")
        XCTAssertEqual(ProjectBinaryTextExtractor.notesText(Array("plain note\u{0}".utf8)), "plain note")
        XCTAssertEqual(ProjectBinaryTextExtractor.utf16String([0x54, 0x00, 0x61, 0x00, 0x73, 0x00, 0x6B, 0x00, 0x00, 0x00, 0x41, 0x00]), "Task")
    }

    /// Over the per-part guard the file is skipped with the stated reason;
    /// a non-Project OLE2 file is refused with the reason.
    func testGuardAndRefusal() throws {
        ExtractionLimits.baseOverride = ExtractionLimits(partBytes: 1024, totalArchiveBytes: 1_073_741_824, archiveDepth: 3)
        let guarded = try extract("tika/testPROJECT2003.mpp")
        ExtractionLimits.baseOverride = nil
        XCTAssertEqual(guarded.skipped.count, 1)
        XCTAssertTrue(guarded.skipped[0].contains("over the 1024-byte guard"), "\(guarded.skipped)")
        XCTAssertThrowsError(try DocumentTextExtractor.extract(fileURL: Self.fixture("tika/testVISIO.vsd"), kind: .mpp)) { error in
            guard case OfficeTextExtractor.ExtractError.notAPackage(let reason) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(reason.contains("not a Project file") || reason.contains("not a Microsoft Project file"), reason)
        }
    }

    /// 200 random mutations of each real fixture: a result or an error, never a trap.
    func testFuzz_mutatedFixturesNeverTrap() throws {
        var generator = SystemRandomNumberGenerator()
        for name in ["tika/testPROJECT2003.mpp", "tika/testPROJECT2007.mpp", "mpxj/writepassword9.mpp", "mpxj/ResourceIdAndUniqueId-project2013-mpp14.mpp"] {
            let original = try Data(contentsOf: Self.fixture(name))
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("fuzz-\(UUID().uuidString).mpp")
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
                do { _ = try ProjectBinaryTextExtractor.extract(fileURL: scratch); outcomes.results += 1 } catch { outcomes.errors += 1 }
            }
            XCTAssertEqual(outcomes.results + outcomes.errors, 200, name)
        }
    }
}
