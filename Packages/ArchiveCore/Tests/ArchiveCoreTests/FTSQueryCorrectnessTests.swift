//
//  FTSQueryCorrectnessTests.swift
//  ArchiveCoreTests
//
//  Whole-codebase review 2026-11-16, search index items:
//   B8  free text that contains FTS5 operator words built an invalid FTS5
//       expression, and every step loop read the resulting error as "end of
//       results" — the person saw "No results".
//   B9  the regex literal pre-filter went through the porter stemmer:
//       `runn\w+` → `"runn"*` never matches the indexed stem "run".
//   C22 the synchronous partial-index count read the default root, not the
//       root the shared index uses.
//   E   `clear()` deleted content and registry in two transactions.
//

import XCTest
import Foundation
import SQLite3
@testable import ArchiveCore

final class FTSQueryCorrectnessTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ftsq-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func email(_ i: Int, subject: String, body: String) -> MBOXParser.RawEmail {
        let date = Date(timeIntervalSince1970: 1_735_689_600 + Double(i) * 86_400)
        let fmt = DateFormatter(); fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return MBOXParser.RawEmail(
            headers: ["Message-ID": "<ftsq-\(i)-\(UUID().uuidString)@test>", "Subject": subject,
                      "From": "a@test", "To": "me@test", "Date": fmt.string(from: date)],
            rawSource: "", messageType: "email", attachments: [], timestamp: "", domains: [],
            plainBody: body, htmlBody: "")
    }

    private func makeIndex() -> FTSSearchIndex {
        FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts", isDirectory: true))
    }

    /// The emails every query test searches.
    private struct Corpus {
        let notGuilty, reportAnd, spamBudget, budget, near, orMail, running: MBOXParser.RawEmail
        var all: [MBOXParser.RawEmail] { [notGuilty, reportAnd, spamBudget, budget, near, orMail, running] }
    }

    private func corpus() -> Corpus {
        Corpus(
            notGuilty: email(0, subject: "Verdict", body: "the jury found him not guilty today"),
            reportAnd: email(1, subject: "Quarterly report and summary", body: "attached"),
            spamBudget: email(2, subject: "Spam offer", body: "cheap spam budget pills"),
            budget: email(3, subject: "Budget review", body: "the budget for next year"),
            near: email(4, subject: "Office move", body: "we are near the station"),
            orMail: email(5, subject: "Choice", body: "tea or coffee"),
            running: email(6, subject: "Training", body: "I was running late"))
    }

    private func search(_ fts: FTSSearchIndex, _ text: String) async throws -> Set<UUID> {
        Set(try await fts.search(text, limit: 100))
    }

    // MARK: - B8 free-text builder

    func testNotGuiltyFindsTheVerdict() async throws {
        let fts = makeIndex(); let c = corpus()
        try await fts.indexBatch(c.all)
        let q = try XCTUnwrap(FTSQueryBuilder.freeTextOrBoolean("not guilty"))
        XCTAssertEqual(q, #""not" "guilty"*"#)
        let hits = try await search(fts, "not guilty")
        XCTAssertEqual(hits, [c.notGuilty.id])
        // A capital NOT with nothing to its left is a word too.
        let capital = try await search(fts, "NOT guilty")
        XCTAssertEqual(capital, [c.notGuilty.id])
    }

    func testTrailingAndIsAWord() async throws {
        let fts = makeIndex(); let c = corpus()
        try await fts.indexBatch(c.all)
        XCTAssertEqual(FTSQueryBuilder.freeTextOrBoolean("report and"), #""report" "and"*"#)
        let lower = try await search(fts, "report and")
        XCTAssertEqual(lower, [c.reportAnd.id])
        let upper = try await search(fts, "report AND")
        XCTAssertEqual(upper, [c.reportAnd.id])
    }

    func testLeadingMinusExcludesTheWord() async throws {
        let fts = makeIndex(); let c = corpus()
        try await fts.indexBatch(c.all)
        XCTAssertEqual(FTSQueryBuilder.freeTextOrBoolean("-spam budget"), #"("budget"*) NOT "spam""#)
        let leading = try await search(fts, "-spam budget")
        XCTAssertEqual(leading, [c.budget.id], "budget mail without the word spam")
        let trailing = try await search(fts, "budget -spam")
        XCTAssertEqual(trailing, [c.budget.id])
        // On its own there is nothing to exclude from: the word is searched.
        let alone = try await search(fts, "-spam")
        XCTAssertEqual(alone, [c.spamBudget.id])
    }

    func testNearIsAWord() async throws {
        let fts = makeIndex(); let c = corpus()
        try await fts.indexBatch(c.all)
        let hits = try await search(fts, "NEAR")
        XCTAssertEqual(hits, [c.near.id])
        let two = try await search(fts, "near station")
        XCTAssertEqual(two, [c.near.id])
    }

    func testLoneOrIsAWord() async throws {
        let fts = makeIndex(); let c = corpus()
        try await fts.indexBatch(c.all)
        XCTAssertEqual(FTSQueryBuilder.freeTextOrBoolean("or"), #""or"*"#)
        let lower = try await search(fts, "or")
        XCTAssertEqual(lower, [c.orMail.id])
        let upper = try await search(fts, "OR")
        XCTAssertEqual(upper, [c.orMail.id])
    }

    func testRealBooleanOperatorsStillWork() async throws {
        let fts = makeIndex(); let c = corpus()
        try await fts.indexBatch(c.all)
        let or = try await search(fts, "verdict OR training")
        XCTAssertEqual(or, [c.notGuilty.id, c.running.id])
        let not = try await search(fts, "budget NOT spam")
        XCTAssertEqual(not, [c.budget.id])
        let andNot = try await search(fts, "budget AND NOT spam")
        XCTAssertEqual(andNot, [c.budget.id], "AND NOT reads as NOT")
    }

    /// No typed input may yield an invalid FTS5 expression.
    func testOperatorSoupIsAlwaysValid() async throws {
        let fts = makeIndex(); let c = corpus()
        try await fts.indexBatch(c.all)
        let inputs = ["AND", "OR", "NOT", "NEAR", "AND OR NOT", "budget OR", "OR budget", "budget AND OR spam",
                      "budget NOT NOT spam", "- budget", "--", "-", "\"budget", "budget\"", "(budget", "budget)",
                      "NEAR(budget", "budget * spam", "-spam -budget", "a OR NOT b", "&", "budget & spam"]
        for input in inputs {
            do { _ = try await fts.search(input, limit: 10) } catch {
                XCTFail("\(input) → \(FTSQueryBuilder.freeTextOrBoolean(input) ?? "nil") threw \(error)")
            }
        }
    }

    // MARK: - B8 step errors surface

    func testInvalidMatchThrowsInsteadOfReturningNothing() async throws {
        let fts = makeIndex(); let c = corpus()
        try await fts.indexBatch(c.all)
        // `NOT` alone is an FTS5 syntax error; sqlite3_prepare succeeds, the
        // error comes from sqlite3_step.
        do { _ = try await fts.searchRaw("NOT", limit: 10); XCTFail("searchRaw returned instead of throwing") } catch {}
        do { _ = try await fts.searchRanked("NOT", limit: 10); XCTFail("searchRanked returned instead of throwing") } catch {}
        do { _ = try await fts.countRaw("NOT"); XCTFail("countRaw returned instead of throwing") } catch {}
        do { _ = try await fts.matchingIDs(among: [c.budget.id], ftsQuery: "NOT"); XCTFail("matchingIDs returned") } catch {}
        do { _ = try await fts.matchingSubset(of: [c.budget.id], ftsQuery: "NOT"); XCTFail("matchingSubset returned") } catch {}
    }

    // MARK: - B9 regex pre-filter vs the stemmer

    func testRegexLiteralThatContinuesIntoAStemmedWordStillMatches() async throws {
        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let fts = makeIndex(); let c = corpus()
        try await store.insertBatch(c.all, batchSize: 10)
        try await fts.indexBatch(c.all)

        let outcome = try await BoundedRegexSearch.run(pattern: #"/runn\w+/"#, store: store, fts: fts)
        XCTAssertEqual(outcome.matchedIDs, [c.running.id], "\"running\" is indexed as \"run\"; the pre-filter must not drop it")
        XCTAssertFalse(outcome.truncated)
        XCTAssertTrue(RegexLiteralExtractor.prefilterTokens(from: #"runn\w+"#).isEmpty)
    }

    func testWordEndingLiteralsStillDriveTheFTSPath() async throws {
        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let fts = makeIndex()
        let hit = email(10, subject: "Billing", body: "invoices 1234 attached")
        let miss = email(11, subject: "Other", body: "nothing to see")
        try await store.insertBatch([hit, miss], batchSize: 10)
        try await fts.indexBatch([hit, miss])

        // "invoices" (stemmed "invoic") must be found through an exact term.
        let outcome = try await BoundedRegexSearch.run(pattern: #"/invoices\s+\d+/"#, store: store, fts: fts)
        XCTAssertTrue(outcome.usedLiteralPath)
        XCTAssertEqual(outcome.matchedIDs, [hit.id])
        XCTAssertEqual(outcome.scanned, 1, "only the FTS candidate was verified")

        XCTAssertEqual(RegexLiteralExtractor.prefilterTokens(from: #"invoice\s+\d+"#), ["invoice"])
        XCTAssertEqual(RegexLiteralExtractor.prefilterTokens(from: "budget report$"), ["budget", "report"])
        XCTAssertEqual(RegexLiteralExtractor.prefilterTokens(from: "budget.*report"), [], "both may continue into longer words")
        XCTAssertEqual(RegexLiteralExtractor.prefilterTokens(from: #"invoice\s*\d"#), [], "\\s* may match nothing")
        XCTAssertEqual(RegexLiteralExtractor.prefilterTokens(from: #"\bpaid\b"#), ["paid"])
        XCTAssertEqual(RegexLiteralExtractor.prefilterTokens(from: "(?x)invoice 12"), [], "free spacing: a space is not a boundary")
    }

    // MARK: - C22 snapshot root

    func testPartialCountSnapshotReadsTheSharedIndexRoot() async throws {
        let shardsDir = root.appendingPathComponent("relocated-fts", isDirectory: true)
        let saved = FTSSearchIndex.testShardsDirectoryOverride
        FTSSearchIndex.testShardsDirectoryOverride = shardsDir
        defer { FTSSearchIndex.testShardsDirectoryOverride = saved }

        let big = String(repeating: "word ", count: FTSSearchIndex.indexedTextBudgetBytes / 5 + 10)
        let fts = FTSSearchIndex(shardsDirectory: shardsDir)
        try await fts.indexBatch([email(20, subject: "Large", body: big), email(21, subject: "Small", body: "short")])
        let actorCount = try await fts.partiallyIndexedCount()
        XCTAssertEqual(actorCount, 1)

        XCTAssertEqual(FTSSearchIndex.productionShardsDirectory, shardsDir)
        XCTAssertEqual(try FTSSearchIndex.partiallyIndexedCountSnapshot(), 1,
                       "the snapshot reads the shards the shared index uses")
        XCTAssertEqual(try FTSSearchIndex.partiallyIndexedCountSnapshot(shardsDirectory: shardsDir), 1)

        FTSSearchIndex.testShardsDirectoryOverride = nil
        XCTAssertEqual(FTSSearchIndex.productionShardsDirectory,
                       ArchiveLayout.ftsDirectory(under: ArchiveLayout.productionRoot),
                       "without the test hook: the relocation-aware archive root")
    }

    // MARK: - E clear() is one transaction per shard

    func testClearThatFailsHalfwayLeavesContentAndRegistryTogether() async throws {
        let shardsDir = root.appendingPathComponent("fts", isDirectory: true)
        let fts = FTSSearchIndex(shardsDirectory: shardsDir)
        let c = corpus()
        try await fts.indexBatch(c.all)
        let before = try await fts.rowCount()
        XCTAssertEqual(before, c.all.count)

        // Make the SECOND delete (the registry) fail, from another connection.
        let shardFiles = try FileManager.default.contentsOfDirectory(atPath: shardsDir.path).filter { $0.hasSuffix(".db") }
        XCTAssertFalse(shardFiles.isEmpty)
        for name in shardFiles {
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(shardsDir.appendingPathComponent(name).path, &db), SQLITE_OK)
            XCTAssertEqual(sqlite3_exec(db, """
                CREATE TRIGGER block_registry_delete BEFORE DELETE ON indexed_message
                BEGIN SELECT RAISE(ABORT, 'registry delete blocked by test'); END;
                """, nil, nil, nil), SQLITE_OK)
            sqlite3_close(db)
        }

        do { try await fts.clear(); XCTFail("clear should report the failed delete") } catch {}

        let after = try await fts.rowCount()
        XCTAssertEqual(after, c.all.count, "the content delete rolled back with the registry delete")
        let registered = try await fts.indexedSubset(of: c.all.map(\.id))
        XCTAssertEqual(registered.count, c.all.count)
    }
}
