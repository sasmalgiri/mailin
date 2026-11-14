//
//  ConnectedArchiveSinkTests.swift
//  ArchiveCoreTests
//
//  Plan v4 V4-03: the connected-mail ingestion boundary and schema v26.
//    - v25 → v26 migration: snapshot first (rule 2), additive (rule 1), the
//      snapshot is the v25 archive a rollback build can open.
//    - T19: a kill after staging, after publish, after commit and before the
//      checkpoint; restart reconciles; no record points at missing bytes;
//      nothing is skipped; a checkpoint never passes an unrecorded item.
//    - T12: the same Message-ID with different bodies / in different
//      accounts keeps every record; a local deletion is per provider identity.
//    - Provenance survives export (sidecar, byte-identical .eml, inventory clean).
//

import XCTest
import Foundation
import SQLite3
import CryptoKit
@testable import ArchiveCore

final class ConnectedArchiveSinkTests: XCTestCase {
    private var dir: URL!
    private var savedSnapshots = false

    override func setUpWithError() throws {
        savedSnapshots = ArchiveSnapshotPolicy.isEnabled
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("connected-sink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        ArchiveSnapshotPolicy.isEnabled = savedSnapshots
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    struct Killed: Error, Equatable { let boundary: CaptureBoundary }

    static func message(id: String, body: String, subject: String = "Quarterly figures") -> Data {
        Data(("Message-ID: <\(id)>\r\nFrom: Asha <asha@example.com>\r\nTo: ravi@example.org\r\n"
              + "Subject: \(subject) – ü\r\nDate: Mon, 6 Jan 2025 10:00:00 +0530\r\nMIME-Version: 1.0\r\n"
              + "Content-Type: text/plain; charset=utf-8\r\n\r\n\(body)\r\n").utf8)
    }

    func stage(_ sink: ConnectedArchiveSink, _ bytes: Data) throws -> StagedRawMessage {
        let writer = try sink.makeStagingWriter()
        let cut = bytes.count / 2
        try writer.append(bytes.prefix(cut))
        try writer.append(bytes.dropFirst(cut))
        return try writer.finish()
    }

    func makeAccount(_ sink: ConnectedArchiveSink, provider: MailProviderKind = .gmail, display: String = "asha@example.com") async throws -> UUID {
        let id = UUID()
        try await sink.saveAccount(ConnectedAccountRecord(
            accountID: id, provider: provider, issuer: provider == .imap ? "" : "https://accounts.google.com",
            host: provider == .imap ? "imap.example.com" : nil, port: provider == .imap ? 993 : nil,
            displayIdentity: display, grantedScopes: ["https://www.googleapis.com/auth/gmail.readonly"],
            enabledModes: ["capture"], connectionState: "connected", createdAt: Date(), updatedAt: Date()))
        return id
    }

    func item(_ sink: ConnectedArchiveSink, account: UUID, gmailID: String, bytes: Data,
              labels: [String] = ["INBOX"]) throws -> CaptureItem {
        CaptureItem(accountID: account, identity: .gmail(messageID: gmailID),
                    occurrences: labels.map { RemoteFolderOccurrence(serverID: $0, displayPath: $0 == "INBOX" ? "Inbox" : $0, kind: .label) },
                    raw: try stage(sink, bytes),
                    metadata: ProviderMetadata(representation: .gmailRaw, internalDate: Date(timeIntervalSince1970: 1_736_137_800),
                                               revision: "h-\(gmailID)", flags: ["UNREAD"]))
    }

    // MARK: Migration

    func testV26_upgradeFromV25_snapshotsFirst_isAdditive_andTheSnapshotIsTheV25Archive() async throws {
        // A real archive with data, taken back to v25 exactly as a v25 build left it.
        let store = SQLiteEmailStore(directory: dir)
        let emails = try (0..<6).map { i in
            try MBOXParser.processRawMessage(String(decoding: Self.message(id: "old-\(i)@x", body: "Old \(i)"), as: UTF8.self), senderEmail: "")
        }
        _ = try await store.insertBatch(emails, sourceFileHash: nil, accountID: nil, sourceID: nil, firstOrdinal: nil,
                                        dedupPolicy: .messageID, batchSize: 10, progress: nil)
        await store.reopenConnection()
        let path = dir.appendingPathComponent("emails.db").path
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &raw), SQLITE_OK)
        for t in ["mail_accounts", "remote_folders", "remote_messages", "remote_memberships", "sync_checkpoints", "capture_runs", "capture_items"] {
            XCTAssertEqual(sqlite3_exec(raw, "DROP TABLE \(t);", nil, nil, nil), SQLITE_OK)
        }
        XCTAssertEqual(sqlite3_exec(raw, "PRAGMA user_version = 25;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(raw)
        let before = try Self.tableCounts(path)
        XCTAssertEqual(before.version, 25)
        XCTAssertNil(before.counts["remote_messages"])

        ArchiveSnapshotPolicy.isEnabled = true
        let upgraded = SQLiteEmailStore(directory: dir)
        let total = try await upgraded.totalCount()
        XCTAssertEqual(total, 6)
        let version = try await upgraded.schemaVersion()
        XCTAssertEqual(version, 26)

        // Rule 2: snapshot before the upgrade, holding the v25 archive (the rollback point).
        let snapshot = try XCTUnwrap(upgraded.snapshots().first { $0.reason == "before upgrade" })
        XCTAssertTrue(snapshot.url.lastPathComponent.contains("before-upgrade-v25-to-v26"), snapshot.url.lastPathComponent)
        let snap = try Self.tableCounts(snapshot.url.path)
        XCTAssertEqual(snap.version, 25, "the snapshot is the v25 archive a v25 build opens")
        XCTAssertEqual(snap.counts, before.counts)

        // Rule 1: every existing row is untouched; the seven new tables are empty.
        await upgraded.reopenConnection()
        let after = try Self.tableCounts(path)
        for (table, n) in before.counts { XCTAssertEqual(after.counts[table], n, table) }
        let connected = try await upgraded.connectedTableCounts()
        XCTAssertEqual(connected.count, 7)
        XCTAssertTrue(connected.values.allSatisfy { $0 == 0 }, "\(connected)")
    }

    static func tableCounts(_ path: String) throws -> (version: Int, counts: [String: Int]) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw XCTSkip("cannot open") }
        defer { sqlite3_close(db) }
        func rows(_ sql: String) -> [String] {
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            defer { sqlite3_finalize(stmt) }
            var out: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW { out.append(String(cString: sqlite3_column_text(stmt, 0))) }
            return out
        }
        let version = Int(rows("PRAGMA user_version;").first ?? "0") ?? 0
        var counts: [String: Int] = [:]
        for t in rows("SELECT name FROM sqlite_master WHERE type='table' AND sql NOT LIKE 'CREATE VIRTUAL%' ORDER BY name;") {
            counts[t] = Int(rows("SELECT COUNT(*) FROM \"\(t)\";").first ?? "-1") ?? -1
        }
        return (version, counts)
    }

    // MARK: T19 — kill at every boundary

