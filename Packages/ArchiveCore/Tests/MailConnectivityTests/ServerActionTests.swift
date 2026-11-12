//
//  ServerActionTests.swift
//  MailConnectivityTests
//
//  V4-11 (plan v4 §3 A17, §6 "Server actions and safe cleanup", T41–T43, RQ10):
//  journalled server actions and the separate verified cleanup workflow,
//  against the localhost IMAP server and the Gmail / Graph simulators.
//    T41  another client changed the message first → conflict for that item
//         only; nothing unrelated is changed
//    T42  an IMAP folder already holding other \Deleted messages → only the
//         selected UID is expunged (UID EXPUNGE), never a plain EXPUNGE; with
//         neither MOVE nor UIDPLUS the removal is refused with a reason
//    T43  cleanup excludes uncaptured / failed / held / damaged items with
//         reasons, changes exactly the confirmed subset, archive stays readable
//    replay is idempotent (no duplicate mutation), permission refusal sends
//    nothing, Gmail Archive vs Trash, Graph move keeps the immutable id
//

import XCTest
import Foundation
import CryptoKit
@testable import MailConnectivity
@testable import ArchiveCore

final class ServerActionTests: XCTestCase {
    private var dir: URL!
    private var servers: [LocalIMAPServer] = []

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("server-actions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for s in servers { s.stop() }
        servers = []
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    // MARK: Helpers

    static func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    static func message(_ id: String) -> Data {
        Data("Message-ID: <\(id)@example.com>\r\nFrom: Asha <asha@example.com>\r\nTo: ravi@example.org\r\nSubject: \(id)\r\nDate: Mon, 6 Jan 2025 10:00:00 +0000\r\n\r\nBody of \(id)\r\n".utf8)
    }

    func gmailAccount(modes: Set<MailAccount.Mode> = [.capture, .serverActions],
                      scopes: [String] = [GmailOAuth.readOnlyScope, ServerActionScopes.gmailModify]) -> MailAccount {
        MailAccount(provider: .gmail, issuer: "https://accounts.google.com", displayIdentity: "asha@gmail.com",
                    grantedScopes: scopes, enabledModes: modes, connectionState: .connected)
    }

    func graphAccount(scopes: [String] = ["https://graph.microsoft.com/Mail.Read", "https://graph.microsoft.com/Mail.ReadWrite"]) -> MailAccount {
        MailAccount(provider: .microsoftGraph, issuer: "https://login.microsoftonline.com/common/v2.0", displayIdentity: "asha@contoso.com",
                    grantedScopes: scopes, enabledModes: [.capture, .serverActions], connectionState: .connected)
    }

    func journal(_ name: String = "journal") throws -> RemoteOperationJournal {
        try RemoteOperationJournal(storeDirectory: dir.appendingPathComponent(name, isDirectory: true))
    }

    func gmailService(_ sim: GmailActionSimulator, account: MailAccount, journal: RemoteOperationJournal,
                      tokens: CountingTokens = CountingTokens(), asks: ActionBox<[NetworkAsk]> = ActionBox([]),
                      refuseNetwork: Bool = false, refuseChange: Bool = false) -> RemoteActionService {
        struct Off: LocalizedError { var errorDescription: String? { "Mail is switched off." } }
        let executor = GmailActionExecutor(accountID: account.id, tokens: tokens, transport: sim, permission: { ask in
            asks.mutate { $0.append(ask) }
            if refuseNetwork { throw Off() }
        })
        return RemoteActionService(account: account, executor: executor, journal: journal, changePermission: { _ in
            if refuseChange { throw Off() }
        })
    }

    func graphService(_ sim: GraphActionSimulator, account: MailAccount, journal: RemoteOperationJournal,
                      tokens: CountingTokens = CountingTokens()) -> RemoteActionService {
        let executor = GraphActionExecutor(accountID: account.id, tokens: tokens, transport: sim, permission: { _ in })
        return RemoteActionService(account: account, executor: executor, journal: journal, changePermission: { _ in })
    }

    func startServer(_ configure: (IMAPServerModel) -> Void) async throws -> LocalIMAPServer {
        let model = IMAPServerModel()
        model.serveServerActions = true
        configure(model)
        let server = try LocalIMAPServer(model: model)
        try await server.start()
        servers.append(server)
        return server
    }

    func imapService(_ server: LocalIMAPServer, modes: Set<MailAccount.Mode> = [.capture, .serverActions],
                     journal: RemoteOperationJournal, trash: String? = "Trash") throws -> (RemoteActionService, IMAPAdapter) {
        let account = MailAccount(provider: .imap, host: "127.0.0.1", port: Int(server.port), loginName: server.model.login,
                                  displayIdentity: "asha@127.0.0.1", enabledModes: modes, connectionState: .connected)
        let credentials = InMemoryCredentialStore()
        try credentials.write(Data(server.model.password.utf8), kind: .password, account: account.id)
        let config = IMAPAccountConfiguration(host: "127.0.0.1", port: server.port, security: .plaintextLoopbackOnly,
                                              login: server.model.login, maxConnections: 1, timeout: 10)
        let adapter = IMAPAdapter(accountID: account.id, configuration: config, credentials: credentials,
                                  reconnect: IMAPReconnectPolicy(base: 1, maximum: 1, sleep: { _ in }))
        let executor = IMAPActionExecutor(adapter: adapter, trashMailbox: trash, permission: { _ in })
        return (RemoteActionService(account: account, executor: executor, journal: journal, changePermission: { _ in }), adapter)
    }

    func validity(_ model: IMAPServerModel, _ name: String) -> UInt32 { model.mailboxes.first { $0.name == name }!.uidValidity }
    func uids(_ model: IMAPServerModel, _ name: String) -> [UInt32] { model.mailboxes.first { $0.name == name }!.messages.map(\.uid) }

    /// Lines that would change the server (the transcript holds "<tag> <command>").
    func mutatingLines(_ model: IMAPServerModel) -> [String] {
        model.transcript.filter { line in
            let words = line.uppercased().split(separator: " ").map(String.init)
            guard words.count >= 2 else { return false }
            if words[1] == "EXPUNGE" || words[1] == "STORE" || words[1] == "COPY" || words[1] == "MOVE" { return true }
            return words[1] == "UID" && words.count > 2 && ["STORE", "COPY", "MOVE", "EXPUNGE"].contains(words[2])
        }
    }

    // MARK: T41 — another client changed the message

    func testT41_IMAP_trashAfterAnotherClientMovedIt_isAConflict_andNothingElseChanges() async throws {
        let server = try await startServer { m in
            m.addMailbox("INBOX"); m.addMailbox("Trash", attributes: ["\\Trash"]); m.addMailbox("Archive")
            for i in 0..<3 { m.add(Self.message("t41-\(i)"), to: "INBOX") }
        }
        let model = server.model
        let (service, adapter) = try imapService(server, journal: try journal())
        let v = validity(model, "INBOX")

        // (a) Another client moved UID 2 away BEFORE mailin looked.
        _ = model.copy([2], from: "INBOX", to: "Archive")
        _ = model.expungeDeleted(in: "INBOX", only: [], force: [2])
        let a = try await service.perform(.imap(mailbox: "INBOX", uidValidity: v, uid: 2), .moveToTrash(from: "INBOX"))
        guard case .conflict(let why)? = a.outcome else { return XCTFail("expected a conflict, got \(String(describing: a.outcome))") }
        XCTAssertTrue(why.contains("no longer"), why)
        XCTAssertEqual(a.observedBefore?.exists, false)
        XCTAssertEqual(mutatingLines(model), [], "nothing was sent for the conflicting item")

        // (b) Another client moves UID 3 between mailin's read and its MOVE.
        model.postAuthCapabilities.append("MOVE")
        await adapter.disconnect()                                        // new capabilities on a new connection
        model.onCommand = { line, m in
            if line.uppercased().contains("UID MOVE 3") {
                m.onCommand = nil
                _ = m.copy([3], from: "INBOX", to: "Archive")
                _ = m.expungeDeleted(in: "INBOX", only: [], force: [3])
            }
        }
        let b = try await service.perform(.imap(mailbox: "INBOX", uidValidity: v, uid: 3), .moveToTrash(from: "INBOX"))
        guard case .conflict? = b.outcome else { return XCTFail("expected a conflict, got \(String(describing: b.outcome))") }

        // Unrelated mail untouched: UID 1 still in INBOX, Trash empty, Archive holds what the other client moved.
        XCTAssertEqual(uids(model, "INBOX"), [1])
        XCTAssertEqual(uids(model, "Trash"), [])
        XCTAssertEqual(model.mailboxes.first { $0.name == "Archive" }!.messages.count, 2)
        XCTAssertFalse(model.transcript.contains { $0.uppercased().hasSuffix(" EXPUNGE") }, "never a mailbox-wide EXPUNGE")
    }

    func testT41_GmailAndGraph_anotherClientChangedItFirst_conflictOnlyForThatItem() async throws {
        // Gmail: archive, but another client already trashed it.
        let gmail = GmailActionSimulator()
        gmail.put("g1", ["INBOX", "TRASH"]); gmail.put("g2", ["INBOX", "UNREAD"])
        let account = gmailAccount()
        let gs = gmailService(gmail, account: account, journal: try journal("g"))
        let g1 = try await gs.perform(.gmail(messageID: "g1"), .archiveOnServer)
        XCTAssertEqual(g1.outcome, .conflict("another client moved it to Trash"))
        let g2 = try await gs.perform(.gmail(messageID: "g2"), .archiveOnServer)
        XCTAssertEqual(g2.outcome, .applied(verified: true, alreadyInState: false))
        XCTAssertEqual(gmail.labels(of: "g1"), ["INBOX", "TRASH"], "the conflicting message is not touched")
        XCTAssertEqual(gmail.labels(of: "g2"), ["UNREAD"])
        XCTAssertEqual(gmail.mutations.count, 1, "one request, for the one item that was still as expected")

        // Graph: trash from Inbox, but another client moves it to Archive between read and move.
        let graph = GraphActionSimulator()
        graph.put("AAMkM1", .init(folder: "AAMk-inbox", isRead: false, flagged: false))
        let gr = graphService(graph, account: graphAccount(), journal: try journal("m"))
        let before = try await gr.perform(.graph(mailbox: "me", immutableID: "AAMkM1"), .move(from: "inbox", to: "archive"))
        XCTAssertEqual(before.outcome, .applied(verified: true, alreadyInState: false))
        let stale = try await gr.perform(.graph(mailbox: "me", immutableID: "AAMkM1"), .moveToTrash(from: "inbox"))
        guard case .conflict(let why)? = stale.outcome else { return XCTFail("got \(String(describing: stale.outcome))") }
        XCTAssertTrue(why.contains("AAMk-inbox"), why)
        XCTAssertEqual(graph.message("AAMkM1")?.folder, "AAMk-archive", "not moved to Deleted Items")
    }

    // MARK: T42 — targeted removal only

    func testT42_IMAP_withUIDPLUS_otherDeletedMessagesSurvive_onlyTheSelectedUIDIsExpunged() async throws {
        let server = try await startServer { m in
            m.addMailbox("INBOX"); m.addMailbox("Trash", attributes: ["\\Trash"])
            m.add(Self.message("other-deleted-1"), to: "INBOX", flags: ["\\Deleted"])     // UID 1: another client's pending deletion
            m.add(Self.message("mine"), to: "INBOX", flags: ["\\Seen"])                    // UID 2: the selected message
            m.add(Self.message("other-deleted-2"), to: "INBOX", flags: ["\\Deleted"])     // UID 3
            m.add(Self.message("keep"), to: "INBOX")                                       // UID 4
            XCTAssertFalse(m.postAuthCapabilities.contains("MOVE"))
            XCTAssertTrue(m.postAuthCapabilities.contains("UIDPLUS"))
        }
        let model = server.model
        let (service, _) = try imapService(server, journal: try journal())
        let v = validity(model, "INBOX")
        let op = try await service.perform(.imap(mailbox: "INBOX", uidValidity: v, uid: 2), .moveToTrash(from: "INBOX"))
        XCTAssertEqual(op.outcome, .applied(verified: true, alreadyInState: false))
        XCTAssertEqual(op.resultingIdentity, .imap(mailbox: "Trash", uidValidity: validity(model, "Trash"), uid: 1), "COPYUID followed")

        XCTAssertEqual(uids(model, "INBOX"), [1, 3, 4], "the two messages other clients marked \\Deleted are still there")
        XCTAssertEqual(model.flags(of: 1, in: "INBOX"), ["\\Deleted"])
        XCTAssertEqual(model.flags(of: 3, in: "INBOX"), ["\\Deleted"])
        XCTAssertEqual(model.mailboxes.first { $0.name == "Trash" }!.messages.map(\.bytes), [Self.message("mine")])
        let mutations = mutatingLines(model).map { String($0.split(separator: " ", maxSplits: 1)[1]) }
        XCTAssertEqual(mutations, ["UID COPY 2 \"Trash\"", "UID STORE 2 +FLAGS.SILENT (\\Deleted)", "UID EXPUNGE 2"])
        XCTAssertFalse(model.transcript.contains { $0.uppercased().hasSuffix(" EXPUNGE") }, "never a mailbox-wide EXPUNGE")

        // Flags by UID STORE, read back.
        let read = try await service.perform(.imap(mailbox: "INBOX", uidValidity: v, uid: 4), .markRead)
        XCTAssertEqual(read.outcome, .applied(verified: true, alreadyInState: false))
        let flag = try await service.perform(.imap(mailbox: "INBOX", uidValidity: v, uid: 4), .flag)
        XCTAssertEqual(flag.outcome, .applied(verified: true, alreadyInState: false))
        XCTAssertEqual(Set(model.flags(of: 4, in: "INBOX") ?? []), ["\\Seen", "\\Flagged"])
        XCTAssertEqual(uids(model, "INBOX"), [1, 3, 4])

        // Restore from Trash (UIDPLUS COPY path) into INBOX.
        let restore = try await service.perform(XCTUnwrap(op.resultingIdentity), .restoreFromTrash(to: "INBOX"))
        XCTAssertEqual(restore.outcome, .applied(verified: true, alreadyInState: false))
        XCTAssertEqual(uids(model, "Trash"), [])
        XCTAssertEqual(uids(model, "INBOX"), [1, 3, 4, 5])
    }

    func testT42_IMAP_withMOVE_usesUIDMove_andOtherDeletedMessagesSurvive() async throws {
        let server = try await startServer { m in
            m.postAuthCapabilities.append("MOVE")
            m.addMailbox("INBOX"); m.addMailbox("Trash", attributes: ["\\Trash"])
            m.add(Self.message("other-deleted"), to: "INBOX", flags: ["\\Deleted"])
            m.add(Self.message("mine"), to: "INBOX")
        }
        let model = server.model
        let (service, _) = try imapService(server, journal: try journal())
        let op = try await service.perform(.imap(mailbox: "INBOX", uidValidity: validity(model, "INBOX"), uid: 2), .moveToTrash(from: "INBOX"))
        XCTAssertEqual(op.outcome, .applied(verified: true, alreadyInState: false))
        XCTAssertEqual(uids(model, "INBOX"), [1])
        XCTAssertEqual(model.flags(of: 1, in: "INBOX"), ["\\Deleted"])
        XCTAssertEqual(mutatingLines(model).map { String($0.split(separator: " ", maxSplits: 1)[1]) }, ["UID MOVE 2 \"Trash\""])
    }

    func testT42_IMAP_withoutMOVEorUIDPLUS_refusesTheRemoval_andSendsNoChange() async throws {
        let server = try await startServer { m in
            m.postAuthCapabilities.removeAll { $0 == "UIDPLUS" || $0 == "MOVE" }
            m.addMailbox("INBOX"); m.addMailbox("Trash", attributes: ["\\Trash"])
            m.add(Self.message("other-deleted"), to: "INBOX", flags: ["\\Deleted"])
            m.add(Self.message("mine"), to: "INBOX")
        }
        let model = server.model
        let (service, _) = try imapService(server, journal: try journal())
        let op = try await service.perform(.imap(mailbox: "INBOX", uidValidity: validity(model, "INBOX"), uid: 2), .moveToTrash(from: "INBOX"))
        XCTAssertEqual(op.outcome, .rejected(.targetedRemovalUnavailable(IMAPActionExecutor.noTargetedRemoval)))
        XCTAssertEqual(mutatingLines(model), [], "no COPY, STORE or EXPUNGE was sent")
        XCTAssertEqual(uids(model, "INBOX"), [1, 2])
        XCTAssertEqual(model.flags(of: 1, in: "INBOX"), ["\\Deleted"])
        XCTAssertEqual(uids(model, "Trash"), [])
        // Flag changes need no removal and still work on such a server.
        let read = try await service.perform(.imap(mailbox: "INBOX", uidValidity: validity(model, "INBOX"), uid: 2), .markRead)
        XCTAssertEqual(read.outcome, .applied(verified: true, alreadyInState: false))
    }

    // MARK: T43 — safe cleanup

    func testT43_cleanup_excludesUnsafeItemsWithReasons_changesOnlyTheConfirmedSubset_archiveStaysReadable() async throws {
        let account = gmailAccount()
        let sink = ConnectedArchiveSink(storeDirectory: dir.appendingPathComponent("archive", isDirectory: true))
        try await sink.saveAccount(account.record)
        let run = try await sink.beginRun(accountID: account.id, selection: "INBOX")
        var emailIDs: [String: UUID] = [:]
        var digests: [String: String] = [:]
        for id in ["m1", "m2", "m3", "m4", "m6"] {
            let w = try sink.makeStagingWriter()
            try w.append(Self.message(id))
            let out = try await sink.capture(CaptureItem(accountID: account.id, identity: .gmail(messageID: id),
                                                         occurrences: [RemoteFolderOccurrence(serverID: "INBOX", displayPath: "Inbox", kind: .label)],
                                                         raw: try w.finish(), metadata: ProviderMetadata(representation: .gmailRaw)), runID: run)
            emailIDs[id] = try XCTUnwrap(out.emailID)
            digests[id] = out.sha256
        }
        _ = try await sink.finishRun(run)
        // m3's preserved bytes are lost (damaged disk): it must not be removed from the server.
        try FileManager.default.removeItem(at: sink.store.blobStore.url(for: digests["m3"]!))

        let gmail = GmailActionSimulator()
        for id in ["m1", "m2", "m3", "m4", "m5", "m6", "m7"] { gmail.put(id, ["INBOX"]) }
        let verifier = ConnectedArchiveCopyVerifier(sink: sink) { _, p in
            let ref = BlobReference(digest: p.sha256, length: p.byteCount)
            guard sink.store.blobStore.exists(ref) else { return nil }
            let data = try sink.store.blobStore.read(ref, verify: false)
            return (Self.sha(data), Int64(data.count))
        }
        let held = emailIDs["m4"]!
        let checks = CleanupSafetyChecks(archive: verifier,
                                         hold: { emailID, _ in emailID == held ? "Litigation hold 2026-11" : nil },
                                         captureFailure: { identity in identity == .gmail(messageID: "m7") ? "download failed (HTTP 500)" : nil })
        func candidate(_ id: String, emailID: UUID?) -> CleanupCandidate {
            CleanupCandidate(accountID: account.id, identity: .gmail(messageID: id), emailID: emailID, folder: "INBOX")
        }
        let otherAccount = CleanupCandidate(accountID: UUID(), identity: .gmail(messageID: "m6"), emailID: emailIDs["m6"], folder: "INBOX")
        let selection = [candidate("m1", emailID: emailIDs["m1"]), candidate("m2", emailID: emailIDs["m2"]),
                         candidate("m3", emailID: emailIDs["m3"]), candidate("m4", emailID: emailIDs["m4"]),
                         candidate("m5", emailID: nil), candidate("m7", emailID: nil),
                         candidate("m1", emailID: emailIDs["m1"]), otherAccount]

        let plan = await SafeCleanup.plan(selection, action: .moveToTrash, account: account, checks: checks)
        XCTAssertEqual(plan.included.map(\.candidate.identity), [.gmail(messageID: "m1"), .gmail(messageID: "m2")])
        let reasons = Dictionary(plan.excluded.map { ((try! $0.candidate.identity.key()) + "|\($0.candidate.accountID == account.id)", $0.reason) },
                                 uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(reasons[try! ProviderMessageIdentity.gmail(messageID: "m3").key() + "|true"], .archiveBytesMissing)
        XCTAssertEqual(reasons[try! ProviderMessageIdentity.gmail(messageID: "m4").key() + "|true"], .onHold("Litigation hold 2026-11"))
        XCTAssertEqual(reasons[try! ProviderMessageIdentity.gmail(messageID: "m5").key() + "|true"], .notCaptured)
        XCTAssertEqual(reasons[try! ProviderMessageIdentity.gmail(messageID: "m7").key() + "|true"], .captureFailed("download failed (HTTP 500)"))
        XCTAssertEqual(reasons[try! ProviderMessageIdentity.gmail(messageID: "m6").key() + "|false"], .otherAccount)
        XCTAssertEqual(plan.excluded.filter { $0.reason == .duplicateInSelection }.count, 1)
        XCTAssertEqual(plan.preview.selected, 8)
        XCTAssertEqual(plan.preview.toChange, 2)
        XCTAssertEqual(plan.preview.excluded, 6)
        XCTAssertTrue(plan.preview.archiveCopiesKept)
        XCTAssertTrue(plan.preview.defaultText.hasPrefix("2 of 8 messages will be moved to Trash on asha@gmail.com"))
        XCTAssertEqual(gmail.requests.count, 0, "planning never contacts the server")

        // A confirmation for another count / plan changes nothing.
        let service = gmailService(gmail, account: account, journal: try journal())
        var wrong = plan.confirmation(); wrong.confirmedCount = 3
        do { _ = try await SafeCleanup.execute(plan, confirmation: wrong, service: service, checks: checks); XCTFail("must refuse") }
        catch { XCTAssertEqual(error as? CleanupError, .confirmationMismatch) }
        XCTAssertEqual(gmail.requests.count, 0)

        let receipt = try await SafeCleanup.execute(plan, confirmation: plan.confirmation(), service: service, checks: checks)
        XCTAssertEqual(receipt.applied, 2)
        XCTAssertEqual(receipt.excluded, 6)
        XCTAssertEqual(receipt.selected, 8)
        XCTAssertTrue(receipt.archiveCopiesIntact)
        XCTAssertTrue(receipt.defaultText.hasPrefix("2 of 8 changed on the server"))
        XCTAssertEqual(Set(gmail.mutations.map(\.url.path)),
                       ["/gmail/v1/users/me/messages/m1/trash", "/gmail/v1/users/me/messages/m2/trash"], "exactly the confirmed subset")
        for id in ["m3", "m4", "m5", "m6", "m7"] { XCTAssertEqual(gmail.labels(of: id), ["INBOX"], "\(id) untouched on the server") }

        // Remote removal never removes the archived copy: still readable, byte-identical, with provenance.
        for id in ["m1", "m2"] {
            let rawRead = try await sink.store.rawBytes(id: emailIDs[id]!)
            let raw = try XCTUnwrap(rawRead)
            XCTAssertEqual(raw, Self.message(id), "\(id) still exportable byte-for-byte")
            let p = try await sink.provenance(emailID: emailIDs[id]!)
            XCTAssertEqual(p?.sha256, digests[id])
        }
        let saved = try await service.journal.receipt(planID: plan.planID)
        XCTAssertEqual(saved?.entries, receipt.entries, "the receipt is on disk")

        // Running the same confirmed plan again changes nothing more.
        let again = try await SafeCleanup.execute(plan, confirmation: plan.confirmation(), service: service, checks: checks)
        XCTAssertEqual(again.applied, 2)
        XCTAssertEqual(gmail.mutations.count, 2, "no item is changed twice")
    }

    func testT43_cleanup_requiringAnIndependentCopy_excludesItemsWithoutOne() async throws {
        struct AlwaysVerified: ArchivedCopyVerifier {
            func verify(emailID: UUID, accountID: UUID, identity: ProviderMessageIdentity) async -> ArchivedCopyStatus {
                .verified(sha256: "ab", byteCount: 2)
            }
        }
        let account = gmailAccount()
        let backedUp = UUID(), notBackedUp = UUID()
        let checks = CleanupSafetyChecks(archive: AlwaysVerified(), independentCopy: { $0 == backedUp })
        let plan = await SafeCleanup.plan([
            CleanupCandidate(accountID: account.id, identity: .gmail(messageID: "b1"), emailID: backedUp, folder: "INBOX"),
            CleanupCandidate(accountID: account.id, identity: .gmail(messageID: "b2"), emailID: notBackedUp, folder: "INBOX"),
        ], action: .archiveOnServer, account: account, checks: checks)
        XCTAssertEqual(plan.included.map(\.candidate.emailID), [backedUp])
        XCTAssertEqual(plan.excluded.map(\.reason), [.noIndependentCopy])
        XCTAssertEqual(plan.included.first?.request, .archiveOnServer)
    }

    // MARK: Idempotent replay

    func testReplay_isIdempotent_noDuplicateMutation() async throws {
        let gmail = GmailActionSimulator()
        gmail.put("r1", ["INBOX", "UNREAD"]); gmail.put("r2", ["INBOX"]); gmail.put("r3", ["INBOX"])
        let account = gmailAccount()
        let j = try journal()
        let service = gmailService(gmail, account: account, journal: j)

        // A finished operation replays from the journal: no request at all.
        let done = try await service.perform(.gmail(messageID: "r1"), .markRead)
        XCTAssertEqual(done.outcome, .applied(verified: true, alreadyInState: false))
        let sent = gmail.requests.count
        let replay = try await service.execute(done.id)
        XCTAssertEqual(replay.id, done.id)
        XCTAssertEqual(replay.outcome, done.outcome)
        XCTAssertEqual(gmail.requests.count, sent, "a finished operation contacts nobody")

        // Killed after the request, before the outcome was saved → reconciled, not resent.
        struct Killed: Error {}
        await service.setAfterApplyHook { throw Killed() }
        let op = try await service.enqueue(.gmail(messageID: "r2"), .moveToTrash(from: "INBOX"))
        do { _ = try await service.execute(op.id); XCTFail("killed") } catch is Killed {}
        guard case .executing = try await j.load(op.id).attempt else { return XCTFail("left executing on disk") }
        let unfinished = await j.unfinished()
        XCTAssertEqual(unfinished.map(\.id), [op.id])
        let relaunched = gmailService(gmail, account: account, journal: try RemoteOperationJournal(storeDirectory: dir.appendingPathComponent("journal")))
        let reconciled = try await relaunched.execute(op.id)
        XCTAssertEqual(reconciled.outcome, .applied(verified: true, alreadyInState: false))
        XCTAssertEqual(gmail.mutations.filter { $0.url.path.hasSuffix("/r2/trash") }.count, 1, "the trash request was sent once")

        // The reply was lost after the provider applied it → read back, applied, not repeated.
        gmail.dropReplyAfterApplying = true
        let lost = try await relaunched.perform(.gmail(messageID: "r3"), .flag)
        XCTAssertEqual(lost.outcome, .applied(verified: true, alreadyInState: false))
        XCTAssertEqual(gmail.mutations.filter { $0.url.path.hasSuffix("/r3/modify") }.count, 1)

        // Already in the requested state → nothing sent.
        let before = gmail.mutations.count
        let already = try await relaunched.perform(.gmail(messageID: "r3"), .flag)
        XCTAssertEqual(already.outcome, .applied(verified: true, alreadyInState: true))
        XCTAssertEqual(gmail.mutations.count, before)
    }

    func testReplay_IMAPCopyPathInterrupted_isNotRepeated() async throws {
        let server = try await startServer { m in
            m.addMailbox("INBOX"); m.addMailbox("Trash", attributes: ["\\Trash"])
            m.add(Self.message("x"), to: "INBOX")
        }
        let model = server.model
        let j = try journal()
        let (service, _) = try imapService(server, journal: j)
        // An earlier process journalled `executing` and died; whether its COPY reached the server is unknown.
        var op = try await service.enqueue(.imap(mailbox: "INBOX", uidValidity: validity(model, "INBOX"), uid: 1), .moveToTrash(from: "INBOX"))
        op.attempt = .executing(since: Date())
        try await j.save(op)
        let out = try await service.execute(op.id)
        guard case .uncertain(let why)? = out.outcome else { return XCTFail("got \(String(describing: out.outcome))") }
        XCTAssertTrue(why.contains("may have left a copy"), why)
        XCTAssertEqual(mutatingLines(model), [], "a COPY that may already have happened is not repeated")
    }

    // MARK: Permission

    func testPermissionRefusal_sendsNothing() async throws {
        let gmail = GmailActionSimulator()
        gmail.put("p1", ["INBOX", "UNREAD"])
        let tokens = CountingTokens()
        let asks = ActionBox<[NetworkAsk]>([])

        let modeOff = gmailService(gmail, account: gmailAccount(modes: [.capture]), journal: try journal("a"), tokens: tokens, asks: asks)
        let a = try await modeOff.perform(.gmail(messageID: "p1"), .markRead)
        XCTAssertEqual(a.outcome, .rejected(.changeServerMailOff))

        let readOnly = gmailService(gmail, account: gmailAccount(scopes: [GmailOAuth.readOnlyScope]), journal: try journal("b"), tokens: tokens, asks: asks)
        let b = try await readOnly.perform(.gmail(messageID: "p1"), .markRead)
        XCTAssertEqual(b.outcome, .rejected(.needsExtraPermission(scope: ServerActionScopes.gmailModify)))
        XCTAssertTrue(RemoteRejection.needsExtraPermission(scope: "x").defaultText.hasPrefix("This needs extra permission"))

        let policyOff = gmailService(gmail, account: gmailAccount(), journal: try journal("c"), tokens: tokens, asks: asks, refuseChange: true)
        let c = try await policyOff.perform(.gmail(messageID: "p1"), .markRead)
        XCTAssertEqual(c.outcome, .rejected(.changeServerMailOff))

        var signedOut = gmailAccount(); signedOut.connectionState = .needsReauthorisation
        let d = try await gmailService(gmail, account: signedOut, journal: try journal("d"), tokens: tokens, asks: asks)
            .perform(.gmail(messageID: "p1"), .markRead)
        XCTAssertEqual(d.outcome, .rejected(.needsSignIn))

        let graph = GraphActionSimulator()
        graph.put("AAMkP", .init(folder: "AAMk-inbox", isRead: false, flagged: false))
        let graphReadOnly = graphService(graph, account: graphAccount(scopes: ["https://graph.microsoft.com/Mail.Read"]), journal: try journal("e"), tokens: tokens)
        let e = try await graphReadOnly.perform(.graph(mailbox: "me", immutableID: "AAMkP"), .markRead)
        XCTAssertEqual(e.outcome, .rejected(.needsExtraPermission(scope: "Mail.ReadWrite")))

        XCTAssertEqual(tokens.calls.value, 0, "no token was even requested")
        XCTAssertEqual(asks.value, [], "the network policy was not even asked")
        XCTAssertEqual(gmail.requests.count, 0)
        XCTAssertEqual(graph.requests.count, 0)
        XCTAssertEqual(gmail.labels(of: "p1"), ["INBOX", "UNREAD"])

        // The network policy refuses: nothing sent either.
        let netOff = gmailService(gmail, account: gmailAccount(), journal: try journal("f"), tokens: tokens, refuseNetwork: true)
        let f = try await netOff.perform(.gmail(messageID: "p1"), .markRead)
        guard case .rejected(.networkNotPermitted)? = f.outcome else { return XCTFail("got \(String(describing: f.outcome))") }
        XCTAssertEqual(gmail.requests.count, 0)
        XCTAssertEqual(tokens.calls.value, 0)

        // IMAP with the mode off: no connection at all.
        let server = try await startServer { m in m.addMailbox("INBOX"); m.add(Self.message("p"), to: "INBOX") }
        let (imap, _) = try imapService(server, modes: [.capture], journal: try journal("g"))
        let g = try await imap.perform(.imap(mailbox: "INBOX", uidValidity: validity(server.model, "INBOX"), uid: 1), .markRead)
        XCTAssertEqual(g.outcome, .rejected(.changeServerMailOff))
        XCTAssertEqual(server.model.connections, 0)
    }

    // MARK: Gmail Archive vs Trash

    func testGmail_serverArchiveRemovesOnlyInbox_trashIsSeparate_restoreUntrashes() async throws {
        let gmail = GmailActionSimulator()
        gmail.put("a1", ["INBOX", "Label_7", "IMPORTANT"]); gmail.put("t1", ["INBOX", "Label_7"])
        let service = gmailService(gmail, account: gmailAccount(), journal: try journal())

        let archived = try await service.perform(.gmail(messageID: "a1"), .archiveOnServer)
        XCTAssertEqual(archived.outcome, .applied(verified: true, alreadyInState: false))
        XCTAssertEqual(gmail.labels(of: "a1"), ["Label_7", "IMPORTANT"], "Archive = out of the Inbox only; still in All Mail and its labels")
        let archiveRequest = try XCTUnwrap(gmail.mutations.last)
        XCTAssertEqual(archiveRequest.url.path, "/gmail/v1/users/me/messages/a1/modify")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: archiveRequest.body) as? [String: [String]])
        XCTAssertEqual(body["removeLabelIds"], ["INBOX"]); XCTAssertEqual(body["addLabelIds"], [])
        XCTAssertEqual(archiveRequest.headers["Authorization"], "Bearer change-token")

        let trashed = try await service.perform(.gmail(messageID: "t1"), .moveToTrash(from: "INBOX"))
        XCTAssertEqual(trashed.outcome, .applied(verified: true, alreadyInState: false))
        XCTAssertEqual(gmail.mutations.last?.url.path, "/gmail/v1/users/me/messages/t1/trash", "Trash uses messages.trash, not a label edit")
        XCTAssertTrue(gmail.labels(of: "t1")!.contains("TRASH"))

        let restored = try await service.perform(.gmail(messageID: "t1"), .restoreFromTrash(to: "INBOX"))
        XCTAssertEqual(restored.outcome, .applied(verified: true, alreadyInState: false))
        XCTAssertEqual(gmail.mutations.last?.url.path, "/gmail/v1/users/me/messages/t1/untrash")
        XCTAssertFalse(gmail.labels(of: "t1")!.contains("TRASH"))

        // Labels and move are label edits; Spam / Trash cannot be reached that way.
        let label = try await service.perform(.gmail(messageID: "a1"), .move(from: "Label_7", to: "Label_9"))
        XCTAssertEqual(label.outcome, .applied(verified: true, alreadyInState: false))
        XCTAssertEqual(gmail.labels(of: "a1"), ["IMPORTANT", "Label_9"])
        let bad = try await service.perform(.gmail(messageID: "a1"), .addLabel("TRASH"))
        guard case .rejected(.unsupported)? = bad.outcome else { return XCTFail("got \(String(describing: bad.outcome))") }

        // A message deleted on the server since: a conflict, never a request.
        gmail.remove("a1")
        let n = gmail.mutations.count
        let gone = try await service.perform(.gmail(messageID: "a1"), .markRead)
        guard case .conflict? = gone.outcome else { return XCTFail("got \(String(describing: gone.outcome))") }
        XCTAssertEqual(gmail.mutations.count, n)
    }

