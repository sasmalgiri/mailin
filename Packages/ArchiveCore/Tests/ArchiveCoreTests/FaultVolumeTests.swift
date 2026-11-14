//
//  FaultVolumeTests.swift
//  ArchiveCoreTests
//
//  3.0 Phase B-2 / B-5 fault injection on a disk image standing in for an
//  external SSD. Lives in the PACKAGE test target because it must run
//  unsandboxed: the app-hosted test bundle inherits the app sandbox, which
//  cannot write to a mounted volume (found 2026-09-27 — FileManager
//  surfaced the denial as a DecodingError from createDirectory).
//
//  Prepare:  ~/Downloads/Mail/Scale/fault_volume.sh create 512m && … attach
//  Run:      MAILIN_SCALE=1 MAILIN_FAULT_VOLUME=/Volumes/MailinFault \
//            swift test --package-path Packages/ArchiveCore --filter FaultVolumeTests
//
//  Row: ENOSPC — import more than the volume can hold. The run must end in
//  a NAMED outcome (a low-disk pause, a thrown error, or a per-file persist
//  failure), the store must reopen, and its count must never be below what
//  the index says. No silent partial success, no corrupt database.
//

import XCTest
@testable import ArchiveCore

final class FaultVolumeTests: XCTestCase {

    private static var volume: URL? {
        guard let path = ProcessInfo.processInfo.environment["MAILIN_FAULT_VOLUME"],
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static var fixture: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/Mail/Sent.mbox")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MAILIN_SCALE"] == "1", "fault rows are opt-in: MAILIN_SCALE=1")
        try XCTSkipUnless(Self.volume != nil, "attach the fault volume first: fault_volume.sh create && fault_volume.sh attach")
        try XCTSkipUnless(Self.fixture != nil, "~/Downloads/Mail/Sent.mbox not present")
    }

    func testENOSPC_onFaultVolume_isNamedAndLeavesAConsistentStore() async throws {
        let volume = try XCTUnwrap(Self.volume)
        let fixture = try XCTUnwrap(Self.fixture)
        // Never the app's production tree: the volume is a mounted image.
        XCTAssertFalse(volume.path.contains("/Library/Application Support/"), "refusing a production-looking path")

        let root = volume.appendingPathComponent("enospc-\(UUID().uuidString)", isDirectory: true)
        let sourceRoot = FileManager.default.temporaryDirectory.appendingPathComponent("enospc-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceRoot)
        }

        // Eight copies with unique Message-IDs ≈ 760 MB of source: the store
        // alone (~1.08× source) cannot fit in the 512 MB image.
        let copies = 8
        var sources: [URL] = []
        for n in 0..<copies {
            let copy = sourceRoot.appendingPathComponent("copy-\(n).mbox")
            try Self.replicate(fixture, to: copy, suffix: n)
            sources.append(copy)
        }

        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts", isDirectory: true))
        let checkpoints = ImportCheckpointStore(store: store)
        let coordinator = await BulkImportCoordinator(store: store, fts: fts, checkpoints: checkpoints,
                                                      requiresStorageActivation: false)
        var options = BulkImportCoordinator.Options()
        options.enforceStoragePreflight = false   // we WANT to hit the wall

        // A low-disk pause is a valid outcome; give the run three minutes to
        // fill the volume and declare the pause, then cancel as a user would.
        // The run is its own Task so the coordinator's `cancel()` (and Task
        // cancellation) can reach a run parked in a pause loop.
        let run = Task { @MainActor in
            try await coordinator.runImport(urls: sources, options: options)
        }
        let watchdog = Task { @MainActor in
            try? await Task.sleep(for: .seconds(180))
            coordinator.cancel()
            run.cancel()
        }
        var outcome = "completed"
        var thrown: Error?
        do {
            let summary = try await run.value
            if !summary.fileErrors.isEmpty { outcome = "fileErrors: \(summary.fileErrors.map(\.message))" }
            if summary.persistFailed > 0 { outcome += " persistFailed=\(summary.persistFailed)" }
        } catch {
            thrown = error
            outcome = "threw: \(error.localizedDescription)"
        }
        watchdog.cancel()
        let pauseReason = await coordinator.pauseReason
        let free = (try? volume.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity) ?? -1
        print("ENOSPC outcome: \(outcome); pauseReason=\(pauseReason ?? "nil"); volumeFreeAfter=\(free)")

        // Named outcome: something visible said what happened.
        XCTAssertTrue(thrown != nil || outcome != "completed" || pauseReason != nil,
                      "a run that cannot fit must not report a clean completion")

        // Consistent store: reopens, counts, and never trails the index.
        let reopened = SQLiteEmailStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let stored = try await reopened.totalCount()
        let indexed = try await fts.rowCount()
        XCTAssertGreaterThanOrEqual(stored, indexed, "FTS can lag the store, never lead it")
        XCTAssertGreaterThan(stored, 0, "the rows committed before the wall must still be there")
        print("ENOSPC stored=\(stored) indexed=\(indexed)")
    }

    // MARK: - Eject mid-import

    /// The unplug row, automated: an import is running into the volume; the
    /// image is force-detached (`hdiutil detach -force`, what pulling the
    /// cable does); the coordinator must pause with the volume-detached
    /// reason; the image is re-attached; the run must finish, and the store
    /// must hold exactly the messages of the sources, none twice.
    ///
    /// Needs the image path (`MAILIN_FAULT_IMAGE`, default
    /// `~/Downloads/Mail/Scale/MailinFault.sparseimage`) to re-attach.
    func testEjectMidImport_pausesNamesItAndResumesExactly() async throws {
        let volume = try XCTUnwrap(Self.volume)
        let fixture = try XCTUnwrap(Self.fixture)
        let image = ProcessInfo.processInfo.environment["MAILIN_FAULT_IMAGE"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/Mail/Scale/MailinFault.sparseimage").path
        try XCTSkipUnless(FileManager.default.fileExists(atPath: image), "disk image not found at \(image)")

        let root = volume.appendingPathComponent("eject-\(UUID().uuidString)", isDirectory: true)
        let sourceRoot = FileManager.default.temporaryDirectory.appendingPathComponent("eject-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceRoot)
        }

        // Two copies (1,052 messages, ~190 MB) fit the image with room.
        var sources: [URL] = []
        for n in 0..<2 {
            let copy = sourceRoot.appendingPathComponent("copy-\(n).mbox")
            try Self.replicate(fixture, to: copy, suffix: n)
            sources.append(copy)
        }
        let expected = 2 * 526

        let storeDirectory = root.appendingPathComponent("store", isDirectory: true)
        let store = SQLiteEmailStore(directory: storeDirectory)
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts", isDirectory: true))
        let coordinator = await BulkImportCoordinator(store: store, fts: fts,
                                                      checkpoints: ImportCheckpointStore(store: store),
                                                      requiresStorageActivation: false)
        var options = BulkImportCoordinator.Options()
        options.enforceStoragePreflight = false

        let run = Task { @MainActor in try await coordinator.runImport(urls: sources, options: options) }

        // Let the first batches land.
        var committedBeforeEject = 0
        for _ in 0..<600 {
            try await Task.sleep(for: .milliseconds(200))
            committedBeforeEject = (try? await store.totalCount()) ?? 0
            if committedBeforeEject >= 200 { break }
        }
        XCTAssertGreaterThanOrEqual(committedBeforeEject, 200, "the import must be under way before the eject")

        // Pull the cable BETWEEN batches — the moment the design guards
        // ("unplug-before-write"): pause, let the in-flight batch commit, then
        // detach and resume. An unplug that lands in the middle of a SQLite
        // write is a different event: WAL mode memory-maps the `-shm` index,
        // so the OS terminates the process with SIGBUS (observed 2026-09-27),
        // exactly as for any app whose database is on the removed disk; what
        // holds then is WAL recovery + the v17 checkpoint on relaunch, which
        // `ResumeTests` cover. That case cannot be exercised in-process.
        await MainActor.run { coordinator.pause() }
        var settled = -1
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(300))
            let now = (try? await store.totalCount()) ?? 0
            if now == settled { break }
            settled = now
        }
        committedBeforeEject = max(committedBeforeEject, settled)
        try Self.shell("/usr/bin/hdiutil", ["detach", volume.path, "-force"])
        let detachedAt = Date()
        await MainActor.run { coordinator.resume() }

        // The coordinator must name the pause within a few batch boundaries.
        var pauseReason: String?
        for _ in 0..<300 {
            try await Task.sleep(for: .milliseconds(200))
            pauseReason = await coordinator.pauseReason
            if pauseReason != nil { break }
            if run.isCancelled { break }
        }
        print("EJECT pauseReason=\(pauseReason ?? "nil") after \(String(format: "%.1f", Date().timeIntervalSince(detachedAt))) s; committedBeforeEject=\(committedBeforeEject)")
        XCTAssertNotNil(pauseReason, "an ejected archive volume must be reported, not silently retried")
        XCTAssertTrue(pauseReason?.localizedCaseInsensitiveContains("volume") == true
                      || pauseReason?.localizedCaseInsensitiveContains("detached") == true,
                      "reason must say what happened: \(pauseReason ?? "nil")")

        // Plug it back in.
        try await Task.sleep(for: .seconds(5))
        try Self.shell("/usr/bin/hdiutil", ["attach", image, "-mountpoint", volume.path])

        // The run must finish by itself, with exact counts.
        let watchdog = Task { @MainActor in
            try? await Task.sleep(for: .seconds(600))
            coordinator.cancel(); run.cancel()
        }
        var outcome = "completed"
        var summary: BulkImportCoordinator.RunSummary?
        do {
            summary = try await run.value
            outcome = "completed inserted=\(summary?.inserted.map(String.init) ?? "nil") duplicates=\(summary?.duplicates.map(String.init) ?? "nil") persistFailed=\(summary?.persistFailed ?? -1) fileErrors=\(summary?.fileErrors.map(\.message) ?? [])"
        } catch {
            outcome = "threw: \(error.localizedDescription)"
        }
        watchdog.cancel()
        print("EJECT outcome: \(outcome)")
        // Fresh instances over the re-attached volume: the handles the run
        // held point at the OLD mount and must not be what the verdict reads.
        let reopened = SQLiteEmailStore(directory: storeDirectory)
        let freshFTS = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts", isDirectory: true))
        let stored = try await reopened.totalCount()
        let indexed = try await freshFTS.rowCount()
        print("EJECT stored=\(stored) indexed=\(indexed) expected=\(expected)")
        let finished = try XCTUnwrap(summary, "the run must finish after the reconnect: \(outcome)")
        XCTAssertEqual(finished.persistFailed, 0, "no batch may be lost to the unplug: \(outcome)")
        XCTAssertTrue(finished.fileErrors.isEmpty, "\(finished.fileErrors.map { $0.message })")
        // Exact accounting: every message of both sources is either a row or
        // a recorded duplicate (copy 0 carries the fixture's own IDs; a message
        // without a Message-ID is identical in both copies), and nothing is
        // stored twice.
        XCTAssertEqual(stored + (finished.duplicates ?? 0), expected, "inserted + deduplicated must equal the sources' messages")
        XCTAssertEqual(finished.inserted, stored, "the summary's inserted count must be what the reopened store holds")
        XCTAssertEqual(indexed, stored, "index must be complete after the resume")
    }

    private struct ShellError: Error, CustomStringConvertible { let description: String }

    private static func shell(_ launchPath: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw ShellError(description: "\(launchPath) \(arguments.joined(separator: " ")) → \(process.terminationStatus): \(text)")
        }
    }

    /// Streams `source` to `destination`, suffixing every Message-ID with
    /// `.fN` so the copies are distinct rows. Same rule as the fixture scripts.
    private static func replicate(_ source: URL, to destination: URL, suffix: Int) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        let marker = Data("Message-ID: <".utf8)
        let at = UInt8(ascii: "@")
        var carry = Data()
        while let chunk = try input.read(upToCount: 4 << 20), !chunk.isEmpty {
            var data = carry + chunk
            let keep = min(data.count, 512)
            carry = data.suffix(keep)
            data.removeLast(keep)
            var out = Data(capacity: data.count + 1024)
            var searchFrom = data.startIndex
            while let range = data.range(of: marker, in: searchFrom..<data.endIndex) {
                out.append(data[searchFrom..<range.upperBound])
                var i = range.upperBound
                while i < data.endIndex, data[i] != at, data[i] != UInt8(ascii: ">"), data[i] != UInt8(ascii: "\n") { i += 1 }
                out.append(data[range.upperBound..<i])
                if suffix > 0, i < data.endIndex, data[i] == at { out.append(Data(".f\(suffix)".utf8)) }
                searchFrom = i
            }
            out.append(data[searchFrom..<data.endIndex])
            try output.write(contentsOf: out)
        }
        try output.write(contentsOf: carry)
    }
}
