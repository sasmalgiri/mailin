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
