//
//  FixtureImportMeasurementTests.swift
//  maxmailinTests
//
//  P0.2 / P9 measurement against a REAL owner-supplied corpus rather than a
//  synthetic one, so the numbers in RELEASE_READINESS.md come from actual mail
//  with actual attachments.
//
//  Safety: the corpus is parsed into `MailinStorageEnvironment.disposable(at:)`,
//  which hard-refuses any root overlapping the production tree. The owner's
//  real archive is never read, written, migrated or vacuumed by this test.
//
//  Honesty: this measures the ENGINE path — parser → store → FTS, the same
//  production components, driven directly. It is NOT the production
//  BulkImportCoordinator path (that is @MainActor and wired to the shared
//  singletons; injecting a repository into it is tracked as plan task A10).
//  Do not quote these numbers as production-path results.
//
//  The test skips rather than fails when the fixture is absent, so CI on
//  another machine stays green.
//

import XCTest
@testable import maxmailin

final class FixtureImportMeasurementTests: XCTestCase {

    /// Owner-supplied fixture (see RELEASE_READINESS.md §P0.2).
    private static var fixtureURL: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/Mail/Sent.mbox")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func testEnginePathImport_realMBOXFixture_measured() async throws {
        guard let fixture = Self.fixtureURL else {
            throw XCTSkip("fixture ~/Downloads/Mail/Sent.mbox not present on this machine")
        }
        let bytes = (try FileManager.default.attributesOfItem(atPath: fixture.path)[.size] as? NSNumber)?.int64Value ?? 0

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixture-measure-\(UUID().uuidString)", isDirectory: true)
        let env = try MailinStorageEnvironment.disposable(at: root)
        XCTAssertFalse(env.isProduction, "measurement must never touch production storage")
        defer { try? FileManager.default.removeItem(at: root) }

        let clock = ContinuousClock()
        let rssBaseline = currentFootprintBytes()
        var rssPeak = rssBaseline
        var discovered = 0
        var batches = 0
        var withAttachments = 0

        // Production default batch size (BulkImportCoordinator.Options.batchSize).
        let start = clock.now
        let report = try await ParserFactory.parseStreamingCallback(
            fileURL: fixture, senderEmail: "", batchSize: 500
        ) { batch in
            discovered += batch.count
            batches += 1
            withAttachments += batch.reduce(0) { $0 + ($1.attachments.isEmpty ? 0 : 1) }
            try await env.store.insertBatch(batch, batchSize: 500)
            try await env.fts.indexBatch(batch)
            rssPeak = max(rssPeak, currentFootprintBytes())
        }
        let elapsed = start.duration(to: clock.now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        if let sqlite = env.store as? SQLiteEmailStore { try? await sqlite.checkpoint() }

        let stored = try await env.store.totalCount()
        let ftsRows = try await env.fts.rowCount()
        let mib = { (b: UInt64) in Double(b) / 1_048_576.0 }

        // Reconciliation is the acceptance criterion, not throughput: every
        // discovered message must be either stored or accounted for as damaged,
        // and the FTS index must cover what was stored.
        XCTAssertEqual(stored + report.failed, discovered,
                       "every discovered message must be stored or counted damaged")
        XCTAssertEqual(ftsRows, stored, "FTS coverage must equal stored rows")

        print("""
        FIXTURE-MEASUREMENT engine-path \
        source=Sent.mbox bytes=\(bytes) \
        discovered=\(discovered) stored=\(stored) damaged=\(report.failed) parserTotal=\(report.totalMessages) \
        withAttachments=\(withAttachments) batches=\(batches) \
        ftsRows=\(ftsRows) \
        seconds=\(String(format: "%.2f", seconds)) \
        rssBaselineMiB=\(String(format: "%.1f", mib(rssBaseline))) \
        rssPeakMiB=\(String(format: "%.1f", mib(rssPeak))) \
        rssDeltaMiB=\(String(format: "%.1f", mib(rssPeak) - mib(rssBaseline)))
        """)
    }

