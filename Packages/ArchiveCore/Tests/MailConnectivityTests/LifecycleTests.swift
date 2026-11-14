//
//  LifecycleTests.swift
//  MailConnectivityTests
//
//  Plan v4 V4-12: external drives, account removal, subscription lapse,
//  backup / restore and upgrade — against a REAL archive (ConnectedArchiveSink
//  on a temporary store), FakeMailProvider and scripted submitters, with the
//  entitlement and the clock injected.
//    T22  archive drive vanishes mid-capture → pause naming the drive, never a
//         second archive, resume when it returns
//    T23  parallel downloads reserve room; disk full pauses before any
//         checkpoint advance; bounded spool; exact resume
//    T21/T44  account removal: tasks cancelled, outbox kept visible, only its
//         secrets / cache removed, archive kept; separate counted deletion
//    T44  subscription lapse (LIFE-06): archive usable, new paid activity
//         paused with an explanation, queued mail held, submitted mail still
//         reconciled, no stale automatic send after a long lapse
//    T45  backup carries drafts / outbox, never credentials; restored accounts
//         need sign-in; restored outbox waits for a decision
//    T46  old singleton settings migrate only by explicit choice; incomplete
//         earlier online captures listed and compared, never replaced
//

import XCTest
import Foundation
import CryptoKit
@testable import MailConnectivity
@testable import ArchiveCore

// MARK: - Doubles

final class LBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.withLock { stored } }
    func set(_ v: T) { lock.withLock { stored = v } }
    func mutate<R>(_ body: (inout T) -> R) -> R { lock.withLock { body(&stored) } }
}

/// Submits by script; records every submission.
final class ScriptedSubmitter: MessageSubmitter, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [SubmissionOutcome]
    private var _submitted: [String] = []
    init(_ script: [SubmissionOutcome] = []) { self.script = script }
    var submitted: [String] { lock.withLock { _submitted } }
    func push(_ outcome: SubmissionOutcome) { lock.withLock { script.append(outcome) } }
    func submit(_ message: OutboundMessage, checkpoint: @escaping SubmissionCheckpoint) async -> SubmissionOutcome {
        try? await checkpoint(.mayHaveReachedProvider)
        return lock.withLock {
            _submitted.append(message.messageID)
            return script.isEmpty ? .accepted(response: "250 OK", providerReference: nil, savedToSent: false) : script.removeFirst()
        }
    }
}

/// The app's per-account tasks.
actor FakeTaskControl: AccountTaskControl {
    private var tasks: [UUID: [Task<Void, Never>]] = [:]
    func start(_ account: UUID) -> Task<Void, Never> {
        let t = Task { while !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000) } }
        tasks[account, default: []].append(t)
        return t
    }
    func cancelTasks(account: UUID) async -> Int {
        let list = tasks.removeValue(forKey: account) ?? []
        for t in list { t.cancel() }
        for t in list { await t.value }
        return list.count
    }
}

struct DictionaryDefaults: LegacySettingsReading {
    let box: LBox<[String: Any]>
    func object(forKey key: String) -> Any? { box.value[key] }
    func removeObject(forKey key: String) { box.mutate { $0[key] = nil } }
}

// MARK: - Tests

