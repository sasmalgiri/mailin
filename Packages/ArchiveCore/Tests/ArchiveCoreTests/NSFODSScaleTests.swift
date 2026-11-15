//
//  NSFODSScaleTests.swift
//  ArchiveCoreTests
//
//  Owner 2026-11-15 ("with synthetic data have you test it?"): the new Notes
//  ODS reader at the five-jobs size rule (100 MB per format). A ~100 MB ODS 43
//  database is built with the depth tests' builder — thousands of mail notes
//  in summary buckets spread over several descriptor pages and a dozen RRV
//  buckets, two folders (one of them partial), Huffman-coded attachments —
//  and streamed through the import path the app uses (ParserFactory, switch
//  on). Every message must arrive once, with its folders and attachments, and
//  memory must follow the batch, not the file.
//

import XCTest
import Foundation
@testable import ArchiveCore

final class NSFODSScaleTests: XCTestCase {
    typealias D = NSFODSDepthTests

    static let mailCount = 3_300
    static let mailStart: UInt32 = 0x200
    /// ~30 KB of rich text per memo: 3,300 × 30 KB ≈ 100 MB.
    static let body = String(repeating: "Quarterly figures, the plan for the next phase and the minutes. ", count: 470)
    static let attachmentText = Data("Attached figures: revenue, costs, margin — Huffman-coded in Notes.".utf8)

    static func mailID(_ i: Int) -> UInt32 { mailStart + UInt32(4 * i) }

    /// The database, written to `url`; the builder's bytes are released before returning.
    static func writeDatabase(to url: URL) throws -> (bytes: Int, withAttachment: Int, inProjects: Int) {
        var b = D.Builder()
        let n = mailCount
        let objectStart = mailID(n) + 0x100
        // Folder ID tables: Inbox holds every mail (runs of up to 256), Projects the first 1,000.
        func runs(_ range: Range<Int>) -> [(UInt8, UInt32)] {
            stride(from: range.lowerBound, to: range.upperBound, by: 256).map { start in
                (UInt8(min(256, range.upperBound - start) - 1), mailID(start))
            }
        }
        let inProjects = 1_000
        b.objects = [(objectStart, D.idTable(runs(0..<n)), 0), (objectStart + 4, D.idTable(runs(0..<inProjects)), 0)]
        let huffman = D.huffman(attachmentText)
        var attachmentIDs: [Int: UInt32] = [:]
        for i in stride(from: 0, to: n, by: 10) {
            let id = objectStart + 8 + UInt32(4 * attachmentIDs.count)
            attachmentIDs[i] = id
            b.objects.append((id, huffman, 0))
        }
        func folder(_ id: UInt32, _ title: String, _ table: UInt32, bucket: Int) -> D.Builder.NoteSpec {
            .init(id: id, noteClass: 0x0008, items: [D.text("$TITLE", title), D.text("$Flags", "3FY"),
                                                      D.objectRef("$FolderIDTable", type: 0x000A, rrv: table)], bucket: bucket)
        }
        b.notes = [folder(0x110, "($Inbox)", objectStart, bucket: 1), folder(0x114, "Projects", objectStart + 4, bucket: 2)]
        for i in 0..<n {
            var items: [D.Builder.ItemSpec] = [
                D.text("Form", "Memo"), D.text("From", "Sender \(i % 40) <sender\(i % 40)@example.org>"),
                D.text("SendTo", "team@example.org"), D.text("Subject", "Memo \(i)"),
                D.richText("Memo \(i). " + body),
            ]
            if let att = attachmentIDs[i] {
                items.append(D.fileItem("figures-\(i).txt", rrv: att, compression: 1, size: attachmentText.count))
            }
            b.notes.append(.init(id: mailID(i), noteClass: 0x0001, items: items, bucket: 3 + i))
        }
        b.summaryBuckets = n + 2
        b.summaryPages = (b.summaryBuckets + 569) / 570
        let bytes: Int = try autoreleasepool {
            let data = b.build()
            try data.write(to: url)
            return data.count
        }
        return (bytes, attachmentIDs.count, inProjects)
    }

