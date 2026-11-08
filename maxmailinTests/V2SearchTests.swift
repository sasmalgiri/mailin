@testable import ArchiveCore
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

// MARK: - A7 `filename:` operator, archive-wide in SQL

final class AttachmentFilenameSearchTests: XCTestCase {

    func testFilenameOperatorMatchesAttachmentNamesArchiveWide() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailin-filename-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store"))
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts"))
        let archive = ArchiveDataService(repository: EmailStoreRepository(store: store, fts: fts))

        func email(_ i: Int, attachments: [AttachmentMetadata]) -> MBOXParser.RawEmail {
            MBOXParser.RawEmail(
                headers: ["Message-ID": "<fn-\(i)@t>", "Subject": "S\(i)", "From": "a@b.com", "To": "c@d.com",
                          "Date": "Wed, \(String(format: "%02d", 1 + i)) Jan 2025 12:00:00 +0000"],
                rawSource: "raw \(i)", messageType: "email", attachments: attachments,
                timestamp: "2025-01-\(String(format: "%02d", 1 + i))T12:00:00Z", domains: ["b.com"],
                plainBody: "body \(i)", htmlBody: "")
        }
        let fixtures = [
            email(1, attachments: [AttachmentMetadata(filename: "Contract-Final.PDF", mimeType: "application/pdf", size: 10)]),
            email(2, attachments: [AttachmentMetadata(filename: "figures.xlsx", mimeType: "application/vnd.ms-excel", size: 10)]),
            email(3, attachments: [AttachmentMetadata(filename: "scan.pdf", mimeType: "application/pdf", size: 10),
                                   AttachmentMetadata(filename: "notes.txt", mimeType: "text/plain", size: 10)]),
            email(4, attachments: []),
        ]
        try await store.insertBatch(fixtures, batchSize: 100)
        try await fts.indexBatch(fixtures)

        // Compiler: the operator lands in the query, not in free text.
        let pdf = ArchiveQueryCompiler.compile("filename:pdf")
        XCTAssertEqual(pdf.attachmentFilename, "pdf")
        XCTAssertEqual(pdf.hasAttachments, true)
        XCTAssertNil(pdf.text)

        // SQL: case-insensitive substring over the attachments table.
        let pdfIDs = Set(try await archive.page(query: pdf, limit: 50).summaries.map(\.id))
        XCTAssertEqual(pdfIDs, [fixtures[0].id, fixtures[2].id], "both PDFs, whatever the case of the extension")
        let pdfCount = try await archive.count(query: pdf)
        XCTAssertEqual(pdfCount, 2)

        let contract = ArchiveQueryCompiler.compile("attachment:contract")
        let contractIDs = Set(try await archive.page(query: contract, limit: 50).summaries.map(\.id))
        XCTAssertEqual(contractIDs, [fixtures[0].id])

        let nothing = ArchiveQueryCompiler.compile("filename:zip")
        let nothingCount = try await archive.count(query: nothing)
        XCTAssertEqual(nothingCount, 0)

        // Combines with other predicates like any operator.
        let combined = ArchiveQueryCompiler.compile("filename:pdf subject:S3")
        let combinedIDs = Set(try await archive.page(query: combined, limit: 50).summaries.map(\.id))
        XCTAssertEqual(combinedIDs, [fixtures[2].id])
    }
}

// MARK: - IPAD-03 / IPAD-04 — the full list (iPad, iPhone, Mac default) searches on the model

extension V2SearchTests {

