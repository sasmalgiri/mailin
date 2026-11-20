//
//  ListDateSpanTests.swift
//  ArchiveCoreTests
//
//  LIST-01 (owner report 2026-11-20): the date range next to "N Emails" said
//  "29 Jan 2002 – 29 Dec 2005" for 56,699 emails reaching back years — it was
//  the span of the loaded page window. The repository now answers the first
//  and last date of everything the query lists, as the store counts it.
//

import XCTest
@testable import ArchiveCore

final class ListDateSpanTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("datespan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testDateSpan_wholeArchive_dateFilter_andTextSearch_comeFromTheStoreNotTheWindow() async throws {
        // 600 messages from 1999 to late 2001, then 3 late ones in 2005.
        var text = ""
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let start = Date(timeIntervalSince1970: 915_148_800)   // 1 Jan 1999
        for i in 0..<600 {
            let date = start.addingTimeInterval(Double(i) * 86_400 * 1.8)
            let word = i % 2 == 0 ? "budgetword" : "otherword"
            text += "From a@example.com Mon Jan  1 00:00:00 1999\nMessage-ID: <s\(i)@example.com>\nFrom: a@example.com\nTo: b@example.com\nSubject: Span \(i)\nDate: \(formatter.string(from: date))\n\n\(word) \(i)\n\n"
        }
        for i in 0..<3 {
            text += "From a@example.com Mon Jan  1 00:00:00 2005\nMessage-ID: <late\(i)@example.com>\nFrom: a@example.com\nTo: b@example.com\nSubject: Late \(i)\nDate: Thu, \(27 + i) Dec 2005 10:00:00 +0000\n\nlate \(i)\n\n"
        }
        let mbox = root.appendingPathComponent("span.mbox")
        try Data(text.utf8).write(to: mbox)

        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts", isDirectory: true))
        let coordinator = await BulkImportCoordinator(store: store, fts: fts, checkpoints: ImportCheckpointStore(store: store),
                                                      requiresStorageActivation: false)
        var options = BulkImportCoordinator.Options()
        options.enforceStoragePreflight = false
        options.useOffsetEngine = true
        options.recordLocators = true
        _ = try await coordinator.runImport(urls: [mbox], options: options)

        let repository = EmailStoreRepository(store: store, fts: fts)
        let calendar: Calendar = {
            var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
        }()

        // The whole archive: first message 1999, last 29 Dec 2005.
        let all = try await repository.dateSpan(query: .all)
        XCTAssertEqual(all.first.map { calendar.component(.year, from: $0) }, 1999)
        XCTAssertEqual(all.last.map { calendar.dateComponents([.year, .month, .day], from: $0) },
                       DateComponents(year: 2005, month: 12, day: 29))

        // A date filter from 2001: the span starts inside the window, not at 1999.
        var from2002 = EmailQuery.all
        from2002.afterDate = calendar.date(from: DateComponents(year: 2001, month: 1, day: 1))
        let windowed = try await repository.dateSpan(query: from2002)
        XCTAssertEqual(windowed.first.map { calendar.component(.year, from: $0) }, 2001)
        XCTAssertEqual(windowed.last.map { calendar.component(.year, from: $0) }, 2005)
        let count2002 = try await repository.count(query: from2002)
        XCTAssertGreaterThan(count2002, 3)

        // A text search: the span of the matches only (the late mail does not match).
        let search = EmailQuery(text: "budgetword")
        let searched = try await repository.dateSpan(query: search)
        XCTAssertEqual(searched.first.map { calendar.component(.year, from: $0) }, 1999)
        XCTAssertNotNil(searched.last)
        XCTAssertLessThan(searched.last!, calendar.date(from: DateComponents(year: 2005, month: 1, day: 1))!,
                          "the 2005 messages do not contain the word, so the span ends before them")

        // Nothing listed: no span.
        let none = try await repository.dateSpan(query: EmailQuery(text: "nosuchwordanywhere"))
        XCTAssertNil(none.first)
        XCTAssertNil(none.last)
    }
}
