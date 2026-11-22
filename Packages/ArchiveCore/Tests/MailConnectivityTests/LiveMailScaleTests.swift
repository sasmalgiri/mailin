//
//  LiveMailScaleTests.swift
//  LIVE-SCALE-01 (owner 2026-11-22): "make sure it can handle large volume of
//  live mail with current archive load". A live account with many messages is
//  synced into an archive that already holds an imported load, then every call
//  the Live Mail page makes (the 2 s status refresh, the folder list, the
//  inbox page and its total, Show more, a re-sync) is timed and checked.
//
//  Sizes: MAILIN_LIVE_SCALE_IMPORTED (default 20,000) and
//  MAILIN_LIVE_SCALE_MESSAGES (default 20,000); the owner-sized run uses
//  200,000 / 100,000. Times are printed as "[live-scale]" lines.
//

import XCTest
import Foundation
@testable import MailConnectivity
@testable import ArchiveCore

final class LiveMailScaleTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("live-scale-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private static func size(_ name: String, _ fallback: Int) -> Int {
        ProcessInfo.processInfo.environment[name].flatMap(Int.init) ?? fallback
    }

    private func time<T>(_ label: String, _ body: () async throws -> T) async rethrows -> (T, TimeInterval) {
        let start = Date()
        let value = try await body()
        let seconds = Date().timeIntervalSince(start)
        print("[live-scale] \(label): \(String(format: "%.3f", seconds)) s")
        return (value, seconds)
    }

    /// The archive's imported load: plain messages from a file import.
    private func importLoad(_ store: SQLiteEmailStore, count: Int) async throws {
        var batch: [MBOXParser.RawEmail] = []
        batch.reserveCapacity(2_000)
        for i in 0..<count {
            let day = 1 + i % 28, month = 1 + (i / 28) % 12, year = 2010 + i % 15
            batch.append(MBOXParser.RawEmail(
                headers: ["Message-ID": "<imported-\(i)@archive.example>", "From": "sender\(i % 500)@archive.example",
                          "To": "owner@archive.example", "Subject": "Imported message \(i)",
                          "Date": "Mon, \(day) Jan \(year) 10:00:00 +0000"],
                rawSource: "", messageType: "received", attachments: [],
                timestamp: String(format: "%04d-%02d-%02dT10:00:00Z", year, month, day),
                domains: ["archive.example"], plainBody: "Body of imported message \(i)", htmlBody: ""))
            if batch.count == 2_000 { try await store.insertBatch(batch, batchSize: 2_000); batch.removeAll(keepingCapacity: true) }
        }
        if !batch.isEmpty { try await store.insertBatch(batch, batchSize: 2_000) }
    }

    func testLargeLiveAccount_onAnArchiveWithAnImportedLoad_everyPageCallStaysFast() async throws {
        let importedCount = Self.size("MAILIN_LIVE_SCALE_IMPORTED", 20_000)
        let liveCount = Self.size("MAILIN_LIVE_SCALE_MESSAGES", 20_000)
        let folders = 20
        let sink = ConnectedArchiveSink(storeDirectory: dir.appendingPathComponent("archive", isDirectory: true))

        _ = try await time("import \(importedCount) archive messages") { try await importLoad(sink.store, count: importedCount) }

        let fake = FakeMailProvider(pageSize: 500)
        for f in 0..<folders { await fake.addFolder("f\(f)", path: "Folder \(f)") }
        for i in 0..<liveCount {
            let f = i % folders
            // Every tenth message also has a second label (Gmail-style).
            await fake.seed("m\(i)", folders: i % 10 == 0 ? ["f\(f)", "f\((f + 1) % folders)"] : ["f\(f)"])
        }
        try await sink.saveAccount(ConnectedAccountRecord(
            accountID: fake.accountID, provider: .gmail, issuer: "https://accounts.google.com",
            displayIdentity: "big@example.com", enabledModes: ["capture"], connectionState: "connected",
            createdAt: Date(), updatedAt: Date()))
        let engine = SyncEngine(adapter: fake, sink: sink, scheduler: FairDownloadScheduler(totalSlots: 4), tokens: nil,
                                permission: { _ in },
                                backoff: BackoffPolicy(base: 1, maximum: 1, transientAttempts: 2, maximumThrottleWait: 1,
                                                       jitter: { 0 }, sleep: { _ in await Task.yield() }),
                                storage: StorageProbe(reserveBytes: 1_024, availableBytes: { _ in 1 << 40 }))

        let (first, firstSeconds) = await time("first sync of \(liveCount) live messages") { await engine.sync() }
        XCTAssertEqual(first.outcome, .completed)
        XCTAssertEqual(first.receipt?.stored, liveCount, "every live message is preserved")
        let total = try await sink.store.totalCount()
        XCTAssertEqual(total, importedCount + liveCount, "the imported load is untouched")
        print("[live-scale] first sync rate: \(Int(Double(liveCount) / max(firstSeconds, 0.001))) messages/s")

        // What the page asks every 2 s while a sync runs.
        let (status, statusSeconds) = try await time("account status (2 s refresh)") { try await engine.status() }
        XCTAssertTrue(status.acquisitionComplete)
        let (folderList, folderSeconds) = try await time("folder list with counts") { try await sink.folderSummaries(accountID: fake.accountID) }
        XCTAssertEqual(folderList.map(\.messages).reduce(0, +), liveCount + liveCount / 10, "each label counts its messages")

        // The unified inbox: first page, its total, Show more, a filter.
        let (page, pageSeconds) = try await time("unified inbox first page") { try await sink.mailboxPage(ConnectedMailboxQuery()) }
        XCTAssertEqual(page.total, liveCount, "the total counts every live message once")
        XCTAssertEqual(page.rows.count, 200)
        let (more, moreSeconds) = try await time("Show more (second page)") { try await sink.mailboxPage(ConnectedMailboxQuery(), after: page.next) }
        XCTAssertEqual(more.rows.count, 200)
        XCTAssertTrue(Set(page.rows.map(\.emailID)).isDisjoint(with: more.rows.map(\.emailID)), "pages never repeat")
        let (folderPage, folderPageSeconds) = try await time("one folder's first page") {
            try await sink.mailboxPage(ConnectedMailboxQuery(accountIDs: [fake.accountID], folderServerID: "f3"))
        }
        XCTAssertEqual(folderPage.total, folderList.first { $0.serverID == "f3" }?.messages)
        let (_, unreadSeconds) = try await time("unread-only filter") { try await sink.mailboxPage(ConnectedMailboxQuery(unreadOnly: true)) }
        let (_, textSeconds) = try await time("quick filter text") { try await sink.mailboxPage(ConnectedMailboxQuery(text: "m1234")) }

        // A re-sync with a handful of arrivals: the already-saved messages are only confirmed.
        for i in 0..<25 { await fake.apply(.add("new\(i)", folder: "f0")) }
        let (second, secondSeconds) = await time("re-sync with 25 arrivals") { await engine.sync() }
        XCTAssertEqual(second.outcome, .completed)
        XCTAssertEqual(second.receipt?.stored, 25, "only the arrivals are new")
        let after = try await sink.mailboxPage(ConnectedMailboxQuery())
        XCTAssertEqual(after.total, liveCount + 25)

        // Bounds at the default size (seconds; generous for a debug build on a busy Mac).
        // The owner-sized run reads the printed figures instead.
        if liveCount <= 20_000 && importedCount <= 20_000 {
            XCTAssertLessThan(statusSeconds, 1.0, "the 2 s status refresh must finish well inside 2 s")
            XCTAssertLessThan(folderSeconds, 1.0)
            XCTAssertLessThan(pageSeconds, 1.0)
            XCTAssertLessThan(moreSeconds, 1.0)
            XCTAssertLessThan(folderPageSeconds, 1.0)
            XCTAssertLessThan(unreadSeconds, 1.5)
            XCTAssertLessThan(textSeconds, 1.5)
            XCTAssertLessThan(secondSeconds, 30)
        }
    }
}
