//
//  RealCorpusDebugRunTests.swift
//  ArchiveCoreTests
//
//  Debug run on real mail (owner 2026-11-20: "deep dive and do an edge case
//  and debug run"). Imports a real mbox (default: the 50 MB Enron file) with
//  the normal import and with the fast import, then checks every figure the
//  app shows against an oracle read straight from the file, not from the
//  importer:
//    • messages and duplicates (distinct Message-IDs);
//    • fast = normal, the same visible messages;
//    • the list's date range and the month buckets;
//    • search: every stored message that contains a word is found;
//    • the attachment total;
//    • a second import of the same file adds nothing;
//    • MBOX export round trip: same messages out as in;
//    • delete leaves nothing.
//  Opt-in: MAILIN_DEBUGRUN=1 (MAILIN_DEBUGRUN_FILE to choose the file).
//

import XCTest
@testable import ArchiveCore

final class RealCorpusDebugRunTests: XCTestCase {

    private static var fixture: URL? {
        let env = ProcessInfo.processInfo.environment
        if let explicit = env["MAILIN_DEBUGRUN_FILE"], !explicit.isEmpty { return URL(fileURLWithPath: explicit) }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/Mail/Fixtures/real-corpus-enron/enron-50mb.mbox")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: Oracle — read from the file, independent of the importer

    struct OracleMessage {
        let messageID: String?
        let date: Date?
    }

    /// Splits an mbox at "From " lines that start a message (file start or
    /// after a blank line) and reads Message-ID and Date from each header.
    static func oracle(_ url: URL) throws -> [OracleMessage] {
        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        var messages: [OracleMessage] = []
        var headers: [String: String] = [:]
        var lastKey: String?
        var inHeaders = false
        var previousBlank = true
        var started = false
        func finish() {
            guard started else { return }
            let id = headers["message-id"]?.trimmingCharacters(in: .whitespaces).lowercased()
            messages.append(OracleMessage(messageID: (id?.isEmpty ?? true) ? nil : id, date: headers["date"].flatMap(parseDate)))
        }
        text.enumerateLines { line, _ in
            if previousBlank && line.hasPrefix("From ") {
                finish()
                headers = [:]; lastKey = nil; inHeaders = true; started = true
                previousBlank = false
                return
            }
            if inHeaders {
                if line.isEmpty { inHeaders = false }
                else if line.first == " " || line.first == "\t" {
                    if let k = lastKey { headers[k, default: ""] += " " + line.trimmingCharacters(in: .whitespaces) }
                } else if let colon = line.firstIndex(of: ":") {
                    let key = line[..<colon].lowercased()
                    if headers[key] == nil {
                        headers[key] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    }
                    lastKey = key
                }
            }
            previousBlank = line.isEmpty
        }
        finish()
        return messages
    }

    static func parseDate(_ raw: String) -> Date? {
        var s = raw
        if let paren = s.firstIndex(of: "(") { s = String(s[..<paren]) }
        s = s.trimmingCharacters(in: .whitespaces)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        for pattern in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z", "EEE, d MMM yyyy HH:mm:ss zzz"] {
            f.dateFormat = pattern
            if let d = f.date(from: s) {
                let year = Calendar(identifier: .gregorian).component(.year, from: d)
                return year >= 1900 ? d : nil
            }
        }
        return nil
    }

    // MARK: Helpers

    private struct Archive {
        let store: SQLiteEmailStore
        let fts: FTSSearchIndex
        let repository: EmailStoreRepository
        let coordinator: BulkImportCoordinator
    }

    private func makeArchive(_ root: URL) async -> Archive {
        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts", isDirectory: true))
        let coordinator = await BulkImportCoordinator(store: store, fts: fts, checkpoints: ImportCheckpointStore(store: store),
                                                      requiresStorageActivation: false)
        return Archive(store: store, fts: fts, repository: EmailStoreRepository(store: store, fts: fts), coordinator: coordinator)
    }

    private func options(fast: Bool) -> BulkImportCoordinator.Options {
        var options = BulkImportCoordinator.Options()
        options.enforceStoragePreflight = false
        options.useOffsetEngine = true
        options.recordLocators = true
        options.overlapBatches = true
        options.fastImport = fast
        return options
    }

