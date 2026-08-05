//
//  StressHarness.swift
//  maxmailin
//
//  Stage 4 (v2-core-cutover): `mailin-v2-stress` — measures the REAL bounded
//  engine (EmailStore + FTS5 + EmailStoreRepository + FTSReconciler) at scale
//  over a `MailinStorageEnvironment.disposable`, so the SwiftData-vs-direct
//  storage decision rests on evidence, not guessing.
//
//  Hard rules baked in:
//    • Never touches production data — the environment is disposable(at:),
//      which refuses any root overlapping the production storage tree.
//    • No benchmark-only fake persistence — every phase drives the same code
//      the shipping import/search/paging paths use.
//    • Deterministic — a fixed seed produces the same corpus and the same
//      known expected result IDs every run.
//
//  The decisive metric is NOT messages/sec. It is: does resident memory stay
//  clearly sublinear as the archive grows, while reopen / paging / search /
//  reconcile stay usable?
//

import Foundation
import Darwin

// MARK: - Deterministic RNG

/// SplitMix64 — a tiny, fully deterministic generator so the synthetic corpus
/// (and its known expected IDs) is byte-for-byte reproducible from a seed.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func deterministicUUID(_ a: UInt64, _ b: UInt64) -> UUID {
    UUID(uuid: (
        UInt8(truncatingIfNeeded: a >> 56), UInt8(truncatingIfNeeded: a >> 48),
        UInt8(truncatingIfNeeded: a >> 40), UInt8(truncatingIfNeeded: a >> 32),
        UInt8(truncatingIfNeeded: a >> 24), UInt8(truncatingIfNeeded: a >> 16),
        UInt8(truncatingIfNeeded: a >> 8),  UInt8(truncatingIfNeeded: a),
        UInt8(truncatingIfNeeded: b >> 56), UInt8(truncatingIfNeeded: b >> 48),
        UInt8(truncatingIfNeeded: b >> 40), UInt8(truncatingIfNeeded: b >> 32),
        UInt8(truncatingIfNeeded: b >> 24), UInt8(truncatingIfNeeded: b >> 16),
        UInt8(truncatingIfNeeded: b >> 8),  UInt8(truncatingIfNeeded: b)
    ))
}

// MARK: - Memory + timing

/// Current physical memory footprint (bytes) — the same accounting Xcode's
/// memory gauge and the OS Jetsam limit use (`phys_footprint`).
func currentFootprintBytes() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
    )
    let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
}

private func ms(_ d: Duration) -> Double {
    let c = d.components
    return Double(c.seconds) * 1_000 + Double(c.attoseconds) / 1_000_000_000_000_000
}

private func percentile(_ sorted: [Double], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let idx = min(sorted.count - 1, Int((p / 100.0) * Double(sorted.count - 1) + 0.5))
    return sorted[idx]
}

// MARK: - Config + result

struct StressConfig: Sendable {
    var scale: Int
    var seed: UInt64 = 0x0000_4A1_1_5EED_600D
    var bodyBytes: Int = 600
    var years: Int = 10
    var startYear: Int = 2015
    var sameTimestampBlock: Int = 64
    var duplicatePermille: Int = 10          // 1% duplicate copies (dedup test)
    var insertSampleChunk: Int = 5_000       // outer slice for RSS sampling
    var innerBatchSize: Int = 1_000          // EmailStore commit batch
    var indexSampleChunk: Int = 5_000
    var pageSize: Int = 500
    var reconcilePageSize: Int = 5_000
    var searchTrials: Int = 40
    var runDestructiveChecks: Bool = true    // delete + FTS-clear-then-reconcile
    var configurationLabel: String = "Debug"

    init(scale: Int) { self.scale = scale }
}

struct StressResult: Codable, Sendable {
    var scale: Int
    var seed: String
    var configuration: String
    var bodyBytes: Int

