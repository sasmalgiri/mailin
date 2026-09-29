//
//  ExportResumeTests.swift
//  ArchiveCoreTests
//
//  Audit F08 (2026-09-28). A resumable export reports progress once per
//  batch and a resume skips exactly that many positions, so a kept partial
//  artifact must end at the last reported batch boundary — never ten rows
//  and half a record past it. And a positional resume is only valid while
//  the selection has the same members in the same order.
//

import XCTest
import Foundation
@testable import ArchiveCore

final class ExportResumeTests: XCTestCase {

    private struct Env {
        let root: URL
        let store: SQLiteEmailStore
        let archive: ArchiveDataService
        let service: ArchiveExportService
    }

    private func email(_ i: Int) -> MBOXParser.RawEmail {
        let day = String(format: "%02d", 1 + (i % 28))
        let month = String(format: "%02d", 1 + (i / 28) % 12)
        return MBOXParser.RawEmail(
            headers: ["Message-ID": "<resume-\(i)@test>", "Subject": "Subject \(i)", "From": "a@b.com", "To": "c@d.com",
                      "Date": "Wed, \(day) \(["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"][Int(month)! - 1]) 2025 14:30:\(String(format: "%02d", i % 60)) +0000"],
            rawSource: "Message-ID: <resume-\(i)@test>\nSubject: Subject \(i)\n\nbody \(i)\n",
            messageType: "email", attachments: [], timestamp: "", domains: ["b.com"],
            plainBody: "body \(i)", htmlBody: "")
    }

