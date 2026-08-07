import XCTest
@testable import maxmailin

/// Part P regression net — Search v2:
///  P1 date/year shard pruning (pruned results EQUAL the unpruned reference),
///  P2 ranked (bm25) continuation cursor (every match exactly once, stable
///     order, query change invalidates the cursor),
///  P3 bounded regex (literal-derived FTS candidates + exact verify equal a
///     full-scan reference; no-literal patterns respect an explicit cap and
///     surface truncation),
///  plus the preview-bounded FTS subset primitive replacing the
///  whole-corpus-sized fetch in the legacy list.
///
/// Fixtures live in isolated temp SQLite stores + FTS shard dirs
/// (V2ExportTests style) — production singletons are never touched.
@MainActor
final class V2SearchTests: XCTestCase {

    // MARK: - Fixtures (isolated temp store + FTS)

    private struct Env {
        let root: URL
        let store: SQLiteEmailStore
        let fts: FTSSearchIndex
        let repo: EmailStoreRepository
        let archive: ArchiveDataService
    }

    private func makeEnv() throws -> Env {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailin-search-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store"))
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts"))
        let repo = EmailStoreRepository(store: store, fts: fts)
        return Env(root: root, store: store, fts: fts, repo: repo,
                   archive: ArchiveDataService(repository: repo))
    }

