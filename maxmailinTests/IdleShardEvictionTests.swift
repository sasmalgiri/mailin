//
//  IdleShardEvictionTests.swift
//  maxmailinTests
//
//  Plan task A9. Before this, FTS shard handles were closed only under OS
//  memory pressure, so an idle app kept every shard it had touched open — 20
//  handles and their page caches on a 20-year archive, measured as the bulk of
//  a 526 MiB idle RSS (RELEASE_READINESS.md §P0.2).
//
//  The rule being pinned: eviction must drop handles AND lose nothing. A shard
//  re-opens lazily on next access with identical contents.
//

import XCTest
@testable import maxmailin

final class IdleShardEvictionTests: XCTestCase {

    /// Emails spread across `years` so each one lands in its own year shard
    /// (the shard is chosen from the `Date` header — FTSSearchIndex.year(for:)).
    private func emails(years: [Int]) -> [MBOXParser.RawEmail] {
        years.enumerated().map { index, year in
            MBOXParser.RawEmail(
                headers: [
                    "From": "sender@example.com",
                    "To": "recipient@example.com",
                    "Subject": "Shard probe \(year)",
                    "Date": "Tue, 14 Mar \(year) 09:41:00 +0000",
                    "Message-ID": "<probe-\(year)-\(index)@example.com>"
                ],
                rawSource: "",
                messageType: "email",
                attachments: [],
                timestamp: "Tue, 14 Mar \(year) 09:41:00 +0000",
                domains: ["example.com"],
                plainBody: "uniquetoken\(year) body text for the shard probe",
                htmlBody: ""
            )
        }
    }

    func testIdleSweep_closesHandles_andDataSurvivesReopen() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shard-evict-\(UUID().uuidString)", isDirectory: true)
        let env = try MailinStorageEnvironment.disposable(at: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let years = Array(2010...2019)
        let corpus = emails(years: years)
        try await env.fts.indexBatch(corpus)

        let openAfterIndex = await env.fts.openShardCount
        XCTAssertEqual(openAfterIndex, years.count,
                       "each year should have opened its own shard handle")
        let rowsBefore = try await env.fts.rowCount()
        XCTAssertEqual(rowsBefore, corpus.count)

        // Sweep with a zero TTL: everything is "idle" by definition, which is
        // the deterministic stand-in for three minutes of inactivity.
        let closed = await env.fts.sweepIdleShards(ttl: .zero)
        XCTAssertEqual(closed, years.count)
        let openAfterSweep = await env.fts.openShardCount
        XCTAssertEqual(openAfterSweep, 0, "an idle app should hold no shard handles")

        // Nothing was lost: the index re-opens lazily and reads the same rows.
        let rowsAfter = try await env.fts.rowCount()
        XCTAssertEqual(rowsAfter, rowsBefore, "eviction must not lose indexed rows")
        let hits = try await env.fts.searchRaw("uniquetoken2015", limit: 10)
        XCTAssertEqual(hits.count, 1, "a swept shard must still answer queries")
    }

    /// Drives the real scheduler rather than calling the sweep by hand: with a
    /// short TTL, simply waiting must close the handles. Without this, the
    /// mechanism could work while nothing ever triggered it in the app.
    func testScheduledSweep_firesWithoutBeingCalled() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shard-evict-sched-\(UUID().uuidString)", isDirectory: true)
        let fts = FTSSearchIndex(
            shardsDirectory: root.appendingPathComponent("fts", isDirectory: true),
            idleShardTTL: .milliseconds(200)
        )
        defer { try? FileManager.default.removeItem(at: root) }

        try await fts.indexBatch(emails(years: [2014, 2015]))
        let openNow = await fts.openShardCount
        XCTAssertEqual(openNow, 2)

        // One TTL to become stale, one more for the sweep tick to land.
        try await Task.sleep(for: .milliseconds(900))

        let openLater = await fts.openShardCount
        XCTAssertEqual(openLater, 0, "the scheduled sweep should have closed idle handles on its own")
        let rows = try await fts.rowCount()
        XCTAssertEqual(rows, 2, "scheduled eviction must not lose rows")
    }

    func testIdleSweep_keepsShardsTouchedRecently() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shard-evict-keep-\(UUID().uuidString)", isDirectory: true)
        let env = try MailinStorageEnvironment.disposable(at: root)
        defer { try? FileManager.default.removeItem(at: root) }

        try await env.fts.indexBatch(emails(years: [2011, 2012, 2013]))
        let openBefore = await env.fts.openShardCount
        XCTAssertEqual(openBefore, 3)

        // A generous TTL means nothing is stale yet, so a sweep is a no-op —
        // the sweep must not close handles the user is actively using.
        let closed = await env.fts.sweepIdleShards(ttl: .seconds(3600))
        XCTAssertEqual(closed, 0)
        let openAfter = await env.fts.openShardCount
        XCTAssertEqual(openAfter, 3)
    }

    func testReopenAfterSweep_isWritableAgain() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shard-evict-write-\(UUID().uuidString)", isDirectory: true)
        let env = try MailinStorageEnvironment.disposable(at: root)
        defer { try? FileManager.default.removeItem(at: root) }

        try await env.fts.indexBatch(emails(years: [2020]))
        _ = await env.fts.sweepIdleShards(ttl: .zero)
        let openAfterEvict = await env.fts.openShardCount
        XCTAssertEqual(openAfterEvict, 0)

        // Indexing into a previously-evicted year must work, not throw on a
        // closed handle.
        try await env.fts.indexBatch(emails(years: [2020, 2021]))
        let rows = try await env.fts.rowCount()
        XCTAssertEqual(rows, 3)
        let reopened = await env.fts.openShardCount
        XCTAssertGreaterThan(reopened, 0)
    }
}
