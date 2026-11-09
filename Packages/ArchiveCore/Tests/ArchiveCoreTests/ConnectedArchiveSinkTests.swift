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
}