    private static func ipadCRC32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
            table[i] = c
        }
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFFFFFF
    }

    /// A stored (uncompressed) ZIP with correct CRCs — an Office package is one.
    private static func ipadZip(_ members: [(name: String, data: Data)]) -> Data {
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }
        var local = Data(), central = Data()
        for m in members {
            let name = Array(m.name.utf8)
            let crc = ipadCRC32(m.data)
            let size = UInt32(m.data.count)
            let offset = UInt32(local.count)
            local.append(contentsOf: le32(0x04034b50) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0)
                         + le32(crc) + le32(size) + le32(size) + le16(name.count) + le16(0) + name)
            local.append(m.data)
            central.append(contentsOf: le32(0x02014b50) + le16(20) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0)
                           + le32(crc) + le32(size) + le32(size) + le16(name.count) + le16(0) + le16(0) + le16(0) + le16(0)
                           + le32(0) + le32(offset) + name)
        }
        var file = local
        file.append(central)
        file.append(contentsOf: le32(0x06054b50) + le16(0) + le16(0) + le16(members.count) + le16(members.count)
                    + le32(UInt32(central.count)) + le32(UInt32(local.count)) + le16(0))
        return file
    }

    private static func ipadDocx(_ text: String) -> Data {
        ipadZip([
            ("[Content_Types].xml", Data("<Types/>".utf8)),
            ("word/document.xml", Data("""
                <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>
                <w:p><w:r><w:t>\(text)</w:t></w:r></w:p>
                </w:body></w:document>
                """.utf8)),
        ])
    }

    private static func ipadMessage(_ id: String, subject: String, body: String,
                                    attachment: (name: String, mime: String, data: Data)?) throws -> MBOXParser.RawEmail {
        var raw = """
        From sender@example.com Mon Oct 28 10:00:00 2024
        From: Alice Example <alice@example.com>
        To: bob@example.org
        Subject: \(subject)
        Date: Mon, 28 Oct 2024 10:00:00 +0000
        Message-ID: <\(id)@gate1>
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="B"

        --B
        Content-Type: text/plain

        \(body)

        """
        if let attachment {
            raw += """
            --B
            Content-Type: \(attachment.mime); name="\(attachment.name)"
            Content-Disposition: attachment; filename="\(attachment.name)"
            Content-Transfer-Encoding: base64

            \(attachment.data.base64EncodedString())

            """
        }
        raw += "--B--\n"
        return try MBOXParser.processRawMessage(raw, senderEmail: "")
    }

    /// The gate 1 archive in small: a DOCX, a ZIP holding `inner/Contract.docx`,
    /// and ordinary bodies — indexed by the attachment job on an isolated store.
    private func ipadArchive() async throws -> (env: Env, docx: MBOXParser.RawEmail, zip: MBOXParser.RawEmail) {
        SearchChunkPolicy.isEnabled = true
        let env = try makeEnv()
        AttachmentTextIndexJob.testSuppressKicks = true
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()
        AttachmentTextIndexJob.testStoreOverride = env.store
        AttachmentOCR.isEnabled = false
        AttachmentTextIndexJob.installChildReader()

        let docx = try Self.ipadMessage("docx", subject: "Renovation notes", body: "See the document.",
                                        attachment: ("Notes.docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                                                     Self.ipadDocx("The lighthouse renovations start in spring.")))
        let bundle = Self.ipadZip([("inner/Contract.docx", Self.ipadDocx("The secret codeword is zebracrossing quarterly."))])
        let zip = try Self.ipadMessage("zip", subject: "Bundle of contracts", body: "Zip attached.",
                                       attachment: ("Bundle.zip", "application/zip", bundle))
        var all = [docx, zip]
        for i in 0..<6 {
            all.append(try Self.ipadMessage("plain-\(i)", subject: "Routine \(i)", body: "Routine update \(i).", attachment: nil))
        }
        try await seed(env, all)
        _ = await AttachmentTextIndexJob.shared.run()
        return (env, docx, zip)
    }

    /// IPAD-03: the iPad (and iPhone, and Mac default) list's view model finds
    /// words that only an attachment holds — a DOCX, and a DOCX inside a ZIP —
    /// with `in:attachments` too, names the file in the row's evidence, and a
    /// search with no hits carries the notice, never a blank list.
    func testIPAD03_fullListSearchesAttachmentsAndZipChildrenOnTheModel_andANoMatchSaysWhatWasSearched() async throws {
        let wasOn = SearchChunkPolicy.isEnabled
        let ocrWas = AttachmentOCR.isEnabled
        defer {
            SearchChunkPolicy.isEnabled = wasOn
            AttachmentOCR.isEnabled = ocrWas
            AttachmentTextIndexJob.testStoreOverride = nil
            AttachmentTextIndexJob.testSuppressKicks = false
        }
        let (env, docx, zip) = try await ipadArchive()

        let vm = ParsedEmailListViewModel(viewModel: ContentViewModel(), archive: env.archive, pageSize: 50, maxRetained: 200)
        vm.isPremiumUser = true
        func search(_ text: String) async -> [UUID] {
            vm.searchText = text
            await vm.reloadForQueryChangeNow()
            return vm.visibleEmails.map(\.id)
        }

        let inZip = await search("zebracrossing")
        XCTAssertTrue(vm.typedSearchRunsOnModel, "the plain box runs on the search model when it is on")
        XCTAssertNil(vm.currentArchiveQuery.text, "the typed words are model conditions, not previous-index text")
        XCTAssertEqual(inZip, [zip.id], "a DOCX inside a ZIP attachment is found from the list's search box")
        XCTAssertNil(vm.searchNotice, "a search with hits carries no no-match notice")
        let provider = try XCTUnwrap(vm.searchEvidenceProvider, "rows get the index's evidence")
        let evidence = await provider(zip.id)
        XCTAssertTrue(evidence.contains { MatchEvidenceChips.childPath($0.location) == "inner/Contract.docx" },
                      "the chip names the file inside the ZIP: \(evidence)")

        let inDocx = await search("lighthouse")
        XCTAssertEqual(inDocx, [docx.id], "a DOCX attachment's text is found")
        let scoped = await search("in:attachments zebracrossing")
        XCTAssertEqual(scoped, [zip.id], "in:attachments reaches the files inside an attachment")
        let body = await search("Routine")
        XCTAssertEqual(body.count, 6, "body words still work")

        let none = await search("nowhereword")
        XCTAssertEqual(none, [])
        let notice = try XCTUnwrap(vm.searchNotice, "a search with no hits says so — never a blank pane")
        XCTAssertTrue(notice.contains("No match"), notice)
        let expected = ModelSearchNotice.noMatch(coverage: await ModelSearchNotice.snapshot(archive: env.archive))
        XCTAssertEqual(notice, expected)

        // The model switched off: the previous path stays (rule 14), no model evidence.
        SearchChunkPolicy.isEnabled = false
        _ = await search("Routine")
        XCTAssertFalse(vm.typedSearchRunsOnModel)
        XCTAssertNotNil(vm.currentArchiveQuery.text)
        XCTAssertNil(vm.searchEvidenceProvider)
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()
    }

    /// IPAD-03: the notice text for each coverage state (pure).
    func testIPAD03_noMatchNoticeSaysWhatWasSearched() {
        XCTAssertTrue(ModelSearchNotice.noMatch(coverage: nil).contains("coverage could not be checked"))
        let full = SearchCoverageSnapshot(storedMessages: 8, indexedMessages: 8, partiallyIndexedMessages: 0,
                                          chunks: SQLiteEmailStore.SearchDocCoverage(bodiesEvaluable: 8, emails: 8, attachmentsEvaluable: 2,
                                                                                     attachments: 2, bodyChunks: 8))
        XCTAssertTrue(ModelSearchNotice.noMatch(coverage: full).contains("Nothing in the fully indexed scope matches this search."))
        let behind = SearchCoverageSnapshot(storedMessages: 8, indexedMessages: 8, partiallyIndexedMessages: 0,
                                            chunks: SQLiteEmailStore.SearchDocCoverage(bodiesEvaluable: 5, emails: 8, attachmentsEvaluable: 2,
                                                                                       attachments: 2, bodyChunks: 5))
        let behindText = ModelSearchNotice.noMatch(coverage: behind)
        XCTAssertTrue(behindText.contains("indexing is incomplete") && behindText.contains("5 of 8"), behindText)
    }

    /// IPAD-04 (a): the message view's Contents list reads the files inside a
    /// ZIP attachment from the archive it is given, and opens short lists.
    func testIPAD04_zipAttachmentContentsAreListedForTheMessage() async throws {
        let wasOn = SearchChunkPolicy.isEnabled
        let ocrWas = AttachmentOCR.isEnabled
        defer {
            SearchChunkPolicy.isEnabled = wasOn
            AttachmentOCR.isEnabled = ocrWas
            AttachmentTextIndexJob.testStoreOverride = nil
            AttachmentTextIndexJob.testSuppressKicks = false
        }
        let (env, docx, zip) = try await ipadArchive()
        let rows = await AttachmentChildrenList.rows(emailID: zip.id, position: 0, archive: env.archive)
        XCTAssertEqual(rows.map(\.path), ["inner/Contract.docx"])
        XCTAssertEqual(rows.first.map { AttachmentChildrenList.stateLabel($0.state) }, String(localized: "read for search"))
        let none = await AttachmentChildrenList.rows(emailID: docx.id, position: 0, archive: env.archive)
        XCTAssertTrue(none.isEmpty, "a DOCX is a document, not a container: no Contents list")
        XCTAssertTrue(AttachmentChildrenList.startsExpanded(count: rows.count), "a short list is open on arrival — no tap to see the file")
        XCTAssertFalse(AttachmentChildrenList.startsExpanded(count: 500))
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()
    }

    /// IPAD-04 (b): the per-attachment Download follows the access policy —
    /// enabled within Free's daily allowance with the count said, off with the
    /// reason and the upgrade path when it is used, unlimited once a plan was held.
    func testIPAD04_attachmentDownloadFollowsThePolicy_andSaysWhy() throws {
        XCTAssertEqual(StoreManager.freeAttachmentDownloadsPerDay, 10)
        let free = AccessPolicy(state: .free)
        let fresh = AttachmentDownloadGate.decide(policy: free, usedToday: 0)
        XCTAssertTrue(fresh.isEnabled, "Free includes downloads")
        XCTAssertEqual(fresh.remainingToday, 10)
        XCTAssertEqual(fresh.note, String(localized: "Free plan: \(10) of \(10) attachment saves left today."))
        XCTAssertFalse(fresh.offersUpgrade)
        let some = AttachmentDownloadGate.decide(policy: free, usedToday: 7)
        XCTAssertTrue(some.isEnabled)
        XCTAssertEqual(some.remainingToday, 3)
        XCTAssertTrue(try XCTUnwrap(some.note).contains("3"))
        let used = AttachmentDownloadGate.decide(policy: free, usedToday: 10)
        XCTAssertFalse(used.isEnabled)
        XCTAssertEqual(used.remainingToday, 0)
        XCTAssertTrue(used.offersUpgrade, "a disabled button comes with the way past it")
        let reason = try XCTUnwrap(used.note, "disabled is never silent")
        XCTAssertTrue(reason.contains("10") && reason.contains("Personal"), reason)
        XCTAssertFalse(AttachmentDownloadGate.decide(policy: free, usedToday: 25).isEnabled)
        for state in [EntitlementState.active(.personal), .lifetime(.professional), .lapsed(previous: .personal)] {
            let paid = AttachmentDownloadGate.decide(policy: AccessPolicy(state: state), usedToday: 99)
            XCTAssertEqual(paid, AttachmentDownloadDecision(isEnabled: true, remainingToday: nil, note: nil, offersUpgrade: false), "\(state)")
        }

        // A save counts against today's allowance on Free only.
        let suite = "ipad04-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        AttachmentDownloadGate.recordSave(policy: free, defaults: defaults)
        AttachmentDownloadGate.recordSave(policy: free, defaults: defaults)
        XCTAssertEqual(defaults.integer(forKey: AttachmentDownloadGate.usedTodayKey), 2)
        AttachmentDownloadGate.recordSave(policy: AccessPolicy(state: .active(.personal)), defaults: defaults)
        XCTAssertEqual(defaults.integer(forKey: AttachmentDownloadGate.usedTodayKey), 2)

        // Source guard: the message view's button reads the policy, not a parse-time temp file.
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let detail = try String(contentsOf: repo.appendingPathComponent("maxmailin/EmailDetailView.swift"), encoding: .utf8)
        XCTAssertFalse(detail.contains(".disabled(att.fileURL == nil)"), "a stored message has no temp file; the bytes come from the message")
        XCTAssertTrue(detail.contains(".disabled(!downloadDecision.isEnabled)"))
    }
}
