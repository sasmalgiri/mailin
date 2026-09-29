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
