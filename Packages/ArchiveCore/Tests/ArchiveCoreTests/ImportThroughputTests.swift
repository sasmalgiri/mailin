//
//  ImportThroughputTests.swift
//  ArchiveCoreTests
//
//  The import throughput of the OPTIMISED build through the production
//  coordinator, with the schedule as the only variable. The package is built
//  with `-enable-testing` in every configuration, so this runs under
//  `swift test -c release` as well as `swift test` — same code, same file,
//  same Mac, only the optimiser differs.
//
//  PERF-05 (owner instruction 2026-11-19): compares the same offset parser
//  with and without the one-batch-ahead overlap (`Options.overlapBatches`),
//  and the older streaming parser, on an explicit fixture. It reports wall
//  time, messages/s, MiB/s, time to the first committed batch, number of
//  committed batches and the sampled peak process footprint, and asserts the
//  store / index reconciliation. It does not measure UI first paint or the
//  background attachment job.
//
//  Run (Release):
//    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
//    MAILIN_SCALE=1 MAILIN_SCALE_FILE=/absolute/path/to/file.mbox \
//    MAILIN_IMPORT_SCHEDULE=both \
//    xcrun swift test -c release --package-path Packages/ArchiveCore --filter ImportThroughputTests
//
//  MAILIN_IMPORT_SCHEDULE = sequential | pipelined | both (default) | streaming | all.
//  Without MAILIN_SCALE_FILE the real Enron mbox of the gate-2 corpus is used
//  when present. Alternate the order and repeat at least three times before
//  reading a difference as a speed-up: the OS file cache favours the second run.
//

import XCTest
@testable import ArchiveCore

final class ImportThroughputTests: XCTestCase {

    private static var fixture: URL? {
        let env = ProcessInfo.processInfo.environment
        if let explicit = env["MAILIN_SCALE_FILE"], !explicit.isEmpty {
            let url = URL(fileURLWithPath: explicit)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        for candidate in ["Downloads/Mail/Fixtures/real-corpus-enron/enron.mbox", "Downloads/Mail/Sent.mbox"] {
            let url = home.appendingPathComponent(candidate)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    private enum Schedule: String, CaseIterable {
        case sequential, pipelined, streaming
        var label: String {
            switch self {
            case .sequential: return "offset engine, sequential"
            case .pipelined: return "offset engine, one batch ahead"
            case .streaming: return "streaming parser"
            }
        }
    }

    private static var schedules: [Schedule] {
        switch (ProcessInfo.processInfo.environment["MAILIN_IMPORT_SCHEDULE"] ?? "both").lowercased() {
        case "sequential": return [.sequential]
        case "pipelined": return [.pipelined]
        case "streaming": return [.streaming]
        case "all": return [.sequential, .pipelined, .streaming]
        default: return [.sequential, .pipelined]
        }
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MAILIN_SCALE"] == "1", "opt-in: MAILIN_SCALE=1")
        try XCTSkipUnless(Self.fixture != nil, "no fixture: set MAILIN_SCALE_FILE or build the gate-2 Enron corpus")
    }

    /// Samples the process footprint every 250 ms while the import runs.
    private actor PeakSampler {
        private(set) var peak: UInt64 = 0
        private(set) var baseline: UInt64 = 0
        func start() { baseline = currentFootprintBytes(); peak = baseline }
        func sample() { peak = max(peak, currentFootprintBytes()) }
    }

    func testRealMailbox_productionPath_throughput_bySchedule() async throws {
        let fixture = try XCTUnwrap(Self.fixture)
        let bytes = (try FileManager.default.attributesOfItem(atPath: fixture.path)[.size] as? NSNumber)?.int64Value ?? 0
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("throughput-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #if DEBUG
        let configuration = "debug"
        #else
        let configuration = "release"
        #endif

        for schedule in Self.schedules {
            let runRoot = root.appendingPathComponent(schedule.rawValue, isDirectory: true)
            let store = SQLiteEmailStore(directory: runRoot.appendingPathComponent("store", isDirectory: true))
            let fts = FTSSearchIndex(shardsDirectory: runRoot.appendingPathComponent("fts", isDirectory: true))
            let coordinator = await BulkImportCoordinator(store: store, fts: fts,
                                                          checkpoints: ImportCheckpointStore(store: store),
                                                          requiresStorageActivation: false)
            var options = BulkImportCoordinator.Options()
            options.enforceStoragePreflight = false
            options.useOffsetEngine = schedule != .streaming
            options.recordLocators = schedule != .streaming
            options.overlapBatches = schedule == .pipelined

            let clock = ContinuousClock()
            let sampler = PeakSampler()
            await sampler.start()
            let samplerTask = Task {
                while !Task.isCancelled {
                    await sampler.sample()
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            final class FirstCommit: @unchecked Sendable { var at: ContinuousClock.Instant?; var batches = 0 }
            let firstCommit = FirstCommit()
            var callbacks = BulkImportCoordinator.Callbacks()
            callbacks.onCommittedBatch = { _ in
                firstCommit.batches += 1
                if firstCommit.at == nil { firstCommit.at = clock.now }
            }

            let start = clock.now
            let summary = try await coordinator.runImport(urls: [fixture], options: options, callbacks: callbacks)
            let end = clock.now
            samplerTask.cancel()

            let seconds = Self.seconds(start.duration(to: end))
            let firstCommitSeconds = firstCommit.at.map { Self.seconds(start.duration(to: $0)) }
            let stored = try await store.totalCount()
            let indexed = try await fts.rowCount()
            let peak = await sampler.peak, base = await sampler.baseline
            let mib = Double(bytes) / 1_048_576
            print(String(format: "THROUGHPUT configuration=%@ schedule=\"%@\" file=%@ bytes=%lld messages=%d indexed=%d seconds=%.1f msgs_per_s=%.1f MiB_per_s=%.2f first_commit_s=%@ batches=%d peak_footprint_MB=%.0f baseline_footprint_MB=%.0f damaged=%d persist_failed=%d",
                         configuration, schedule.label, fixture.lastPathComponent, bytes, stored, indexed, seconds,
                         seconds > 0 ? Double(stored) / seconds : 0, seconds > 0 ? mib / seconds : 0,
                         firstCommitSeconds.map { String(format: "%.2f", $0) } ?? "n/a", firstCommit.batches,
                         Double(peak) / 1_048_576, Double(base) / 1_048_576, summary.damaged, summary.persistFailed))
            XCTAssertEqual(summary.parsed, stored, "\(schedule.label): parsed = stored")
            XCTAssertEqual(indexed, stored, "\(schedule.label): FTS rows = stored")
            XCTAssertEqual(summary.persistFailed, 0, schedule.label)
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let c = duration.components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}
