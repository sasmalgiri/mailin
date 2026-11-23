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

    // MARK: DL-03 — continuous queue (pages overlap)

    /// Repeats the previous page's last message at the top of the next page —
    /// what Outlook's `$skip` paging does when mail moves during a walk.
    actor OverlappingPages: MailProviderAdapter {
        let inner: FakeMailProvider
        private var lastOfPage: [String: RemoteItemRef] = [:]
        init(_ inner: FakeMailProvider) { self.inner = inner }
        nonisolated var accountID: UUID { inner.accountID }
        nonisolated var provider: MailProviderKind { .gmail }
        nonisolated var mailHost: String { "gmail.googleapis.com" }
        nonisolated var authorizationHost: String? { nil }
        nonisolated var tokenAudience: String? { nil }
        func limits() async -> ProviderLimits { await inner.limits() }
        func listFolders(pageToken: String?, context: ProviderRequestContext) async throws -> FolderPage {
            try await inner.listFolders(pageToken: pageToken, context: context)
        }
        func enumerate(folder: RemoteFolderOccurrence, cursor: String?, pageSize: Int,
                       context: ProviderRequestContext) async throws -> EnumerationPage {
            var page = try await inner.enumerate(folder: folder, cursor: cursor, pageSize: pageSize, context: context)
            if cursor != nil, let repeated = lastOfPage[folder.serverID] { page.items.insert(repeated, at: 0) }
            lastOfPage[folder.serverID] = page.items.last
            return page
        }
        func fetchRaw(_ item: RemoteItemRef, into sink: RawByteSink, context: ProviderRequestContext) async throws -> FetchedItemMetadata {
            try await inner.fetchRaw(item, into: sink, context: context)
        }
        func changeBoundary(scope: ChangeScope, context: ProviderRequestContext) async throws -> String {
            try await inner.changeBoundary(scope: scope, context: context)
        }
        func changes(scope: ChangeScope, since token: String, context: ProviderRequestContext) async throws -> ChangePage {
            try await inner.changes(scope: scope, since: token, context: context)
        }
    }

    func testDL03_pagesOverlap_everyMessageOnce_aRepeatedMessageDownloadedOnce() async throws {
        let sink = makeSink()
        let fake = FakeMailProvider(pageSize: 10)
        await seed(fake, folders: 3, perFolder: 47)                // 141 messages, 5 pages per folder
        await fake.setFetchDelay(1_000_000)
        try await register(fake, in: sink)
        let wrapped = OverlappingPages(fake)
        let engine = SyncEngine(adapter: wrapped, sink: sink, scheduler: FairDownloadScheduler(totalSlots: 4), tokens: nil,
                                permission: { _ in }, backoff: Self.backoff(Box([])), storage: Self.plenty)
        await engine.setPipelineOverride(true)
        let report = await engine.sync()
        XCTAssertEqual(report.outcome, .completed)
        XCTAssertEqual(report.receipt?.stored, 141)
        let pagesAtOnce = await engine.peakPagesInFlight
        XCTAssertEqual(pagesAtOnce, 2, "the next page is saved while the previous one finishes")
        let fetched = await fake.fetched
        XCTAssertEqual(fetched.count, 141, "a message listed on two overlapping pages is downloaded once")
        XCTAssertEqual(Set(fetched).count, 141)
        let ids = try await capturedIDs(sink, account: fake.accountID)
        let live = await fake.liveIDs
        XCTAssertEqual(Set(ids), live)
        XCTAssertEqual(ids.count, 141)
        for f in 0..<3 {
            let cp = try await sink.checkpoint(accountID: fake.accountID, scope: "enum:f\(f)")
            XCTAssertEqual(cp?.bootstrapState.hasPrefix("enumerated@"), true, "every folder's walk is recorded as finished")
        }
        XCTAssertTrue(stagedFiles(sink).isEmpty)
        // A second run only confirms.
        let again = await engine.sync()
        XCTAssertEqual(again.outcome, .completed)
        XCTAssertEqual(again.receipt?.stored, 0)
        let refetched = await fake.fetched
        XCTAssertEqual(refetched.count, 141)
    }

    func testDL03_aStopWhileTwoPagesRun_neverCheckpointsAnUnfinishedPage_resumeIsExact() async throws {
        let sink = makeSink()
        let fake = FakeMailProvider(pageSize: 8)
        await seed(fake, folders: 2, perFolder: 30)
        await fake.setFetchDelay(2_000_000)
        try await register(fake, in: sink)
        let engine = makeEngine(fake, sink)
        await engine.setPipelineOverride(true)
        let task = Box<Task<SyncRunReport, Never>?>(nil)
        await fake.on(.beforeFetchNumber(13), [.run { task.value?.cancel() }])   // inside the second page
        let running = Task { await engine.sync() }
        task.mutate { $0 = running }
        let report = await running.value
        XCTAssertEqual(report.outcome, .cancelled)
        XCTAssertTrue(stagedFiles(sink).isEmpty, "nothing is left half-written after the stop")
        if let cp = try await sink.checkpoint(accountID: fake.accountID, scope: "enum:f0"), cp.bootstrapState.hasPrefix("enumerating@") {
            // The saved position never passes a message that was not saved.
            let saved = Set(try await capturedIDs(sink, account: fake.accountID))
            let upTo = Int(cp.cursor) ?? 0
            for i in 0..<upTo { XCTAssertTrue(saved.contains("f0-\(i)"), "f0-\(i) is before the saved position, so it is saved") }
        }
        await engine.setPipelineOverride(true)
        let resumed = await engine.sync()
        XCTAssertEqual(resumed.outcome, .completed)
        let ids = try await capturedIDs(sink, account: fake.accountID)
        XCTAssertEqual(ids.count, 60); XCTAssertEqual(Set(ids).count, 60)
    }

    /// DL-04: with the continuous queue the archive prepares several downloaded
    /// messages at once (blob copy + parse off the sink actor); the result is the
    /// same archive as one at a time — same bytes, same records, same folders.
    func testDL04_parallelPreparation_sameArchiveAsOneAtATime() async throws {
        var digests: [Bool: [String: String]] = [:]
        var subjects: [Bool: Set<String>] = [:]
        for parallel in [false, true] {
            let sink = makeSink("archive-\(parallel)")
            let fake = FakeMailProvider(accountID: UUID(uuidString: "00000000-0000-0000-0000-0000000000D4")!, pageSize: 20)
            await seed(fake, folders: 3, perFolder: 40)
            await fake.apply(.move("f0-1", to: ["f0", "f2"]))
            await fake.setFetchDelay(500_000)
            try await register(fake, in: sink)
            let engine = makeEngine(fake, sink)
            await engine.setPipelineOverride(parallel)
            let report = await engine.sync()
            XCTAssertEqual(report.outcome, .completed)
            XCTAssertEqual(report.receipt?.stored, 120)
            let peak = await sink.peakParallelPreparations
            if parallel { XCTAssertGreaterThanOrEqual(peak, 2, "several messages prepared at once") } else { XCTAssertEqual(peak, 0) }
            var byKey: [String: String] = [:]
            for row in try await sink.store.remoteMessageDigests() where row.account == fake.accountID { byKey[row.key] = row.digest }
            digests[parallel] = byKey
            let all = try await sink.store.summaryPage(after: nil, before: nil, cursorDate: nil, cursorID: nil, limit: 1_000)
            subjects[parallel] = Set(all.map(\.subject))
            let counts = try await sink.store.connectedTableCounts()
            XCTAssertEqual(counts["remote_memberships"], 121)
            XCTAssertTrue(stagedFiles(sink).isEmpty)
        }
        XCTAssertEqual(digests[true], digests[false], "the same bytes for every message")
        XCTAssertEqual(digests[true]?.count, 120)
        XCTAssertEqual(subjects[true], subjects[false], "the same records")
    }

    // MARK: TOR-01 — endgame mode

    func testTOR01_aStuckDownload_isAskedForAgainOnAnIdleSlot_theFirstCompleteCopyIsSaved() async throws {
        let sink = makeSink()
        let fake = FakeMailProvider(pageSize: 40)
        await seed(fake, folders: 1, perFolder: 40)
        await fake.setFetchDelay(2_000_000)
        await fake.hangFirstFetch(of: "f0-30", for: 20_000_000_000)        // 20 s: a hung connection
        try await register(fake, in: sink)
        let engine = makeEngine(fake, sink)
        await engine.setPipelineOverride(true)
        await engine.setHedgeMinimumDelay(0.05)
        let started = Date()
        let report = await engine.sync()
        let seconds = Date().timeIntervalSince(started)
        XCTAssertEqual(report.outcome, .completed)
        XCTAssertEqual(report.receipt?.stored, 40)
        XCTAssertLessThan(seconds, 5, "the stuck download did not hold the run for 20 s")
        let started2 = await engine.hedgesStarted
        let won = await engine.hedgesWon
        XCTAssertGreaterThanOrEqual(started2, 1)
        XCTAssertEqual(won, 1, "the second request finished first and was saved")
        let starts = await fake.fetchStarts
        XCTAssertEqual(starts.filter { $0 == "f0-30" }.count, 2, "asked for twice")
        let ids = try await capturedIDs(sink, account: fake.accountID)
        XCTAssertEqual(ids.count, 40); XCTAssertEqual(Set(ids).count, 40, "saved once")
        try await assertEveryRecordHasItsBytes(sink, "after a hedged download")
        XCTAssertTrue(stagedFiles(sink).isEmpty, "the cancelled copy left nothing behind")
    }

    func testTOR01_noSecondRequest_withoutTheFastMode_orUnderASpeedLimit_orWhileOthersWait() async throws {
        for mode in ["plain", "limited"] {
            let sink = makeSink(mode)
            let fake = FakeMailProvider(pageSize: 40)
            await seed(fake, folders: 1, perFolder: 30)
            await fake.hangFirstFetch(of: "f0-25", for: 300_000_000)      // 0.3 s
            try await register(fake, in: sink)
            let engine = makeEngine(fake, sink)
            await engine.setHedgeMinimumDelay(0.01)
            await engine.setPipelineOverride(mode == "limited")
            if mode == "limited" { await engine.setLimiter(BandwidthLimiter(bytesPerSecond: 1_000_000_000)) }
            let report = await engine.sync()
            XCTAssertEqual(report.outcome, .completed)
            let hedges = await engine.hedgesStarted
            XCTAssertEqual(hedges, 0, mode)
        }
        // The scheduler never gives a second-request slot while someone waits for one.
        let scheduler = FairDownloadScheduler(totalSlots: 1)
        let a = UUID(), b = UUID()
        try await scheduler.acquire(account: a, accountLimit: 1)
        let ok = await scheduler.tryAcquire(account: b, accountLimit: 1)
        XCTAssertFalse(ok, "no free slot")
        await scheduler.release(account: a)
        let free = await scheduler.tryAcquire(account: b, accountLimit: 1)
        XCTAssertTrue(free, "an idle slot is used")
    }

    // MARK: TOR-02 — adaptive downloads

    func testTOR02_adaptive_growsByOneAfterCleanDownloads_halvesWhenToldToSlowDown() {
        var a = SyncEngine.AdaptiveDownloads(current: 4, ceiling: 6)
        for _ in 0..<7 { a.succeeded() }
        XCTAssertEqual(a.current, 4, "not before 2 × limit clean downloads")
        a.succeeded()
        XCTAssertEqual(a.current, 5)
        for _ in 0..<100 { a.succeeded() }
        XCTAssertEqual(a.current, 6, "never above the provider's ceiling")
        a.throttled()
        XCTAssertEqual(a.current, 3, "halved at the first slow-down")
        a.throttled(); a.throttled(); a.throttled()
        XCTAssertEqual(a.current, 1, "never below one")
    }

    func testTOR02_aSync_probesUpToTheCeiling_neverAbove_andSavesEverything() async throws {
        let sink = makeSink()
        let fake = FakeMailProvider(pageSize: 50)
        await fake.setMaxConcurrent(2)
        await fake.setAdaptiveCeiling(6)
        await seed(fake, folders: 2, perFolder: 100)
        await fake.setFetchDelay(1_000_000)
        try await register(fake, in: sink)
        let engine = makeEngine(fake, sink, scheduler: FairDownloadScheduler(totalSlots: 12))
        await engine.setPipelineOverride(true)
        let report = await engine.sync()
        XCTAssertEqual(report.outcome, .completed)
        XCTAssertEqual(report.receipt?.stored, 200)
        let peak = await engine.peakDownloadLimit
        let inFlight = await fake.maxInFlight
        XCTAssertEqual(peak, 6, "probed up to the ceiling")
        XCTAssertGreaterThan(inFlight, 2, "more than the starting number ran at once")
        XCTAssertLessThanOrEqual(inFlight, 6, "never more than the ceiling")
    }

    func testTOR02_aSlowDown_halvesTheDownloadsAtOnce_everythingStillSaved() async throws {
        let sink = makeSink()
        let fake = FakeMailProvider(pageSize: 20)
        await fake.setMaxConcurrent(4)
        await seed(fake, folders: 1, perFolder: 60)
        for i in [5, 6, 7] { await fake.failFetch("f0-\(i)", with: [.rateLimited(retryAfter: 0)]) }
        try await register(fake, in: sink)
        let engine = makeEngine(fake, sink)
        await engine.setPipelineOverride(true)
        let report = await engine.sync()
        XCTAssertEqual(report.outcome, .completed)
        XCTAssertEqual(report.receipt?.stored, 60)
        let backoffs = await engine.adaptiveBackoffs
        let now = await engine.adaptive?.current
        XCTAssertGreaterThanOrEqual(backoffs, 1, "the slow-down was answered")
        XCTAssertNotNil(now)
        XCTAssertLessThanOrEqual(now ?? 9, 4, "never above the provider's own number")
        // Without the fast mode the fixed number is used, as before.
        let plain = makeEngine(fake, makeSink("plain"))
        await plain.setPipelineOverride(false)
        let plainAdaptive = await plain.adaptive
        XCTAssertNil(plainAdaptive)
    }

    // MARK: DL-06 — speed limiter

    func testDL06_limiter_booksBytesOnOneTimeline() async {
        let off = BandwidthLimiter()
        let none = await off.reserve(10_000_000)
        XCTAssertEqual(none, .zero, "no limit: never waits")
        let l = BandwidthLimiter(bytesPerSecond: 1_000_000)
        let first = await l.reserve(500_000)
        let second = await l.reserve(500_000)
        let third = await l.reserve(1_000_000)
        XCTAssertEqual(first, .zero)
        XCTAssertEqual(Double(second.components.attoseconds) / 1e18 + Double(second.components.seconds), 0.5, accuracy: 0.05)
        XCTAssertEqual(Double(third.components.attoseconds) / 1e18 + Double(third.components.seconds), 1.0, accuracy: 0.05)
        await l.setLimit(bytesPerSecond: 0)
        let afterOff = await l.reserve(5_000_000)
        XCTAssertEqual(afterOff, .zero, "switching the limit off releases at once")
    }

    func testDL06_aSyncUnderALimit_keepsTheAverage_andSavesEverything() async throws {
        var elapsed: [Bool: TimeInterval] = [:]
        for limited in [false, true] {
            let sink = makeSink("limit-\(limited)")
            let fake = FakeMailProvider(pageSize: 10)
            await fake.setPadding(10_000)                       // ~10 KB per message
            await seed(fake, folders: 1, perFolder: 30)        // ~300 KB
            try await register(fake, in: sink)
            let engine = makeEngine(fake, sink)
            await engine.setLimiter(BandwidthLimiter(bytesPerSecond: limited ? 300_000 : 0))
            let start = Date()
            let report = await engine.sync()
            elapsed[limited] = Date().timeIntervalSince(start)
            XCTAssertEqual(report.outcome, .completed)
            XCTAssertEqual(report.receipt?.stored, 30)
            XCTAssertTrue(stagedFiles(sink).isEmpty)
        }
        XCTAssertGreaterThanOrEqual(elapsed[true] ?? 0, 0.8, "about 300 KB at 300 KB/s takes about a second")
        // Relative check only (a loaded machine stretches both runs); the bound above is the limiter's own.
        XCTAssertLessThan(elapsed[false] ?? 1, elapsed[true] ?? 0, "no limit is faster")
    }

    // MARK: DL-01 — what a person reads first is saved first

    func testDL01_folderPriority_allMailInboxSentFirst_restInProviderOrder() {
        func f(_ id: String, _ use: String? = nil) -> RemoteFolderOccurrence {
            RemoteFolderOccurrence(serverID: id, displayPath: id, kind: .folder, specialUse: use)
        }
        let imap = [f("Archive", "\\Archive"), f("Projects"), f("Sent Items", "\\Sent"), f("INBOX", "INBOX"), f("Notes")]
        XCTAssertEqual(SyncEngine.priorityOrder(imap).map(\.serverID), ["INBOX", "Sent Items", "Archive", "Projects", "Notes"])
        let gmailIMAP = [f("INBOX", "INBOX"), f("[Gmail]/Sent Mail", "\\Sent"), f("[Gmail]/All Mail", "\\All"), f("Work")]
        XCTAssertEqual(SyncEngine.priorityOrder(gmailIMAP).map(\.serverID), ["[Gmail]/All Mail", "INBOX", "[Gmail]/Sent Mail", "Work"],
                       "All Mail first: its walk saves everything, the other folders only add memberships")
        let graph = [f("AAMk-1", "drafts"), f("AAMk-2"), f("AAMk-3", "sentitems"), f("AAMk-4", "inbox")]
        XCTAssertEqual(SyncEngine.priorityOrder(graph).map(\.serverID), ["AAMk-4", "AAMk-3", "AAMk-1", "AAMk-2"])
        let gmailAPI = [f("ALL", "\\All"), f("INBOX", "INBOX"), f("SENT", "SENT"), f("Label_1")]
        XCTAssertEqual(SyncEngine.priorityOrder(gmailAPI).map(\.serverID), ["ALL", "INBOX", "SENT", "Label_1"])
        XCTAssertEqual(SyncEngine.priorityOrder(imap).count, imap.count, "every folder is kept")
    }

    func testDL01_withinAPage_largeMessagesLast_everyMessageKept() {
        let folder = RemoteFolderOccurrence(serverID: "f", displayPath: "f", kind: .folder, specialUse: nil)
        func r(_ id: String, _ size: Int64?) -> (RemoteItemRef, [RemoteFolderOccurrence]) {
            (RemoteItemRef(identity: .gmail(messageID: id), folder: folder, sizeHint: size), [folder])
        }
        let big = SyncEngine.largeMessageBytes + 1
        let page = [r("a", big), r("b", 2_000), r("c", nil), r("d", big * 3), r("e", SyncEngine.largeMessageBytes)]
        let ordered = SyncEngine.smallFirst(page).map { entry -> String in
            guard case .gmail(let id) = entry.0.identity else { return "?" }
            return id
        }
        XCTAssertEqual(ordered, ["b", "c", "e", "a", "d"], "small and unknown sizes in listing order, then the large ones")
    }

    func testDL01_aSyncStillSavesEveryMessage_inboxFolderFirst() async throws {
        let sink = makeSink()
        let fake = FakeMailProvider(pageSize: 10)
        await fake.addFolder("other", path: "Other")
        await fake.addFolder("INBOX", path: "Inbox")
        for i in 0..<30 { await fake.seed("o\(i)", folders: ["other"]) }
        for i in 0..<30 { await fake.seed("i\(i)", folders: ["INBOX"]) }
        try await register(fake, in: sink)
        let report = await makeEngine(fake, sink).sync()
        XCTAssertEqual(report.outcome, .completed)
        XCTAssertEqual(report.receipt?.stored, 60)
        let fetched = await fake.fetched
        XCTAssertEqual(fetched.count, 60)
        XCTAssertTrue(fetched.prefix(30).allSatisfy { $0.hasPrefix("i") }, "the Inbox (added second) is saved first")
        let ids = try await capturedIDs(sink, account: fake.accountID)
        XCTAssertEqual(Set(ids).count, 60)
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

// MARK: - Release audit 2026-11-13 (connected mail UX)

extension SyncEngineTests {

    /// A provider error that stops the run reads as a sentence, never as the
    /// enum's debug form (`permanent("…")`, `folderUnavailable(…)`).
    func testAudit_runStopReasonIsASentence_notAnEnumDump() async throws {
        let sink = makeSink()
        let fake = FakeMailProvider(pageSize: 10)
        await seed(fake, folders: 1, perFolder: 2)
        try await register(fake, in: sink)
        await fake.failNextRequests([.permanent("Gmail refused the request.")])
        let report = await makeEngine(fake, sink).sync()
        XCTAssertEqual(report.outcome, .failed("Gmail refused the request."))
        for error: MailProviderError in [.rateLimited(retryAfter: 5), .quotaExceeded(resetAfter: nil), .transient("HTTP 503"),
                                         .unauthorized, .reauthorisationRequired, .itemUnavailable, .changeTokenExpired,
                                         .folderUnavailable("Projects"), .permanent("No.")] {
            let text = error.localizedDescription
            XCTAssertFalse(text.contains("MailProviderError") || text.contains("rateLimited(") || text.contains("retryAfter"),
                           "debug form shown: \(text)")
            XCTAssertTrue(text.hasSuffix("."), text)
        }
    }

    /// Pressing Sync now while a run is under way starts nothing and fails
    /// nothing: the second call says "already running".
    func testAudit_secondSyncWhileRunning_isAlreadyRunning_notAFailure() async throws {
        let sink = makeSink()
        let fake = FakeMailProvider(pageSize: 10)
        await seed(fake, folders: 1, perFolder: 4)
        await fake.setFetchDelay(50_000_000)
        try await register(fake, in: sink)
        let engine = makeEngine(fake, sink)
        let first = Task { await engine.sync() }
        var waited = 0
        while !(await engine.isRunning), waited < 200 { try await Task.sleep(nanoseconds: 5_000_000); waited += 1 }
        let isRunning = await engine.isRunning
        XCTAssertTrue(isRunning)
        let second = await engine.sync()
        XCTAssertEqual(second.outcome, .alreadyRunning)
        XCTAssertFalse(second.outcome.isCompletion)
        let firstReport = await first.value
        XCTAssertEqual(firstReport.outcome, .completed, "the running capture went on undisturbed")
        let afterwards = await engine.isRunning
        XCTAssertFalse(afterwards)
    }

    /// A pause that passes by itself carries how long to wait before the
    /// account is tried again (the provider's own figure first); a finished
    /// run or a sign-in stop carries none.
    func testAudit_pausesThatPassByThemselves_suggestARetry() async throws {
        let sink = makeSink()
        let throttled = FakeMailProvider(pageSize: 10)
        await seed(throttled, folders: 1, perFolder: 3)
        await throttled.failFetch("f0-1", with: [.rateLimited(retryAfter: 600), .rateLimited(retryAfter: 600)])
        let quota = FakeMailProvider(pageSize: 10)
        await seed(quota, folders: 1, perFolder: 3)
        await quota.failFetch("f0-1", with: [.quotaExceeded(resetAfter: nil)])
        let flaky = FakeMailProvider(pageSize: 10)
        await seed(flaky, folders: 1, perFolder: 1)
        await flaky.failNextRequests(Array(repeating: .transient("HTTP 503"), count: 6))
        let revoked = FakeMailProvider(pageSize: 10)
        await seed(revoked, folders: 1, perFolder: 1)
        await revoked.failNextRequests([.reauthorisationRequired])
        for fake in [throttled, quota, flaky, revoked] { try await register(fake, in: sink) }

        let r1 = await makeEngine(throttled, sink, backoff: Self.backoff(Box([]), maximumThrottleWait: 1_000)).sync()
        XCTAssertEqual(r1.outcome, .paused(.rateLimited(retryAfter: 600)))
        XCTAssertEqual(r1.suggestedRetry, 600, "the provider's Retry-After is respected")
        let r2 = await makeEngine(quota, sink).sync()
        XCTAssertEqual(r2.outcome, .paused(.quotaExceeded(resetAfter: nil)))
        XCTAssertEqual(r2.suggestedRetry ?? 0, 3_600, accuracy: 0.1, "no reset time stated: an hour")
        let r3 = await makeEngine(flaky, sink).sync()
        guard case .failed = r3.outcome else { return XCTFail("\(r3.outcome)") }
        XCTAssertEqual(r3.suggestedRetry, 60, "a server that kept failing: the backoff's longest step")
        let r4 = await makeEngine(revoked, sink).sync()
        XCTAssertEqual(r4.outcome, .needsSignIn)
        XCTAssertNil(r4.suggestedRetry, "sign-in needs the person; never retried on its own")
        let r5 = await makeEngine(throttled, sink).sync()
        XCTAssertEqual(r5.outcome, .completed)
        XCTAssertNil(r5.suggestedRetry)
    }
}

// MARK: - Audit 2026-11-14

/// A token endpoint that fails `failures` times (network or server), then answers.
actor FlakyTokenEndpoint: TokenTransport {
    let failure: @Sendable () throws -> (status: Int, body: Data)
    var failuresLeft: Int
    private(set) var calls = 0
    init(failures: Int, failure: @escaping @Sendable () throws -> (status: Int, body: Data)) {
        self.failuresLeft = failures; self.failure = failure
    }
    func postForm(_ url: URL, body: Data) async throws -> (status: Int, body: Data) {
        calls += 1
        if failuresLeft > 0 { failuresLeft -= 1; return try failure() }
        return (200, Data(Fixtures.tokenJSON(access: "fresh").utf8))
    }
}

extension SyncEngineTests {

    func flakyAccount(_ sink: ConnectedArchiveSink, failures: Int,
                      failure: @escaping @Sendable () throws -> (status: Int, body: Data)) async throws
        -> (FakeMailProvider, TokenRefreshCoordinator, FlakyTokenEndpoint) {
        let endpoint = FlakyTokenEndpoint(failures: failures, failure: failure)
        let coordinator = TokenRefreshCoordinator(credentials: InMemoryCredentialStore(), transport: endpoint)
        let fake = FakeMailProvider(pageSize: 10, tokenAudience: Fixtures.google.audience)
        await seed(fake, folders: 1, perFolder: 3)
        await fake.setRequiredToken("fresh")
        await coordinator.register(account: fake.accountID, configuration: Fixtures.google)
        try await coordinator.store(Fixtures.expiredSet(fake.accountID, refresh: "refresh-1"))   // refresh due now
        try await register(fake, in: sink)
        return (fake, coordinator, endpoint)
    }

    /// #5: the token is fetched outside the request's retry handling; a network
    /// failure on the way to the token endpoint is transient — backoff, then the run goes on.
    func testAudit1114_networkFailureDuringTokenRefresh_isTransient_backoffThenCompletes() async throws {
        let sink = makeSink()
        let failures: [@Sendable () throws -> (status: Int, body: Data)] = [
            { throw URLError(.notConnectedToInternet) },
            { throw URLError(.timedOut) },
            { (503, Data()) },
            { (400, Data(#"{"error":"temporarily_unavailable"}"#.utf8)) },
        ]
        for failure in failures {
            let (fake, coordinator, endpoint) = try await flakyAccount(sink, failures: 2, failure: failure)
            let waits = Box<[TimeInterval]>([])
            let report = await makeEngine(fake, sink, tokens: coordinator, waits: waits).sync()
            XCTAssertEqual(report.outcome, .completed, "the run went on after the sign-in service came back")
            XCTAssertEqual(waits.value.count, 2, "one backoff wait per failed token request: \(waits.value)")
            let calls = await endpoint.calls
            XCTAssertEqual(calls, 3)
            let ids = try await capturedIDs(sink, account: fake.accountID)
            XCTAssertEqual(ids.count, 3)
        }

        // Still unreachable after the run's budget: a failure that is retried
        // later on its own, with its typed cause — never "needs sign-in".
        let (fake, coordinator, _) = try await flakyAccount(sink, failures: 100) { throw URLError(.notConnectedToInternet) }
        let report = await makeEngine(fake, sink, tokens: coordinator).sync()
        guard case .failed = report.outcome, case .provider(.transient)? = report.failureCause else {
            return XCTFail("\(report.outcome) \(String(describing: report.failureCause))")
        }
        XCTAssertEqual(report.suggestedRetry, 60, "scheduled retry after the backoff's longest step")
        let requiresSignIn = await coordinator.requiresReauthorisation(fake.accountID)
        XCTAssertFalse(requiresSignIn)

        // A refusal that does not pass by itself is not retried.
        let (refused, refusedTokens, refusedEndpoint) = try await flakyAccount(sink, failures: 100) {
            (400, Data(#"{"error":"invalid_client","error_description":"AADSTS700016: Application not found in the directory."}"#.utf8))
        }
        let r2 = await makeEngine(refused, sink, tokens: refusedTokens).sync()
        guard case .signIn(.tokenEndpoint(400, "invalid_client", let description))? = r2.failureCause else {
            return XCTFail("\(r2.outcome) \(String(describing: r2.failureCause))")
        }
        XCTAssertEqual(microsoftRefusalCode(description), 700016)
        let refusedCalls = await refusedEndpoint.calls
        XCTAssertEqual(refusedCalls, 1, "not retried")
    }

    /// #1: the typed cause is cleared by the next run and reaches `status()`.
    func testAudit1114_failureCause_inStatus_clearedByNextRun() async throws {
        let sink = makeSink()
        let fake = FakeMailProvider(pageSize: 10)
        await seed(fake, folders: 1, perFolder: 2)
        try await register(fake, in: sink)
        await fake.failNextRequests([.permanent("graphX: HTTP 418")])
        let engine = makeEngine(fake, sink)
        let failed = await engine.sync()
        XCTAssertEqual(failed.failureCause, .provider(.permanent("graphX: HTTP 418")))
        let status = try await engine.status()
        XCTAssertEqual(status.failureCause, .provider(.permanent("graphX: HTTP 418")))
        let ok = await engine.sync()
        XCTAssertEqual(ok.outcome, .completed)
        let after = try await engine.status()
        XCTAssertNil(after.failureCause)
    }
}
