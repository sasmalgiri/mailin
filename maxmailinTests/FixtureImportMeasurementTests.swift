@testable import ArchiveCore
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
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Downloads/Mail/Sent.mbox")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func testEnginePathImport_realMBOXFixture_measured() async throws {
        guard let fixture = Self.fixtureURL else {
            throw XCTSkip("fixture ~/Downloads/Mail/Sent.mbox not present on this machine")
        }
        // A full volume makes this fail as `exec("disk I/O error")`, which
        // looks like a store defect. Skip with the shortfall named instead.
        try TestPreconditions.requireFreeSpace(TestPreconditions.referenceFixtureBudget)
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
        // A full volume makes this fail as `exec("disk I/O error")`, which
        // looks like a store defect. Skip with the shortfall named instead.
        try TestPreconditions.requireFreeSpace(TestPreconditions.referenceFixtureBudget)
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

// MARK: - Scale run: 1.5 GB of REAL content through the production path

/// P9 at the 1–2 GB step, on the owner's request (2026-09-26). The fixture is
/// `~/Downloads/Mail/Scale/Sent-x16.mbox`: the real 526-message `Sent.mbox`
/// replicated 16 times by `make_scale_fixture.py` beside it, changing only
/// the Message-ID (a `.cN` suffix, so dedup keeps every copy) and the Date
/// (shifted 37 days per copy, so the years spread across FTS shards). Every
/// body, MIME structure, attachment and CRLF is the real one. The label for
/// the results document is therefore "real content, synthetic replication",
/// not "real corpus".
///
/// Skips when the fixture is absent or the volume lacks room for source +
/// store + FTS + export (≈ 4 × source). Also skips unless `MAILIN_SCALE=1`
/// is in the environment: the three runs take about an hour together on
/// this Mac and would otherwise ride along with every full-plan run. Run
/// them deliberately, e.g. from the scheme's test environment or
/// `MAILIN_SCALE=1 xcodebuild test -only-testing:maxmailinTests/ScaleFixtureImportTests`.
final class ScaleFixtureImportTests: XCTestCase {

    private static var scaleRunsEnabled: Bool {
        ProcessInfo.processInfo.environment["MAILIN_SCALE"] == "1"
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(Self.scaleRunsEnabled,
                          "scale runs are opt-in: set MAILIN_SCALE=1 (each run is 15–35 minutes)")
    }