    // Counts / integrity
    var generatedTotal: Int
    var distinctExpected: Int
    var duplicateCopies: Int
    var storeCountAfterImport: Int
    var ftsCountCommonTerm: Int
    var ftsRowCount: Int

    // Throughput
    var importSeconds: Double
    var importMsgPerSec: Double
    var indexSeconds: Double
    var indexMsgPerSec: Double

    // Memory (MB, phys_footprint)
    var rssBaselineMB: Double
    var rssPeakImportMB: Double
    var rssPostImportMB: Double
    var rssPeakIndexMB: Double
    var rssSearchMB: Double
    var rssReconcileMB: Double

    // Disk (bytes)
    var storeDirBytes: Int
    var externalStorageBytes: Int
    var ftsDirBytes: Int
    var walShmBytes: Int
    var totalDiskBytes: Int

    // Latency (ms)
    var firstPageMs: Double
    var deepPageMs: Double
    var searchP50Ms: Double
    var searchP95Ms: Double
    var nearP50Ms: Double
    var nearP95Ms: Double
    var countMs: Double
    var coldReopenMs: Double
    var warmReopenMs: Double

    // Reconcile verification pass
    var reconcileVerifySeconds: Double
    var reconcileRowsReindexed: Int

    // Correctness
    var pagingVisitedCount: Int
    var pagingNoSkips: Bool
    var pagingNoDuplicates: Bool
    var rareTermExactMatch: Bool
    var booleanAndExactMatch: Bool
    var nearProximityExactMatch: Bool
    var deleteConsistent: Bool
    var reconcileRebuiltAll: Bool
    var reopenPersisted: Bool

    var passed: Bool
    var notes: [String]
}

// MARK: - Corpus

/// A plan holds only metadata + the known expected-ID sets — NOT the emails.
/// Emails are regenerated deterministically per chunk during import/index so
/// the harness never holds the whole corpus in memory; the measured RSS then
/// reflects the store, not a giant test buffer. (Critical for a truthful 1M
/// memory number: a materialized 1M-email array would be ~2 GB on its own.)
private struct StressCorpusPlan {
    let config: StressConfig
    let distinctCount: Int
    let duplicateCount: Int
    let generatedTotal: Int
    let rareIndices: Set<Int>
    let nearAdjIndices: Set<Int>
    let nearFarIndices: Set<Int>
    let dupSourceIndices: [Int]
    let rareIDs: Set<UUID>
    let booleanAndIDs: Set<UUID>
    let nearIDs: Set<UUID>

    let commonToken = "commontoken"
    let rareToken = "zebraxyzq"
    let alphaToken = "alphatok"
    let betaToken = "betatok"
    let nearA = "quickmarker"
    let nearB = "jumpmarker"
    let nearProximity = 3

    /// The id of distinct email `i` — first two draws of its per-index RNG.
    /// `email(at:)` uses the same RNG and continues from the same point, so the
    /// ids computed here (for expected sets) match the ids that get stored.
    static func idForIndex(_ i: Int, seed: UInt64) -> UUID {
        var rng = SplitMix64(seed: seed ^ (UInt64(i) &* 0x9E37_79B9_7F4A_7C15))
        return deterministicUUID(rng.next(), rng.next())
    }