    func testT19_killAtEachBoundary_restartReconciles_noRecordWithoutBytes_nothingSkipped() async throws {
        for boundary in CaptureBoundary.allCases {
            let here = dir.appendingPathComponent(boundary.rawValue, isDirectory: true)
            let messages = (1...3).map { Self.message(id: "m\($0)@x", body: "Body \($0) for \(boundary.rawValue)") }

            // First process: m1 is preserved, then the process "dies" at the boundary.
            var sink: ConnectedArchiveSink? = ConnectedArchiveSink(storeDirectory: here)
            let account = try await makeAccount(sink!)
            let run1 = try await sink!.beginRun(accountID: account, selection: "INBOX")
            try await sink!.recordDiscovered(runID: run1, identities: (1...3).map { .gmail(messageID: "g\($0)") })
            _ = try await sink!.capture(try item(sink!, account: account, gmailID: "g1", bytes: messages[0]), runID: run1)
            do {
                try await sink!.advanceCheckpoint(accountID: account, scope: "INBOX", cursor: "after-g3", runID: run1)
                XCTFail("a checkpoint must not pass listed items that are still pending")
            } catch ConnectedArchiveError.itemsNotTerminal(_, let pending) { XCTAssertEqual(pending, 2) }
            await sink!.setFaultHook { if $0 == boundary { throw Killed(boundary: $0) } }
            do {
                if boundary == .beforeCheckpoint {
                    for n in 2...3 { _ = try await sink!.capture(try item(sink!, account: account, gmailID: "g\(n)", bytes: messages[n - 1]), runID: run1) }
                    try await sink!.advanceCheckpoint(accountID: account, scope: "INBOX", cursor: "after-g3", runID: run1)
                } else {
                    _ = try await sink!.capture(try item(sink!, account: account, gmailID: "g2", bytes: messages[1]), runID: run1)
                }
                XCTFail("the fault at \(boundary) must interrupt")
            } catch let killed as Killed { XCTAssertEqual(killed.boundary, boundary) }
            sink = nil

            // Restart: a new process opens the same archive.
            let restarted = ConnectedArchiveSink(storeDirectory: here)
            let report = try await restarted.reconcileAfterRestart()
            XCTAssertEqual(report.recordsMissingBytes, 0, "\(boundary): no record may point at missing bytes")
            XCTAssertEqual(report.runsInterrupted, 1, "\(boundary)")
            if boundary == .afterStaging || boundary == .afterPublish {
                XCTAssertEqual(report.stagedFilesRemoved, 1, "\(boundary): the uncommitted staged bytes are cleaned up")
            }
            if boundary == .afterCommit {
                XCTAssertEqual(report.stagedFilesRemoved, 1, "\(boundary): the committed item's staging file is cleaned up")
            }
            let checkpoint = try await restarted.checkpoint(accountID: account, scope: "INBOX")
            XCTAssertNil(checkpoint, "\(boundary): the cursor never advanced")
            try await assertEveryRecordHasItsBytes(restarted, boundary: boundary)

            // Replay from the old (absent) cursor: every listed message is captured again.
            let run2 = try await restarted.beginRun(accountID: account, selection: "INBOX")
            try await restarted.recordDiscovered(runID: run2, identities: (1...3).map { .gmail(messageID: "g\($0)") })
            var states: [CaptureItemState] = []
            for n in 1...3 {
                states.append(try await restarted.capture(try item(restarted, account: account, gmailID: "g\(n)", bytes: messages[n - 1]), runID: run2).state)
            }
            try await restarted.advanceCheckpoint(accountID: account, scope: "INBOX", cursor: "after-g3", runID: run2)
            let receipt = try await restarted.finishRun(run2)
            XCTAssertEqual(receipt.state, .completed, "\(boundary)")
            XCTAssertEqual(receipt.total, 3); XCTAssertEqual(receipt.pending, 0)
            XCTAssertEqual(states[0], .alreadyPreserved, "\(boundary): m1 was preserved before the kill")
            switch boundary {
            case .afterStaging, .afterPublish: XCTAssertEqual(states[1], .stored, "\(boundary): m2 never committed")
            case .afterCommit: XCTAssertEqual(states[1], .alreadyPreserved, "\(boundary): m2 committed before the kill")
            case .beforeCheckpoint: XCTAssertEqual(states[1...2], [.alreadyPreserved, .alreadyPreserved])
            }
            let total = try await restarted.store.totalCount()
            XCTAssertEqual(total, 3, "\(boundary): exactly one record per provider message — none skipped, none doubled")
            let counts = try await restarted.store.connectedTableCounts()
            XCTAssertEqual(counts["remote_messages"], 3)
            let cp = try await restarted.checkpoint(accountID: account, scope: "INBOX")
            XCTAssertEqual(cp?.cursor, "after-g3")
            try await assertEveryRecordHasItsBytes(restarted, boundary: boundary, expected: messages)
        }
    }

