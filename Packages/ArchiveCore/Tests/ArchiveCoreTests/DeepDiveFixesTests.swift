//
//  DeepDiveFixesTests.swift
//  ArchiveCoreTests
//
//  Deep dive 2026-11-20 (owner: "deep dive and do an edge case and debug
//  run"). One test per archive-side fix:
//   DATE-01  undated / year-1 mail is undated everywhere (no fake PST date,
//            no year-1 bucket, no year-1 range, reads back undated);
//   DATE-03  a typed day is a day on this Mac's calendar;
//   EXP-01   HTML read by a person: no CSS, no script, entities decoded;
//   WIN-03   the attachment total is the whole list's.
//

import XCTest
import SQLite3
@testable import ArchiveCore

final class DeepDiveFixesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("deepdive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    // MARK: DATE-01

    func testPSTItemWithoutATime_hasNoDateHeader_andIsUndated() {
        var message = PSTReader.PSTMessage()
        message.subject = "No time"
        message.senderEmail = "a@example.com"
        let email = PSTParser.rawEmail(from: message, senderEmail: "", isoFormatter: ISO8601DateFormatter())
        XCTAssertNil(email.headers["Date"], "no year-1 Date header is invented")
        XCTAssertEqual(email.timestamp, MBOXParser.undatedTimestamp)
        XCTAssertNil(MBOXParser.effectiveDate(for: email))

        message.deliveryTime = Date(timeIntervalSince1970: 1_000_000_000)
        let dated = PSTParser.rawEmail(from: message, senderEmail: "", isoFormatter: ISO8601DateFormatter())
        XCTAssertNotNil(dated.headers["Date"])
        XCTAssertEqual(MBOXParser.effectiveDate(for: dated), Date(timeIntervalSince1970: 1_000_000_000))
    }

    func testYearOneHeader_isUndated_andStaysOutOfRangesBucketsAndReadBack() async throws {
        func mail(_ id: String, _ date: String) -> String {
            "From a@example.com Mon Jan  1 00:00:00 2001\nMessage-ID: <\(id)@example.com>\nFrom: a@example.com\nTo: b@example.com\nSubject: \(id)\nDate: \(date)\n\nbody \(id)\n\n"
        }
        let text = mail("real", "Mon, 1 Jan 2001 10:00:00 +0000") + mail("yearone", "Mon, 19 Dec 0001 10:00:00 +0000")
        let mbox = root.appendingPathComponent("dates.mbox")
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

        let range = try await store.dateRangeSeconds()
        XCTAssertEqual(range.min, 978_343_200, "the archive's first date is the real one, not year 1")
        let months = try await store.monthlyCounts().map(\.value)
        XCTAssertEqual(months, ["2001-01"], "no 0001 bucket")
        let ids = try await store.summaryPage(after: nil, before: nil, cursorDate: nil, cursorID: nil, limit: 10).map(\.id)
        let read = try await store.emails(withIDs: ids)
        let yearOne = try XCTUnwrap(read.first { $0.headers["Subject"] == "yearone" })
        XCTAssertEqual(yearOne.timestamp, MBOXParser.undatedTimestamp, "reads back undated, not as year 1")
        XCTAssertNil(MBOXParser.effectiveDate(for: yearOne))
    }

    // MARK: DATE-03

    func testTypedDay_isADayOnThisMacsCalendar() throws {
        let parsed = try XCTUnwrap(ArchiveQueryCompiler.parseDate("2024-03-05"))
        let local = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2024, month: 3, day: 5)))
        XCTAssertEqual(parsed, local, "local midnight, the zone the list shows dates in")
    }

    // MARK: EXP-01

    func testReadableText_dropsStyleAndScript_decodesEntities_keepsLines() {
        let html = """
        <html><head><title>T</title><style>p { color: red; }</style></head>
        <body><script>alert(1)</script><p>Hello&nbsp;Ann &amp; Bob &#39;team&#39; &lt;3</p><p>Line two<br>Line three</p>
        <!-- hidden --></body></html>
        """
        let text = HTMLReadableText.readable(html)
        XCTAssertFalse(text.contains("color"), "no CSS: \(text)")
        XCTAssertFalse(text.contains("alert"), "no script: \(text)")
        XCTAssertFalse(text.contains("hidden"), "no comments: \(text)")
        XCTAssertTrue(text.contains("Hello Ann & Bob 'team' <3"), text)
        XCTAssertTrue(text.contains("Line two\nLine three"), text)
    }

    // MARK: WIN-03

    func testAttachmentTotal_isTheWholeLists() async throws {
        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store2", isDirectory: true))
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts2", isDirectory: true))
        var emails: [MBOXParser.RawEmail] = []
        for i in 0..<120 {
            let attachments = (0..<(i % 3)).map { AttachmentMetadata(filename: "f\(i)-\($0).txt", mimeType: "text/plain", size: 10, base64: "aGVsbG8=") }
            emails.append(MBOXParser.RawEmail(headers: ["Message-ID": "<a\(i)@x>", "From": "a@x.com", "To": "b@x.com",
                                                        "Subject": "S \(i)", "Date": "Mon, 6 Jan 2025 10:00:00 +0000"],
                                              rawSource: "", messageType: "received", attachments: attachments,
                                              timestamp: "2025-01-06T10:00:00Z", domains: ["x.com"], plainBody: "word\(i % 2 == 0 ? " even" : "")", htmlBody: ""))
        }
        try await store.insertBatch(emails, batchSize: 200)
        try await fts.indexBatch(emails)
        let repository = EmailStoreRepository(store: store, fts: fts)
        let expected = (0..<120).reduce(0) { $0 + $1 % 3 }
        let all = try await repository.attachmentTotal(query: .all)
        XCTAssertEqual(all, expected, "every listed email's attachments, not a window's")
        let even = try await repository.attachmentTotal(query: EmailQuery(text: "even"))
        XCTAssertEqual(even, (0..<120).filter { $0 % 2 == 0 }.reduce(0) { $0 + $1 % 3 }, "a search counts its matches only")
    }

    // MARK: WORD-01

    /// The search box with "Whole words" on: a word matches only as a whole
    /// word; off (the default), the last word matches the start of a word
    /// (as typed so far) — never the inside of one.
    func testWholeWords_option_matchesWholeWordsOnly_defaultStaysAsTyped() async throws {
        let wasOn = SearchChunkPolicy.isEnabled
        defer { SearchChunkPolicy.isEnabled = wasOn }
        SearchChunkPolicy.isEnabled = true
        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store3", isDirectory: true))
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts3", isDirectory: true))
        let bodies = ["the oil price", "water will boil", "the merger closed", "two mergers", "Jeff Skilling spoke", "new skills"]
        let emails = bodies.enumerated().map { i, body in
            MBOXParser.RawEmail(headers: ["Message-ID": "<w\(i)@x>", "From": "a@x.com", "To": "b@x.com",
                                          "Subject": "Note \(i)", "Date": "Mon, 6 Jan 2025 10:00:00 +0000"],
                                rawSource: "", messageType: "received", attachments: [],
                                timestamp: "2025-01-06T10:00:00Z", domains: ["x.com"], plainBody: body, htmlBody: "")
        }
        try await store.insertBatch(emails, batchSize: 100)
        try await fts.indexBatch(emails)
        let repository = EmailStoreRepository(store: store, fts: fts)
        func count(_ text: String, whole: Bool) async throws -> Int {
            let q = ArchiveBrowseState(searchText: text, wholeWords: whole).query(plainTextOnModel: true)
            XCTAssertNil(q.text, "the typed words run on the search model")
            return try await repository.count(query: q)
        }
        let oilAsTyped = try await count("oil", whole: false)
        XCTAssertEqual(oilAsTyped, 1, "never inside a word: boil does not match")
        let mergerAsTyped = try await count("merger", whole: false)
        let mergerWhole = try await count("merger", whole: true)
        XCTAssertEqual(mergerAsTyped, 2, "default: the start of a word, so mergers matches")
        XCTAssertEqual(mergerWhole, 1, "whole words: not mergers")
        let skillAsTyped = try await count("skill", whole: false)
        let skillWhole = try await count("skill", whole: true)
        XCTAssertEqual(skillAsTyped, 2, "default: Skilling and skills")
        XCTAssertEqual(skillWhole, 0, "whole words: neither")
        let skillingWhole = try await count("skilling", whole: true)
        XCTAssertEqual(skillingWhole, 1)
        let twoWords = try await count("the merger", whole: true)
        XCTAssertEqual(twoWords, 1)
        let phrase = try await count("\"two mergers\"", whole: true)
        XCTAssertEqual(phrase, 1, "a quoted phrase is the exact text")
    }
}