    /// Deterministically (re)build distinct email `i`.
    func email(at i: Int) -> MBOXParser.RawEmail {
        var rng = SplitMix64(seed: config.seed ^ (UInt64(i) &* 0x9E37_79B9_7F4A_7C15))
        let id = deterministicUUID(rng.next(), rng.next())
        let mid = "<msg-\(i)@stress.mailin>"

        let year: Int, month: Int, day: Int, hour: Int, minute: Int
        if i < config.sameTimestampBlock {
            year = config.startYear; month = 1; day = 1; hour = 0; minute = 0
        } else {
            year = config.startYear + (i % config.years)
            month = 1 + ((i / config.years) % 12)
            day = 1 + (i % 28)
            hour = i % 24
            minute = i % 60
        }
        let dateHeader = stressDateHeader(year: year, month: month, day: day, hour: hour, minute: minute)

        let vocabCount = stressVocab.count
        var words: [String] = [commonToken]
        if i % 50 == 0 { words.append(alphaToken) }
        if i % 80 == 0 { words.append(betaToken) }
        if rareIndices.contains(i) { words.append(rareToken) }
        if nearAdjIndices.contains(i) {
            words.append(contentsOf: [nearA, nearB])
        } else if nearFarIndices.contains(i) {
            words.append(nearA)
            for _ in 0..<30 { words.append(stressVocab[Int(rng.next() % UInt64(vocabCount))]) }
            words.append(nearB)
        }
        var bytes = words.joined(separator: " ").utf8.count
        while bytes < config.bodyBytes {
            let w = stressVocab[Int(rng.next() % UInt64(vocabCount))]
            words.append(w); bytes += w.utf8.count + 1
        }
        let body = words.joined(separator: " ")

        return MBOXParser.RawEmail(
            id: id,
            headers: [
                "Message-ID": mid,
                "Subject": "Message \(i) \(commonToken)",
                "From": "sender\(i % 500)@example.com",
                "To": "recipient\(i % 300)@example.org",
                "Date": dateHeader,
            ],
            rawSource: "From sender@example.com\nSubject: Message \(i)\n\n\(body)",
            messageType: "email",
            attachments: [],
            timestamp: "\(year)-01-01T00:00:00Z",
            domains: ["example.com"],
            plainBody: body,
            htmlBody: ""
        )
    }

    /// Deterministically (re)build duplicate copy `k` — same Message-ID as an
    /// earlier email (new id), so the store's dedup must drop it.
    func duplicate(at k: Int) -> MBOXParser.RawEmail {
        let srcIndex = dupSourceIndices[k]
        let mid = "<msg-\(srcIndex)@stress.mailin>"
        var rng = SplitMix64(seed: config.seed ^ 0xDEAD_BEEF ^ UInt64(k))
        let dupID = deterministicUUID(rng.next(), rng.next())
        return MBOXParser.RawEmail(
            id: dupID,
            headers: [
                "Message-ID": mid,
                "Subject": "Duplicate of \(srcIndex) \(commonToken)",
                "From": "dup@example.com",
                "To": "dup@example.org",
                "Date": stressDateHeader(year: config.startYear, month: 6, day: 15, hour: 12, minute: 0),
            ],
            rawSource: "From dup@example.com\n\n\(commonToken) duplicate body",
            messageType: "email",
            attachments: [],
            timestamp: "\(config.startYear)-06-15T12:00:00Z",
            domains: ["example.com"],
            plainBody: "\(commonToken) duplicate body filler filler filler",
            htmlBody: ""
        )
    }
}

private let stressVocab: [String] = [
    "invoice", "meeting", "project", "budget", "review", "contract", "shipment",
    "report", "schedule", "proposal", "customer", "vendor", "payment", "receipt",
    "quarter", "revenue", "expense", "policy", "compliance", "audit", "server",
    "network", "database", "release", "deadline", "attachment", "forward", "reply",
    "urgent", "confidential", "draft", "final", "summary", "agenda", "minutes",
    "logistics", "inventory", "forecast", "pipeline", "renewal",
]

private let stressMonths = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                            "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