    private static var scaleFixtureURL: URL? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Downloads/Mail/Scale/Sent-x16.mbox")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static var scaleZipURL: URL? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Downloads/Mail/Scale/Sent-x16.zip")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static let expectedMessages = 526 * 16

    private func directoryBytes(_ url: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    private struct Run {
        let root: URL
        let store: SQLiteEmailStore
        let fts: FTSSearchIndex
        let summary: BulkImportCoordinator.RunSummary
        let seconds: Double
        let rssBaseline: UInt64
        let rssPeak: UInt64
        let rssAfter: UInt64
        let batches: Int
    }

    /// The production coordinator over disposable storage, with per-batch
    /// footprint sampling. Shared by the mbox and the ZIP runs.
    private func importThroughProductionPath(_ source: URL, label: String, useOffsetEngine: Bool = false) async throws -> Run {
        let sourceBytes = (try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value ?? 0
        try TestPreconditions.requireFreeSpace(sourceBytes * 4)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scale-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try MailinStorageEnvironment.assertNotProduction(root)
        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts", isDirectory: true))
        // v17: store-backed checkpoints, exactly as production.
        let checkpoints = ImportCheckpointStore(store: store)
        let coordinator = await BulkImportCoordinator(store: store, fts: fts, checkpoints: checkpoints,
                                                      requiresStorageActivation: false)
        let clock = ContinuousClock()
        let rssBaseline = currentFootprintBytes()
        let probe = BatchProbe(baseline: rssBaseline)
        var callbacks = BulkImportCoordinator.Callbacks()
        callbacks.onCommittedBatch = { batch in probe.record(count: batch.count, footprint: currentFootprintBytes()) }
        var options = BulkImportCoordinator.Options()
        options.useOffsetEngine = useOffsetEngine
        let start = clock.now
        let summary = try await coordinator.runImport(urls: [source], options: options, callbacks: callbacks)
        let elapsed = start.duration(to: clock.now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        let shape = probe.snapshot
        return Run(root: root, store: store, fts: fts, summary: summary, seconds: seconds,
                   rssBaseline: rssBaseline, rssPeak: shape.peak, rssAfter: currentFootprintBytes(),
                   batches: shape.batches)
    }

    private func report(_ run: Run, source: URL, label: String) async throws {
        let mib = { (b: UInt64) in Double(b) / 1_048_576.0 }
        let sourceBytes = (try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value ?? 1
        let stored = try await run.store.totalCount()
        let ftsRows = try await run.fts.rowCount()
        let storeBytes = directoryBytes(run.root.appendingPathComponent("store", isDirectory: true))
        let ftsBytes = directoryBytes(run.root.appendingPathComponent("fts", isDirectory: true))
        print("""

        ── SCALE-RUN \(label) ─────────────────────────────────────────
        source            \(sourceBytes) bytes (\(String(format: "%.2f", Double(sourceBytes) / 1e9)) GB)
        discovered/parsed \(run.summary.discovered) / \(run.summary.parsed)   damaged \(run.summary.damaged)   persistFailed \(run.summary.persistFailed)
        inserted/dupes    \(run.summary.inserted.map(String.init) ?? "nil") / \(run.summary.duplicates.map(String.init) ?? "nil")
        stored / ftsRows  \(stored) / \(ftsRows)   indexed \(run.summary.indexed)   attachmentsSeen \(run.summary.attachmentsSeen)
        batches           \(run.batches)
        seconds           \(String(format: "%.1f", run.seconds))   → \(String(format: "%.1f", Double(sourceBytes) / 1_048_576.0 / run.seconds)) MiB/s, \(String(format: "%.0f", Double(stored) / run.seconds)) msg/s
        rss baseline/peak/after  \(String(format: "%.0f", mib(run.rssBaseline))) / \(String(format: "%.0f", mib(run.rssPeak))) / \(String(format: "%.0f", mib(run.rssAfter))) MiB   (peak delta \(String(format: "%.0f", mib(run.rssPeak) - mib(run.rssBaseline))) MiB)
        store / fts bytes \(storeBytes) / \(ftsBytes)   ratios store \(String(format: "%.3f", Double(storeBytes) / Double(sourceBytes))) fts \(String(format: "%.3f", Double(ftsBytes) / Double(sourceBytes))) total \(String(format: "%.3f", Double(storeBytes + ftsBytes) / Double(sourceBytes)))
        ────────────────────────────────────────────────────────────────
        """)

        XCTAssertEqual(run.summary.discovered, Self.expectedMessages, "every envelope in the 16 copies is discovered")
        XCTAssertEqual(run.summary.damaged, 0)
        XCTAssertEqual(run.summary.persistFailed, 0)
        XCTAssertEqual(run.summary.duplicates ?? 0, 0, "the .cN Message-ID suffix keeps every copy")
        XCTAssertEqual(stored, Self.expectedMessages)
        XCTAssertEqual(ftsRows, stored, "FTS coverage equals stored rows")
        // The claim that matters at scale: memory does not grow with the file.
        // 1.5 GB in; the peak over baseline must stay far below the source.
        XCTAssertLessThan(Int64(run.rssPeak) - Int64(run.rssBaseline), 1_073_741_824,
                          "peak footprint over baseline must not approach the source size")
    }

    /// The whole 1.5 GB through the production path, then EXPORTED again as
    /// mbox and re-parsed: the round trip must return every message.
    func testScale_1_5GB_importThenExportRoundTrip() async throws {
        guard let fixture = Self.scaleFixtureURL else {
            throw XCTSkip("~/Downloads/Mail/Scale/Sent-x16.mbox is not present — run make_scale_fixture.py")
        }
        let run = try await importThroughProductionPath(fixture, label: "mbox")
        defer { try? FileManager.default.removeItem(at: run.root) }
        try await report(run, source: fixture, label: "mbox 1.5 GB")

        // Export round trip ([[no-artificial-caps]]: round-trip-verify exports).
        let archive = ArchiveDataService(repository: EmailStoreRepository(store: run.store, fts: run.fts))
        let exporter = await ArchiveExportService(archive: archive)
        let out = run.root.appendingPathComponent("roundtrip.mbox")
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await exporter.exportMBOXArchive(scope: .query(.all, exclusions: []), to: out)
        let exportSeconds = { let c = start.duration(to: clock.now).components; return Double(c.seconds) + Double(c.attoseconds) / 1e18 }()
        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.recordsWritten, Self.expectedMessages)

        var reparsed = 0
        let reparseReport = try await ParserFactory.parseStreamingCallback(fileURL: out, senderEmail: "", batchSize: 500) { reparsed += $0.count }
        let outBytes = (try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? NSNumber)?.int64Value ?? 0
        print("""
        ── SCALE-RUN export round trip ────────────────────────────────
        written \(result.recordsWritten) records, \(outBytes) bytes, sha256 \(result.sha256Hex ?? "—"), \(String(format: "%.1f", exportSeconds)) s
        re-parsed \(reparsed) (report total \(reparseReport.totalMessages), failed \(reparseReport.failed))
        ────────────────────────────────────────────────────────────────
        """)
        XCTAssertEqual(reparsed, Self.expectedMessages, "export → re-parse must return every message")
        XCTAssertEqual(reparseReport.failed, 0)
    }

    /// The same 1.5 GB through the S4 OFFSET engine (`Capability.offsetParser`,
    /// off by default): byte-offset scan, header-only parse, locators recorded.
    /// Measured side by side with the streaming parser so the throughput
    /// difference is a number, not an expectation.
    func testScale_1_5GB_offsetEngine() async throws {
        guard let fixture = Self.scaleFixtureURL else {
            throw XCTSkip("~/Downloads/Mail/Scale/Sent-x16.mbox is not present — run make_scale_fixture.py")
        }
        let run = try await importThroughProductionPath(fixture, label: "offset", useOffsetEngine: true)
        defer { try? FileManager.default.removeItem(at: run.root) }
        try await report(run, source: fixture, label: "mbox 1.5 GB — OFFSET engine")
    }

    /// The same 1.5 GB inside a stored ZIP: the container path streams it to
    /// scratch with size and CRC-32 verified, then imports it identically.
    func testScale_1_5GB_insideZIP() async throws {
        guard let zip = Self.scaleZipURL else {
            throw XCTSkip("~/Downloads/Mail/Scale/Sent-x16.zip is not present — `zip -0 Sent-x16.zip Sent-x16.mbox`")
        }
        XCTAssertEqual(SourceFormatClassifier.classify(url: zip).format, .zip)
        let run = try await importThroughProductionPath(zip, label: "zip")
        defer { try? FileManager.default.removeItem(at: run.root) }
        try await report(run, source: zip, label: "zip 1.5 GB (stored member)")
    }
}

// MARK: - Five jobs OPEN-06 — the format matrix at 100 MB (owner, 2026-11-05)

/// The owner's rule for this release: test every format at about 100 MB;
/// the bounded-memory design is the evidence for larger files, and the
/// documents say "tested at 100 MB; memory does not grow with file size" —
/// never more than that.
///
/// No real 100 MB fixtures live on this Mac any more, so the matrix generates
/// its own: a ~100 MB mbox of synthetic messages with a base64 attachment
/// each, imported through the PRODUCTION coordinator; then that archive is
/// exported as PST (mailin's own MS-PST writer), as a folder of .eml files
/// and as .msg files, and each export is imported into a fresh environment.
/// For every run the figures asked for are recorded separately: time to the
/// first committed message, total time, peak footprint over baseline, final
/// store + search index size, and the largest transient growth of the
/// environment while the run was going (temporary disk).
///
/// A 25 MB mbox runs last so "memory does not grow with file size" is a
/// comparison between two sizes, not a feeling. Rows are printed in the
/// SCALE_RESULTS.md format. Set MAILIN_SKIP_MATRIX=1 to skip (≈ 5–10 min).
final class HundredMegabyteFormatMatrixTests: XCTestCase {

    private struct Run {
        let label: String
        let sourceBytes: Int64
        let expectedMessages: Int
        let firstMessageSeconds: Double
        let seconds: Double
        let baselineBytes: UInt64
        let peakBytes: UInt64
        let storeBytes: Int64
        let ftsBytes: Int64
        let peakTransientBytes: Int64
        let stored: Int
        let ftsRows: Int
        let summary: BulkImportCoordinator.RunSummary
        let root: URL
        let store: SQLiteEmailStore
        let fts: FTSSearchIndex
        var peakDeltaMB: Double { Double(peakBytes) - Double(baselineBytes) > 0 ? (Double(peakBytes) - Double(baselineBytes)) / 1_048_576 : 0 }
    }

    /// Per-batch sampling: footprint and the environment's size on disk.
    private final class Sampler: @unchecked Sendable {
        private let lock = NSLock()
        private let root: URL
        private let start: ContinuousClock.Instant
        private let clock = ContinuousClock()
        private(set) var firstMessageSeconds: Double?
        private(set) var peakFootprint: UInt64
        private(set) var peakRootBytes: Int64 = 0
        private(set) var batches = 0
        init(root: URL, baseline: UInt64, start: ContinuousClock.Instant) { self.root = root; self.peakFootprint = baseline; self.start = start }
        func record(count: Int) {
            let now = clock.now
            let footprint = currentFootprintBytes()
            let bytes = HundredMegabyteFormatMatrixTests.directoryBytes(root)
            lock.lock(); defer { lock.unlock() }
            batches += 1
            if firstMessageSeconds == nil, count > 0 {
                let d = start.duration(to: now).components
                firstMessageSeconds = Double(d.seconds) + Double(d.attoseconds) / 1e18
            }
            peakFootprint = max(peakFootprint, footprint)
            peakRootBytes = max(peakRootBytes, bytes)
        }
    }

    static func directoryBytes(_ url: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker { total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }

    // MARK: Fixture generation

    /// Deterministic pseudo-random bytes (no real randomness, so every run makes the same file).
    private struct LCG {
        var state: UInt64
        mutating func next() -> UInt8 { state = state &* 6364136223846793005 &+ 1442695040888963407; return UInt8(truncatingIfNeeded: state >> 33) }
    }

    private static let words = ["invoice", "contract", "meeting", "quarter", "review", "attached", "please", "regards", "project", "alpha",
                                "deadline", "budget", "approved", "draft", "signature", "client", "schedule", "update", "summary", "thanks"]

    /// Writes an mbox of about `targetBytes`: ~2 KB of text and one ~45 KB base64 attachment per message.
    static func generateMBOX(at url: URL, targetBytes: Int64) throws -> (url: URL, messages: Int) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var rng = LCG(state: 0x5EED)
        var written: Int64 = 0
        var index = 0
        let attachmentBytes = 45_000
        var raw = [UInt8](repeating: 0, count: attachmentBytes)
        while written < targetBytes {
            index += 1
            for i in 0..<attachmentBytes { raw[i] = rng.next() }
            let base64 = Data(raw).base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
            var text = ""
            var w = index
            for _ in 0..<300 { text += words[w % words.count] + " "; w = (w &* 31 &+ 7) % 1_000_003; if text.utf8.count % 70 < 8 { text += "\n" } }
            let day = 1 + (index % 28), month = 1 + (index / 28) % 12, year = 2019 + (index / 336) % 6
            let date = String(format: "%02d", day) + " " + ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"][month - 1] + " \(year) 09:\(String(format: "%02d", index % 60)):00 +0000"
            let message = """
            From sender\(index % 97)@matrix.test Mon Jan  1 00:00:00 \(year)
            From: Sender \(index % 97) <sender\(index % 97)@matrix.test>
            To: me@matrix.test
            Cc: cc\(index % 11)@matrix.test
            Subject: Synthetic message \(index) about \(words[index % words.count])
            Date: Mon, \(date)
            Message-ID: <synthetic-\(index)@matrix.test>
            MIME-Version: 1.0
            Content-Type: multipart/mixed; boundary="matrix-\(index)"

            --matrix-\(index)
            Content-Type: text/plain; charset=utf-8

            \(text)

            --matrix-\(index)
            Content-Type: application/pdf; name="doc-\(index).pdf"
            Content-Disposition: attachment; filename="doc-\(index).pdf"
            Content-Transfer-Encoding: base64

            \(base64)
            --matrix-\(index)--


            """
            let data = Data(message.utf8)
            handle.write(data)
            written += Int64(data.count)
        }
        return (url, index)
    }

    // MARK: Production-path import, measured

    private func importMeasured(urls: [URL], sourceBytes: Int64, expectedMessages: Int, label: String) async throws -> Run {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("matrix-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try MailinStorageEnvironment.assertNotProduction(root)
        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts", isDirectory: true))
        let checkpoints = ImportCheckpointStore(store: store)
        let coordinator = await BulkImportCoordinator(store: store, fts: fts, checkpoints: checkpoints, requiresStorageActivation: false)
        var options = BulkImportCoordinator.Options()
        options.enforceStoragePreflight = false
        let clock = ContinuousClock()
        let baseline = currentFootprintBytes()
        let start = clock.now
        let sampler = Sampler(root: root, baseline: baseline, start: start)
        var callbacks = BulkImportCoordinator.Callbacks()
        callbacks.onCommittedBatch = { batch in sampler.record(count: batch.count) }
        let summary = try await coordinator.runImport(urls: urls, options: options, callbacks: callbacks)
        let elapsed = start.duration(to: clock.now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        try? await store.checkpoint()
        let stored = try await store.totalCount()
        let ftsRows = try await fts.rowCount()
        let storeBytes = Self.directoryBytes(root.appendingPathComponent("store", isDirectory: true))
        let ftsBytes = Self.directoryBytes(root.appendingPathComponent("fts", isDirectory: true))
        let finalRoot = Self.directoryBytes(root)
        return Run(label: label, sourceBytes: sourceBytes, expectedMessages: expectedMessages,
                   firstMessageSeconds: sampler.firstMessageSeconds ?? seconds, seconds: seconds,
                   baselineBytes: baseline, peakBytes: sampler.peakFootprint, storeBytes: storeBytes, ftsBytes: ftsBytes,
                   peakTransientBytes: max(0, sampler.peakRootBytes - finalRoot), stored: stored, ftsRows: ftsRows,
                   summary: summary, root: root, store: store, fts: fts)
    }

    private func row(_ run: Run) -> String {
        let mb = { (b: Int64) in String(format: "%.1f", Double(b) / 1_000_000) }
        return "| \(run.label) | \(mb(run.sourceBytes)) MB | \(run.stored) | \(String(format: "%.2f", run.firstMessageSeconds)) s | \(String(format: "%.1f", run.seconds)) s | \(String(format: "%.0f", run.peakDeltaMB)) MB | \(mb(run.storeBytes)) / \(mb(run.ftsBytes)) MB | \(mb(run.peakTransientBytes)) MB | discovered \(run.summary.discovered), parsed \(run.summary.parsed), damaged \(run.summary.damaged), persist failed \(run.summary.persistFailed), FTS rows \(run.ftsRows) |"
    }

    func testFormatMatrix_100MB_mbox_pst_emlFolder_msgFiles_memoryFlatAgainst25MB() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["MAILIN_SKIP_MATRIX"] == "1", "MAILIN_SKIP_MATRIX=1")
        try TestPreconditions.requireFreeSpace(2_500_000_000)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("matrix-fixtures-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var runs: [Run] = []
        defer {
            try? FileManager.default.removeItem(at: root)
            for run in runs { try? FileManager.default.removeItem(at: run.root) }
        }

        // 1. mbox, ~100 MB.
        let mbox = try Self.generateMBOX(at: root.appendingPathComponent("synthetic-100mb.mbox"), targetBytes: 100_000_000)
        let mboxBytes = Int64((try FileManager.default.attributesOfItem(atPath: mbox.url.path)[.size] as? NSNumber)?.intValue ?? 0)
        XCTAssertGreaterThan(mboxBytes, 100_000_000)
        let mboxRun = try await importMeasured(urls: [mbox.url], sourceBytes: mboxBytes, expectedMessages: mbox.messages, label: "mbox 100 MB")
        runs.append(mboxRun)

        // 2. The same archive as PST, an .eml folder and .msg files — mailin's own writers.
        let archive = ArchiveDataService(repository: EmailStoreRepository(store: mboxRun.store, fts: mboxRun.fts))
        let service = await ArchiveExportService(archive: archive)
        let scope = ArchiveSelectionScope.query(.all, exclusions: [])
        let pst = root.appendingPathComponent("synthetic.pst")
        let pstWritten = try await service.exportPST(scope: scope, to: pst)
        XCTAssertEqual(pstWritten, mbox.messages)
        let emlFolder = root.appendingPathComponent("eml", isDirectory: true)
        let emlResult = try await service.exportEMLFiles(scope: scope, to: emlFolder)
        XCTAssertEqual(emlResult.recordsWritten, mbox.messages)
        let msgFolder = root.appendingPathComponent("msg", isDirectory: true)
        let msgResult = try await service.exportMSGFiles(scope: scope, to: msgFolder)
        XCTAssertEqual(msgResult.recordsWritten, mbox.messages)
        // Export inventories do not belong to the source folders being imported.
        try? FileManager.default.removeItem(at: emlFolder.appendingPathComponent(ExportInventory.filename))
        try? FileManager.default.removeItem(at: msgFolder.appendingPathComponent(ExportInventory.filename))

        let pstBytes = Int64((try FileManager.default.attributesOfItem(atPath: pst.path)[.size] as? NSNumber)?.intValue ?? 0)
        runs.append(try await importMeasured(urls: [pst], sourceBytes: pstBytes, expectedMessages: mbox.messages, label: "pst (mailin writer)"))
        runs.append(try await importMeasured(urls: [emlFolder], sourceBytes: Self.directoryBytes(emlFolder), expectedMessages: mbox.messages, label: "eml folder"))
        let msgFiles = try FileManager.default.contentsOfDirectory(at: msgFolder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "msg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertEqual(msgFiles.count, mbox.messages)
        runs.append(try await importMeasured(urls: msgFiles, sourceBytes: Self.directoryBytes(msgFolder), expectedMessages: mbox.messages, label: "msg files"))

        // 3. The size comparison.
        let small = try Self.generateMBOX(at: root.appendingPathComponent("synthetic-25mb.mbox"), targetBytes: 25_000_000)
        let smallBytes = Int64((try FileManager.default.attributesOfItem(atPath: small.url.path)[.size] as? NSNumber)?.intValue ?? 0)
        let smallRun = try await importMeasured(urls: [small.url], sourceBytes: smallBytes, expectedMessages: small.messages, label: "mbox 25 MB")
        runs.append(smallRun)

        print("""

        ## Executed \(Date().formatted(.iso8601.year().month().day())) — the format matrix at 100 MB (OPEN-06, synthetic fixtures, Debug test host)

        | Source | Size | Messages stored | First message | Total | Peak footprint over baseline | Store / FTS on disk | Peak transient disk | Reconciliation |
        |---|---|---|---|---|---|---|---|---|
        \(runs.map(row).joined(separator: "\n"))

        """)

        for run in runs {
            XCTAssertEqual(run.stored, run.expectedMessages, "\(run.label): every message stored")
            XCTAssertEqual(run.ftsRows, run.stored, "\(run.label): search coverage equals stored rows")
            XCTAssertEqual(run.summary.damaged, 0, "\(run.label): nothing damaged")
            XCTAssertEqual(run.summary.persistFailed, 0, "\(run.label)")
            XCTAssertLessThan(run.peakDeltaMB, 600, "\(run.label): the footprint never approaches the source size")
        }
        // Memory does not grow with file size: four times the bytes, the same order of peak.
        XCTAssertLessThan(mboxRun.peakDeltaMB, smallRun.peakDeltaMB + 150,
                          "100 MB peak \(mboxRun.peakDeltaMB) MB vs 25 MB peak \(smallRun.peakDeltaMB) MB")
    }
}