    func testHundredMegabyteNotesDatabase_newReader_everyMessageOnce_foldersAttachments_memoryFollowsTheBatch() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nsf-scale-\(UUID().uuidString).nsf")
        defer { try? FileManager.default.removeItem(at: url) }
        let built = try Self.writeDatabase(to: url)
        XCTAssertGreaterThan(built.bytes, 95_000_000, "the five-jobs size rule: about 100 MB")

        NotesODSPolicy.isEnabled = true
        defer { NotesODSPolicy.isEnabled = false }
        XCTAssertEqual(ParserFactory.parserIdentity(forExtension: "nsf").name, "nsf-ods")

        let baseline = CarverScaleTests.footprint()
        var peak = baseline
        var seen = Set<String>()
        var duplicates = 0
        var inbox = 0, projects = 0, withAttachment = 0, decodedAttachments = 0, bodiesComplete = 0
        var batches = 0
        let started = Date()
        let report = try await ParserFactory.parseStreamingCallback(fileURL: url, senderEmail: "", batchSize: 100,
                                                                    materializeAttachments: false) { batch in
            batches += 1
            XCTAssertLessThanOrEqual(batch.count, 100)
            for email in batch {
                let subject = email.headers["Subject"] ?? ""
                if !seen.insert(subject).inserted { duplicates += 1 }
                if email.folderPath == "Inbox" { inbox += 1 }
                if email.tags.contains("Projects") { projects += 1 }
                if !email.attachments.isEmpty {
                    withAttachment += 1
                    let bytes = email.attachments.first?.base64.flatMap { Data(base64Encoded: $0) }
                        ?? email.attachments.first?.fileURL.flatMap { try? Data(contentsOf: $0) }
                    if bytes == Self.attachmentText { decodedAttachments += 1 }
                }
                let text = email.plainBody.isEmpty ? email.htmlBody : email.plainBody
                if text.contains("Memo \(subject.dropFirst(5)).") && text.count > 29_000 { bodiesComplete += 1 }
                else if bodiesComplete < 100000, ProcessInfo.processInfo.environment["NSFDBG"] != nil || true {
                    if !text.contains("Memo \(subject.dropFirst(5)).") || text.count <= 29_000, Int.random(in: 0..<30) == 0 {
                        print("DBGH", subject, email.headers.filter { $0.key.lowercased().contains("content") || $0.key.hasPrefix("X-") }); print("DBG", subject, "plain", email.plainBody.count, "html", email.htmlBody.count, "att", email.attachments.count, String(text.prefix(60)).replacingOccurrences(of: "\n", with: "|"), "...", String(text.suffix(40)).replacingOccurrences(of: "\n", with: "|"))
                    }
                }
            }
            peak = max(peak, CarverScaleTests.footprint())
        }
        let seconds = Date().timeIntervalSince(started)
        let growth = peak > baseline ? peak - baseline : 0
        print("NSF-SCALE: \(built.bytes) bytes, \(report.successfullyParsed) messages in \(batches) batches, "
              + String(format: "%.1f s", seconds) + ", peak footprint growth \(growth / 1_048_576) MB")

        XCTAssertEqual(report.totalMessages, Self.mailCount)
        XCTAssertEqual(report.successfullyParsed, Self.mailCount, "every mail note arrives")
        XCTAssertEqual(report.failed, 0)
        XCTAssertEqual(seen.count, Self.mailCount)
        XCTAssertEqual(duplicates, 0, "each message once")
        XCTAssertEqual(inbox, Self.mailCount, "every memo is in the Inbox folder")
        XCTAssertEqual(projects, built.inProjects, "the partial folder holds exactly its 1,000")
        XCTAssertEqual(withAttachment, built.withAttachment)
        XCTAssertEqual(decodedAttachments, built.withAttachment, "every Huffman attachment decodes to its bytes")
        XCTAssertEqual(bodiesComplete, Self.mailCount, "whole ~30 KB bodies, never cut")
        XCTAssertEqual(report.declaredFolders, ["Inbox", "Projects"])
        XCTAssertLessThan(growth, UInt64(built.bytes / 2), "memory follows the batch, not the 100 MB file")
    }
}
