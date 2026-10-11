@testable import ArchiveCore
//
//  V3ScaleTests.swift
//  maxmailinTests
//
//  §3-F7 test tiers. A synthetic archive is generated batch by batch (never
//  held in memory) with facts planted at fixed rates, so every tool's answer
//  is known exactly ("result == SQL count"), and the process footprint is
//  sampled while it runs ("memory flat").
//
//   MAILIN_SCALE_TIER unset or "100k" — 100,000 emails, every run
//   MAILIN_SCALE_TIER=1m              — 1,000,000 emails, before release
//   MAILIN_SCALE_TIER=10m             — 10,000,000 headers-only rows: store,
//                                       counts and paging only
//   MAILIN_SCALE_TIER=off             — skip (e.g. a quick local loop)
//
//  Results are printed as "SCALE …" lines for SCALE_RESULTS.md.
//

import Foundation
import XCTest
@testable import maxmailin

@MainActor
final class V3ScaleTests: XCTestCase {

    /// Footprint growth allowed while a whole-archive tool runs — sized for
    /// the smallest supported iPhone (4 GB RAM; the foreground limit there
    /// is about 2 GB, and the app itself needs headroom).
    static let footprintCeilingBytes: UInt64 = 700 * 1_048_576

    private enum Tier: String {
        case k100 = "100k", m1 = "1m", m10 = "10m", off
        var count: Int { switch self { case .k100: 100_000; case .m1: 1_000_000; case .m10: 10_000_000; case .off: 0 } }
    }

    private var tier: Tier {
        Tier(rawValue: (ProcessInfo.processInfo.environment["MAILIN_SCALE_TIER"] ?? "100k").lowercased()) ?? .k100
    }

    // MARK: Planted rates (expected answers are arithmetic)

    private static let senders = ["ann@one.example", "ben@two.example", "cat@three.example"]
    private static func sender(_ i: Int) -> String { senders[i % 3] }
    private static func hasKeyword(_ i: Int) -> Bool { i % 7 == 3 }
    private static func hasSSN(_ i: Int) -> Bool { i % 11 == 5 }
    private static func hasSPF(_ i: Int) -> Bool { i % 2 == 0 }

    private static func expected(_ n: Int, _ predicate: (Int) -> Bool) -> Int { (0..<n).reduce(0) { $0 + (predicate($1) ? 1 : 0) } }

