//
//  AccessScopeTests.swift
//  ArchiveCoreTests
//
//  The purchase tier's archive scope (owner, 2026-10-08): a Free user works
//  with the newest N emails of the archive, in every read — pages, counts,
//  filtered queries, text search and streams. One predicate in the store,
//  applied once by ArchiveDataService.
//

import XCTest
import Foundation
@testable import ArchiveCore

final class AccessScopeTests: XCTestCase {

    private func email(_ i: Int, from: String) -> MBOXParser.RawEmail {
        // i = 0 is the oldest; higher i is newer (one day apart in 2025).
        let date = Date(timeIntervalSince1970: 1_735_689_600 + Double(i) * 86_400)
        let fmt = DateFormatter(); fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return MBOXParser.RawEmail(
            headers: ["Message-ID": "<scope-\(i)@test>", "Subject": "Subject \(i) kiwi", "From": from, "To": "me@test",
                      "Date": fmt.string(from: date)],
            rawSource: "", messageType: "email", attachments: [], timestamp: "", domains: [],
            plainBody: "body \(i) kiwi", htmlBody: "")
    }

    @MainActor
    func testFreeScopeBoundsEveryRead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts", isDirectory: true))
        // 12 emails: even ones from ann@, odd ones from bob@.
        let emails = (0..<12).map { email($0, from: $0 % 2 == 0 ? "ann@test" : "bob@test") }
        try await store.insertBatch(emails, batchSize: 100)
        try await fts.indexBatch(emails)
        let archive = ArchiveDataService(repository: EmailStoreRepository(store: store, fts: fts))

        // Paid: the whole archive.
        let paidCount = try await archive.count(query: .all)
        XCTAssertEqual(paidCount, 12)

        // Free: the newest 5 (i = 7…11).
        archive.accessLimit = 5
        let freeCount = try await archive.count(query: .all)
        XCTAssertEqual(freeCount, 5)
        let page = try await archive.page(query: .all, limit: 100)
        XCTAssertEqual(page.summaries.map(\.subject), (7...11).reversed().map { "Subject \($0) kiwi" })

        // A filtered query stays inside the scope: bob@ sent 7, 9, 11.
        var bob = EmailQuery(); bob.sender = "bob@test"
        let bobCount = try await archive.count(query: bob)
        XCTAssertEqual(bobCount, 3)
        let bobSubjects = Set(try await archive.page(query: bob, limit: 100).summaries.map(\.subject))
        XCTAssertEqual(bobSubjects, ["Subject 7 kiwi", "Subject 9 kiwi", "Subject 11 kiwi"])

        // Text search ranks the whole index but returns only scoped hits.
        var text = EmailQuery(); text.text = "kiwi"
        let textCount = try await archive.count(query: text)
        XCTAssertEqual(textCount, 5)
        let ranked = try await archive.searchRanked(query: text, limit: 100).summaries.count
        XCTAssertEqual(ranked, 5)
        let textPage = try await archive.page(query: text, limit: 100).summaries.count
        XCTAssertEqual(textPage, 5)

        // Streams (analytics, AI, exports) see the same 5.
        var streamed = 0
        for try await batch in archive.streamFullEmails(query: .all, batchSize: 2) { streamed += batch.count }
        XCTAssertEqual(streamed, 5)

        // Candidate verification (AI retrieval) rejects out-of-scope ids.
        let all = try await archive.page(query: .all, limit: 100).summaries.map(\.id)
        archive.accessLimit = nil
        let everyID = try await archive.page(query: .all, limit: 100).summaries.map(\.id)
        archive.accessLimit = 5
        let allowed = try await archive.matchingIDs(among: everyID, query: .all)
        XCTAssertEqual(allowed, Set(all))
        XCTAssertEqual(allowed.count, 5)

        // Back to paid: everything again.
        archive.accessLimit = nil
        let again = try await archive.count(query: .all)
        XCTAssertEqual(again, 12)
        // The unscoped total the Free banners show ("First 500 of 526").
        archive.accessLimit = 5
        let unscoped = try await archive.unscopedCount(query: .all)
        XCTAssertEqual(unscoped, 12)
    }
}