final class LifecycleTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    // MARK: Helpers

    static let noWait = BackoffPolicy(base: 1, maximum: 1, transientAttempts: 3, jitter: { 0 }, sleep: { _ in await Task.yield() })
    static let plenty = StorageProbe(reserveBytes: 1_024, availableBytes: { _ in 1 << 40 })

    func record(_ id: UUID, _ display: String, provider: MailProviderKind = .gmail) -> ConnectedAccountRecord {
        ConnectedAccountRecord(accountID: id, provider: provider,
                               issuer: provider == .gmail ? "https://accounts.google.com" : "https://login.microsoftonline.com/common/v2.0",
                               displayIdentity: display, enabledModes: ["capture", "send"], connectionState: "connected",
                               createdAt: Date(), updatedAt: Date())
    }

    func engine(_ fake: FakeMailProvider, _ sink: ConnectedArchiveSink, storage: StorageProbe = LifecycleTests.plenty,
                permission: @escaping NetworkPermission = { _ in }) -> SyncEngine {
        SyncEngine(adapter: fake, sink: sink, scheduler: FairDownloadScheduler(totalSlots: 4), tokens: nil,
                   permission: permission, backoff: Self.noWait, storage: storage)
    }

    func seed(_ fake: FakeMailProvider, _ ids: [String], folder: String = "INBOX") async {
        await fake.addFolder(folder, path: "Inbox")
        for id in ids { await fake.seed(id, folders: [folder]) }
    }

    func capturedIDs(_ sink: ConnectedArchiveSink, account: UUID) async throws -> [String] {
        try await sink.store.remoteMessageDigests().filter { $0.account == account }.map { row in
            guard case .gmail(let id) = try ProviderMessageIdentity(key: row.key) else { return "?" }
            return id
        }
    }

    func stagedFiles(_ sink: ConnectedArchiveSink) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: sink.stagingDirectory.path)) ?? []).filter { $0.hasPrefix("stage-") }
    }

    struct Prepared { var draft: Draft; var composed: ComposedMessage }

    /// A saved draft of `account`, composed once.
    func prepare(_ account: MailAccount, store: DraftStore, subject: String) async throws -> Prepared {
        let me = SendingIdentity(accountID: account.id, address: try MailAddress(parsing: account.displayIdentity))
        var draft = Draft(accountID: account.id, senderIdentityID: me.id, to: [try MailAddress(parsing: "ann@example.net")],
                          subject: subject, plainBody: "Body of \(subject)")
        draft = try await store.save(draft)
        let composed = try await store.compose(draft.id, account: account, identities: [me], date: Date(timeIntervalSince1970: 1_800_000_000))
        return Prepared(draft: draft, composed: composed)
    }

    func gmailAccount(_ display: String) -> MailAccount {
        MailAccount(provider: .gmail, issuer: "https://accounts.google.com", displayIdentity: display,
                    enabledModes: [.capture, .send], connectionState: .connected)
    }

    // MARK: T22 — the archive drive vanishes mid-capture

    func testV412_T22_driveVanishesMidCapture_pausesNamingTheDrive_neverStartsASecondArchive_resumesWhenItReturns() async throws {
        let mount = dir.appendingPathComponent("drive", isDirectory: true)
        let storeDir = mount.appendingPathComponent("archive", isDirectory: true)
        let unplugged = dir.appendingPathComponent("unplugged", isDirectory: true)
        let sink = ConnectedArchiveSink(storeDirectory: storeDir)
        let fake = FakeMailProvider(pageSize: 5)
        await fake.setMaxConcurrent(1)
        await seed(fake, (0..<20).map { "m\($0)" })
        try await sink.saveAccount(record(fake.accountID, "asha@gmail.com"))
        let drive = try ArchiveDriveIdentity.of(storeDirectory: storeDir)
        XCTAssertNotNil(drive.volumeUUID, "a local APFS volume has a UUID")
        XCTAssertEqual(ArchiveDriveGuard.check(drive).isPresent, true)

        // The "drive" goes away while the 7th message is downloading.
        await fake.on(.beforeFetchNumber(7), [.run { try? FileManager.default.moveItem(at: mount, to: unplugged) }])
        let engine = engine(fake, sink, storage: .guarded(by: drive, reserveBytes: 1_024))
        let first = await engine.sync()
        XCTAssertEqual(first.outcome, .paused(.driveUnavailable))
        XCTAssertFalse(first.outcome.isCompletion)
        XCTAssertEqual(first.missingDrive, drive, "the pause names the drive")
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeDir.path), "nothing was written where the archive used to be")
        let missing = await engine.missingDrive
        XCTAssertEqual(missing?.volumeName, drive.volumeName)

        // While it is gone: no provider request, no fallback archive — not even into an empty folder at the old path.
        let requestsBefore = await fake.requests
        let again = await engine.sync()
        XCTAssertEqual(again.outcome, .paused(.driveUnavailable))
        let requestsAfter = await fake.requests
        XCTAssertEqual(requestsAfter, requestsBefore, "a missing drive pauses before the provider is touched")
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        XCTAssertEqual(ArchiveDriveGuard.check(drive), .archiveMissing)
        let decoy = await engine.sync()
        XCTAssertEqual(decoy.outcome, .paused(.driveUnavailable))
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeDir.appendingPathComponent("emails.db").path), "no second archive")
        XCTAssertThrowsError(try ArchiveDriveGuard.requirePresent(drive)) { error in
            XCTAssertTrue(error.localizedDescription.contains("no new archive was started"), error.localizedDescription)
        }
        try FileManager.default.removeItem(at: mount)
        // A different volume at the recorded path is refused too.
        var elsewhere = drive
        elsewhere.volumeUUID = "00000000-0000-0000-0000-000000000000"
        XCTAssertEqual(ArchiveDriveGuard.check(elsewhere).isPresent, false)

        // The drive returns: the monitor says so, the store reopens, capture resumes from its checkpoints.
        let monitor = ArchiveDriveMonitor(drive: drive)
        let stillGone = await monitor.poll()
        XCTAssertNil(stillGone)
        try FileManager.default.moveItem(at: unplugged, to: mount)
        let event = await monitor.poll()
        XCTAssertEqual(event, .returned)
        _ = try await monitor.reopen(sink)
        let resumed = await engine.sync()
        XCTAssertTrue(resumed.outcome.isCompletion, "\(resumed.outcome)")
        let ids = try await capturedIDs(sink, account: fake.accountID)
        XCTAssertEqual(ids.count, 20); XCTAssertEqual(Set(ids).count, 20, "nothing captured twice")
        let total = try await sink.store.totalCount()
        XCTAssertEqual(total, 20)
        for row in try await sink.store.remoteMessageDigests() {
            XCTAssertTrue(sink.store.blobStore.exists(BlobReference(digest: row.digest, length: 0)), "\(row.key) has its bytes")
        }
        let status = try await engine.status()
        XCTAssertNil(status.missingDrive)
    }

    func testV412_T22_statusTextNamesTheDrive() {
        let drive = ArchiveDriveIdentity(volumeUUID: "X", volumeName: "Archive SSD", mountPath: "/Volumes/Archive SSD",
                                         storePath: "/Volumes/Archive SSD/mailin", isRemovable: true)
        let empty = ConnectedCompleteness(accountID: UUID(),
                                          acquisition: .init(captured: 0, locallyDeleted: 0, remaining: 0, failed: 0, unavailable: 0,
                                                             inventoryKnown: false, reconciledTo: nil, reconciledAt: nil, removedOnServer: 0),
                                          preservation: .init(recordsWithBytes: 0, recordsMissingBytes: 0, bytes: 0, unreadable: 0),
                                          runs: .init(lastAttemptedAt: nil, lastSuccessfulAt: nil, lastSuccessfulStartedAt: nil))
        var status = CaptureStatus(accountID: UUID(), state: .paused(.driveUnavailable), completeness: empty, search: nil, export: nil)
        XCTAssertEqual(status.defaultText, "Capture paused: drive unavailable")
        status.missingDrive = drive
        XCTAssertEqual(status.defaultText, "Capture paused: reconnect the drive “Archive SSD” that holds the archive")
    }

    // MARK: T23 — room for parallel downloads, disk full, bounded spool

    func testV412_T23_parallelDownloadsReserveRoom_diskFullPausesBeforeCheckpoint_spoolBounded_resumeExact() async throws {
        let sink = ConnectedArchiveSink(storeDirectory: dir.appendingPathComponent("archive", isDirectory: true))
        let fake = FakeMailProvider(pageSize: 8)
        await fake.setMaxConcurrent(4)
        await fake.setFetchDelay(20_000_000)
        await seed(fake, (0..<16).map { "p\($0)" })
        try await sink.saveAccount(record(fake.accountID, "asha@gmail.com"))
        let size = Int64(FakeMailProvider.body("p0").count)
        let reserve: Int64 = 10_000
        // Room for three messages in flight (each staged AND published), not four.
        let free = LBox<Int64>(reserve + 3 * 2 * size + size)
        let spoolPeak = LBox(0)
        for n in 1...8 {
            await fake.on(.beforeFetchNumber(n), [.run { [sink] in
                let staged = ((try? FileManager.default.contentsOfDirectory(atPath: sink.stagingDirectory.path)) ?? []).filter { $0.hasPrefix("stage-") }.count
                spoolPeak.mutate { $0 = max($0, staged) }
            }])
        }
        let engine = engine(fake, sink, storage: StorageProbe(reserveBytes: reserve, availableBytes: { _ in free.value }))
        let paused = await engine.sync()
        XCTAssertEqual(paused.outcome, .paused(.diskFull(availableBytes: free.value)),
                       "four parallel downloads do not all fit: the fourth pauses the account")
        XCTAssertFalse(paused.outcome.isCompletion)
        XCTAssertEqual(paused.receipt?.state, .partial)
        XCTAssertTrue(stagedFiles(sink).isEmpty, "no staged bytes are left while paused")
        XCTAssertLessThanOrEqual(spoolPeak.value, 4, "the spool never holds more than the downloads in flight")
        let firstPage = try await sink.checkpoint(accountID: fake.accountID, scope: "enum:INBOX")
        XCTAssertNil(firstPage, "the page with unfinished items did not advance its cursor")
        let status = try await engine.status()
        XCTAssertEqual(status.defaultText, "Capture paused: not enough free space")

        free.set(1 << 40)
        let resumed = await engine.sync()
        XCTAssertEqual(resumed.outcome, .completed)
        let ids = try await capturedIDs(sink, account: fake.accountID)
        XCTAssertEqual(ids.count, 16); XCTAssertEqual(Set(ids).count, 16)
        XCTAssertTrue(stagedFiles(sink).isEmpty)
    }

    /// Found by the real disk-image rehearsal: the volume's free-space figure
    /// said "enough" while the blob publish failed with "not enough space";
    /// the run then FAILED. A write the volume refuses for space now pauses.
    func testV412_T23_writeRefusedForSpace_pausesEvenWhenTheFreeSpaceFigureIsOptimistic() async throws {
        let sink = ConnectedArchiveSink(storeDirectory: dir.appendingPathComponent("archive", isDirectory: true))
        let fake = FakeMailProvider(pageSize: 5)
        await fake.setMaxConcurrent(1)
        await seed(fake, (0..<6).map { "s\($0)" })
        try await sink.saveAccount(record(fake.accountID, "asha@gmail.com"))
        let refuse = LBox(true)
        let count = LBox(0)
        await sink.setFaultHook { boundary in
            guard boundary == .afterStaging else { return }
            let n = count.mutate { $0 += 1; return $0 }
            if refuse.value && n == 3 {
                let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
                throw BlobStoreError.write(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError,
                                                   userInfo: [NSUnderlyingErrorKey: posix]))
            }
        }
        let engine = engine(fake, sink)           // the probe always reports plenty of space
        let paused = await engine.sync()
        XCTAssertEqual(paused.outcome, .paused(.diskFull(availableBytes: 1 << 40)), "\(paused.outcome)")
        XCTAssertTrue(stagedFiles(sink).isEmpty)
        refuse.set(false)
        await sink.setFaultHook(nil)
        let resumed = await engine.sync()
        XCTAssertEqual(resumed.outcome, .completed)
        let ids = try await capturedIDs(sink, account: fake.accountID)
        XCTAssertEqual(Set(ids).count, 6); XCTAssertEqual(ids.count, 6)

        XCTAssertTrue(ArchiveWriteError.isOutOfSpace(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))))
        XCTAssertTrue(ArchiveWriteError.isOutOfSpace(SQLiteStoreError.step("database or disk is full")))
        XCTAssertTrue(ArchiveWriteError.isOutOfSpace(ConnectedArchiveError.volumeFull("x")))
        XCTAssertFalse(ArchiveWriteError.isOutOfSpace(BlobStoreError.writeFailed("permission denied")))
        XCTAssertFalse(ArchiveWriteError.isOutOfSpace(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
    }

    // MARK: T21 / T44 — account removal

    func testV412_accountRemoval_cancelsTasks_keepsOutboxVisible_removesOnlyItsSecrets_keepsArchive_othersUntouched() async throws {
        let storeDir = dir.appendingPathComponent("archive", isDirectory: true)
        let sink = ConnectedArchiveSink(storeDirectory: storeDir)
        let credentials = InMemoryCredentialStore()
        let registry = MailAccountRegistry(records: sink, credentials: credentials)
        let a = gmailAccount("a@gmail.com"), b = gmailAccount("b@gmail.com"), c = gmailAccount("c@gmail.com")
        for acct in [a, b, c] { try await registry.add(acct, secret: Data("secret-\(acct.displayIdentity)".utf8), kind: .oauthTokenSet) }
        let lifecycle = try ConnectedLifecycle(storeDirectory: storeDir, entitlement: { ConnectedEntitlement(plan: .active) })
        var fakes: [UUID: FakeMailProvider] = [:]
        for (acct, ids) in [(a, ["a1", "a2", "shared"]), (b, ["b1", "b2", "b3", "shared"]), (c, ["c1"])] {
            let fake = FakeMailProvider(accountID: acct.id)
            await seed(fake, ids)
            fakes[acct.id] = fake
            let r = await engine(fake, sink, permission: lifecycle.capturePermission { _ in }).sync()
            XCTAssertEqual(r.outcome, .completed)
        }

        // B's outbox: one queued (draft kept), one queued whose draft was discarded, one accepted, one uncertain. A has one queued.
        let drafts = try DraftStore(storeDirectory: storeDir)
        let clock = TestClock()
        let outbox = Outbox(store: try OutboxStore(storeDirectory: storeDir), permission: { _ in }, now: { clock.now })
        await outbox.setAdmission(lifecycle.outboxAdmission)
        let submitter = ScriptedSubmitter()
        await outbox.register(account: b.id, submitter: submitter)
        await outbox.register(account: a.id, submitter: submitter)
        let p1 = try await prepare(b, store: drafts, subject: "kept draft")
        let p2 = try await prepare(b, store: drafts, subject: "draft discarded")
        let p3 = try await prepare(b, store: drafts, subject: "accepted")
        let p4 = try await prepare(b, store: drafts, subject: "uncertain")
        let pa = try await prepare(a, store: drafts, subject: "a's mail")
        let op3 = try await outbox.enqueue(p3.composed, draft: p3.draft, route: .graphAPI)
        clock.advance(1)       // the outbox submits in queue order
        let op4 = try await outbox.enqueue(p4.composed, draft: p4.draft, route: .graphAPI)
        submitter.push(.accepted(response: "202 Accepted", providerReference: nil, savedToSent: false))
        submitter.push(.uncertain(reason: "connection lost after the request was sent"))
        try await outbox.runDue()
        let s3 = try await outbox.operation(op3.id).state.name, s4 = try await outbox.operation(op4.id).state.name
        XCTAssertEqual(s3, "accepted"); XCTAssertEqual(s4, "outcomeUncertain")
        let op1 = try await outbox.enqueue(p1.composed, draft: p1.draft, route: .graphAPI, undoDelay: 3_600)
        let op2 = try await outbox.enqueue(p2.composed, draft: p2.draft, route: .graphAPI, undoDelay: 3_600)
        let opA = try await outbox.enqueue(pa.composed, draft: pa.draft, route: .graphAPI, undoDelay: 3_600)
        try await drafts.discard(p2.draft.id)

        let tasks = FakeTaskControl()
        let taskB = await tasks.start(b.id)
        let taskA = await tasks.start(a.id)
        let coordinator = AccountRemovalCoordinator(registry: registry, sink: sink, outbox: outbox, drafts: drafts,
                                                    lifecycle: lifecycle, tasks: tasks)
        let plan = try await coordinator.plan(b.id)
        XCTAssertEqual(plan.outboxToKeep, 2); XCTAssertEqual(plan.outboxAwaitingOutcome, 2)
        XCTAssertEqual(plan.drafts, 3, "p1, p3, p4 (p2 was discarded)")
        XCTAssertEqual(plan.archive.records, 4)

        let report = try await coordinator.remove(b.id)
        XCTAssertEqual(report.tasksCancelled, 1)
        XCTAssertTrue(taskB.isCancelled); XCTAssertFalse(taskA.isCancelled, "A's work goes on")
        taskA.cancel()
        XCTAssertEqual(report.keptAsDrafts, [op1.id])
        XCTAssertEqual(report.keptInOutbox, [op2.id])
        XCTAssertEqual(Set(report.awaitingOutcome), [op3.id, op4.id])
        XCTAssertEqual(report.archivedRecordsKept, 4)
        XCTAssertGreaterThan(report.liveCacheRowsRemoved, 0)

        // Visible, never dropped or sent.
        for id in [op1.id, op2.id] {
            let op = try await outbox.operation(id)
            XCTAssertEqual(op.state.name, "cancelledBeforeSubmission")
            XCTAssertEqual(op.history.last?.note, "account removed; kept, not sent")
            let frozen = try await outbox.frozenMessage(id)
            XCTAssertFalse(frozen.isEmpty)
        }
        let keptDraft = try await drafts.draft(p1.draft.id)
        XCTAssertEqual(keptDraft.subject, "kept draft")
        let after3 = try await outbox.operation(op3.id).state.name, after4 = try await outbox.operation(op4.id).state.name
        XCTAssertEqual(after3, "accepted"); XCTAssertEqual(after4, "outcomeUncertain")
        clock.advance(7_200)
        let submittedBefore = submitter.submitted.count
        try await outbox.runDue()
        XCTAssertEqual(submitter.submitted.count, submittedBefore + 1, "only A's message is sent")
        XCTAssertEqual(submitter.submitted.last, pa.composed.messageID)
        let stateA = try await outbox.operation(opA.id).state.isAccepted
        XCTAssertTrue(stateA)

        // Secrets: only B's are gone.
        XCTAssertNil(try credentials.read(.oauthTokenSet, account: b.id))
        XCTAssertNotNil(try credentials.read(.oauthTokenSet, account: a.id))
        XCTAssertNotNil(try credentials.read(.oauthTokenSet, account: c.id))
        let states = Dictionary(uniqueKeysWithValues: try await registry.accounts().map { ($0.id, $0.connectionState) })
        XCTAssertEqual(states[b.id], .removed); XCTAssertEqual(states[a.id], .connected); XCTAssertEqual(states[c.id], .connected)
        // Live cache: B's cursors gone, A's kept; B's archive kept.
        for scope in [ChangeScope.account.checkpointScope, "enum:INBOX"] {
            let cpB = try await sink.checkpoint(accountID: b.id, scope: scope)
            let cpA = try await sink.checkpoint(accountID: a.id, scope: scope)
            XCTAssertNil(cpB, scope); XCTAssertNotNil(cpA, scope)
        }
        let total = try await sink.store.totalCount()
        XCTAssertEqual(total, 3 + 4 + 1)
        // A late request from B is refused; A still captures.
        let fakeB = try XCTUnwrap(fakes[b.id])
        let requestsB = await fakeB.requests
        let late = await engine(fakeB, sink, permission: lifecycle.capturePermission { _ in }).sync()
        guard case .notPermitted(let why) = late.outcome else { return XCTFail("\(late.outcome)") }
        XCTAssertTrue(why.contains("removed"), why)
        let requestsBAfter = await fakeB.requests
        XCTAssertEqual(requestsBAfter, requestsB)
        let again = await engine(try XCTUnwrap(fakes[a.id]), sink, permission: lifecycle.capturePermission { _ in }).sync()
        XCTAssertEqual(again.outcome, .completed)
    }

    func testV412_deleteAccountArchive_needsTheShownCount_skipsHolds_keepsSharedBlobs_neverTouchesOtherAccounts() async throws {
        let sink = ConnectedArchiveSink(storeDirectory: dir.appendingPathComponent("archive", isDirectory: true))
        let a = UUID(), b = UUID(), c = UUID()
        for (id, display, ids) in [(a, "a@gmail.com", ["a1", "shared"]), (b, "b@gmail.com", ["b1", "b2", "b3", "shared"]), (c, "c@gmail.com", ["c1"])] {
            try await sink.saveAccount(record(id, display))
            let fake = FakeMailProvider(accountID: id)
            await seed(fake, ids)
            let r = await engine(fake, sink).sync()
            XCTAssertEqual(r.outcome, .completed)
        }
        func email(_ account: UUID, _ gmailID: String) async throws -> UUID {
            let row = try await sink.store.remoteMessageDigests().first { $0.account == account && $0.key == (try? ProviderMessageIdentity.gmail(messageID: gmailID).key()) }
            return try XCTUnwrap(row?.emailID)
        }
        let heldB1 = try await email(b, "b1")
        try await sink.store.legalHoldsAdd([heldB1], matter: "Matter 7", sync: true)
        let blobOf: (String) -> URL = { sink.store.blobStore.url(for: SHA256.hash(data: FakeMailProvider.body($0)).map { String(format: "%02x", $0) }.joined()) }

        let summary = try await sink.accountArchiveSummary(accountID: b)
        XCTAssertEqual(summary.records, 4); XCTAssertEqual(summary.held, 1); XCTAssertEqual(summary.deletable, 3)
        XCTAssertEqual(summary.exclusiveBlobs, 2, "b2, b3"); XCTAssertEqual(summary.sharedBlobs, 1, "the blob A also holds")

        // A count that is not the one shown deletes nothing.
        do {
            _ = try await sink.deleteAccountArchive(accountID: b, confirmedCount: 2)
            XCTFail("a stale count must be refused")
        } catch let error as ConnectedLifecycleError {
            XCTAssertEqual(error, .countChanged(shown: 2, now: 3))
        }
        let untouched = try await sink.store.totalCount()
        XCTAssertEqual(untouched, 2 + 4 + 1)

        let deletion = try await sink.deleteAccountArchive(accountID: b, confirmedCount: summary.deletable)
        XCTAssertEqual(deletion.deletedEmailIDs.count, 3)
        XCTAssertEqual(deletion.heldKept, 1); XCTAssertEqual(deletion.blobsRemoved, 2); XCTAssertEqual(deletion.blobsKeptShared, 1)
        let total = try await sink.store.totalCount()
        XCTAssertEqual(total, 2 + 1 + 1, "A, C and B's held record remain")
        XCTAssertFalse(FileManager.default.fileExists(atPath: blobOf("b2").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: blobOf("b3").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: blobOf("shared").path), "A still references it")
        XCTAssertTrue(FileManager.default.fileExists(atPath: blobOf("b1").path), "the held record keeps its bytes")
        // A and C exactly as before: records, provenance, bytes.
        for (account, ids) in [(a, ["a1", "shared"]), (c, ["c1"])] {
            let captured = try await capturedIDs(sink, account: account)
            XCTAssertEqual(Set(captured), Set(ids))
            for id in ids {
                let e = try await email(account, id)
                let provenance = try await sink.provenance(emailID: e)
                XCTAssertEqual(provenance?.accountID, account)
                let full = try await sink.store.fullEmail(id: e)
                XCTAssertNotNil(full)
            }
        }
        let afterB = try await sink.accountArchiveSummary(accountID: b)
        XCTAssertEqual(afterB.records, 1); XCTAssertEqual(afterB.deletable, 0)
        let reconcile = try await sink.reconcileAfterRestart()
        XCTAssertEqual(reconcile.recordsMissingBytes, 0, "no remaining record points at a removed blob")
    }

    // MARK: T44 — subscription lapse

    func testV412_T44_lapse_archiveUsable_capturePausedWithReason_queuedHeld_submittedReconciled_noStaleAutoSend() async throws {
        let storeDir = dir.appendingPathComponent("archive", isDirectory: true)
        let sink = ConnectedArchiveSink(storeDirectory: storeDir)
        let account = gmailAccount("asha@gmail.com")
        try await sink.saveAccount(account.record)
        let clock = TestClock()
        let entitlement = LBox(ConnectedEntitlement(plan: .active))
        func lifecycle() throws -> ConnectedLifecycle {
            try ConnectedLifecycle(storeDirectory: storeDir, entitlement: { entitlement.value }, now: { clock.now }, staleAfter: 24 * 3_600)
        }
        var life = try lifecycle()
        let fake = FakeMailProvider(accountID: account.id)
        await seed(fake, ["m1", "m2", "m3"])
        let captured = await engine(fake, sink, permission: life.capturePermission { _ in }).sync()
        XCTAssertEqual(captured.outcome, .completed)

        let drafts = try DraftStore(storeDirectory: storeDir)
        let submitter = ScriptedSubmitter()
        let lookup = FakeLookup(find: { _ in .found(providerReference: "sent-1") })
        func makeOutbox(_ l: ConnectedLifecycle) async throws -> Outbox {
            let o = Outbox(store: try OutboxStore(storeDirectory: storeDir), permission: { _ in }, now: { clock.now })
            await o.register(account: account.id, submitter: submitter, lookup: lookup)
            await o.setAdmission(l.outboxAdmission)
            return o
        }
        var outbox = try await makeOutbox(life)
        // Submitted while active: accepted (Graph-style 202), not yet reconciled.
        let pSent = try await prepare(account, store: drafts, subject: "already submitted")
        let opSent = try await outbox.enqueue(pSent.composed, draft: pSent.draft, route: .graphAPI)
        try await outbox.runDue()
        let sentState = try await outbox.operation(opSent.id).state.name
        XCTAssertEqual(sentState, "accepted")
        // Queued, not yet due when the plan lapses.
        let pQueued = try await prepare(account, store: drafts, subject: "queued before the lapse")
        let opQueued = try await outbox.enqueue(pQueued.composed, draft: pQueued.draft, route: .graphAPI, undoDelay: 60)
        let pKeep = try await prepare(account, store: drafts, subject: "to keep as draft")
        let opKeep = try await outbox.enqueue(pKeep.composed, draft: pKeep.draft, route: .graphAPI, undoDelay: 60)
        XCTAssertEqual(submitter.submitted.count, 1)

        // The subscription lapses.
        let lapsedAt = clock.now
        entitlement.set(ConnectedEntitlement(plan: .lapsed, lapsedAt: lapsedAt))
        clock.advance(120)
        // Captured mail: readable, searchable, exportable; drafts editable — never gated.
        for activity in [ConnectedActivity.readArchive, .search, .export, .editDrafts, .reconcileSubmittedSend, .signIn, .removeAccount] {
            XCTAssertEqual(life.decide(activity), .allowed, "\(activity)")
        }
        let total = try await sink.store.totalCount()
        XCTAssertEqual(total, 3)
        let out = dir.appendingPathComponent("export", isDirectory: true)
        let ids = Set(try await sink.store.remoteMessageDigests().compactMap(\.emailID))
        let fts = FTSSearchIndex(shardsDirectory: dir.appendingPathComponent("fts", isDirectory: true))
        let store = sink.store
        _ = try await MainActor.run {
            ArchiveExportService(archive: ArchiveDataService(repository: EmailStoreRepository(store: store, fts: fts)))
        }.exportEMLFiles(scope: .explicit(ids), to: out)
        let exported = try FileManager.default.contentsOfDirectory(atPath: out.path).filter { $0.hasSuffix(".eml") }
        XCTAssertEqual(exported.count, 3, "export works while lapsed")
        var edited = try await drafts.draft(pKeep.draft.id)
        edited.plainBody += "\nedited during the lapse"
        _ = try await drafts.save(edited)

        // New paid activity pauses with the reason.
        XCTAssertEqual(life.decide(.capture), .paused(.subscriptionLapsed(.capture, since: lapsedAt)))
        let requests = await fake.requests
        let refused = await engine(fake, sink, permission: life.capturePermission { _ in }).sync()
        guard case .notPermitted(let why) = refused.outcome else { return XCTFail("\(refused.outcome)") }
        XCTAssertTrue(why.contains("subscription ended") && why.contains("Saved mail stays readable"), why)
        let requestsAfter = await fake.requests
        XCTAssertEqual(requestsAfter, requests, "nothing is requested from the provider")
        // Queued mail is held, visible; nothing is sent.
        try await outbox.runDue()
        XCTAssertEqual(submitter.submitted.count, 1)
        let held = await outbox.heldOperations()
        XCTAssertEqual(held[opQueued.id], .sendingPaused(.subscriptionLapsed(.send, since: lapsedAt)))
        XCTAssertTrue(held[opQueued.id]?.defaultText.contains("Not sent yet") == true)
        let overview = try await ConnectedLifecycleOverview.make(lifecycle: life, drafts: drafts, outbox: outbox)
        XCTAssertEqual(Set(overview.waitingToSend), [opQueued.id, opKeep.id])
        XCTAssertEqual(overview.awaitingReconciliation, [opSent.id])
        XCTAssertEqual(overview.drafts, 3, "every draft stays listed")
        // The already-submitted send is still reconciled (maintenance).
        let reconciled = try await outbox.reconcile(opSent.id)
        XCTAssertEqual(reconciled.state.name, "sentReconciled")

        // Ten days later the plan is renewed: the stale queued messages wait for the user.
        clock.advance(10 * 86_400)
        entitlement.set(ConnectedEntitlement(plan: .active))
        try await outbox.runDue()
        XCTAssertEqual(submitter.submitted.count, 1, "no stale message is sent automatically after a long lapse")
        let decisions = life.pendingDecisions()
        guard case .decisionNeededAfterLapse(_, let lapsedFor)? = decisions[opQueued.id] else { return XCTFail("\(decisions)") }
        XCTAssertGreaterThanOrEqual(lapsedFor, 10 * 86_400)
        XCTAssertTrue(decisions[opQueued.id]?.needsUserDecision == true)

        // A restart cannot turn the decision back into an automatic send.
        life = try lifecycle()
        outbox = try await makeOutbox(life)
        try await outbox.runDue()
        XCTAssertEqual(submitter.submitted.count, 1)
        XCTAssertEqual(Set(life.pendingDecisions().keys), [opQueued.id, opKeep.id])

        // The user decides: keep one as a draft, send the other.
        let kept = try await life.keepAsDraft(opKeep.id, outbox: outbox)
        XCTAssertEqual(kept.state.name, "cancelledBeforeSubmission")
        let keptDraft = try await drafts.draft(pKeep.draft.id)
        XCTAssertTrue(keptDraft.plainBody.contains("edited during the lapse"))
        try life.release(opQueued.id)
        try await outbox.runDue()
        XCTAssertEqual(submitter.submitted, [pSent.composed.messageID, pQueued.composed.messageID])

        // A short lapse (under a day) does not need a decision.
        let pShort = try await prepare(account, store: drafts, subject: "short lapse")
        let opShort = try await outbox.enqueue(pShort.composed, draft: pShort.draft, route: .graphAPI, undoDelay: 60)
        entitlement.set(ConnectedEntitlement(plan: .lapsed, lapsedAt: clock.now))
        clock.advance(3_600)
        try await outbox.runDue()
        XCTAssertEqual(submitter.submitted.count, 2)
        entitlement.set(ConnectedEntitlement(plan: .active))
        try await outbox.runDue()
        XCTAssertEqual(submitter.submitted.last, pShort.composed.messageID)
        let shortState = try await outbox.operation(opShort.id).state.isAccepted
        XCTAssertTrue(shortState)
        XCTAssertEqual(life.lapses.count, 2)
        XCTAssertTrue(life.lapses.allSatisfy { $0.end != nil })

        // A plan that does not treat sending as paid never holds it.
        let free = ConnectedEntitlement(plan: .free, paidActivities: [.capture])
        entitlement.set(free)
        XCTAssertEqual(life.decide(.send), .allowed)
        XCTAssertEqual(life.decide(.capture), .paused(.notInPlan(.capture)))
    }

    // MARK: T45 — backup / restore with drafts and outbox, never credentials

    func testV412_T45_backupCarriesDraftsAndOutboxButNoCredentials_restoredAccountsNeedSignIn_restoredOutboxWaits() async throws {
        let access = "ya29.SECRET-ACCESS-\(UUID().uuidString)"
        let refresh = "1//SECRET-REFRESH-\(UUID().uuidString)"
        let smtpPassword = "smtp-SECRET-\(UUID().uuidString)"
        let storeDir = dir.appendingPathComponent("archive", isDirectory: true)
        let sink = ConnectedArchiveSink(storeDirectory: storeDir)
        let credentials = InMemoryCredentialStore()
        let registry = MailAccountRegistry(records: sink, credentials: credentials)
        let account = gmailAccount("asha@gmail.com")
        try await registry.add(account, secret: try OAuthTokenSet(
            accountID: account.id, issuer: account.issuer, audience: "https://gmail.googleapis.com/", accessToken: access,
            refreshToken: refresh, expiresAt: Date().addingTimeInterval(3_600), scopes: []).encoded(), kind: .oauthTokenSet)
        try credentials.write(Data(smtpPassword.utf8), kind: .password, account: account.id)
        let fake = FakeMailProvider(accountID: account.id)
        await seed(fake, ["m1"])
        let captured = await engine(fake, sink).sync()
        XCTAssertEqual(captured.outcome, .completed)

        let drafts = try DraftStore(storeDirectory: storeDir)
        let lifecycle = try ConnectedLifecycle(storeDirectory: storeDir, entitlement: { ConnectedEntitlement(plan: .active) })
        let clock = TestClock()
        let submitter = ScriptedSubmitter()
        let outbox = Outbox(store: try OutboxStore(storeDirectory: storeDir), permission: { _ in }, now: { clock.now })
        await outbox.register(account: account.id, submitter: submitter)
        await outbox.setAdmission(lifecycle.outboxAdmission)
        let pAccepted = try await prepare(account, store: drafts, subject: "accepted before backup")
        let opAccepted = try await outbox.enqueue(pAccepted.composed, draft: pAccepted.draft, route: .graphAPI)
        try await outbox.runDue()
        let pQueued = try await prepare(account, store: drafts, subject: "queued at backup")
        let opQueued = try await outbox.enqueue(pQueued.composed, draft: pQueued.draft, route: .graphAPI, undoDelay: 600)
        var withAttachment = try await prepare(account, store: drafts, subject: "draft with attachment").draft
        let attachmentBytes = Data((0..<4_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        withAttachment = try await drafts.addAttachment(DraftAttachmentPayload(filename: "plan.pdf", mimeType: "application/pdf", data: attachmentBytes), to: withAttachment)

        let backup = dir.appendingPathComponent("backup", isDirectory: true)
        let inventory = try await ArchiveBackup.create(store: sink.store, to: backup)
        let connected = inventory.files.filter { $0.kind == "connected" }.map(\.path)
        XCTAssertTrue(connected.contains { $0.hasPrefix("ConnectedDrafts/") }, "\(connected)")
        XCTAssertTrue(connected.contains { $0.hasPrefix("ConnectedOutbox/") && $0.hasSuffix("message.eml") })
        XCTAssertTrue(connected.contains { $0 == "ConnectedLifecycle/lifecycle.json" })
        XCTAssertTrue(inventory.omitted.contains { $0.contains("credentials") })
        try assertNoSecret(in: backup, secrets: [access, refresh, smtpPassword])

        // A different machine: clean folder; this Keychain HAS a stale secret for the account — the
        // restored record still asks to sign in again, because the state is marked in the database.
        let restoredDir = dir.appendingPathComponent("restored", isDirectory: true)
        try ArchiveBackup.restore(backup: backup, intoStoreDirectory: restoredDir, mode: .cleanProfile)
        let otherKeychain = InMemoryCredentialStore()
        try otherKeychain.write(Data("stale".utf8), kind: .oauthTokenSet, account: account.id)
        let restoredSink = ConnectedArchiveSink(storeDirectory: restoredDir)
        let restoredRegistry = MailAccountRegistry(records: restoredSink, credentials: otherKeychain)
        let restoredAccounts = try await restoredRegistry.accounts()
        XCTAssertEqual(restoredAccounts.map(\.connectionState), [.needsReauthorisation])
        let restoredLifecycle = try ConnectedLifecycle(storeDirectory: restoredDir, entitlement: { ConnectedEntitlement(plan: .active) })
        let report = try await ConnectedRestore.prepare(storeDirectory: restoredDir, registry: restoredRegistry, lifecycle: restoredLifecycle)
        XCTAssertEqual(report.accountsNeedingSignIn, [account.id])
        XCTAssertEqual(report.outboxHeldForDecision, [opQueued.id])
        XCTAssertEqual(report.outboxAwaitingReconciliation, [opAccepted.id])
        XCTAssertEqual(report.drafts, 3)
        XCTAssertTrue(report.unreadable.isEmpty)
        let restoredDrafts = try DraftStore(storeDirectory: restoredDir)
        let restoredDraft = try await restoredDrafts.draft(withAttachment.id)
        let bytes = try await restoredDrafts.bytes(of: try XCTUnwrap(restoredDraft.attachments.first), in: withAttachment.id)
        XCTAssertEqual(bytes, attachmentBytes)

        // Signed in again on the new machine: the restored queued message still waits for a decision.
        let restoredSubmitter = ScriptedSubmitter()
        let restoredOutbox = Outbox(store: try OutboxStore(storeDirectory: restoredDir), permission: { _ in }, now: { clock.now.addingTimeInterval(3_600) })
        await restoredOutbox.register(account: account.id, submitter: restoredSubmitter)
        await restoredOutbox.setAdmission(restoredLifecycle.outboxAdmission)
        try await restoredOutbox.runDue()
        XCTAssertTrue(restoredSubmitter.submitted.isEmpty, "a restored message is never sent automatically")
        let held = await restoredOutbox.heldOperations()
        guard case .restoredFromBackup? = held[opQueued.id] else { return XCTFail("\(held)") }
        XCTAssertEqual(restoredLifecycle.pendingDecisions()[opQueued.id]?.needsUserDecision, true)
        let total = try await restoredSink.store.totalCount()
        XCTAssertEqual(total, 1, "the archive works without any credential")
    }

    func assertNoSecret(in folder: URL, secrets: [String], file: StaticString = #filePath, line: UInt = #line) throws {
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]))
        var scanned = 0
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let data = try Data(contentsOf: url)
            scanned += 1
            for secret in secrets {
                XCTAssertNil(data.range(of: Data(secret.utf8)), "\(url.path) contains a credential", file: file, line: line)
            }
        }
        XCTAssertGreaterThan(scanned, 5, file: file, line: line)
    }

    // MARK: T46 — upgrade

    func testV412_T46_oldSingletonSettings_migrateOnlyByExplicitChoice_neverDeleted() async throws {
        let storeDir = dir.appendingPathComponent("archive", isDirectory: true)
        let sink = ConnectedArchiveSink(storeDirectory: storeDir)
        let credentials = InMemoryCredentialStore()
        let registry = MailAccountRegistry(records: sink, credentials: credentials)
        let oldDraft = try JSONEncoder().encode(["to": "Ann <ann@example.net>, bob@example.org", "cc": "", "bcc": "hidden@example.com",
                                                 "subject": "Old draft", "body": "Typed before v4", "from": "me@old.example"])
        let box = LBox<[String: Any]>(["compose_draft": oldDraft, "imap_server": "imap.old.example", "imap_port": 993,
                                       "imap_username": "me@old.example", "smtp_server": "smtp.old.example", "smtp_port": 465,
                                       "smtp_username": "me@old.example", "smtp_from": "me@old.example"])
        let inventory = LegacySettingsInventory(defaults: DictionaryDefaults(box: box))
        let items = inventory.items()
        XCTAssertEqual(Set(items.map(\.key)), ["compose_draft", "imap_server", "imap_port", "imap_username",
                                               "smtp_server", "smtp_port", "smtp_username", "smtp_from"])
        let first = gmailAccount("first@gmail.com"), second = gmailAccount("second@gmail.com")
        for a in [first, second] { try await registry.save(a) }
        let drafts = try DraftStore(storeDirectory: storeDir)
        let listed = await drafts.drafts()
        XCTAssertTrue(listed.drafts.isEmpty, "nothing is migrated on upgrade")

        // Refused without a confirmation naming this account and exactly the key.
        do {
            _ = try await inventory.migrateComposeDraft(to: second, confirmation: .init(accountID: first.id, keys: ["compose_draft"]), into: drafts)
            XCTFail("another account's confirmation must be refused")
        } catch let e as LegacySettingError { XCTAssertEqual(e, .notConfirmed) }
        do {
            _ = try await inventory.migrateComposeDraft(to: second, confirmation: .init(accountID: second.id, keys: []), into: drafts)
            XCTFail("an empty confirmation must be refused")
        } catch let e as LegacySettingError { XCTAssertEqual(e, .notConfirmed) }
        let migrated = try await inventory.migrateComposeDraft(to: second, confirmation: .init(accountID: second.id, keys: ["compose_draft"]), into: drafts)
        XCTAssertEqual(migrated.accountID, second.id)
        XCTAssertNil(migrated.senderIdentityID, "the sender is chosen by the user, never taken from the old text")
        XCTAssertEqual(migrated.to.map(\.normalizedKey), ["ann@example.net", "bob@example.org"])
        XCTAssertEqual(migrated.bcc.map(\.normalizedKey), ["hidden@example.com"])
        XCTAssertEqual(migrated.subject, "Old draft"); XCTAssertEqual(migrated.plainBody, "Typed before v4")
        XCTAssertNotNil(box.value["compose_draft"], "the old setting is kept (rule 1)")

        // IMAP: proposed, refused for a Gmail account, saved only when confirmed, never with a password.
        let proposed = try XCTUnwrap(inventory.proposedIMAPAccount())
        XCTAssertEqual(proposed.host, "imap.old.example"); XCTAssertEqual(proposed.port, 993); XCTAssertEqual(proposed.loginName, "me@old.example")
        do {
            _ = try await inventory.migrateIMAPSettings(to: first, confirmation: .init(accountID: first.id, keys: Set(LegacySettingsInventory.imapKeys)), registry: registry)
            XCTFail("IMAP settings cannot go to a Gmail account")
        } catch let e as LegacySettingError { XCTAssertEqual(e, .providerMismatch) }
        let imap = try await inventory.migrateIMAPSettings(to: proposed, confirmation: .init(accountID: proposed.id, keys: Set(LegacySettingsInventory.imapKeys)), registry: registry)
        let imapState = try await registry.account(imap.id).connectionState
        XCTAssertEqual(imapState, .needsReauthorisation)
        XCTAssertNil(try credentials.read(.password, account: imap.id))
        let smtp = try inventory.confirmedSMTPSettings(for: imap, confirmation: .init(accountID: imap.id, keys: Set(LegacySettingsInventory.smtpKeys)))
        XCTAssertEqual(smtp.settings.host, "smtp.old.example"); XCTAssertEqual(smtp.settings.security, .implicitTLS)
        XCTAssertThrowsError(try inventory.confirmedSMTPSettings(for: imap, confirmation: .init(accountID: first.id, keys: Set(LegacySettingsInventory.smtpKeys))))
        // Retiring is separate and explicit.
        XCTAssertEqual(inventory.items().count, 8)
        inventory.retire(items.filter { $0.purpose == .composeDraft })
        XCTAssertEqual(inventory.items().count, 7)
    }

    /// A record as the pre-v26 `ingestEmails` path stored it (no source, no account).
    func oldOnlineRecord(gmailID: String, rawSource: String, tags: [String], body: String? = nil) throws -> MBOXParser.RawEmail {
        var email = try MBOXParser.processRawMessage(String(decoding: FakeMailProvider.body(gmailID), as: UTF8.self), senderEmail: "")
        email.rawSource = rawSource
        email.tags = tags
        if let body { email.plainBody = body }
        return email
    }

    func testV412_T46_incompleteOnlineCaptures_listedPageByPage_recaptureComparedNeverReplaced() async throws {
        let storeDir = dir.appendingPathComponent("archive", isDirectory: true)
        let sink = ConnectedArchiveSink(storeDirectory: storeDir)
        let lifecycle = try ConnectedLifecycle(storeDirectory: storeDir, entitlement: { ConnectedEntitlement(plan: .active) })
        let g1 = try oldOnlineRecord(gmailID: "g1", rawSource: "", tags: ["INBOX", "CATEGORY_UPDATES"])
        let g2 = try oldOnlineRecord(gmailID: "g2", rawSource: "", tags: ["INBOX"], body: "Body g2 as the old connector extracted it")
        let g3 = try oldOnlineRecord(gmailID: "g3", rawSource: "", tags: ["Label_42"])
        let outlook = try oldOnlineRecord(gmailID: "o1", rawSource: "From: Asha <asha@example.com>\r\nSubject: Message o1\r\n\r\nBody o1 end", tags: ["Outlook"])
        var unknown = try oldOnlineRecord(gmailID: "u1", rawSource: "", tags: [])
        unknown.headers["Message-ID"] = nil
        let complete = try oldOnlineRecord(gmailID: "s1", rawSource: String(decoding: FakeMailProvider.body("s1"), as: UTF8.self), tags: [])
        try await sink.store.insertBatch([g1, g2, g3, outlook, unknown, complete], sourceFileHash: nil, accountID: nil, batchSize: 200, progress: nil)

        // Listed page by page (page size 1 proves every page is read), counted by kind; complete records not listed.
        let planner = LegacyRecapturePlanner(sink: sink, lifecycle: lifecycle, pageSize: 1)
        let seen = LBox<[UUID]>([])
        let inventory = try await planner.inventory { item in seen.mutate { $0.append(item.emailID) } }
        XCTAssertEqual(inventory, LegacyCaptureInventory(gmailWithoutSource: 3, outlookPseudoSource: 1, noSourceUnknownOrigin: 1))
        XCTAssertEqual(Set(seen.value), [g1.id, g2.id, g3.id, outlook.id, unknown.id])
        XCTAssertFalse(seen.value.contains(complete.id))

        let account = gmailAccount("asha@gmail.com")
        try await sink.saveAccount(account.record)
        let old = try await sink.legacyOnlineCaptures(after: nil, limit: 100)
        let oldG1 = try XCTUnwrap(old.first { $0.emailID == g1.id }), oldG2 = try XCTUnwrap(old.first { $0.emailID == g2.id })
        let before = try await planner.compare(oldG1, account: account)
        XCTAssertEqual(before.verdict, .notRecapturedYet)
        do {
            _ = try await planner.compare(try XCTUnwrap(old.first { $0.emailID == outlook.id }), account: account)
            XCTFail("an old Outlook record is not compared with a Gmail account")
        } catch let e as LegacyRecaptureError { XCTAssertEqual(e, .providerMismatch(.outlookPseudoSource, .gmail)) }
        let noID = try await planner.compare(try XCTUnwrap(old.first { $0.emailID == unknown.id }), account: account)
        XCTAssertEqual(noID.verdict, .noMessageID)

        // Source-based recapture: a normal capture of the chosen account.
        let fake = FakeMailProvider(accountID: account.id)
        await seed(fake, ["g1", "g2"])
        let run = await engine(fake, sink).sync()
        XCTAssertEqual(run.outcome, .completed)
        let total = try await sink.store.totalCount()
        XCTAssertEqual(total, 6 + 2, "the recaptured copies are added; nothing old is replaced")

        let same = try await planner.compare(oldG1, account: account)
        guard case .recaptured(let newG1, let d1) = same.verdict else { return XCTFail("\(same.verdict)") }
        XCTAssertEqual(d1, [], "the same content, now with its real source")
        XCTAssertNil(same.old.sourceSHA256)
        XCTAssertEqual(same.recaptured?.sourceSHA256, SHA256.hash(data: FakeMailProvider.body("g1")).map { String(format: "%02x", $0) }.joined())
        let differs = try await planner.compare(oldG2, account: account)
        guard case .recaptured(_, let d2) = differs.verdict else { return XCTFail("\(differs.verdict)") }
        XCTAssertEqual(d2, [.body], "the conflicting original is kept for comparison")

        try planner.decide(old: g1.id, recaptured: newG1, choice: .preferRecaptured)
        let reopened = try ConnectedLifecycle(storeDirectory: storeDir, entitlement: { ConnectedEntitlement(plan: .active) })
        XCTAssertEqual(reopened.recaptureDecision(old: g1.id)?.choice, .preferRecaptured)
        let oldStill = try await sink.store.fullEmail(id: g1.id)
        XCTAssertEqual(oldStill?.headers["Subject"], g1.headers["Subject"], "the old record is untouched")
        let g2Still = try await sink.store.fullEmail(id: g2.id)
        XCTAssertEqual(g2Still?.plainBody, "Body g2 as the old connector extracted it")
    }
}

