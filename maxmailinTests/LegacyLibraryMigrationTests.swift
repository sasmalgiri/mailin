@testable import ArchiveCore
//
//  LegacyLibraryMigrationTests.swift
//  maxmailinTests
//
//  I-11 (owner decision 2026-09-27): synthetic stand-ins for the genuine v1
//  JSON library and the 2.x SQLite library that only the owner has. Both are
//  authored from the owner's REAL mailbox, then read / opened by the current
//  code and timed.
//
//  Stated plainly in the results: these prove the code against a library
//  SHAPED like v1 / 2.x, not against a customer's actual files. The 2.x row
//  in particular is a cold reopen of a current-schema store (the migration
//  chain itself is covered by `V2CutoverTests`); forcing an older
//  `user_version` onto a current file would replay ALTER TABLEs that already
//  ran, which is not what a real 2.x file does.
//

import XCTest
@testable import maxmailin

final class LegacyLibraryMigrationTests: XCTestCase {

    private static var fixture: URL? {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads/Mail/Sent.mbox")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func parseFixture(_ url: URL) async throws -> [MBOXParser.RawEmail] {
        var emails: [MBOXParser.RawEmail] = []
        _ = try await ParserFactory.parseStreamingCallback(fileURL: url, senderEmail: "", batchSize: 200) { emails.append(contentsOf: $0) }
        return emails
    }

    /// v1 JSON library → read → into the SQLite store, both timed.
    func testSyntheticV1JSONLibrary_loadsAndMigratesWithExactCount() async throws {
        guard let fixture = Self.fixture else { throw XCTSkip("~/Downloads/Mail/Sent.mbox not present") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("v1lib-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try MailinStorageEnvironment.assertNotProduction(root)

        let emails = try await parseFixture(fixture)
        XCTAssertGreaterThan(emails.count, 0)

        let storeURL = root.appendingPathComponent("saved_emails.json")
        try EmailPersistence.writeLegacyStoreForTesting(emails: emails, senderEmail: "owner@example.com", to: storeURL)
        XCTAssertTrue(EmailPersistence.legacyStoreExists(at: storeURL))
        let bytes = (try? FileManager.default.attributesOfItem(atPath: storeURL.path)[.size] as? NSNumber)?.int64Value ?? 0

        let clock = ContinuousClock()
        let loadStart = clock.now
        let loaded = EmailPersistence.load(from: storeURL)
        let loadSeconds = seconds(loadStart.duration(to: clock.now))
        XCTAssertEqual(loaded.emails.count, emails.count, "every v1 message must load")
        XCTAssertEqual(loaded.senderEmail, "owner@example.com")

        let store = SQLiteEmailStore(directory: root.appendingPathComponent("sqlite", isDirectory: true))
        let migrateStart = clock.now
        try await store.insertBatch(loaded.emails, batchSize: 200)
        let migrateSeconds = seconds(migrateStart.duration(to: clock.now))
        let stored = try await store.totalCount()
        print("V1-JSON-LIBRARY messages=\(emails.count) bytes=\(bytes) loadSeconds=\(String(format: "%.2f", loadSeconds)) migrateSeconds=\(String(format: "%.2f", migrateSeconds)) stored=\(stored)")
        XCTAssertEqual(stored, emails.count)
    }

    /// 2.x-shaped SQLite library: written by the current store, closed, and
    /// reopened cold by a fresh instance — the open path a customer's library
    /// takes at launch — timed and counted.
    func testSyntheticV2Library_coldReopenKeepsEveryRowAtCurrentSchema() async throws {
        guard let fixture = Self.fixture else { throw XCTSkip("~/Downloads/Mail/Sent.mbox not present") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("v2lib-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try MailinStorageEnvironment.assertNotProduction(root)

        let emails = try await parseFixture(fixture)
        let directory = root.appendingPathComponent("sqlite", isDirectory: true)
        do {
            let store = SQLiteEmailStore(directory: directory)
            try await store.insertBatch(emails, batchSize: 200)
            try await store.checkpoint()
        }
        let clock = ContinuousClock()
        let start = clock.now
        let reopened = SQLiteEmailStore(directory: directory)
        let count = try await reopened.totalCount()
        let version = try await reopened.userVersionForTesting()
        let open = seconds(start.duration(to: clock.now))
        print("V2-LIBRARY messages=\(emails.count) coldOpenSeconds=\(String(format: "%.3f", open)) schema=v\(version)")
        XCTAssertEqual(count, emails.count)
        XCTAssertGreaterThanOrEqual(version, 17)
    }

    private func seconds(_ d: Duration) -> Double {
        let c = d.components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}
