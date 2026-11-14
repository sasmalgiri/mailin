//
//  ProjectBinaryReaderTests.swift
//  ArchiveCoreTests
//
//  Directive 2026-11-07 §6 "Other business formats": Microsoft Project
//  binary files (.mpp, Project 2000–2013) are read for search — the
//  document properties, every task's and resource's name and notes — on
//  files written by Project from Apache Tika's and MPXJ's corpora, including
//  MPXJ's password-protected files. Before this change .mpp had no
//  DocumentKind and the registry said "not implemented". Since 2026-11-09
//  each task also carries start, finish and duration, and the resource
//  assignments (units, work) are listed — checked against MPXJ's own test
//  assertions (MppTaskTest) and an MSPDI twin saved by Project.
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
            // Dates/durations/assignments here have no external oracle (Tika does not read
            // them); the oracle-checked values are in the MPXJ tests below.
            XCTAssertTrue(result.text.contains("[Tasks]\n1\tAquire fox\t2011-11-24T08:00:00\t2011-11-24T17:00:00\t1 day\t\n2\tObtain Dog\t2011-11-24T08:00:00\t2011-11-24T17:00:00\t1 day\t\n3\tFox does his jump\t2011-11-25T08:00:00\t2011-11-25T17:00:00\t1 day\t\n"), "\(name)\n\(result.text)")
            XCTAssertTrue(result.text.contains("[Resources]\n1\tFox\t\n2\tDog\t\n"), "\(name)\n\(result.text)")
            XCTAssertTrue(result.text.contains("[Assignments]\ntask 1 (Aquire fox) → resource 1 (Fox)\t100%\t8 hrs\ntask 2 (Obtain Dog) → resource 2 (Dog)\t100%\t8 hrs\n"), "\(name)\n\(result.text)")
            XCTAssertEqual(result.components, ["Project data", "Tasks", "Resources", "Assignments"], name)
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
        XCTAssertTrue(columns.text.contains("[Tasks]\n1\tTask One\t2010-03-08T08:00:00\t2010-03-08T17:00:00\t1 day\t\n"), columns.text)
        XCTAssertTrue(columns.text.contains("[Resources]\n1\tResource One\t\n"), columns.text)
        XCTAssertTrue(columns.skipped.isEmpty, "\(columns.skipped)")
        let mpp14 = try extract("mpxj/ResourceIdAndUniqueId-project2013-mpp14.mpp")
        XCTAssertTrue(mpp14.text.hasPrefix("[Project: ResourceIdAndUniqueId]\n"), mpp14.text)
        XCTAssertTrue(mpp14.text.contains("\tResourceIdAndUniqueId\t"), mpp14.text)
        XCTAssertTrue(mpp14.text.contains("[Resources]\n11\tResource One\t\n12\tResource Two\t\n13\tResource Three\t\n"), mpp14.text)
        XCTAssertTrue(mpp14.skipped.isEmpty, "\(mpp14.skipped)")
        let sub = try extract("mpxj/SubprojectA-9.mpp")
        XCTAssertTrue(sub.text.contains("Author: Wade Golden\n"), sub.text)
        XCTAssertTrue(sub.text.contains("[Tasks]\n1\tSubproject Task A\t2006-08-28T08:00:00\t2006-08-29T17:00:00\t2 days\t\n2\tSubproject Task A1\t2006-08-28T08:00:00\t2006-08-28T17:00:00\t1 day\t\n3\tSubproject Task A2\t2006-08-29T08:00:00\t2006-08-29T17:00:00\t1 day\t\n"), sub.text)
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
        XCTAssertTrue(write.text.contains("[Tasks]\n1\tTask One\t2004-08-11T08:00:00\t2004-08-11T17:00:00\t1 day\t\n"), write.text)
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

    /// MPXJ's MppTaskTest.testBasicTask asserts, for the same project saved
    /// as MPP9, MPP12 and MPP14 (mpp9task / mpp12task / mpp14task.mpp):
    /// task 1 "Task #1", start 23/08/2006, finish 29/08/2006, duration
    /// exactly 1 week (TimeUnit.WEEKS), work 40 hours, notes "Notes Example".
    /// The single assignment carries the task's 40 hours.
    func testREAL_mpxjTaskMPP9_12_14_startFinishDurationAssignment() throws {
        for name in ["mpxj/mpp9task.mpp", "mpxj/mpp12task.mpp", "mpxj/mpp14task.mpp"] {
            let result = try extract(name)
            XCTAssertTrue(result.text.contains("[Tasks]\n1\tTask #1\t2006-08-23T08:00:00\t2006-08-29T17:00:00\t1 wk\tNotes Example\n"), "\(name)\n\(result.text)")
            XCTAssertTrue(result.text.contains("[Assignments]\ntask 1 (Task #1) → resource 1 (Wade Golden)\t100%\t40 hrs\n"), "\(name)\n\(result.text)")
            XCTAssertEqual(result.components, ["Project data", "Tasks", "Resources", "Assignments"], name)
            XCTAssertTrue(result.skipped.isEmpty, "\(name): \(result.skipped)")
        }
    }

    /// MPXJ's assignment-fields project saved as MPP9, MPP12 and MPP14,
    /// cross-checked against its MSPDI twin (mspdiassignmentfields.xml, the
    /// same project saved by Project as XML) read by the package's own
    /// Project XML reader: Task One starts 2011-07-06T08:00:00 and finishes
    /// 2011-07-18T16:01:00 with Duration PT71H1M0S (8.88 days at the
    /// project's 480 minutes a day); assignments task 1 → resource 1 with
    /// Units 1 and Work PT80H0M0S, task 1 → resource 4 with Units 0.25 and
    /// Work PT23H0M0S. (Its assignments to the project summary task — the
    /// budget resources — are not listed: the summary task row is not.)
    func testREAL_mpxjAssignmentFields_matchTheMSPDITwin() throws {
        let twin = try DocumentTextExtractor.extract(fileURL: Self.fixture("mpxj/mspdiassignmentfields.xml"), kind: .projectXML)
        XCTAssertTrue(twin.text.contains("1\tTask One\t2011-07-06T08:00:00\t2011-07-18T16:01:00\n"), twin.text)
        XCTAssertTrue(twin.text.contains("task 1 → resource 1\ntask 0 → resource 2\ntask 0 → resource 3\ntask 1 → resource 4\n"), twin.text)
        let xml = try String(contentsOf: Self.fixture("mpxj/mspdiassignmentfields.xml"), encoding: .utf8)
        for fragment in ["<Duration>PT71H1M0S</Duration>", "<MinutesPerDay>480</MinutesPerDay>", "<Units>0.25</Units>", "<Work>PT80H0M0S</Work>", "<Work>PT23H0M0S</Work>"] {
            XCTAssertTrue(xml.contains(fragment), fragment)
        }
        for name in ["mpxj/mpp9assignmentfields.mpp", "mpxj/mpp12assignmentfields.mpp", "mpxj/mpp14assignmentfields.mpp"] {
            let result = try extract(name)
            XCTAssertTrue(result.text.contains("[Tasks]\n1\tTask One\t2011-07-06T08:00:00\t2011-07-18T16:01:00\t8.88 days\t\n"), "\(name)\n\(result.text)")
            XCTAssertTrue(result.text.contains("[Resources]\n1\tResource One\t\n2\tBudget Work Resource\t\n3\tBudget Cost Resource\t\n4\tResource Two\t\n"), "\(name)\n\(result.text)")
            XCTAssertTrue(result.text.contains("[Assignments]\ntask 1 (Task One) → resource 1 (Resource One)\t100%\t80 hrs\ntask 1 (Task One) → resource 4 (Resource Two)\t25%\t23 hrs\n"), "\(name)\n\(result.text)")
            XCTAssertTrue(result.skipped.isEmpty, "\(name): \(result.skipped)")
        }
    }

    /// The decoding rules on vectors: MPPUtility.getTimestamp (tenths of a
    /// minute + days since 1983-12-31; days ≤ 1 or 65535 = NA), the
    /// duration units and Project's labels.
    func testTimestampAndDurationRules() {
        // 2011-07-06 is day 10049 after 1983-12-31; 08:00 = 4800 tenths of a minute.
        XCTAssertEqual(ProjectBinaryTextExtractor.timestamp([0xC0, 0x12, 0x41, 0x27], 0).map(ProjectBinaryTextExtractor.formatTimestamp), "2011-07-06T08:00:00")
        XCTAssertNil(ProjectBinaryTextExtractor.timestamp([0x00, 0x00, 0x01, 0x00], 0))
        XCTAssertNil(ProjectBinaryTextExtractor.timestamp([0x00, 0x00, 0xFF, 0xFF], 0))
        XCTAssertNil(ProjectBinaryTextExtractor.timestamp([0x00, 0x00], 0), "short bytes are NA, not a trap")
        XCTAssertEqual(ProjectBinaryTextExtractor.formatTimestamp(2 * 86_400), "1984-01-02T00:00:00")
        let settings = ProjectBinaryTextExtractor.Settings(props: .init([]), applicationVersion: 0)
        func shown(_ tenths: Int, _ code: Int) -> String {
            let units = ProjectBinaryTextExtractor.Settings.durationUnits(code, projectDefault: settings.defaultDurationUnits)
            return ProjectBinaryTextExtractor.formatDuration(ProjectBinaryTextExtractor.durationValue(tenths: tenths, units: units, settings: settings), units: units)
        }
        XCTAssertEqual(shown(24_000, 9), "1 wk")
        XCTAssertEqual(shown(42_610, 7), "8.88 days")
        XCTAssertEqual(shown(4_800, 7), "1 day")
        XCTAssertEqual(shown(24_000, 5), "40 hrs")
        XCTAssertEqual(shown(43_200, 8), "3 edays")
        XCTAssertEqual(shown(300, 3), "30 mins")
        XCTAssertEqual(shown(4_800, 21), "1 day", "21 = the project default (days)")
        XCTAssertEqual(shown(4_800, 0x27), "1 day", "flag bits above the low five are ignored")

        // A Project 2010+ row whose second fixed block is missing: the scheduled values
        // are still given, and the row is reported incomplete instead of guessed.
        let map = ProjectBinaryTextExtractor.FieldMap(data: nil, version: 14, prefix: 0x0B40_0000, defaults: ProjectBinaryTextExtractor.TaskField.defaults(14), keepDefaults: [])
        var block = [UInt8](repeating: 0, count: 120)
        block[64...67] = [0xC0, 0x12, 0x41, 0x27][...]                      // scheduled start 2011-07-06T08:00
        block[42...45] = [0x60, 0x12, 0x00, 0x00][...]                      // 4704 tenths of a minute
        block[46] = 5                                                      // hours
        let row = ProjectBinaryTextExtractor.Row(id: 1, uid: 1, blocks: [block, []], meta2: [])
        let schedule = ProjectBinaryTextExtractor.taskSchedule(row, map: map, version: 14, settings: settings)
        XCTAssertEqual(schedule.start.map(ProjectBinaryTextExtractor.formatTimestamp), "2011-07-06T08:00:00")
        XCTAssertEqual(schedule.duration, "7.84 hrs")
        XCTAssertFalse(schedule.complete)
        // No fixed data at all (names listed from the variable data only): nothing invented.
        let bare = ProjectBinaryTextExtractor.taskSchedule(.init(id: 1, uid: 1, blocks: [], meta2: []), map: map, version: 9, settings: settings)
        XCTAssertNil(bare.start); XCTAssertNil(bare.duration); XCTAssertFalse(bare.complete)
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
        for name in ["tika/testPROJECT2003.mpp", "tika/testPROJECT2007.mpp", "mpxj/writepassword9.mpp", "mpxj/ResourceIdAndUniqueId-project2013-mpp14.mpp",
                     "mpxj/mpp9assignmentfields.mpp", "mpxj/mpp14assignmentfields.mpp"] {
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