// MARK: - Lifecycle audit 2026-11-14

/// A restore into this device's running archive, a removed account added
/// again, Delete All Data, the login check before an IMAP account is saved.
final class LifecycleAuditTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("lifecycle-audit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func gmail(_ display: String) -> MailAccount {
        MailAccount(provider: .gmail, issuer: "https://accounts.google.com", displayIdentity: display,
                    enabledModes: [.capture, .send], connectionState: .connected)
    }

    private func record(_ id: UUID) -> ConnectedAccountRecord {
        ConnectedAccountRecord(accountID: id, provider: .gmail, issuer: "https://accounts.google.com",
                               displayIdentity: "asha@gmail.com", enabledModes: ["capture"],
                               connectionState: "connected", createdAt: Date(), updatedAt: Date())
    }

    private func capture(_ fake: FakeMailProvider, _ sink: ConnectedArchiveSink) async -> SyncRunReport {
        await SyncEngine(adapter: fake, sink: sink, scheduler: FairDownloadScheduler(totalSlots: 2), tokens: nil, permission: { _ in },
                         backoff: LifecycleTests.noWait, storage: LifecycleTests.plenty).sync()
    }

    /// The in-app restore keeps this device's Keychain: without `requireSignIn`
    /// the restored accounts would connect at once with the old secrets.
    func testRestoreIntoRunningArchive_accountsNeedSignIn_queuedOutboxHeld() async throws {
        let storeDir = dir.appendingPathComponent("archive", isDirectory: true)
        let sink = ConnectedArchiveSink(storeDirectory: storeDir)
        let credentials = InMemoryCredentialStore()
        let registry = MailAccountRegistry(records: sink, credentials: credentials)
        let account = gmail("asha@gmail.com")
        try await registry.add(account, secret: Data("tokens".utf8), kind: .oauthTokenSet)
        let lifecycle = try ConnectedLifecycle(storeDirectory: storeDir, entitlement: { ConnectedEntitlement(plan: .active) })
        let drafts = try DraftStore(storeDirectory: storeDir)
        let me = SendingIdentity(accountID: account.id, address: try MailAddress(parsing: account.displayIdentity))
        var draft = Draft(accountID: account.id, senderIdentityID: me.id, to: [try MailAddress(parsing: "ann@example.net")], subject: "queued")
        draft = try await drafts.save(draft)
        let composed = try await drafts.compose(draft.id, account: account, identities: [me], date: Date())
        let outbox = Outbox(store: try OutboxStore(storeDirectory: storeDir), permission: { _ in })
        let queued = try await outbox.enqueue(composed, draft: draft, route: .gmailAPI)

        let untouched = try await ConnectedRestore.prepare(storeDirectory: storeDir, registry: registry, lifecycle: lifecycle)
        XCTAssertEqual(untouched.accountsNeedingSignIn, [], "the default (clean profile) relies on the restore's own marking")

        let report = try await ConnectedRestore.prepare(storeDirectory: storeDir, registry: registry, lifecycle: lifecycle, requireSignIn: true)
        XCTAssertEqual(report.accountsNeedingSignIn, [account.id])
        XCTAssertEqual(report.outboxHeldForDecision, [queued.id])
        let state = try await registry.account(account.id).connectionState
        XCTAssertEqual(state, .needsReauthorisation, "stays marked although the Keychain still has the secret")

        let submitter = ScriptedSubmitter()
        await outbox.register(account: account.id, submitter: submitter)
        await outbox.setAdmission(lifecycle.outboxAdmission)
        try await outbox.runDue()
        XCTAssertTrue(submitter.submitted.isEmpty, "a restored message is never sent automatically")
    }

    func testRemovedAccountAddedAgain_mayRunAgain_persisted() throws {
        let id = UUID()
        let lifecycle = try ConnectedLifecycle(storeDirectory: dir, entitlement: { ConnectedEntitlement(plan: .active) })
        try lifecycle.markAccountRemoved(id)
        XCTAssertEqual(lifecycle.decide(.capture, account: id), .paused(.accountRemoved))
        try lifecycle.clearAccountRemoved(id)
        XCTAssertEqual(lifecycle.decide(.capture, account: id), .allowed)
        let reread = try ConnectedLifecycle(storeDirectory: dir, entitlement: { ConnectedEntitlement(plan: .active) })
        XCTAssertFalse(reread.isRemoved(id))
    }

    /// Delete All Data: no connected row survives, so an account added again
    /// captures its mail again (old identities would read "deleted here").
    func testEraseConnectedRows_emptiesEveryTable_andAReaddedAccountCapturesAgain() async throws {
        let sink = ConnectedArchiveSink(storeDirectory: dir.appendingPathComponent("archive", isDirectory: true))
        let id = UUID()
        try await sink.saveAccount(record(id))
        let fake = FakeMailProvider(accountID: id)
        await fake.addFolder("INBOX", path: "Inbox")
        for m in ["m1", "m2"] { await fake.seed(m, folders: ["INBOX"]) }
        let first = await capture(fake, sink)
        XCTAssertEqual(first.receipt?.stored, 2)

        // What erase-all does to the store: every mail row, then the connected rows.
        try await sink.store.clearAll()
        let removed = try await sink.eraseAllConnectedRows()
        XCTAssertGreaterThan(removed, 0)
        let counts = try await sink.store.connectedTableCounts()
        XCTAssertEqual(counts.values.reduce(0, +), 0, "\(counts)")

        try await sink.saveAccount(record(id))
        let again = await capture(fake, sink)
        XCTAssertEqual(again.receipt?.stored, 2, "the re-added account saved its mail again")
        let total = try await sink.store.totalCount()
        XCTAssertEqual(total, 2)
    }

    func testDeletableRecordIDs_areExactlyWhatTheAccountDeletionRemoves() async throws {
        let sink = ConnectedArchiveSink(storeDirectory: dir.appendingPathComponent("archive", isDirectory: true))
        let id = UUID()
        try await sink.saveAccount(record(id))
        let fake = FakeMailProvider(accountID: id)
        await fake.addFolder("INBOX", path: "Inbox")
        for m in ["m1", "m2", "m3"] { await fake.seed(m, folders: ["INBOX"]) }
        _ = await capture(fake, sink)
        let listed = try await sink.deletableRecordIDs(accountID: id)
        XCTAssertEqual(listed.count, 3)
        let deletion = try await sink.deleteAccountArchive(accountID: id, confirmedCount: listed.count)
        XCTAssertEqual(Set(listed), Set(deletion.deletedEmailIDs))
        let after = try await sink.deletableRecordIDs(accountID: id)
        XCTAssertEqual(after, [])
    }

    // MARK: Login check

    func testSMTPLoginCheck_authenticatesOverTLS_sendsNoMessage_refusalIsStated() async throws {
        let ok = try ScriptedSMTPServer(behavior: SMTPServerBehavior())
        defer { ok.stop() }
        let settings = SMTPServerSettings(host: "127.0.0.1", port: Int(ok.port), security: .startTLS, commandTimeout: 5)
        try await SMTPLoginCheck.verify(settings, username: "me@alpha.example", password: "pw-1", accountID: UUID(),
                                        connector: SimulatedTLSConnector(), permission: { _ in })
        XCTAssertTrue(ok.allLines.contains { $0.hasPrefix("AUTH") })
        XCTAssertFalse(ok.allLines.contains { $0.hasPrefix("MAIL") }, "no message is sent by the check")
        XCTAssertTrue(ok.allLines.contains("QUIT"))

        let refusing = try ScriptedSMTPServer(script: { c in
            c.reply("220 mail.test ESMTP")
            while let line = c.readLine() {
                let upper = line.uppercased()
                if upper.hasPrefix("EHLO") { c.send("250-mail.test\r\n250-STARTTLS\r\n250 AUTH PLAIN LOGIN\r\n") }
                else if upper == "STARTTLS" { c.reply("220 go ahead") }
                else if upper.hasPrefix("AUTH") { c.reply("535 5.7.8 Authentication credentials invalid") }
                else if upper == "QUIT" { c.reply("221 bye"); return }
            }
        })
        defer { refusing.stop() }
        do {
            try await SMTPLoginCheck.verify(SMTPServerSettings(host: "127.0.0.1", port: Int(refusing.port), security: .startTLS, commandTimeout: 5),
                                            username: "me", password: "wrong", accountID: UUID(), connector: SimulatedTLSConnector(), permission: { _ in })
            XCTFail("a refused login must throw")
        } catch let error as AccountLoginCheckError {
            guard case .outgoing(let why) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(why.contains("refused"), why)
        }

        let never = try ScriptedSMTPServer(behavior: SMTPServerBehavior())
        defer { never.stop() }
        do {
            try await SMTPLoginCheck.verify(SMTPServerSettings(host: "127.0.0.1", port: Int(never.port)), username: "me", password: "pw",
                                            accountID: UUID(), connector: SimulatedTLSConnector(),
                                            permission: { _ in throw NSError(domain: "policy", code: 1) })
            XCTFail("a refused permission must throw")
        } catch is AccountLoginCheckError {}
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(never.connections, 0, "nothing connects without permission")
    }

    func testIMAPLoginCheck_logsInListsAndLogsOut_wrongPasswordIsStated() async throws {
        let model = IMAPServerModel()
        model.addMailbox("INBOX")
        model.addMailbox("Trash", attributes: ["\\HasNoChildren", "\\Trash"])
        let server = try LocalIMAPServer(model: model)
        try await server.start()
        defer { server.stop() }
        let account = MailAccount(provider: .imap, host: "127.0.0.1", port: Int(server.port), loginName: model.login,
                                  displayIdentity: "asha@example.com", enabledModes: [])
        let folders = try await IMAPLoginCheck.verify(account, password: model.password, security: .plaintextLoopbackOnly, permission: { _ in })
        XCTAssertEqual(folders.first { $0.specialUse == "\\Trash" }?.serverID, "Trash")
        XCTAssertTrue(model.transcript.contains { $0.uppercased().contains("LOGOUT") }, "the check logs out")

        do {
            try await IMAPLoginCheck.verify(account, password: "wrong", security: .plaintextLoopbackOnly, permission: { _ in })
            XCTFail("a wrong password must throw")
        } catch let error as AccountLoginCheckError {
            guard case .incoming = error else { return XCTFail("\(error)") }
        }
    }
}
