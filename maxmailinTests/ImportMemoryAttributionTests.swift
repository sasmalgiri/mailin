//
//  ImportMemoryAttributionTests.swift
//  maxmailinTests
//
//  Plan task P3.3, attribution step. Two hypotheses for the ~420 MiB import
//  peak have now been measured and falsified: batch size (2 → 4 batches changed
//  nothing) and the SQLite cache/mmap budget plus shard cap (no change either).
//
//  Rather than guess a third time, this measures each stage of the pipeline
//  separately over the same real corpus and prints the footprint delta for
//  each: parse only, parse + store, parse + store + index. Whatever is
//  responsible has to show up as the stage whose delta dominates.
//
//  Deltas are measured per stage (peak during the stage minus footprint at its
//  start) because process RSS does not fall back when memory is freed.
//

import XCTest
@testable import maxmailin

final class ImportMemoryAttributionTests: XCTestCase {

    private static var fixtureURL: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/Mail/Sent.mbox")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func mib(_ bytes: UInt64) -> Double { Double(bytes) / 1_048_576.0 }

    /// Same batch shape for every stage, so the only variable is how much of
    /// the pipeline runs.
    private let envelope = BatchEnvelope(maxMessages: 168, maxBytes: 16 * 1_048_576)

    func testAttributeImportPeakByStage() async throws {
        guard let fixture = Self.fixtureURL else {
            throw XCTSkip("fixture ~/Downloads/Mail/Sent.mbox not present")
        }

        // ---- Stage 1: parse only -----------------------------------------
        var start = currentFootprintBytes()
        var peak = start
        var parsed = 0
        _ = try await MBOXParser.parseStreamingCallback(
            fileURL: fixture, senderEmail: "", batchSize: 500,
            envelopeProvider: { [envelope] in envelope }
        ) { batch in
            parsed += batch.count
            peak = max(peak, currentFootprintBytes())
        }
        let parseDelta = mib(peak) - mib(start)
        print("ATTRIBUTION parse-only messages=\(parsed) deltaMiB=\(String(format: "%.1f", parseDelta))")

        // ---- Stage 2: parse + store --------------------------------------
        let storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("attrib-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storeRoot) }
        let store = SQLiteEmailStore(directory: storeRoot)

        start = currentFootprintBytes()
        peak = start
        _ = try await MBOXParser.parseStreamingCallback(
            fileURL: fixture, senderEmail: "", batchSize: 500,
            envelopeProvider: { [envelope] in envelope }
        ) { batch in
            try await store.insertBatch(batch, batchSize: 168)
            peak = max(peak, currentFootprintBytes())
        }
        let storeDelta = mib(peak) - mib(start)
        print("ATTRIBUTION parse+store deltaMiB=\(String(format: "%.1f", storeDelta))")

        // ---- Stage 3: parse + store + index ------------------------------
        let fullRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("attrib-full-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fullRoot) }
        let store2 = SQLiteEmailStore(directory: fullRoot.appendingPathComponent("store"))
        let fts = FTSSearchIndex(shardsDirectory: fullRoot.appendingPathComponent("fts"))

        start = currentFootprintBytes()
        peak = start
        _ = try await MBOXParser.parseStreamingCallback(
            fileURL: fixture, senderEmail: "", batchSize: 500,
            envelopeProvider: { [envelope] in envelope }
        ) { batch in
            try await store2.insertBatch(batch, batchSize: 168)
            try await fts.indexBatch(batch)
            peak = max(peak, currentFootprintBytes())
        }
        let fullDelta = mib(peak) - mib(start)
        let shards = await fts.shardBudget
        print("""
        ATTRIBUTION parse+store+index deltaMiB=\(String(format: "%.1f", fullDelta)) \
        openShards=\(shards.open) cap=\(shards.cap)
        """)

        print("""
        ATTRIBUTION SUMMARY \
        parseOnly=\(String(format: "%.1f", parseDelta)) \
        plusStore=\(String(format: "%.1f", storeDelta)) \
        plusIndex=\(String(format: "%.1f", fullDelta))
        """)

        // No assertion on the numbers themselves — this test exists to attribute
        // cost, and the thresholds are not yet established. It does assert the
        // corpus was actually processed, so a silent no-op cannot masquerade as
        // a cheap pipeline.
        XCTAssertEqual(parsed, 526)
    }
}