    func assertEveryRecordHasItsBytes(_ sink: ConnectedArchiveSink, boundary: CaptureBoundary, expected: [Data]? = nil) async throws {
        let rows = try await sink.store.remoteMessageDigests()
        for row in rows {
            let ref = BlobReference(digest: row.digest, length: 0)
            XCTAssertTrue(sink.store.blobStore.exists(ref), "\(boundary): \(row.key) bytes present")
            let id = try XCTUnwrap(row.emailID)
            let email = try await sink.store.fullEmail(id: id)
            let raw = try XCTUnwrap(email?.rawSource)
            let digest = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(digest, row.digest, "\(boundary): the record reads back the exact captured bytes")
        }
        if let expected {
            let wanted = Set(expected.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() })
            XCTAssertEqual(Set(rows.map(\.digest)), wanted, "\(boundary)")
        }
    }

    // MARK: T12 — Message-ID never decides

    func testT12_sameMessageIDDifferentBodiesAndAccounts_keepsEveryRecord_tombstoneIsPerIdentity() async throws {
        let sink = ConnectedArchiveSink(storeDirectory: dir)
        let a = try await makeAccount(sink, display: "asha@example.com")
        let b = try await makeAccount(sink, display: "asha.work@example.com")
        let x = Self.message(id: "same@x", body: "Version X")
        let y = Self.message(id: "same@x", body: "Version Y — different body, same Message-ID")
        let runA = try await sink.beginRun(accountID: a, selection: "all")
        let runB = try await sink.beginRun(accountID: b, selection: "all")

        let ax = try await sink.capture(try item(sink, account: a, gmailID: "g1", bytes: x), runID: runA)
        let ay = try await sink.capture(try item(sink, account: a, gmailID: "g2", bytes: y), runID: runA)
        // Same provider id AND same bytes, but another account: its own occurrence.
        let bx = try await sink.capture(try item(sink, account: b, gmailID: "g1", bytes: x), runID: runB)
        XCTAssertEqual([ax.state, ay.state, bx.state], [.stored, .stored, .stored])
        XCTAssertEqual(Set([ax.emailID, ay.emailID, bx.emailID].compactMap { $0 }).count, 3)
        var total = try await sink.store.totalCount()
        XCTAssertEqual(total, 3, "Message-ID suppresses nothing")
        XCTAssertEqual(ax.sha256, bx.sha256, "the byte-identical blob may be shared; the records stay separate")

        // A repeated provider event (Gmail message now also labelled Work): one record, a new membership.
        let again = try await sink.capture(try item(sink, account: a, gmailID: "g1", bytes: x, labels: ["INBOX", "Work"]), runID: runA)
        XCTAssertEqual(again.state, .alreadyPreserved)
        XCTAssertEqual(again.emailID, ax.emailID)
        XCTAssertEqual(again.newMemberships, 1)
        total = try await sink.store.totalCount()
        XCTAssertEqual(total, 3)
        let provenance = try await sink.provenance(emailID: try XCTUnwrap(ax.emailID))
        XCTAssertEqual(provenance?.memberships, ["Inbox", "Work"])
        XCTAssertEqual(provenance?.accountID, a)
        let folders = try await sink.store.folderNodes().filter { $0.messageCount > 0 }.map(\.path).sorted()
        XCTAssertEqual(folders, ["Inbox", "Inbox", "Work"], "A's Inbox and Work, B's Inbox — per account source")

        // Local deletion of A/g1: re-capturing it does not resurrect it; B's copy and A/g2 are unaffected.
        try await sink.store.delete(ids: [try XCTUnwrap(ax.emailID)])
        let resurrect = try await sink.capture(try item(sink, account: a, gmailID: "g1", bytes: x), runID: runA)
        XCTAssertEqual(resurrect.state, .locallyDeleted)
        let other = try await sink.capture(try item(sink, account: b, gmailID: "g1", bytes: x), runID: runB)
        XCTAssertEqual(other.state, .alreadyPreserved)
        let fresh = try await sink.capture(try item(sink, account: b, gmailID: "g9", bytes: x), runID: runB)
        XCTAssertEqual(fresh.state, .stored, "a new provider identity is never suppressed by a deleted Message-ID")
        total = try await sink.store.totalCount()
        XCTAssertEqual(total, 3)
        let receipt = try await sink.finishRun(runA)
        XCTAssertEqual(receipt.locallyDeleted, 1)
    }

    // MARK: Identities, staging integrity

    func testProviderIdentity_isAccountQualifiedAndNeverASequenceNumberOrBareUID() throws {
        XCTAssertNotEqual(try ProviderMessageIdentity.imap(mailbox: "INBOX", uidValidity: 7, uid: 42).key(),
                          try ProviderMessageIdentity.imap(mailbox: "INBOX", uidValidity: 8, uid: 42).key(),
                          "a UIDVALIDITY change is a different identity")
        XCTAssertNotEqual(try ProviderMessageIdentity.imap(mailbox: "INBOX", uidValidity: 7, uid: 42).key(),
                          try ProviderMessageIdentity.imap(mailbox: "Archive", uidValidity: 7, uid: 42).key())
        XCTAssertNotEqual(try ProviderMessageIdentity.graph(mailbox: "a@x", immutableID: "AAMk").key(),
                          try ProviderMessageIdentity.graph(mailbox: "b@x", immutableID: "AAMk").key())
        XCTAssertThrowsError(try ProviderMessageIdentity.imap(mailbox: "INBOX", uidValidity: 0, uid: 1).key())
        XCTAssertThrowsError(try ProviderMessageIdentity.gmail(messageID: "").key())
        XCTAssertThrowsError(try ProviderMessageIdentity.graph(mailbox: "a\u{1F}b", immutableID: "c").key())
    }

    func testCapture_refusesBytesThatChangedAfterStaging_andRecordsNothing() async throws {
        let sink = ConnectedArchiveSink(storeDirectory: dir)
        let account = try await makeAccount(sink)
        let run = try await sink.beginRun(accountID: account, selection: "INBOX")
        let it = try item(sink, account: account, gmailID: "g1", bytes: Self.message(id: "t@x", body: "Original"))
        try Self.message(id: "t@x", body: "Tampered").write(to: it.raw.fileURL)
        do {
            _ = try await sink.capture(it, runID: run)
            XCTFail("changed bytes must not be preserved")
        } catch ConnectedArchiveError.stagedBytesMismatch {}
        let total = try await sink.store.totalCount()
        XCTAssertEqual(total, 0)
        let other = try await makeAccount(sink, display: "other@example.com")
        let wrong = try item(sink, account: other, gmailID: "g2", bytes: Self.message(id: "u@x", body: "x"))
        do {
            _ = try await sink.capture(wrong, runID: run)
            XCTFail("an item of another account must not enter this run")
        } catch ConnectedArchiveError.accountMismatch {}
    }

    // MARK: Provenance through export

    @MainActor
    func testProvenance_survivesEMLExport_byteIdentical_inventoryStillVerifiesClean() async throws {
        let sink = ConnectedArchiveSink(storeDirectory: dir.appendingPathComponent("store", isDirectory: true))
        let account = try await makeAccount(sink, provider: .imap, display: "asha@imap.example.com")
        let run = try await sink.beginRun(accountID: account, selection: "INBOX")
        let bytes = Self.message(id: "exp@x", body: "Export me")
        let it = CaptureItem(accountID: account, identity: .imap(mailbox: "INBOX", uidValidity: 1_700_000_000, uid: 7),
                             occurrences: [RemoteFolderOccurrence(serverID: "INBOX", displayPath: "Inbox", specialUse: "INBOX", uidValidity: 1_700_000_000)],
                             raw: try stage(sink, bytes), metadata: ProviderMetadata(representation: .imapLiteral))
        let outcome = try await sink.capture(it, runID: run)
        let store = sink.store
        let fts = FTSSearchIndex(shardsDirectory: dir.appendingPathComponent("fts", isDirectory: true))
        let service = ArchiveExportService(archive: ArchiveDataService(repository: EmailStoreRepository(store: store, fts: fts)))
        let out = dir.appendingPathComponent("export", isDirectory: true)
        let result = try await service.exportEMLFiles(scope: .explicit([try XCTUnwrap(outcome.emailID)]), to: out)
        XCTAssertEqual(result.recordsWritten, 1)
        let sidecarURL = try await sink.writeProvenanceSidecar(exportFolder: out)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let sidecar = try decoder.decode(ConnectedProvenanceSidecar.self, from: Data(contentsOf: try XCTUnwrap(sidecarURL)))
        let entry = try XCTUnwrap(sidecar.entries.first)
        XCTAssertTrue(entry.bytesIdenticalToCapture, "the exported .eml is the captured bytes")
        XCTAssertEqual(entry.provenance.accountID, account)
        XCTAssertEqual(entry.provenance.host, "imap.example.com")
        XCTAssertEqual(entry.provenance.uidValidity, 1_700_000_000)
        XCTAssertEqual(entry.provenance.uid, 7)
        XCTAssertEqual(entry.provenance.memberships, ["Inbox"])
        XCTAssertEqual(entry.provenance.representation, "imap-literal")
        XCTAssertTrue(try ExportInventory.verify(folder: out).isClean, "the sidecar is not stray output")
    }

    // MARK: V4-08 — the archive side of the five jobs

    final class IDBox: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [UUID] = []
        func add(_ id: UUID) { lock.withLock { ids.append(id) } }
        var value: [UUID] { lock.withLock { ids } }
    }

    /// The search feed hears of every NEW record once, after its commit — not
    /// of a repeated provider event.
    func testV408_storedObserver_firesOncePerNewRecord_notForRepeatedEvents() async throws {
        let sink = ConnectedArchiveSink(storeDirectory: dir.appendingPathComponent("store", isDirectory: true))
        let heard = IDBox()
        await sink.setStoredObserver { id in heard.add(id) }
        let account = try await makeAccount(sink)
        let run = try await sink.beginRun(accountID: account, selection: "INBOX")
        let first = try await sink.capture(try item(sink, account: account, gmailID: "o1", bytes: Self.message(id: "o1@x", body: "one")), runID: run)
        let again = try await sink.capture(try item(sink, account: account, gmailID: "o1", bytes: Self.message(id: "o1@x", body: "one"),
                                                     labels: ["INBOX", "Work"]), runID: run)
        XCTAssertEqual(first.state, .stored)
        XCTAssertEqual(again.state, .alreadyPreserved)
        XCTAssertEqual(heard.value, [try XCTUnwrap(first.emailID)], "one notification, for the stored record only")
    }

    /// A server folder renamed between syncs: the message shows under the new
    /// path, and its membership of the old path (the historical capture) stays.
    func testV408_serverFolderRenamed_keepsHistoricalMembership_andShowsTheCurrentPath() async throws {
        let sink = ConnectedArchiveSink(storeDirectory: dir.appendingPathComponent("store", isDirectory: true))
        let account = try await makeAccount(sink)
        let projects = RemoteFolderOccurrence(serverID: "Label_7", displayPath: "Projects", kind: .label)
        try await sink.recordFolders(accountID: account, folders: [projects])
        let run = try await sink.beginRun(accountID: account, selection: "all")
        var it = try item(sink, account: account, gmailID: "r1", bytes: Self.message(id: "r1@x", body: "renamed"))
        it.occurrences = [projects]
        let outcome = try await sink.capture(it, runID: run)
        _ = try await sink.finishRun(run)
        let id = try XCTUnwrap(outcome.emailID)

        try await sink.recordFolders(accountID: account, folders: [RemoteFolderOccurrence(serverID: "Label_7", displayPath: "Projects 2025", kind: .label)])
        let nodes = try await sink.store.folderNodes()
        let paths = Set(nodes.filter { $0.messageCount > 0 }.map(\.path))
        XCTAssertEqual(paths, ["Projects", "Projects 2025"], "old path kept, new path added")
        let loaded = try await sink.store.emails(withIDs: [id])
        let email = try XCTUnwrap(loaded.first)
        XCTAssertTrue(email.tags.contains("Projects 2025") || email.folderPath == "Projects 2025", "legacy tag dual write follows")
        // Listing again (no rename) adds nothing.
        try await sink.recordFolders(accountID: account, folders: [RemoteFolderOccurrence(serverID: "Label_7", displayPath: "Projects 2025", kind: .label)])
        let after = try await sink.store.folderNodes()
        XCTAssertEqual(after.reduce(0) { $0 + $1.messageCount }, 2)
    }

    /// Account, source (file vs account) and capture state are search
    /// conditions: they combine with OR branches and exclusions.
    func testV408_searchConditions_accountSourceKindCaptureState() async throws {
        let sink = ConnectedArchiveSink(storeDirectory: dir.appendingPathComponent("store", isDirectory: true))
        let store = sink.store
        let fileCopy = try MBOXParser.processRawMessage(String(decoding: Self.message(id: "file@x", body: "from a file"), as: UTF8.self), senderEmail: "")
        _ = try await store.insertBatch([fileCopy], sourceFileHash: nil, accountID: nil, sourceID: nil, firstOrdinal: nil,
                                        dedupPolicy: .preserveAll, batchSize: 10, progress: nil)
        let a = try await makeAccount(sink, display: "a@example.com")
        let b = try await makeAccount(sink, display: "b@example.com")
        let runA = try await sink.beginRun(accountID: a, selection: "all")
        let onA = try await sink.capture(try item(sink, account: a, gmailID: "a1", bytes: Self.message(id: "a1@x", body: "a one")), runID: runA)
        let goneA = try await sink.capture(try item(sink, account: a, gmailID: "a2", bytes: Self.message(id: "a2@x", body: "a two")), runID: runA)
        let runB = try await sink.beginRun(accountID: b, selection: "all")
        _ = try await sink.capture(try item(sink, account: b, gmailID: "b1", bytes: Self.message(id: "b1@x", body: "b one")), runID: runB)
        let marked = try await sink.markRemoteAbsent(accountID: a, identity: .gmail(messageID: "a2"))
        XCTAssertTrue(marked)

        let fts = FTSSearchIndex(shardsDirectory: dir.appendingPathComponent("fts", isDirectory: true))
        let archive = ArchiveDataService(repository: EmailStoreRepository(store: store, fts: fts))
        func expect(_ groups: [SearchGroup], _ expected: Int, line: UInt = #line) async throws {
            var q = EmailQuery()
            q.spec = SearchSpec(groups: groups)
            XCTAssertTrue(q.spec!.isValid, "\(groups)", line: line)
            let n = try await archive.count(query: q)
            XCTAssertEqual(n, expected, "\(groups)", line: line)
        }
        try await expect([SearchGroup(.all, [SearchCondition(.account, .equals, a.uuidString)])], 2)
        try await expect([SearchGroup(.all, [SearchCondition(.sourceKind, .equals, "connected")])], 3)
        try await expect([SearchGroup(.all, [SearchCondition(.sourceKind, .equals, "file")])], 1)
        try await expect([SearchGroup(.all, [SearchCondition(.captureState, .equals, "removedOnServer")])], 1)
        try await expect([SearchGroup(.all, [SearchCondition(.captureState, .equals, "onServer")])], 2)
        try await expect([SearchGroup(.any, [SearchCondition(.account, .equals, b.uuidString),
                                             SearchCondition(.sourceKind, .equals, "file")])], 2)
        try await expect([SearchGroup(.exclude, [SearchCondition(.account, .equals, a.uuidString)])], 2)
        XCTAssertFalse(SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.sourceKind, .equals, "cloud")])]).isValid)
        XCTAssertFalse(SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.account, .equals, "not-a-uuid")])]).isValid)
        _ = (onA, goneA)
    }

    /// An account whose inventory is not fully listed, or with queued /
    /// failed items, is a gap; a completed one is not.
    func testV408_acquisitionGaps_andAccountSearchCounts() async throws {
        let sink = ConnectedArchiveSink(storeDirectory: dir.appendingPathComponent("store", isDirectory: true))
        let account = try await makeAccount(sink, display: "gap@example.com")
        let run = try await sink.beginRun(accountID: account, selection: "all")
        _ = try await sink.capture(try item(sink, account: account, gmailID: "g1", bytes: Self.message(id: "g1@x", body: "saved")), runID: run)
        try await sink.recordDiscovered(runID: run, identities: [.gmail(messageID: "g2")])
        var gaps = try await sink.acquisitionGaps()
        XCTAssertEqual(gaps.map(\.accountID), [account])
        XCTAssertEqual(gaps.first?.saved, 1)
        XCTAssertEqual(gaps.first?.inventoryKnown, false)
        try await sink.recordFailure(runID: run, identity: .gmail(messageID: "g2"), state: .unavailable, reason: "gone")
        try await sink.advanceCheckpoint(accountID: account, scope: "sync", cursor: "9", bootstrapState: "ready@1", runID: run)
        _ = try await sink.finishRun(run)
        gaps = try await sink.acquisitionGaps()
        XCTAssertEqual(gaps, [], "listed to its end, nothing pending or failed: no gap")
        let counts = try await sink.searchCounts(accountID: account)
        XCTAssertEqual(counts.messages, 1)
        XCTAssertEqual(counts.attachments, 0)
    }

    /// The EML export writes the provenance sidecar itself; an export without
    /// connected mail gets none.
    @MainActor
    func testV408_emlExport_writesTheProvenanceSidecar_onlyWhenConnectedMailIsExported() async throws {
        let sink = ConnectedArchiveSink(storeDirectory: dir.appendingPathComponent("store", isDirectory: true))
        let store = sink.store
        let fileCopy = try MBOXParser.processRawMessage(String(decoding: Self.message(id: "plain@x", body: "file"), as: UTF8.self), senderEmail: "")
        _ = try await store.insertBatch([fileCopy], sourceFileHash: nil, accountID: nil, sourceID: nil, firstOrdinal: nil,
                                        dedupPolicy: .preserveAll, batchSize: 10, progress: nil)
        let fts = FTSSearchIndex(shardsDirectory: dir.appendingPathComponent("fts", isDirectory: true))
        let service = ArchiveExportService(archive: ArchiveDataService(repository: EmailStoreRepository(store: store, fts: fts)))
        let plain = dir.appendingPathComponent("plain", isDirectory: true)
        _ = try await service.exportEMLFiles(scope: .explicit([fileCopy.id]), to: plain)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plain.appendingPathComponent(ConnectedProvenanceSidecar.filename).path))

        let account = try await makeAccount(sink)
        let run = try await sink.beginRun(accountID: account, selection: "all")
        let outcome = try await sink.capture(try item(sink, account: account, gmailID: "e1", bytes: Self.message(id: "e1@x", body: "captured")), runID: run)
        let out = dir.appendingPathComponent("export", isDirectory: true)
        let result = try await service.exportEMLFiles(scope: .explicit([fileCopy.id, try XCTUnwrap(outcome.emailID)]), to: out)
        XCTAssertEqual(result.recordsWritten, 2)
        XCTAssertNil(result.inventoryFailure)
        let data = try Data(contentsOf: out.appendingPathComponent(ConnectedProvenanceSidecar.filename))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let sidecar = try decoder.decode(ConnectedProvenanceSidecar.self, from: data)
        XCTAssertEqual(sidecar.entries.map(\.provenance.accountID), [account], "only the connected message has provenance")
        XCTAssertTrue(try ExportInventory.verify(folder: out).isClean)
    }

    // MARK: - Fix pass 2026-11-14 (connected mail × five jobs)

    /// An 8-bit ISO-8859-1 message as a server delivers it (no UTF-8 anywhere).
    static func latin1Message(id: String, from: String = "Ravi <ravi@example.org>", to: String = "asha@example.com") -> Data {
        var bytes = Data(("Message-ID: <\(id)>\r\nFrom: \(from)\r\nTo: \(to)\r\nSubject: Caf").utf8)
        bytes.append(0xE9)
        bytes.append(Data(("\r\nDate: Mon, 6 Jan 2025 10:00:00 +0530\r\nMIME-Version: 1.0\r\n"
                           + "Content-Type: text/plain; charset=iso-8859-1\r\nContent-Transfer-Encoding: 8bit\r\n\r\n"
                           + "Meet at the caf").utf8))
        bytes.append(0xE9)
        bytes.append(Data(" tomorrow.\r\n".utf8))
        return bytes
    }

    @MainActor
    private func service(_ store: SQLiteEmailStore) -> ArchiveExportService {
        let fts = FTSSearchIndex(shardsDirectory: dir.appendingPathComponent("fts-\(UUID().uuidString)", isDirectory: true))
        return ArchiveExportService(archive: ArchiveDataService(repository: EmailStoreRepository(store: store, fts: fts)))
    }

    @MainActor
    private func archiveService(_ store: SQLiteEmailStore) -> ArchiveDataService {
        let fts = FTSSearchIndex(shardsDirectory: dir.appendingPathComponent("fts-\(UUID().uuidString)", isDirectory: true))
        return ArchiveDataService(repository: EmailStoreRepository(store: store, fts: fts))
    }

    private func reconcileLookup(_ store: SQLiteEmailStore) -> ExportReconciliation.SourceLookup {
        ExportReconciliation.SourceLookup(
            records: { ids in
                var out: [UUID: MBOXParser.RawEmail] = [:]
                for id in ids { if let e = try await store.fullEmail(id: id) { out[id] = e } }
                return out
            },
            recordsByMessageID: { mids in
                var out: [String: MBOXParser.RawEmail] = [:]
                for (key, id) in try await store.emailIDs(forMessageIDs: mids) { if let e = try await store.fullEmail(id: id) { out[key] = e } }
                return out
            })
    }

    /// Finding 1: captured 8-bit Latin-1 mail is decoded as the store decodes
    /// raw MIME (UTF-8, else Latin-1): the body reads "café", search finds it,
    /// the .eml export is the captured bytes exactly, the mbox carries the
    /// original bytes, and both verify against the archive.
    @MainActor
    func testFix1_latin1Capture_searchFindsCafe_exportsAreTheCapturedBytes_andReconcile() async throws {
        let chunksWereOn = SearchChunkPolicy.isEnabled
        SearchChunkPolicy.isEnabled = true
        defer { SearchChunkPolicy.isEnabled = chunksWereOn }
        let sink = ConnectedArchiveSink(storeDirectory: dir.appendingPathComponent("store", isDirectory: true))
        let store = sink.store
        let account = try await makeAccount(sink)
        let run = try await sink.beginRun(accountID: account, selection: "INBOX")
        let bytes = Self.latin1Message(id: "latin@x")
        let outcome = try await sink.capture(try item(sink, account: account, gmailID: "l1", bytes: bytes), runID: run)
        let id = try XCTUnwrap(outcome.emailID)

        let email = try await XCTUnwrapAsync(await store.fullEmail(id: id))
        XCTAssertTrue(email.plainBody.contains("café"), "the 8-bit body decodes: \(email.plainBody)")
        XCTAssertFalse(email.plainBody.contains("\u{FFFD}"))
        XCTAssertEqual(email.headers["Subject"], "Café")

        var q = EmailQuery()
        q.spec = SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.body, .contains, "café")])])
        let found = try await archiveService(store).count(query: q)
        XCTAssertEqual(found, 1, "search finds café")

        let service = service(store)
        let emlFolder = dir.appendingPathComponent("eml", isDirectory: true)
        let eml = try await service.exportEMLFiles(scope: .explicit([id]), to: emlFolder)
        XCTAssertEqual(eml.recordsWritten, 1)
        let inventory = try ExportInventory.load(folder: emlFolder)
        let file = try XCTUnwrap(inventory.files.first)
        XCTAssertEqual(try Data(contentsOf: emlFolder.appendingPathComponent(file.path)), bytes, "the .eml is the captured bytes, byte for byte")
        let emlReport = await ExportReconciliation.reconcile(folder: emlFolder, lookup: reconcileLookup(store))
        XCTAssertEqual(emlReport.outcome, .complete, "\(emlReport.summary)\n\(emlReport.findings)")

        let mbox = dir.appendingPathComponent("latin.mbox")
        let mboxResult = try await service.exportMBOXArchive(scope: .explicit([id]), to: mbox)
        XCTAssertEqual(mboxResult.recordsWritten, 1)
        let written = try Data(contentsOf: mbox)
        XCTAssertNotNil(written.range(of: bytes.suffix(from: bytes.firstRange(of: Data("Meet".utf8))!.lowerBound)),
                        "the mbox record carries the original 8-bit bytes")
        XCTAssertNil(written.range(of: Data("caf\u{FFFD}".utf8)))
        let mboxReport = await ExportReconciliation.reconcile(file: mbox, promised: 1, lookup: reconcileLookup(store))
        XCTAssertEqual(mboxReport.outcome, .complete, "\(mboxReport.summary)\n\(mboxReport.findings)")
    }

    private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }

    /// Finding 2: duplicate cleanup that keeps an imported copy and trashes
    /// the captured one hands the account link to the survivor — account
    /// search, the Mail workspace and provenance still find the mail, and a
    /// later label change lands on the survivor.
    @MainActor
    func testFix2_duplicateCleanup_carriesTheAccountLinkToTheSurvivor() async throws {
        let sink = ConnectedArchiveSink(storeDirectory: dir.appendingPathComponent("store", isDirectory: true))
        let store = sink.store
        let bytes = Self.message(id: "dup@x", body: "Same mail twice")
        let fileCopy = try MBOXParser.processRawMessage(String(decoding: bytes, as: UTF8.self), senderEmail: "")
        _ = try await store.insertBatch([fileCopy], sourceFileHash: nil, accountID: nil, sourceID: nil, firstOrdinal: nil,
                                        dedupPolicy: .preserveAll, batchSize: 10, progress: nil)
        let account = try await makeAccount(sink)
        let run = try await sink.beginRun(accountID: account, selection: "all")
        let captured = try await XCTUnwrapAsync(sink.capture(item(sink, account: account, gmailID: "d1", bytes: bytes), runID: run).emailID)

        let result = try await store.removeDuplicateCopies([.init(survivor: fileCopy.id, removed: [captured])])
        XCTAssertEqual(result.trashed, [captured])
        XCTAssertEqual(result.accountLinksCarried, 1)

        var q = EmailQuery()
        q.spec = SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.account, .equals, account.uuidString)])])
        let inAccount = try await archiveService(store).count(query: q)
        XCTAssertEqual(inAccount, 1, "account search still finds the mail (the survivor)")
        let page = try await sink.mailboxPage(ConnectedMailboxQuery(accountIDs: [account]))
        XCTAssertEqual(page.rows.map(\.emailID), [fileCopy.id], "the Mail workspace lists the survivor")
        let provenance = try await sink.provenance(emailID: fileCopy.id)
        XCTAssertEqual(provenance?.accountID, account)

        // A later label on the server attaches to the survivor.
        let again = try await sink.capture(try item(sink, account: account, gmailID: "d1", bytes: bytes, labels: ["INBOX", "Work"]), runID: run)
        XCTAssertEqual(again.state, .alreadyPreserved)
        XCTAssertEqual(again.emailID, fileCopy.id)
        let survivor = try await XCTUnwrapAsync(await store.fullEmail(id: fileCopy.id))
        XCTAssertTrue(SQLiteEmailStore.folderPaths(for: survivor).contains("Work"), "\(SQLiteEmailStore.folderPaths(for: survivor))")
    }

    /// Finding 4: a Sources row selects by source id — "inbox.mbox" does not
    /// also select "old-inbox.mbox" — and two accounts with one address are
    /// named apart by provider.
    @MainActor
    func testFix4_sourceSelection_byID_andSameAddressAccountsAreNamedApart() async throws {
        let store = SQLiteEmailStore(directory: dir.appendingPathComponent("store", isDirectory: true))
        var ids: [Int64] = []
        for (n, name) in ["inbox.mbox", "old-inbox.mbox"].enumerated() {
            let source = try await store.registerSource(SQLiteEmailStore.SourceDescriptor(sha256: String(repeating: "\(n)", count: 64), filename: name, byteSize: 1,
                                                                         parser: "mbox", parserVersion: 1, accountID: nil, sourceKind: "file"))
            ids.append(source)
            let email = try MBOXParser.processRawMessage(String(decoding: Self.message(id: "s\(n)@x", body: "b\(n)"), as: UTF8.self), senderEmail: "")
            _ = try await store.insertBatch([email], sourceFileHash: nil, accountID: nil, sourceID: source, firstOrdinal: 0,
                                            dedupPolicy: .preserveAll, batchSize: 10, progress: nil)
        }
        let archive = archiveService(store)
        for id in ids {
            var q = EmailQuery(); q.sourceID = id
            let n = try await archive.count(query: q)
            XCTAssertEqual(n, 1, "source \(id) selects its own message only")
        }
        let names = ConnectedAccountNaming.distinctNames([
            .init(key: "a", display: "asha@example.com", provider: .gmail),
            .init(key: "b", display: "asha@example.com", provider: .imap),
            .init(key: "c", display: "other@example.com", provider: .gmail),
            .init(key: "f", display: "asha@example.com", provider: nil),
        ])
        XCTAssertEqual(names["a"], "asha@example.com · Gmail")
        XCTAssertEqual(names["b"], "asha@example.com · IMAP")
        XCTAssertEqual(names["c"], "other@example.com")
        XCTAssertEqual(names["f"], "asha@example.com", "a file source keeps its name")
        XCTAssertEqual(ConnectedAccountNaming.provider(parser: "connected-graph"), .microsoftGraph)
        XCTAssertNil(ConnectedAccountNaming.provider(parser: "mbox"))
    }

    /// Finding 5: deleting an account's archived mail writes no Message-ID
    /// tombstone, so the same mail imported afterwards is stored.
    func testFix5_accountArchiveDeletion_doesNotTombstone_reimportAfterwardsWorks() async throws {
        let sink = ConnectedArchiveSink(storeDirectory: dir.appendingPathComponent("store", isDirectory: true))
        let store = sink.store
        let account = try await makeAccount(sink)
        let run = try await sink.beginRun(accountID: account, selection: "all")
        let bytes = Self.message(id: "again@x", body: "Comes back")
        _ = try await sink.capture(try item(sink, account: account, gmailID: "t1", bytes: bytes), runID: run)
        _ = try await sink.finishRun(run)
        let summary = try await sink.accountArchiveSummary(accountID: account)
        let deletion = try await sink.deleteAccountArchive(accountID: account, confirmedCount: summary.deletable)
        XCTAssertEqual(deletion.deletedEmailIDs.count, 1)

        let fileCopy = try MBOXParser.processRawMessage(String(decoding: bytes, as: UTF8.self), senderEmail: "")
        let inserted = try await store.insertBatch([fileCopy], sourceFileHash: nil, accountID: nil, sourceID: nil, firstOrdinal: nil,
                                                   dedupPolicy: .messageID, batchSize: 10, progress: nil)
        XCTAssertEqual(inserted.insertedIDs, [fileCopy.id], "a later import of the same mail is stored, not refused by a tombstone")
        let total = try await store.totalCount()
        XCTAssertEqual(total, 1)
    }

    /// Finding 6: the account deletion never removes the only visible copy —
    /// a survivor whose duplicate is in the Trash, or a record the account's
    /// link was carried to — and says how many it kept.
    func testFix6_accountDeletion_keepsTheOnlyVisibleCopy_andCountsItApart() async throws {
        let sink = ConnectedArchiveSink(storeDirectory: dir.appendingPathComponent("store", isDirectory: true))
        let store = sink.store
        let account = try await makeAccount(sink)
        let run = try await sink.beginRun(accountID: account, selection: "all")
        // (a) captured copy survives, the imported copy went to the Trash.
        let a = Self.message(id: "keep-a@x", body: "A")
        let fileA = try MBOXParser.processRawMessage(String(decoding: a, as: UTF8.self), senderEmail: "")
        _ = try await store.insertBatch([fileA], sourceFileHash: nil, accountID: nil, sourceID: nil, firstOrdinal: nil,
                                        dedupPolicy: .preserveAll, batchSize: 10, progress: nil)
        let capA = try await XCTUnwrapAsync(sink.capture(item(sink, account: account, gmailID: "ka", bytes: a), runID: run).emailID)
        _ = try await store.removeDuplicateCopies([.init(survivor: capA, removed: [fileA.id])])
        // (b) the imported copy survives, the captured one's link was carried to it.
        let b = Self.message(id: "keep-b@x", body: "B")
        let fileB = try MBOXParser.processRawMessage(String(decoding: b, as: UTF8.self), senderEmail: "")
        _ = try await store.insertBatch([fileB], sourceFileHash: nil, accountID: nil, sourceID: nil, firstOrdinal: nil,
                                        dedupPolicy: .preserveAll, batchSize: 10, progress: nil)
        let capB = try await XCTUnwrapAsync(sink.capture(item(sink, account: account, gmailID: "kb", bytes: b), runID: run).emailID)
        _ = try await store.removeDuplicateCopies([.init(survivor: fileB.id, removed: [capB])])
        // (c) an ordinary captured message: deletable.
        let c = try await XCTUnwrapAsync(sink.capture(item(sink, account: account, gmailID: "kc", bytes: Self.message(id: "plain-c@x", body: "C")), runID: run).emailID)

        let summary = try await sink.accountArchiveSummary(accountID: account)
        XCTAssertEqual(summary.records, 3)
        XCTAssertEqual(summary.held, 0)
        XCTAssertEqual(summary.keptOnlyCopy, 2)
        XCTAssertEqual(summary.deletable, 1)
        let deletion = try await sink.deleteAccountArchive(accountID: account, confirmedCount: summary.deletable)
        XCTAssertEqual(deletion.deletedEmailIDs, [c])
        XCTAssertEqual(deletion.keptOnlyCopy, 2)
        let left = try await store.emails(withIDs: [capA, fileB.id])
        XCTAssertEqual(Set(left.map(\.id)), [capA, fileB.id], "both only-visible copies remain")
    }

    /// Finding 7: captured mail the account sent is "sent" — by its own
    /// address, or by a Sent folder / label.
    func testFix7_capturedSentMail_isClassifiedSent() async throws {
        let sink = ConnectedArchiveSink(storeDirectory: dir.appendingPathComponent("store", isDirectory: true))
        let account = try await makeAccount(sink, display: "asha@example.com")
        let run = try await sink.beginRun(accountID: account, selection: "all")
        let byAddress = try await sink.capture(try item(sink, account: account, gmailID: "s1", bytes: Self.message(id: "s1@x", body: "mine")), runID: run)
        let bySent = try await sink.capture(try item(sink, account: account, gmailID: "s2",
                                                     bytes: Self.latin1Message(id: "s2@x", from: "Shared <team@example.org>"), labels: ["SENT"]), runID: run)
        let received = try await sink.capture(try item(sink, account: account, gmailID: "s3",
                                                       bytes: Self.latin1Message(id: "s3@x"), labels: ["INBOX"]), runID: run)
        let loaded = try await sink.store.emails(withIDs: [byAddress, bySent, received].compactMap(\.emailID))
        let types = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0.messageType) })
        XCTAssertEqual(types[try XCTUnwrap(byAddress.emailID)], "sent", "From is the account's own address")
        XCTAssertEqual(types[try XCTUnwrap(bySent.emailID)], "sent", "observed in the Sent label")
        XCTAssertEqual(types[try XCTUnwrap(received.emailID)], "received")
    }

    /// Finding 8: a folder export files captured Gmail mail under its Inbox,
    /// not under "All Mail" (which sorts first).
    @MainActor
    func testFix8_folderExport_filesGmailMailUnderTheInbox_notAllMail() async throws {
        XCTAssertEqual(ArchiveExportService.primaryFolderFirst(["All Mail", "Inbox", "Projects"]).first, "Inbox")
        XCTAssertEqual(ArchiveExportService.primaryFolderFirst(["All Mail", "Projects"]).first, "Projects")
        XCTAssertEqual(ArchiveExportService.primaryFolderFirst(["[Gmail]/All Mail", "Work"]), ["Work", "[Gmail]/All Mail"])
        XCTAssertEqual(ArchiveExportService.primaryFolderFirst(["All Mail"]), ["All Mail"])

        let sink = ConnectedArchiveSink(storeDirectory: dir.appendingPathComponent("store", isDirectory: true))
        let account = try await makeAccount(sink)
        let run = try await sink.beginRun(accountID: account, selection: "all")
        var it = try item(sink, account: account, gmailID: "f1", bytes: Self.message(id: "f1@x", body: "filed"))
        it.occurrences = [RemoteFolderOccurrence(serverID: "mailin:all-mail", displayPath: "All Mail", kind: .label, specialUse: "\\All"),
                          RemoteFolderOccurrence(serverID: "INBOX", displayPath: "Inbox", kind: .label, specialUse: "INBOX"),
                          RemoteFolderOccurrence(serverID: "Label_1", displayPath: "Projects", kind: .label)]
        let id = try await XCTUnwrapAsync(sink.capture(it, runID: run).emailID)
        var options = ExportWriteOptions(); options.layout = .sourceFolders
        let out = dir.appendingPathComponent("folders", isDirectory: true)
        let result = try await service(sink.store).exportEMLFiles(scope: .explicit([id]), to: out, write: options)
        XCTAssertEqual(result.recordsWritten, 1)
        let files = try ExportInventory.load(folder: out).files.map(\.path)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].hasPrefix("Inbox/"), "\(files)")
    }

    /// Finding 9: the provenance sidecar is written for MBOX, PST and MSG
    /// exports too (beside a container, inside a folder).
    @MainActor
    func testFix9_provenanceSidecar_forMBOX_PST_andMSG() async throws {
        let sink = ConnectedArchiveSink(storeDirectory: dir.appendingPathComponent("store", isDirectory: true))
        let account = try await makeAccount(sink)
        let run = try await sink.beginRun(accountID: account, selection: "all")
        let id = try await XCTUnwrapAsync(sink.capture(item(sink, account: account, gmailID: "p1", bytes: Self.message(id: "p1@x", body: "prov")), runID: run).emailID)
        let service = service(sink.store)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601

        let mbox = dir.appendingPathComponent("out.mbox")
        let m = try await service.exportMBOXArchive(scope: .explicit([id]), to: mbox)
        XCTAssertNil(m.inventoryFailure)
        let mboxSidecar = try decoder.decode(ConnectedProvenanceSidecar.self,
                                             from: Data(contentsOf: ConnectedProvenanceSidecar.url(forContainer: mbox)))
        XCTAssertEqual(mboxSidecar.entries.map(\.provenance.accountID), [account])
        XCTAssertEqual(mboxSidecar.entries.first?.ordinal, 0)
        XCTAssertEqual(mboxSidecar.entries.first?.fileSHA256.count, 64, "the record's bytes in the mbox are hashed")

        let pst = dir.appendingPathComponent("out.pst")
        _ = try await service.exportPST(scope: .explicit([id]), to: pst)
        let pstSidecar = try decoder.decode(ConnectedProvenanceSidecar.self,
                                            from: Data(contentsOf: ConnectedProvenanceSidecar.url(forContainer: pst)))
        XCTAssertEqual(pstSidecar.entries.map(\.provenance.emailID), [id])

        let msg = dir.appendingPathComponent("msg", isDirectory: true)
        let r = try await service.exportMSGFiles(scope: .explicit([id]), to: msg)
        XCTAssertNil(r.inventoryFailure)
        XCTAssertTrue(FileManager.default.fileExists(atPath: msg.appendingPathComponent(ConnectedProvenanceSidecar.filename).path))
        XCTAssertTrue(try ExportInventory.verify(folder: msg).isClean)

        // A renamed PST part carries its provenance with it.
        let renamed = dir.appendingPathComponent("named.pst")
        try FileManager.default.moveItem(at: pst, to: renamed)
        try ContainerManifest.moveSidecar(from: pst, to: renamed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ConnectedProvenanceSidecar.url(forContainer: renamed).path))
    }

    /// Finding 10: parsing a capture writes no temporary file per attachment.
    func testFix10_captureParse_writesNoTemporaryAttachmentFiles() async throws {
        let sink = ConnectedArchiveSink(storeDirectory: dir.appendingPathComponent("store", isDirectory: true))
        let raw = "Message-ID: <att@x>\r\nFrom: a@example.com\r\nTo: b@example.com\r\nSubject: With file\r\nMIME-Version: 1.0\r\n"
            + "Content-Type: multipart/mixed; boundary=\"b1\"\r\n\r\n--b1\r\nContent-Type: text/plain\r\n\r\nSee attached.\r\n"
            + "--b1\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=\"data.bin\"\r\n"
            + "Content-Transfer-Encoding: base64\r\n\r\nAAECAwQFBgcICQ==\r\n--b1--\r\n"
        let blob = try sink.store.blobStore.write(Data(raw.utf8))
        let email = try ConnectedArchiveSink.record(from: blob, store: sink.store, occurrences: [])
        XCTAssertEqual(email.attachments.count, 1)
        XCTAssertTrue(email.attachments.allSatisfy { $0.fileURL == nil }, "no temporary copy of an attachment")
    }

    /// Findings 12 and 13: a removed account whose mail is gone leaves no
    /// Sources row, no empty server-folder tree and no account-picker entry;
    /// while it still has mail it stays.
    func testFix12_13_removedAccountWithoutMail_isHiddenFromSourcesFoldersAndPicker() async throws {
        let sink = ConnectedArchiveSink(storeDirectory: dir.appendingPathComponent("store", isDirectory: true))
        let store = sink.store
        let account = try await makeAccount(sink)
        let other = try await makeAccount(sink, display: "other@example.com")
        try await sink.recordFolders(accountID: account, folders: [RemoteFolderOccurrence(serverID: "Label_E", displayPath: "Empty", kind: .label)])
        let run = try await sink.beginRun(accountID: account, selection: "all")
        _ = try await sink.capture(try item(sink, account: account, gmailID: "g1", bytes: Self.message(id: "g1@x", body: "x")), runID: run)
        _ = try await sink.finishRun(run)
        let records = try await sink.accountRecords()
        var removed = try XCTUnwrap(records.first { $0.accountID == account })
        let source = try XCTUnwrap(removed.archiveSourceID)
        removed.connectionState = "removed"
        try await sink.saveAccount(removed)

        var hidden = try await store.hiddenConnectedSourceIDs()
        XCTAssertFalse(hidden.contains(source), "a removed account that still has mail stays listed")
        var searchable = try await sink.searchableAccounts()
        XCTAssertEqual(Set(searchable.map(\.accountID)), [account, other])

        let summary = try await sink.accountArchiveSummary(accountID: account)
        _ = try await sink.deleteAccountArchive(accountID: account, confirmedCount: summary.deletable)
        hidden = try await store.hiddenConnectedSourceIDs()
        XCTAssertEqual(hidden, [source], "its row and empty folder tree are left out; the connected account with no mail yet is not")
        searchable = try await sink.searchableAccounts()
        XCTAssertEqual(searchable.map(\.accountID), [other])
        let nodes = try await store.folderNodes()
        XCTAssertTrue(nodes.contains { $0.sourceID == source }, "nothing is deleted — the folders are hidden, not removed")
    }

    /// Finding 3 (precondition of the duplicate check): two unreadable
    /// captures with different bytes load with no identifying header, no body
    /// and no attachment — their raw sources differ — so the duplicate
    /// verifier (app, `DuplicateVerification.hasParsedContent`) cannot call
    /// them content-equivalent.
    func testFix3_unreadableCaptures_loadWithNoParsedContent_andDifferentRawBytes() async throws {
        let sink = ConnectedArchiveSink(storeDirectory: dir.appendingPathComponent("store", isDirectory: true))
        struct Unreadable: Error {}
        await sink.setParseFaultHook { _ in throw Unreadable() }
        let account = try await makeAccount(sink)
        let run = try await sink.beginRun(accountID: account, selection: "all")
        let a = try await sink.capture(try item(sink, account: account, gmailID: "u1", bytes: Data("garbage one \u{1}".utf8)), runID: run)
        let b = try await sink.capture(try item(sink, account: account, gmailID: "u2", bytes: Data("garbage two \u{2}".utf8)), runID: run)
        let loaded = try await sink.store.emails(withIDs: [a.emailID, b.emailID].compactMap { $0 })
        XCTAssertEqual(loaded.count, 2)
        for email in loaded {
            XCTAssertTrue(email.plainBody.isEmpty && email.htmlBody.isEmpty && email.attachments.isEmpty)
            for header in ["From", "To", "Cc", "Subject", "Date", "Message-ID"] {
                let value = email.headers[header] ?? ""
                XCTAssertTrue(value.isEmpty || (header == "Subject" && value == "(No Subject)"), "\(header): \(value)")
            }
            XCTAssertFalse(email.rawSource.isEmpty, "the preserved bytes are the raw source")
        }
        XCTAssertNotEqual(loaded[0].rawSource, loaded[1].rawSource)
    }
}