    private static let rfc: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f
    }()
    private static let iso = ISO8601DateFormatter()

    private static func email(_ i: Int, headersOnly: Bool) -> MBOXParser.RawEmail {
        let date = Date(timeIntervalSince1970: 1_577_836_800 + Double(i) * 600)   // 2020-01-01, every 10 minutes
        var body = headersOnly ? "" : "plain text for the synthetic archive message."
        if !headersOnly, hasKeyword(i) { body += " The confidential plan." }
        if !headersOnly, hasSSN(i) { body += " Ref 078-05-1120." }
        var headers = ["Message-ID": "<scale-\(i)@test>", "Subject": "Synthetic", "From": sender(i),
                       "To": "desk@four.example", "Date": rfc.string(from: date)]
        if hasSPF(i) { headers["Authentication-Results"] = "mx; spf=pass" }
        return MBOXParser.RawEmail(headers: headers, rawSource: headersOnly ? "" : "Message-ID: <scale-\(i)@test>\n\n" + body,
                                   messageType: "email", attachments: [], timestamp: iso.string(from: date),
                                   domains: [String(sender(i).split(separator: "@").last ?? "")],
                                   plainBody: body, htmlBody: "")
    }

    // MARK: Harness

    private struct Env {
        let root: URL
        let store: SQLiteEmailStore
        let archive: ArchiveDataService
        var job: ScopeJobEnvironment { ScopeJobEnvironment(archive: archive, store: store, root: root) }
    }

    /// Footprint growth over the baseline; 0 when memory fell below it (the
    /// unsigned `&-` wrapped to ~18 EB and failed the 1M run, 2026-10-11).
    static func growth(_ now: UInt64, over base: UInt64) -> UInt64 { now > base ? now - base : 0 }

    private func build(_ n: Int, headersOnly: Bool) async throws -> (Env, peakInsert: UInt64) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scale-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts", isDirectory: true))
        let base = currentFootprintBytes()
        var peak: UInt64 = 0
        let batch = 5_000
        for start in stride(from: 0, to: n, by: batch) {
            let emails = (start..<min(start + batch, n)).map { Self.email($0, headersOnly: headersOnly) }
            try await store.insertBatch(emails, batchSize: batch)
            peak = max(peak, Self.growth(currentFootprintBytes(), over: base))
        }
        return (Env(root: root, store: store, archive: ArchiveDataService(repository: EmailStoreRepository(store: store, fts: fts))), peak)
    }

    /// Runs `body`, sampling the footprint every 250 ms; returns growth peak.
    private func measured<T>(_ label: String, _ body: () async throws -> T) async rethrows -> (T, UInt64) {
        let base = currentFootprintBytes()
        let sampler = Task.detached(priority: .high) { () -> UInt64 in
            var peak: UInt64 = 0
            while !Task.isCancelled {
                peak = max(peak, Self.growth(currentFootprintBytes(), over: base))
                try? await Task.sleep(for: .milliseconds(250))
            }
            return peak
        }
        let started = Date()
        let value = try await body()
        sampler.cancel()
        let peak = await sampler.value
        print(String(format: "SCALE tier=%@ tool=%@ seconds=%.1f peakGrowthMB=%.0f", tier.rawValue, label,
                     Date().timeIntervalSince(started), Double(peak) / 1_048_576))
        XCTAssertLessThan(peak, Self.footprintCeilingBytes, "\(label): memory stays flat at \(tier.rawValue)")
        return (value, peak)
    }

    // MARK: Tiers

    func testScaleTier_everyToolAnswersExactly_memoryFlat() async throws {
        try XCTSkipIf(tier == .off || tier == .m10, "tier \(tier.rawValue) runs its own test")
        let n = tier.count
        let (env, insertPeak) = try await build(n, headersOnly: false)
        print(String(format: "SCALE tier=%@ tool=insert peakGrowthMB=%.0f", tier.rawValue, Double(insertPeak) / 1_048_576))

        try await ScopeJobEnvironment.$current.withValue(env.job) {
            let (count, _) = try await measured("count") { try await env.archive.count(query: .all) }
            XCTAssertEqual(count, n)

            var q = EmailQuery(); q.sender = "ann@"
            let (ann, _) = try await measured("sender filter") { try await env.archive.count(query: q) }
            XCTAssertEqual(ann, Self.expected(n) { $0 % 3 == 0 })

            let (keywords, _) = try await measured("keyword sweep") {
                try await KeywordMonitorEngine.scan(scope: .wholeArchive, keywords: [.init(keyword: "confidential")])
            }
            XCTAssertEqual(Set(keywords.matches.map(\.email.id)).count, Self.expected(n, Self.hasKeyword))
            XCTAssertEqual(keywords.receipt.processed, n, "every email read, no hidden cap")

            let (pii, _) = try await measured("PII report") { try await PIIEngine.scan(scope: .wholeArchive) }
            XCTAssertEqual(pii.counts[.ssnPattern], Self.expected(n, Self.hasSSN))

            let (it, _) = try await measured("IT stats") { try await ITAdminStatsEngine.compute() }
            XCTAssertEqual(it.stats.total, n)
            XCTAssertEqual(it.stats.spfPass, Self.expected(n, Self.hasSPF))

            let (bates, _) = try await measured("Bates numbering") {
                try await BatesEngine.number(query: .all, prefix: "S", start: 1) { "S\($0)" }
            }
            XCTAssertEqual(bates.state.assigned, n)
            XCTAssertEqual(bates.state.last, "S\(n)")

            let (leaves, _) = try await measured("fingerprint tree") { () -> Int in
                while try await env.store.fingerprintBuildMissing(limit: 5_000) > 0 {}
                try await env.store.fingerprintRefreshBuckets()
                return try await env.store.fingerprintTree().leaves
            }
            XCTAssertEqual(leaves, n)
        }
    }

    /// 10M headers-only rows: the store, counts and keyset paging stay fast
    /// and flat (bodies are not part of this tier).
    func testScaleTier10M_storeCountsAndPaging() async throws {
        try XCTSkipUnless(tier == .m10, "opt-in: MAILIN_SCALE_TIER=10m (about 10 GB of disk and an hour)")
        let n = tier.count
        let (env, insertPeak) = try await build(n, headersOnly: true)
        print(String(format: "SCALE tier=10m tool=insert peakGrowthMB=%.0f", Double(insertPeak) / 1_048_576))
        let (count, _) = try await measured("count") { try await env.archive.count(query: .all) }
        XCTAssertEqual(count, n)
        // Deep keyset paging: walk 50 pages from the newest and 50 from the
        // oldest; each page is the requested size and pages never overlap.
        let (pages, _) = try await measured("paging") { () -> Int in
            var seen = Set<UUID>()
            for sort in [EmailSortOrder.dateDesc, .dateAsc] {
                var q = EmailQuery(); q.sort = sort
                var cursor: EmailPageCursor? = nil
                for _ in 0..<50 {
                    let page = try await env.archive.page(query: q, cursor: cursor, limit: 200)
                    XCTAssertEqual(page.summaries.count, 200)
                    for s in page.summaries { XCTAssertTrue(seen.insert(s.id).inserted, "no overlap") }
                    cursor = page.nextCursor
                }
            }
            return seen.count
        }
        XCTAssertEqual(pages, 20_000)
    }
}