    /// PRODUCTION-PATH measurement: the same BulkImportCoordinator the app
    /// uses, driven over disposable storage via the A10 injection. This is the
    /// number that may be quoted as production-path (configuration caveats
    /// still apply — the test target builds Debug).
    func testProductionPathImport_realMBOXFixture_measured() async throws {
        guard let fixture = Self.fixtureURL else {
            throw XCTSkip("fixture ~/Downloads/Mail/Sent.mbox not present on this machine")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixture-prodpath-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Disposable storage triple; the gate in MailinStorageEnvironment is
        // asserted separately, and none of these point at production.
        try MailinStorageEnvironment.assertNotProduction(root)
        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts", isDirectory: true))
        let checkpoints = ImportCheckpointStore(storeURL: root.appendingPathComponent("checkpoints.json"))

        let coordinator = await BulkImportCoordinator(
            store: store, fts: fts, checkpoints: checkpoints,
            requiresStorageActivation: false
        )

        let clock = ContinuousClock()
        let rssBaseline = currentFootprintBytes()
        let start = clock.now
        // P3.1: count batches and sample peak footprint per committed batch, so
        // the adaptive envelope's effect is measured rather than assumed.
        let probe = BatchProbe(baseline: rssBaseline)
        var callbacks = BulkImportCoordinator.Callbacks()
        callbacks.onCommittedBatch = { batch in
            probe.record(count: batch.count, footprint: currentFootprintBytes())
        }
        let summary = try await coordinator.runImport(urls: [fixture], callbacks: callbacks)
        let elapsed = start.duration(to: clock.now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        let rssAfter = currentFootprintBytes()

        let stored = try await store.totalCount()
        let ftsRows = try await fts.rowCount()
        let mib = { (b: UInt64) in Double(b) / 1_048_576.0 }
        let shape = probe.snapshot

        // S2: measured on-disk growth, so StoragePlanner's coefficients come
        // from a real corpus instead of a guess.
        func directoryBytes(_ url: URL) -> Int64 {
            guard let walker = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]) else { return 0 }
            var total: Int64 = 0
            for case let file as URL in walker {
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                total += Int64(size)
            }
            return total
        }
        let storeBytes = directoryBytes(root.appendingPathComponent("store", isDirectory: true))
        let ftsBytes = directoryBytes(root.appendingPathComponent("fts", isDirectory: true))
        let sourceBytes = (try FileManager.default
            .attributesOfItem(atPath: fixture.path)[.size] as? NSNumber)?.int64Value ?? 1
        print("""
        STORAGE-GROWTH sourceBytes=\(sourceBytes) storeBytes=\(storeBytes) ftsBytes=\(ftsBytes) \
        storeRatio=\(String(format: "%.3f", Double(storeBytes) / Double(sourceBytes))) \
        ftsRatio=\(String(format: "%.3f", Double(ftsBytes) / Double(sourceBytes))) \
        totalRatio=\(String(format: "%.3f", Double(storeBytes + ftsBytes) / Double(sourceBytes)))
        """)

        XCTAssertGreaterThan(shape.batches, 2,
                             "adaptive batching must split this attachment-heavy source into more than the two batches the fixed 500 produced")
        XCTAssertEqual(summary.discovered, summary.parsed + summary.damaged,
                       "discovered must equal parsed + damaged")
        XCTAssertEqual(stored, summary.parsed - summary.persistFailed,
                       "stored rows must equal parsed minus hard persist failures")
        XCTAssertEqual(ftsRows, stored, "FTS coverage must equal stored rows")

        print("""
        FIXTURE-MEASUREMENT production-path \
        batches=\(shape.batches) minBatch=\(shape.minBatch) maxBatch=\(shape.maxBatch) \
        rssPeakMiB=\(String(format: "%.1f", mib(shape.peak))) \
        rssDeltaMiB=\(String(format: "%.1f", mib(shape.peak) - mib(rssBaseline))) \
        discovered=\(summary.discovered) parsed=\(summary.parsed) \
        inserted=\(summary.inserted.map(String.init) ?? "nil") \
        duplicates=\(summary.duplicates.map(String.init) ?? "nil") \
        damaged=\(summary.damaged) persistFailed=\(summary.persistFailed) \
        indexed=\(summary.indexed) stored=\(stored) ftsRows=\(ftsRows) \
        seconds=\(String(format: "%.2f", seconds)) \
        rssBaselineMiB=\(String(format: "%.1f", mib(rssBaseline))) \
        rssAfterMiB=\(String(format: "%.1f", mib(rssAfter)))
        """)
    }

    /// The safety gate itself, asserted here too so a future refactor of the
    /// measurement cannot quietly start writing into the real archive.
    func testMeasurementCannotRootOnProduction() {
        let prod = MailinStorageEnvironment.productionStorageDirectory
        XCTAssertThrowsError(try MailinStorageEnvironment.disposable(at: prod))
        XCTAssertThrowsError(
            try MailinStorageEnvironment.disposable(at: prod.appendingPathComponent("sqlite"))
        )
    }
}


/// Records batch sizes and peak footprint during a production-path import.
/// Lock-guarded rather than actor-isolated: the callback arrives on the main
/// actor while the test body reads it from a non-isolated context.
private final class BatchProbe: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var batches = 0
    private(set) var minBatch = Int.max
    private(set) var maxBatch = 0
    private(set) var peakFootprint: UInt64

    init(baseline: UInt64) { self.peakFootprint = baseline }

    func record(count: Int, footprint: UInt64) {
        lock.lock(); defer { lock.unlock() }
        batches += 1
        minBatch = min(minBatch, count)
        maxBatch = max(maxBatch, count)
        peakFootprint = max(peakFootprint, footprint)
    }

    var snapshot: (batches: Int, minBatch: Int, maxBatch: Int, peak: UInt64) {
        lock.lock(); defer { lock.unlock() }
        return (batches, minBatch, maxBatch, peakFootprint)
    }
}