    /// Every visible email, page by page (bounded).
    private func everyEmail(_ repository: EmailStoreRepository, _ body: ([MBOXParser.RawEmail]) throws -> Void) async throws {
        var cursor: EmailPageCursor?
        repeat {
            let page = try await repository.page(query: .all, cursor: cursor, limit: 1_000)
            try body(try await repository.fullEmails(ids: page.summaries.map(\.id)))
            cursor = page.nextCursor
        } while cursor != nil
    }

    private func searchIDs(_ repository: EmailStoreRepository, _ word: String) async throws -> Set<UUID> {
        var ids = Set<UUID>()
        var cursor: RankedSearchCursor?
        repeat {
            let page = try await repository.searchRanked(query: EmailQuery(text: word), cursor: cursor, limit: 1_000)
            ids.formUnion(page.summaries.map(\.id))
            cursor = page.nextCursor
        } while cursor != nil
        return ids
    }

    static func containsWord(_ text: String, _ word: String) -> Bool {
        var searchRange = text.startIndex..<text.endIndex
        while let r = text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange) {
            let before = r.lowerBound == text.startIndex ? nil : text[text.index(before: r.lowerBound)]
            let after = r.upperBound == text.endIndex ? nil : text[r.upperBound]
            if !(before?.isLetter ?? false || before?.isNumber ?? false) && !(after?.isLetter ?? false || after?.isNumber ?? false) { return true }
            searchRange = r.upperBound..<text.endIndex
        }
        return false
    }

    // MARK: The run

    func testRealMailbox_everyFigureMatchesTheFile() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MAILIN_DEBUGRUN"] == "1", "opt-in: MAILIN_DEBUGRUN=1")
        let file = try XCTUnwrap(Self.fixture, "no real mbox found")
        let root = URL(fileURLWithPath: "/tmp/mailin-debugrun-\(UUID().uuidString).noindex", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Oracle
        let oracle = try Self.oracle(file)
        let withID = oracle.compactMap(\.messageID)
        let distinctIDs = Set(withID)
        let withoutID = oracle.count - withID.count
        let expectedVisible = distinctIDs.count + withoutID
        let datedFirstOccurrence: [Date] = {
            var seen = Set<String>(); var dates: [Date] = []
            for m in oracle {
                if let id = m.messageID { guard seen.insert(id).inserted else { continue } }
                if let d = m.date { dates.append(d) }
            }
            return dates
        }()
        print("DEBUGRUN oracle file=\(file.lastPathComponent) messages=\(oracle.count) distinct_ids=\(distinctIDs.count) without_id=\(withoutID) expected_visible=\(expectedVisible) oracle_dated=\(datedFirstOccurrence.count)")

        // 1. Normal and fast import
        let normal = await makeArchive(root.appendingPathComponent("normal", isDirectory: true))
        let fast = await makeArchive(root.appendingPathComponent("fast", isDirectory: true))
        let normalSummary = try await normal.coordinator.runImport(urls: [file], options: options(fast: false))
        let fastSummary = try await fast.coordinator.runImport(urls: [file], options: options(fast: true))
        let normalCount = try await normal.repository.count(query: .all)
        let fastCount = try await fast.repository.count(query: .all)
        print("DEBUGRUN import normal parsed=\(normalSummary.parsed) duplicates=\(normalSummary.duplicates ?? 0) damaged=\(normalSummary.damaged) visible=\(normalCount); fast parsed=\(fastSummary.parsed) duplicates=\(fastSummary.duplicates ?? 0) damaged=\(fastSummary.damaged) visible=\(fastCount)")
        XCTAssertEqual(normalSummary.parsed, oracle.count, "every message in the file is read")
        XCTAssertEqual(normalCount, expectedVisible, "visible = distinct Message-IDs + messages without one")
        XCTAssertEqual(fastCount, normalCount, "fast import shows the same number")
        XCTAssertEqual(normalSummary.duplicates ?? 0, oracle.count - expectedVisible, "duplicates reported = repeats in the file")

        // Same visible messages, and collect everything else from the normal archive.
        var normalKeys = Set<String>(), fastKeys = Set<String>()
        var attachmentSum = 0
        var storedUndated = 0
        var storedDates: [Date] = []
        let words = ["skilling", "dabhol", "california", "pipeline", "fastow", "merger"]
        var oracleHits: [String: Set<UUID>] = [:]
        var headerHits: [String: Set<UUID>] = [:]
        var dateCounts: [String: Int] = [:]
        try await everyEmail(normal.repository) { emails in
            for e in emails {
                normalKeys.insert(e.headers["Message-ID"]?.lowercased() ?? "subject:\(e.headers["Subject"] ?? "")|\(e.timestamp)")
                attachmentSum += e.attachments.count
                if let d = MBOXParser.effectiveDate(for: e) { storedDates.append(d) } else { storedUndated += 1 }
                let haystack = (e.headers["Subject"] ?? "") + "\n" + e.plainBody + "\n" + HTMLReadableText.readable(e.htmlBody)
                for w in words where Self.containsWord(haystack, w) { oracleHits[w, default: []].insert(e.id) }
                let headerText = e.headers.values.joined(separator: "\n") + "\n" + e.attachments.map(\.filename).joined(separator: "\n")
                for w in words where headerText.range(of: w, options: .caseInsensitive) != nil { headerHits[w, default: []].insert(e.id) }
                if let d = MBOXParser.effectiveDate(for: e) { dateCounts[ISO8601DateFormatter().string(from: d), default: 0] += 1 }
            }
        }
        try await everyEmail(fast.repository) { emails in
            for e in emails { fastKeys.insert(e.headers["Message-ID"]?.lowercased() ?? "subject:\(e.headers["Subject"] ?? "")|\(e.timestamp)") }
        }
        XCTAssertEqual(normalKeys.symmetricDifference(fastKeys).count, 0,
                       "fast and normal keep the same messages; differ: \(normalKeys.symmetricDifference(fastKeys).prefix(5))")

        // 2. Date range and month buckets
        let span = try await normal.repository.dateSpan(query: .all)
        let oracleFirst = datedFirstOccurrence.min(), oracleLast = datedFirstOccurrence.max()
        print("DEBUGRUN dates list_first=\(span.first.map { "\($0)" } ?? "nil") list_last=\(span.last.map { "\($0)" } ?? "nil") oracle_first=\(oracleFirst.map { "\($0)" } ?? "nil") oracle_last=\(oracleLast.map { "\($0)" } ?? "nil") stored_undated=\(storedUndated) oracle_undated=\(expectedVisible - datedFirstOccurrence.count)")
        XCTAssertEqual(span.first, storedDates.min(), "the list's first date is the earliest stored date")
        XCTAssertEqual(span.last, storedDates.max(), "the list's last date is the latest stored date")
        if let first = span.first, let oracleFirst { XCTAssertEqual(first.timeIntervalSince1970, oracleFirst.timeIntervalSince1970, accuracy: 1) }
        if let last = span.last, let oracleLast { XCTAssertEqual(last.timeIntervalSince1970, oracleLast.timeIntervalSince1970, accuracy: 1) }
        let repeated = dateCounts.filter { $0.value >= 20 }.sorted { $0.value > $1.value }.prefix(5)
        print("DEBUGRUN most_repeated_timestamps=\(repeated.map { "\($0.key)×\($0.value)" })")
        let months = try await normal.store.monthlyCounts()
        let monthSum = months.reduce(0) { $0 + $1.count }
        print("DEBUGRUN months buckets=\(months.count) sum=\(monthSum) first=\(months.first?.value ?? "-") last=\(months.last?.value ?? "-")")
        XCTAssertEqual(monthSum + storedUndated, normalCount, "month buckets + undated = every message")
        XCTAssertFalse(months.contains { ($0.value.prefix(4)).compare("1900") == .orderedAscending }, "no bucket before 1900")

        // 3. Search: nothing that contains the word is missed
        for w in words {
            let found = try await searchIDs(normal.repository, w)
            let counted = try await normal.repository.count(query: EmailQuery(text: w))
            let expected = oracleHits[w] ?? []
            let missed = expected.subtracting(found)
            print("DEBUGRUN search word=\(w) oracle=\(expected.count) found=\(found.count) count=\(counted) missed=\(missed.count) extra=\(found.subtracting(expected).count)")
            XCTAssertTrue(missed.isEmpty, "search for \(w) missed \(missed.count) messages that contain it")
            let unexplained = found.subtracting(expected).subtracting(headerHits[w] ?? [])
            if !unexplained.isEmpty {
                // Which forms of the word do they contain? (the index stems: porter)
                let sample = try await normal.repository.fullEmails(ids: Array(unexplained))
                var forms: [String: Int] = [:]
                let stemPrefix = String(w.prefix(max(4, w.count - 3))).lowercased()
                for e in sample {
                    let text = ((e.headers["Subject"] ?? "") + " " + e.plainBody + " " + HTMLReadableText.readable(e.htmlBody)).lowercased()
                    let tokens = Set(text.split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.hasPrefix(stemPrefix) })
                    for t in tokens { forms[t, default: 0] += 1 }
                    if tokens.isEmpty { forms["<none>", default: 0] += 1 }
                }
                print("DEBUGRUN search_extra word=\(w) unexplained=\(unexplained.count) forms=\(forms.sorted { $0.value > $1.value }.prefix(8))")
                // The index stems (porter): an extra result must hold another form of the word.
                XCTAssertNil(forms["<none>"], "\(forms["<none>"] ?? 0) results for \(w) hold no form of it")
            }
            XCTAssertEqual(counted, found.count, "the count shown for \(w) is the number of results")
        }

        // 4. Attachment total
        let attachmentTotal = try await normal.repository.attachmentTotal(query: .all)
        print("DEBUGRUN attachments total=\(attachmentTotal ?? -1) oracle=\(attachmentSum)")
        XCTAssertEqual(attachmentTotal, attachmentSum)

        // 5. Same file again: nothing new
        let again = try await normal.coordinator.runImport(urls: [file], options: options(fast: false))
        let afterAgain = try await normal.repository.count(query: .all)
        let fastAgain = try await fast.coordinator.runImport(urls: [file], options: options(fast: true))
        let fastAfterAgain = try await fast.repository.count(query: .all)
        print("DEBUGRUN reimport normal parsed=\(again.parsed) duplicates=\(again.duplicates ?? 0) visible=\(afterAgain); fast parsed=\(fastAgain.parsed) duplicates=\(fastAgain.duplicates ?? 0) visible=\(fastAfterAgain)")
        XCTAssertEqual(afterAgain, normalCount, "a second import of the same file adds nothing")
        XCTAssertEqual(fastAfterAgain, fastCount, "a second fast import of the same file adds nothing")

        // 6. MBOX export round trip
        let archive = ArchiveDataService(repository: normal.repository)
        let service = await ArchiveExportService(archive: archive)
        let out = root.appendingPathComponent("export.mbox")
        let result = try await service.exportMBOXArchive(scope: .query(.all, exclusions: []), to: out)
        let reread = try Self.oracle(out)
        let rereadIDs = Set(reread.compactMap(\.messageID))
        print("DEBUGRUN export written=\(result.recordsWritten) reread=\(reread.count) reread_distinct_ids=\(rereadIDs.count)")
        XCTAssertEqual(reread.count, normalCount, "the exported file holds every message")
        XCTAssertEqual(rereadIDs, distinctIDs, "with the same Message-IDs")
        let rereadDated = reread.compactMap(\.date)
        XCTAssertEqual(rereadDated.count, storedDates.count, "every dated message keeps a readable date in the export")

        // 7. Delete leaves nothing
        try await normal.store.clearAll()
        try await normal.fts.clear()
        let afterClear = try await normal.repository.count(query: .all)
        let spanAfter = try await normal.repository.dateSpan(query: .all)
        let searchAfter = try await normal.repository.count(query: EmailQuery(text: "enron"))
        print("DEBUGRUN clear visible=\(afterClear) search=\(searchAfter)")
        XCTAssertEqual(afterClear, 0)
        XCTAssertNil(spanAfter.first)
        XCTAssertEqual(searchAfter, 0)
    }
}