    // MARK: Graph move with immutable id

    func testGraph_moveKeepsTheImmutableID_flagsByPatch_trashAndRestore() async throws {
        let graph = GraphActionSimulator()
        graph.put("AAMkImm=", .init(folder: "AAMk-inbox", isRead: false, flagged: false))
        let service = graphService(graph, account: graphAccount(), journal: try journal())
        let identity = ProviderMessageIdentity.graph(mailbox: "me", immutableID: "AAMkImm=")

        let moved = try await service.perform(identity, .move(from: "inbox", to: "archive"))
        XCTAssertEqual(moved.outcome, .applied(verified: true, alreadyInState: false))
        XCTAssertNil(moved.resultingIdentity, "the immutable id is the same after the move")
        XCTAssertEqual(moved.observedAfter?.folders, ["AAMk-archive"])
        XCTAssertEqual(graph.ids, ["AAMkImm="])
        let move = try XCTUnwrap(graph.mutations.last)
        XCTAssertEqual(move.method, "POST")
        XCTAssertEqual(move.url.path, "/v1.0/me/messages/AAMkImm=/move")
        XCTAssertEqual(move.headers["Prefer"], #"IdType="ImmutableId""#)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: move.body) as? [String: String], ["destinationId": "AAMk-archive"])
        XCTAssertTrue(graph.requests.allSatisfy { $0.headers["Prefer"] == #"IdType="ImmutableId""# }, "every request asks for immutable ids")

        let read = try await service.perform(identity, .markRead)
        XCTAssertEqual(read.outcome, .applied(verified: true, alreadyInState: false))
        XCTAssertEqual(graph.mutations.last?.method, "PATCH")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: graph.mutations.last!.body) as? [String: Bool], ["isRead": true])
        let flagged = try await service.perform(identity, .flag)
        XCTAssertEqual(flagged.outcome, .applied(verified: true, alreadyInState: false))
        XCTAssertEqual(graph.message("AAMkImm=")?.flagged, true)

        let trashed = try await service.perform(identity, .moveToTrash(from: "archive"))
        XCTAssertEqual(trashed.outcome, .applied(verified: true, alreadyInState: false))
        XCTAssertEqual(graph.message("AAMkImm=")?.folder, "AAMk-deleted")
        let restored = try await service.perform(identity, .restoreFromTrash(to: "inbox"))
        XCTAssertEqual(restored.outcome, .applied(verified: true, alreadyInState: false))
        XCTAssertEqual(graph.message("AAMkImm=")?.folder, "AAMk-inbox")
        XCTAssertEqual(graph.ids, ["AAMkImm="], "one message, one id, throughout")

        // Labels / server Archive are Gmail actions: refused with a reason, nothing sent.
        let n = graph.mutations.count
        let label = try await service.perform(identity, .addLabel("Red"))
        guard case .rejected(.unsupported)? = label.outcome else { return XCTFail("got \(String(describing: label.outcome))") }
        XCTAssertEqual(graph.mutations.count, n)
    }
}