    private func makeEnv(count: Int) async throws -> Env {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("resume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts", isDirectory: true))
        try await store.insertBatch((0..<count).map(email), batchSize: 100)
        let archive = ArchiveDataService(repository: EmailStoreRepository(store: store, fts: fts))
        let service = await ArchiveExportService(archive: archive)
        return Env(root: root, store: store, archive: archive, service: service)
    }

    struct Injected: Error {}

    static func size(of url: URL) -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
    }
    static func sha(of url: URL) throws -> String {
        try ArchiveExportService.sha256(ofFile: url).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Single text artifact

    /// Fails after 200 reported + 10 written rows. The kept file must hold
    /// exactly 200 rows; the resume must append the remaining 300 once.
    func testTextDocument_keptPartialEndsAtTheReportedBatch_andResumeCompletesExactly() async throws {
        let env = try await makeEnv(count: 500); defer { try? FileManager.default.removeItem(at: env.root) }
        let url = env.root.appendingPathComponent("rows.txt")
        var lastProgress = (done: -1, total: -1)
        var kept = ExportWriteOptions(); kept.keepPartialOnCancel = true

        do {
            _ = try await env.service.exportTextDocument(
                scope: .query(.all, exclusions: []), to: url, batchSize: 200, write: kept,
                onProgress: { d, t in lastProgress = (d, t) }) { email, position in
                    if position == 210 { throw Injected() }
                    return "\(position)|\(email.headers["Message-ID"] ?? "")\n"
                }
            XCTFail("the injected error must propagate")
        } catch is Injected {}

        XCTAssertEqual(lastProgress.done, 200, "progress was last reported at the batch boundary")
        let partial = try String(contentsOf: url, encoding: .utf8)
        let partialRows = partial.split(separator: "\n")
        XCTAssertEqual(partialRows.count, 200, "the kept file ends at the boundary the receipt will report")
        XCTAssertEqual(partialRows.last?.hasPrefix("199|"), true)

        // Resume: skip the 200 the receipt counts, append — with the boundary
        // the receipt would carry (length + hash of the partial, T2).
        var resume = ExportWriteOptions(); resume.skipFirst = lastProgress.done; resume.append = true; resume.keepPartialOnCancel = true
        resume.expectedAppendOffset = Self.size(of: url)
        resume.expectedAppendSHA256 = try Self.sha(of: url)
        let result = try await env.service.exportTextDocument(
            scope: .query(.all, exclusions: []), to: url, batchSize: 200, write: resume) { email, position in
                "\(position)|\(email.headers["Message-ID"] ?? "")\n"
            }
        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.recordsWritten, 500)

        // Byte-identical to a single uninterrupted pass.
        let fresh = env.root.appendingPathComponent("fresh.txt")
        _ = try await env.service.exportTextDocument(scope: .query(.all, exclusions: []), to: fresh, batchSize: 200) { email, position in
            "\(position)|\(email.headers["Message-ID"] ?? "")\n"
        }
        XCTAssertEqual(try Data(contentsOf: url), try Data(contentsOf: fresh))
        let rows = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(rows.count, 500)
        XCTAssertEqual(Set(rows).count, 500, "no record appears twice")
    }

    /// The header survives a failure inside the very first batch.
    func testTextDocument_failureInFirstBatchKeepsOnlyTheHeader() async throws {
        let env = try await makeEnv(count: 50); defer { try? FileManager.default.removeItem(at: env.root) }
        let url = env.root.appendingPathComponent("first.txt")
        var kept = ExportWriteOptions(); kept.keepPartialOnCancel = true
        do {
            _ = try await env.service.exportTextDocument(scope: .query(.all, exclusions: []), to: url, batchSize: 20, write: kept,
                                                         header: { _ in "HEADER\n" }) { _, position in
                if position == 5 { throw Injected() }
                return "row\n"
            }
            XCTFail()
        } catch is Injected {}
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "HEADER\n")
    }

    // MARK: One file per message

    func testMessageFiles_keptPartialHoldsOnlyReportedRecords_andResumeAddsTheRest() async throws {
        let env = try await makeEnv(count: 500); defer { try? FileManager.default.removeItem(at: env.root) }
        let folder = env.root.appendingPathComponent("files", isDirectory: true)
        var lastDone = -1
        var kept = ExportWriteOptions(); kept.keepPartialOnCancel = true
        do {
            _ = try await env.service.exportMessageFiles(scope: .query(.all, exclusions: []), to: folder, batchSize: 200, write: kept,
                                                         onProgress: { d, _ in lastDone = d }) { email, index in
                if index == 210 { throw Injected() }
                return ("\(index).txt", Data("\(email.headers["Message-ID"] ?? "")\n".utf8))
            }
            XCTFail()
        } catch is Injected {}
        XCTAssertEqual(lastDone, 200)
        let after = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".txt") }
        XCTAssertEqual(after.count, 200, "files past the reported boundary are removed: \(after.count)")

        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(ExportFolderManifest.filename).path),
                      "a kept partial folder carries its manifest")
        var resume = ExportWriteOptions(); resume.skipFirst = lastDone; resume.append = true; resume.keepPartialOnCancel = true
        let result = try await env.service.exportMessageFiles(scope: .query(.all, exclusions: []), to: folder, batchSize: 200, write: resume) { email, index in
            ("\(index).txt", Data("\(email.headers["Message-ID"] ?? "")\n".utf8))
        }
        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.recordsWritten, 500)
        XCTAssertEqual(result.positionsConsumed, 500)
        let all = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".txt") }
        XCTAssertEqual(all.count, 500)
        XCTAssertEqual(Set(all).count, 500)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(ExportFolderManifest.filename).path),
                       "a finished run leaves no manifest behind")
    }

    // MARK: Third review T3 — skipped or withheld inputs do not shift the resume position

    func testMessageFiles_skippedInputs_resumeByInputPositionNotByProducedCount() async throws {
        let env = try await makeEnv(count: 300); defer { try? FileManager.default.removeItem(at: env.root) }
        let folder = env.root.appendingPathComponent("skips", isDirectory: true)
        var lastDone = -1, lastProduced = -1
        var kept = ExportWriteOptions(); kept.keepPartialOnCancel = true
        // Every third message is skipped by the renderer (as a withheld or
        // unrenderable message would be); the run fails after the first batch.
        func render(_ email: MBOXParser.RawEmail, _ index: Int) throws -> (filename: String, data: Data)? {
            let mid = email.headers["Message-ID"] ?? ""
            let n = Int(mid.split(separator: "-")[1].split(separator: "@")[0]) ?? 0
            if n % 3 == 0 { return nil }
            return ("\(mid.replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: "")).txt", Data(mid.utf8))
        }
        do {
            _ = try await env.service.exportMessageFiles(scope: .query(.all, exclusions: []), to: folder, batchSize: 100, write: kept,
                                                         onProgress: { d, _ in lastDone = d }, onProduced: { lastProduced = $0 }) { email, index in
                if index == 80 { throw Injected() }   // 80th PRODUCED file, inside batch 2
                return try render(email, index)
            }
            XCTFail()
        } catch is Injected {}
        XCTAssertEqual(lastDone, 100, "progress is the INPUT position at the boundary")
        XCTAssertEqual(lastProduced, 67, "100 inputs minus the 33 skipped: produced is reported separately")
        let after = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".txt") }
        XCTAssertEqual(after.count, 67)

        // Resume from the INPUT position. Skipping by produced count (67)
        // would re-export 33 messages; skipping by position exports exactly
        // the remaining 200 inputs.
        var resume = ExportWriteOptions(); resume.skipFirst = lastDone; resume.append = true; resume.keepPartialOnCancel = true
        let result = try await env.service.exportMessageFiles(scope: .query(.all, exclusions: []), to: folder, batchSize: 100, write: resume) { email, index in
            try render(email, index)
        }
        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.positionsConsumed, 300)
        let all = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".txt") }
        XCTAssertEqual(all.count, 200, "300 inputs minus 100 skipped, each exactly once")
        XCTAssertEqual(Set(all).count, 200)
    }

    // MARK: Third review T2 — folder resume validates the manifest

    func testMessageFiles_resumeRefusesMissingOrChangedFilesAndAMissingFolder() async throws {
        let env = try await makeEnv(count: 120); defer { try? FileManager.default.removeItem(at: env.root) }
        let folder = env.root.appendingPathComponent("manifest", isDirectory: true)
        var kept = ExportWriteOptions(); kept.keepPartialOnCancel = true
        do {
            _ = try await env.service.exportMessageFiles(scope: .query(.all, exclusions: []), to: folder, batchSize: 40, write: kept) { email, index in
                if index == 50 { throw Injected() }
                return ("\(index).txt", Data((email.headers["Message-ID"] ?? "").utf8))
            }
            XCTFail()
        } catch is Injected {}
        var resume = ExportWriteOptions(); resume.skipFirst = 40; resume.append = true; resume.keepPartialOnCancel = true
        let render: @MainActor (MBOXParser.RawEmail, Int) throws -> (filename: String, data: Data)? = { email, index in
            ("\(index).txt", Data((email.headers["Message-ID"] ?? "").utf8))
        }

        // One produced file edited at the same length → refused.
        let victim = folder.appendingPathComponent("7.txt")
        var bytes = try Data(contentsOf: victim)
        bytes[0] = bytes[0] == UInt8(ascii: "<") ? UInt8(ascii: "[") : UInt8(ascii: "<")
        try bytes.write(to: victim)
        do {
            _ = try await env.service.exportMessageFiles(scope: .query(.all, exclusions: []), to: folder, batchSize: 40, write: resume, content: render)
            XCTFail("a changed file must refuse the resume")
        } catch let error as ArchiveExportError {
            guard case .partialManifestInvalid(let why) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(why.contains("7.txt"), why)
        }

        // One produced file missing → refused.
        try FileManager.default.removeItem(at: victim)
        do {
            _ = try await env.service.exportMessageFiles(scope: .query(.all, exclusions: []), to: folder, batchSize: 40, write: resume, content: render)
            XCTFail("a missing file must refuse the resume")
        } catch let error as ArchiveExportError {
            guard case .partialManifestInvalid(let why) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(why.contains("missing"), why)
        }

        // Wrong position → refused.
        try FileManager.default.removeItem(at: folder)
        do {
            _ = try await env.service.exportMessageFiles(scope: .query(.all, exclusions: []), to: folder, batchSize: 40, write: resume, content: render)
            XCTFail("a deleted folder must refuse the resume, never be recreated from position 40")
        } catch let error as ArchiveExportError {
            guard case .partialManifestInvalid = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "nothing is created by a refused resume")
    }

    // MARK: Recheck R2 — the partial artifact must be exactly what the receipt recorded

    func testResume_refusesAChangedOrMissingPartialArtifact() async throws {
        let env = try await makeEnv(count: 60); defer { try? FileManager.default.removeItem(at: env.root) }
        let url = env.root.appendingPathComponent("rows.txt")
        var kept = ExportWriteOptions(); kept.keepPartialOnCancel = true
        do {
            _ = try await env.service.exportTextDocument(scope: .query(.all, exclusions: []), to: url, batchSize: 20, write: kept) { _, position in
                if position == 45 { throw Injected() }
                return "row \(position)\n"
            }
            XCTFail()
        } catch is Injected {}
        let recorded = UInt64((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0)
        XCTAssertGreaterThan(recorded, 0)

        let recordedHash = try Self.sha(of: url)
        var resume = ExportWriteOptions(); resume.skipFirst = 40; resume.append = true; resume.keepPartialOnCancel = true
        resume.expectedAppendOffset = recorded
        resume.expectedAppendSHA256 = recordedHash

        // T2: a same-length edit is caught by the hash.
        var same = try Data(contentsOf: url)
        same[3] = same[3] == UInt8(ascii: "1") ? UInt8(ascii: "2") : UInt8(ascii: "1")
        try same.write(to: url, options: .atomic)
        do {
            _ = try await env.service.exportTextDocument(scope: .query(.all, exclusions: []), to: url, batchSize: 20, write: resume) { _, p in "row \(p)\n" }
            XCTFail("a same-length edit must be refused")
        } catch let error as ArchiveExportError {
            guard case .partialArtifactContentChanged = error else { return XCTFail("\(error)") }
        }
        // T2: a resume without the recorded boundary is refused outright.
        var unbounded = resume; unbounded.expectedAppendSHA256 = nil
        do {
            _ = try await env.service.exportTextDocument(scope: .query(.all, exclusions: []), to: url, batchSize: 20, write: unbounded) { _, p in "row \(p)\n" }
            XCTFail()
        } catch let error as ArchiveExportError {
            guard case .resumeBoundaryMissing = error else { return XCTFail("\(error)") }
        }

        // Someone edits the partial file: appending would corrupt it.
        try Data("tampered\n".utf8).write(to: url, options: .atomic)
        do {
            _ = try await env.service.exportTextDocument(scope: .query(.all, exclusions: []), to: url, batchSize: 20, write: resume) { _, p in "row \(p)\n" }
            XCTFail("a changed partial must be refused")
        } catch let error as ArchiveExportError {
            guard case .partialArtifactChanged(_, let expected, let actual) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(expected, recorded)
            XCTAssertEqual(actual, 9)
        }

        // The partial is gone: nothing to append to — refused, never recreated
        // as a file that starts at position 40.
        try FileManager.default.removeItem(at: url)
        do {
            _ = try await env.service.exportTextDocument(scope: .query(.all, exclusions: []), to: url, batchSize: 20, write: resume) { _, p in "row \(p)\n" }
            XCTFail("a missing partial must be refused")
        } catch let error as ArchiveExportError {
            guard case .partialArtifactMissing = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "no file is created by a refused resume")
    }

    // MARK: Fourth review Q2 — a resume never moves its checkpoint backward

    /// 600 rows, stopped at 400. The resume uses a SMALLER batch, so its
    /// first four batches only replay the prefix; it then fails inside the
    /// first new batch. The checkpoint must stay at 400 throughout (never
    /// 100/200/300), the file must still hold exactly 400 rows, and a second
    /// resume must produce the same bytes as one uninterrupted pass.
    func testTextDocument_resumeInterruptedDuringPrefixReplay_keepsTheCheckpoint() async throws {
        let env = try await makeEnv(count: 600); defer { try? FileManager.default.removeItem(at: env.root) }
        let url = env.root.appendingPathComponent("rows.txt")
        let row: @MainActor (MBOXParser.RawEmail, Int) throws -> String = { email, position in
            "\(position)|\(email.headers["Message-ID"] ?? "")\n"
        }
        var kept = ExportWriteOptions(); kept.keepPartialOnCancel = true
        var lastDone = -1
        do {
            _ = try await env.service.exportTextDocument(scope: .query(.all, exclusions: []), to: url, batchSize: 200, write: kept,
                                                         onProgress: { d, _ in lastDone = d }) { email, position in
                if position == 410 { throw Injected() }
                return try row(email, position)
            }
            XCTFail()
        } catch is Injected {}
        XCTAssertEqual(lastDone, 400)
        let sizeAt400 = Self.size(of: url), shaAt400 = try Self.sha(of: url)

        // Resume 1: batch 100, fails at position 450 (inside the first NEW batch).
        var resume = ExportWriteOptions(); resume.skipFirst = 400; resume.append = true; resume.keepPartialOnCancel = true
        resume.expectedAppendOffset = sizeAt400; resume.expectedAppendSHA256 = shaAt400
        var reports: [Int] = []
        do {
            _ = try await env.service.exportTextDocument(scope: .query(.all, exclusions: []), to: url, batchSize: 100, write: resume,
                                                         onProgress: { d, _ in reports.append(d) }) { email, position in
                if position == 450 { throw Injected() }
                return try row(email, position)
            }
            XCTFail()
        } catch is Injected {}
        XCTAssertEqual(reports, [400], "the checkpoint is seeded from the resume and never reported below it: \(reports)")
        XCTAssertEqual(Self.size(of: url), sizeAt400, "the file is cut back to the same 400-row boundary")
        XCTAssertEqual(try Self.sha(of: url), shaAt400)

        // Resume 2 from the SAME boundary completes the export exactly once.
        let result = try await env.service.exportTextDocument(scope: .query(.all, exclusions: []), to: url, batchSize: 100, write: resume, row: row)
        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.positionsConsumed, 600)
        let fresh = env.root.appendingPathComponent("fresh.txt")
        _ = try await env.service.exportTextDocument(scope: .query(.all, exclusions: []), to: fresh, batchSize: 200, row: row)
        XCTAssertEqual(try Data(contentsOf: url), try Data(contentsOf: fresh), "byte-identical to a single pass")
        let rows = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(rows.count, 600)
        XCTAssertEqual(Set(rows).count, 600, "no row appears twice")
    }

    func testMessageFiles_resumeInterruptedDuringPrefixReplay_keepsTheManifestBoundary() async throws {
        let env = try await makeEnv(count: 600); defer { try? FileManager.default.removeItem(at: env.root) }
        let folder = env.root.appendingPathComponent("replay", isDirectory: true)
        let render: @MainActor (MBOXParser.RawEmail, Int) throws -> (filename: String, data: Data)? = { email, index in
            ("\(index).txt", Data((email.headers["Message-ID"] ?? "").utf8))
        }
        var kept = ExportWriteOptions(); kept.keepPartialOnCancel = true
        do {
            _ = try await env.service.exportMessageFiles(scope: .query(.all, exclusions: []), to: folder, batchSize: 200, write: kept) { email, index in
                if index == 410 { throw Injected() }
                return try render(email, index)
            }
            XCTFail()
        } catch is Injected {}
        func txtFiles() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".txt") }
        }
        XCTAssertEqual(try txtFiles().count, 400)

        var resume = ExportWriteOptions(); resume.skipFirst = 400; resume.append = true; resume.keepPartialOnCancel = true
        var reports: [Int] = [], produced: [Int] = []
        do {
            _ = try await env.service.exportMessageFiles(scope: .query(.all, exclusions: []), to: folder, batchSize: 100, write: resume,
                                                         onProgress: { d, _ in reports.append(d) }, onProduced: { produced.append($0) }) { email, index in
                if index == 450 { throw Injected() }
                return try render(email, index)
            }
            XCTFail()
        } catch is Injected {}
        XCTAssertEqual(reports, [400], "no replay-only boundary is reported: \(reports)")
        XCTAssertEqual(produced, [400])
        XCTAssertEqual(try txtFiles().count, 400, "files past the unchanged boundary are removed")
        let state = try ExportFolderManifest.verify(folder: folder, expectedPositions: 400)
        XCTAssertEqual(state.positions, 400)
        XCTAssertEqual(state.files.count, 400, "the manifest still ends at the 400 boundary")
        // The manifest's last boundary is 400 — a resume from anything lower is refused.
        XCTAssertThrowsError(try ExportFolderManifest.verify(folder: folder, expectedPositions: 200))

        let result = try await env.service.exportMessageFiles(scope: .query(.all, exclusions: []), to: folder, batchSize: 100, write: resume, content: render)
        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.positionsConsumed, 600)
        let all = try txtFiles()
        XCTAssertEqual(all.count, 600)
        XCTAssertEqual(Set(all).count, 600)
    }

    // MARK: Fourth review Q5 — "skip existing files" still resumes

    func testMessageFiles_skipExistingFiles_acceptedFileIsInTheManifest_andTheRunResumes() async throws {
        let env = try await makeEnv(count: 120); defer { try? FileManager.default.removeItem(at: env.root) }
        let folder = env.root.appendingPathComponent("skip-existing", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let existing = folder.appendingPathComponent("7.txt")
        try Data("already here\n".utf8).write(to: existing)
        let render: @MainActor (MBOXParser.RawEmail, Int) throws -> (filename: String, data: Data)? = { email, index in
            ("\(index).txt", Data((email.headers["Message-ID"] ?? "").utf8))
        }
        var kept = ExportWriteOptions(); kept.keepPartialOnCancel = true; kept.collision = .skipExisting
        var lastProduced = -1
        do {
            _ = try await env.service.exportMessageFiles(scope: .query(.all, exclusions: []), to: folder, batchSize: 40, write: kept,
                                                         onProduced: { lastProduced = $0 }) { email, index in
                if index == 50 { throw Injected() }
                return try render(email, index)
            }
            XCTFail()
        } catch is Injected {}
        XCTAssertEqual(lastProduced, 40, "the accepted file counts as produced")
        let state = try ExportFolderManifest.verify(folder: folder, expectedPositions: 40)
        XCTAssertEqual(state.files.count, 40, "produced == listed files, including the accepted one")
        let accepted = try XCTUnwrap(state.files.first { $0.name == "7.txt" })
        XCTAssertEqual(accepted.existing, true)
        XCTAssertEqual(accepted.bytes, "already here\n".utf8.count)

        var resume = kept; resume.skipFirst = 40; resume.append = true
        let result = try await env.service.exportMessageFiles(scope: .query(.all, exclusions: []), to: folder, batchSize: 40, write: resume, content: render)
        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.recordsWritten, 120)
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "already here\n", "the accepted file is never rewritten or removed")
        let all = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".txt") }
        XCTAssertEqual(all.count, 120)

        // The accepted file is part of the verified output: editing it refuses a resume.
        let folder2 = env.root.appendingPathComponent("skip-existing-2", isDirectory: true)
        try FileManager.default.createDirectory(at: folder2, withIntermediateDirectories: true)
        try Data("already here\n".utf8).write(to: folder2.appendingPathComponent("7.txt"))
        do {
            _ = try await env.service.exportMessageFiles(scope: .query(.all, exclusions: []), to: folder2, batchSize: 40, write: kept) { email, index in
                if index == 50 { throw Injected() }
                return try render(email, index)
            }
            XCTFail()
        } catch is Injected {}
        try Data("edited later\n".utf8).write(to: folder2.appendingPathComponent("7.txt"))
        XCTAssertThrowsError(try ExportFolderManifest.verify(folder: folder2, expectedPositions: 40)) { error in
            guard case ArchiveExportError.partialManifestInvalid(let why)? = error as? ArchiveExportError else { return XCTFail("\(error)") }
            XCTAssertTrue(why.contains("7.txt"), why)
        }
    }

    // MARK: Fourth review Q4 — the manifest is untrusted input

    private func writeManifest(_ lines: [Data], to folder: URL) throws {
        var data = Data()
        for line in lines { data.append(line); data.append(0x0A) }
        try data.write(to: folder.appendingPathComponent(ExportFolderManifest.filename))
    }
    private func fileLine(_ name: String, _ content: Data) throws -> Data {
        try JSONEncoder().encode(ExportFolderManifest.FileEntry(name: name, bytes: content.count, sha256: ExportFolderManifest.hex(content)))
    }
    private func boundaryLine(_ positions: Int, produced: Int) throws -> Data {
        try JSONEncoder().encode(ExportFolderManifest.Boundary(boundary: positions, produced: produced, withheld: 0, skipped: 0))
    }

    func testManifest_refusesTraversalAbsoluteAndSymlinkNames_andTouchesNothingOutsideTheFolder() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("manifest-escape-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("export", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("sentinel.txt")
        try Data("do not delete".utf8).write(to: sentinel)
        let good = Data("good".utf8)
        try good.write(to: folder.appendingPathComponent("0.txt"))

        func expectRefusal(_ lines: [Data], _ label: String, expected: Int = 1, file: StaticString = #filePath, line: UInt = #line) throws {
            try writeManifest(lines, to: folder)
            XCTAssertThrowsError(try ExportFolderManifest.verify(folder: folder, expectedPositions: expected), label, file: file, line: line) { error in
                guard case ArchiveExportError.partialManifestInvalid? = error as? ArchiveExportError else {
                    return XCTFail("\(label): \(error)", file: file, line: line)
                }
            }
            XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "do not delete", "\(label): the sentinel outside the folder is untouched", file: file, line: line)
        }

        // A stray (past-boundary) entry that climbs out of the folder.
        try expectRefusal([try fileLine("0.txt", good), try boundaryLine(1, produced: 1),
                           try fileLine("../outside/sentinel.txt", Data("do not delete".utf8))], "traversal stray")
        // A counted entry that climbs out.
        try expectRefusal([try fileLine("../outside/sentinel.txt", Data("do not delete".utf8)), try boundaryLine(1, produced: 1)], "traversal counted")
        // Absolute path.
        try expectRefusal([try fileLine("0.txt", good), try boundaryLine(1, produced: 1), try fileLine(sentinel.path, Data("do not delete".utf8))], "absolute")
        // Through a symlinked subfolder inside the export folder.
        let link = folder.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        try expectRefusal([try fileLine("0.txt", good), try boundaryLine(1, produced: 1), try fileLine("link/sentinel.txt", Data("do not delete".utf8))], "symlinked parent")
        try FileManager.default.removeItem(at: link)
        // The entry itself is a symlink pointing outside.
        let fileLink = folder.appendingPathComponent("1.txt")
        try FileManager.default.createSymbolicLink(at: fileLink, withDestinationURL: sentinel)
        try expectRefusal([try fileLine("0.txt", good), try boundaryLine(1, produced: 1), try fileLine("1.txt", Data("do not delete".utf8))], "symlink entry")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileLink.path), "the symlink itself is not removed either")
        try FileManager.default.removeItem(at: fileLink)
        // A duplicate name (matching position and count, so only the
        // duplicate guard can refuse — fifth review test note).
        try expectRefusal([try fileLine("0.txt", good), try fileLine("0.txt", good), try boundaryLine(2, produced: 2)], "duplicate", expected: 2)
        // The control file listed as output.
        try expectRefusal([try fileLine("0.txt", good), try boundaryLine(1, produced: 1), try fileLine(ExportFolderManifest.filename, good)], "control file as entry")

        // And the honest case still verifies, removing only the stray regular file it created.
        let stray = folder.appendingPathComponent("1.txt")
        try Data("stray".utf8).write(to: stray)
        try writeManifest([try fileLine("0.txt", good), try boundaryLine(1, produced: 1), try fileLine("1.txt", Data("stray".utf8))], to: folder)
        let state = try ExportFolderManifest.verify(folder: folder, expectedPositions: 1)
        XCTAssertEqual(state.files.map(\.name), ["0.txt"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path))
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "do not delete")
    }

    // MARK: Fourth review Q6 — stale entries past the boundary are cut, not inherited

    func testManifest_trailingEntriesPastTheBoundary_areCutBack_soTheNextResumeStaysValid() async throws {
        let env = try await makeEnv(count: 120); defer { try? FileManager.default.removeItem(at: env.root) }
        let folder = env.root.appendingPathComponent("trailing", isDirectory: true)
        let render: @MainActor (MBOXParser.RawEmail, Int) throws -> (filename: String, data: Data)? = { email, index in
            ("\(index).txt", Data((email.headers["Message-ID"] ?? "").utf8))
        }
        var kept = ExportWriteOptions(); kept.keepPartialOnCancel = true
        do {
            _ = try await env.service.exportMessageFiles(scope: .query(.all, exclusions: []), to: folder, batchSize: 40, write: kept) { email, index in
                if index == 50 { throw Injected() }
                return try render(email, index)
            }
            XCTFail()
        } catch is Injected {}

        // Simulate a stop that could not cut the manifest back: a complete
        // stray entry (its file present) and a torn final line.
        let manifestURL = folder.appendingPathComponent(ExportFolderManifest.filename)
        let stray = folder.appendingPathComponent("stray.txt")
        try Data("stray".utf8).write(to: stray)
        var tail = try fileLine("stray.txt", Data("stray".utf8)); tail.append(0x0A)
        tail.append(Data("{\"name\":\"to".utf8))
        let h = try FileHandle(forWritingTo: manifestURL); try h.seekToEnd(); try h.write(contentsOf: tail); try h.close()

        // Resume 1 verifies (cutting the manifest back to the 40 boundary and
        // removing the stray file), writes one more batch, then fails.
        var resume = kept; resume.skipFirst = 40; resume.append = true
        do {
            _ = try await env.service.exportMessageFiles(scope: .query(.all, exclusions: []), to: folder, batchSize: 40, write: resume) { email, index in
                if index == 90 { throw Injected() }
                return try render(email, index)
            }
            XCTFail()
        } catch is Injected {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path), "the uncommitted stray file is removed")

        // Resume 2: the manifest's 80 boundary must verify — the old stray
        // entry was cut, not carried across into the committed range.
        let state = try ExportFolderManifest.verify(folder: folder, expectedPositions: 80)
        XCTAssertEqual(state.files.count, 80)
        XCTAssertFalse(state.files.contains { $0.name == "stray.txt" })
        var resume2 = kept; resume2.skipFirst = 80; resume2.append = true
        let result = try await env.service.exportMessageFiles(scope: .query(.all, exclusions: []), to: folder, batchSize: 40, write: resume2, content: render)
        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.recordsWritten, 120)
        let all = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".txt") }
        XCTAssertEqual(all.count, 120)

        // A torn line BEFORE any boundary, or an unreadable line inside the
        // committed range, still refuses.
        let folder2 = env.root.appendingPathComponent("torn-early", isDirectory: true)
        try FileManager.default.createDirectory(at: folder2, withIntermediateDirectories: true)
        try Data("{\"name\":\"to".utf8).write(to: folder2.appendingPathComponent(ExportFolderManifest.filename))
        XCTAssertThrowsError(try ExportFolderManifest.verify(folder: folder2, expectedPositions: 1))
        var bad = try fileLine("0.txt", Data("x".utf8)); bad.append(0x0A); bad.append(Data("garbage\n".utf8))
        bad.append(try boundaryLine(1, produced: 1)); bad.append(0x0A)
        try bad.write(to: folder2.appendingPathComponent(ExportFolderManifest.filename))
        XCTAssertThrowsError(try ExportFolderManifest.verify(folder: folder2, expectedPositions: 1))
    }

    // MARK: Fifth review S1 — the manifest file itself is untrusted

    func testManifest_asASymlink_isRefusedBeforeAnyReadOrWrite_andAFreshRunNeverWritesThroughOne() async throws {
        let env = try await makeEnv(count: 120); defer { try? FileManager.default.removeItem(at: env.root) }
        let folder = env.root.appendingPathComponent("symlinked-manifest", isDirectory: true)
        let render: @MainActor (MBOXParser.RawEmail, Int) throws -> (filename: String, data: Data)? = { email, index in
            ("\(index).txt", Data((email.headers["Message-ID"] ?? "").utf8))
        }
        var kept = ExportWriteOptions(); kept.keepPartialOnCancel = true
        do {
            _ = try await env.service.exportMessageFiles(scope: .query(.all, exclusions: []), to: folder, batchSize: 40, write: kept) { email, index in
                if index == 50 { throw Injected() }
                return try render(email, index)
            }
            XCTFail()
        } catch is Injected {}
        let manifestURL = folder.appendingPathComponent(ExportFolderManifest.filename)
        let outputBefore = try (0..<40).map { try Data(contentsOf: folder.appendingPathComponent("\($0).txt")) }

        // A writable sentinel OUTSIDE the folder holding a matching, parseable
        // manifest with a trailing entry (what would be truncated).
        let sentinel = env.root.appendingPathComponent("outside-manifest.jsonl")
        var sentinelBytes = try Data(contentsOf: manifestURL)
        sentinelBytes.append(try fileLine("40.txt", Data("x".utf8))); sentinelBytes.append(0x0A)
        try sentinelBytes.write(to: sentinel)
        try FileManager.default.removeItem(at: manifestURL)
        try FileManager.default.createSymbolicLink(at: manifestURL, withDestinationURL: sentinel)

        var resume = kept; resume.skipFirst = 40; resume.append = true
        do {
            _ = try await env.service.exportMessageFiles(scope: .query(.all, exclusions: []), to: folder, batchSize: 40, write: resume, content: render)
            XCTFail("a symlinked manifest must refuse the resume")
        } catch let error as ArchiveExportError {
            guard case .partialManifestInvalid(let why) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(why.contains("symbolic link"), why)
        }
        XCTAssertEqual(try Data(contentsOf: sentinel), sentinelBytes, "the outside file is byte-identical: neither truncated nor appended to")
        XCTAssertEqual(try (0..<40).map { try Data(contentsOf: folder.appendingPathComponent("\($0).txt")) }, outputBefore)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".txt") }.count, 40, "no new file was written")

        // No-tail variant: a matching manifest without trailing bytes would
        // only be appended to — still refused before the append.
        let exact = try Data(contentsOf: manifestURL)   // follows the link: the sentinel's content
        XCTAssertEqual(exact, sentinelBytes)
        sentinelBytes.removeLast(try fileLine("40.txt", Data("x".utf8)).count + 1)
        try sentinelBytes.write(to: sentinel)
        XCTAssertThrowsError(try ExportFolderManifest.verify(folder: folder, expectedPositions: 40))
        XCTAssertEqual(try Data(contentsOf: sentinel), sentinelBytes)

        // A hard link is not the folder's own file either.
        try FileManager.default.removeItem(at: manifestURL)
        try FileManager.default.linkItem(at: sentinel, to: manifestURL)
        XCTAssertThrowsError(try ExportFolderManifest.verify(folder: folder, expectedPositions: 40)) { error in
            guard case ArchiveExportError.partialManifestInvalid(let why)? = error as? ArchiveExportError else { return XCTFail("\(error)") }
            XCTAssertTrue(why.contains("links"), why)
        }
        try FileManager.default.removeItem(at: manifestURL)

        // A FRESH run into a folder that already holds a symlink at the
        // manifest path replaces the link and never writes through it.
        let fresh = env.root.appendingPathComponent("fresh-with-link", isDirectory: true)
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        let sentinel2 = env.root.appendingPathComponent("outside-2.jsonl")
        try Data("untouched\n".utf8).write(to: sentinel2)
        try FileManager.default.createSymbolicLink(at: fresh.appendingPathComponent(ExportFolderManifest.filename), withDestinationURL: sentinel2)
        let result = try await env.service.exportMessageFiles(scope: .query(.all, exclusions: []), to: fresh, batchSize: 40, content: render)
        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.recordsWritten, 120)
        XCTAssertEqual(try String(contentsOf: sentinel2, encoding: .utf8), "untouched\n", "nothing was written through the pre-existing link")
    }

    // MARK: Fifth review S2 — a stray file that cannot be removed is never forgotten

    func testManifest_strayThatCannotBeRemoved_refusesTheResume_andKeepsItsEntryForTheRetry() async throws {
        let env = try await makeEnv(count: 120); defer { try? FileManager.default.removeItem(at: env.root) }
        let folder = env.root.appendingPathComponent("locked-stray", isDirectory: true)
        let render: @MainActor (MBOXParser.RawEmail, Int) throws -> (filename: String, data: Data)? = { email, index in
            ("\(index).txt", Data((email.headers["Message-ID"] ?? "").utf8))
        }
        var kept = ExportWriteOptions(); kept.keepPartialOnCancel = true
        let locked = folder.appendingPathComponent("42.txt")
        // The writer's own stop-time cleanup meets a file it cannot remove:
        // 42.txt (written after the 40 boundary) is made immutable before the
        // failure at 50.
        do {
            _ = try await env.service.exportMessageFiles(scope: .query(.all, exclusions: []), to: folder, batchSize: 40, write: kept) { email, index in
                if index == 45 { try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: locked.path) }
                if index == 50 { throw Injected() }
                return try render(email, index)
            }
            XCTFail()
        } catch is Injected {}
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: locked.path) }
        guard FileManager.default.fileExists(atPath: locked.path) else {
            throw XCTSkip("the immutable flag did not prevent removal on this filesystem; the failure path cannot be injected here")
        }
        let manifestURL = folder.appendingPathComponent(ExportFolderManifest.filename)
        let manifestText = try String(contentsOf: manifestURL, encoding: .utf8)
        XCTAssertTrue(manifestText.contains("\"42.txt\""), "the entry for the file that would not go is kept, not cut away")

        // Resume verification tries again, cannot remove it, and refuses —
        // it does not return success and drop the accounting.
        var resume = kept; resume.skipFirst = 40; resume.append = true
        do {
            _ = try await env.service.exportMessageFiles(scope: .query(.all, exclusions: []), to: folder, batchSize: 40, write: resume, content: render)
            XCTFail("an unremovable stray must refuse the resume")
        } catch let error as ArchiveExportError {
            guard case .partialManifestInvalid(let why) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(why.contains("42.txt") && why.contains("could not be removed"), why)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: locked.path))
        XCTAssertTrue(try String(contentsOf: manifestURL, encoding: .utf8).contains("\"42.txt\""), "still accounted for after the refusal")

        // Deletion becomes possible again: the retry cleans up and completes
        // with exactly the intended output set.
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: locked.path)
        let result = try await env.service.exportMessageFiles(scope: .query(.all, exclusions: []), to: folder, batchSize: 40, write: resume, content: render)
        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.recordsWritten, 120)
        let all = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".txt") }
        XCTAssertEqual(Set(all), Set((0..<120).map { "\($0).txt" }), "exactly the intended files, the once-stray 42.txt rewritten by its message")

        // Accepted-existing files are never candidates for removal, locked or not.
        let folder2 = env.root.appendingPathComponent("locked-accepted", isDirectory: true)
        try FileManager.default.createDirectory(at: folder2, withIntermediateDirectories: true)
        let accepted = folder2.appendingPathComponent("45.txt")
        try Data("mine\n".utf8).write(to: accepted)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: accepted.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: accepted.path) }
        var skipExisting = kept; skipExisting.collision = .skipExisting
        do {
            _ = try await env.service.exportMessageFiles(scope: .query(.all, exclusions: []), to: folder2, batchSize: 40, write: skipExisting) { email, index in
                if index == 50 { throw Injected() }
                return try render(email, index)
            }
            XCTFail()
        } catch is Injected {}
        var resume2 = skipExisting; resume2.skipFirst = 40; resume2.append = true
        let result2 = try await env.service.exportMessageFiles(scope: .query(.all, exclusions: []), to: folder2, batchSize: 40, write: resume2, content: render)
        XCTAssertTrue(result2.completed)
        XCTAssertEqual(try String(contentsOf: accepted, encoding: .utf8), "mine\n")
    }

    // MARK: Selection fingerprint

    func testSelectionFingerprint_isStable_changesWhenTheSelectionChanges_andIgnoresSetOrder() async throws {
        let env = try await makeEnv(count: 60); defer { try? FileManager.default.removeItem(at: env.root) }
        let scope = ArchiveSelectionScope.query(.all, exclusions: [])
        let a = try await env.archive.selectionFingerprint(scope: scope)
        let b = try await env.archive.selectionFingerprint(scope: scope)
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.hasPrefix("60:"))

        try await env.store.insertBatch([email(9_999)], batchSize: 10)
        let c = try await env.archive.selectionFingerprint(scope: scope)
        XCTAssertNotEqual(a, c, "an inserted message changes the positional meaning of the selection")
        XCTAssertTrue(c.hasPrefix("61:"))

        let page = try await env.archive.page(query: .all, cursor: nil, limit: 10)
        let ids = page.summaries.map(\.id)
        let e1 = try await env.archive.selectionFingerprint(scope: .explicit(Set(ids)))
        let e2 = try await env.archive.selectionFingerprint(scope: .explicit(Set(ids.reversed())))
        XCTAssertEqual(e1, e2, "an explicit selection is a set; its fingerprint does not depend on insertion order")
        let e3 = try await env.archive.selectionFingerprint(scope: .explicit(Set(ids.dropLast())))
        XCTAssertNotEqual(e1, e3)
        let none = try await env.archive.selectionFingerprint(scope: .none)
        XCTAssertTrue(none.hasPrefix("0:"))
    }
}