private func stressDateHeader(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> String {
    // Weekday token is cosmetic; parsers key off day/month/year.
    String(format: "Mon, %02d %@ %04d %02d:%02d:00 +0000",
           day, stressMonths[(month - 1) % 12], year, hour, minute)
}

private func makePlan(_ config: StressConfig) -> StressCorpusPlan {
    let n = config.scale
    let step = max(1, n / 8)
    let rareIndices = Set((1...7).map { $0 * step }.filter { $0 < n })
    let nearStep = max(1, n / 6)
    let nearAdjIndices = Set((1...5).map { $0 * nearStep }.filter { $0 < n })
    let nearFarIndices = Set((1...5).map { $0 * nearStep + 3 }.filter { $0 < n && !nearAdjIndices.contains($0) })

    let dupCount = n * config.duplicatePermille / 1000
    let dupSourceIndices = (0..<dupCount).map { k in (k * max(1, n / max(1, dupCount))) % n }

    // Expected result-ID sets, computed from indices without materializing any
    // email (ids are a pure function of index + seed).
    var rareIDs = Set<UUID>(), booleanAndIDs = Set<UUID>(), nearIDs = Set<UUID>()
    for i in rareIndices { rareIDs.insert(StressCorpusPlan.idForIndex(i, seed: config.seed)) }
    for i in nearAdjIndices { nearIDs.insert(StressCorpusPlan.idForIndex(i, seed: config.seed)) }
    // Boolean AND: alpha (i%50==0) AND beta (i%80==0) ⇒ i % lcm(50,80)=400 == 0.
    var i = 0
    while i < n { booleanAndIDs.insert(StressCorpusPlan.idForIndex(i, seed: config.seed)); i += 400 }

    return StressCorpusPlan(
        config: config, distinctCount: n, duplicateCount: dupCount, generatedTotal: n + dupCount,
        rareIndices: rareIndices, nearAdjIndices: nearAdjIndices, nearFarIndices: nearFarIndices,
        dupSourceIndices: dupSourceIndices,
        rareIDs: rareIDs, booleanAndIDs: booleanAndIDs, nearIDs: nearIDs
    )
}

// MARK: - Directory sizing

private func directoryStats(_ url: URL) -> (total: Int, walShm: Int) {
    let fm = FileManager.default
    guard let en = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
        return (0, 0)
    }
    var total = 0, walShm = 0
    for case let f as URL in en {
        let vals = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard vals?.isRegularFile == true, let size = vals?.fileSize else { continue }
        total += size
        let ext = f.pathExtension.lowercased()
        if ext == "wal" || ext == "shm" { walShm += size }
    }
    return (total, walShm)
}

// MARK: - Harness

enum StressHarness {

