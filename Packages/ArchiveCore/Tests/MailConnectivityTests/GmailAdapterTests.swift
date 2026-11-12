//
//  GmailAdapterTests.swift
//  MailConnectivityTests
//
//  V4-05: the Gmail connector against the deterministic Gmail API simulator,
//  through the REAL `SyncEngine` and a REAL archive (`ConnectedArchiveSink`).
//    T09  multi-page, multi-label mailbox → one captured representation per
//         message with every label membership; archived mail via All Mail;
//         Spam / Trash only when selected
//         attachment bytes (binary, Unicode name, inline CID) hash-equal the fixture
//    history sync: arrivals, label moves, deletions, move to unselected
//         Trash, add-then-delete (unavailable), paged history
//    T17  expired history → full reconciliation without duplicate captures
//    T18  error mapping (401/403/429/5xx/404, Retry-After), engine backoff,
//         truncated body retried, one token refresh on 401
//    redirect to another host refused (adapter and URLSession transport)
//    OAuth: placeholder client id refused, PKCE, minimal scope, no secret
//    every request asks the network policy first; refusal sends nothing
//

import XCTest
import Foundation
import CryptoKit
@testable import MailConnectivity
@testable import ArchiveCore

final class GmailAdapterTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("gmail-adapter-\(UUID().uuidString)", isDirectory: true)
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

    struct Refused: LocalizedError { var errorDescription: String? { "Mail is switched off." } }

    /// A token source that always hands out one token.
    struct StaticTokens: AccessTokenSource {
        let token: String
        func accessToken(for account: UUID, audience: String) async throws -> String { token }
        func refreshAfterRejection(account: UUID, audience: String) async throws -> String { token }
    }

    static let plenty = StorageProbe(reserveBytes: 1_024, availableBytes: { _ in 1 << 40 })

    func makeSink(_ name: String = "archive") -> ConnectedArchiveSink {
        ConnectedArchiveSink(storeDirectory: dir.appendingPathComponent(name, isDirectory: true))
    }

    func register(_ account: UUID, in sink: ConnectedArchiveSink) async throws {
        try await sink.saveAccount(ConnectedAccountRecord(
            accountID: account, provider: .gmail, issuer: GmailOAuth.issuer, displayIdentity: "asha@example.com",
            grantedScopes: GmailOAuth.captureScopes, enabledModes: ["capture"], connectionState: "connected",
            createdAt: Date(), updatedAt: Date()))
    }

    func makeAdapter(_ sim: GmailAPISimulator, account: UUID = UUID(), options: GmailCaptureOptions = GmailCaptureOptions(),
                     asks: Box<[NetworkAsk]> = Box([]), refuse: Box<Bool> = Box(false)) -> GmailAdapter {
        GmailAdapter(accountID: account, transport: sim, permission: { ask in
            asks.mutate { $0.append(ask) }
            if refuse.value { throw Refused() }
        }, options: options)
    }

    func makeEngine(_ adapter: GmailAdapter, _ sink: ConnectedArchiveSink, tokens: (any AccessTokenSource)? = StaticTokens(token: "good"),
                    asks: Box<[NetworkAsk]> = Box([]), waits: Box<[TimeInterval]> = Box([])) -> SyncEngine {
        SyncEngine(adapter: adapter, sink: sink, scheduler: FairDownloadScheduler(totalSlots: 4), tokens: tokens,
                   permission: { ask in asks.mutate { $0.append(ask) } },
                   backoff: BackoffPolicy(base: 1, maximum: 60, transientAttempts: 6, maximumThrottleWait: 1_800,
                                          jitter: { 0.5 }, sleep: { s in waits.mutate { $0.append(s) }; await Task.yield() }),
                   storage: Self.plenty)
    }

    func context(_ token: String? = "good", attempt: Int = 0) -> ProviderRequestContext {
        ProviderRequestContext(accountID: UUID(), accessToken: token, attempt: attempt)
    }

    /// Labels: system + Work, Work/Projects, Family, a Unicode label.
    /// m00…m44 in five label patterns (one with no label at all), two in
    /// Spam, three in Trash.
    @discardableResult
    func seed(_ sim: GmailAPISimulator, count: Int = 45) async -> [String: GmailFixtures.Built] {
        await sim.addStandardSystemLabels()
        await sim.addLabel("Label_1", name: "Work")
        await sim.addLabel("Label_2", name: "Work/Projects")
        await sim.addLabel("Label_3", name: "Family")
        await sim.addLabel("Label_4", name: "Reisen – Ümläut 旅")
        var built: [String: GmailFixtures.Built] = [:]
        for i in 0..<count {
            let id = String(format: "m%02d", i)
            let b = GmailFixtures.message(id, attachmentSize: 1_000 + i * 97, inline: i % 2 == 0)
            built[id] = b
            let labels: [String]
            switch i % 5 {
            case 0: labels = ["INBOX", "UNREAD", "Label_1", "Label_2"]
            case 1: labels = ["CATEGORY_UPDATES", "INBOX"]
            case 2: labels = ["SENT"]
            case 3: labels = ["Label_3", "Label_4", "STARRED", "IMPORTANT"]
            default: labels = []                                  // archived: only in All Mail
            }
            await sim.add(id, raw: b.raw, labels: labels)
        }
        for id in ["s1", "s2"] {
            let b = GmailFixtures.message(id); built[id] = b
            await sim.add(id, raw: b.raw, labels: ["SPAM", "UNREAD"])
        }
        for id in ["t1", "t2", "t3"] {
            let b = GmailFixtures.message(id); built[id] = b
            await sim.add(id, raw: b.raw, labels: ["TRASH", "Label_1"])
        }
        return built
    }

    func captured(_ sink: ConnectedArchiveSink, _ account: UUID) async throws -> [String: (digest: String, emailID: UUID?)] {
        var out: [String: (String, UUID?)] = [:]
        for row in try await sink.store.remoteMessageDigests() where row.account == account {
            guard case .gmail(let id) = try ProviderMessageIdentity(key: row.key) else { continue }
            XCTAssertNil(out[id], "\(id) captured twice")
            out[id] = (row.digest, row.emailID)
        }
        return out
    }

    func memberships(_ sink: ConnectedArchiveSink, _ account: UUID, _ id: String) async throws -> [String] {
        let rows = try await captured(sink, account)
        let emailID = try XCTUnwrap(rows[id]?.emailID, "\(id) has a record")
        return try await sink.provenance(emailID: emailID)?.memberships ?? []
    }

    // MARK: T09 — multi-page, multi-label capture

    func testT09_multiPageMultiLabelMailbox_oneCapturePerMessage_allLabelMemberships_spamTrashExcluded() async throws {
        let sink = makeSink()
        let sim = GmailAPISimulator()
        let built = await seed(sim)
        let account = UUID()
        try await register(account, in: sink)
        let adapterAsks = Box<[NetworkAsk]>([])
        let adapter = makeAdapter(sim, account: account, options: GmailCaptureOptions(pageSize: 7), asks: adapterAsks)
        let engineAsks = Box<[NetworkAsk]>([])
        let engine = makeEngine(adapter, sink, asks: engineAsks)

        let report = await engine.sync()
        XCTAssertEqual(report.outcome, .completed)
        let receipt = try XCTUnwrap(report.receipt)
        XCTAssertEqual(receipt.stored, 45)
        XCTAssertEqual(receipt.pending, 0)

        let rows = try await captured(sink, account)
        XCTAssertEqual(Set(rows.keys), Set((0..<45).map { String(format: "m%02d", $0) }),
                       "every message outside Spam/Trash, including archived mail with no label")
        let total = try await sink.store.totalCount()
        XCTAssertEqual(total, 45, "a message in four labels is ONE archive record")
        for (id, row) in rows {
            XCTAssertEqual(row.digest, GmailFixtures.sha256(built[id]!.raw), "\(id): the raw MIME is preserved byte for byte")
            let gets = await sim.getCount(id)
            XCTAssertEqual(gets, 1, "\(id) downloaded once although listed under several labels")
        }
        for id in ["s1", "s2", "t1", "t2", "t3"] {
            let gets = await sim.getCount(id)
            XCTAssertEqual(gets, 0, "\(id): Spam / Trash are not captured unless selected")
        }

        // Memberships: one per label, state labels are not folders.
        let m00 = try await memberships(sink, account, "m00")
        XCTAssertEqual(Set(m00), ["Inbox", "Work", "Work/Projects", "All Mail"])
        let m03 = try await memberships(sink, account, "m03")
        XCTAssertEqual(Set(m03), ["Family", "Reisen – Ümläut 旅", "All Mail"])
        let m04 = try await memberships(sink, account, "m04")
        XCTAssertEqual(m04, ["All Mail"], "a message with no label is kept, in All Mail")
        let m01 = try await memberships(sink, account, "m01")
        XCTAssertEqual(Set(m01), ["Inbox", "Categories/Updates", "All Mail"])

        let counts = try await sink.store.connectedTableCounts()
        // All Mail, Inbox, Sent, Drafts, Chats, Categories/Updates + 4 user labels.
        XCTAssertEqual(counts["remote_folders"], 10, "Spam, Trash and state labels are not folders unless selected")
        XCTAssertEqual(counts["remote_memberships"], 9 * 4 + 9 * 3 + 9 * 2 + 9 * 3 + 9 * 1)

        // Complete paging: All Mail alone needs 45 / 7 → 7 pages.
        let pages = await sim.listPages
        XCTAssertGreaterThanOrEqual(pages, 7 + 2 + 2 + 2 + 2 + 2 + 2)

        // Every HTTP request asked the policy first (adapter) and was also
        // asked by the engine; the token went to Gmail only.
        let requests = await sim.requests
        XCTAssertEqual(adapterAsks.value.count, requests.count)
        XCTAssertTrue(adapterAsks.value.allSatisfy { $0.host == "gmail.googleapis.com" && $0.destination == .mailServer })
        XCTAssertGreaterThanOrEqual(engineAsks.value.count, requests.count)
        let foreign = await sim.foreignRequests
        XCTAssertTrue(foreign.isEmpty)
        XCTAssertTrue(requests.allSatisfy { $0.headers["Authorization"] == "Bearer good" })
        let status = try await engine.status()
        XCTAssertTrue(status.acquisitionComplete)

        // A repeated sync downloads nothing and adds nothing.
        let again = await engine.sync()
        XCTAssertEqual(again.outcome, .completed)
        let allGets = await sim.totalGets
        XCTAssertEqual(allGets, 45)
        let totalAfter = try await sink.store.totalCount()
        XCTAssertEqual(totalAfter, 45)
    }

    func testT09_attachmentBytes_unicodeNames_andInlineCIDs_hashEqualTheFixture() async throws {
        let sink = makeSink()
        let sim = GmailAPISimulator()
        await sim.set(chunkSize: 13, pad: true, escapeEquals: true)    // padded, "=" escaped, tiny chunks
        await sim.addStandardSystemLabels()
        var built: [String: GmailFixtures.Built] = [:]
        for (i, size) in [0, 1, 2, 3, 50_001, 262_147].enumerated() {
            let id = "a\(i)"
            built[id] = GmailFixtures.message(id, attachmentSize: size, inline: i % 2 == 0)
            await sim.add(id, raw: built[id]!.raw, labels: ["INBOX"])
        }
        let account = UUID()
        try await register(account, in: sink)
        let engine = makeEngine(makeAdapter(sim, account: account), sink)
        let report = await engine.sync()
        XCTAssertEqual(report.outcome, .completed)

        let rows = try await captured(sink, account)
        XCTAssertEqual(rows.count, built.count)
        for (id, fixture) in built {
            let row = try XCTUnwrap(rows[id])
            let bytes = try sink.store.blobStore.read(BlobReference(digest: row.digest, length: Int64(fixture.raw.count)))
            XCTAssertEqual(bytes, fixture.raw, "\(id): preserved bytes equal the fixture")
            // The archive's own reader finds every attachment with its exact bytes.
            let email = try MBOXParser.processRawMessage(String(decoding: bytes, as: UTF8.self), senderEmail: "")
            for expected in fixture.attachments {
                let found = email.attachments.first { $0.filename == expected.filename }
                let attachment = try XCTUnwrap(found, "\(id): \(expected.filename) found in \(email.attachments.map(\.filename))")
                let data: Data
                if let b64 = attachment.base64, let decoded = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) {
                    data = decoded
                } else {
                    data = try Data(contentsOf: try XCTUnwrap(attachment.fileURL, "\(id): attachment bytes available"))
                }
                XCTAssertEqual(GmailFixtures.sha256(data), GmailFixtures.sha256(expected.data), "\(id): \(expected.filename) hash-equal")
                if let cid = expected.contentID {
                    XCTAssertEqual(attachment.contentID?.trimmingCharacters(in: CharacterSet(charactersIn: "<>")), cid)
                    XCTAssertTrue(email.htmlBody.contains("cid:\(cid)"), "\(id): the inline reference survives")
                }
            }
            let subject = email.headers["Subject"] ?? ""; XCTAssertTrue(subject.contains("März ✓"), "\(id): UTF-8 subject decoded: \(subject)")
        }
    }

    func testSpamAndTrash_capturedOnlyWhenSelected_withTheirLabels() async throws {
        let sink = makeSink()
        let sim = GmailAPISimulator()
        await seed(sim, count: 10)
        let account = UUID()
        try await register(account, in: sink)
        let adapter = makeAdapter(sim, account: account, options: GmailCaptureOptions(includeSpam: true, includeTrash: true, pageSize: 4))
        let report = await makeEngine(adapter, sink).sync()
        XCTAssertEqual(report.outcome, .completed)
        let rows = try await captured(sink, account)
        XCTAssertEqual(rows.count, 15)
        let t1 = try await memberships(sink, account, "t1")
        XCTAssertEqual(Set(t1), ["Trash", "Work"], "a trashed message is not in All Mail")
        let s1 = try await memberships(sink, account, "s1")
        XCTAssertEqual(s1, ["Spam"])
        let counts = try await sink.store.connectedTableCounts()
        XCTAssertEqual(counts["remote_folders"], 12)

        // Selecting only some labels: a user selection, stated as such.
        let sink2 = makeSink("second")
        let account2 = UUID()
        try await register(account2, in: sink2)
        let adapter2 = makeAdapter(sim, account: account2)
        let partial = await makeEngine(adapter2, sink2).sync(.folders(["Label_3"]))
        XCTAssertEqual(partial.outcome, .completed)
        let rows2 = try await captured(sink2, account2)
        XCTAssertEqual(Set(rows2.keys), ["m03", "m08"])
    }

    // MARK: History sync

    func testHistorySync_arrivalsLabelMovesDeletions_pagedHistory_noRedownload() async throws {
        let sink = makeSink()
        let sim = GmailAPISimulator()
        let built = await seed(sim, count: 20)
        let account = UUID()
        try await register(account, in: sink)
        let adapter = makeAdapter(sim, account: account, options: GmailCaptureOptions(pageSize: 6, historyPageSize: 2))
        let engine = makeEngine(adapter, sink)
        let first = await engine.sync()
        XCTAssertEqual(first.outcome, .completed)
        let getsAfterFirst = await sim.totalGets
        XCTAssertEqual(getsAfterFirst, 20)

        let n1 = GmailFixtures.message("n1", attachmentSize: 9_999)
        await sim.add("n1", raw: n1.raw, labels: ["INBOX", "UNREAD"])            // arrival
        await sim.modify("m00", add: ["Label_3"], remove: ["INBOX"])            // label move
        await sim.delete("m02")                                                  // deleted on the server
        await sim.modify("m06", add: ["TRASH"])                                  // moved to unselected Trash
        await sim.add("n2", raw: GmailFixtures.message("n2").raw, labels: ["SPAM"])   // straight into unselected Spam
        await sim.add("n3", raw: GmailFixtures.message("n3").raw, labels: ["INBOX"])
        await sim.delete("n3")                                                   // gone before it could be saved
        await sim.addLabel("Label_5", name: "Neu – 新")
        let n4 = GmailFixtures.message("n4")
        await sim.add("n4", raw: n4.raw, labels: ["Label_5"])
        let historyBefore = await sim.historyPages

        let second = await engine.sync()
        XCTAssertEqual(second.outcome, .completed)
        XCTAssertFalse(second.fullEnumeration, "history, not a re-enumeration")
        let historyPages = await sim.historyPages - historyBefore
        XCTAssertGreaterThanOrEqual(historyPages, 4, "every history page read (8 records, 2 per page)")
        let gets = await sim.totalGets - getsAfterFirst
        XCTAssertEqual(gets, 3, "n1, n4 and the vanished n3 (404) — nothing preserved is downloaded again")
        let n2Gets = await sim.getCount("n2")
        XCTAssertEqual(n2Gets, 0, "unselected Spam is not captured")

        let rows = try await captured(sink, account)
        XCTAssertEqual(rows.count, 22)
        XCTAssertEqual(rows["n1"]?.digest, GmailFixtures.sha256(n1.raw))
        XCTAssertEqual(rows["m02"]?.digest, GmailFixtures.sha256(built["m02"]!.raw), "deleted on the server: still preserved")
        let m00 = try await memberships(sink, account, "m00")
        XCTAssertTrue(m00.contains("Family"), "the label added on the server is recorded: \(m00)")
        let n4m = try await memberships(sink, account, "n4")
        XCTAssertTrue(n4m.contains("Neu – 新"), "a new label arrives with its name: \(n4m)")

        let completeness = try await sink.completeness(accountID: account)
        XCTAssertEqual(completeness.acquisition.removedOnServer, 2, "m02 deleted, m06 moved to unselected Trash")
        XCTAssertEqual(completeness.acquisition.unavailable, 1, "n3 vanished before capture: unavailable, not captured")
        XCTAssertNil(rows["n3"])
        let total = try await sink.store.totalCount()
        XCTAssertEqual(total, 22)

        // Idle mailbox: the next sync reads history and downloads nothing.
        let third = await engine.sync()
        XCTAssertEqual(third.outcome, .completed)
        let getsAfterThird = await sim.totalGets
        XCTAssertEqual(getsAfterThird, getsAfterFirst + 3)
    }

    // MARK: T17 — expired history

    func testT17_expiredHistory_fullReconciliation_noDuplicateCaptures() async throws {
        let sink = makeSink()
        let sim = GmailAPISimulator()
        await seed(sim, count: 25)
        let account = UUID()
        try await register(account, in: sink)
        let engine = makeEngine(makeAdapter(sim, account: account, options: GmailCaptureOptions(pageSize: 8)), sink)
        let first = await engine.sync()
        XCTAssertEqual(first.outcome, .completed)
        let getsAfterFirst = await sim.totalGets

        for i in 0..<3 { await sim.add("late\(i)", raw: GmailFixtures.message("late\(i)").raw, labels: ["INBOX"]) }
        await sim.modify("m01", add: ["Label_3"])
        await sim.delete("m07")
        await sim.expireHistory()

        let second = await engine.sync()
        XCTAssertEqual(second.outcome, .completed)
        XCTAssertTrue(second.fullEnumeration, "history too old (HTTP 404) → full reconciliation")
        let newGets = await sim.totalGets - getsAfterFirst
        XCTAssertEqual(newGets, 3, "only the three new messages are downloaded")
        let r2 = try XCTUnwrap(second.receipt)
        XCTAssertEqual(r2.stored, 3)
        XCTAssertEqual(r2.failed, 0)
        let rows = try await captured(sink, account)
        XCTAssertEqual(rows.count, 28, "old data kept (m07 too), nothing captured twice")
        let total = try await sink.store.totalCount()
        XCTAssertEqual(total, 28)
        let m01 = try await memberships(sink, account, "m01")
        XCTAssertTrue(m01.contains("Family"), "the reconciliation records the new label: \(m01)")

        let third = await engine.sync()
        XCTAssertEqual(third.outcome, .completed)
        XCTAssertFalse(third.fullEnumeration, "incremental again from the new boundary")
        let getsAfterThird = await sim.totalGets
        XCTAssertEqual(getsAfterThird, getsAfterFirst + 3)
    }

    // MARK: T18 — errors, backoff, refresh

    func testErrorMapping_gmailResponsesMapOntoTheEngineVocabulary() async throws {
        let sim = GmailAPISimulator()
        await seed(sim, count: 3)
        let adapter = makeAdapter(sim)
        let staging = makeSink()
        func fetch(_ id: String) async -> Error? {
            do {
                let sink = RawByteSink(writer: try staging.makeStagingWriter())
                defer { sink.discard() }
                _ = try await adapter.fetchRaw(RemoteItemRef(identity: .gmail(messageID: id), folder: nil), into: sink, context: context())
                return nil
            } catch { return error }
        }
        func body(_ status: Int, _ reason: String) -> Data { GmailAPISimulator.errorJSON(status, reason, "x", domain: "usageLimits") }

        await sim.inject(.message("m00"), .init(status: 403, headers: ["Retry-After": "7"], body: body(403, "rateLimitExceeded")))
        var e = await fetch("m00"); XCTAssertEqual(e as? MailProviderError, .rateLimited(retryAfter: 7))
        await sim.inject(.message("m00"), .init(status: 403, body: body(403, "userRateLimitExceeded")))
        e = await fetch("m00"); XCTAssertEqual(e as? MailProviderError, .rateLimited(retryAfter: nil))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        await sim.inject(.message("m00"), .init(status: 429, headers: ["retry-after": formatter.string(from: Date(timeIntervalSinceNow: 120))],
                                                body: body(429, "rateLimitExceeded")))
        e = await fetch("m00")
        if case .rateLimited(let after)? = e as? MailProviderError, let after {
            XCTAssertTrue((100...121).contains(after), "HTTP-date Retry-After: \(after)")
        } else { XCTFail("429 → rateLimited, got \(String(describing: e))") }
        await sim.inject(.message("m00"), .init(status: 403, body: body(403, "dailyLimitExceeded")))
        e = await fetch("m00"); XCTAssertEqual(e as? MailProviderError, .quotaExceeded(resetAfter: nil))
        await sim.inject(.message("m00"), .init(status: 429, headers: ["Retry-After": "3600"], body: body(429, "quotaExceeded")))
        e = await fetch("m00"); XCTAssertEqual(e as? MailProviderError, .quotaExceeded(resetAfter: 3600))
        await sim.inject(.message("m00"), .init(status: 401, body: body(401, "authError")))
        e = await fetch("m00"); XCTAssertEqual(e as? MailProviderError, .unauthorized)
        for status in [500, 502, 504] {
            await sim.inject(.message("m00"), .init(status: status, body: body(status, "backendError")))
            e = await fetch("m00"); XCTAssertEqual(e as? MailProviderError, .transient("Gmail answered HTTP \(status)"))
        }
        await sim.inject(.message("m00"), .init(status: 503, headers: ["Retry-After": "5"]))
        e = await fetch("m00"); XCTAssertEqual(e as? MailProviderError, .rateLimited(retryAfter: 5))
        await sim.inject(.message("m00"), .init(status: 403, body: body(403, "insufficientPermissions")))
        e = await fetch("m00")
        if case .permanent? = e as? MailProviderError {} else { XCTFail("403 forbidden → permanent, got \(String(describing: e))") }
        e = await fetch("gone1"); XCTAssertEqual(e as? MailProviderError, .itemUnavailable, "404 for one message")
        e = await fetch("m00"); XCTAssertNil(e, "the message itself still downloads")

        // A body cut off mid-transfer is a transient failure, never a message.
        await sim.cutOffBody(of: "m01", after: 400)
        e = await fetch("m01")
        if case .transient? = e as? MailProviderError {} else { XCTFail("cut-off body → transient, got \(String(describing: e))") }

        // History: too old (404) and a stale page token (400) → full reconciliation.
        await sim.expireHistory()
        do { _ = try await adapter.changes(scope: .account, since: "4001", context: context()); XCTFail() }
        catch { XCTAssertEqual(error as? MailProviderError, .changeTokenExpired) }
        let boundary = try await adapter.changeBoundary(scope: .account, context: context())
        do { _ = try await adapter.changes(scope: .account, since: "\(boundary)|bogus", context: context()); XCTFail() }
        catch { XCTAssertEqual(error as? MailProviderError, .changeTokenExpired) }
        do { _ = try await adapter.changes(scope: .account, since: "not-a-history-id", context: context()); XCTFail() }
        catch { XCTAssertEqual(error as? MailProviderError, .changeTokenExpired) }
        let empty = try await adapter.changes(scope: .account, since: boundary, context: context())
        XCTAssertTrue(empty.changes.isEmpty); XCTAssertFalse(empty.hasMore); XCTAssertEqual(empty.resume, boundary)

        // A label that vanished mid-enumeration.
        await sim.inject(.list(label: "Label_9"), .init(status: 404, body: body(404, "notFound")))
        do {
            _ = try await adapter.enumerate(folder: RemoteFolderOccurrence(serverID: "Label_9", displayPath: "Old", kind: .label),
                                            cursor: nil, pageSize: 10, context: context())
            XCTFail()
        } catch { XCTAssertEqual(error as? MailProviderError, .folderUnavailable("Label_9")) }

        // No token: nothing is sent.
        let before = await sim.requests.count
        do { _ = try await adapter.listFolders(pageToken: nil, context: context(nil)); XCTFail() }
        catch { XCTAssertEqual(error as? MailProviderError, .unauthorized) }
        let after = await sim.requests.count
        XCTAssertEqual(after, before)
    }

    func testT18_rateLimitAndTruncatedTransfer_engineBacksOffAndRetries_completes() async throws {
        let sink = makeSink()
        let sim = GmailAPISimulator()
        let built = await seed(sim, count: 10)
        await sim.inject(.message("m03"), .init(status: 403, headers: ["Retry-After": "30"],
                                                body: GmailAPISimulator.errorJSON(403, "userRateLimitExceeded", "slow down")))
        await sim.inject(.labels, .init(status: 503))
        await sim.cutOffBody(of: "m05", after: 900)
        let account = UUID()
        try await register(account, in: sink)
        let waits = Box<[TimeInterval]>([])
        let asks = Box<[NetworkAsk]>([])
        let engine = makeEngine(makeAdapter(sim, account: account), sink, asks: asks, waits: waits)
        let report = await engine.sync()
        XCTAssertEqual(report.outcome, .completed)
        XCTAssertTrue(waits.value.contains { $0 >= 30 }, "Retry-After honoured: \(waits.value)")
        XCTAssertGreaterThanOrEqual(asks.value.filter { $0.operation == .retry }.count, 3, "every retry asked the policy")
        let m05 = await sim.getCount("m05")
        XCTAssertEqual(m05, 2, "the cut-off transfer was retried, not preserved")
        let rows = try await captured(sink, account)
        XCTAssertEqual(rows["m05"]?.digest, GmailFixtures.sha256(built["m05"]!.raw))
        XCTAssertEqual(rows.count, 10)
    }

    func testT18_rejectedToken_refreshedOnce_thenRequestsCarryTheFreshToken_revokedNeedsSignIn() async throws {
        let sink = makeSink()
        let credentials = InMemoryCredentialStore()
        let endpoint = FakeTokenEndpoint()
        let coordinator = TokenRefreshCoordinator(credentials: credentials, transport: endpoint)
        let config = try GmailOAuth.configuration(clientID: Self.validClientID)
        let sim = GmailAPISimulator()
        await seed(sim, count: 12)
        await sim.set(requiredToken: "fresh")
        let good = UUID(), stuck = UUID()
        for account in [good, stuck] {
            await coordinator.register(account: account, configuration: config)
            try await coordinator.store(OAuthTokenSet(accountID: account, issuer: GmailOAuth.issuer, audience: GmailOAuth.audience,
                                                      accessToken: "stale", refreshToken: "r-\(account)",
                                                      expiresAt: Date(timeIntervalSinceNow: 3_600), scopes: GmailOAuth.captureScopes))
            try await register(account, in: sink)
        }
        await endpoint.respond(to: "r-\(good)", json: Fixtures.tokenJSON(access: "fresh"))
        await endpoint.respond(to: "r-\(stuck)", json: Fixtures.tokenJSON(access: "still-rejected"))

        let asks = Box<[NetworkAsk]>([])
        let report = await makeEngine(makeAdapter(sim, account: good), sink, tokens: coordinator, asks: asks).sync()
        XCTAssertEqual(report.outcome, .completed)
        let refreshes = await coordinator.refreshCount(for: good)
        XCTAssertEqual(refreshes, 1, "one refresh after the 401")
        XCTAssertTrue(asks.value.contains { $0.operation == .oauthRefresh && $0.host == "oauth2.googleapis.com" })
        let seen = await sim.authorizationsSeen
        XCTAssertEqual(seen.filter { $0 == "Bearer stale" }.count, 1, "only the first request carried the rejected token")
        XCTAssertEqual(seen.last, "Bearer fresh")
        let refreshRequest = await endpoint.requests.first
        XCTAssertEqual(refreshRequest?.url, GmailOAuth.tokenEndpoint)
        XCTAssertNil(refreshRequest?.form["client_secret"], "a native client sends no secret")

        // A refresh that yields another rejected token: no loop — sign in again.
        let stuckReport = await makeEngine(makeAdapter(sim, account: stuck), sink, tokens: coordinator).sync()
        XCTAssertEqual(stuckReport.outcome, .needsSignIn)
        let stuckRefreshes = await coordinator.refreshCount(for: stuck)
        XCTAssertEqual(stuckRefreshes, 1)
    }

    // MARK: Redirects

    func testRedirectToAnotherHost_isRefused_tokenNeverLeavesGmail_itemRetriedNextSync() async throws {
        let sink = makeSink()
        let sim = GmailAPISimulator()
        await seed(sim, count: 6)
        // m04 has no label: it is listed once (All Mail), so the run has one attempt.
        await sim.inject(.message("m04"), .init(status: 302, headers: ["Location": "https://evil.example.com/steal?x=1"]))
        let account = UUID()
        try await register(account, in: sink)
        let engine = makeEngine(makeAdapter(sim, account: account), sink)
        let first = await engine.sync()
        XCTAssertEqual(first.outcome, .completedWithFailures(failed: 1), "the redirected item is a recorded failure, not a silent skip")
        let foreign = await sim.foreignRequests
        XCTAssertTrue(foreign.isEmpty, "nothing was sent to the redirect target")
        let rows = try await captured(sink, account)
        XCTAssertNil(rows["m04"])
        let completeness = try await sink.completeness(accountID: account)
        XCTAssertEqual(completeness.acquisition.failed, 1)
        let second = await engine.sync()
        XCTAssertEqual(second.outcome, .completed, "the exact failure is retried on the next sync")
        let rows2 = try await captured(sink, account)
        XCTAssertEqual(rows2.count, 6)

        // A transport that DID follow a redirect: its answer is not used.
        struct Following: GmailHTTPTransport {
            let inner: GmailAPISimulator
            func send(_ request: GmailHTTPRequest) async throws -> GmailHTTPResponse {
                var response = try await inner.send(request)
                response.url = URL(string: "https://evil.example.com/landing")
                return response
            }
        }
        let adapter = GmailAdapter(accountID: UUID(), transport: Following(inner: sim), permission: { _ in })
        do { _ = try await adapter.listFolders(pageToken: nil, context: context()); XCTFail() }
        catch {
            guard case .permanent(let why)? = error as? MailProviderError else { return XCTFail("\(error)") }
            XCTAssertTrue(why.contains("evil.example.com"))
        }
    }

    func testURLSessionTransport_neverFollowsRedirects_andStreamsTheBody() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GmailStubURLProtocol.self]
        GmailStubURLProtocol.reset()
        let transport = URLSessionGmailTransport(configuration: config)
        defer { transport.invalidate() }

        let payload = GmailFixtures.binary(seed: 3, count: 200_000)
        GmailStubURLProtocol.body = payload
        let ok = try await transport.send(GmailHTTPRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile")!,
                                                           headers: ["Authorization": "Bearer t"]))
        XCTAssertEqual(ok.status, 200)
        var received = Data()
        for try await chunk in ok.body { received.append(chunk) }
        XCTAssertEqual(received, payload)
        XCTAssertEqual(GmailStubURLProtocol.authorizations, ["Bearer t"])

        let redirected = try? await transport.send(GmailHTTPRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/redirect")!,
                                                                    headers: ["Authorization": "Bearer t"]))
        XCTAssertFalse(GmailStubURLProtocol.seen.contains { $0.host == "evil.example.com" }, "the redirect target was never requested")
        XCTAssertEqual(transport.refusedRedirects, 1)
        if let redirected { XCTAssertEqual(redirected.status, 302) }
    }

    // MARK: OAuth

    static let validClientID = "123456789012-a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6.apps.googleusercontent.com"

    func testOAuth_placeholderClientIDRefused_PKCE_minimalScope_googleEndpoints_noSecret() async throws {
        XCTAssertThrowsError(try GmailOAuth.configuration(clientID: "YOUR_GOOGLE_OAUTH_CLIENT_ID.apps.googleusercontent.com")) {
            XCTAssertEqual($0 as? GmailOAuth.ConfigurationError, .placeholderClientID("YOUR_GOOGLE_OAUTH_CLIENT_ID.apps.googleusercontent.com"))
        }
        XCTAssertThrowsError(try GmailOAuth.configuration(clientID: "  ")) { XCTAssertEqual($0 as? GmailOAuth.ConfigurationError, .missingClientID) }
        for bad in ["123-test.apps.googleusercontent.com", "000000-aaaaaaaaaaaaaaaaaaaa.apps.googleusercontent.com",
                    "123456789012-placeholderplaceholder.apps.googleusercontent.com", "client.example.com",
                    "123456789012-A1B2C3D4E5F6G7H8I9J0.apps.googleusercontent.com"] {
            XCTAssertThrowsError(try GmailOAuth.configuration(clientID: bad), bad)
        }
        XCTAssertThrowsError(try GmailOAuth.configuration(clientID: Self.validClientID,
                                                          scopes: [GmailOAuth.readOnlyScope, "https://www.googleapis.com/auth/drive"]))
        XCTAssertThrowsError(try GmailOAuth.configuration(clientID: Self.validClientID,
                                                          redirectURI: URL(string: "https://attacker.example/cb")!))
        XCTAssertThrowsError(try GmailOAuth.configuration(clientID: Self.validClientID, redirectURI: URL(string: "mailin://oauth")!))

        let config = try GmailOAuth.configuration(clientID: Self.validClientID)
        XCTAssertEqual(config.scopes, ["https://www.googleapis.com/auth/gmail.readonly"], "capture asks for read-only Gmail only")
        XCTAssertEqual(config.redirectURI.absoluteString,
                       "com.googleusercontent.apps.123456789012-a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6:/oauth2redirect")
        XCTAssertEqual(config.audience, GmailOAuth.audience)
        XCTAssertEqual(config.tokenEndpoint.host, "oauth2.googleapis.com")

        let endpoint = FakeTokenEndpoint()
        await endpoint.respond(to: "the-code", json: Fixtures.tokenJSON(access: "a1", refresh: "r1"))
        let account = UUID()
        let session = try GmailOAuth.makeSession(accountID: account, clientID: Self.validClientID, transport: endpoint)
        let url = try await session.begin()
        XCTAssertEqual(url.host, "accounts.google.com")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ n: String) -> String? { items.first { $0.name == n }?.value }
        XCTAssertEqual(q("code_challenge_method"), "S256")
        XCTAssertEqual(q("scope"), GmailOAuth.readOnlyScope)
        XCTAssertEqual(q("client_id"), Self.validClientID)
        XCTAssertNotNil(q("code_challenge")); XCTAssertNotNil(q("state"))
        let state = try XCTUnwrap(q("state"))
        let callback = URL(string: "\(config.redirectURI.absoluteString)?code=the-code&state=\(state)")!
        let tokens = try await session.complete(callback: callback)
        XCTAssertEqual(tokens.audience, GmailOAuth.audience)
        XCTAssertEqual(tokens.accountID, account)
        let exchange = await endpoint.requests.first
        XCTAssertEqual(exchange?.url, GmailOAuth.tokenEndpoint)
        XCTAssertNotNil(exchange?.form["code_verifier"])
        XCTAssertNil(exchange?.form["client_secret"])
    }

    // MARK: Network policy

    func testEveryRequestAsksThePolicy_refusalSendsNothing() async throws {
        let sim = GmailAPISimulator()
        await seed(sim, count: 2)
        let refuse = Box(true)
        let asks = Box<[NetworkAsk]>([])
        let adapter = makeAdapter(sim, asks: asks, refuse: refuse)
        do { _ = try await adapter.changeBoundary(scope: .account, context: context()); XCTFail() }
        catch { XCTAssertEqual(error as? GmailAdapterError, .notPermitted("Mail is switched off.")) }
        let sent = await sim.requests.count
        XCTAssertEqual(sent, 0, "a refused request never reaches the transport")
        XCTAssertEqual(asks.value.count, 1)

        // Through the engine: a refusal stops the account, nothing is sent.
        let sink = makeSink()
        let account = UUID()
        try await register(account, in: sink)
        let engine = SyncEngine(adapter: makeAdapter(sim, account: account), sink: sink, scheduler: FairDownloadScheduler(totalSlots: 2),
                                tokens: StaticTokens(token: "good"), permission: { _ in throw Refused() }, storage: Self.plenty)
        let report = await engine.sync()
        XCTAssertEqual(report.outcome, .notPermitted("Mail is switched off."))
        let sentAfter = await sim.requests.count
        XCTAssertEqual(sentAfter, 0)
    }

    // MARK: Streaming decoder

    func testRawStreamDecoder_anyChunking_paddingAndEscapes_truncationAndMissingRaw() throws {
        let message = GmailFixtures.message("dec", attachmentSize: 4_321).raw
        let b64 = message.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let variants = [b64, b64.replacingOccurrences(of: "=", with: ""), b64.replacingOccurrences(of: "=", with: "\\u003d")]
        for (v, raw) in variants.enumerated() {
            let json = Data(#"{"id":"x","nested":{"raw":"@@"},"labelIds":["A","B"],"raw":"\#(raw)","historyId":"77","snippet":"a \"raw\" \\"}"#.utf8)
            for size in [1, 2, 3, 4, 5, 7, 64, 1_000, json.count] {
                var decoder = GmailRawStreamDecoder()
                var out = Data()
                var offset = 0
                while offset < json.count {
                    let end = min(json.count, offset + size)
                    try decoder.feed(json.subdata(in: offset..<end)) { out.append($0) }
                    offset = end
                }
                try decoder.finish { out.append($0) }
                XCTAssertEqual(out, message, "variant \(v), chunk \(size)")
                let meta = try JSONDecoder().decode(GmailAPI.RawMessageMeta.self, from: decoder.metadataJSON)
                XCTAssertEqual(meta.labelIds, ["A", "B"]); XCTAssertEqual(meta.historyId, "77")
                XCTAssertLessThan(decoder.metadataJSON.count, 200, "the raw value is not kept in memory")
            }
        }
        func run(_ text: String) -> Error? {
            var decoder = GmailRawStreamDecoder()
            do { try decoder.feed(Data(text.utf8)) { _ in }; try decoder.finish { _ in }; return nil } catch { return error }
        }
        XCTAssertEqual(run(#"{"id":"x","raw":"QUJD"#) as? GmailRawDecodeError, .truncated)
        XCTAssertEqual(run(#"{"id":"x","raw":"QUJD", "a":1"#) as? GmailRawDecodeError, .truncated)
        XCTAssertEqual(run(#"{"id":"x","raw":null}"#) as? GmailRawDecodeError, .missingRaw)
        XCTAssertEqual(run(#"{"id":"x"}"#) as? GmailRawDecodeError, .missingRaw)
        if case .malformed? = run(#"{"raw":"QU*D"}"#) as? GmailRawDecodeError {} else { XCTFail("non-base64url byte") }
        if case .malformed? = run(#"{"raw":"Q"}"#) as? GmailRawDecodeError {} else { XCTFail("dangling sextet") }
        if case .malformed? = run(#"[1]"#) as? GmailRawDecodeError {} else { XCTFail("not an object") }
        XCTAssertNil(run(#"  {"raw":"QUJD"}  "#))
    }
}

// MARK: - URLProtocol stub for the URLSession transport

final class GmailStubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var _seen: [URL] = []
    private static var _auth: [String] = []
    static var body = Data()
    static var seen: [URL] { lock.withLock { _seen } }
    static var authorizations: [String] { lock.withLock { _auth } }
    static func reset() { lock.withLock { _seen = []; _auth = [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        Self.lock.withLock {
            Self._seen.append(url)
            if url.host == "gmail.googleapis.com" { Self._auth.append(request.value(forHTTPHeaderField: "Authorization") ?? "") }
        }
        if url.path.hasSuffix("/redirect") {
            let target = URL(string: "https://evil.example.com/steal")!
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/octet-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let data = Self.body
        var offset = 0
        while offset < data.count {
            let end = min(data.count, offset + 16_384)
            client?.urlProtocol(self, didLoad: data.subdata(in: offset..<end))
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
