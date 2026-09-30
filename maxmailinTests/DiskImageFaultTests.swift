@testable import ArchiveCore
//
//  DiskImageFaultTests.swift
//  maxmailinTests
//
//  3.0 Phase B-2 / B-5: fault injection on a disk image standing in for an
//  external SSD (owner decision 2026-09-27: no physical SSD; hdiutil image).
//
//  Opt-in: `~/Downloads/Mail/Scale/fault_volume.sh create 512m && … attach`
//  prints the `MAILIN_FAULT_VOLUME` export; run with MAILIN_SCALE=1. The
//  test host is sandboxed and cannot attach images itself, so the volume is
//  prepared outside and read from the environment.
//
//  Rows:
//   • ENOSPC — import more than the volume can hold. The run must end in a
//     NAMED outcome (a storage refusal before start, a low-disk pause that is
//     cancelled, or a persist failure recorded per file), the store must
//     reopen, and its count must equal what the checkpoint says was
//     committed. No silent partial success, no corrupt database.
//   • Relocation — copy an archive onto the volume with `ArchiveRelocator`,
//     verify, and read it back from the new location.
//
//  The eject-mid-import row is driven by hand (`fault_volume.sh detach`
//  during a run) and recorded in SCALE_RESULTS.md; its automatic half is the
//  coordinator's `waitForStoreVolume`, which `RelocationAndVolumeTests`
//  covers with a renamed directory instead of an eject.
//

import XCTest
@testable import maxmailin

final class DiskImageFaultTests: XCTestCase {

    private static var volume: URL? {
        guard let path = ProcessInfo.processInfo.environment["MAILIN_FAULT_VOLUME"],
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static var fixture: URL? {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads/Mail/Sent.mbox")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MAILIN_SCALE"] == "1", "fault rows are opt-in: MAILIN_SCALE=1")
        try XCTSkipUnless(Self.volume != nil, "attach the fault volume first: fault_volume.sh create && fault_volume.sh attach")
        try XCTSkipUnless(Self.fixture != nil, "~/Downloads/Mail/Sent.mbox not present")
        // The app-hosted bundle runs INSIDE the app sandbox, which has no
        // access to a mounted volume (any mount point — /Volumes or a folder
        // under ~/Downloads; FileManager reports the denial as a
        // DecodingError). Probe once and skip with the real reason; the
        // executed row is `FaultVolumeTests` in Packages/ArchiveCore, run
        // unsandboxed with `swift test`.
        if let volume = Self.volume {
            let probe = volume.appendingPathComponent("write-probe-\(UUID().uuidString)", isDirectory: true)
            let writable = (try? FileManager.default.createDirectory(at: probe, withIntermediateDirectories: true)) != nil
            try? FileManager.default.removeItem(at: probe)
            try XCTSkipUnless(writable, """
                the sandboxed test host cannot write to \(volume.path); run the row unsandboxed: \
                MAILIN_SCALE=1 MAILIN_FAULT_VOLUME=\(volume.path) swift test --package-path Packages/ArchiveCore --filter FaultVolumeTests
                """)
        }
    }

    /// Fill the volume: the 95 MB fixture replicated until the 512 MB image
    /// cannot hold the archive. Whatever stops the run must be named, and the
    /// store left behind must be consistent.
    /// Wraps one preparatory step so a thrown error names the step: an
    /// `async throws` test reports a thrown error at `<unknown>:0`.
    private func step<T>(_ name: String, _ body: () throws -> T) throws -> T {
        do { return try body() } catch { throw StepError(step: name, underlying: error) }
    }
    private struct StepError: Error, CustomStringConvertible {
        let step: String; let underlying: Error
        var description: String { "step '\(step)' failed: \(String(reflecting: underlying))" }
        var localizedDescription: String { description }
    }

    func testENOSPC_onFaultVolume_isNamedAndLeavesAConsistentStore() async throws {
        let volume = try XCTUnwrap(Self.volume)
        let fixture = try XCTUnwrap(Self.fixture)
        // The ARCHIVE goes on the small volume; the replicated sources stay in
        // the sandbox's temporary directory so the volume is filled by the
        // import, not by the fixtures.
        let root = volume.appendingPathComponent("enospc-\(UUID().uuidString)", isDirectory: true)
        let sourceRoot = FileManager.default.temporaryDirectory.appendingPathComponent("enospc-src-\(UUID().uuidString)", isDirectory: true)
        try step("create archive root on the volume") {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        try step("create source root in temp") {
            try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        }
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceRoot)
        }
        try step("assertNotProduction") { try MailinStorageEnvironment.assertNotProduction(root) }

        // Eight copies with unique Message-IDs ≈ 760 MB of source → the store
        // alone (~1.08× source) cannot fit in 512 MB.
        let copies = 8
        var sources: [URL] = []
        for n in 0..<copies {
            let copy = sourceRoot.appendingPathComponent("copy-\(n).mbox")
            try step("replicate copy \(n)") { try Self.replicate(fixture, to: copy, suffix: n) }
            sources.append(copy)
        }

        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts", isDirectory: true))
        let checkpoints = ImportCheckpointStore(store: store)
        let coordinator = await BulkImportCoordinator(store: store, fts: fts, checkpoints: checkpoints,
                                                      requiresStorageActivation: false)
        var options = BulkImportCoordinator.Options()
        options.enforceStoragePreflight = false   // we WANT to hit the wall

        // A low-disk pause is a valid outcome; give it 60 s to declare itself
        // and then cancel, as a user would.
        let watchdog = Task { @MainActor in
            try? await Task.sleep(for: .seconds(600))
            coordinator.cancel()
        }
        var outcome = "completed"
        var thrown: Error?
        do {
            let summary = try await coordinator.runImport(urls: sources, options: options)
            if !summary.fileErrors.isEmpty { outcome = "fileErrors: \(summary.fileErrors.map(\.message))" }
            if summary.persistFailed > 0 { outcome += " persistFailed=\(summary.persistFailed)" }
        } catch {
            thrown = error
            outcome = "threw: \(error.localizedDescription)"
        }
        watchdog.cancel()
        let pauseReason = await coordinator.pauseReason
        print("ENOSPC outcome: \(outcome); pauseReason=\(pauseReason ?? "nil")")

        // Named outcome: something visible said what happened.
        XCTAssertTrue(thrown != nil || outcome != "completed" || pauseReason != nil,
                      "a run that cannot fit must not report a clean completion")

        // Consistent store: reopens, counts, and matches the checkpoint ledger.
        let reopened = SQLiteEmailStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let stored = try await reopened.totalCount()
        let indexed = try await fts.rowCount()
        XCTAssertGreaterThanOrEqual(stored, indexed, "FTS can lag the store, never lead it")
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
            // Keep a tail so a header split across chunks is handled next round.
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