    private static let monthNames = ["", "Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                     "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    private func makeEmail(tag: String, i: Int, year: Int, month: Int = 6,
                           day: Int? = nil, body: String) -> MBOXParser.RawEmail {
        let d = day ?? (1 + (i % 28))
        let dd = String(format: "%02d", d)
        let mm = String(format: "%02d", month)
        let mid = "<\(tag)-\(i)-\(year)@test>"
        return MBOXParser.RawEmail(
            headers: [
                "Message-ID": mid,
                "Subject": "Subject \(tag) \(i)",
                "From": "a@b.com",
                "To": "c@d.com",
                "Date": "Wed, \(dd) \(Self.monthNames[month]) \(year) 12:00:00 +0000"
            ],
            rawSource: "raw \(tag) \(i)",
            messageType: "email",
            attachments: [],
            timestamp: "\(year)-\(mm)-\(dd)T12:00:00Z",
            domains: ["b.com"],
            plainBody: body,
            htmlBody: ""
        )
    }

    private func seed(_ env: Env, _ fixtures: [MBOXParser.RawEmail]) async throws {
        try await env.store.insertBatch(fixtures, batchSize: 100)
        try await env.fts.indexBatch(fixtures)
    }

    private func utcDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: comps)!
    }

    // MARK: - P1 — date/year shard pruning

    /// The pruned shard set is structurally bounded: it always contains the
    /// unknown-date shard, covers the range (± the safety year), and EXCLUDES
    /// years far outside the range.
    func testShardYearsPruneStructure() {
        let years = FTSSearchIndex.shardYears(after: utcDate(2020, 3, 1), before: utcDate(2022, 9, 1))!
        XCTAssertTrue(years.contains(0), "unknown-date shard always searched")
        for y in 2019...2023 { XCTAssertTrue(years.contains(y), "range ± 1 covered (\(y))") }
        XCTAssertFalse(years.contains(2016), "far-outside year pruned away")
        XCTAssertFalse(years.contains(2025), "far-outside year pruned away")
        XCTAssertNil(FTSSearchIndex.shardYears(after: nil, before: nil), "no bounds → no pruning")
    }

    /// Text + date over a multi-year fixture: the pruned implementation (page
    /// path AND ranked-cursor path) returns EXACTLY the same id set as an
    /// unpruned reference (all-shard searchRaw + exact date filter).
    func testShardPrunedTextPlusDateEqualsUnprunedReference() async throws {
        let env = try makeEnv()
        var fixtures: [MBOXParser.RawEmail] = []
        for year in [2016, 2019, 2020, 2021, 2022] {
            for i in 0..<8 {
                let body = (i % 2 == 0) ? "alpha report item \(i) y\(year)" : "beta note \(i) y\(year)"
                fixtures.append(makeEmail(tag: "p1", i: i, year: year, day: 1 + i, body: body))
            }
        }
        try await seed(env, fixtures)

        let after = utcDate(2020, 3, 1)
        let before = utcDate(2022, 9, 1)
        let query = EmailQuery(text: "alpha", beforeDate: before, afterDate: after)

        // Unpruned reference: ALL shards, then exact date filter.
        let ftsQuery = try XCTUnwrap(FTSQueryBuilder.freeTextOrBoolean("alpha"))
        let allIDs = try await env.fts.searchRaw(ftsQuery, limit: 10_000)
        let allSums = try await env.store.summaries(ids: allIDs)
        let reference = Set(allSums.filter { $0.date >= after && $0.date < before }.map(\.id))
        XCTAssertEqual(reference.count, 12, "fixture sanity: 4 alpha × 3 in-range years")

        // Pruned page path.
        let page = try await env.repo.page(query: query, cursor: nil, limit: 10_000)
        XCTAssertEqual(Set(page.summaries.map(\.id)), reference, "pruned page == unpruned reference")

        // Pruned ranked-cursor path, iterated to exhaustion.
        var collected: [UUID] = []
        var cursor: RankedSearchCursor? = nil
        var pages = 0
        repeat {
            let p = try await env.repo.searchRanked(query: query, cursor: cursor, limit: 5)
            collected += p.summaries.map(\.id)
            cursor = p.nextCursor
            pages += 1
        } while cursor != nil && pages < 20
        XCTAssertEqual(Set(collected), reference, "ranked cursor iteration == unpruned reference")
        XCTAssertEqual(collected.count, reference.count, "no duplicates across pages")
    }

    // MARK: - P2 — ranked continuation cursor

    /// Duplicate-score ties across two shards: iterating the cursor to
    /// exhaustion yields every expected id EXACTLY once, and the whole
    /// pagination is stable (a second full run produces the identical order).
    func testRankedCursorIteratesExactlyOnceWithStableOrder() async throws {
        let env = try makeEnv()
        var fixtures: [MBOXParser.RawEmail] = []
        for year in [2021, 2022] {
            for i in 0..<6 {
                // Identical bodies → identical bm25 within a shard (tie-break by id).
                fixtures.append(makeEmail(tag: "p2", i: i, year: year, body: "tiedtoken payload"))
            }
        }
        try await seed(env, fixtures)
        let expected = Set(fixtures.map(\.id))
        let query = EmailQuery(text: "tiedtoken")

        func iterate() async throws -> [UUID] {
            var out: [UUID] = []
            var cursor: RankedSearchCursor? = nil
            var pages = 0
            repeat {
                let p = try await env.repo.searchRanked(query: query, cursor: cursor, limit: 5)
                out += p.summaries.map(\.id)
                cursor = p.nextCursor
                pages += 1
            } while cursor != nil && pages < 20
            return out
        }

        let run1 = try await iterate()
        XCTAssertEqual(Set(run1), expected, "every expected id appears")
        XCTAssertEqual(run1.count, expected.count, "exactly once — no dups, no skips")
        let run2 = try await iterate()
        XCTAssertEqual(run1, run2, "pagination order is stable across runs")
    }

    /// A cursor from query A presented with query B throws — the continuation
    /// is bound to its query by fingerprint, never silently mixed.
    func testRankedCursorInvalidatedOnQueryChange() async throws {
        let env = try makeEnv()
        let fixtures = (0..<8).map { makeEmail(tag: "p2b", i: $0, year: 2023, body: "alpha item \($0)") }
        try await seed(env, fixtures)

        let first = try await env.repo.searchRanked(query: EmailQuery(text: "alpha"), cursor: nil, limit: 3)
        XCTAssertEqual(first.summaries.count, 3)
        let cursor = try XCTUnwrap(first.nextCursor, "more matches remain → live cursor")

        do {
            _ = try await env.repo.searchRanked(query: EmailQuery(text: "beta"), cursor: cursor, limit: 3)
            XCTFail("changed query must invalidate the cursor")
        } catch let error as EmailRepositoryError {
            XCTAssertEqual(error, .staleSearchCursor)
        }

        // Same query + same cursor still resumes fine.
        let second = try await env.repo.searchRanked(query: EmailQuery(text: "alpha"), cursor: cursor, limit: 10)
        let all = Set(first.summaries.map(\.id)).union(second.summaries.map(\.id))
        XCTAssertEqual(all, Set(fixtures.map(\.id)), "resume covers the remainder exactly")
        XCTAssertEqual(first.summaries.count + second.summaries.count, fixtures.count, "no overlap")
    }

    /// The v2 list pages ranked text results through the continuation cursor:
    /// walking hasMore to the end sees every match exactly once.
    func testArchiveListViewModelPagesRankedTextResults() async throws {
        let env = try makeEnv()
        var fixtures: [MBOXParser.RawEmail] = []
        for (n, year) in [(9, 2021), (8, 2022), (8, 2023)] {
            for i in 0..<n {
                fixtures.append(makeEmail(tag: "alvm\(year)", i: i, year: year, body: "budget line \(i) y\(year)"))
            }
        }
        try await seed(env, fixtures)

        let vm = ArchiveListViewModel(archive: env.archive, pageSize: 10)
        var appended: [[EmailSummary]] = []
        vm._debugOnAppend = { appended.append($0) }
        await vm.setQuery(EmailQuery(text: "budget"))
        XCTAssertEqual(vm.totalCount, 25, "store-truth total for the text query")

        var guardCount = 0
        while vm.hasMore && guardCount < 20 {
            await vm.loadNextPage()
            guardCount += 1
        }
        let ids = appended.flatMap { $0.map(\.id) }
        XCTAssertEqual(ids.count, 25, "all ranked matches paged through")
        XCTAssertEqual(Set(ids), Set(fixtures.map(\.id)), "every match exactly once")
        XCTAssertNil(vm.error)
    }

    // MARK: - P3 — bounded regex

    /// Conservative mandatory-literal extraction: derivable literals come out;
    /// anything uncertain yields none.
    func testRegexLiteralExtractionConservative() {
        XCTAssertEqual(RegexLiteralExtractor.mandatoryLiteralTokens(from: #"invoice\s+\d+"#), ["invoice"])
        XCTAssertEqual(RegexLiteralExtractor.mandatoryLiteralTokens(from: "budget.*report"), ["budget", "report"])
        XCTAssertEqual(RegexLiteralExtractor.mandatoryLiteralTokens(from: "colou?r"), ["colo"])
        XCTAssertEqual(RegexLiteralExtractor.mandatoryLiteralTokens(from: "(abc)+def"), ["def"])
        XCTAssertEqual(RegexLiteralExtractor.mandatoryLiteralTokens(from: "foo|bar"), [], "top-level alternation → nothing mandatory")
        XCTAssertEqual(RegexLiteralExtractor.mandatoryLiteralTokens(from: #"\d{3,}"#), [], "no literal derivable")
        XCTAssertEqual(RegexLiteralExtractor.mandatoryLiteralTokens(from: "a{2}bc"), [], "short/uncertain runs dropped")
        XCTAssertEqual(RegexLiteralExtractor.mandatoryLiteralTokens(from: "(unbalanced"), [], "uncertain syntax → conservative none")
    }

    /// Regex with a derivable literal: FTS candidates + exact verification
    /// return EXACTLY the matches of a full-scan reference over the fixture.
    func testRegexWithDerivableLiteralEqualsFullScanReference() async throws {
        let env = try makeEnv()
        var fixtures: [MBOXParser.RawEmail] = []
        for i in 0..<6 { fixtures.append(makeEmail(tag: "rx", i: i, year: 2021 + (i % 3), body: "invoice 12\(i) attached")) }
        for i in 6..<9 { fixtures.append(makeEmail(tag: "rx", i: i, year: 2022, body: "invoice due soon \(i)")) }
        for i in 9..<12 { fixtures.append(makeEmail(tag: "rx", i: i, year: 2023, body: "receipt 99\(i) filed")) }
        try await seed(env, fixtures)

        let pattern = #"/invoice\s+\d+/"#
        // Full-scan reference over the fixture (same normalization + text scope).
        let normalized = BoundedRegexSearch.normalizedPattern(pattern)
        let regex = try NSRegularExpression(pattern: normalized, options: [.caseInsensitive])
        let reference = Set(fixtures.filter { BoundedRegexSearch.matches(regex, $0) }.map(\.id))
        XCTAssertEqual(reference.count, 6, "fixture sanity")

        let outcome = try await BoundedRegexSearch.run(pattern: pattern, store: env.store, fts: env.fts)
        XCTAssertTrue(outcome.usedLiteralPath, "literal 'invoice' drives FTS candidate retrieval")
        XCTAssertFalse(outcome.truncated)
        XCTAssertEqual(outcome.matchedIDs, reference, "literal path == full-scan reference")
        XCTAssertLessThan(outcome.scanned, fixtures.count, "bounded: only FTS candidates were hydrated/verified")
    }

    /// Regex with NO derivable literal: the scan respects the explicit cap and
    /// SURFACES truncation (never silent); an uncapped run equals the full
    /// reference.
    func testRegexWithoutLiteralRespectsCapAndSurfacesTruncation() async throws {
        let env = try makeEnv()
        var fixtures: [MBOXParser.RawEmail] = []
        for i in 0..<30 {
            let body = (i % 2 == 0) ? "ref 12345 body \(i)" : "no numbers here \(i)"
            fixtures.append(makeEmail(tag: "rxc", i: i, year: 2022, day: 1 + (i % 28), body: body))
        }
        try await seed(env, fixtures)
        let pattern = #"\d{3,}"#

        let capped = try await BoundedRegexSearch.run(pattern: pattern, store: env.store, fts: env.fts, scanCap: 10)
        XCTAssertFalse(capped.usedLiteralPath)
        XCTAssertEqual(capped.scanned, 10, "cap respected exactly")
        XCTAssertTrue(capped.truncated, "the bound is surfaced, not silent")

        let normalized = BoundedRegexSearch.normalizedPattern(pattern)
        let regex = try NSRegularExpression(pattern: normalized, options: [.caseInsensitive])
        let reference = Set(fixtures.filter { BoundedRegexSearch.matches(regex, $0) }.map(\.id))
        let full = try await BoundedRegexSearch.run(pattern: pattern, store: env.store, fts: env.fts, scanCap: 1_000)
        XCTAssertFalse(full.truncated, "cap covers the whole scope → no truncation flag")
        XCTAssertEqual(full.scanned, fixtures.count)
        XCTAssertEqual(full.matchedIDs, reference, "capped scan == full reference when the cap suffices")
    }

    // MARK: - Preview-bounded boolean/text search (whole-corpus fetch fix)

    /// `matchingSubset` answers "which of THESE ids match" — exact against a
    /// searchRaw reference, bounded by the id list, and (used by the legacy
    /// list) never materializes an archive-wide result set.
    func testMatchingSubsetIsPreviewBoundedAndExact() async throws {
        let env = try makeEnv()
        var fixtures: [MBOXParser.RawEmail] = []
        for i in 0..<12 {
            let body = (i % 2 == 0) ? "gamma finding \(i)" : "delta memo \(i)"
            fixtures.append(makeEmail(tag: "sub", i: i, year: 2021 + (i % 2), body: body))
        }
        try await seed(env, fixtures)

        let matching = fixtures.filter { $0.plainBody.contains("gamma") }.map(\.id)
        let nonMatching = fixtures.filter { !$0.plainBody.contains("gamma") }.map(\.id)
        let preview = Array(matching.prefix(4)) + Array(nonMatching.prefix(3))

        let ftsQuery = try XCTUnwrap(FTSQueryBuilder.freeTextOrBoolean("gamma"))
        let result = try await env.fts.matchingSubset(of: preview, ftsQuery: ftsQuery)
        XCTAssertEqual(result, Set(matching.prefix(4)), "exactly the matching preview ids")

        // Reference: full ranked search intersected with the preview.
        let all = Set(try await env.fts.searchRaw(ftsQuery, limit: 10_000))
        XCTAssertEqual(result, all.intersection(preview), "subset == reference ∩ preview")
    }
}
