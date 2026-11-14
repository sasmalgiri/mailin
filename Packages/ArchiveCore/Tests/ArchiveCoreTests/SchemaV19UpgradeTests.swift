//
//  SchemaV19UpgradeTests.swift
//  ArchiveCoreTests
//
//  3.0 A5: a real schema-v19 archive (Fixtures/v19-1k, written by the 3.0
//  build before v20, commit 3e4b9cb^: 1,000 emails, legal holds and seals,
//  tags, review flags, notes, fingerprints, features) is opened by this
//  build. A snapshot is taken first (rule 2), v20 is added, every existing
//  row is kept (rule 1), the recovery engine switched off still reads it
//  (rule 16), and with recovery on a new mailbox imports into it.
//

import XCTest
import Foundation
import SQLite3
@testable import ArchiveCore

final class SchemaV19UpgradeTests: XCTestCase {
    private var dir: URL!
    private var saved: (snapshots: Bool, recovery: Bool)!

    override func setUpWithError() throws {
        saved = (ArchiveSnapshotPolicy.isEnabled, RecoveryPolicy.isEnabled)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("V3Scale-v19-\(UUID().uuidString)", isDirectory: true)
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/v19-1k")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("emails.db"), to: dir.appendingPathComponent("emails.db"))
    }

    override func tearDown() {
        ArchiveSnapshotPolicy.isEnabled = saved.snapshots
        RecoveryPolicy.isEnabled = saved.recovery
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func manifest() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/v19-1k/manifest.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    /// Row count of every table, read directly (no store involved).
    private func tableCounts(_ path: String) throws -> (version: Int, counts: [String: Int]) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw XCTSkip("cannot open") }
        defer { sqlite3_close(db) }
        func rows(_ sql: String) -> [[String]] {
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            defer { sqlite3_finalize(stmt) }
            var out: [[String]] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append((0..<sqlite3_column_count(stmt)).map { String(cString: sqlite3_column_text(stmt, $0)) })
            }
            return out
        }
        let version = Int(rows("PRAGMA user_version;").first?.first ?? "0") ?? 0
        var counts: [String: Int] = [:]
        // Plain tables only: FTS shadow tables are rebuilt by their own module.
        for t in rows("SELECT name FROM sqlite_master WHERE type='table' AND sql NOT LIKE 'CREATE VIRTUAL%' ORDER BY name;").map({ $0[0] }) {
            counts[t] = Int(rows("SELECT COUNT(*) FROM \"\(t)\";").first?.first ?? "-1") ?? -1
        }
        return (version, counts)
    }

    func testRealV19Archive_upgradesWithSnapshot_keepsEveryRow_andReadsWithRecoveryOffOrOn() async throws {
        let m = try manifest()
        let path = dir.appendingPathComponent("emails.db").path
        let before = try tableCounts(path)
        XCTAssertEqual(before.version, 19, "the fixture is a real v19 archive")
        XCTAssertEqual(before.counts["emails"], 1_000)
        XCTAssertNil(before.counts["email_recovery"], "v20 tables are not there yet")

        // Open in this build with the 3.0 rollback position: recovery off.
        ArchiveSnapshotPolicy.isEnabled = true
        RecoveryPolicy.isEnabled = false
        let store = SQLiteEmailStore(directory: dir)
        let total = try await store.count(after: nil, before: nil)
        XCTAssertEqual(total, 1_000)

        // Rule 2: the snapshot was taken before the upgrade, and it is the v19 file.
        let snapshots = store.snapshots()
        let upgrade = try XCTUnwrap(snapshots.first { $0.reason == "before upgrade" }, "\(snapshots.map(\.reason))")
        XCTAssertNil(ArchiveSnapshotPolicy.upgradeSnapshotFailure)
        let snapDB = upgrade.url.hasDirectoryPath ? upgrade.url.appendingPathComponent("emails.db") : upgrade.url
        let snap = try tableCounts(snapDB.path)
        XCTAssertEqual(snap.version, 19, "the snapshot is the archive as it was")
        XCTAssertEqual(snap.counts, before.counts, "the snapshot holds every row")

        // v20 added; every row that existed is still there (additive upgrade).
        await store.reopenConnection()
        let after = try tableCounts(path)
        XCTAssertEqual(after.version, SQLiteEmailStore.currentSchemaVersion)
        for t in ["email_recovery", "email_custom_values", "script_runs"] { XCTAssertNotNil(after.counts[t], "v20 table \(t)") }
        for (table, n) in before.counts { XCTAssertEqual(after.counts[table], n, "rows in \(table)") }

        // The legal and review data reads back as v19 wrote it.
        let held = try await store.legalHoldCount()
        XCTAssertEqual(held, m["held"] as? Int)
        let tags = Dictionary(uniqueKeysWithValues: try await store.userTagCounts().map { ($0.tag, $0.count) })
        XCTAssertEqual(tags["Responsive"], m["tagResponsive"] as? Int)
        XCTAssertEqual(tags["Hot \"doc\""], m["tagHot"] as? Int)
        let pinned = try await store.reviewCount(of: .pinned)
        XCTAssertEqual(pinned, m["pinned"] as? Int)
        let read = try await store.reviewCount(of: .isRead)
        XCTAssertEqual(read, m["read"] as? Int)
        let privileged = try await store.featurePrivilegedCount()
        XCTAssertEqual(privileged, m["privileged"] as? Int)
        let tree = try await store.fingerprintTree()
        XCTAssertEqual(tree.root, m["fingerprintRoot"] as? String, "every email's fingerprint is unchanged")
        let recoveryOff = try await store.recoveryCounts()
        XCTAssertEqual(recoveryOff.recovered, 0, "nothing is marked recovered by the upgrade")

        // Recovery on: a new mailbox imports into the upgraded archive.
        RecoveryPolicy.isEnabled = true
        let mbox = (0..<50).map { i in
            "From x@example.com Mon Jan  6 10:00:00 2025\nMessage-ID: <after-\(i)@test>\nSubject: After upgrade \(i)\n"
            + "From: x@example.com\nDate: Mon, 6 Jan 2025 10:\(String(format: "%02d", i)):00 +0000\n"
            + (i < 10 ? "X-Status: D\n" : "") + "\nBody \(i)\n\n"
        }.joined()
        let emails = try mbox.components(separatedBy: "From x@example.com Mon Jan  6 10:00:00 2025\n").filter { !$0.isEmpty }
            .map { try MBOXParser.processRawMessage($0, senderEmail: "") }
        XCTAssertEqual(emails.count, 50)
        _ = try await store.insertBatch(emails, sourceFileHash: nil, accountID: nil, sourceID: nil, firstOrdinal: nil,
                                        dedupPolicy: .messageID, batchSize: 50, progress: nil)
        let grown = try await store.count(after: nil, before: nil)
        XCTAssertEqual(grown, 1_050)
        let recoveryOn = try await store.recoveryCounts()
        XCTAssertEqual(recoveryOn[.flaggedDeleted], 10, "deleted-flag mail is marked in the upgraded archive")
        let heldAfter = try await store.legalHoldCount()
        XCTAssertEqual(heldAfter, m["held"] as? Int, "holds untouched by the import")
    }
}
