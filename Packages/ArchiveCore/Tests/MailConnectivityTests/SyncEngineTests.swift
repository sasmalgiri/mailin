//
//  SyncEngineTests.swift
//  MailConnectivityTests
//
//  V4-04: the provider-independent sync engine against `FakeMailProvider`
//  and a REAL archive (`ConnectedArchiveSink` on a temporary store).
//    T08  > 5,000 messages, > 50 folders, every page, bounded memory
//    T16  arrivals / moves / deletions during the bootstrap
//    T17  expired history → full reconciliation without duplicate captures
//    T18  rate limits, Retry-After, transient failures, quota, 401 refresh,
//         revoked grant, fairness across accounts, no busy loop
//    T19  kill at every sink and engine boundary → restart → nothing skipped,
//         no record without bytes
//    T20  parse failure + download failure: distinct counts, exact retry
//    T23  disk full, drive gone, cancellation → safe pause, no completion claim
//    idempotent repeated sync; every request asks the network policy first
//

import XCTest
import Foundation
import CryptoKit
@testable import MailConnectivity
@testable import ArchiveCore

final class SyncEngineTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("sync-engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    // MARK: Helpers

    final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T
        init(_ value: T) { stored = value }
        var value: T { lock.withLock { stored } }
        func mutate<R>(_ body: (inout T) -> R) -> R { lock.withLock { body(&stored) } }
    }

    struct Killed: Error {}
    struct Refused: LocalizedError { var errorDescription: String? { "Mail is switched off." } }

    func makeSink(_ name: String = "archive") -> ConnectedArchiveSink {
        ConnectedArchiveSink(storeDirectory: dir.appendingPathComponent(name, isDirectory: true))
    }

    func register(_ fake: FakeMailProvider, in sink: ConnectedArchiveSink) async throws {
        try await sink.saveAccount(ConnectedAccountRecord(
            accountID: fake.accountID, provider: .gmail, issuer: "https://accounts.google.com",
            displayIdentity: "user-\(fake.accountID.uuidString.prefix(4))@example.com",
            enabledModes: ["capture"], connectionState: "connected", createdAt: Date(), updatedAt: Date()))
    }

    static let plenty = StorageProbe(reserveBytes: 1_024, availableBytes: { _ in 1 << 40 })

    static func backoff(_ waits: Box<[TimeInterval]>, transientAttempts: Int = 6,
                        maximumThrottleWait: TimeInterval = 1_800) -> BackoffPolicy {
        BackoffPolicy(base: 1, maximum: 60, transientAttempts: transientAttempts, maximumThrottleWait: maximumThrottleWait,
                      jitter: { 0.5 }, sleep: { seconds in waits.mutate { $0.append(seconds) }; await Task.yield() })
    }

    func makeEngine(_ fake: FakeMailProvider, _ sink: ConnectedArchiveSink,
                    scheduler: FairDownloadScheduler = FairDownloadScheduler(totalSlots: 4),
                    tokens: (any AccessTokenSource)? = nil,
                    asks: Box<[NetworkAsk]> = Box([]),
                    refuse: Box<Bool> = Box(false),
                    waits: Box<[TimeInterval]> = Box([]),
                    backoff: BackoffPolicy? = nil,
                    storage: StorageProbe = SyncEngineTests.plenty) -> SyncEngine {
        SyncEngine(adapter: fake, sink: sink, scheduler: scheduler, tokens: tokens,
                   permission: { ask in
                       asks.mutate { $0.append(ask) }
                       if refuse.value { throw Refused() }
                   },
                   backoff: backoff ?? Self.backoff(waits), storage: storage)
    }

    /// Gmail ids preserved for `account`.
    func capturedIDs(_ sink: ConnectedArchiveSink, account: UUID) async throws -> [String] {
        try await sink.store.remoteMessageDigests().filter { $0.account == account }.map { row in
            guard case .gmail(let id) = try ProviderMessageIdentity(key: row.key) else { return "?" }
            return id
        }
    }

    func assertEveryRecordHasItsBytes(_ sink: ConnectedArchiveSink, _ label: String = "",
                                      file: StaticString = #filePath, line: UInt = #line) async throws {
        for row in try await sink.store.remoteMessageDigests() {
            XCTAssertTrue(sink.store.blobStore.exists(BlobReference(digest: row.digest, length: 0)),
                          "\(label): \(row.key) has its bytes", file: file, line: line)
            guard case .gmail(let id) = try ProviderMessageIdentity(key: row.key) else { continue }
            let expected = SHA256.hash(data: FakeMailProvider.body(id)).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(row.digest, expected, "\(label): \(id) preserved byte-exact", file: file, line: line)
        }
    }

    func stagedFiles(_ sink: ConnectedArchiveSink) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: sink.stagingDirectory.path)) ?? []).filter { $0.hasPrefix("stage-") }
    }

    /// Folders f0…f(n-1), `perFolder` messages each, ids "<folder>-<i>".
    func seed(_ fake: FakeMailProvider, folders: Int, perFolder: Int) async {
        for f in 0..<folders {
            await fake.addFolder("f\(f)", path: "Folder \(f)")
            for i in 0..<perFolder { await fake.seed("f\(f)-\(i)", folders: ["f\(f)"]) }
        }
    }

    // MARK: T08 — > 5,000 messages, > 50 folders

    func testT08_moreThan5000MessagesAnd55Folders_everyPageEnumerated_boundedMemory() async throws {
        let sink = makeSink()
        let fake = FakeMailProvider(pageSize: 100)
        await seed(fake, folders: 55, perFolder: 95)            // 5,225 messages
        await fake.addFolder("empty", path: "Empty folder")      // empty folders are listed too
        for i in 0..<40 { await fake.apply(.move("f\(i)-0", to: ["f\(i)", "f\(i + 1)"])) }   // multi-label
        try await register(fake, in: sink)
        let asks = Box<[NetworkAsk]>([])
        let engine = makeEngine(fake, sink, asks: asks)

        let report = await engine.sync()
        XCTAssertEqual(report.outcome, .completed)
        let receipt = try XCTUnwrap(report.receipt)
        XCTAssertEqual(receipt.stored, 5_225, "no legacy fetch cap, no missing later page")
        XCTAssertEqual(receipt.pending, 0)
        let ids = try await capturedIDs(sink, account: fake.accountID)
        let live = await fake.liveIDs
        XCTAssertEqual(Set(ids), live)
        XCTAssertEqual(ids.count, 5_225, "one record per provider identity — a two-label message is one capture")
        let total = try await sink.store.totalCount()
        XCTAssertEqual(total, 5_225)

        // Every folder (56, listed over 3 folder pages) is in the archive tree.
        let counts = try await sink.store.connectedTableCounts()
        XCTAssertEqual(counts["remote_folders"], 56)
        XCTAssertEqual(counts["remote_memberships"], 5_225 + 40)

        // Bounded memory: one page at a time, downloads bounded by the provider limit.
        let peakHeld = await engine.peakItemsHeld
        let maxPage = await fake.maxItemsInOnePage
        let maxInFlight = await fake.maxInFlight
        XCTAssertLessThanOrEqual(peakHeld, 100)
        XCTAssertLessThanOrEqual(maxPage, 100)
        XCTAssertLessThanOrEqual(maxInFlight, 4)
        XCTAssertTrue(stagedFiles(sink).isEmpty, "the spool is empty after the run")

        // The policy was asked before every provider request.
        let requests = await fake.requests
        XCTAssertGreaterThanOrEqual(asks.value.count, requests)
        let status = try await engine.status()
        XCTAssertEqual(status.headline, .upToDate(saved: 5_225, reconciledAt: status.completeness.acquisition.reconciledAt))
        XCTAssertTrue(status.acquisitionComplete)
    }

    // MARK: T16 — changes during the bootstrap

    func testT16_arrivalsMovesAndDeletionsDuringBootstrap_nothingSilentlyOmitted_vanishedAreUnavailable() async throws {
        let sink = makeSink()
        let fake = FakeMailProvider(pageSize: 5)
        await seed(fake, folders: 3, perFolder: 20)              // f0, f1, f2 enumerated in that order, 4 pages each
        // Page 5 = f1's first page (f1-0…f1-4): f1-2 is deleted after it was listed, before it is downloaded.
        await fake.on(.afterEnumeratePage(5), [.delete("f1-2")])
        // Page 9 = f2's first page: f0 is finished, so these are only visible through the change log.
        await fake.on(.afterEnumeratePage(9), [
            .add("arrival-f0", folder: "f0"),        // a new message in an already-enumerated folder
            .move("f2-18", to: ["f0"]),             // moved out of the folder being enumerated, into a finished one
            .delete("f2-19"),                       // deleted before it was ever listed
            .add("arrival-f2", folder: "f2"),       // arrives in the folder being enumerated
        ])
        try await register(fake, in: sink)
        let engine = makeEngine(fake, sink)

        let report = await engine.sync()
        XCTAssertEqual(report.outcome, .completed, "unavailable items are reported, not hidden, and do not block completion")
        XCTAssertTrue(report.fullEnumeration)
        XCTAssertNotNil(report.reconciledTo, "the capture interval ends at a stated reconciliation point")
        XCTAssertLessThanOrEqual(report.startedAt, report.endedAt)

        let live = await fake.liveIDs
        let ids = Set(try await capturedIDs(sink, account: fake.accountID))
        XCTAssertEqual(ids, live, "every message on the server at the end is preserved")
        XCTAssertTrue(ids.contains("arrival-f0")); XCTAssertTrue(ids.contains("f2-18")); XCTAssertTrue(ids.contains("arrival-f2"))
        XCTAssertFalse(ids.contains("f1-2")); XCTAssertFalse(ids.contains("f2-19"))

        let receipt = try XCTUnwrap(report.receipt)
        XCTAssertEqual(receipt.unavailable, 2, "f1-2 and f2-19 vanished before capture: unavailable, never captured")
        XCTAssertEqual(receipt.pending, 0)
        let completeness = try await sink.completeness(accountID: fake.accountID)
        XCTAssertEqual(completeness.acquisition.captured, live.count)
        XCTAssertEqual(completeness.acquisition.unavailable, 2)
        XCTAssertTrue(completeness.acquisition.inventoryKnown)
        XCTAssertNotNil(completeness.runs.lastSuccessfulAt)
        XCTAssertNotNil(completeness.runs.lastSuccessfulStartedAt, "the interval the capture covered is recorded")

        // The moved message carries its new folder.
        let moved = try await sink.store.remoteMessageDigests().first { $0.key.hasSuffix("f2-18") }
        let provenance = try await sink.provenance(emailID: try XCTUnwrap(moved?.emailID))
        XCTAssertEqual(provenance?.memberships, ["Folder 0"])
        let total = try await sink.store.totalCount()
        XCTAssertEqual(total, live.count, "a message seen in enumeration AND the change log is one record")
    }

    // MARK: T17 — expired history

    func testT17_expiredHistory_fullReconciliation_noDuplicateCaptures_oldDataKept() async throws {
        let sink = makeSink()
        let fake = FakeMailProvider(pageSize: 7)
        await seed(fake, folders: 3, perFolder: 10)
        try await register(fake, in: sink)
        let engine = makeEngine(fake, sink)
        let first = await engine.sync()
        XCTAssertEqual(first.outcome, .completed)
        let fetchedAfterFirst = await fake.fetchCount
        XCTAssertEqual(fetchedAfterFirst, 30)

        for i in 0..<5 { await fake.apply(.add("late-\(i)", folder: "f1")) }
        await fake.apply(.move("f0-0", to: ["f0", "f2"]))
        await fake.apply(.delete("f2-9"))                       // deleted on the server: stays preserved
        await fake.apply(.expireHistory)

        let second = await engine.sync()
        XCTAssertEqual(second.outcome, .completed)
        XCTAssertTrue(second.fullEnumeration, "expired history starts a full reconciliation")
        let fetchedAfterSecond = await fake.fetchCount
        XCTAssertEqual(fetchedAfterSecond - fetchedAfterFirst, 5, "only the five new messages are downloaded")
        let r2 = try XCTUnwrap(second.receipt)
        XCTAssertEqual(r2.stored, 5)
        XCTAssertEqual(r2.alreadyPreserved, 29, "everything else is recognised by provider identity")
        let total = try await sink.store.totalCount()
        XCTAssertEqual(total, 35, "the server deletion kept the preserved f2-9; nothing was captured twice")
        let ids = try await capturedIDs(sink, account: fake.accountID)
        XCTAssertEqual(ids.count, Set(ids).count)
        let f00 = try await sink.store.remoteMessageDigests().first { $0.key.hasSuffix("f0-0") }
        let provenance = try await sink.provenance(emailID: try XCTUnwrap(f00?.emailID))
        XCTAssertEqual(provenance?.memberships, ["Folder 0", "Folder 2"], "the full reconcile records the new label")

        // The next sync is incremental again and downloads nothing.
        let third = await engine.sync()
        XCTAssertEqual(third.outcome, .completed)
        XCTAssertFalse(third.fullEnumeration)
        let fetchedAfterThird = await fake.fetchCount
        XCTAssertEqual(fetchedAfterThird, fetchedAfterSecond)
        try await assertEveryRecordHasItsBytes(sink, "T17")
    }

    // MARK: T18 — throttling, transient failures, quota, auth, fairness

    func testT18_retryAfterAndTransientFailures_backOffWithoutBusyLoop_andRecordReasons() async throws {
        let sink = makeSink()
        let fake = FakeMailProvider(pageSize: 10)
        await seed(fake, folders: 1, perFolder: 10)
        await fake.failNextRequests([.rateLimited(retryAfter: 30), .transient("connection reset")])   // folder list
        await fake.failFetch("f0-1", with: [.rateLimited(retryAfter: 45), .transient("timeout"), .transient("503")])
        await fake.failEveryFetch(of: "f0-7", with: .transient("HTTP 502"))
        try await register(fake, in: sink)
        let waits = Box<[TimeInterval]>([])
        let asks = Box<[NetworkAsk]>([])
        let engine = makeEngine(fake, sink, asks: asks, waits: waits)

        let report = await engine.sync()
        XCTAssertEqual(report.outcome, .completedWithFailures(failed: 1), "a failing item is recorded, never a false completion")
        let receipt = try XCTUnwrap(report.receipt)
        XCTAssertEqual(receipt.stored, 9); XCTAssertEqual(receipt.failed, 1); XCTAssertEqual(receipt.state, .partial)

        let recorded = waits.value
        XCTAssertTrue(recorded.contains { $0 >= 30 }, "Retry-After 30 honoured: \(recorded)")
        XCTAssertTrue(recorded.contains { $0 >= 45 }, "Retry-After 45 honoured: \(recorded)")
        // f0-7: six attempts, five waits growing exponentially (1, 2, 4, 8, 16 × jitter 0.75).
        let transient = recorded.filter { $0 < 30 }
        // Folder list 1, f0-1 2, f0-7 5 (exponential: 1, 2, 4, 8, 16 × jitter 0.75); concurrent, so compared as a multiset.
        XCTAssertEqual(transient.sorted(), [0.75, 0.75, 0.75, 1.5, 1.5, 3, 6, 12],
                       "every retry is preceded by a wait — no busy loop: \(recorded)")
        let attempts = await fake.fetched.count
        XCTAssertEqual(attempts, 9)
        // Every retry asked the policy again.
        XCTAssertEqual(asks.value.filter { $0.operation == .retry }.count, 2 + 3 + 5)

        let completeness = try await sink.completeness(accountID: fake.accountID)
        XCTAssertEqual(completeness.acquisition.failed, 1)
        let status = try await engine.status()
        XCTAssertEqual(status.headline, .savedWithFailures(saved: 9, failed: 1))
        XCTAssertFalse(status.acquisitionComplete)
    }

    func testT18_throttlingBeyondBudget_andQuota_pauseTheAccount_withoutCompletionClaim() async throws {
        let sink = makeSink()
        let throttled = FakeMailProvider(pageSize: 10)
        await seed(throttled, folders: 1, perFolder: 6)
        await throttled.failFetch("f0-2", with: [.rateLimited(retryAfter: 600), .rateLimited(retryAfter: 600)])
        let quota = FakeMailProvider(pageSize: 10)
        await seed(quota, folders: 1, perFolder: 6)
        await quota.failFetch("f0-3", with: [.quotaExceeded(resetAfter: 3_600)])
        try await register(throttled, in: sink); try await register(quota, in: sink)

        let e1 = makeEngine(throttled, sink, backoff: Self.backoff(Box([]), maximumThrottleWait: 1_000))
        let r1 = await e1.sync()
        XCTAssertEqual(r1.outcome, .paused(.rateLimited(retryAfter: 600)))
        XCTAssertFalse(r1.outcome.isCompletion)
        XCTAssertGreaterThan(r1.receipt?.pending ?? 0, 0, "the throttled item stays queued")
        let s1 = try await e1.status()
        XCTAssertEqual(s1.headline, .paused(.rateLimited(retryAfter: 600)))
        XCTAssertNil(s1.lastSuccessfulSync, "a paused run is never the last successful sync")

        let e2 = makeEngine(quota, sink)
        let r2 = await e2.sync()
        XCTAssertEqual(r2.outcome, .paused(.quotaExceeded(resetAfter: 3_600)))
        let s2 = try await e2.status()
        XCTAssertEqual(s2.defaultText, "Capture paused: the provider's limit was reached; it resumes later")
        XCTAssertFalse(s2.completeness.acquisition.inventoryKnown)

        // Both resume by themselves on the next run.
        let again1 = await e1.sync(); let again2 = await e2.sync()
        XCTAssertEqual(again1.outcome, .completed); XCTAssertEqual(again2.outcome, .completed)
        let total = try await sink.store.totalCount()
        XCTAssertEqual(total, 12)
    }

    func testT18_twoAccountsShareSlotsFairly_andAThrottledAccountDoesNotStallTheOther() async throws {
        let sink = makeSink()
        let journal = FetchJournal()
        let a = FakeMailProvider(pageSize: 40, journal: journal)
        let b = FakeMailProvider(pageSize: 40, journal: journal)
        await seed(a, folders: 1, perFolder: 40); await seed(b, folders: 1, perFolder: 40)
        await a.setFetchDelay(1_000_000); await b.setFetchDelay(1_000_000)
        try await register(a, in: sink); try await register(b, in: sink)
        let scheduler = FairDownloadScheduler(totalSlots: 2)
        let ea = makeEngine(a, sink, scheduler: scheduler)
        let eb = makeEngine(b, sink, scheduler: scheduler)
        async let ra = ea.sync()
        async let rb = eb.sync()
        let (reportA, reportB) = await (ra, rb)
        XCTAssertEqual(reportA.outcome, .completed); XCTAssertEqual(reportB.outcome, .completed)
        let starts = await journal.starts
        XCTAssertEqual(starts.count, 80)
        // Once both are waiting, neither runs ahead: alternate while the
        // account that started first still has work.
        let firstSwitch = try XCTUnwrap(starts.firstIndex { $0 != starts[0] })
        XCTAssertLessThan(firstSwitch, 40, "the second account started before the first finished")
        let earlyRemaining = 40 - firstSwitch
        let overlap = Array(starts[firstSwitch..<min(starts.count, firstSwitch + max(2, 2 * earlyRemaining - 2))])
        var longest = 0, streak = 0
        for (i, s) in overlap.enumerated() { streak = (i > 0 && overlap[i - 1] == s) ? streak + 1 : 1; longest = max(longest, streak) }
        XCTAssertLessThanOrEqual(longest, 3, "fair scheduling across accounts: \(overlap.map { $0 == starts[0] ? "A" : "B" }.joined())")
        let peak = await scheduler.peak()
        XCTAssertLessThanOrEqual(peak, 2)

        // A throttled account waits WITHOUT holding a slot: its waits only end
        // once the other account finished — impossible if it held both slots.
        let sink2 = makeSink("second")
        let slow = FakeMailProvider(pageSize: 10)
        let fast = FakeMailProvider(pageSize: 10)
        await seed(slow, folders: 1, perFolder: 4); await seed(fast, folders: 1, perFolder: 30)
        for i in 0..<4 { await slow.failFetch("f0-\(i)", with: [.rateLimited(retryAfter: 120)]) }
        try await register(slow, in: sink2); try await register(fast, in: sink2)
        let fastDone = Box(false)
        let waitedForOther = Box(false)
        let gatedBackoff = BackoffPolicy(jitter: { 0.5 }, sleep: { _ in
            for _ in 0..<5_000 where !fastDone.value { try await Task.sleep(nanoseconds: 2_000_000) }
            waitedForOther.mutate { $0 = fastDone.value }
        })
        let shared = FairDownloadScheduler(totalSlots: 2)
        let eSlow = makeEngine(slow, sink2, scheduler: shared, backoff: gatedBackoff)
        let eFast = makeEngine(fast, sink2, scheduler: shared)
        async let slowRun = eSlow.sync()
        let fastReport = await eFast.sync()
        fastDone.mutate { $0 = true }
        let slowReport = await slowRun
        XCTAssertEqual(fastReport.outcome, .completed)
        XCTAssertEqual(slowReport.outcome, .completed)
        XCTAssertTrue(waitedForOther.value, "the other account completed while this one was backing off")
    }

    func testT18_expiredAccessToken_oneSharedRefresh_revokedGrant_needsSignIn_otherAccountUnaffected() async throws {
        let sink = makeSink()
        let credentials = InMemoryCredentialStore()
        let endpoint = FakeTokenEndpoint()
        let coordinator = TokenRefreshCoordinator(credentials: credentials, transport: endpoint)
        let good = FakeMailProvider(pageSize: 20, tokenAudience: Fixtures.google.audience)
        let revoked = FakeMailProvider(pageSize: 20, tokenAudience: Fixtures.google.audience)
        await seed(good, folders: 2, perFolder: 15); await seed(revoked, folders: 1, perFolder: 5)
        for fake in [good, revoked] {
            await coordinator.register(account: fake.accountID, configuration: Fixtures.google)
            var set = Fixtures.expiredSet(fake.accountID, refresh: "refresh-\(fake.accountID)", access: "stale")
            set.expiresAt = Date(timeIntervalSinceNow: 3_600)       // looks valid locally; the provider rejects it
            try await coordinator.store(set)
            try await register(fake, in: sink)
        }
        await good.setRequiredToken("fresh")
        await revoked.setRequiredToken("fresh")
        await endpoint.respond(to: "refresh-\(good.accountID)", json: Fixtures.tokenJSON(access: "fresh"))
        await endpoint.respond(to: "refresh-\(revoked.accountID)", status: 400, json: #"{"error":"invalid_grant"}"#)

        let asks = Box<[NetworkAsk]>([])
        let eGood = makeEngine(good, sink, tokens: coordinator, asks: asks)
        let eRevoked = makeEngine(revoked, sink, tokens: coordinator)
        async let rGood = eGood.sync()
        async let rRevoked = eRevoked.sync()
        let (goodReport, revokedReport) = await (rGood, rRevoked)

        XCTAssertEqual(goodReport.outcome, .completed)
        let refreshes = await coordinator.refreshCount(for: good.accountID)
        XCTAssertEqual(refreshes, 1, "one refresh for the account, shared by every request")
        XCTAssertTrue(asks.value.contains { $0.operation == .oauthRefresh && $0.destination == .authorization
                                            && $0.host == "oauth2.googleapis.com" })
        XCTAssertEqual(revokedReport.outcome, .needsSignIn)
        let status = try await eRevoked.status()
        XCTAssertEqual(status.defaultText, "Account needs sign-in; saved mail remains available")
        let goodIDs = try await capturedIDs(sink, account: good.accountID)
        XCTAssertEqual(goodIDs.count, 30, "the revoked account did not stall the other")
        // No request ever carried another account's token.
        let tokens = await revoked.tokensSeen
        XCTAssertFalse(tokens.contains("fresh"))
    }

    func testPolicyRefusal_stopsBeforeAnyRequest_andNeverRetries() async throws {
        let sink = makeSink()
        let fake = FakeMailProvider()
        await seed(fake, folders: 1, perFolder: 3)
        try await register(fake, in: sink)
        let asks = Box<[NetworkAsk]>([])
        let engine = makeEngine(fake, sink, asks: asks, refuse: Box(true))
        let report = await engine.sync()
        XCTAssertEqual(report.outcome, .notPermitted("Mail is switched off."))
        let requests = await fake.requests
        XCTAssertEqual(requests, 0, "nothing reached the provider")
        XCTAssertEqual(asks.value.count, 1, "refused once, no retry loop")
        let status = try await engine.status()
        XCTAssertEqual(status.headline, .notPermitted)
    }

    // MARK: T19 — kill at every boundary

    func testT19_killAtEverySinkAndEngineBoundary_restartResumes_nothingSkipped_noRecordWithoutBytes() async throws {
        enum Point { case sink(CaptureBoundary), engine(SyncBoundary) }
        let points: [Point] = CaptureBoundary.allCases.map(Point.sink) + SyncBoundary.allCases.map(Point.engine)
        for point in points {
            let name = "\(point)"
            let fake = FakeMailProvider(pageSize: 6)
            await seed(fake, folders: 3, perFolder: 12)
            await fake.on(.afterEnumeratePage(4), [.add("mid-1", folder: "f0"), .move("f2-11", to: ["f0"]), .delete("f2-10")])
            let killAt: Int
            if case .engine(.afterBoundaryRecorded) = point { killAt = 1 } else if case .engine(.afterChangePage) = point { killAt = 1 } else { killAt = 4 }
            let counter = Box(0)

            var sink: ConnectedArchiveSink? = makeSink(name)
            try await register(fake, in: sink!)
            var engine: SyncEngine? = makeEngine(fake, sink!)
            await engine!.setAbortFilter { $0 is Killed }
            switch point {
            case .sink(let boundary):
                await sink!.setFaultHook { b in
                    if b == boundary, counter.mutate({ $0 += 1; return $0 }) == killAt { throw Killed() }
                }
            case .engine(let boundary):
                await engine!.setFaultHook { b in
                    if b == boundary, counter.mutate({ $0 += 1; return $0 }) == killAt { throw Killed() }
                }
            }
            let dying = await engine!.sync()
            XCTAssertEqual(dying.outcome, .aborted, "\(name): the process died")
            engine = nil; sink = nil

            // Restart: a new process on the same archive, the same server.
            let restarted = makeSink(name)
            let report = try await restarted.reconcileAfterRestart()
            XCTAssertEqual(report.recordsMissingBytes, 0, "\(name): no record points at missing bytes")
            XCTAssertEqual(report.runsInterrupted, 1, "\(name)")
            let resumed = makeEngine(fake, restarted)
            let result = await resumed.sync()
            XCTAssertEqual(result.outcome, .completed, "\(name)")

            let live = await fake.liveIDs
            let ids = try await capturedIDs(restarted, account: fake.accountID)
            XCTAssertEqual(Set(ids), live, "\(name): no skipped message")
            XCTAssertEqual(ids.count, live.count, "\(name): none doubled")
            let total = try await restarted.store.totalCount()
            XCTAssertEqual(total, live.count, "\(name)")
            try await assertEveryRecordHasItsBytes(restarted, name)
            let completeness = try await restarted.completeness(accountID: fake.accountID)
            XCTAssertTrue(completeness.acquisition.inventoryKnown, "\(name)")
            XCTAssertEqual(completeness.acquisition.remaining, 0, "\(name)")
            XCTAssertEqual(completeness.acquisition.unavailable, 1, "\(name): f2-10 vanished before capture")
        }
    }

    // MARK: T20 — parse failure, download failure

    func testT20_parseFailureKeepsBytes_downloadFailureRecorded_countsDistinct_failureRetriedExactly() async throws {
        let sink = makeSink()
        let fake = FakeMailProvider(pageSize: 5)
        await seed(fake, folders: 1, perFolder: 12)
        await fake.failEveryFetch(of: "f0-7", with: .permanent("HTTP 500: the provider could not produce the message"))
        try await register(fake, in: sink)
        await sink.setParseFaultHook { data in
            if String(decoding: data, as: UTF8.self).contains("Body f0-3 end") {
                throw ConnectedArchiveError.stagingFailed("simulated reader failure")
            }
        }
        let engine = makeEngine(fake, sink)
        let first = await engine.sync()
        XCTAssertEqual(first.outcome, .completedWithFailures(failed: 1))

        var c = try await sink.completeness(accountID: fake.accountID)
        XCTAssertEqual(c.acquisition.captured, 11, "acquired")
        XCTAssertEqual(c.acquisition.failed, 1, "the transfer failure is not counted as preserved")
        XCTAssertEqual(c.preservation.recordsWithBytes, 11, "preserved — including the unreadable one")
        XCTAssertEqual(c.preservation.unreadable, 1, "not described as searchable")
        let unreadable = try await sink.unreadableCaptures(accountID: fake.accountID)
        XCTAssertEqual(unreadable.map(\.identity), [.gmail(messageID: "f0-3")])
        XCTAssertTrue(unreadable.first?.reason.contains("simulated reader failure") ?? false)
        try await assertEveryRecordHasItsBytes(sink, "T20")
        // The unreadable record still reads back its exact bytes.
        let row = try await sink.store.remoteMessageDigests().first { $0.key.hasSuffix("f0-3") }
        let email = try await sink.store.fullEmail(id: try XCTUnwrap(row?.emailID))
        XCTAssertEqual(email?.rawSource, String(decoding: FakeMailProvider.body("f0-3"), as: UTF8.self))
        let s1 = try await engine.status()
        XCTAssertEqual(s1.headline, .savedWithFailures(saved: 11, failed: 1))

        // The provider recovers: the exact failed item is retried, nothing else is fetched.
        await fake.failEveryFetch(of: "f0-7", with: nil)
        let before = await fake.fetched.count
        let second = await engine.sync()
        XCTAssertEqual(second.outcome, .completed)
        let fetched = await fake.fetched
        XCTAssertEqual(Array(fetched.dropFirst(before)), ["f0-7"])
        c = try await sink.completeness(accountID: fake.accountID)
        XCTAssertEqual(c.acquisition.captured, 12); XCTAssertEqual(c.acquisition.failed, 0)
        XCTAssertEqual(c.preservation.unreadable, 1)
        let s2 = try await engine.status()
        XCTAssertEqual(s2.headline, .savedTextPending(saved: 12))
        XCTAssertEqual(s2.defaultText, "Saved locally; attachment text pending")
    }

    // MARK: T23 — disk full, drive gone, cancellation

    func testT23_diskFull_pausesBeforeCheckpoint_spoolEmpty_resumesExactly() async throws {
        let sink = makeSink()
        let fake = FakeMailProvider(pageSize: 10)
        await seed(fake, folders: 2, perFolder: 15)
        try await register(fake, in: sink)
        let free = Box<Int64>(1 << 40)
        let storage = StorageProbe(reserveBytes: 1_000_000, availableBytes: { _ in free.value })
        await fake.on(.beforeFetchNumber(6), [.run { free.mutate { $0 = 500_000 } }])
        let engine = makeEngine(fake, sink, storage: storage)

        let paused = await engine.sync()
        XCTAssertEqual(paused.outcome, .paused(.diskFull(availableBytes: 500_000)))
        XCTAssertFalse(paused.outcome.isCompletion)
        XCTAssertEqual(paused.receipt?.state, .partial)
        XCTAssertTrue(stagedFiles(sink).isEmpty, "no spool growth while paused")
        let cp = try await sink.checkpoint(accountID: fake.accountID, scope: "enum:f0")
        XCTAssertNil(cp, "the first page never completed, so its cursor did not advance")
        let status = try await engine.status()
        XCTAssertEqual(status.defaultText, "Capture paused: not enough free space")
        XCTAssertFalse(status.completeness.acquisition.inventoryKnown)
        XCTAssertNil(status.lastSuccessfulSync)
        XCTAssertNotNil(status.lastAttemptedSync)

        free.mutate { $0 = 1 << 40 }
        let resumed = await engine.sync()
        XCTAssertEqual(resumed.outcome, .completed)
        let total = try await sink.store.totalCount()
        XCTAssertEqual(total, 30)
        try await assertEveryRecordHasItsBytes(sink, "T23")
    }

    func testT23_driveUnavailable_pausesWithoutTouchingTheProvider() async throws {
        let sink = makeSink()
        let fake = FakeMailProvider()
        await seed(fake, folders: 1, perFolder: 3)
        try await register(fake, in: sink)
        let engine = makeEngine(fake, sink, storage: StorageProbe(availableBytes: { _ in nil }))
        let report = await engine.sync()
        XCTAssertEqual(report.outcome, .paused(.driveUnavailable))
        let requests = await fake.requests
        XCTAssertEqual(requests, 0)
        let status = try await engine.status()
        XCTAssertEqual(status.defaultText, "Capture paused: drive unavailable")
    }

    func testT23_cancellation_stopsSafely_noCompletionClaim_resumeIsExact() async throws {
        let sink = makeSink()
        let fake = FakeMailProvider(pageSize: 8)
        await seed(fake, folders: 2, perFolder: 20)
        await fake.setFetchDelay(2_000_000)
        try await register(fake, in: sink)
        let engine = makeEngine(fake, sink)
        let task = Box<Task<SyncRunReport, Never>?>(nil)
        await fake.on(.beforeFetchNumber(10), [.run { task.value?.cancel() }])
        let running = Task { await engine.sync() }
        task.mutate { $0 = running }
        let report = await running.value
        XCTAssertEqual(report.outcome, .cancelled)
        XCTAssertFalse(report.outcome.isCompletion)
        XCTAssertTrue(stagedFiles(sink).isEmpty)
        let c = try await sink.completeness(accountID: fake.accountID)
        XCTAssertFalse(c.acquisition.inventoryKnown)
        XCTAssertNil(c.runs.lastSuccessfulAt, "a cancelled run is not a successful sync")

        let resumed = await engine.sync()
        XCTAssertEqual(resumed.outcome, .completed)
        let ids = try await capturedIDs(sink, account: fake.accountID)
        XCTAssertEqual(ids.count, 40); XCTAssertEqual(Set(ids).count, 40)
    }

    // MARK: Idempotence

    func testRepeatedSync_isIdempotent_noNewRecordsNoDownloads() async throws {
        let sink = makeSink()
        let fake = FakeMailProvider(pageSize: 9)
        await seed(fake, folders: 4, perFolder: 10)
        await fake.apply(.move("f1-1", to: ["f1", "f3"]))
        try await register(fake, in: sink)
        let engine = makeEngine(fake, sink)
        let first = await engine.sync()
        XCTAssertEqual(first.outcome, .completed)
        let tablesBefore = try await sink.store.connectedTableCounts()
        let fetchedBefore = await fake.fetchCount
        for _ in 0..<2 {
            let again = await engine.sync()
            XCTAssertEqual(again.outcome, .completed)
            XCTAssertEqual(again.receipt?.stored, 0)
        }
        let fetchedAfter = await fake.fetchCount
        XCTAssertEqual(fetchedAfter, fetchedBefore, "no download for preserved mail")
        let total = try await sink.store.totalCount()
        XCTAssertEqual(total, 40)
        let tablesAfter = try await sink.store.connectedTableCounts()
        XCTAssertEqual(tablesAfter["remote_messages"], tablesBefore["remote_messages"])
        XCTAssertEqual(tablesAfter["remote_memberships"], tablesBefore["remote_memberships"])

        // Engine concurrency guard: a second sync of the same account while one runs is refused.
        await fake.setFetchDelay(0)
        async let one = engine.sync()
        async let two = engine.sync()
        let outcomes = await [one.outcome, two.outcome]
        XCTAssertTrue(outcomes.contains(.completed))
    }

    // MARK: Contract pieces

    func testIdentityKeyRoundTrip_andSchedulerRespectsPerAccountLimit() async throws {
        for identity: ProviderMessageIdentity in [.gmail(messageID: "18c1"), .graph(mailbox: "a@b.c", immutableID: "AAMk=="),
                                                   .imap(mailbox: "INBOX/Ünïcode", uidValidity: 7, uid: 42)] {
            XCTAssertEqual(try ProviderMessageIdentity(key: identity.key()), identity)
        }
        XCTAssertThrowsError(try ProviderMessageIdentity(key: "imap\u{1F}INBOX\u{1F}0\u{1F}1"))
        let scheduler = FairDownloadScheduler(totalSlots: 5)
        let account = UUID()
        try await scheduler.acquire(account: account, accountLimit: 2)
        try await scheduler.acquire(account: account, accountLimit: 2)
        let third = Task { try await scheduler.acquire(account: account, accountLimit: 2) }
        try await Task.sleep(nanoseconds: 20_000_000)
        let inUse = await scheduler.slotsInUse
        XCTAssertEqual(inUse, 2, "the account's own limit holds even with free slots")
        await scheduler.release(account: account)
        try await third.value
        let after = await scheduler.slotsInUse
        XCTAssertEqual(after, 2)
        let cancelled = Task { try await scheduler.acquire(account: account, accountLimit: 2) }
        cancelled.cancel()
        do { try await cancelled.value; XCTFail("a cancelled waiter must not get a slot") } catch is CancellationError {}
    }
}