    /// Run the full lifecycle against a disposable environment rooted at `root`.
    /// The caller owns `root` (create + delete). Returns a fully-populated
    /// `StressResult` — correctness failures are recorded, not thrown, so a run
    /// always yields a JSON artifact.
    static func run(config: StressConfig, root: URL) async throws -> StressResult {
        var notes: [String] = []
        let env = try MailinStorageEnvironment.disposable(at: root)
        precondition(!env.isProduction, "stress harness must never run against production")

        let plan = makePlan(config)
        let clock = ContinuousClock()

        let rssBaseline = currentFootprintBytes()

        // ---- Import (streamed: only one chunk resident at a time) ----------
        var rssPeakImport = rssBaseline
        let importStart = clock.now
        var lo = 0
        while lo < plan.distinctCount {
            let hi = min(lo + config.insertSampleChunk, plan.distinctCount)
            var chunk: [MBOXParser.RawEmail] = []; chunk.reserveCapacity(hi - lo)
            for j in lo..<hi { chunk.append(plan.email(at: j)) }
            try await env.store.insertBatch(chunk, batchSize: config.innerBatchSize)
            rssPeakImport = max(rssPeakImport, currentFootprintBytes())
            lo = hi
        }
        // Duplicate copies (dedup must drop them).
        lo = 0
        while lo < plan.duplicateCount {
            let hi = min(lo + config.insertSampleChunk, plan.duplicateCount)
            var chunk: [MBOXParser.RawEmail] = []; chunk.reserveCapacity(hi - lo)
            for k in lo..<hi { chunk.append(plan.duplicate(at: k)) }
            try await env.store.insertBatch(chunk, batchSize: config.innerBatchSize)
            rssPeakImport = max(rssPeakImport, currentFootprintBytes())
            lo = hi
        }
        let importSeconds = ms(importStart.duration(to: clock.now)) / 1_000
        if let s = env.store as? SQLiteEmailStore { try? await s.checkpoint() }
        let rssPostImport = currentFootprintBytes()
        let storeCount = try await env.store.totalCount()

        // ---- Index (streamed FTS5 indexBatch, sharded by year) -------------
        var rssPeakIndex = rssPostImport
        let indexStart = clock.now
        lo = 0
        while lo < plan.distinctCount {
            let hi = min(lo + config.indexSampleChunk, plan.distinctCount)
            var chunk: [MBOXParser.RawEmail] = []; chunk.reserveCapacity(hi - lo)
            for j in lo..<hi { chunk.append(plan.email(at: j)) }
            try await env.fts.indexBatch(chunk)
            rssPeakIndex = max(rssPeakIndex, currentFootprintBytes())
            lo = hi
        }
        let indexSeconds = ms(indexStart.duration(to: clock.now)) / 1_000
        let ftsCommonCount = try await env.fts.countRaw(env.repositoryCommonQuery(plan.commonToken))
        let ftsRowCount = try await env.fts.rowCount()

        // ---- Reconcile verification pass (should re-index ~nothing) --------
        let recStart = clock.now
        let recResult = try await FTSReconciler.reconcile(
            store: env.store, fts: env.fts, pageSize: config.reconcilePageSize
        )
        let reconcileSeconds = ms(recStart.duration(to: clock.now)) / 1_000
        let rssReconcile = currentFootprintBytes()

        // ---- Search / NEAR / count latency ---------------------------------
        // Time-capped: the common term matches every row, so at 1M a single
        // ranked search can take seconds — cap the phase so latency sampling
        // can't dominate (or blow the test timeout).
        let phaseCapMs = 3_000.0
        var searchTimes: [Double] = [], nearTimes: [Double] = []
        var elapsed = 0.0
        while searchTimes.count < config.searchTrials && elapsed < phaseCapMs {
            let t0 = clock.now
            _ = try await env.fts.searchRaw(plan.commonToken, limit: 50)
            let dt = ms(t0.duration(to: clock.now)); searchTimes.append(dt); elapsed += dt
        }
        let nearQuery = FTSQueryBuilder.proximity(term1: plan.nearA, term2: plan.nearB, distance: plan.nearProximity)
            ?? FTSQueryBuilder.escapeTerm(plan.nearA)
        elapsed = 0.0
        while nearTimes.count < config.searchTrials && elapsed < phaseCapMs {
            let t0 = clock.now
            _ = try await env.fts.searchRaw(nearQuery, limit: 50)
            let dt = ms(t0.duration(to: clock.now)); nearTimes.append(dt); elapsed += dt
        }
        searchTimes.sort(); nearTimes.sort()
        let countStart = clock.now
        _ = try await env.fts.countRaw(plan.commonToken)
        let countMs = ms(countStart.duration(to: clock.now))
        let rssSearch = currentFootprintBytes()

        // ---- Correctness: rare / boolean / NEAR exact sets -----------------
        let rareResult = Set(try await env.fts.searchRaw(plan.rareToken, limit: max(100, plan.rareIDs.count * 4)))
        let rareOK = rareResult == plan.rareIDs
        let boolQuery = "\(plan.alphaToken) AND \(plan.betaToken)"
        let boolResult = Set(try await env.fts.searchRaw(boolQuery, limit: max(100, plan.booleanAndIDs.count * 4)))
        let boolOK = boolResult == plan.booleanAndIDs
        let nearResult = Set(try await env.fts.searchRaw(nearQuery, limit: max(100, plan.nearIDs.count * 4)))
        let nearOK = nearResult == plan.nearIDs
        if !rareOK { notes.append("rare mismatch: got \(rareResult.count), expected \(plan.rareIDs.count)") }
        if !boolOK { notes.append("boolean mismatch: got \(boolResult.count), expected \(plan.booleanAndIDs.count)") }
        if !nearOK { notes.append("NEAR mismatch: got \(nearResult.count), expected \(plan.nearIDs.count)") }

        // ---- Paging: full keyset walk, exact no-skip/no-dupe ---------------
        // (Uses a Set of ids for exact verification — test-only memory, kept
        // out of the reported product-RSS phases above.)
        var seen = Set<UUID>(); seen.reserveCapacity(plan.distinctCount)
        var noDup = true
        var cursorDate: Date? = nil, cursorID: UUID? = nil
        var firstPageMs = 0.0, deepPageMs = 0.0
        let deepThreshold = Int(Double(plan.distinctCount) * 0.9)
        var visited = 0, pageNo = 0
        while true {
            let t0 = clock.now
            let page = try await env.store.summaryPage(
                after: nil, before: nil, cursorDate: cursorDate, cursorID: cursorID, limit: config.pageSize
            )
            let dt = ms(t0.duration(to: clock.now))
            if pageNo == 0 { firstPageMs = dt }
            if page.isEmpty { break }
            for s in page { if !seen.insert(s.id).inserted { noDup = false } }
            visited += page.count
            if deepPageMs == 0 && visited >= deepThreshold { deepPageMs = dt }
            cursorDate = page.last!.date; cursorID = page.last!.id
            pageNo += 1
            if page.count < config.pageSize { break }
        }
        let noSkips = (visited == plan.distinctCount) && (seen.count == plan.distinctCount)
        if !noSkips { notes.append("paging visited \(visited)/\(plan.distinctCount), unique \(seen.count)") }

        // ---- Disk footprint (full corpus, before destructive checks) -------
        if let s = env.store as? SQLiteEmailStore { try? await s.checkpoint() }
        let storeStats = directoryStats(root.appendingPathComponent("store"))
        let ftsStats = directoryStats(root.appendingPathComponent("fts"))
        // External storage = SwiftData blob files that aren't the main .store db.
        let externalBytes = max(0, storeStats.total - mainStoreDBBytes(root.appendingPathComponent("store")))

        // ---- Reopen (cold = fresh instance over same on-disk root) ---------
        let reopened = try MailinStorageEnvironment.disposable(at: root)
        let coldStart = clock.now
        let reopenCount = try await reopened.store.totalCount()
        let coldReopenMs = ms(coldStart.duration(to: clock.now))
        let warmStart = clock.now
        _ = try await reopened.store.summaryPage(after: nil, before: nil, cursorDate: nil, cursorID: nil, limit: config.pageSize)
        let warmReopenMs = ms(warmStart.duration(to: clock.now))
        let reopenOK = (reopenCount == plan.distinctCount)
        if !reopenOK { notes.append("reopen count \(reopenCount) != \(plan.distinctCount)") }

        // ---- Destructive: delete consistency + reconcile rebuild -----------
        var deleteOK = true, rebuiltOK = true
        if config.runDestructiveChecks {
            if let victim = plan.rareIDs.first {
                try await env.repository.delete(ids: [victim])
                let stillInStore = (try await env.store.fullEmail(id: victim)) != nil
                let stillInFTS = try await env.fts.searchRaw(plan.rareToken, limit: 100).contains(victim)
                deleteOK = !stillInStore && !stillInFTS
                if !deleteOK { notes.append("delete left residue store=\(stillInStore) fts=\(stillInFTS)") }
            }
            // Clear FTS, then reconcile must rebuild it entirely from the store.
            try await env.fts.clear()
            _ = try await FTSReconciler.reconcile(store: env.store, fts: env.fts, pageSize: config.reconcilePageSize)
            let rebuilt = try await env.fts.countRaw(plan.commonToken)
            // One rare doc was deleted above, so expected common count is distinct-1.
            let expectedAfterDelete = plan.distinctCount - (plan.rareIDs.isEmpty ? 0 : 1)
            rebuiltOK = (rebuilt == expectedAfterDelete)
            if !rebuiltOK { notes.append("reconcile rebuilt \(rebuilt), expected \(expectedAfterDelete)") }
        }

        let passed = (storeCount == plan.distinctCount)
            && (ftsCommonCount == plan.distinctCount)
            && noSkips && noDup && rareOK && boolOK && nearOK
            && deleteOK && rebuiltOK && reopenOK

        func mb(_ b: UInt64) -> Double { Double(b) / 1_048_576.0 }

        return StressResult(
            scale: config.scale,
            seed: String(format: "0x%016llX", config.seed),
            configuration: config.configurationLabel,
            bodyBytes: config.bodyBytes,
            generatedTotal: plan.generatedTotal,
            distinctExpected: plan.distinctCount,
            duplicateCopies: plan.duplicateCount,
            storeCountAfterImport: storeCount,
            ftsCountCommonTerm: ftsCommonCount,
            ftsRowCount: ftsRowCount,
            importSeconds: importSeconds,
            importMsgPerSec: importSeconds > 0 ? Double(plan.generatedTotal) / importSeconds : 0,
            indexSeconds: indexSeconds,
            indexMsgPerSec: indexSeconds > 0 ? Double(plan.distinctCount) / indexSeconds : 0,
            rssBaselineMB: mb(rssBaseline),
            rssPeakImportMB: mb(rssPeakImport),
            rssPostImportMB: mb(rssPostImport),
            rssPeakIndexMB: mb(rssPeakIndex),
            rssSearchMB: mb(rssSearch),
            rssReconcileMB: mb(rssReconcile),
            storeDirBytes: storeStats.total,
            externalStorageBytes: externalBytes,
            ftsDirBytes: ftsStats.total,
            walShmBytes: storeStats.walShm + ftsStats.walShm,
            totalDiskBytes: storeStats.total + ftsStats.total,
            firstPageMs: firstPageMs,
            deepPageMs: deepPageMs,
            searchP50Ms: percentile(searchTimes, 50),
            searchP95Ms: percentile(searchTimes, 95),
            nearP50Ms: percentile(nearTimes, 50),
            nearP95Ms: percentile(nearTimes, 95),
            countMs: countMs,
            coldReopenMs: coldReopenMs,
            warmReopenMs: warmReopenMs,
            reconcileVerifySeconds: reconcileSeconds,
            reconcileRowsReindexed: recResult.rowsIndexed,
            pagingVisitedCount: visited,
            pagingNoSkips: noSkips,
            pagingNoDuplicates: noDup,
            rareTermExactMatch: rareOK,
            booleanAndExactMatch: boolOK,
            nearProximityExactMatch: nearOK,
            deleteConsistent: deleteOK,
            reconcileRebuiltAll: rebuiltOK,
            reopenPersisted: reopenOK,
            passed: passed,
            notes: notes
        )
    }

    /// Size of the primary SwiftData store db files (default.store + wal/shm),
    /// used to isolate external-storage blob bytes from the main db.
    private static func mainStoreDBBytes(_ storeDir: URL) -> Int {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: storeDir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for f in files {
            let name = f.lastPathComponent
            if name.hasSuffix(".store") || name.hasSuffix(".store-wal") || name.hasSuffix(".store-shm") {
                total += (try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            }
        }
        return total
    }
}

private extension MailinStorageEnvironment {
    /// Build the FTS query the repository would use for a plain term, so the
    /// harness counts via the same query path as production.
    func repositoryCommonQuery(_ term: String) -> String {
        FTSQueryBuilder.freeTextOrBoolean(term) ?? FTSQueryBuilder.escapeTerm(term)
    }
}
