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
