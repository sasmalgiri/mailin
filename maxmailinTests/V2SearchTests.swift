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
                                    attachment: (name: String, mime: String, data: Data)?,
                                    date: String = "Mon, 28 Oct 2024 10:00:00 +0000") throws -> MBOXParser.RawEmail {
        var raw = """
        From sender@example.com Mon Oct 28 10:00:00 2024
        From: Alice Example <alice@example.com>
        To: bob@example.org
        Subject: \(subject)
        Date: \(date)
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
    private func ipadArchive(extra: [MBOXParser.RawEmail] = []) async throws -> (env: Env, docx: MBOXParser.RawEmail, zip: MBOXParser.RawEmail) {
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
        all += extra
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
        let expected = ModelSearchNotice.noMatch(coverage: await ModelSearchNotice.snapshot(archive: env.archive, scope: vm.currentArchiveQuery))
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

// MARK: - R7 — Show text at the match, paged, with the search's phrase rule; honest coverage; rebuild record

extension V2SearchTests {

    private static let r7Filler = "lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor "

    /// Filler of about `characters` characters (whole words).
    private static func r7Filler(_ characters: Int) -> String {
        String(repeating: r7Filler, count: max(1, characters / r7Filler.count))
    }

    /// One message with one text attachment whose extracted text spans about
    /// six chunks: no match in the first two, the first (wrapped) occurrence of
    /// "quarterly results" in the third, a second in the fourth, a third near the end.
    private func r7Archive() async throws -> (env: Env, email: MBOXParser.RawEmail, text: String) {
        let env = try makeEnv()
        var email = makeEmail(tag: "r7", i: 1, year: 2025, body: "See the report.")
        email.attachments = [AttachmentMetadata(filename: "report.txt", mimeType: "text/plain", size: 10)]
        try await seed(env, [email])
        let chunk = SearchChunker.chunkCharacters
        let text = Self.r7Filler(chunk * 2 + chunk / 2) + "the quarterly\n   results were good "
            + Self.r7Filler(chunk) + "and the Quarterly Results again "
            + Self.r7Filler(chunk + chunk / 3) + "final quarterly results here " + Self.r7Filler(2_000)
        try await env.store.indexAttachmentSearchDocuments(emailID: email.id, documents: [
            AttachmentSearchDocument(ordinal: 0, filename: "report.txt", text: text, state: .complete, extractorVersion: 10, ocr: false)
        ])
        return (env, email, text)
    }

    /// The chunk and raw offset of every phrase-rule occurrence, read the slow way (the reference).
    private func r7Reference(_ env: Env, _ id: UUID) async throws -> [(chunk: Int, offset: Int)] {
        let chunks = try await env.store.searchChunks(emailID: id, kind: .attachmentText, ordinal: 0)
        var out: [(Int, Int)] = []
        for (index, chunk) in chunks.enumerated() {
            for r in SectionBoundary.phraseRanges(of: "quarterly results", in: chunk) { out.append((index, r.location)) }
        }
        return out
    }

    /// R7 (1): the chip's evidence carries the matched span; Show text opens
    /// there with the query in the field, every occurrence marked and the one
    /// at the span current — not at the start of the text.
    func testR7_showTextOpensAtTheMatchedSpanWithTheQuery() async throws {
        let (env, email, _) = try await r7Archive()
        let reference = try await r7Reference(env, email.id)
        XCTAssertEqual(reference.count, 3, "the fixture holds three occurrences: \(reference)")
        XCTAssertGreaterThanOrEqual(reference[0].chunk, 2, "the first occurrence is well inside the text")

        var group = AttachmentConditionGroup()
        group.content = "quarterly results"
        group.contentMatch = .phrase
        let spec = SearchSpec(groups: [SearchGroup(.all, attachments: [group])])
        let evidence = try await env.store.matchEvidence(emailID: email.id, spec: spec, freeText: nil)
        let item = try XCTUnwrap(evidence.first { MatchEvidenceChips.attachmentOrdinal($0.location) == 0 }, "\(evidence)")
        let anchor = try XCTUnwrap(item.anchor, "the evidence says where the match is")
        XCTAssertEqual(anchor.chunk, reference[0].chunk)
        XCTAssertEqual(anchor.offset, reference[0].offset)
        XCTAssertEqual(anchor.query, "quarterly results")

        let text = try XCTUnwrap(MatchEvidenceChips.evidenceText(item), "an attachment chip with a located match offers Show text")
        XCTAssertEqual(text.ordinal, 0); XCTAssertEqual(text.position, 0); XCTAssertEqual(text.filename, "report.txt")
        let viewer = ExtractedTextViewerModel(source: StoredExtractedTextSource(store: env.store, emailID: email.id, ordinal: 0),
                                              target: text.target)
        await viewer.open()
        XCTAssertEqual(viewer.query, "quarterly results", "the find field holds the search's query, not an empty string")
        XCTAssertEqual(viewer.total, 3)
        XCTAssertEqual(viewer.current, 0)
        let window = try XCTUnwrap(viewer.window)
        XCTAssertTrue(window.contains(anchor.chunk))
        XCTAssertEqual(viewer.marks(inChunk: anchor.chunk).current?.location, anchor.offset, "the match in view is the search's span")
        let scrolled = try XCTUnwrap(viewer.scrollTarget)
        XCTAssertEqual(viewer.segments.first { $0.id == scrolled }?.chunk, anchor.chunk, "the sheet scrolls to the span's block")
        XCTAssertFalse(viewer.marks(inChunk: anchor.chunk).all.isEmpty, "every occurrence is marked")

        // A target at a later occurrence opens on that one.
        let later = ExtractedTextTarget(query: "quarterly results", chunk: reference[1].chunk, offset: reference[1].offset, length: 17)
        let second = ExtractedTextViewerModel(source: StoredExtractedTextSource(store: env.store, emailID: email.id, ordinal: 0), target: later)
        await second.open()
        XCTAssertEqual(second.current, 1)
    }

    /// R7 (1): Next / Previous step through every occurrence of the document, in order, wrapping.
    func testR7_nextAndPreviousMoveBetweenAllMatches() async throws {
        let (env, email, _) = try await r7Archive()
        let reference = try await r7Reference(env, email.id)
        let viewer = ExtractedTextViewerModel(source: StoredExtractedTextSource(store: env.store, emailID: email.id, ordinal: 0),
                                              target: ExtractedTextTarget(query: "quarterly results", chunk: reference[0].chunk,
                                                                          offset: reference[0].offset, length: 17))
        await viewer.open()
        func focused() -> (Int, Int)? {
            for chunk in viewer.window ?? 0...0 { if let r = viewer.marks(inChunk: chunk).current { return (chunk, r.location) } }
            return nil
        }
        XCTAssertEqual(viewer.current, 0)
        await viewer.next()
        XCTAssertEqual(viewer.current, 1)
        XCTAssertTrue(focused().map { $0 == (reference[1].chunk, reference[1].offset) } ?? false, "\(String(describing: focused()))")
        await viewer.next()
        XCTAssertEqual(viewer.current, 2)
        XCTAssertTrue(focused().map { $0 == (reference[2].chunk, reference[2].offset) } ?? false)
        await viewer.next()
        XCTAssertEqual(viewer.current, 0, "Next after the last wraps to the first")
        await viewer.previous()
        XCTAssertEqual(viewer.current, 2, "Previous before the first wraps to the last")
        await viewer.previous()
        XCTAssertEqual(viewer.current, 1)

        // Typing another query counts again over the whole text.
        viewer.query = "QUARTERLY RESULTS"
        await viewer.recount(fromTarget: false)
        XCTAssertEqual(viewer.total, 3, "ASCII case folds, as in search")
        viewer.query = "nowhere phrase"
        await viewer.recount(fromTarget: false)
        XCTAssertEqual(viewer.total, 0)
    }

    /// R7 (2): the viewer reads only the chunks around the one in view — never
    /// the whole text — and holds at most three; the counts come per chunk.
    func testR7_pagedLoaderReadsOnlyNearbyChunks() async throws {
        let (env, email, _) = try await r7Archive()
        let outlineRead = try await env.store.attachmentDocumentOutline(emailID: email.id, ordinal: 0)
        let outline = try XCTUnwrap(outlineRead)
        XCTAssertGreaterThanOrEqual(outline.chunkCount, 5)
        let reference = try await r7Reference(env, email.id)
        let countsRead = try await env.store.attachmentDocumentMatchCounts(emailID: email.id, ordinal: 0, kind: .attachmentText,
                                                                           literal: "quarterly results")
        let counts = try XCTUnwrap(countsRead)
        XCTAssertEqual(counts.count, outline.chunkCount, "one count per chunk")
        for (chunk, n) in counts.enumerated() {
            XCTAssertEqual(n, reference.filter { $0.chunk == chunk }.count, "chunk \(chunk)")
        }

        let anchorChunk = reference[0].chunk
        let viewer = ExtractedTextViewerModel(source: StoredExtractedTextSource(store: env.store, emailID: email.id, ordinal: 0),
                                              target: ExtractedTextTarget(query: "quarterly results", chunk: anchorChunk,
                                                                          offset: reference[0].offset, length: 17))
        await viewer.open()
        XCTAssertFalse(viewer.requestedRanges.isEmpty)
        for range in viewer.requestedRanges {
            XCTAssertGreaterThanOrEqual(range.lowerBound, anchorChunk - ExtractedTextViewerModel.windowRadius, "\(viewer.requestedRanges)")
            XCTAssertLessThanOrEqual(range.upperBound, anchorChunk + ExtractedTextViewerModel.windowRadius, "\(viewer.requestedRanges)")
        }
        XCTAssertFalse(viewer.requestedRanges.contains { $0.contains(0) }, "the start of the text is not read to open in the middle")
        XCTAssertLessThanOrEqual(viewer.loadedChunks.count, 3)
        XCTAssertTrue(viewer.canShowEarlier)
        await viewer.showEarlier()
        XCTAssertLessThanOrEqual(viewer.loadedChunks.count, 3, "paging drops the far chunks")
        XCTAssertEqual(viewer.window?.upperBound, anchorChunk - 1, "the window moved one page earlier and kept its first chunk")

        // The display hides the boundary character but the marks keep their place.
        let display = ExtractedTextViewerModel.displayText("a\u{1E}bc\u{1E}de")
        XCTAssertEqual(display.text, "abcde")
        XCTAssertEqual(display.map(NSRange(location: 5, length: 2)), NSRange(location: 3, length: 2))
    }

    /// R7 (2): whether Show text exists is one EXISTS on the document row; the
    /// button no longer joins the whole text to decide.
    func testR7_existenceQueryDoesNotLoadText() async throws {
        let (env, email, text) = try await r7Archive()
        let has = try await env.store.attachmentDocumentHasText(emailID: email.id, ordinal: 0)
        XCTAssertTrue(has)
        let none = try await env.store.attachmentDocumentHasText(emailID: email.id, ordinal: 1)
        XCTAssertFalse(none)
        let outlineRead = try await env.store.attachmentDocumentOutline(emailID: email.id, ordinal: 0)
        let outline = try XCTUnwrap(outlineRead)
        XCTAssertEqual(outline.kind, .attachmentText)
        XCTAssertEqual(outline.characters, text.count, "the size comes from the document row")
        let archiveHas = await env.archive.attachmentDocumentHasText(emailID: email.id, ordinal: 0)
        XCTAssertTrue(archiveHas)

        // Source guard: neither the button nor the sheet reads the joined text.
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let sheet = try String(contentsOf: repo.appendingPathComponent("maxmailin/ExtractedTextSheet.swift"), encoding: .utf8)
        XCTAssertFalse(sheet.contains("attachmentDocumentText("), "Show text never loads the whole text")
        XCTAssertTrue(sheet.contains("attachmentDocumentHasText("))
    }

    /// R7 (3): the sheet's find is the search's phrase rule — a phrase wrapped
    /// over a line or a double space is found, one across a section boundary
    /// is not, ASCII letters fold case and nothing else does — and agrees with
    /// `mailin_phrase` on every case.
    func testR7_findUsesThePhraseRule() {
        let wrapped = "The quarterly\n   results were good."
        XCTAssertEqual(ExtractedTextSheet.ranges(of: "quarterly results", in: wrapped).count, 1, "a wrapped phrase is found")
        XCTAssertEqual(ExtractedTextSheet.ranges(of: "quarterly results", in: "quarterly\t\u{1E}results").count, 0,
                       "never across a section boundary")
        XCTAssertEqual(ExtractedTextSheet.ranges(of: "QUARTERLY Results", in: wrapped).count, 1)
        let cases: [(String, String)] = [
            (wrapped, "quarterly results"), ("quarterly\u{1E}results", "quarterly results"), ("a  b  a b", "a b"),
            ("Éclair", "éclair"), ("éclair", "éclair"), ("x\u{00A0}y", "x y"), ("cost: $5", "$5"), ("foo.bar", "foo bar"),
            ("[Sheet: Q3]\n\u{1E}total\t\u{1E}42", "total 42"), ("nothing", "  "),
        ]
        for (text, literal) in cases where !literal.trimmingCharacters(in: .whitespaces).isEmpty {
            XCTAssertEqual(!ExtractedTextSheet.ranges(of: literal, in: text).isEmpty, SectionBoundary.contains(text, literal: literal),
                           "“\(literal)” in “\(text)” — the viewer and the search agree")
        }
        XCTAssertTrue(ExtractedTextSheet.ranges(of: "  ", in: "anything").isEmpty)
        // A phrase across a chunk join is found once and belongs to the chunk it starts in.
        let regex = try! XCTUnwrap(SectionBoundary.phraseRegex("quarterly results"))
        let first = PhraseChunks.matches(in: "the quarterly ", previous: nil, next: "results here", regex: regex)
        let second = PhraseChunks.matches(in: "results here", previous: "the quarterly ", next: nil, regex: regex)
        XCTAssertEqual(first.starting.count + second.starting.count, 1)
        XCTAssertEqual(first.starting.count, 1)
        XCTAssertEqual(second.marks.first?.location, 0, "its end is still marked in the next chunk")
    }

    /// R7 (4): a failed child-state read is "not known", never "none".
    func testR7_coverageUnknownWhenTheChildQueryFails() async throws {
        let env = try makeEnv()
        _ = try AttachmentCoverageStore(url: await env.store.attachmentCoverageURL)
        struct Broken: Error {}
        let broken = await AttachmentTextIndexJob.coverageSummary(store: env.store, scope: nil) { _ in throw Broken() }
        let summary = try XCTUnwrap(broken)
        XCTAssertNil(summary.childCounts, "unknown, not an empty dictionary")
        let notice = AttachmentTextIndexJob.noMatchNotice(summary)
        XCTAssertTrue(notice.contains("could not be read") && notice.contains("not known"), notice)
        let fineRead = await AttachmentTextIndexJob.coverageSummary(store: env.store)
        let fine = try XCTUnwrap(fineRead)
        XCTAssertEqual(fine.childCounts, [:])
        XCTAssertFalse(AttachmentTextIndexJob.noMatchNotice(fine).contains("not known"))
    }

    /// R7 (4): with the search's scope the files-inside counts are that
    /// scope's; without one they are labelled archive-wide.
    func testR7_childCountsAreScopedToTheSearch() async throws {
        let env = try makeEnv()
        var old = makeEmail(tag: "r7s", i: 1, year: 2023, body: "old")
        old.attachments = [AttachmentMetadata(filename: "old.zip", mimeType: "application/zip", size: 10)]
        var new = makeEmail(tag: "r7s", i: 2, year: 2025, body: "new")
        new.attachments = [AttachmentMetadata(filename: "new.zip", mimeType: "application/zip", size: 10)]
        try await seed(env, [old, new])
        func child(_ email: MBOXParser.RawEmail, _ index: Int, _ state: String) -> AttachmentChildRow {
            AttachmentChildRow(emailID: email.id, position: 0, childIndex: index, path: "f\(index)", filename: "f\(index).bin",
                               kind: "bin", sha256: "", bytes: 1, state: state, note: nil)
        }
        try await env.store.recordAttachmentChildren(emailID: old.id, position: 0, children: [child(old, 0, "locked")],
                                                     texts: [:], states: [0: .locked], extractorVersion: 10)
        try await env.store.recordAttachmentChildren(emailID: new.id, position: 0,
                                                     children: [child(new, 0, "locked"), child(new, 1, "unsupported")],
                                                     texts: [:], states: [0: .locked, 1: .unsupported], extractorVersion: 10)
        _ = try AttachmentCoverageStore(url: await env.store.attachmentCoverageURL)

        var scope = EmailQuery()
        scope.afterDate = utcDate(2025, 1, 1)
        let scoped = try await env.store.attachmentChildStateCounts(scope: scope)
        XCTAssertEqual(scoped, ["locked": 1, "unsupported": 1])
        let wide = try await env.store.attachmentChildStateCounts()
        XCTAssertEqual(wide, ["locked": 2, "unsupported": 1])

        let inScopeRead = await AttachmentTextIndexJob.coverageSummary(store: env.store, scope: scope)
        let inScope = try XCTUnwrap(inScopeRead)
        XCTAssertEqual(inScope.childScope, .search)
        let scopedNotice = AttachmentTextIndexJob.noMatchNotice(inScope)
        XCTAssertTrue(scopedNotice.contains("in this search's scope: 1 locked, 1 not read"), scopedNotice)
        let archiveRead = await AttachmentTextIndexJob.coverageSummary(store: env.store)
        let archive = try XCTUnwrap(archiveRead)
        XCTAssertEqual(archive.childScope, .archive)
        let wideNotice = AttachmentTextIndexJob.noMatchNotice(archive)
        XCTAssertTrue(wideNotice.contains("across the whole archive: 2 locked, 1 not read"), wideNotice)
    }

    /// R7 (5): the reader upgrade's re-read is a record of THIS archive, in its
    /// store directory, written when the pass finished, with read / unread counts.
    func testR7_rebuildRecordWrittenOnlyOnCompletionAndPerArchive() async throws {
        let a = try makeEnv(), b = try makeEnv()
        let dirA = AttachmentTextIndexJob.rebuildDirectory(store: a.store), dirB = AttachmentTextIndexJob.rebuildDirectory(store: b.store)
        XCTAssertNotEqual(dirA, dirB)
        AttachmentTextIndexJob.recordRebuild(requeued: 5, in: dirA)
        XCTAssertNil(AttachmentTextIndexJob.rebuildRecord(in: dirA), "queued is not re-read: nothing is reported before the pass finishes")
        AttachmentTextIndexJob.completeRebuild(in: dirA, stillUnread: 2)
        let record = try XCTUnwrap(AttachmentTextIndexJob.rebuildRecord(in: dirA))
        XCTAssertEqual(record.messagesRequeued, 5); XCTAssertEqual(record.completed, 3); XCTAssertEqual(record.failed, 2)
        XCTAssertNil(AttachmentTextIndexJob.rebuildRecord(in: dirB), "another archive has its own record")
        let report = try XCTUnwrap(AttachmentTextIndexJob.rebuildReportText(record))
        XCTAssertTrue(report.contains("5 messages") && report.contains("3 read") && report.contains("2 still unread"), report)
        // Completing again without new work changes nothing.
        AttachmentTextIndexJob.completeRebuild(in: dirA, stillUnread: 0)
        XCTAssertEqual(AttachmentTextIndexJob.rebuildRecord(in: dirA), record)

        // Through the job: the pass that finishes on archive B writes B's record.
        let ocrWas = AttachmentOCR.isEnabled
        defer {
            AttachmentOCR.isEnabled = ocrWas
            AttachmentTextIndexJob.testStoreOverride = nil
            AttachmentTextIndexJob.testSuppressKicks = false
        }
        AttachmentTextIndexJob.testSuppressKicks = true
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()
        AttachmentTextIndexJob.testStoreOverride = b.store
        AttachmentOCR.isEnabled = false
        try await seed(b, [makeEmail(tag: "r7b", i: 1, year: 2025, body: "x")])
        AttachmentTextIndexJob.recordRebuild(requeued: 4, in: dirB)
        _ = await AttachmentTextIndexJob.shared.run()
        let fromJob = try XCTUnwrap(AttachmentTextIndexJob.rebuildRecord(in: dirB), "the finished pass writes the record")
        XCTAssertEqual(fromJob.messagesRequeued, 4); XCTAssertEqual(fromJob.failed, 0)
        XCTAssertEqual(AttachmentTextIndexJob.rebuildRecord(in: dirA), record, "archive A's record is untouched")
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()
    }
}

// MARK: - v4.0 SEARCH-01…03 — Advanced Search across tiers, one serialised spec, honest scope and coverage

extension V2SearchTests {

    /// Two messages either side of midnight in India on 10/11 March 2024:
    /// 17:00 UTC is 22:30 IST on the 10th, 19:00 UTC is 00:30 IST on the 11th.
    private static func searchDayPair() throws -> (late10: MBOXParser.RawEmail, early11: MBOXParser.RawEmail) {
        (try ipadMessage("ist-10", subject: "Evening ledger", body: "Ledger close.", attachment: nil,
                         date: "Sun, 10 Mar 2024 17:00:00 +0000"),
         try ipadMessage("ist-11", subject: "Midnight ledger", body: "Ledger open.", attachment: nil,
                         date: "Sun, 10 Mar 2024 19:00:00 +0000"))
    }

    /// Every ID a query reaches, page by page (no cap).
    private func searchAllIDs(_ archive: ArchiveDataService, _ query: EmailQuery) async throws -> [UUID] {
        var ids: [UUID] = []
        var cursor: EmailPageCursor? = nil
        repeat {
            let page = try await archive.page(query: query, cursor: cursor, limit: 3)
            ids += page.summaries.map(\.id)
            cursor = page.nextCursor
        } while cursor != nil
        return ids
    }

    private static func searchBattery() -> [(name: String, spec: SearchSpec)] {
        [
            ("all-anywhere", SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.anyText, .allWords, "lighthouse")])])),
            ("any", SearchSpec(groups: [SearchGroup(.any, [SearchCondition(.anyText, .phrase, "zebracrossing"),
                                                           SearchCondition(.subject, .phrase, "Routine 1")])])),
            ("exclude", SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.hasAttachments, .equals, "yes")]),
                                            SearchGroup(.exclude, [SearchCondition(.anyText, .allWords, "lighthouse")])])),
            ("same-attachment", SearchSpec(groups: [SearchGroup(.all, attachments: [
                AttachmentConditionGroup(nameContains: "Notes", contentMatch: .phrase, content: "lighthouse renovations")])])),
            ("same-attachment-mismatch", SearchSpec(groups: [SearchGroup(.all, attachments: [
                AttachmentConditionGroup(nameContains: "Notes", contentMatch: .phrase, content: "zebracrossing")])])),
            ("whole-day-IST", SearchSpec(groups: [SearchGroup(.all, [
                SearchCondition(.dateOnOrAfter, .equals, "2024-03-11", timeZone: "Asia/Kolkata"),
                SearchCondition(.dateOnOrBefore, .equals, "2024-03-11", timeZone: "Asia/Kolkata")])])),
            ("sql-text", SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.anyText, .contains, "'; DROP TABLE emails; --")])])),
            ("sql-name", SearchSpec(groups: [SearchGroup(.any, [SearchCondition(.attachmentName, .contains, "\" OR 1=1 --"),
                                                                SearchCondition(.sender, .contains, "x') OR ('1'='1")])])),
        ]
    }

    private struct TierAnswer: Equatable {
        var ids: [UUID]
        var unresolved: Int
        var evidence: [UUID: [MatchEvidence]]
        var coverage: SearchCoverageSnapshot?
        var childCounts: [String: Int]?
    }

    /// SEARCH-01 (plan §8.3, RQ06/RQ08): the same SearchSpec on the same
    /// permitted data gives identical IDs, evidence and coverage under Free,
    /// Personal, Pro, lifetime and lapsed (LIFE-06) — no tier unlocks a search
    /// capability; the AI is off and nothing leaves the device.
    func testSEARCH01_sameSpecSameDataGivesIdenticalAnswersOnEveryTier() async throws {
        let wasOn = SearchChunkPolicy.isEnabled
        let ocrWas = AttachmentOCR.isEnabled
        defer {
            SearchChunkPolicy.isEnabled = wasOn
            AttachmentOCR.isEnabled = ocrWas
            AttachmentTextIndexJob.testStoreOverride = nil
            AttachmentTextIndexJob.testSuppressKicks = false
        }
        let pair = try Self.searchDayPair()
        let (env, docx, zip) = try await ipadArchive(extra: [pair.late10, pair.early11])
        let stored = try await env.archive.unscopedCount()
        XCTAssertLessThanOrEqual(stored, StoreManager.freeEmailLimit, "the dataset is one Free may access in full")

        let tiers: [EntitlementState] = [.free, .active(.personal), .active(.professional),
                                         .lifetime(.personal), .lapsed(previous: .professional), .lapsed(previous: .personal)]
        var reference: [String: TierAnswer] = [:]
        for state in tiers {
            env.archive.accessLimit = AccessPolicy(state: state).archiveReadLimit
            for (name, spec) in Self.searchBattery() {
                XCTAssertTrue(spec.isValid, name)
                var query = EmailQuery()
                query.spec = spec
                let ids = try await searchAllIDs(env.archive, query)
                var evidence: [UUID: [MatchEvidence]] = [:]
                for id in ids { evidence[id] = try await env.archive.matchEvidence(emailID: id, spec: spec, freeText: nil) }
                var coverage = await ModelSearchNotice.snapshot(archive: env.archive, scope: query)
                coverage?.takenAt = .distantPast
                let unresolved = try await env.archive.unresolvedCount(query: query)
                let answer = TierAnswer(ids: ids, unresolved: unresolved, evidence: evidence,
                                        coverage: coverage, childCounts: coverage?.attachments?.childCounts)
                if let first = reference[name] {
                    XCTAssertEqual(answer, first, "\(name) under \(state) differs from the first tier")
                } else {
                    reference[name] = answer
                }
            }
        }
        env.archive.accessLimit = nil
        // The battery is not vacuous: each case found what it should.
        XCTAssertEqual(reference["all-anywhere"]?.ids, [docx.id])
        XCTAssertTrue(reference["any"]?.ids.contains(zip.id) ?? false)
        XCTAssertEqual(reference["any"]?.ids.count, 2, "the phrase OR the subject")
        XCTAssertEqual(reference["exclude"]?.ids, [zip.id])
        XCTAssertEqual(reference["same-attachment"]?.ids, [docx.id])
        XCTAssertEqual(reference["same-attachment-mismatch"]?.ids, [], "the words are in another message's file")
        XCTAssertEqual(reference["whole-day-IST"]?.ids, [pair.early11.id], "the day in the zone it was chosen in")
        XCTAssertEqual(reference["sql-text"]?.ids, [])
        XCTAssertEqual(reference["sql-name"]?.ids, [])
        XCTAssertTrue(reference["all-anywhere"]?.evidence[docx.id]?.contains {
            if case .attachmentText(_, let filename, _, _) = $0.location { return filename == "Notes.docx" }
            return false
        } ?? false, "evidence names the file")
        let after = try await env.archive.unscopedCount()
        XCTAssertEqual(after, stored, "SQL-looking text is data: nothing was dropped")

        // No tier lock on any entry point of the builder; no AI, no network in the search path.
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String { try String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8) }
        // (The list views keep the Free data-scope banner — a data rule, not a search lock.)
        for path in ["maxmailin/AdvancedSearchView.swift", "maxmailin/SearchSpecDescriber.swift",
                     "Packages/ArchiveCore/Sources/ArchiveCore/SearchSpec.swift",
                     "Packages/ArchiveCore/Sources/ArchiveCore/SearchSpecCompiler.swift",
                     "Packages/ArchiveCore/Sources/ArchiveCore/SearchMatchEvidence.swift",
                     "Packages/ArchiveCore/Sources/ArchiveCore/SearchSpecTransport.swift"] {
            let text = try source(path)
            for banned in ["isPremium", "allowsPaidWork", "requestPurchase(", "PaywallView", "isEnabled(.professional)",
                           "isEnabled(.aiInsights)", "URLSession", "FoundationModels", "LanguageModelSession"] {
                XCTAssertFalse(text.contains(banned), "\(path) must not contain \(banned)")
            }
        }
        let shell = try source("maxmailin/ArchiveThreePaneView.swift")
        XCTAssertTrue(shell.contains("if modules?.isOn(.searchQueryModel) ?? false {\n                        ToolbarItem {\n                            Button { showAdvancedSearch = true }"),
                      "the toolbar button follows the search switch only")
        XCTAssertFalse(shell.contains("requestPurchase("), "the shell never sells search")
        XCTAssertEqual(Capability.searchQueryModel.owner, .archive, "Advanced Search belongs to the Archive page, which is never optional")
        XCTAssertFalse(AppModule.archive.isOptional)
        XCTAssertEqual(EngineSpec.of(.searchQueryModel)?.maturity, .stable)
        XCTAssertTrue(try source("maxmailin/ArchiveListView.swift").contains("AdvancedSearchView("),
                      "the iPhone list offers the same builder")
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()
    }

    /// SEARCH-02: one serialised spec through the toolbar's builder, a saved
    /// search, the full list's copy of the saved searches and a recipe field;
    /// a newer spec is refused, never run as something else; the whole day in
    /// its zone survives and runs the same rows.
    func testSEARCH02_oneSerialisedSpecRoundTripsThroughToolbarSavedSearchesAndRecipes() async throws {
        let spec = SearchSpec(groups: [
            SearchGroup(.all, [SearchCondition(.sender, .contains, "alice"),
                               SearchCondition(.dateOnOrAfter, .equals, "2024-03-11", timeZone: "Asia/Kolkata"),
                               SearchCondition(.dateOnOrBefore, .equals, "2024-03-11", timeZone: "Asia/Kolkata")]),
            SearchGroup(.any, [SearchCondition(.anyText, .phrase, "purchase order", branch: 1),
                               SearchCondition(.anyText, .allWords, "urgent", branch: 1),
                               SearchCondition(.anyText, .anyWords, "receipt", negated: true)],
                        attachments: [AttachmentConditionGroup(nameContains: "PO", type: "PDF", contentMatch: .allWords, content: "total due")]),
            SearchGroup(.exclude, [SearchCondition(.tag, .equals, "Spam")]),
        ])
        // Text form.
        let text = SearchSpecTransport.encode(spec)
        XCTAssertTrue(text.hasPrefix(SearchSpecTransport.prefix))
        XCTAssertEqual(try SearchSpecTransport.decode(text), spec)
        XCTAssertEqual(SearchSpecTransport.encode(try SearchSpecTransport.decode(text)), text, "stable text")
        let decodedDay = try SearchSpecTransport.decode(text).groups[0].conditions[1]
        XCTAssertEqual(decodedDay.timeZone, "Asia/Kolkata")
        XCTAssertEqual(SearchSpec.parseDay(decodedDay.value, timeZone: decodedDay.timeZone)?.start,
                       SearchSpec.parseDay("2024-03-11", timeZone: "Asia/Kolkata")?.start)

        // The toolbar: the builder's normal form (three groups, fixed order) and a chip removal round-trip.
        let built = AdvancedSearchView.normalized(spec)
        XCTAssertEqual(built.groups.map(\.kind), [.all, .any, .exclude])
        XCTAssertEqual(built.liveGroups, spec.liveGroups, "the builder shows exactly the applied spec")
        XCTAssertEqual(try SearchSpecTransport.decode(SearchSpecTransport.encode(built)), built)
        let chipRemoved = built.removingCondition(group: 0, condition: 0)
        XCTAssertEqual(try SearchSpecTransport.decode(SearchSpecTransport.encode(chipRemoved)), chipRemoved)
        let fromSparse = AdvancedSearchView.normalized(SearchSpec(groups: [SearchGroup(.exclude, [SearchCondition(.tag, .equals, "x")])]))
        XCTAssertEqual(fromSparse.groups.map(\.kind), [.all, .any, .exclude])

        // Saved searches: kept with the spec, read back by a fresh store, kept by the full list's copy.
        let suite = "search02-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ArchiveSavedSearchStore(defaults: defaults)
        store.add(name: "POs", query: "", spec: spec)
        store.add(name: "", query: "  ", spec: nil)   // nothing to save
        XCTAssertEqual(store.searches.count, 1)
        let reread = ArchiveSavedSearchStore(defaults: defaults)
        let saved = try XCTUnwrap(reread.searches.first)
        XCTAssertEqual(saved.spec, spec)
        XCTAssertEqual(saved.name, "POs")
        XCTAssertEqual(saved.runnableQuery.spec, spec, "the saved search runs the spec it was saved with")
        let data = try XCTUnwrap(defaults.data(forKey: ArchiveSavedSearchStore.defaultsKey))
        let legacy = try JSONDecoder().decode([ParsedEmailListViewModel.SavedSearch].self, from: data)
        XCTAssertEqual(legacy.first?.spec, spec, "the full list's copy of the same key keeps the spec")
        let legacyAgain = try JSONDecoder().decode([ArchiveSavedSearch].self, from: JSONEncoder().encode(legacy))
        XCTAssertEqual(legacyAgain.first?.spec, spec, "re-saving from the full list does not strip it")
        let old = Data(#"[{"id":"\#(UUID().uuidString)","name":"old","query":"from:bob"}]"#.utf8)
        let oldDecoded = try JSONDecoder().decode([ArchiveSavedSearch].self, from: old)
        XCTAssertNil(oldDecoded.first?.spec, "searches saved before the spec still decode")
        XCTAssertEqual(oldDecoded.first?.runnableQuery, ArchiveQueryCompiler.compile("from:bob"))

        // Recipes: an encoded spec and typed words reach the same model.
        XCTAssertEqual(SearchSpecTransport.recipeQuery(value: text)?.spec, spec)
        var base = EmailQuery(); base.folderID = 7
        let scoped = try XCTUnwrap(SearchSpecTransport.recipeQuery(value: text, base: base))
        XCTAssertEqual(scoped.folderID, 7, "the recipe's scope stays outside the spec")
        XCTAssertEqual(SearchSpecTransport.spec(fromRecipeValue: "lighthouse"), PlainSearchTranslator.spec(from: "lighthouse"))
        XCTAssertNil(SearchSpecTransport.spec(fromRecipeValue: "   "))

        // A newer spec, or a damaged one, is refused — never a different query.
        let newer = SearchSpecTransport.prefix + #"{"groups":[],"version":99}"#
        XCTAssertThrowsError(try SearchSpecTransport.decode(newer)) { XCTAssertEqual($0 as? SearchSpecTransport.DecodeError, .newerVersion(99)) }
        XCTAssertNil(SearchSpecTransport.spec(fromRecipeValue: newer))
        XCTAssertThrowsError(try SearchSpecTransport.decode(SearchSpecTransport.prefix + "{not json")) {
            XCTAssertEqual($0 as? SearchSpecTransport.DecodeError, .malformed)
        }
        XCTAssertNil(SearchSpecTransport.spec(fromRecipeValue: SearchSpecTransport.prefix + "{not json"))

        // Executed: the decoded day spec selects the same rows as the original.
        let pair = try Self.searchDayPair()
        let env = try makeEnv()
        try await seed(env, [pair.late10, pair.early11])
        let day = SearchSpec(groups: [SearchGroup(.all, [spec.groups[0].conditions[1], spec.groups[0].conditions[2]])])
        var direct = EmailQuery(); direct.spec = day
        let viaRecipe = try XCTUnwrap(SearchSpecTransport.recipeQuery(value: SearchSpecTransport.encode(day)))
        let original = try await searchAllIDs(env.archive, direct)
        XCTAssertEqual(original, [pair.early11.id], "00:30 IST on the 11th is in the day; 22:30 IST on the 10th is not")
        let viaRecipeIDs = try await searchAllIDs(env.archive, viaRecipe)
        XCTAssertEqual(viaRecipeIDs, original)
    }

    /// SEARCH-02: a frozen execution selection is the rows matched at one
    /// revision; importing new matching mail changes the live search, not the
    /// frozen one — including the Free plan's newest-N window.
    func testSEARCH02_frozenSelectionDoesNotDriftWhenNewMailIsImported() async throws {
        let wasOn = SearchChunkPolicy.isEnabled
        defer { SearchChunkPolicy.isEnabled = wasOn }
        SearchChunkPolicy.isEnabled = true
        let env = try makeEnv()
        let first = (0..<4).map { makeEmail(tag: "frz", i: $0, year: 2020, body: "quarterly invoice \($0)") }
        try await seed(env, first + [makeEmail(tag: "frz-other", i: 9, year: 2019, body: "unrelated")])
        var live = EmailQuery()
        live.spec = SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.anyText, .allWords, "quarterly invoice")])])

        let maybeFrozen = try await FrozenSearchSelection.freeze(live, archive: env.archive)
        let frozen = try XCTUnwrap(maybeFrozen)
        XCTAssertNil(frozen.liveQuery.snapshotMaxRowID, "the live query stays live")
        XCTAssertNotNil(frozen.query.snapshotMaxRowID)
        let before = try await searchAllIDs(env.archive, frozen.query)
        XCTAssertEqual(Set(before), Set(first.map(\.id)))

        // New matching mail arrives (newer dates) after the selection was frozen.
        let later = (0..<2).map { makeEmail(tag: "frz-new", i: $0, year: 2026, body: "quarterly invoice late \($0)") }
        try await seed(env, later)
        let frozenAfter = try await searchAllIDs(env.archive, frozen.query)
        XCTAssertEqual(frozenAfter, before, "the frozen selection does not drift")
        let frozenCount = try await env.archive.count(query: frozen.query)
        XCTAssertEqual(frozenCount, 4)
        let liveAfter = try await searchAllIDs(env.archive, frozen.liveQuery)
        XCTAssertEqual(liveAfter.count, 6, "the live search sees the new mail")

        // It travels (recipes, export resume) and comes back the same.
        let decoded = try JSONDecoder().decode(FrozenSearchSelection.self, from: JSONEncoder().encode(frozen))
        XCTAssertEqual(decoded, frozen)
        let decodedIDs = try await searchAllIDs(env.archive, decoded.query)
        XCTAssertEqual(decodedIDs, before)

        // Under a tier window (Free's newest N; here N = 3) the window is frozen too.
        env.archive.accessLimit = 3
        defer { env.archive.accessLimit = nil }
        let maybeWindowed = try await FrozenSearchSelection.freeze(live, archive: env.archive)
        let windowed = try XCTUnwrap(maybeWindowed)
        let windowBefore = try await searchAllIDs(env.archive, windowed.query)
        XCTAssertEqual(windowBefore.count, 3)
        let newest = (0..<2).map { makeEmail(tag: "frz-newest", i: $0, year: 2027, body: "quarterly invoice newest \($0)") }
        try await seed(env, newest)
        let windowAfter = try await searchAllIDs(env.archive, windowed.query)
        XCTAssertEqual(windowAfter, windowBefore, "newer mail does not push frozen rows out of the Free window")
    }

    /// SEARCH-03: files inside attachments that could not be read (locked,
    /// unsupported, failed, partly read) make every partial and no-match case
    /// say so; the list's coverage line and both lists' no-match texts agree.
    func testSEARCH03_lockedAndUnreadFilesInsideAttachmentsAreNeverHidden() {
        let complete = SQLiteEmailStore.SearchDocCoverage(bodiesEvaluable: 8, emails: 8, attachmentsEvaluable: 2, attachments: 2, bodyChunks: 8)
        var summary = AttachmentCoverageSummary()
        summary.counts = [.extracted: 2]
        summary.childCounts = ["locked": 2, "unsupported": 1, "extracted": 4]
        summary.childScope = .search
        let snapshot = SearchCoverageSnapshot(storedMessages: 8, indexedMessages: 8, partiallyIndexedMessages: 0,
                                              chunks: complete, attachments: summary)
        XCTAssertTrue(snapshot.needsNotice, "a result list says files inside attachments were not searched")
        XCTAssertTrue(snapshot.summaryLine.contains("Files inside attachments, in this search's scope: 2 locked, 1 not read"), snapshot.summaryLine)
        let noMatch = ModelSearchNotice.noMatch(coverage: snapshot)
        XCTAssertFalse(noMatch.contains("Nothing in the fully indexed scope matches"), "not a complete-looking zero: \(noMatch)")
        XCTAssertTrue(noMatch.hasPrefix(String(localized: "No matches in the text that could be read")), noMatch)
        XCTAssertTrue(noMatch.contains("2 locked"), noMatch)
        XCTAssertEqual(ModelSearchNotice.headline(snapshot), String(localized: "No matches in the text that could be read"))

        // Unknown child states are unknown, never "none".
        summary.childCounts = nil
        let unknown = SearchCoverageSnapshot(storedMessages: 8, indexedMessages: 8, partiallyIndexedMessages: 0, chunks: complete, attachments: summary)
        XCTAssertTrue(unknown.needsNotice)
        XCTAssertTrue(ModelSearchNotice.noMatch(coverage: unknown).contains("not known"))

        // Attachments themselves partly read are named in the line.
        var partly = AttachmentCoverageSummary()
        partly.counts = [.extracted: 1, .partial: 1]
        partly.childCounts = [:]
        let partial = SearchCoverageSnapshot(storedMessages: 8, indexedMessages: 8, partiallyIndexedMessages: 0,
                                             chunks: SQLiteEmailStore.SearchDocCoverage(bodiesEvaluable: 8, emails: 8, attachmentsEvaluable: 1,
                                                                                        attachments: 2, bodyChunks: 8),
                                             attachments: partly)
        XCTAssertTrue(partial.summaryLine.contains("1 partly read"), partial.summaryLine)

        // Everything read: the complete wording, and nothing extra on a result list.
        var all = AttachmentCoverageSummary()
        all.counts = [.extracted: 2]
        all.childCounts = ["extracted": 3]
        let clean = SearchCoverageSnapshot(storedMessages: 8, indexedMessages: 8, partiallyIndexedMessages: 0, chunks: complete, attachments: all)
        XCTAssertFalse(clean.needsNotice)
        XCTAssertTrue(ModelSearchNotice.noMatch(coverage: clean).contains("Nothing in the fully indexed scope matches this search."))
        XCTAssertEqual(ModelSearchNotice.headline(nil), String(localized: "No matches — coverage could not be checked"))
    }

    /// SEARCH-03: the searched scope is stated — the sidebar row, the date
    /// range and, on Free, the newest-N window — and a Free search whose
    /// matches all lie outside the window never reads as "no matching emails".
    func testSEARCH03_activeScopeAndFreeWindowAreStatedForEveryNoMatch() {
        XCTAssertNil(ArchiveNoResultsState.scopeNote(accessLimit: nil, totalCount: 9, accessibleCount: 9), "paid and lapsed: the whole archive")
        XCTAssertEqual(ArchiveNoResultsState.scopeNote(accessLimit: 500, totalCount: 3, accessibleCount: 0),
                       String(localized: "\(3) matching emails are outside the newest \(500) emails the Free plan works with."))
        XCTAssertEqual(ArchiveNoResultsState.scopeNote(accessLimit: 500, totalCount: 0, accessibleCount: 0),
                       String(localized: "Searched the newest \(500) emails of your archive (Free plan)."))

        XCTAssertEqual(ArchiveThreePaneView.describeScope(title: "All Mail", dateScope: .all, accessLimit: nil), "All Mail")
        XCTAssertEqual(ArchiveThreePaneView.describeScope(title: "Inbox", dateScope: .days30, accessLimit: 500),
                       "Inbox · " + ArchiveDateScope.days30.rawValue + " · " + String(localized: "newest \(500) emails (Free plan)"))
    }
}
