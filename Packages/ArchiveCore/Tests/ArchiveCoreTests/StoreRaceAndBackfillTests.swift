//
//  StoreRaceAndBackfillTests.swift
//  ArchiveCoreTests
//
//  Whole-codebase review 2026-11-16:
//    B2 (P0) — orphan-blob collection could delete a connected capture's
//      bytes between publish and row commit. Interleave publish → GC → commit
//      and require the blob to survive and the row to read it back; pins are
//      released on every exit; the age grace spares fresh and re-used blobs.
//    B7 (P1) — the folder backfill dropped (email, folder) memberships at
//      every page boundary. Force boundaries with a page size of 1 and
//      require every membership; an archive damaged by the old backfill is
//      repaired once at open, additively.
//

import XCTest
import Foundation
import SQLite3
import CryptoKit
@testable import ArchiveCore

final class StoreRaceAndBackfillTests: XCTestCase {
    private var dir: URL!
    private var savedPageSize = 0

    override func setUpWithError() throws {
        savedPageSize = SQLiteEmailStore.folderBackfillPageSize
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("race-backfill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        SQLiteEmailStore.folderBackfillPageSize = savedPageSize
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    // MARK: - B2 helpers

    struct Killed: Error {}

    static func message(id: String, body: String) -> Data {
        Data(("Message-ID: <\(id)>\r\nFrom: Asha <asha@example.com>\r\nTo: ravi@example.org\r\n"
              + "Subject: Race \(id)\r\nDate: Mon, 6 Jan 2025 10:00:00 +0530\r\nMIME-Version: 1.0\r\n"
              + "Content-Type: text/plain; charset=utf-8\r\n\r\n\(body)\r\n").utf8)
    }

    static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func makeAccount(_ sink: ConnectedArchiveSink) async throws -> UUID {
        let id = UUID()
        try await sink.saveAccount(ConnectedAccountRecord(
            accountID: id, provider: .gmail, issuer: "https://accounts.google.com", host: nil, port: nil,
            displayIdentity: "asha@example.com", grantedScopes: ["https://www.googleapis.com/auth/gmail.readonly"],
            enabledModes: ["capture"], connectionState: "connected", createdAt: Date(), updatedAt: Date()))
        return id
    }

    func item(_ sink: ConnectedArchiveSink, account: UUID, gmailID: String, bytes: Data) throws -> CaptureItem {
        let writer = try sink.makeStagingWriter()
        try writer.append(bytes)
        return CaptureItem(accountID: account, identity: .gmail(messageID: gmailID),
                           occurrences: [RemoteFolderOccurrence(serverID: "INBOX", displayPath: "Inbox", kind: .label)],
                           raw: try writer.finish(),
                           metadata: ProviderMetadata(representation: .gmailRaw, internalDate: Date(timeIntervalSince1970: 1_736_137_800),
                                                      revision: "h-\(gmailID)", flags: []))
    }

    func setModificationDate(_ blobs: BlobStore, _ digest: String, secondsAgo: TimeInterval) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-secondsAgo)],
                                              ofItemAtPath: blobs.url(for: digest).path)
    }

    // MARK: - B2

    /// The race as it happens: the sink publishes, a collector that read the
    /// referenced set before the commit runs, then the sink commits.
    func testB2_collectionBetweenPublishAndCommit_spareTheBlob_andTheRowReadsItBack() async throws {
        let sink = ConnectedArchiveSink(storeDirectory: dir)
        let account = try await makeAccount(sink)
        let run = try await sink.beginRun(accountID: account, selection: "INBOX")
        let bytes = Self.message(id: "race-1@x", body: "Bytes that must survive the collector")
        let digest = Self.sha(bytes)
        let blobs = sink.store.blobStore

        let deletedInWindow = LockedCount()
        await sink.setFaultHook { boundary in
            guard boundary == .afterPublish else { return }
            // No row names the blob yet, so the live set is empty — exactly
            // what a file import's end-of-run collection reads at this moment.
            let collected = blobs.collectOrphans(referenced: [])
            deletedInWindow.add(collected.deleted)
        }
        let outcome = try await sink.capture(try item(sink, account: account, gmailID: "g1", bytes: bytes), runID: run)

        XCTAssertEqual(outcome.state, .stored)
        XCTAssertEqual(deletedInWindow.value, 0, "a published-but-uncommitted blob must never be collected")
        XCTAssertTrue(blobs.exists(BlobReference(digest: digest, length: Int64(bytes.count))),
                      "the bytes the row names are on disk")
        let email = try await sink.store.fullEmail(id: try XCTUnwrap(outcome.emailID))
        let raw = try XCTUnwrap(email?.rawSource)
        XCTAssertEqual(Self.sha(Data(raw.utf8)), digest, "the row reads back the exact captured bytes")
        XCTAssertFalse(blobs.isPinned(digest), "the pin is released after the commit")

        // Now committed and referenced: a real collection keeps it.
        let after = try await sink.store.collectBlobOrphans()
        XCTAssertEqual(after.deleted, 0)
    }

    /// The store-level collector (the one `BulkImportCoordinator` calls)
    /// honours a pin, and collects the same blob once the pin is released.
    func testB2_storeCollector_skipsPinnedBlob_untilReleased() async throws {
        let store = SQLiteEmailStore(directory: dir)
        _ = try await store.totalCount()
        let staged = dir.appendingPathComponent("staged.eml")
        try Self.message(id: "pin@x", body: "pinned").write(to: staged)
        let blobs = store.blobStore

        let ref = try blobs.write(contentsOf: staged, pin: true)
        XCTAssertTrue(blobs.isPinned(ref.digest))
        let during = try await store.collectBlobOrphans()
        XCTAssertEqual(during.deleted, 0, "a pinned blob is in flight, not an orphan")
        XCTAssertTrue(blobs.exists(ref))

        blobs.unpin(ref.digest)
        XCTAssertFalse(blobs.isPinned(ref.digest))
        let afterRelease = try await store.collectBlobOrphans()
        XCTAssertEqual(afterRelease.deleted, 1, "once released and still unreferenced, it is an ordinary orphan")
        XCTAssertFalse(blobs.exists(ref))
    }

    /// A capture that throws after publishing (the fault hook stands in for
    /// any failure before the commit) releases its pin, so the orphan it
    /// leaves is collectable — a pin never leaks.
    func testB2_failedCapture_releasesItsPin() async throws {
        let sink = ConnectedArchiveSink(storeDirectory: dir)
        let account = try await makeAccount(sink)
        let run = try await sink.beginRun(accountID: account, selection: "INBOX")
        let bytes = Self.message(id: "fail@x", body: "never committed")
        await sink.setFaultHook { if $0 == .afterPublish { throw Killed() } }
        do {
            _ = try await sink.capture(try item(sink, account: account, gmailID: "g9", bytes: bytes), runID: run)
            XCTFail("the fault must interrupt")
        } catch is Killed {}
        let blobs = sink.store.blobStore
        XCTAssertFalse(blobs.isPinned(Self.sha(bytes)))
        let collected = try await sink.store.collectBlobOrphans()
        XCTAssertEqual(collected.deleted, 1, "the uncommitted blob is an ordinary orphan after the failure")
    }

    /// Belt and braces: the age grace spares a blob written moments ago, and
    /// one an in-actor writer has just re-used (its date is refreshed).
    func testB2_ageGrace_sparesFreshAndReusedBlobs() async throws {
        let store = SQLiteEmailStore(directory: dir)
        _ = try await store.totalCount()
        let blobs = store.blobStore
        let grace = SQLiteEmailStore.blobOrphanGraceSeconds

        let data = Data(repeating: 0x41, count: 256)
        let ref = try blobs.write(data)
        var result = try await store.collectBlobOrphans(minimumAge: grace)
        XCTAssertEqual(result.deleted, 0, "a blob written inside the grace is not collected")

        // Old, then re-used by a writer: inside the grace again.
        try setModificationDate(blobs, ref.digest, secondsAgo: grace * 2)
        _ = try blobs.write(data)
        result = try await store.collectBlobOrphans(minimumAge: grace)
        XCTAssertEqual(result.deleted, 0, "re-using an existing blob refreshes its date")

        // Old and untouched: collected.
        try setModificationDate(blobs, ref.digest, secondsAgo: grace * 2)
        result = try await store.collectBlobOrphans(minimumAge: grace)
        XCTAssertEqual(result.deleted, 1)
        XCTAssertFalse(blobs.exists(ref))
    }

    // MARK: - B7 helpers

    func email(_ n: Int, folder: String, labels: [String]) throws -> MBOXParser.RawEmail {
        var e = try MBOXParser.processRawMessage(String(decoding: Self.message(id: "fold-\(n)@x", body: "Folder \(n)"), as: UTF8.self),
                                                 senderEmail: "")
        e.folderPath = folder
        e.tags = labels
        return e
    }

    func insert(_ store: SQLiteEmailStore, _ emails: [MBOXParser.RawEmail]) async throws {
        _ = try await store.insertBatch(emails, sourceFileHash: nil, accountID: nil, sourceID: nil, firstOrdinal: nil,
                                        dedupPolicy: .messageID, batchSize: 50, progress: nil)
    }

    /// (email id, folder path) for every membership, read on its own connection.
    func memberships() throws -> Set<String> {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dir.appendingPathComponent("emails.db").path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw XCTSkip("cannot open")
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT ef.email_id, f.path FROM email_folders ef JOIN folders f ON f.folder_id = ef.folder_id;", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        var out: Set<String> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.insert(String(cString: sqlite3_column_text(stmt, 0)) + "|" + String(cString: sqlite3_column_text(stmt, 1)))
        }
        return out
    }

    func metaRows() throws -> Int {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dir.appendingPathComponent("emails.db").path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw XCTSkip("cannot open")
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM meta;", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : -1
    }

    func execute(_ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dir.appendingPathComponent("emails.db").path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw XCTSkip("cannot open")
        }
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db)))
    }

    func expected(_ emails: [MBOXParser.RawEmail]) -> Set<String> {
        Set(emails.flatMap { e in SQLiteEmailStore.folderPaths(for: e).map { "\(e.id.uuidString)|\($0)" } })
    }

    // MARK: - B7

    /// Page size 1: every tag row is its own page, so each email's second
    /// folder sits across a boundary from its first.
    func testB7_rebuildFromTags_keepsEveryMembership_acrossPageBoundaries() async throws {
        let store = SQLiteEmailStore(directory: dir)
        let emails = try (0..<3).map { try email($0, folder: "Inbox", labels: ["Work", "Clients/Acme"]) }
        try await insert(store, emails)
        let want = expected(emails)
        XCTAssertEqual(want.count, 9)
        XCTAssertEqual(try memberships(), want, "the import writes every membership")

        SQLiteEmailStore.folderBackfillPageSize = 1
        try await store.rebuildFoldersFromTags()
        XCTAssertEqual(try memberships(), want, "a page boundary must not drop an email's later folders")
    }

    /// An archive the pre-fix v21 backfill damaged: (X, Inbox) present,
    /// (X, Work) missing, the tags intact. Opening it repairs the gap once,
    /// additively; a second pass finds nothing to add.
    func testB7_archiveDamagedByOldBackfill_isRepairedAtOpen_additivelyAndOnce() async throws {
        let store = SQLiteEmailStore(directory: dir)
        let emails = try (0..<4).map { try email($0, folder: "Inbox", labels: ["Work"]) }
        try await insert(store, emails)
        let want = expected(emails)
        await store.reopenConnection()

        // Reproduce the damage and the state of an archive opened only by
        // pre-fix builds (no repair recorded).
        try execute("DELETE FROM email_folders WHERE folder_id IN (SELECT folder_id FROM folders WHERE path = 'Work');")
        try? FileManager.default.removeItem(at: store.folderPairRepairMarker)
        XCTAssertEqual(try memberships().count, 4)
        let metaBefore = try metaRows()

        SQLiteEmailStore.folderBackfillPageSize = 1
        let total = try await store.totalCount()      // re-opens: migrateSchema → repair
        XCTAssertEqual(total, 4, "nothing removed")
        XCTAssertEqual(try memberships(), want, "every dropped membership is back from the tags")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.folderPairRepairMarker.path), "the repair is recorded")
        XCTAssertEqual(try metaRows(), metaBefore, "the open-time repair adds no row outside the memberships")

        let again = try await store.repairFolderMembershipsFromTags()
        XCTAssertEqual(again, 0, "idempotent")

        // Recorded: a later open does not scan again (the deleted row stays
        // deleted until the explicit repair or rebuild is asked for).
        await store.reopenConnection()
        try execute("DELETE FROM email_folders WHERE folder_id IN (SELECT folder_id FROM folders WHERE path = 'Work');")
        _ = try await store.totalCount()
        XCTAssertEqual(try memberships().count, 4, "the open-time repair runs once per archive")
        let added = try await store.repairFolderMembershipsFromTags()
        XCTAssertEqual(added, 4)
        XCTAssertEqual(try memberships(), want)
    }

    /// The per-pair rule writes nothing the import would not: Apple Mail flag
    /// tags stay tags, never folders.
    func testB7_perPairBackfill_neverTurnsEmlxFlagsIntoFolders() async throws {
        let store = SQLiteEmailStore(directory: dir)
        var e = try email(0, folder: "Inbox", labels: ["Work"])
        e.tags.append(contentsOf: ["Read", "Flagged"])
        e.flags = ["Read", "Flagged"]
        try await insert(store, [e])
        try execute("""
            INSERT INTO sources(sha256, filename, parser, imported_at) VALUES ('emlx-src', 'Mail', 'emlx', 0);
            UPDATE emails SET source_id = (SELECT source_id FROM sources WHERE sha256 = 'emlx-src');
        """)
        SQLiteEmailStore.folderBackfillPageSize = 1
        let added = try await store.repairFolderMembershipsFromTags()
        let paths = Set(try memberships().map { String($0.split(separator: "|")[1]) })
        XCTAssertFalse(paths.contains("Read") || paths.contains("Flagged"), "\(paths)")
        XCTAssertTrue(paths.isSuperset(of: ["Inbox", "Work"]))
        XCTAssertEqual(added, 0, "the import already wrote both folder memberships; flags are not folders")
    }
}

/// A counter the synchronous fault hook can update.
private final class LockedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add(_ k: Int) { lock.lock(); n += k; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
