//
//  GraphAdapterTests.swift
//  MailConnectivityTests
//
//  V4-06: the Microsoft Graph connector through the REAL `SyncEngine` and a
//  real archive (`ConnectedArchiveSink` on a temporary store), against the
//  deterministic `GraphSimulator` (no network).
//    T10  deep folder tree (childFolders + nextLink paging, hidden optional),
//         moves keep the immutable identity, empty delta page with a
//         persisted continuation, shared mailbox (/users/…, 403 named)
//    T17  expired delta → full reconciliation without duplicate captures
//    MIME attached .eml and inline images preserved byte-for-byte; file /
//         item / reference attachments recorded (references not invented)
//    Inbox = the Inbox well-known folder, never /me/messages
//    audience: a Graph token is never an IMAP / EWS token; placeholder
//         client IDs refused; PKCE sign-in configuration
//    error mapping, redirects to other hosts, permission before every request
//

import XCTest
import Foundation
import CryptoKit
@testable import MailConnectivity
@testable import ArchiveCore

final class GraphAdapterTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("graph-adapter-\(UUID().uuidString)", isDirectory: true)
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

    /// Hands out one Graph token; counts refreshes.
    struct StaticTokens: AccessTokenSource {
        let token: String
        func accessToken(for account: UUID, audience: String) async throws -> String {
            guard audience == GraphAudience.resource() else { throw OAuthError.audienceMismatch(expected: audience, found: GraphAudience.resource()) }
            return token
        }
        func refreshAfterRejection(account: UUID, audience: String) async throws -> String { token }
    }

    static let plenty = StorageProbe(reserveBytes: 1_024, availableBytes: { _ in 1 << 40 })
    static let token = "graph-access-token"

    func makeSink(_ name: String = "archive") -> ConnectedArchiveSink {
        ConnectedArchiveSink(storeDirectory: dir.appendingPathComponent(name, isDirectory: true))
    }

    func register(_ account: UUID, in sink: ConnectedArchiveSink, identity: String = "asha@contoso.com") async throws {
        try await sink.saveAccount(ConnectedAccountRecord(
            accountID: account, provider: .microsoftGraph, issuer: "https://login.microsoftonline.com/common/v2.0",
            displayIdentity: identity, enabledModes: ["capture"], connectionState: "connected", createdAt: Date(), updatedAt: Date()))
    }

    func makeAdapter(_ sim: GraphSimulator, account: UUID = UUID(), mailbox: GraphMailbox = .me,
                     options: GraphAdapterOptions = GraphAdapterOptions(pageSize: 3),
                     asks: Box<[NetworkAsk]> = Box([]), refuse: Box<Bool> = Box(false)) -> GraphAdapter {
        GraphAdapter(accountID: account, mailbox: mailbox, transport: sim, permission: { ask in
            asks.mutate { $0.append(ask) }
            if refuse.value { throw Refused() }
        }, options: options)
    }

    func makeEngine(_ adapter: GraphAdapter, _ sink: ConnectedArchiveSink, asks: Box<[NetworkAsk]> = Box([]),
                    waits: Box<[TimeInterval]> = Box([])) -> SyncEngine {
        SyncEngine(adapter: adapter, sink: sink, scheduler: FairDownloadScheduler(totalSlots: 4),
                   tokens: StaticTokens(token: Self.token),
                   permission: { ask in asks.mutate { $0.append(ask) } },
                   backoff: BackoffPolicy(base: 1, maximum: 60, transientAttempts: 4, maximumThrottleWait: 1_800,
                                          jitter: { 0.5 }, sleep: { s in waits.mutate { $0.append(s) }; await Task.yield() }),
                   storage: Self.plenty)
    }

    var ctx: ProviderRequestContext { ProviderRequestContext(accountID: UUID(), accessToken: Self.token, attempt: 0) }

    /// Immutable ids preserved for `account`.
    func capturedIDs(_ sink: ConnectedArchiveSink, account: UUID, mailbox: String = "me") async throws -> [String] {
        try await sink.store.remoteMessageDigests().filter { $0.account == account }.compactMap { row in
            guard case .graph(let box, let id) = try ProviderMessageIdentity(key: row.key) else { return nil }
            XCTAssertEqual(box, mailbox)
            return id
        }
    }

    func memberships(_ sink: ConnectedArchiveSink, account: UUID, id: String, mailbox: String = "me") async throws -> [String] {
        let key = try ProviderMessageIdentity.graph(mailbox: mailbox, immutableID: id).key()
        guard let row = try await sink.store.remoteMessageDigests().first(where: { $0.account == account && $0.key == key }),
              let emailID = row.emailID,
              let provenance = try await sink.provenance(emailID: emailID) else { return [] }
        return provenance.memberships
    }

    func assertBytesExact(_ sink: ConnectedArchiveSink, _ sim: GraphSimulator, account: UUID, mailbox: String? = nil,
                          file: StaticString = #filePath, line: UInt = #line) async throws {
        for row in try await sink.store.remoteMessageDigests() where row.account == account {
            guard case .graph(_, let id) = try ProviderMessageIdentity(key: row.key) else { continue }
            XCTAssertTrue(sink.store.blobStore.exists(BlobReference(digest: row.digest, length: 0)), "\(id) has its bytes", file: file, line: line)
            guard let mime = await sim.mimeOf(id, mailbox: mailbox) else { continue }
            XCTAssertEqual(row.digest, Self.sha(mime), "\(id) preserved byte-exact", file: file, line: line)
        }
    }

    static func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    static func jwt(aud: String) -> String {
        func b64(_ s: String) -> String {
            Data(s.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        return b64(#"{"alg":"RS256","typ":"JWT"}"#) + "." + b64(#"{"aud":"\#(aud)","scp":"Mail.Read"}"#) + ".c2ln"
    }

    /// A standard mailbox: Inbox, Sent Items, Deleted Items.
    func standardFolders(_ sim: GraphSimulator) async {
        await sim.addFolder("AAMk-inbox", name: "Inbox", wellKnown: "inbox")
        await sim.addFolder("AAMk-sent", name: "Sent Items", wellKnown: "sentitems")
        await sim.addFolder("AAMk-deleted", name: "Deleted Items", wellKnown: "deleteditems")
    }

    // MARK: T10 — deep folder tree

    func testT10_deepFolderTree_everyLevelAndPage_hiddenOnlyWhenAsked() async throws {
        let sim = GraphSimulator()
        await sim.setFolderPageSize(4)                       // forces nextLink on top level and childFolders
        await standardFolders(sim)
        for i in 0..<6 { await sim.addFolder("top\(i)", name: "Top \(i)") }    // 10 top-level folders → 3 pages
        await sim.addFolder("proj", name: "Projects")
        var parent = "proj"
        for level in 1...9 {                                 // nine levels below Projects
            parent = await sim.addFolder("L\(level)", name: "Level \(level)", parent: parent)
        }
        for i in 0..<11 { await sim.addFolder("wide\(i)", name: "Client/\(i)", parent: "L3") }   // 11 siblings → 3 child pages; "/" in a name
        await sim.addFolder("hidden", name: "Hidden stuff", hidden: true)
        await sim.addFolder("hiddenChild", name: "Under hidden", parent: "hidden")
        for i in 0..<7 { await sim.addMessage("deep-\(i)", folder: "L9") }   // 3 message pages (pageSize 3)
        await sim.addMessage("wide-msg", folder: "wide10")
        await sim.addMessage("inbox-1", folder: "AAMk-inbox")
        await sim.addMessage("hidden-msg", folder: "hidden")
        await sim.addMessage("hidden-child-msg", folder: "hiddenChild")

        let sink = makeSink()
        let account = UUID()
        try await register(account, in: sink)
        let asks = Box<[NetworkAsk]>([])
        let adapter = makeAdapter(sim, account: account, asks: asks)
        let report = await makeEngine(adapter, sink).sync()
        XCTAssertEqual(report.outcome, .completed)

        let visibleFolders = 3 + 6 + 1 + 9 + 11
        let counts = try await sink.store.connectedTableCounts()
        XCTAssertEqual(counts["remote_folders"], visibleFolders, "every level and every page of the tree; hidden folders not by default")
        let ids = Set(try await capturedIDs(sink, account: account))
        XCTAssertEqual(ids, Set((0..<7).map { "deep-\($0)" } + ["wide-msg", "inbox-1"]))
        let deep = try await memberships(sink, account: account, id: "deep-6")
        XCTAssertEqual(deep, ["Projects/Level 1/Level 2/Level 3/Level 4/Level 5/Level 6/Level 7/Level 8/Level 9"])
        let wide = try await memberships(sink, account: account, id: "wide-msg")
        XCTAssertEqual(wide, ["Projects/Level 1/Level 2/Level 3/Client\u{2215}10"], "a \"/\" in a folder name is not a level")
        try await assertBytesExact(sink, sim, account: account)

        // Every request asked the adapter's permission first, carried the immutable-id preference, went to Graph.
        let requests = await sim.requests
        XCTAssertEqual(asks.value.count, requests.count)
        XCTAssertTrue(asks.value.allSatisfy { $0.host == "graph.microsoft.com" && $0.destination == .mailServer })
        XCTAssertTrue(requests.allSatisfy { ($0.header("Prefer") ?? "").contains(#"IdType="ImmutableId""#) })
        XCTAssertTrue(requests.allSatisfy { $0.header("Authorization") == "Bearer \(Self.token)" })
        XCTAssertTrue(requests.contains { $0.url.absoluteString.contains("$skip=") && $0.url.path.hasSuffix("/childFolders") },
                      "childFolders followed through its nextLink")

        // Hidden folders when asked for.
        let sink2 = makeSink("hidden")
        let account2 = UUID()
        try await register(account2, in: sink2)
        let withHidden = makeAdapter(sim, account: account2, options: GraphAdapterOptions(includeHiddenFolders: true, pageSize: 3))
        let report2 = await makeEngine(withHidden, sink2).sync()
        XCTAssertEqual(report2.outcome, .completed)
        let counts2 = try await sink2.store.connectedTableCounts()
        XCTAssertEqual(counts2["remote_folders"], visibleFolders + 2)
        let ids2 = Set(try await capturedIDs(sink2, account: account2))
        XCTAssertTrue(ids2.isSuperset(of: ["hidden-msg", "hidden-child-msg"]))
        let hiddenChild = try await memberships(sink2, account: account2, id: "hidden-child-msg")
        XCTAssertEqual(hiddenChild, ["Hidden stuff/Under hidden"])
    }

    // MARK: T10 — moves keep the immutable identity

    func testT10_moveBetweenFolders_immutableIdentityStable_noDuplicate() async throws {
        let sim = GraphSimulator()
        await standardFolders(sim)
        await sim.addFolder("A", name: "Alpha")
        await sim.addFolder("B", name: "Beta", parent: "A")
        for i in 0..<5 { await sim.addMessage("m\(i)", folder: "A") }
        let sink = makeSink()
        let account = UUID()
        try await register(account, in: sink)
        let adapter = makeAdapter(sim, account: account)
        let engine = makeEngine(adapter, sink)
        let first = await engine.sync()
        XCTAssertEqual(first.outcome, .completed)
        let v1 = try await capturedIDs(sink, account: account).count
        XCTAssertEqual(v1, 5)

        await sim.move("m1", to: "B")                      // within the tree
        await sim.move("m2", to: "AAMk-deleted")           // "deleted" in Outlook = moved to Deleted Items
        await sim.delete("m3")                             // hard delete
        await sim.addMessage("m5", folder: "B")
        let second = await engine.sync()
        XCTAssertEqual(second.outcome, .completed)
        XCTAssertFalse(second.fullEnumeration, "per-folder delta, not a re-listing")

        let ids = try await capturedIDs(sink, account: account)
        XCTAssertEqual(ids.count, 6, "one record per immutable id: a moved message is not captured again")
        XCTAssertEqual(Set(ids), ["m0", "m1", "m2", "m3", "m4", "m5"], "the hard-deleted m3 stays preserved")
        let downloads = await sim.valueDownloads
        XCTAssertEqual(downloads["m1"], 1); XCTAssertEqual(downloads["m2"], 1); XCTAssertEqual(downloads["m5"], 1)
        let m1 = try await memberships(sink, account: account, id: "m1")
        XCTAssertEqual(Set(m1), ["Alpha", "Alpha/Beta"], "the move is a new membership of the same record")
        let m2 = try await memberships(sink, account: account, id: "m2")
        XCTAssertTrue(m2.contains("Deleted Items"))
        let completeness = try await sink.completeness(accountID: account)
        XCTAssertEqual(completeness.acquisition.captured, 6)
        try await assertBytesExact(sink, sim, account: account)
    }

    // MARK: T10 — empty delta page with continuation

    func testT10_emptyDeltaPageWithContinuation_isPersistedAndResumed() async throws {
        let sim = GraphSimulator()
        await standardFolders(sim)
        await sim.addFolder("A", name: "Alpha")
        for i in 0..<4 { await sim.addMessage("a\(i)", folder: "A") }
        let sink = makeSink()
        let account = UUID()
        try await register(account, in: sink)
        let adapter = makeAdapter(sim, account: account)
        let first = await makeEngine(adapter, sink).sync()
        XCTAssertEqual(first.outcome, .completed)

        for i in 4..<9 { await sim.addMessage("a\(i)", folder: "A") }     // 5 new: two real pages after the empty ones
        await sim.setEmptyContinuationPages(2)
        let killer = makeEngine(adapter, sink)
        await killer.setAbortFilter { $0 is Killed }
        await killer.setFaultHook { boundary in if boundary == .afterChangePage { throw Killed() } }
        let killed = await killer.sync(.folders(["A"]))
        XCTAssertEqual(killed.outcome, .aborted)
        let served = await sim.emptyPagesServed
        XCTAssertEqual(served, 1, "the run died right after the first (empty) continuation page")
        let cp = try await sink.checkpoint(accountID: account, scope: ChangeScope.folder(
            RemoteFolderOccurrence(serverID: "A", displayPath: "Alpha")).checkpointScope)
        let cursor = try XCTUnwrap(cp?.cursor)
        XCTAssertTrue(cursor.contains("$skiptoken="), "the empty page's nextLink was persisted, not skipped: \(cursor)")
        XCTAssertTrue(cp?.bootstrapState.hasPrefix("ready@") == true)

        let resumed = await makeEngine(adapter, sink).sync()
        XCTAssertEqual(resumed.outcome, .completed)
        let requests = await sim.requests
        XCTAssertTrue(requests.contains { $0.url.absoluteString == cursor }, "the restart asked for exactly the persisted continuation")
        let emptyServed = await sim.emptyPagesServed
        XCTAssertEqual(emptyServed, 2)
        let ids = try await capturedIDs(sink, account: account)
        XCTAssertEqual(ids.count, 9)
        XCTAssertEqual(Set(ids), Set((0..<9).map { "a\($0)" }))
        let downloads = await sim.totalValueDownloads
        XCTAssertEqual(downloads, 9, "nothing downloaded twice")
    }

    // MARK: T10 — shared mailbox

    func testT10_sharedMailbox_usersPath_mailboxQualifiedIdentity_and403Named() async throws {
        let sim = GraphSimulator()
        await standardFolders(sim)
        await sim.addMessage("own-1", folder: "AAMk-inbox")
        await sim.addMailbox("team@contoso.com")
        await sim.addFolder("T-inbox", name: "Inbox", wellKnown: "inbox", mailbox: "team@contoso.com")
        await sim.addFolder("T-cases", name: "Cases", parent: "T-inbox", mailbox: "team@contoso.com")
        for i in 0..<4 { await sim.addMessage("team-\(i)", folder: i < 2 ? "T-inbox" : "T-cases", mailbox: "team@contoso.com") }
        await sim.addMailbox("boss@contoso.com")
        await sim.deny("boss@contoso.com")

        let sink = makeSink()
        let account = UUID()
        try await register(account, in: sink, identity: "team@contoso.com")
        let adapter = makeAdapter(sim, account: account, mailbox: .user("Team@Contoso.com"))
        let report = await makeEngine(adapter, sink).sync()
        XCTAssertEqual(report.outcome, .completed)
        let ids = Set(try await capturedIDs(sink, account: account, mailbox: "team@contoso.com"))
        XCTAssertEqual(ids, ["team-0", "team-1", "team-2", "team-3"], "the shared mailbox's mail, not the signed-in user's")
        let requests = await sim.requests
        XCTAssertTrue(requests.allSatisfy { $0.url.path.hasPrefix("/v1.0/users/Team@Contoso.com/") }, "every request through /users/{upn}")
        let cases = try await memberships(sink, account: account, id: "team-3", mailbox: "team@contoso.com")
        XCTAssertEqual(cases, ["Inbox/Cases"])
        try await assertBytesExact(sink, sim, account: account, mailbox: "team@contoso.com")

        // Not permitted: the run says so by name and claims nothing.
        let sink2 = makeSink("boss")
        let account2 = UUID()
        try await register(account2, in: sink2, identity: "boss@contoso.com")
        let denied = await makeEngine(makeAdapter(sim, account: account2, mailbox: .user("boss@contoso.com")), sink2).sync()
        guard case .failed(let why) = denied.outcome else { return XCTFail("expected a named failure, got \(denied.outcome)") }
        XCTAssertTrue(why.contains("mailboxAccessDenied"), why)
        XCTAssertTrue(why.contains("boss@contoso.com"), why)
        XCTAssertFalse(denied.outcome.isCompletion)
        let v3 = try await capturedIDs(sink2, account: account2, mailbox: "boss@contoso.com").count
        XCTAssertEqual(v3, 0)
    }

    // MARK: T17 — expired delta

    func testT17_expiredDelta_fullReconciliation_noDuplicateCaptures() async throws {
        let sim = GraphSimulator()
        await standardFolders(sim)
        await sim.addFolder("A", name: "Alpha")
        for i in 0..<8 { await sim.addMessage("x\(i)", folder: i.isMultiple(of: 2) ? "A" : "AAMk-inbox") }
        let sink = makeSink()
        let account = UUID()
        try await register(account, in: sink)
        let adapter = makeAdapter(sim, account: account)
        let engine = makeEngine(adapter, sink)
        let first = await engine.sync()
        XCTAssertEqual(first.outcome, .completed)

        await sim.addMessage("x8", folder: "A")
        await sim.move("x1", to: "A")
        await sim.expireDeltaTokens()
        let second = await engine.sync()
        XCTAssertEqual(second.outcome, .completed)
        XCTAssertTrue(second.fullEnumeration, "the expired delta started a new generation")
        let requests = await sim.requests
        XCTAssertTrue(requests.contains { $0.url.absoluteString.contains("$deltatoken=latest") })
        let ids = try await capturedIDs(sink, account: account)
        XCTAssertEqual(ids.count, 9, "old data kept, nothing multiplied")
        let downloads = await sim.totalValueDownloads
        XCTAssertEqual(downloads, 9, "only the new message was downloaded again")
        let x1 = try await memberships(sink, account: account, id: "x1")
        XCTAssertEqual(Set(x1), ["Inbox", "Alpha"])
        let receipt = try XCTUnwrap(second.receipt)
        XCTAssertEqual(receipt.stored, 1)
        XCTAssertEqual(receipt.pending, 0)

        // A service without $deltatoken=latest: the initial round is walked to its end.
        let sink2 = makeSink("nolatest")
        let account2 = UUID()
        try await register(account2, in: sink2)
        await sim.setSupportsLatest(false)
        let report = await makeEngine(makeAdapter(sim, account: account2), sink2).sync()
        XCTAssertEqual(report.outcome, .completed)
        let v5 = try await capturedIDs(sink2, account: account2).count
        XCTAssertEqual(v5, 9)
    }

    // MARK: MIME — attached messages, inline images, reference attachments

    static func richMIME() -> Data {
        let head: [String] = [
            "Message-ID: <rich@contoso.example>", "From: Asha <asha@contoso.com>", "To: ravi@example.org",
            "Subject: Report with attachments", "Date: Mon, 6 Jan 2025 10:00:00 +0000", "MIME-Version: 1.0",
            "Content-Type: multipart/mixed; boundary=\"outer\"", "",
            "--outer", "Content-Type: multipart/related; boundary=\"rel\"", "",
            "--rel", "Content-Type: text/html; charset=utf-8", "", "<p>See <img src=\"cid:logo@x\"> \u{FC}</p>",
            "--rel", "Content-Type: image/png", "Content-ID: <logo@x>", "Content-Disposition: inline; filename=\"logo.png\"",
            "Content-Transfer-Encoding: binary", "", "",
        ]
        let tail: [String] = [
            "", "--rel--",
            "--outer", "Content-Type: message/rfc822", "Content-Disposition: attachment; filename=\"forwarded.eml\"", "",
            "Message-ID: <inner@contoso.example>", "Subject: Inner", "MIME-Version: 1.0",
            "Content-Type: multipart/related; boundary=\"in\"", "",
            "--in", "Content-Type: text/plain", "", "inner body",
            "--in", "Content-Type: image/jpeg", "Content-ID: <pic@in>", "Content-Transfer-Encoding: base64", "", "/9j/4AAQSkZJRg==",
            "--in--", "--outer--", "",
        ]
        var d = Data(head.joined(separator: "\r\n").utf8)
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0xFF, 0xFE, 0x0A, 0x0D, 0x00, 0x80]
        d.append(contentsOf: png)
        d.append(Data(tail.joined(separator: "\r\n").utf8))
        return d
    }

    func testMIME_attachedEmlAndInlineImages_byteForByte_referenceAttachmentRecordedNotInvented() async throws {
        let sim = GraphSimulator()
        await standardFolders(sim)
        let mime = Self.richMIME()
        await sim.addMessage("rich", folder: "AAMk-inbox", mime: mime, attachments: [
            .init(type: "#microsoft.graph.fileAttachment", name: "logo.png", contentType: "image/png", size: 15, isInline: true),
            .init(type: "#microsoft.graph.itemAttachment", name: "forwarded.eml", contentType: "message/rfc822", size: 300, isInline: false),
            .init(type: "#microsoft.graph.referenceAttachment", name: "Budget.xlsx", contentType: "application/vnd.ms-excel", size: 0, isInline: false),
        ])
        let sink = makeSink()
        let account = UUID()
        try await register(account, in: sink)
        let adapter = makeAdapter(sim, account: account)
        let report = await makeEngine(adapter, sink).sync()
        XCTAssertEqual(report.outcome, .completed)
        let rows = try await sink.store.remoteMessageDigests().filter { $0.account == account }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.digest, Self.sha(mime), "the MIME with its attached .eml and inline images, byte for byte")
        let provenance = try await sink.provenance(emailID: XCTUnwrap(rows.first?.emailID))
        XCTAssertEqual(provenance?.representation, "graph-mime", "recorded as a provider-produced representation")
        XCTAssertEqual(provenance?.byteCount, Int64(mime.count), "no bytes added for the reference attachment")

        // The metadata the adapter hands the sink.
        let staging = try sink.makeStagingWriter()
        let bytes = RawByteSink(writer: staging)
        _ = try await adapter.listFolders(pageToken: nil, context: ctx)
        let fetched = try await adapter.fetchRaw(RemoteItemRef(identity: .graph(mailbox: "me", immutableID: "rich"), folder: nil),
                                                into: bytes, context: ctx)
        XCTAssertEqual(bytes.bytesWritten, Int64(mime.count))
        XCTAssertEqual(fetched.expectedByteCount, Int64(mime.count))
        bytes.discard()
        XCTAssertEqual(fetched.metadata.representation, .graphMIME)
        XCTAssertEqual(fetched.metadata.revision, "ck1")
        XCTAssertNotNil(fetched.metadata.internalDate)
        XCTAssertEqual(fetched.metadata.flags, ["flagged"])
        XCTAssertEqual(fetched.metadata.extra["graphRepresentation"], GraphAdapter.mimeRepresentationNote)
        let all = try XCTUnwrap(fetched.metadata.extra["graphAttachments"])
        XCTAssertTrue(all.contains(#""kind":"file""#) && all.contains(#""kind":"item""#) && all.contains(#""kind":"reference""#), all)
        let refs = try XCTUnwrap(fetched.metadata.extra["graphReferenceAttachments"])
        XCTAssertTrue(refs.contains("Budget.xlsx"), refs)
        XCTAssertFalse(refs.contains("logo.png"))
        XCTAssertNotNil(fetched.metadata.extra["graphReferenceAttachmentNote"])
        XCTAssertEqual(fetched.occurrences.map(\.displayPath), ["Inbox"])
        XCTAssertEqual(fetched.occurrences.first?.specialUse, "inbox")
    }

    // MARK: Inbox = the Inbox well-known folder

    func testInbox_meansTheWellKnownInboxFolder_neverTheMessagesCollection() async throws {
        let sim = GraphSimulator()
        // A German mailbox: the Inbox is not called "Inbox"; a user folder IS called "Inbox".
        await sim.addFolder("AAMk-posteingang", name: "Posteingang", wellKnown: "inbox")
        await sim.addFolder("AAMk-gesendet", name: "Gesendete Elemente", wellKnown: "sentitems")
        await sim.addFolder("AAMk-fake", name: "Inbox")
        await sim.addMessage("in-1", folder: "AAMk-posteingang")
        await sim.addMessage("in-2", folder: "AAMk-posteingang")
        await sim.addMessage("sent-1", folder: "AAMk-gesendet")
        await sim.addMessage("fake-1", folder: "AAMk-fake")

        let adapter = makeAdapter(sim)
        var folders: [RemoteFolderOccurrence] = []
        var token: String?
        repeat {
            let page = try await adapter.listFolders(pageToken: token, context: ctx)
            folders += page.folders; token = page.nextPageToken
        } while token != nil
        let inbox = try XCTUnwrap(folders.first { $0.specialUse == "inbox" })
        XCTAssertEqual(inbox.serverID, "AAMk-posteingang")
        XCTAssertEqual(inbox.displayPath, "Posteingang")
        XCTAssertNil(folders.first { $0.serverID == "AAMk-fake" }?.specialUse, "a folder named Inbox is not the Inbox")
        XCTAssertEqual(folders.first { $0.serverID == "AAMk-gesendet" }?.specialUse, "sentitems")
        let resolved = await adapter.wellKnownFolderID("inbox")
        XCTAssertEqual(resolved, "AAMk-posteingang")

        // Capturing the Inbox selection captures the Inbox, nothing else.
        let sink = makeSink()
        let account = UUID()
        try await register(account, in: sink)
        let engineAdapter = makeAdapter(sim, account: account)
        let report = await makeEngine(engineAdapter, sink).sync(.folders([inbox.serverID]))
        XCTAssertEqual(report.outcome, .completed)
        let v7 = Set(try await capturedIDs(sink, account: account))
        XCTAssertEqual(v7, ["in-1", "in-2"])
        let collection = await sim.collectionRequests
        XCTAssertEqual(collection, 0, "the /me/messages collection (every folder) is never read as the Inbox")
        let requests = await sim.requests
        XCTAssertFalse(requests.contains { $0.url.path == "/v1.0/me/messages" })
        XCTAssertTrue(requests.contains { $0.url.path == "/v1.0/me/mailFolders/inbox" })
        XCTAssertTrue(requests.contains { $0.url.path == "/v1.0/me/mailFolders/AAMk-posteingang/messages" })
    }

    // MARK: Audience and sign-in configuration

    func testAudience_graphTokenNeverAnIMAPToken_placeholderClientRefused_PKCEConfiguration() async throws {
        let redirect = URL(string: "msauth.com.ecosanskriti.mailin://auth")!
        for placeholder in ["", "YOUR_CLIENT_ID", "00000000-0000-0000-0000-000000000000", "<client-id>", "not-a-guid", " 6731de76-14a6-49ae-97bc-6eba6914391e"] {
            XCTAssertThrowsError(try GraphOAuth.configuration(GraphSignInSettings(clientID: placeholder, redirectURI: redirect)), placeholder) {
                XCTAssertEqual($0 as? GraphConfigurationError, .placeholderClientID(placeholder))
            }
        }
        XCTAssertThrowsError(try GraphOAuth.configuration(GraphSignInSettings(clientID: "6731de76-14a6-49ae-97bc-6eba6914391e",
                                                                              tenant: "contoso/../evil", redirectURI: redirect)))
        XCTAssertThrowsError(try GraphOAuth.configuration(GraphSignInSettings(clientID: "6731de76-14a6-49ae-97bc-6eba6914391e",
                                                                              redirectURI: URL(string: "http://example.com/cb")!)))

        let settings = GraphSignInSettings(clientID: "6731de76-14a6-49ae-97bc-6eba6914391e", tenant: "contoso.onmicrosoft.com",
                                           redirectURI: redirect, sharedMailboxes: true)
        let config = try GraphOAuth.configuration(settings)
        XCTAssertEqual(config.authorizationEndpoint.absoluteString, "https://login.microsoftonline.com/contoso.onmicrosoft.com/oauth2/v2.0/authorize")
        XCTAssertEqual(config.tokenEndpoint.absoluteString, "https://login.microsoftonline.com/contoso.onmicrosoft.com/oauth2/v2.0/token")
        XCTAssertEqual(config.issuer, "https://login.microsoftonline.com/contoso.onmicrosoft.com/v2.0")
        XCTAssertEqual(config.scopes, ["https://graph.microsoft.com/Mail.Read", "https://graph.microsoft.com/Mail.Read.Shared", "offline_access"])
        XCTAssertFalse(config.scopes.contains { $0.contains("Send") || $0.contains("ReadWrite") }, "capture asks for reading only")
        XCTAssertEqual(config.audience, "https://graph.microsoft.com")
        XCTAssertTrue(config.sendsScopeOnRefresh)
        let capture = try GraphOAuth.configuration(GraphSignInSettings(clientID: "6731de76-14a6-49ae-97bc-6eba6914391e", redirectURI: redirect))
        XCTAssertEqual(capture.scopes, ["https://graph.microsoft.com/Mail.Read", "offline_access"])
        XCTAssertTrue(capture.authorizationEndpoint.absoluteString.contains("/common/"))

        let session = OAuthSession(accountID: UUID(), configuration: config, transport: FakeTokenEndpoint())
        let authorize = try await session.begin()
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: authorize, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(query["client_id"], settings.clientID)
        XCTAssertEqual(query["code_challenge"]?.count, 43)
        XCTAssertNil(query["client_secret"])

        // Exchange protocol scopes are never part of a Graph configuration.
        for foreign in ["https://outlook.office.com/IMAP.AccessAsUser.All", "https://outlook.office.com/SMTP.Send",
                        "https://outlook.office365.com/EWS.AccessAsUser.All", "https://graph.microsoft.com/Mail.ReadWrite"] {
            XCTAssertThrowsError(try GraphOAuth.validateScopes([foreign]), foreign)
        }

        // The coordinator binds the stored set to Graph: an IMAP audience never gets it.
        let account = UUID()
        let credentials = InMemoryCredentialStore()
        let coordinator = TokenRefreshCoordinator(credentials: credentials, transport: FakeTokenEndpoint())
        await coordinator.register(account: account, configuration: config)
        try await coordinator.store(OAuthTokenSet(accountID: account, issuer: config.issuer, audience: config.audience,
                                                  accessToken: "graph-at", refreshToken: "rt", expiresAt: Date().addingTimeInterval(3600),
                                                  scopes: config.scopes))
        let graph = try await coordinator.accessToken(for: account, audience: GraphAudience.resource())
        XCTAssertEqual(graph, "graph-at")
        do {
            _ = try await coordinator.accessToken(for: account, audience: "https://outlook.office.com")
            XCTFail("a Graph token must not be handed to IMAP / SMTP / EWS")
        } catch {
            XCTAssertEqual(error as? OAuthError, .audienceMismatch(expected: "https://outlook.office.com", found: "https://graph.microsoft.com"))
        }

        // The adapter asks for the Graph audience and refuses to send a token for another resource.
        let sim = GraphSimulator()
        await standardFolders(sim)
        let adapter = makeAdapter(sim)
        XCTAssertEqual(adapter.tokenAudience, config.audience)
        XCTAssertEqual(adapter.mailHost, "graph.microsoft.com")
        XCTAssertEqual(adapter.authorizationHost, "login.microsoftonline.com")
        let imapToken = Self.jwt(aud: "https://outlook.office.com")
        do {
            _ = try await adapter.listFolders(pageToken: nil, context: ProviderRequestContext(accountID: UUID(), accessToken: imapToken, attempt: 0))
            XCTFail("an Outlook IMAP token must not be sent to Graph")
        } catch MailProviderError.permanent(let why) {
            XCTAssertTrue(why.hasPrefix("tokenAudience"), why)
        }
        let sentAfterRefusal = await sim.requests.count
        XCTAssertEqual(sentAfterRefusal, 0, "the token never left the device")
        let graphJWT = Self.jwt(aud: "00000003-0000-0000-c000-000000000000")
        _ = try await adapter.listFolders(pageToken: nil, context: ProviderRequestContext(accountID: UUID(), accessToken: graphJWT, attempt: 0))
        let sent = await sim.requests.count
        XCTAssertEqual(sent, 1)
        XCTAssertFalse(GraphAdapter.inPlaceArchiveNotice.isEmpty)
        XCTAssertTrue(GraphAdapter.inPlaceArchiveNotice.contains("in-place archive"))
    }

    // MARK: Errors, redirects, permission

    func testErrorMapping_redirectsToOtherHostsNeverGetTheToken_permissionBeforeEveryRequest() async throws {
        let sim = GraphSimulator()
        await standardFolders(sim)
        await sim.addMessage("e1", folder: "AAMk-inbox")
        let asks = Box<[NetworkAsk]>([])
        let refuse = Box(false)
        let adapter = makeAdapter(sim, asks: asks, refuse: refuse)
        let inbox = RemoteFolderOccurrence(serverID: "AAMk-inbox", displayPath: "Inbox")
        let ref = RemoteItemRef(identity: .graph(mailbox: "me", immutableID: "e1"), folder: inbox)

        func enumError() async -> Error? {
            do { _ = try await adapter.enumerate(folder: inbox, cursor: nil, pageSize: 10, context: ctx); return nil } catch { return error }
        }
        await sim.fail("/messages", status: 401, code: "InvalidAuthenticationToken")
        let v9 = await enumError() as? MailProviderError
        XCTAssertEqual(v9, .unauthorized)
        await sim.fail("/messages", status: 429, headers: ["Retry-After": "7"])
        let v11 = await enumError() as? MailProviderError
        XCTAssertEqual(v11, .rateLimited(retryAfter: 7))
        await sim.fail("/messages", status: 503, headers: ["Retry-After": "12"])
        let v13 = await enumError() as? MailProviderError
        XCTAssertEqual(v13, .rateLimited(retryAfter: 12))
        await sim.fail("/messages", status: 500)
        if case .transient? = await enumError() as? MailProviderError {} else { XCTFail("5xx is transient") }
        await sim.fail("/messages", status: 403, code: "ErrorAccessDenied")
        if case .permanent(let why)? = await enumError() as? MailProviderError { XCTAssertTrue(why.hasPrefix("mailboxAccessDenied"), why) } else { XCTFail("403 is named") }
        await sim.fail("/messages", status: 404, code: "ErrorItemNotFound")
        let v15 = await enumError() as? MailProviderError
        XCTAssertEqual(v15, .folderUnavailable("AAMk-inbox"))

        // 404 for one message → itemUnavailable.
        let sink = makeSink()
        func fetch(_ r: RemoteItemRef) async -> Error? {
            let bytes = RawByteSink(writer: try! sink.makeStagingWriter())
            defer { bytes.discard() }
            do { _ = try await adapter.fetchRaw(r, into: bytes, context: ctx); return nil } catch { return error }
        }
        let v17 = await fetch(RemoteItemRef(identity: .graph(mailbox: "me", immutableID: "gone"), folder: inbox)) as? MailProviderError
        XCTAssertEqual(v17, .itemUnavailable)
        await sim.fail("/$value", status: 404)
        let v19 = await fetch(ref) as? MailProviderError
        XCTAssertEqual(v19, .itemUnavailable)

        // Expired delta: 410, and syncStateNotFound under a 400.
        let boundary = try await adapter.changeBoundary(scope: .folder(inbox), context: ctx)
        XCTAssertTrue(boundary.contains("$deltatoken="))
        await sim.fail("/delta", status: 410, code: "SyncStateNotFound")
        do { _ = try await adapter.changes(scope: .folder(inbox), since: boundary, context: ctx); XCTFail() } catch {
            XCTAssertEqual(error as? MailProviderError, .changeTokenExpired)
        }
        await sim.fail("/delta", status: 400, code: "syncStateNotFound")
        do { _ = try await adapter.changes(scope: .folder(inbox), since: boundary, context: ctx); XCTFail() } catch {
            XCTAssertEqual(error as? MailProviderError, .changeTokenExpired)
        }
        let page = try await adapter.changes(scope: .folder(inbox), since: boundary, context: ctx)
        XCTAssertFalse(page.hasMore)
        XCTAssertTrue(page.changes.isEmpty)

        // A redirect to another host: refused, and that host never sees the token.
        await sim.redirect("/$value", to: "https://evil.example/steal")
        if case .permanent(let why)? = await fetch(ref) as? MailProviderError { XCTAssertTrue(why.hasPrefix("graphRedirectRefused"), why) } else { XCTFail("cross-host redirect refused") }
        let foreign = await sim.foreignRequests
        XCTAssertTrue(foreign.isEmpty, "no request — with or without the bearer token — went to the other host")
        // A same-host redirect is followed (with the token).
        let valueURL = try await adapter.url(["messages", "e1", "$value"])
        await sim.redirect("/$value", to: valueURL.absoluteString)
        let v21 = await fetch(ref)
        XCTAssertNil(v21)
        // A stored cursor naming another host is never requested.
        do {
            _ = try await adapter.enumerate(folder: inbox, cursor: "https://evil.example/v1.0/me/mailFolders/x/messages?$skip=3", pageSize: 10, context: ctx)
            XCTFail()
        } catch MailProviderError.permanent(let why) { XCTAssertTrue(why.hasPrefix("graphForeignHost"), why) }
        do {
            _ = try await adapter.changes(scope: .folder(inbox), since: "http://graph.microsoft.com/v1.0/me/mailFolders/x/messages/delta", context: ctx)
            XCTFail("plain http is not Graph")
        } catch MailProviderError.permanent(let why) { XCTAssertTrue(why.hasPrefix("graphForeignHost"), why) }
        let foreignAfter = await sim.foreignRequests
        XCTAssertTrue(foreignAfter.isEmpty)

        // The permission was asked before every request that reached the service.
        let reached = await sim.requests.count
        XCTAssertEqual(asks.value.count, reached)
        // A refusal sends nothing.
        refuse.mutate { $0 = true }
        do { _ = try await adapter.listFolders(pageToken: nil, context: ctx); XCTFail() } catch {
            guard case SyncEngine.Stop.notPermitted? = error as? SyncEngine.Stop else { return XCTFail("\(error)") }
        }
        let afterRefusal = await sim.requests.count
        XCTAssertEqual(afterRefusal, reached)

        // Through the engine: 429 Retry-After is honoured, the run completes.
        refuse.mutate { $0 = false }
        let engineSink = makeSink("engine")
        let account = UUID()
        try await register(account, in: engineSink)
        await sim.fail("/$value", status: 429, headers: ["Retry-After": "9"])
        let waits = Box<[TimeInterval]>([])
        let report = await makeEngine(makeAdapter(sim, account: account), engineSink, waits: waits).sync()
        XCTAssertEqual(report.outcome, .completed)
        XCTAssertEqual(waits.value.count, 1)
        XCTAssertGreaterThanOrEqual(waits.value.first ?? 0, 9, "Retry-After: 9 honoured")
        let v23 = try await capturedIDs(engineSink, account: account)
        XCTAssertEqual(v23, ["e1"])
    }
}
