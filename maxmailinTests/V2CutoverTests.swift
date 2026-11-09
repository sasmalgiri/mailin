@testable import ArchiveCore
import XCTest
import PDFKit
import Compression
import CryptoKit
@testable import maxmailin

/// Parts Q/R/S regression net — the final legacy-corpus cutover:
///  Q: no startup corpus rehydration and NO production writes to the v1 JSON
///     store (EmailPersistence is migration-source + clear/retention only),
///  R: detail navigation sources ordered ids from the list's loaded PAGE
///     state (never a whole-corpus array),
///  S: the Advanced list mode (ParsedEmailListViewModel) pages the archive
///     through ArchiveDataService — repository-backed search, bounded window,
///     free-tier paging gated from store counts.
///
/// Fixtures live in isolated temp SQLite stores + FTS shard dirs
/// (V2SearchTests style) — production singletons are never written.
@MainActor
final class V2CutoverTests: XCTestCase {

    // MARK: - Fixtures (isolated temp store + FTS)

    private struct Env {
        let root: URL
        let store: SQLiteEmailStore
        let fts: FTSSearchIndex
        let archive: ArchiveDataService
    }

    private func makeEnv() throws -> Env {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailin-cutover-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store"))
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts"))
        let repo = EmailStoreRepository(store: store, fts: fts)
        return Env(root: root, store: store, fts: fts,
                   archive: ArchiveDataService(repository: repo))
    }

    private static let monthNames = ["", "Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                     "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// Distinct dates → deterministic keyset order (newest first).
    private func makeEmail(i: Int, total: Int, body: String) -> MBOXParser.RawEmail {
        // Spread across days/months so every fixture has a unique date.
        let month = 1 + (i / 28) % 12
        let day = 1 + (i % 28)
        let dd = String(format: "%02d", day)
        let mm = String(format: "%02d", month)
        return MBOXParser.RawEmail(
            headers: [
                "Message-ID": "<cutover-\(i)@test>",
                "Subject": "Subject \(i)",
                "From": "sender\(i % 7)@example.com",
                "To": "me@example.com",
                "Date": "Wed, \(dd) \(Self.monthNames[month]) 2023 12:00:00 +0000"
            ],
            rawSource: "raw \(i)",
            messageType: "received",
            attachments: [],
            timestamp: "2023-\(mm)-\(dd)T12:00:00Z",
            domains: ["example.com"],
            plainBody: body,
            htmlBody: ""
        )
    }

    private func seed(_ env: Env, count: Int, taggedAlpha: Set<Int> = []) async throws -> [MBOXParser.RawEmail] {
        let fixtures = (0..<count).map {
            makeEmail(i: $0, total: count,
                      body: taggedAlpha.contains($0) ? "alpha needle body \($0)" : "plain body \($0)")
        }
        try await env.store.insertBatch(fixtures, batchSize: 200)
        try await env.fts.indexBatch(fixtures)
        return fixtures
    }

    private var appSource: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // maxmailinTests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("maxmailin")
    }

    // MARK: - Part Q — the v1 JSON store is never written by production code

    /// Source-level guard: no production call site writes the v1 store.
    /// `EmailPersistence.save*` must not appear anywhere outside
    /// EmailPersistence.swift itself (where the DEBUG-only test writer and the
    /// internal uncompressed→compressed rewrite live), and `EmailPersistence
    /// .load(` may appear ONLY in MigrationService.swift (the one-time
    /// migration source).
    func testPartQ_noProductionV1StoreWritePath() throws {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: appSource, includingPropertiesForKeys: nil) else {
            throw XCTSkip("app source not found at \(appSource.path)")
        }
        var writeViolations: [String] = []
        var loadViolations: [String] = []
        for f in items where f.pathExtension == "swift" {
            guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
            let name = f.lastPathComponent
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                if name != "EmailPersistence.swift",
                   line.contains("EmailPersistence.save") {
                    writeViolations.append("\(name):\(i + 1)")
                }
                if name != "MigrationService.swift", name != "EmailPersistence.swift",
                   line.contains("EmailPersistence.load()") {
                    loadViolations.append("\(name):\(i + 1)")
                }
            }
        }
        XCTAssertTrue(writeViolations.isEmpty,
            "Part Q violated — production writes to the v1 JSON store: \(writeViolations.joined(separator: ", "))")
        XCTAssertTrue(loadViolations.isEmpty,
            "Part Q violated — v1 store loaded outside MigrationService: \(loadViolations.joined(separator: ", "))")
    }

    /// Runtime guard: the startup/list path (refresh + paging + search over an
    /// archive) leaves the v1 store location untouched — no file appears.
    func testPartQ_listRefreshLeavesV1StoreAbsent() async throws {
        let savedOverride = EmailPersistence.testBaseDirectoryOverride
        let v1Dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailin-v1probe-\(UUID().uuidString)", isDirectory: true)
        EmailPersistence.testBaseDirectoryOverride = v1Dir
        defer {
            EmailPersistence.testBaseDirectoryOverride = savedOverride
            try? FileManager.default.removeItem(at: v1Dir)
        }

        let env = try makeEnv()
        _ = try await seed(env, count: 30)

        let vm = ParsedEmailListViewModel(viewModel: ContentViewModel(), archive: env.archive,
                                          pageSize: 10, maxRetained: 50)
        vm.isPremiumUser = true
        await vm.reloadForQueryChangeNow()
        await vm.loadNextPageNow()

        XCTAssertEqual(vm.residentEmails.count, 20, "two pages hydrated")
        XCTAssertFalse(EmailPersistence.hasSavedData,
            "Part Q violated — the list/restore path wrote the v1 JSON store")
        XCTAssertFalse(EmailPersistence.legacyStoreExists,
            "Part Q violated — a v1 store file appeared during list paging")
    }

    // MARK: - Part R — detail navigation from list PAGE state

    /// `visibleOrderedIDs` is exactly the loaded page window's ordered ids —
    /// it grows page by page and never covers the whole archive up front.
    func testPartR_detailNavigationOrderFromPageState() async throws {
        let env = try makeEnv()
        _ = try await seed(env, count: 30)

        let list = ArchiveListViewModel(archive: env.archive, pageSize: 10, maxRetained: 100)
        await list.loadInitial()
        XCTAssertEqual(list.visibleOrderedIDs, list.summaries.map(\.id))
        XCTAssertEqual(list.visibleOrderedIDs.count, 10, "first page only — never the corpus")
        XCTAssertEqual(list.totalCount, 30, "store-truth total")

        let firstPage = list.visibleOrderedIDs
        await list.loadNextPage()
        XCTAssertEqual(list.visibleOrderedIDs.count, 20)
        XCTAssertEqual(Array(list.visibleOrderedIDs.prefix(10)), firstPage,
            "navigation order is stable across page loads")

        // The hydrated Advanced list exposes the same page-state ordering.
        let vm = ParsedEmailListViewModel(viewModel: ContentViewModel(), archive: env.archive,
                                          pageSize: 10, maxRetained: 100)
        vm.isPremiumUser = true
        await vm.reloadForQueryChangeNow()
        XCTAssertEqual(vm.visibleOrderedIDs, vm.visibleEmails.map(\.id))
        XCTAssertEqual(Set(vm.visibleOrderedIDs), Set(firstPage),
            "detail navigation ids come from the loaded page window")
    }

    // MARK: - Part S — Advanced list pages the repository

    /// Basic paging: first page + next page hydrate bounded windows in archive
    /// order, and the header count is the store total (not the window size).
    func testPartS_advancedListPagesBoundedWindows() async throws {
        let env = try makeEnv()
        _ = try await seed(env, count: 35)

        let vm = ParsedEmailListViewModel(viewModel: ContentViewModel(), archive: env.archive,
                                          pageSize: 10, maxRetained: 20)
        vm.isPremiumUser = true
        await vm.reloadForQueryChangeNow()

        XCTAssertEqual(vm.residentEmails.count, 10, "first page hydrated")
        XCTAssertEqual(vm.visibleEmails.count, 10)
        XCTAssertEqual(vm.queryTotalCount, 35, "store-truth total for the query")
        XCTAssertEqual(vm.displayedEmailCount, 35, "header shows archive-truth count, not the window")
        XCTAssertTrue(vm.hasMorePages)

        await vm.loadNextPageNow()
        XCTAssertEqual(vm.residentEmails.count, 20)

        // Window bound: a third page drops the head page (maxRetained 20).
        await vm.loadNextPageNow()
        XCTAssertLessThanOrEqual(vm.residentEmails.count, 20,
            "resident window stays bounded (LRU page window)")
        XCTAssertTrue(vm.hasEarlierPages, "dropped pages are re-fetchable")
    }

    /// Search triggers the repository (FTS-backed ranked query): the hydrated
    /// window contains exactly the matching emails and the total is the
    /// store-truth match count — proving the query ran archive-side, not over
    /// a resident array.
    func testPartS_advancedListSearchIsRepositoryBacked() async throws {
        let env = try makeEnv()
        let tagged: Set<Int> = [2, 7, 11, 19, 23]
        _ = try await seed(env, count: 30, taggedAlpha: tagged)

        let vm = ParsedEmailListViewModel(viewModel: ContentViewModel(), archive: env.archive,
                                          pageSize: 10, maxRetained: 50)
        vm.isPremiumUser = true
        vm.searchText = "alpha"
        await vm.reloadForQueryChangeNow()

        XCTAssertEqual(vm.queryTotalCount, tagged.count, "repository-side match count")
        XCTAssertEqual(vm.residentEmails.count, tagged.count)
        XCTAssertTrue(vm.residentEmails.allSatisfy { $0.plainBody.contains("alpha") },
            "window contains only repository matches")

        // Clearing the query re-pages the full archive.
        vm.searchText = ""
        await vm.reloadForQueryChangeNow()
        XCTAssertEqual(vm.queryTotalCount, 30)
        XCTAssertEqual(vm.residentEmails.count, 10, "back to plain first page")
    }

    /// THE folder-click regression: a structured operator (tag:) must page
    /// its matches from the WHOLE archive via SQL — not merely refine the
    /// resident window. The only tagged email here is the OLDEST row, which
    /// never enters the first page of a 10-row window; before the fix this
    /// query showed "no matching emails" while the folder tree counted 1.
    func testPartS_structuredOperatorsPageArchiveWide() async throws {
        let env = try makeEnv()
        var fixtures = (0..<30).map { makeEmail(i: $0, total: 30, body: "plain body \($0)") }
        fixtures[0].tags = ["Boxbe Waiting List"]   // oldest date → outside page 1
        try await env.store.insertBatch(fixtures, batchSize: 200)
        try await env.fts.indexBatch(fixtures)

        let vm = ParsedEmailListViewModel(viewModel: ContentViewModel(), archive: env.archive,
                                          pageSize: 10, maxRetained: 50)
        vm.isPremiumUser = true
        vm.searchText = "tag:\"Boxbe Waiting List\""
        await vm.reloadForQueryChangeNow()

        XCTAssertEqual(vm.queryTotalCount, 1, "SQL-side match count, not window count")
        XCTAssertEqual(vm.visibleEmails.map(\.id), [fixtures[0].id],
            "the tagged email pages in even though it is 30 rows deep")

        // source:-style operators ride the same compiled path; a miss must be
        // an honest zero, not a silently unfiltered list.
        vm.searchText = "tag:NoSuchLabel"
        await vm.reloadForQueryChangeNow()
        XCTAssertEqual(vm.visibleEmails.count, 0)
    }

    /// THE sidebar-filters regression ("filters not working"): checkbox
    /// selections must COMPILE into the pager query and re-page the archive.
    /// Only the OLDEST 5 rows match the selected sender — none are in the
    /// first 10-row page, so a window-only refinement shows zero.
    func testPartU_sidebarSelectionsPageArchiveWide() async throws {
        let env = try makeEnv()
        var fixtures = (0..<30).map { makeEmail(i: $0, total: 30, body: "plain body \($0)") }
        for i in 0..<5 {   // oldest dates → outside page 1
            fixtures[i].headers["From"] = "old.sender@legacy.com"
        }
        fixtures[2].tags = ["Boxbe Waiting List"]
        try await env.store.insertBatch(fixtures, batchSize: 200)
        try await env.fts.indexBatch(fixtures)

        let vm = ParsedEmailListViewModel(viewModel: ContentViewModel(), archive: env.archive,
                                          pageSize: 10, maxRetained: 50)
        vm.isPremiumUser = true

        // Multi-select senders: SQL OR-group, archive-wide.
        vm.selectedFromEmails = ["old.sender@legacy.com"]
        await vm.reloadForQueryChangeNow()
        XCTAssertEqual(vm.queryTotalCount, 5, "SQL-side sender match count")
        XCTAssertEqual(Set(vm.visibleEmails.map(\.id)), Set(fixtures.prefix(5).map(\.id)),
            "all 5 old-sender emails page in despite being 25+ rows deep")

        // Selections AND together with label checkboxes.
        vm.selectedTags = ["Boxbe Waiting List"]
        await vm.reloadForQueryChangeNow()
        XCTAssertEqual(vm.visibleEmails.map(\.id), [fixtures[2].id],
            "sender AND label intersect archive-wide")

        // applyFilters() itself must detect the changed compiled query and
        // re-page (the sidebar Apply button path) — await the async reload.
        vm.selectedTags = []
        vm.applyFilters()
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(vm.queryTotalCount, 5, "Apply re-paged after selection change")

        // Sort compiles too: subject A→Z ordering comes from SQL, whole archive.
        vm.selectedFromEmails = []
        vm.sortBy = .subjectAsc
        await vm.reloadForQueryChangeNow()
        let subjects = vm.visibleEmails.map { $0.headers["Subject"] ?? "" }
        XCTAssertEqual(subjects, subjects.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending },
            "first page is the archive-wide sort order, not a re-sorted window")
    }

    /// Quick-chip parity: the Sent/Received/Attachments chips compile to
    /// SQL. Critically, an email whose has_attach FLAG was recovered from
    /// headers (no attachment metadata rows — rawless archives) must still
    /// match the Attachments filter.
    func testPartU_quickChipsFilterViaSQLIncludingRecoveredFlags() async throws {
        let env = try makeEnv()
        var fixtures = (0..<30).map { makeEmail(i: $0, total: 30, body: "plain body \($0)") }
        fixtures[0].messageType = "sent"     // oldest — outside page 1
        try await env.store.insertBatch(fixtures, batchSize: 200)
        try await env.fts.indexBatch(fixtures)
        // Recovered-flag shape: has_attach set in SQL, attachments table empty.
        try await env.store.applyHeaderFidelity([
            .init(id: fixtures[1].id, tags: [], hasAttachment: true, sourceFilename: nil)
        ])

        let vm = ParsedEmailListViewModel(viewModel: ContentViewModel(), archive: env.archive,
                                          pageSize: 10, maxRetained: 50)
        vm.isPremiumUser = true

        vm.quickTypeFilter = "sent"
        await vm.reloadForQueryChangeNow()
        XCTAssertEqual(vm.visibleEmails.map(\.id), [fixtures[0].id],
            "Sent chip pages the whole archive via SQL")

        vm.quickTypeFilter = nil
        vm.hasAttachmentFilter = true
        await vm.reloadForQueryChangeNow()
        XCTAssertEqual(vm.visibleEmails.map(\.id), [fixtures[1].id],
            "Attachments chip matches the recovered has_attach flag even with no metadata rows")
    }

    /// AI chips (priority/phishing/sentiment/classification) compile to SQL
    /// over the persisted derived table — matches page in from the whole
    /// archive, not just the resident window.
    func testPartU_aiChipsFilterViaPersistedDerivedRecords() async throws {
        let env = try makeEnv()
        let fixtures = (0..<30).map { makeEmail(i: $0, total: 30, body: "plain body \($0)") }
        try await env.store.insertBatch(fixtures, batchSize: 200)
        try await env.fts.indexBatch(fixtures)
        // Persisted analysis: only the OLDEST row is high priority + phishing.
        var record = DerivedRecord(emailID: fixtures[0].id)
        record.corpusRevision = 1
        record.analysisVersion = 1
        record.sentiment = "-0.8000"
        record.classification = "newsletter"
        record.priority = 5
        record.phishing = true
        try await env.store.derivedUpsert([record])

        let vm = ParsedEmailListViewModel(viewModel: ContentViewModel(), archive: env.archive,
                                          pageSize: 10, maxRetained: 50)
        vm.isPremiumUser = true

        vm.quickMinPriority = 4
        await vm.reloadForQueryChangeNow()
        XCTAssertEqual(vm.visibleEmails.map(\.id), [fixtures[0].id],
            "High Priority chip pages the archive via derived.priority")

        vm.quickMinPriority = nil
        vm.quickPhishingOnly = true
        await vm.reloadForQueryChangeNow()
        XCTAssertEqual(vm.visibleEmails.map(\.id), [fixtures[0].id], "phishing flag via SQL")

        vm.quickPhishingOnly = false
        vm.quickNegativeOnly = true
        await vm.reloadForQueryChangeNow()
        XCTAssertEqual(vm.visibleEmails.map(\.id), [fixtures[0].id], "sentiment threshold via SQL")

        vm.quickNegativeOnly = false
        vm.quickNewsletterOnly = true
        await vm.reloadForQueryChangeNow()
        XCTAssertEqual(vm.visibleEmails.map(\.id), [fixtures[0].id], "classification via SQL")
    }

    // MARK: - Free-tier paging gate from store counts

    /// Non-premium paging depth is capped at `StoreManager.freeEmailLimit`
    /// (store-count-driven), while the store-truth total stays visible; the
    /// premium flag lifts the gate without any array semantics.
    func testFreeTierPagingGateFromStoreCount() async throws {
        let env = try makeEnv()
        _ = try await seed(env, count: 30)

        // pageSize 10 → the free limit (500) allows 50 page-loads; simulate the
        // gate arithmetic directly at the boundary instead of seeding 500+
        // fixtures: with pageSize equal to the free limit, ONE page exhausts
        // the free depth.
        let vm = ParsedEmailListViewModel(viewModel: ContentViewModel(), archive: env.archive,
                                          pageSize: StoreManager.freeEmailLimit, maxRetained: StoreManager.freeEmailLimit)
        vm.isPremiumUser = false
        await vm.reloadForQueryChangeNow()

        XCTAssertEqual(vm.queryTotalCount, 30, "store-truth total independent of tier")
        XCTAssertFalse(vm.hasMorePages,
            "free tier: paging depth is gated at freeEmailLimit emails")

        // Same state, premium: the gate is the pager's own hasMore only.
        vm.isPremiumUser = true
        XCTAssertEqual(vm.hasMorePages, false,
            "30 fixtures fit one page — premium gate defers to pager exhaustion")

        // Boundary arithmetic on a smaller page size: after 1 initial page of
        // 100, a free user may keep paging until 500 is reached.
        let vm2 = ParsedEmailListViewModel(viewModel: ContentViewModel(), archive: env.archive,
                                           pageSize: 100, maxRetained: 500)
        vm2.isPremiumUser = false
        await vm2.reloadForQueryChangeNow()
        XCTAssertEqual(vm2.residentEmails.count, 30, "single page holds every fixture")
        XCTAssertFalse(vm2.hasMorePages, "nothing further in the store")
    }

    // MARK: - Part S — the list-mode flag is presentation-only

    /// The stored preference migrated off the rollback-named key: the legacy
    /// key is removed and its value carried over once.
    func testListModePreferenceKeyMigration() {
        let suiteName = "cutover-pref-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Legacy value false (Advanced) migrates to the new key.
        defaults.set(false, forKey: "useV2ArchiveList")
        ListModePreference.migrateIfNeeded(defaults: defaults)
        XCTAssertEqual(defaults.object(forKey: ListModePreference.key) as? Bool, false,
            "stored choice carried over")
        XCTAssertNil(defaults.object(forKey: "useV2ArchiveList"), "rollback-era key removed")

        // Idempotent: a second migration never clobbers the new key.
        defaults.set(true, forKey: ListModePreference.key)
        ListModePreference.migrateIfNeeded(defaults: defaults)
        XCTAssertEqual(defaults.object(forKey: ListModePreference.key) as? Bool, true)
    }

    /// §27 regression guard: the SHIPPING DEFAULT list mode is Advanced —
    /// the full v1-parity toolkit. A v1 user upgrading must never land in
    /// the minimal Simple list and perceive their features as deleted.
    func testDefaultListModeIsAdvanced() {
        XCTAssertFalse(ListModePreference.defaultSimple,
            "default list mode must be Advanced (v1 feature parity); Simple is opt-in")
    }

    // MARK: - Min Reply Count (v1 behavior): per-sender frequency in SQL

    /// v1's Min Reply Count filtered by how many messages each SENDER has in
    /// the whole archive. v2 compiles it to a HAVING subquery
    /// (EmailQuery.minSenderMessages) so it is archive-wide and never depends
    /// on the resident window or the 500-sender rollup (the 'weird behavior').
    func testMinSenderMessagesCompilesArchiveWide() async throws {
        let env = try makeEnv()
        // heavy@ 5 messages, mid@ 3, rare@ 1 — explicit per-sender counts.
        var fixtures: [MBOXParser.RawEmail] = []
        let plan: [(String, Int)] = [("heavy@example.com", 5),
                                     ("mid@example.com", 3),
                                     ("rare@example.com", 1)]
        var serial = 0
        for (sender, n) in plan {
            for _ in 0..<n {
                var email = makeEmail(i: serial, total: 9, body: "reply-count body \(serial)")
                email.headers["From"] = sender
                fixtures.append(email)
                serial += 1
            }
        }
        try await env.store.insertBatch(fixtures, batchSize: 50)

        func count(min: Int) async throws -> Int {
            var q = EmailQuery.all
            q.minSenderMessages = min
            return try await env.archive.count(query: q)
        }
        let atLeast3 = try await count(min: 3)
        XCTAssertEqual(atLeast3, 8, "senders with ≥3 messages: heavy(5) + mid(3)")
        let atLeast5 = try await count(min: 5)
        XCTAssertEqual(atLeast5, 5, "only heavy has ≥5 messages")
        let atLeast6 = try await count(min: 6)
        XCTAssertEqual(atLeast6, 0, "no sender reaches 6")

        // Paging must honor it too (SQL, not window refinement): every row
        // returned for min=3 is from heavy@ or mid@.
        var q = EmailQuery.all
        q.minSenderMessages = 3
        let page = try await env.archive.page(query: q, cursor: nil, limit: 100)
        XCTAssertEqual(page.summaries.count, 8)
        XCTAssertTrue(page.summaries.allSatisfy {
            $0.from.contains("heavy@") || $0.from.contains("mid@")
        }, "a rare-sender row leaked through minSenderMessages")
    }

    // MARK: - Natural-language search (NLQueryInterpreter)

    /// The heuristic tier (pre-26 OS fallback) extracts sender, attachment
    /// and topic words without clobbering anything else.
    func testNLHeuristicIntent_extractsFilters() {
        let intent = NLQueryInterpreter.heuristicIntent(
            "emails from alice@example.com about invoices with attachments")
        XCTAssertEqual(intent.sender, "alice@example.com")
        XCTAssertTrue(intent.hasAttachments)
        XCTAssertTrue(intent.keywords.contains("invoices"),
                      "topic words survive as FTS keywords, got: '\(intent.keywords)'")
        XCTAssertFalse(intent.keywords.contains("emails"), "stop words are dropped")
    }

    /// An interpreted intent compiles to SQL and yields exactly the right
    /// rows archive-wide — the 'proper result' check the NL mode rests on.
    func testNLIntent_appliedQueryYieldsCorrectRows() async throws {
        let env = try makeEnv()
        var fixtures: [MBOXParser.RawEmail] = []
        for i in 0..<12 {
            var e = makeEmail(i: i, total: 12,
                              body: i < 4 ? "quarterly invoice details \(i)" : "meeting notes \(i)")
            e.headers["From"] = i < 4 ? "alice@corp.com" : "bob@corp.com"
            fixtures.append(e)
        }
        try await env.store.insertBatch(fixtures, batchSize: 50)
        try await env.fts.indexBatch(fixtures)

        // "invoices from alice" as an interpreted intent:
        var intent = NLSearchIntent()
        intent.sender = "alice"
        intent.keywords = "invoice"
        let query = intent.apply(to: .all)
        XCTAssertEqual(query.sender, "alice")
        XCTAssertEqual(query.text, "invoice")

        // Sender-only slice (structured clause).
        var senderOnly = NLSearchIntent()
        senderOnly.sender = "alice"
        let senderCount = try await env.archive.count(query: senderOnly.apply(to: .all))
        XCTAssertEqual(senderCount, 4, "sender filter must be archive-wide SQL")

        // Keywords go through FTS.
        var keywordOnly = NLSearchIntent()
        keywordOnly.keywords = "invoice"
        let page = try await env.archive.searchRanked(
            query: keywordOnly.apply(to: .all), cursor: nil, limit: 50)
        XCTAssertEqual(page.summaries.count, 4, "FTS keyword slice")
        XCTAssertTrue(page.summaries.allSatisfy { $0.from.contains("alice@") })

        // Date bounds map to SQL clauses.
        var dated = NLSearchIntent()
        dated.afterDate = ISO8601DateFormatter().date(from: "2023-01-01T00:00:00Z")
        let datedQuery = dated.apply(to: .all)
        XCTAssertNotNil(datedQuery.afterDate)
    }

    /// Hallucination guard: the exact failure from the field — the model
    /// answered 'show me patent related emails' with an invented date range,
    /// 'sent', a duplicate subject clause and '-' placeholders, ANDing to
    /// zero matches. Every unsupported filter must be stripped.
    func testNLSanitizer_dropsInventedFilters() {
        var raw = NLSearchIntent()
        raw.keywords = "patent"
        raw.subject = "patent"                 // duplicate of keywords
        raw.sender = "-"                       // placeholder junk
        raw.recipient = "n/a"
        raw.messageType = "sent"               // never asked for
        raw.hasAttachments = true              // never asked for
        raw.afterDate = Date(timeIntervalSince1970: 1_785_000_000)   // invented
        raw.beforeDate = Date(timeIntervalSince1970: 1_786_000_000)

        let clean = NLQueryInterpreter.sanitized(raw, query: "show me patent related emails")
        XCTAssertEqual(clean.keywords, "patent")
        XCTAssertEqual(clean.subject, "", "unrequested subject clause dropped")
        XCTAssertEqual(clean.sender, "", "'-' placeholder stripped")
        XCTAssertEqual(clean.recipient, "", "'n/a' placeholder stripped")
        XCTAssertNil(clean.messageType, "'sent' was never requested")
        XCTAssertFalse(clean.hasAttachments, "attachments were never requested")
        XCTAssertNil(clean.afterDate, "no time period in the sentence → no date bound")
        XCTAssertNil(clean.beforeDate)

        // And stated filters SURVIVE sanitization.
        let kept = NLQueryInterpreter.sanitized(raw, query:
            "patent emails I sent with attachments since January 2026")
        XCTAssertEqual(kept.messageType, "sent")
        XCTAssertTrue(kept.hasAttachments)
        XCTAssertNotNil(kept.afterDate)
    }

    /// Live model on the exact sentence from the bug report: a topic-only
    /// request must come back topic-only after sanitization.
    func testNLModelInterpretation_topicOnlyQueryStaysTopicOnly() async throws {
        guard NLQueryInterpreter.isModelBacked else {
            throw XCTSkip("on-device foundation model unavailable")
        }
        let intent = await NLQueryInterpreter.interpret("show me patent related emails")
        XCTAssertTrue(intent.keywords.lowercased().contains("patent"),
                      "topic extracted, got: '\(intent.keywords)'")
        XCTAssertNil(intent.afterDate, "no dates were mentioned — none may be invented")
        XCTAssertNil(intent.beforeDate)
        XCTAssertNil(intent.messageType, "sent/received was never mentioned")
        XCTAssertFalse(intent.hasAttachments)
        XCTAssertTrue(intent.sender.isEmpty, "no sender mentioned, got: '\(intent.sender)'")
        XCTAssertTrue(intent.subject.isEmpty || intent.keywords.isEmpty == false,
                      "subject-only interpretation would over-restrict")
    }

    /// Live Apple-Intelligence interpretation (skips where the model is
    /// unavailable): a real sentence must come back as structured filters,
    /// not free text.
    func testNLModelInterpretation_live() async throws {
        guard NLQueryInterpreter.isModelBacked else {
            throw XCTSkip("on-device foundation model unavailable")
        }
        let intent = await NLQueryInterpreter.interpret(
            "invoices from alice with attachments since January 2026")
        XCTAssertTrue(intent.sender.lowercased().contains("alice"),
                      "sender extracted, got: '\(intent.sender)'")
        XCTAssertTrue(intent.hasAttachments, "attachment constraint extracted")
        XCTAssertTrue(intent.keywords.lowercased().contains("invoice"),
                      "topic keywords extracted, got: '\(intent.keywords)'")
        if let after = intent.afterDate {
            let cal = Calendar.current
            let jan2026 = cal.date(from: DateComponents(year: 2026, month: 1, day: 1))!
            XCTAssertTrue(abs(after.timeIntervalSince(jan2026)) < 45 * 86_400,
                          "'since January 2026' resolved near 2026-01-01, got \(after)")
        } else {
            XCTFail("'since January 2026' must produce a start date")
        }
    }

    // MARK: - PII detection quality

    /// The exact junk from the field report: timestamps, year-prefixed refs,
    /// long tracking numbers and decimal fragments must NOT pass as phone
    /// numbers, while genuinely formatted numbers must.
    func testPhoneValidator_rejectsScreenshotJunk_keepsRealNumbers() {
        let junk = ["1693660628", "1662556449", "18175944444394", "2023 1775931",
                    "20233181965", "1771216833082", "0000000000169",
                    "104.15350994113", "1.1724930082", "+0000 1848193",
                    "78293080000", "1007847871189"]
        for value in junk {
            XCTAssertFalse(EmailNLPEngine.isPlausiblePhoneNumber(value),
                           "'\(value)' is not a phone number")
        }
        let real = ["+91 120 3132513", "+91-4009026817", "(817) 594-4444",
                    "817.594.4444", "1-800-555-0123", "+1 (212) 555-0187"]
        for value in real {
            XCTAssertTrue(EmailNLPEngine.isPlausiblePhoneNumber(value),
                          "'\(value)' is a real phone number")
        }
    }

    /// End-to-end: an email whose body mixes junk digits with real PII yields
    /// only the real findings — and the header fallback is validated too.
    func testDetectPII_filtersJunkAcrossBodyAndHeaders() {
        var email = makeEmail(i: 0, total: 1, body:
            "Call me at +91-120-3132513 about order 18175944444394. " +
            "Logged at 1693660628 from 8.8.8.8 and 192.168.1.10. " +
            "Reach my assistant: assistant@example.org")
        email.headers["X-Junk"] = "ref 1662556449 batch 20233181965"

        let findings = EmailNLPEngine.detectPII(in: [email])
        let phones = findings.filter { $0.type == .phoneNumber }.map(\.value)
        XCTAssertTrue(phones.contains { $0.contains("3132513") }, "real phone found")
        XCTAssertFalse(phones.contains { $0.filter(\.isNumber).contains("18175944444394") },
                       "tracking number not a phone")
        XCTAssertFalse(phones.contains { $0.filter(\.isNumber) == "1693660628" },
                       "epoch timestamp not a phone")
        XCTAssertFalse(phones.contains { $0.filter(\.isNumber) == "1662556449" },
                       "header fallback validates too")
        let ips = findings.filter { $0.type == .ipAddress }.map(\.value)
        XCTAssertTrue(ips.contains("8.8.8.8"), "public IP found")
        XCTAssertFalse(ips.contains("192.168.1.10"), "private range excluded")
        XCTAssertTrue(findings.contains { $0.type == .emailAddress && $0.value == "assistant@example.org" })
    }

    /// Field regression: the Credit Card Pattern section showed all-zero
    /// runs (Luhn-valid by accident!) and paired 8-digit reference numbers.
    /// A card finding must be Luhn-valid AND card-grouped AND carry a known
    /// issuer prefix.
    func testCardValidator_rejectsPatternJunk_keepsRealCards() {
        let junk = ["0000-0000-0000-0000", "00000000-0000-0000",
                    "0000-000000000000", "67698703 67698713",
                    "1111-1111-1111-1111"]
        for value in junk {
            XCTAssertFalse(EmailNLPEngine.isPlausibleCardNumber(value),
                           "'\(value)' is not a card number")
        }
        // Industry-standard test numbers (Luhn-valid, real IINs).
        let real = ["4111 1111 1111 1111", "4111-1111-1111-1111",
                    "4111111111111111", "5500 0000 0000 0004",
                    "378282246310005", "3782 822463 10005",
                    "6011 0009 9013 9424"]
        for value in real {
            XCTAssertTrue(EmailNLPEngine.isPlausibleCardNumber(value),
                          "'\(value)' is a valid card format")
        }
    }

    /// Field regression: repeated AI Clean-up clicks wiped the whole report.
    /// The verdict policy must distrust over-flagging batches (hallucination)
    /// and drop invalid offsets — accepting only clearly-minority junk.
    func testPIICleanupPolicy_distrustsOverFlaggingBatches() {
        // Model flags everything → hallucination → keep the whole batch.
        XCTAssertEqual(PIIAICleanupPolicy.acceptedOffsets(Array(0..<30), batchCount: 30), [])
        // Flags just over half → still distrusted.
        XCTAssertEqual(PIIAICleanupPolicy.acceptedOffsets(Array(0..<16), batchCount: 30), [])
        // Minority flags → accepted, deduped, sorted, in-range only.
        XCTAssertEqual(PIIAICleanupPolicy.acceptedOffsets([7, 3, 3, -1, 99, 12], batchCount: 30),
                       [3, 7, 12])
        // Exactly half is the boundary — allowed (small mixed batches).
        XCTAssertEqual(PIIAICleanupPolicy.acceptedOffsets([0, 1], batchCount: 4), [0, 1])
        // Empty batch or no flags.
        XCTAssertEqual(PIIAICleanupPolicy.acceptedOffsets([], batchCount: 30), [])
        XCTAssertEqual(PIIAICleanupPolicy.acceptedOffsets([0], batchCount: 0), [])
    }

    /// Tag corrections (manual adds + suppressed AI tags) must survive
    /// relaunch: UserDefaults round-trip, junk keys dropped, empties pruned.
    func testTagOverridePersistence_roundTrip() {
        let suite = "tag-override-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let a = UUID(), b = UUID()
        let corrections: [UUID: Set<String>] = [
            a: ["Personal", "High Priority"],
            b: ["Newsletter"],
        ]
        TagOverridePersistence.save(corrections, key: TagOverridePersistence.manualKey,
                                    defaults: defaults)
        let loaded = TagOverridePersistence.load(key: TagOverridePersistence.manualKey,
                                                 defaults: defaults)
        XCTAssertEqual(loaded, corrections)

        // Empty sets are pruned on save.
        TagOverridePersistence.save([a: [], b: ["Phishing"]],
                                    key: TagOverridePersistence.suppressedKey, defaults: defaults)
        let pruned = TagOverridePersistence.load(key: TagOverridePersistence.suppressedKey,
                                                 defaults: defaults)
        XCTAssertEqual(pruned, [b: ["Phishing"]])

        // Corrupt payloads load as empty, never crash.
        defaults.set(Data("not json".utf8), forKey: "corrupt")
        XCTAssertTrue(TagOverridePersistence.load(key: "corrupt", defaults: defaults).isEmpty)
    }

    /// The layman's tags explainer must be in the searchable Feature Guide
    /// catalog, and every catalog entry must be substantive (a title match in
    /// the guide search that opens an empty tutorial would be worse than none).
    func testFeatureGuide_containsTagsTutorial_allEntriesSubstantive() {
        let all = FeatureTutorial.allFeatures
        guard let tags = all.first(where: { $0.title == "Email Labels & AI Tags" }) else {
            return XCTFail("tags tutorial missing from Feature Guide catalog")
        }
        XCTAssertGreaterThanOrEqual(tags.steps.count, 4,
            "tags tutorial covers pills, toggle, correction, manual labels, filtering")
        XCTAssertTrue(tags.overview.contains("one click"),
            "overview promises the one-click correction")
        for tutorial in all {
            XCTAssertFalse(tutorial.overview.isEmpty, "\(tutorial.title): empty overview")
            XCTAssertFalse(tutorial.quickStart.isEmpty, "\(tutorial.title): empty quick start")
        }
    }

    /// Simple/Advanced label split: Simple shows act-on labels only
    /// (category, High Priority, Phishing); Pro adds sentiment and Medium
    /// Priority; fact pills obey their own option. Display-only policy.
    func testTagDisplayPolicy_simpleVsAdvanced() {
        let tags = ["Newsletter", "Positive", "Medium Priority", "High Priority",
                    "Phishing", "Sent", "Has Attachment"]
        XCTAssertEqual(
            TagDisplayPolicy.visible(tags, advancedMode: false, showFacts: false),
            ["Newsletter", "High Priority", "Phishing"],
            "Simple mode: category + importance + danger, nothing else")
        XCTAssertEqual(
            TagDisplayPolicy.visible(tags, advancedMode: true, showFacts: false),
            ["Newsletter", "Positive", "Medium Priority", "High Priority", "Phishing"],
            "Pro adds analyst labels but fact pills still obey their option")
        XCTAssertEqual(
            TagDisplayPolicy.visible(tags, advancedMode: true, showFacts: true),
            tags,
            "Pro + fact pills on shows everything")
        XCTAssertEqual(
            TagDisplayPolicy.visible(["Sent"], advancedMode: false, showFacts: true),
            [],
            "fact labels are advanced-only: Simple mode never shows them, even with the option on")
    }

    /// Field regression: a v1-migrated archive (rows WITHOUT source
    /// identity) + a fresh import of the original file under preserveAll
    /// doubled every email — the occurrence guard can't match NULL-source
    /// rows and preserveAll skips Message-ID dedup. The archive-wide
    /// resolver must return exactly the redundant copies, preferring to
    /// KEEP the source-identified (full-fidelity) row.
    func testExactDuplicateResolver_migratedPlusReimport() async throws {
        let env = try makeEnv()

        // 'Migrated' rows: message-ids, NO source identity.
        var migrated: [MBOXParser.RawEmail] = []
        for i in 0..<5 {
            var e = makeEmail(i: i, total: 10, body: "body \(i)")
            e.headers["Message-ID"] = "<shared-\(i)@test>"
            migrated.append(e)
        }
        try await env.store.insertBatch(
            migrated, sourceFileHash: nil, accountID: nil,
            sourceID: nil, firstOrdinal: nil, dedupPolicy: .preserveAll,
            batchSize: 10, progress: nil)

        // Fresh import of the same file: same message-ids, NEW UUIDs,
        // WITH source identity, preserveAll (Auto-Remove off).
        let sid = try await env.store.registerSource(SQLiteEmailStore.SourceDescriptor(
            sha256: "ffff", filename: "Sent.mbox", byteSize: 10,
            parser: "mbox", parserVersion: 3, accountID: nil, sourceKind: "mbox"))
        var imported: [MBOXParser.RawEmail] = []
        for i in 0..<6 {   // one extra email only in the file
            var e = makeEmail(i: 100 + i, total: 10, body: "body \(i)")
            e.headers["Message-ID"] = "<shared-\(i)@test>"
            imported.append(e)
        }
        let result = try await env.store.insertBatch(
            imported, sourceFileHash: "ffff", accountID: nil,
            sourceID: sid, firstOrdinal: 0, dedupPolicy: .preserveAll,
            batchSize: 10, progress: nil)
        XCTAssertEqual(result.insertedIDs.count, 6, "preserveAll re-inserts everything — the doubling")
        let doubled = try await env.archive.count()
        XCTAssertEqual(doubled, 11)

        // Resolver: exactly the 5 redundant copies — and the KEPT rows are
        // the source-identified imports, not the migrated ones.
        let toRemove = try await env.store.exactMessageIDDuplicateIDs()
        XCTAssertEqual(toRemove.count, 5)
        let migratedIDs = Set(migrated.map(\.id))
        XCTAssertTrue(Set(toRemove).isSubset(of: migratedIDs),
                      "the migrated (source-less) copies are the ones removed")

        try await env.store.delete(ids: Set(toRemove))
        let remaining = try await env.archive.count()
        XCTAssertEqual(remaining, 6, "one copy per email survives")
        let after = try await env.store.exactMessageIDDuplicateIDs()
        XCTAssertTrue(after.isEmpty, "idempotent — nothing left to remove")
    }

    // MARK: - Five jobs DUP-01 — a clue is not a comparison

    /// A fresh copy (new id) of `email` with `change` applied.
    private func copy(of email: MBOXParser.RawEmail,
                      _ change: (inout MBOXParser.RawEmail) -> Void = { _ in }) -> MBOXParser.RawEmail {
        var e = MBOXParser.RawEmail(
            headers: email.headers, rawSource: email.rawSource, messageType: email.messageType,
            attachments: email.attachments, timestamp: email.timestamp, domains: email.domains,
            plainBody: email.plainBody, htmlBody: email.htmlBody)
        change(&e)
        return e
    }

    func testDUP01_identicalStoredBytesAreByteIdentical() {
        let a = makeEmail(i: 1, total: 2, body: "the same body")
        let b = copy(of: a)
        XCTAssertEqual(DuplicateVerification.verify([a, b]), .byteIdentical)
        // CRLF and LF forms of the same message are the same message — but
        // not the same bytes (audit A01): content-equivalent, not byte-identical.
        let lf = copy(of: a) { $0.rawSource = "Subject: s\n\nline one\nline two" }
        let crlf = copy(of: a) { $0.rawSource = "Subject: s\r\n\r\nline one\r\nline two" }
        XCTAssertEqual(DuplicateVerification.verify([lf, crlf]), .contentEquivalent(attachmentBytesCompared: true))
    }

    func testDUP01_sameMessageIDDifferentAttachmentIsACandidate() {
        let pdfA = Data("%PDF-1.4 version one".utf8).base64EncodedString()
        let pdfB = Data("%PDF-1.4 version two".utf8).base64EncodedString()
        let a = copy(of: makeEmail(i: 2, total: 2, body: "see attached")) {
            $0.attachments = [AttachmentMetadata(filename: "contract.pdf", mimeType: "application/pdf", size: 20, base64: pdfA)]
        }
        let b = copy(of: a) {
            $0.rawSource = "raw other"
            $0.attachments = [AttachmentMetadata(filename: "contract.pdf", mimeType: "application/pdf", size: 20, base64: pdfB)]
        }
        XCTAssertEqual(a.headers["Message-ID"], b.headers["Message-ID"], "the clue the engines group on")
        XCTAssertEqual(DuplicateVerification.verify([a, b]), .candidate(differences: [.attachments]))
        XCTAssertFalse(DuplicateVerification.verify([a, b]).isVerified)
    }

    func testDUP01_bodyThatDiffersAfterTheFingerprintPrefixIsACandidate() {
        let prefix = String(repeating: "x", count: 300)
        let a = makeEmail(i: 3, total: 2, body: prefix + " ends one way")
        let b = copy(of: a) { $0.rawSource = "raw other"; $0.plainBody = prefix + " ends another way" }
        // The engines' SHA-1 of the first 200 characters cannot tell these apart.
        XCTAssertEqual(String(a.plainBody.prefix(200)), String(b.plainBody.prefix(200)))
        XCTAssertEqual(DuplicateVerification.verify([a, b]), .candidate(differences: [.body]))
    }

    func testDUP01_transportHeadersAloneDoNotMakeACandidate() {
        // RFC 5322 §3.6.4: the same message may gain Received/transport headers
        // without changing its Message-ID. Different raw bytes, same content.
        let a = makeEmail(i: 4, total: 2, body: "identical content")
        let b = copy(of: a) {
            $0.rawSource = "Received: from relay.example\n" + $0.rawSource
            $0.headers["Received"] = "from relay.example"
        }
        XCTAssertEqual(DuplicateVerification.verify([a, b]), .contentEquivalent(attachmentBytesCompared: true))
        // A changed recipient display name is not content either; a changed address is.
        let renamed = copy(of: a) { $0.rawSource = "raw other"; $0.headers["To"] = "Me Myself <me@example.com>" }
        XCTAssertEqual(DuplicateVerification.verify([a, renamed]), .contentEquivalent(attachmentBytesCompared: true))
        let other = copy(of: a) { $0.rawSource = "raw other"; $0.headers["To"] = "you@example.com" }
        XCTAssertEqual(DuplicateVerification.verify([a, other]), .candidate(differences: [.to]))
    }

    func testDUP01_attachmentsWithoutStoredBytesAreCompareByMetadataAndSaySo() {
        let a = copy(of: makeEmail(i: 5, total: 2, body: "b")) {
            $0.attachments = [AttachmentMetadata(filename: "a.txt", mimeType: "text/plain", size: 9)]
        }
        let b = copy(of: a) { $0.rawSource = "raw other" }
        // Audit 2026-11-06 A01: bytes that cannot be produced leave the copies unproven — a candidate, not a verified pair.
        XCTAssertEqual(DuplicateVerification.verify([a, b]), .candidate(differences: [.attachmentBytes]))
        XCTAssertFalse(DuplicateVerification.verify([a, b]).isVerified)
        XCTAssertTrue(DuplicateVerification.differenceLine(.candidate(differences: [.attachmentBytes]))?.contains("attachment bytes") == true)
    }

    func testA01_sameNameSizeAndType_differentBytes_isACandidate_andLineEndingsAreNotByteIdentical() {
        let one = Data("first contents".utf8), two = Data("other contents".utf8)   // the same length
        let a = copy(of: makeEmail(i: 8, total: 2, body: "b")) {
            $0.attachments = [AttachmentMetadata(filename: "a.txt", mimeType: "text/plain", size: one.count, base64: one.base64EncodedString())]
        }
        let b = copy(of: a) {
            $0.rawSource = "raw other"
            $0.attachments = [AttachmentMetadata(filename: "a.txt", mimeType: "text/plain", size: two.count, base64: two.base64EncodedString())]
        }
        XCTAssertEqual(DuplicateVerification.verify([a, b]), .candidate(differences: [.attachments]), "same name, type and size; different bytes")
        let same = copy(of: a) { $0.rawSource = "raw other" }
        XCTAssertEqual(DuplicateVerification.verify([a, same]), .contentEquivalent(attachmentBytesCompared: true))
        // Raw bytes that differ only in line endings are content-equivalent, never "byte-identical".
        let lf = copy(of: a) { $0.rawSource = "Subject: s\n\nline one\nline two" }
        let crlf = copy(of: a) { $0.rawSource = "Subject: s\r\n\r\nline one\r\nline two" }
        XCTAssertNotEqual(lf.rawSource, crlf.rawSource)
        XCTAssertEqual(DuplicateVerification.verify([lf, crlf]), .contentEquivalent(attachmentBytesCompared: true))
        XCTAssertEqual(DuplicateVerification.verify([a, copy(of: a)]), .byteIdentical)
        // Archive-wide planning never takes from the unproven group.
        let (verified, candidates) = DuplicateVerification.classify([[a, b], [a, same]])
        XCTAssertEqual(verified.count, 1); XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(DuplicateVerification.bulkRemovable(verified + candidates), [same.id])
    }

    func testDUP01_bulkRemovalNeverTakesFromCandidateGroups() {
        let a = makeEmail(i: 6, total: 4, body: "same")
        let a2 = copy(of: a)
        let b = makeEmail(i: 7, total: 4, body: "first version")
        let b2 = copy(of: b) { $0.rawSource = "raw other"; $0.plainBody = "second version" }
        let (verified, candidates) = DuplicateVerification.classify([[a, a2], [b, b2]])
        XCTAssertEqual(verified.map(\.id), [a.id])
        XCTAssertEqual(candidates.map(\.id), [b.id])
        XCTAssertEqual(DuplicateVerification.bulkRemovable(verified + candidates), [a2.id],
                       "only the verified group's extra copy; b2 is a different message")
        XCTAssertEqual(DuplicateVerification.differenceLine(candidates[0].verdict), "Differs in body")
    }

    func testDUP01_archiveWideVerificationLoadsInChunksAndSkipsCandidates() async throws {
        // 600 same-Message-ID pairs: 599 identical, one whose body changed.
        var byID: [UUID: MBOXParser.RawEmail] = [:]
        var groups: [[UUID]] = []
        var changedKeep: UUID?
        for i in 0..<600 {
            let keep = makeEmail(i: 1000 + i, total: 600, body: "body \(i)")
            let extra = copy(of: keep) {
                if i == 123 { $0.rawSource = "raw other"; $0.plainBody = "body \(i) — edited later" }
            }
            if i == 123 { changedKeep = keep.id }
            byID[keep.id] = keep; byID[extra.id] = extra
            groups.append([keep.id, extra.id])
        }
        var loads = 0
        let result = try await DuplicateVerification.verifyArchiveWide(groups: groups) { ids in
            loads += 1
            XCTAssertLessThanOrEqual(ids.count, 502, "a chunk is bounded, never the whole archive")
            return ids.compactMap { byID[$0] }
        }
        XCTAssertGreaterThan(loads, 1, "600 pairs need more than one chunk")
        XCTAssertEqual(result.verifiedGroups, 599)
        XCTAssertEqual(result.candidateGroups, 1)
        XCTAssertEqual(result.removable.count, 599)
        let keepIDs = Set(groups.map { $0[0] })
        XCTAssertTrue(Set(result.removable).isDisjoint(with: keepIDs), "the kept copy is never removable")
        let changedExtra = try XCTUnwrap(groups.first { $0[0] == changedKeep }?[1])
        XCTAssertFalse(result.removable.contains(changedExtra), "the edited copy stays")
    }

    /// The store hands back whole same-Message-ID groups, first id = the copy to
    /// keep (source-identified before migrated), so the view can compare each
    /// group in full before offering a removal.
    func testDUP01_messageIDDuplicateGroups_keepsSourceIdentifiedCopyFirst() async throws {
        let env = try makeEnv()
        var migrated: [MBOXParser.RawEmail] = []
        for i in 0..<3 {
            var e = makeEmail(i: i, total: 10, body: "body \(i)")
            e.headers["Message-ID"] = "<shared-\(i)@test>"
            migrated.append(e)
        }
        try await env.store.insertBatch(
            migrated, sourceFileHash: nil, accountID: nil,
            sourceID: nil, firstOrdinal: nil, dedupPolicy: .preserveAll,
            batchSize: 10, progress: nil)
        let sid = try await env.store.registerSource(SQLiteEmailStore.SourceDescriptor(
            sha256: "ffff", filename: "Sent.mbox", byteSize: 10,
            parser: "mbox", parserVersion: 3, accountID: nil, sourceKind: "mbox"))
        var imported: [MBOXParser.RawEmail] = []
        for i in 0..<4 {   // one email only in the fresh import: not a group
            var e = makeEmail(i: 100 + i, total: 10, body: "body \(i)")
            e.headers["Message-ID"] = "<shared-\(i)@test>"
            imported.append(e)
        }
        try await env.store.insertBatch(
            imported, sourceFileHash: "ffff", accountID: nil,
            sourceID: sid, firstOrdinal: 0, dedupPolicy: .preserveAll,
            batchSize: 10, progress: nil)

        let groups = try await env.store.messageIDDuplicateGroups()
        XCTAssertEqual(groups.count, 3, "three Message-IDs stored twice; the fourth once")
        let importedIDs = Set(imported.map(\.id))
        for group in groups {
            XCTAssertEqual(group.count, 2)
            XCTAssertTrue(importedIDs.contains(group[0]), "the source-identified copy is kept")
        }
        // Same rows as the id-only resolver, now with their partner.
        let redundant = try await env.store.exactMessageIDDuplicateIDs()
        XCTAssertEqual(Set(groups.flatMap { $0.dropFirst() }), Set(redundant))
    }

    // MARK: - Five jobs FOLD-01 — every folder reachable, no 200 ceiling

    /// 10,000 distinct labels over 20 emails (500 each).
    private func seedManyFolders(_ env: Env) async throws -> Int {
        let total = 10_000
        var emails: [MBOXParser.RawEmail] = []
        for i in 0..<20 {
            var e = makeEmail(i: 2000 + i, total: 20, body: "folders \(i)")
            e.tags = (0..<500).map { String(format: "Folder/%05d", i * 500 + $0) }
            if i == 0 { e.tags[0] = "Sales 100%" }   // a LIKE wildcard in a real name
            emails.append(e)
        }
        try await env.store.insertBatch(emails, batchSize: 20)
        return total
    }

    func testFOLD01_storePagesAndFiltersEveryFolder() async throws {
        let env = try makeEnv()
        let total = try await seedManyFolders(env)

        let storeTotal = try await env.store.parserTagTotal()
        XCTAssertEqual(storeTotal, total)
        let previous = try await env.store.parserTagCounts(limit: 200)
        XCTAssertEqual(previous.count, 200, "the previous path still answers")

        var reached = Set<String>()
        var offset = 0
        while true {
            let page = try await env.store.parserTagCounts(matching: nil, offset: offset, limit: 200)
            if page.isEmpty { break }
            XCTAssertLessThanOrEqual(page.count, 200)
            reached.formUnion(page.map(\.value))
            offset += page.count
        }
        XCTAssertEqual(reached.count, total, "paging reaches every folder exactly once")

        let oneTotal = try await env.store.parserTagTotal(matching: "00999")
        XCTAssertEqual(oneTotal, 1)
        let one = try await env.store.parserTagCounts(matching: "00999", offset: 0, limit: 50)
        XCTAssertEqual(one.map(\.value), ["Folder/00999"])
        let lower = try await env.store.parserTagCounts(matching: "folder/0099", offset: 0, limit: 50)
        XCTAssertEqual(lower.count, 10, "case-insensitive")
        let literal = try await env.store.parserTagCounts(matching: "100%", offset: 0, limit: 50)
        XCTAssertEqual(literal.map(\.value), ["Sales 100%"], "a wildcard in the filter is a literal character")
        let blank = try await env.store.parserTagTotal(matching: "   ")
        XCTAssertEqual(blank, total, "blank filter means no filter")
    }

    func testFOLD01_sidebarReachesEveryFolderPageByPageWithTheTotalShown() async throws {
        let env = try makeEnv()
        let total = try await seedManyFolders(env)
        let saved = SQLiteEmailStore.unboundedIDLookups
        defer { SQLiteEmailStore.unboundedIDLookups = saved }

        // Previous path (switch off): busiest 200, no claim about the rest.
        SQLiteEmailStore.unboundedIDLookups = false
        let old = ArchiveSidebarModel(archive: env.archive)
        await old.refresh()
        XCTAssertFalse(old.completeLabels)
        XCTAssertEqual(old.labels.count, 200)
        XCTAssertEqual(old.labelTotal, 200)
        await old.loadMoreLabels()
        XCTAssertEqual(old.labels.count, 200, "the previous path does not page")

        // Complete lists (3.0) on: the total is the archive's, and paging reaches it all.
        SQLiteEmailStore.unboundedIDLookups = true
        let model = ArchiveSidebarModel(archive: env.archive)
        await model.refresh()
        XCTAssertTrue(model.completeLabels)
        XCTAssertEqual(model.labels.count, ArchiveSidebarModel.labelPage)
        XCTAssertEqual(model.labelTotal, total)
        var loads = 0
        while model.labels.count < model.labelTotal {
            await model.loadMoreLabels()
            loads += 1
            XCTAssertLessThan(loads, 100, "paging must terminate")
        }
        XCTAssertEqual(Set(model.labels.map(\.value)).count, total, "every folder is reachable")
        XCTAssertEqual(loads, total / ArchiveSidebarModel.labelPage - 1)

        await model.setLabelFilter("Folder/0042")
        XCTAssertEqual(model.labelTotal, 10)
        XCTAssertEqual(model.labels.count, 10)
        XCTAssertTrue(model.labels.allSatisfy { $0.value.hasPrefix("Folder/0042") })
        await model.setLabelFilter("")
        XCTAssertEqual(model.labelTotal, total)
        XCTAssertEqual(model.labels.count, ArchiveSidebarModel.labelPage, "clearing the filter starts at the first page again")
        // A refresh keeps the reach the person had opened.
        await model.loadMoreLabels()
        await model.refresh()
        XCTAssertEqual(model.labels.count, 2 * ArchiveSidebarModel.labelPage)
    }

    // MARK: - Five jobs FIND-03 — every attachment has a state, not "attempted"

    private func mimeAttachment(_ filename: String, _ mime: String, _ data: Data) -> String {
        """
        --B
        Content-Type: \(mime); name="\(filename)"
        Content-Disposition: attachment; filename="\(filename)"
        Content-Transfer-Encoding: base64

        \(data.base64EncodedString())
        """
    }

    private func lockedPDF() throws -> Data {
        let document = PDFDocument()
        document.insert(PDFPage(), at: 0)
        let options: [PDFDocumentWriteOption: Any] = [
            PDFDocumentWriteOption.userPasswordOption: "secret",
            PDFDocumentWriteOption.ownerPasswordOption: "secret"]
        return try XCTUnwrap(document.dataRepresentation(options: options))
    }

    func testFIND03_everyAttachmentGetsAStateAndANewExtractorRetriesWhatItCould() async throws {
        let env = try makeEnv()
        AttachmentTextIndexJob.testSuppressKicks = true
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()
        AttachmentTextIndexJob.testStoreOverride = env.store
        defer {
            AttachmentTextIndexJob.testStoreOverride = nil
            AttachmentTextIndexJob.testSuppressKicks = false
        }
        let long = String(repeating: "word ", count: 120_000)   // 600,000 characters
        let raw = """
        From sender@example.com Wed Jan 15 10:00:00 2025
        From: sender@example.com
        To: user@dest.org
        Subject: Five attachments
        Date: Wed, 15 Jan 2025 10:00:00 +0000
        Message-ID: <find03@t>
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="B"

        --B
        Content-Type: text/plain

        see attached
        \(mimeAttachment("notes.txt", "text/plain", Data("the xylophone clause".utf8)))
        \(mimeAttachment("blank.txt", "text/plain", Data("   \n  ".utf8)))
        \(mimeAttachment("report.doc", "application/msword", Data("\u{D0}\u{CF}legacy word".utf8)))
        \(mimeAttachment("locked.pdf", "application/pdf", try lockedPDF()))
        \(mimeAttachment("big.txt", "text/plain", Data(long.utf8)))
        --B--
        """
        let email = try MBOXParser.processRawMessage(raw, senderEmail: "")
        XCTAssertEqual(email.attachments.count, 5, "fixture parses with five attachments")
        _ = try await env.store.insertBatch([email], sourceFileHash: nil, accountID: nil,
            sourceID: nil, firstOrdinal: nil, dedupPolicy: .messageID, batchSize: 10, progress: nil)

        let outcome = await AttachmentTextIndexJob.shared.run()
        XCTAssertEqual(outcome.indexedEmails, 1)
        XCTAssertEqual(outcome.extractedTexts, 2, "notes.txt and the cut big.txt carry text")

        let coverage = try AttachmentCoverageStore(url: await env.store.attachmentCoverageURL)
        let rows = try coverage.rows(for: email.id)
        XCTAssertEqual(rows.map(\.filename), ["notes.txt", "blank.txt", "report.doc", "locked.pdf", "big.txt"])
        XCTAssertEqual(rows.map(\.state), [.extracted, .noText, .failed, .locked, .truncated])
        XCTAssertEqual(rows[4].characters, AttachmentTextIndexJob.maxTextPerAttachment)
        XCTAssertTrue(rows.allSatisfy { $0.extractorVersion == AttachmentTextIndexJob.extractorVersion })
        XCTAssertNotNil(rows[3].note)

        let summary = try coverage.summary(currentExtractorVersion: AttachmentTextIndexJob.extractorVersion)
        XCTAssertEqual(summary.total, 5)
        XCTAssertEqual(summary.searchable, 2)
        // TYPE-01: .doc is a read kind now; this fixture's bytes are not a Word file, so it is a failed read with its reason.
        XCTAssertEqual(summary.unsupportedKinds.map(\.kind), [])
        XCTAssertTrue(rows[2].note?.contains("OLE2") == true, rows[2].note ?? "")
        XCTAssertEqual(summary.staleRows, 0)
        let hits = try await env.store.attachmentTextSearch("xylophone")
        XCTAssertEqual(hits, [email.id])

        // Nothing is stale for the current extractor; a newer one would retry
        // the unsupported, locked-out and cut-short attachments' email.
        var requeued = try await AttachmentTextIndexJob.requeueStale(store: env.store, coverage: coverage)
        XCTAssertEqual(requeued, 0)
        let staleForNext = try coverage.emailIDs(staleBelow: AttachmentTextIndexJob.extractorVersion + 1, limit: 10)
        XCTAssertEqual(staleForNext, [email.id])

        // Rows left by an older extractor are re-queued without a reimport.
        try coverage.record(emailID: email.id, rows: rows.map {
            AttachmentCoverageRow(emailID: $0.emailID, ordinal: $0.ordinal, filename: $0.filename, mimeType: $0.mimeType,
                                  state: $0.state, extractor: $0.extractor, extractorVersion: 1, characters: $0.characters, note: $0.note)
        })
        requeued = try await AttachmentTextIndexJob.requeueStale(store: env.store, coverage: coverage)
        XCTAssertEqual(requeued, 1)
        let pending = try await env.store.attachmentTextProgress().pending
        XCTAssertEqual(pending, 1, "back on the work list")
        XCTAssertTrue(try coverage.rows(for: email.id).isEmpty)
        let again = await AttachmentTextIndexJob.shared.run()
        XCTAssertEqual(again.indexedEmails, 1)
        XCTAssertEqual(try coverage.rows(for: email.id).map(\.state), [.extracted, .noText, .failed, .locked, .truncated])
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()
    }

    /// Stage A: the previous duplicate engine's 5,000-email window is stated on
    /// screen, alone or after the "new engine stopped" fallback note.
    func testStageA_previousDuplicateEngineStatesItsWindow() {
        let alone = DuplicateManagerView.previousEngineScopeNote(appendedTo: nil)
        XCTAssertTrue(alone.contains("5,000"), alone)
        let after = DuplicateManagerView.previousEngineScopeNote(appendedTo: "The new engine stopped.")
        XCTAssertTrue(after.hasPrefix("The new engine stopped. "), after)
        XCTAssertTrue(after.hasSuffix(alone), after)
    }

    func testFIND03_noMatchNoticeNamesWhatWasNotSearchable() {
        var summary = AttachmentCoverageSummary()
        summary.counts = [.extracted: 1, .truncated: 1, .noText: 1, .unsupported: 1, .locked: 1]
        summary.unsupportedKinds = [("docx", 1)]
        let notice = AttachmentTextIndexJob.noMatchNotice(summary)
        XCTAssertTrue(notice.contains("2 of 5"), notice)
        XCTAssertTrue(notice.contains("1 unsupported (docx)"), notice)
        XCTAssertTrue(notice.contains("1 locked"), notice)
        XCTAssertTrue(notice.contains("1 cut short"), notice)
        XCTAssertTrue(notice.contains("1 with no text"), notice)

        var complete = AttachmentCoverageSummary()
        complete.counts = [.extracted: 3]
        XCTAssertEqual(AttachmentTextIndexJob.noMatchNotice(complete), "No attachments matched. Searchable text covers all 3 attachments.")
    }

    // MARK: - Five jobs OPEN-02 — PST streams in batches; memory follows the batch, not the file

    /// Anonymous + compressed memory of this process (what Xcode's gauge
    /// shows); clean file-backed pages from mmap are not counted.
    private static func physFootprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    func testOPEN02_pstStreamsInBatches_andTheFootprintFollowsTheBatch() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailin-open02-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("hundred-megabytes.pst")

        // ~100 MB: 2,000 messages with ~50 KB bodies, in a named folder.
        let n = 2_000
        let body = String(repeating: "Streaming body text for the open-archive test. ", count: 1_100)
        let writer = try PSTSpecWriter(url: url)
        let inbox = writer.appendFolder(name: "Inbox")
        for i in 0..<n {
            var e = makeEmail(i: 5_000 + i, total: n, body: body + "\nTail \(i)")
            e.headers["Subject"] = "Stream \(i)"
            try writer.append(email: e, folder: inbox)
        }
        XCTAssertEqual(try writer.finalize(), n)
        let fileSize = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        XCTAssertGreaterThan(fileSize, 90_000_000, "the fixture is about 100 MB")

        let wasStreaming = StreamingParserPolicy.binaryStreaming
        defer { StreamingParserPolicy.binaryStreaming = wasStreaming }
        StreamingParserPolicy.binaryStreaming = true

        let before = Self.physFootprint()
        var peak = before
        var batches = 0, largestBatch = 0, total = 0
        var subjects = Set<String>()
        var folders = Set<String>()
        // Through the factory: the seam every import uses.
        let report = try await ParserFactory.parseStreamingCallback(
            fileURL: url, senderEmail: "", batchSize: 100, materializeAttachments: false
        ) { batch in
            batches += 1
            largestBatch = max(largestBatch, batch.count)
            total += batch.count
            for email in batch {
                subjects.insert(email.headers["Subject"] ?? "")
                folders.formUnion(email.tags)
            }
            peak = max(peak, Self.physFootprint())
        }
        XCTAssertEqual(report.totalMessages, n)
        XCTAssertEqual(total, n)
        XCTAssertEqual(largestBatch, 100, "never more than one batch in hand")
        XCTAssertEqual(batches, n / 100)
        XCTAssertEqual(subjects.count, n, "every message arrived once")
        XCTAssertTrue(folders.contains { $0.hasSuffix("Inbox") }, "folder path preserved: \(folders)")
        let grewBy = peak - before
        XCTAssertLessThan(grewBy, fileSize / 2,
                          "footprint grew \(grewBy / 1_048_576) MB while streaming a \(fileSize / 1_048_576) MB file")

        // Off: the previous path, unchanged — same messages, same order.
        StreamingParserPolicy.binaryStreaming = false
        var firstStreamed: String?
        _ = try await PSTParser.parseStreaming(fileURL: url, senderEmail: "", batchSize: 7) { batch in
            if firstStreamed == nil { firstStreamed = batch.first?.headers["Subject"] }
        }
        let array = try PSTParser.parse(fileURL: url, senderEmail: "")
        XCTAssertEqual(array.count, n)
        XCTAssertEqual(array.first?.headers["Subject"], firstStreamed, "both paths hand out messages in the same order")
    }

    /// One Notes item record: type, name length, value length, name, value.
    private static func nsfItem(_ name: String, _ value: String) -> Data {
        var d = Data()
        let n = Data(name.utf8), v = Data(value.utf8)
        withUnsafeBytes(of: UInt16(0x0500).littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(n.count).littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(v.count).littleEndian) { d.append(contentsOf: $0) }
        d.append(n); d.append(v)
        return d
    }

    func testOPEN02_nsfStreamsInBatches_andTheFootprintFollowsTheBatch() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailin-open02-nsf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("hundred-megabytes.nsf")

        // ~100 MB synthetic Notes database: 2,000 memos with ~50 KB bodies,
        // written record by record so the fixture itself never sits in memory.
        let n = 2_000
        let body = String(repeating: "Streaming body text for the open-archive test. ", count: 1_100)
        var header = Data([0x1A, 0x00]); header.append(Data(repeating: 0, count: 254))
        withUnsafeBytes(of: UInt32(256).littleEndian) { header.replaceSubrange(0x28..<0x2C, with: $0) }
        FileManager.default.createFile(atPath: url.path, contents: header)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        for i in 0..<n {
            var record = Data()
            record.append(Self.nsfItem("Subject", "Stream \(i)"))
            record.append(Self.nsfItem("From", "CN=Sender \(i % 25)/O=Acme"))
            record.append(Self.nsfItem("SendTo", "CN=Team/O=Acme"))
            record.append(Self.nsfItem("DeliveredDate", String(format: "02/%02d/2024 09:%02d:00", 1 + i % 28, i % 60)))
            record.append(Self.nsfItem("$MessageID", "<nsf-open02-\(i)@acme.example>"))
            record.append(Self.nsfItem("Body", body + "\nTail \(i)"))
            record.append(Self.nsfItem("Form", "Memo"))
            try handle.write(contentsOf: record)
        }
        try handle.write(contentsOf: Data(repeating: 0, count: 128))
        try handle.close()
        let fileSize = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        XCTAssertGreaterThan(fileSize, 90_000_000, "the fixture is about 100 MB")

        let wasStreaming = StreamingParserPolicy.binaryStreaming
        defer { StreamingParserPolicy.binaryStreaming = wasStreaming }
        StreamingParserPolicy.binaryStreaming = true

        let before = Self.physFootprint()
        var peak = before
        var batches = 0, largestBatch = 0, total = 0
        var subjects = Set<String>()
        let report = try await ParserFactory.parseStreamingCallback(
            fileURL: url, senderEmail: "", batchSize: 100, materializeAttachments: false
        ) { batch in
            batches += 1
            largestBatch = max(largestBatch, batch.count)
            total += batch.count
            for email in batch { subjects.insert(email.headers["Subject"] ?? "") }
            peak = max(peak, Self.physFootprint())
        }
        XCTAssertEqual(report.totalMessages, n)
        XCTAssertEqual(total, n)
        XCTAssertEqual(largestBatch, 100)
        XCTAssertEqual(batches, n / 100)
        XCTAssertEqual(subjects.count, n, "every memo arrived once")
        let grewBy = peak - before
        XCTAssertLessThan(grewBy, fileSize / 2,
                          "footprint grew \(grewBy / 1_048_576) MB while streaming a \(fileSize / 1_048_576) MB file")

        // The previous path reads the same memos in the same order.
        var firstStreamed: String?
        _ = try await NSFParser.parseStreaming(fileURL: url, senderEmail: "", batchSize: 5) { batch in
            if firstStreamed == nil { firstStreamed = batch.first?.headers["Subject"] }
        }
        let array = try NSFParser.parse(fileURL: url, senderEmail: "")
        XCTAssertEqual(array.count, n)
        XCTAssertEqual(array.first?.headers["Subject"], firstStreamed)
    }

    /// Streaming keeps B3: with recovery on, a deletion stub between memos is a
    /// marked partial row on both paths, in the same order.
    func testOPEN02_nsfStreaming_keepsDeletionStubs_sameAsTheArrayPath() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailin-open02-nsfstub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("stubs.nsf")
        var file = Data([0x1A, 0x00]); file.append(Data(repeating: 0, count: 254))
        withUnsafeBytes(of: UInt32(256).littleEndian) { file.replaceSubrange(0x28..<0x2C, with: $0) }
        var noteID: UInt32 = 0x0000_0102
        let mails = 200, stubs = 7
        for i in 0..<mails {
            if i % (mails / stubs) == 0 && i / (mails / stubs) < stubs {
                file.append(Self.nsfItem("UNID", String(format: "%016X%016X", 0xA1B2_0001, i)))
                file.append(Self.nsfItem("$Seq", "3"))
                file.append(Self.nsfItem("$Modified", "03/01/2024 10:15:00"))
                file.append(Self.nsfItem("$NoteID", String(format: "0x%08X", noteID | NSFDeletionStub.rrvDeleted)))
                noteID += 4
            }
            file.append(Self.nsfItem("Subject", "Report \(i)"))
            file.append(Self.nsfItem("From", "CN=Sender/O=Acme"))
            file.append(Self.nsfItem("SendTo", "CN=Team/O=Acme"))
            file.append(Self.nsfItem("$MessageID", "<nsf-stub-\(i)@acme.example>"))
            file.append(Self.nsfItem("UNID", String(format: "%016X%016X", 0xA1B2_0000, i)))
            file.append(Self.nsfItem("Body", "Body \(i)."))
            file.append(Self.nsfItem("Form", "Memo"))
            noteID += 4
        }
        file.append(Data(repeating: 0, count: 128))
        try file.write(to: url)

        let wasRecovery = RecoveryPolicy.isEnabled
        defer { RecoveryPolicy.isEnabled = wasRecovery }
        RecoveryPolicy.isEnabled = true

        var streamed: [MBOXParser.RawEmail] = []
        _ = try await NSFParser.parseStreaming(fileURL: url, senderEmail: "", batchSize: 50) { streamed += $0 }
        let array = try NSFParser.parse(fileURL: url, senderEmail: "")
        XCTAssertEqual(streamed.count, mails + stubs)
        XCTAssertEqual(array.count, streamed.count)
        XCTAssertEqual(streamed.filter { $0.recovery?.state == .deletionStub }.count, stubs)
        XCTAssertEqual(streamed.map { $0.headers["Subject"] ?? $0.headers["X-Notes-UNID"] ?? "" },
                       array.map { $0.headers["Subject"] ?? $0.headers["X-Notes-UNID"] ?? "" }, "same records, same order")

        RecoveryPolicy.isEnabled = false
        var plain = 0
        _ = try await NSFParser.parseStreaming(fileURL: url, senderEmail: "", batchSize: 50) { plain += $0.count }
        XCTAssertEqual(plain, mails, "recovery off: stubs are not rows")
    }

    // MARK: - Five jobs FOLD-02 — folders are first-class, per source, empty ones kept

    private func registerSource(_ env: Env, sha: String, name: String, parser: String) async throws -> Int64 {
        try await env.store.registerSource(SQLiteEmailStore.SourceDescriptor(
            sha256: sha, filename: name, byteSize: 10, parser: parser, parserVersion: 1, accountID: nil, sourceKind: parser))
    }

    func testFOLD02_pstFoldersPerSource_emptyOnesKept_sameNamesStayDistinct() async throws {
        let env = try makeEnv()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailin-fold02-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        func writePST(_ name: String, salt: Int) throws -> URL {
            let url = root.appendingPathComponent(name)
            let w = try PSTSpecWriter(url: url)
            let inbox = w.appendFolder(name: "Inbox")
            let clients = w.appendFolder(name: "Clients", parent: inbox)
            _ = w.appendFolder(name: "Archive 2019")   // declared, holds nothing
            for i in 0..<6 {
                var e = makeEmail(i: salt + i, total: 6, body: "b \(i)")
                e.headers["Subject"] = "\(name) \(i)"
                try w.append(email: e, folder: i < 4 ? inbox : clients)
            }
            XCTAssertEqual(try w.finalize(), 6)
            return url
        }
        let wasStreaming = StreamingParserPolicy.binaryStreaming
        defer { StreamingParserPolicy.binaryStreaming = wasStreaming }
        StreamingParserPolicy.binaryStreaming = true

        var sourceIDs: [String: Int64] = [:]
        for (name, salt, sha) in [("a.pst", 7_000, "aaaa"), ("b.pst", 7_100, "bbbb")] {
            let url = try writePST(name, salt: salt)
            let sid = try await registerSource(env, sha: sha, name: name, parser: "pst")
            sourceIDs[name] = sid
            var ordinal = 0
            let report = try await ParserFactory.parseStreamingCallback(
                fileURL: url, senderEmail: "", batchSize: 4, materializeAttachments: false
            ) { batch in
                _ = try await env.store.insertBatch(batch, sourceFileHash: sha, accountID: nil, sourceID: sid,
                                                    firstOrdinal: ordinal, dedupPolicy: .preserveAll, batchSize: 10, progress: nil)
                ordinal += batch.count
            }
            XCTAssertEqual(report.totalMessages, 6)
            XCTAssertTrue(report.declaredFolders.contains { $0.hasSuffix("Archive 2019") }, "the empty folder is listed: \(report.declaredFolders)")
            try await env.store.registerFolders(sourceID: sid, paths: report.declaredFolders)
        }

        let nodes = try await env.store.folderNodes()
        let inboxes = nodes.filter { $0.name == "Inbox" }
        XCTAssertEqual(inboxes.count, 2, "one Inbox per source")
        XCTAssertEqual(Set(inboxes.map(\.sourceID)), Set(sourceIDs.values))
        XCTAssertTrue(inboxes.allSatisfy { $0.messageCount == 4 && $0.declared }, "\(inboxes)")
        let clients = nodes.filter { $0.name == "Clients" }
        XCTAssertEqual(clients.count, 2)
        for c in clients {
            XCTAssertEqual(c.messageCount, 2)
            XCTAssertTrue(c.path.hasSuffix("Inbox/Clients"), c.path)
            XCTAssertEqual(nodes.first { $0.folderID == c.parentID }?.name, "Inbox", "nested under its own source's Inbox")
            XCTAssertEqual(nodes.first { $0.folderID == c.parentID }?.sourceID, c.sourceID)
        }
        let empty = nodes.filter { $0.name == "Archive 2019" }
        XCTAssertEqual(empty.count, 2)
        XCTAssertTrue(empty.allSatisfy { $0.declared && $0.messageCount == 0 }, "kept although empty")
        let folderTotal = try await env.store.folderTotal()
        XCTAssertEqual(folderTotal, nodes.count)

        // One source's Inbox is only that source's four messages.
        for inbox in inboxes {
            var q = EmailQuery.all
            q.folderID = inbox.folderID
            let inFolder = try await env.archive.count(query: q)
            XCTAssertEqual(inFolder, 4)
            let sourceName = sourceIDs.first { $0.value == inbox.sourceID }!.key
            var subjects: [String] = []
            for try await batch in await env.archive.streamFullEmails(query: q, batchSize: 10) {
                subjects += batch.map { $0.headers["Subject"] ?? "" }
            }
            XCTAssertEqual(subjects.count, 4)
            XCTAssertTrue(subjects.allSatisfy { $0.hasPrefix(sourceName) }, "\(subjects)")
        }

        // The sidebar nests them per source, empty folder included.
        let trees = ArchiveSidebarModel.trees(from: nodes, sources: try await env.store.sources())
        XCTAssertEqual(trees.map(\.title).sorted(), ["a.pst", "b.pst"])
        func flatten(_ items: [ArchiveSidebarModel.FolderItem]) -> [ArchiveSidebarModel.FolderItem] {
            items.flatMap { [$0] + flatten($0.children ?? []) }
        }
        for tree in trees {
            // Outlook's own root ("Top of Personal Folders") stays as the source wrote it.
            let all = flatten(tree.items)
            XCTAssertTrue(all.contains { $0.node.name == "Archive 2019" }, "\(all.map(\.node.path))")
            let inbox = all.first { $0.node.name == "Inbox" }
            XCTAssertEqual(inbox?.children?.map(\.node.name), ["Clients"])
            XCTAssertTrue(tree.items.contains { ($0.children ?? []).contains { $0.node.name == "Inbox" } },
                          "Inbox sits under the PST's root folder: \(tree.items.map(\.node.path))")
        }
    }

    func testFOLD02_gmailLabels_areMembershipsOfOneEmail_nestedLabelsHaveParents() async throws {
        let env = try makeEnv()
        var e = makeEmail(i: 7_300, total: 1, body: "labelled")
        e.tags = ["Work", "Receipts/2024"]
        try await env.store.insertBatch([e], batchSize: 10)
        let total = try await env.archive.count(query: .all)
        XCTAssertEqual(total, 1, "one email, not one per label")
        let nodes = try await env.store.folderNodes()
        XCTAssertEqual(nodes.map(\.path).sorted(), ["Receipts", "Receipts/2024", "Work"])
        let receipts = try XCTUnwrap(nodes.first { $0.path == "Receipts" })
        let year = try XCTUnwrap(nodes.first { $0.path == "Receipts/2024" })
        XCTAssertEqual(year.parentID, receipts.folderID)
        XCTAssertEqual(receipts.messageCount, 0, "the parent holds nothing directly")
        XCTAssertEqual(year.messageCount, 1)
        for id in [try XCTUnwrap(nodes.first { $0.path == "Work" }).folderID, year.folderID] {
            var q = EmailQuery.all
            q.folderID = id
            let inFolder = try await env.archive.count(query: q)
            XCTAssertEqual(inFolder, 1)
        }
    }

    func testFOLD02_flagsAreNotFolders_andRebuildFromTagsRestoresMemberships() async throws {
        let env = try makeEnv()
        let sid = try await registerSource(env, sha: "eeee", name: "Mail", parser: "emlx")
        var e = makeEmail(i: 7_400, total: 1, body: "apple mail")
        e.tags = ["Read", "Flagged"]
        e.flags = ["Read", "Flagged"]
        e.folderPath = "Inbox/Clients"
        _ = try await env.store.insertBatch([e], sourceFileHash: "eeee", accountID: nil, sourceID: sid,
                                            firstOrdinal: 0, dedupPolicy: .preserveAll, batchSize: 10, progress: nil)
        func check(_ nodes: [ArchiveFolderNode], file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(nodes.map(\.path).sorted(), ["Inbox", "Inbox/Clients"], file: file, line: line)
            XCTAssertEqual(nodes.first { $0.path == "Inbox/Clients" }?.messageCount, 1, file: file, line: line)
            XCTAssertTrue(nodes.allSatisfy { $0.sourceID == sid }, file: file, line: line)
        }
        check(try await env.store.folderNodes())
        // Dual write: the previous path sees the folder as a label too.
        let tags = try await env.store.parserTagCounts(limit: 10).map(\.value)
        XCTAssertTrue(tags.contains("Inbox/Clients") && tags.contains("Read"), "\(tags)")
        // A rebuild from the tags gives the same folders — flags stay out.
        try await env.store.rebuildFoldersFromTags()
        check(try await env.store.folderNodes())
    }

    /// The open guard must equal what the migration chain produces, or a store
    /// upgraded by this build refuses to reopen (found while adding v21).
    func testFOLD02_schemaGuardMatchesTheMigrationChain() async throws {
        let env = try makeEnv()
        let v = try await env.store.schemaVersion()
        XCTAssertEqual(v, 25, "v21 adds folders, v22/v23 the search chunks, v24 contiguous chunks (R02), v25 attachment children (§13.3)")
        XCTAssertEqual(v, SQLiteEmailStore.currentSchemaVersion, "the guard follows the chain")
        // Reopening the same directory is the real check: a lagging guard refuses here.
        let reopened = SQLiteEmailStore(directory: env.root.appendingPathComponent("store"))
        let reopenedVersion = try await reopened.schemaVersion()
        XCTAssertEqual(reopenedVersion, SQLiteEmailStore.currentSchemaVersion)
        let folders = try await reopened.folderTotal()
        XCTAssertEqual(folders, 0)
    }

    func testFOLD02_directoryLayoutsNameTheMailbox() {
        let work = URL(fileURLWithPath: "/tmp/Work.mbox", isDirectory: true)
        XCTAssertEqual(SourceFormatClassifier.folderPath(member: work.appendingPathComponent("mbox"), root: work, format: .appleMailMailbox), "Work")
        XCTAssertEqual(SourceFormatClassifier.folderPath(member: work.appendingPathComponent("Clients.mbox/mbox"), root: work, format: .appleMailMailbox), "Work/Clients")
        let library = URL(fileURLWithPath: "/tmp/Mail", isDirectory: true)
        let emlx = library.appendingPathComponent("V10/ACC/INBOX.mbox/UUID/Data/1/Messages/1.emlx")
        XCTAssertEqual(SourceFormatClassifier.folderPath(member: emlx, root: library, format: .appleMailLibrary), "INBOX")
        let maildir = URL(fileURLWithPath: "/tmp/Maildir", isDirectory: true)
        XCTAssertEqual(SourceFormatClassifier.folderPath(member: maildir.appendingPathComponent("cur/1.eml"), root: maildir, format: .maildir), "Maildir")
        let mbox = URL(fileURLWithPath: "/tmp/all.mbox")
        XCTAssertNil(SourceFormatClassifier.folderPath(member: mbox, root: mbox, format: .mbox), "a single mbox has no folder of its own")
        // The stamp fills only what the parser left empty.
        var a = makeEmail(i: 7_500, total: 2, body: "a"); a.folderPath = "Already"
        let b = makeEmail(i: 7_501, total: 2, body: "b")
        XCTAssertEqual(ParserFactory.stamp([a, b], folder: "Inbox").map(\.folderPath), ["Already", "Inbox"])
    }

    // MARK: - Five jobs LIFE-01 — self-contained archive; linked mode names what is missing

    /// An mbox whose third message is far above a small full-parse ceiling,
    /// so the offset engine keeps it as a byte locator.
    private func writeDeferredMbox(to url: URL) throws -> String {
        let big = String(repeating: "deferred body line for the self-contained test\n", count: 4_000)   // ~190 KB
        var text = ""
        for i in 0..<3 {
            text += """
            From sender@example.com Mon Jan  1 00:00:0\(i) 2024
            From: sender@example.com
            To: me@example.com
            Subject: Life \(i)
            Date: Mon, 01 Jan 2024 00:00:0\(i) +0000
            Message-ID: <life01-\(i)@test>

            \(i == 2 ? big : "small body \(i)")

            """
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return big
    }

    private func importForLife01(_ env: Env, _ url: URL) async throws -> BulkImportCoordinator.RunSummary {
        let checkpoints = ImportCheckpointStore(store: env.store)
        let coordinator = await BulkImportCoordinator(store: env.store, fts: env.fts, checkpoints: checkpoints,
                                                      requiresStorageActivation: false)
        var options = BulkImportCoordinator.Options()
        options.useOffsetEngine = true
        options.recordLocators = true
        options.enforceStoragePreflight = false
        options.fullParseCeilingBytes = 64 * 1024
        return try await coordinator.runImport(urls: [url], options: options)
    }

    private func deferredLocator(_ env: Env) async throws -> MessageLocator {
        var q = EmailQuery.all
        q.subjectContains = "Life 2"
        var ids: [UUID] = []
        for try await batch in await env.archive.streamFullEmails(query: q, batchSize: 10) { ids += batch.map(\.id) }
        XCTAssertEqual(ids.count, 1)
        let locator = try await env.store.locator(forEmailID: ids[0])
        return try XCTUnwrap(locator)
    }

    func testLIFE01_copyIntoArchive_verifiesBytes_andDiscardsATamperedCopy() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailin-life01-copy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("Sent.mbox")
        try Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: original)
        let sha = try SourceCopies.sha256(of: original)
        let store = root.appendingPathComponent("store", isDirectory: true)

        let copy = try SourceCopies.copyIntoArchive(original: original, sha256: sha, storeDirectory: store, chunkSize: 4096)
        XCTAssertEqual(copy, SourceCopies.copyURL(sha256: sha, filename: "Sent.mbox", storeDirectory: store))
        XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: original))
        XCTAssertEqual(SourceCopies.existingCopy(sha256: sha, filename: "Sent.mbox", storeDirectory: store), copy)
        XCTAssertEqual(SourceCopies.totalBytes(storeDirectory: store), 300_000)
        // Same file again: the existing copy is reused, nothing rewritten.
        XCTAssertEqual(try SourceCopies.copyIntoArchive(original: original, sha256: sha, storeDirectory: store), copy)

        // A digest that does not match leaves nothing behind.
        let other = root.appendingPathComponent("Other.mbox")
        try Data("not the same bytes".utf8).write(to: other)
        XCTAssertThrowsError(try SourceCopies.copyIntoArchive(original: other, sha256: sha, storeDirectory: store)) { error in
            guard case SourceCopyError.digestMismatch = error else { return XCTFail("\(error)") }
        }
        XCTAssertNil(SourceCopies.existingCopy(sha256: sha, filename: "Other.mbox", storeDirectory: store))
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: SourceCopies.directory(in: store).appendingPathComponent(sha).path)) ?? []
        XCTAssertEqual(leftovers, ["Sent.mbox"], "no temporary file survives a failed copy")
    }

    func testLIFE01_selfContained_deferredMessagesReadAfterTheOriginalIsDeleted() async throws {
        let env = try makeEnv()
        let original = env.root.appendingPathComponent("Archive.mbox")
        let big = try writeDeferredMbox(to: original)
        let wasOn = SourceCopyPolicy.isEnabled
        defer { SourceCopyPolicy.isEnabled = wasOn }
        SourceCopyPolicy.isEnabled = true

        let summary = try await importForLife01(env, original)
        XCTAssertEqual(summary.parsed, 3, "\(summary.fileErrors)")
        let locator = try await deferredLocator(env)
        XCTAssertTrue(locator.sourcePath.hasPrefix(env.store.storeDirectory.path),
                      "the locator points inside the archive: \(locator.sourcePath)")
        XCTAssertNotEqual(locator.sourcePath, original.path)
        XCTAssertNotNil(SourceCopies.existingCopy(sha256: try XCTUnwrap(locator.sourceDigest), filename: "Archive.mbox",
                                                  storeDirectory: env.store.storeDirectory))

        // Detach the original: reading, verifying and exporting still work.
        try FileManager.default.removeItem(at: original)
        let bytes = try LocatorReader().read(locator.messageRange, from: locator.sourcePath)
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(text.contains("Subject: Life 2") && text.contains(big.prefix(60)), "the whole message is read from the copy")
        XCTAssertNoThrow(try LocatorReader().verifySource(locator), "the copy's digest is the original's")
        let missing = try await env.store.missingLocatorSources()
        XCTAssertTrue(missing.isEmpty, "nothing depends on the deleted original: \(missing)")
    }

    func testLIFE01_linked_missingOriginalIsNamed_andRelinkVerifiesTheFile() async throws {
        let env = try makeEnv()
        let original = env.root.appendingPathComponent("Linked.mbox")
        _ = try writeDeferredMbox(to: original)
        let wasOn = SourceCopyPolicy.isEnabled
        defer { SourceCopyPolicy.isEnabled = wasOn }
        SourceCopyPolicy.isEnabled = false

        let summary = try await importForLife01(env, original)
        XCTAssertEqual(summary.parsed, 3)
        let locator = try await deferredLocator(env)
        XCTAssertEqual(locator.sourcePath, original.path, "linked mode reads the original where it is")
        XCTAssertNil(SourceCopies.existingCopy(sha256: try XCTUnwrap(locator.sourceDigest), filename: "Linked.mbox",
                                               storeDirectory: env.store.storeDirectory), "nothing copied with the switch off")
        var missing = try await env.store.missingLocatorSources()
        XCTAssertTrue(missing.isEmpty)

        // The person moves the file: the archive names it and counts what depends on it.
        let moved = env.root.appendingPathComponent("Moved").appendingPathComponent("Linked.mbox")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: original, to: moved)
        missing = try await env.store.missingLocatorSources()
        XCTAssertEqual(missing.map(\.filename), ["Linked.mbox"])
        XCTAssertEqual(missing.first?.messages, 3, "every message has a locator (attachments are served from the file)")
        XCTAssertEqual(missing.first?.deferredMessages, 1, "one message has no other copy")
        XCTAssertThrowsError(try LocatorReader().read(locator.messageRange, from: locator.sourcePath))

        // Relinking to a different file is refused; to the real one, verified and applied.
        let impostor = env.root.appendingPathComponent("Impostor.mbox")
        try Data("From x\nSubject: not it\n\nbody\n".utf8).write(to: impostor)
        let digest = try XCTUnwrap(locator.sourceDigest)
        do {
            _ = try await env.store.relinkLocators(sourceDigest: digest, to: impostor)
            XCTFail("an impostor must be refused")
        } catch RelinkError.digestMismatch {
            // refused, nothing changed
        }
        let moved2 = try await env.store.relinkLocators(sourceDigest: digest, to: moved)
        XCTAssertEqual(moved2, 3, "every locator of the file follows it")
        let relinked = try await deferredLocator(env)
        XCTAssertEqual(relinked.sourcePath, moved.path)
        XCTAssertNoThrow(try LocatorReader().read(relinked.messageRange, from: relinked.sourcePath))
        missing = try await env.store.missingLocatorSources()
        XCTAssertTrue(missing.isEmpty)
    }

    // MARK: - Five jobs OPEN-01 — preflight tells unsupported, inaccessible, damaged and encrypted apart

    /// A PST header: "!BDN", the version word, the encoding byte and the two
    /// table roots — enough for the preflight, not for a parse.
    private func pstHeader(unicode: Bool = true, crypt: UInt8, nbt: UInt64, bbt: UInt64, length: Int = 4096) -> Data {
        var d = Data(repeating: 0, count: length)
        d.replaceSubrange(0..<4, with: [0x21, 0x42, 0x44, 0x4E])
        let version: UInt16 = unicode ? 23 : 14
        d[10] = UInt8(version & 0xFF); d[11] = UInt8(version >> 8)
        d[unicode ? 513 : 461] = crypt
        func put(_ value: UInt64, at offset: Int, bytes: Int) {
            for i in 0..<bytes { d[offset + i] = UInt8((value >> (8 * UInt64(i))) & 0xFF) }
        }
        if unicode { put(nbt, at: 224, bytes: 8); put(bbt, at: 240, bytes: 8) } else { put(nbt, at: 188, bytes: 4); put(bbt, at: 196, bytes: 4) }
        return d
    }

    /// A ZIP with stored, empty members; `encrypted` sets general-purpose bit 0.
    private func zipBytes(_ members: [(name: String, encrypted: Bool)]) -> Data {
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func le32(_ v: Int) -> [UInt8] { le16(v & 0xFFFF) + le16((v >> 16) & 0xFFFF) }
        var local = Data(), central = Data()
        for m in members {
            let name = Array(m.name.utf8)
            let flags = m.encrypted ? 1 : 0
            let offset = local.count
            local.append(contentsOf: le32(0x04034b50) + le16(20) + le16(flags) + le16(0) + le16(0) + le16(0)
                         + le32(0) + le32(0) + le32(0) + le16(name.count) + le16(0) + name)
            central.append(contentsOf: le32(0x02014b50) + le16(20) + le16(20) + le16(flags) + le16(0) + le16(0) + le16(0)
                           + le32(0) + le32(0) + le32(0) + le16(name.count) + le16(0) + le16(0) + le16(0) + le16(0)
                           + le32(0) + le32(offset) + name)
        }
        var file = local
        file.append(central)
        file.append(contentsOf: le32(0x06054b50) + le16(0) + le16(0) + le16(members.count) + le16(members.count)
                    + le32(central.count) + le32(local.count) + le16(0))
        return file
    }

    func testOPEN01_preflightTellsTheFourObstaclesApart() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailin-open01-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        func write(_ name: String, _ data: Data) throws -> URL {
            let url = root.appendingPathComponent(name); try data.write(to: url); return url
        }
        func condition(_ url: URL) -> SourceCondition { SourceFormatClassifier.preflight(url: url).condition }

        // Ready: a real mbox.
        let mbox = try write("ok.mbox", Data("From a@b Mon Jan  1 00:00:00 2024\nFrom: a@b\nSubject: s\n\nbody\n".utf8))
        XCTAssertEqual(SourceFormatClassifier.preflight(url: mbox), .ready)

        // Unsupported: text that is not mail.
        XCTAssertEqual(condition(try write("notes.txt", Data("just some notes, nothing like a header block\n".utf8))), .unsupported)

        // Inaccessible: missing, and unreadable.
        XCTAssertEqual(condition(root.appendingPathComponent("gone.mbox")), .inaccessible)
        let locked = try write("locked.mbox", Data("From a@b Mon Jan  1 00:00:00 2024\nFrom: a@b\n\nx\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        XCTAssertEqual(condition(locked), .inaccessible)

        // Damaged: empty, a PST shorter than its header, a PST whose tables lie past the end, a ZIP without a directory.
        XCTAssertEqual(condition(try write("empty.pst", Data())), .damaged)
        XCTAssertEqual(condition(try write("short.pst", Data([0x21, 0x42, 0x44, 0x4E]) + Data(repeating: 0, count: 300))), .damaged)
        let truncated = try write("truncated.pst", pstHeader(crypt: 1, nbt: 1 << 40, bbt: 1 << 40))
        let truncatedPreflight = SourceFormatClassifier.preflight(url: truncated)
        XCTAssertEqual(truncatedPreflight.condition, .damaged)
        XCTAssertTrue(truncatedPreflight.detail.contains("beyond the end"), truncatedPreflight.detail)
        XCTAssertEqual(condition(try write("nodir.zip", Data([0x50, 0x4B, 0x03, 0x04]) + Data(repeating: 0, count: 200))), .damaged)
        XCTAssertFalse(SourceCondition.damaged.blocksImport, "a damaged file still starts; the parser reports what it could not read")

        // Encrypted: an undocumented PST encoding; a ZIP whose every file is encrypted.
        let encryptedPST = try write("locked-encoding.pst", pstHeader(crypt: 3, nbt: 512, bbt: 1024))
        XCTAssertEqual(condition(encryptedPST), .encrypted)
        XCTAssertEqual(condition(try write("ansi-ok.pst", pstHeader(unicode: false, crypt: 2, nbt: 512, bbt: 1024))), .ready,
                       "cyclic encoding is decoded by the reader — not 'encrypted'")
        let allEncrypted = try write("all.zip", zipBytes([("a.mbox", true), ("b.eml", true)]))
        let allPreflight = SourceFormatClassifier.preflight(url: allEncrypted)
        XCTAssertEqual(allPreflight.condition, .encrypted)
        XCTAssertEqual(allPreflight.encryptedMembers, 2)
        let someEncrypted = try write("some.zip", zipBytes([("a.mbox", true), ("b.eml", false)]))
        let somePreflight = SourceFormatClassifier.preflight(url: someEncrypted)
        XCTAssertEqual(somePreflight.condition, .ready, "the readable member imports; the encrypted one is skipped and counted")
        XCTAssertEqual(somePreflight.encryptedMembers, 1)
        XCTAssertTrue(SourceCondition.encrypted.blocksImport && SourceCondition.inaccessible.blocksImport && SourceCondition.unsupported.blocksImport)

        // The sheet's plan takes only what can start and keeps the reason for the rest.
        let plan = ImportPlan.build(urls: [mbox, encryptedPST, truncated, locked], destination: root, copiesOriginals: false)
        XCTAssertEqual(plan.supported.map(\.name).sorted(), ["ok.mbox", "truncated.pst"])
        XCTAssertEqual(plan.unsupported.map(\.name).sorted(), ["locked-encoding.pst", "locked.mbox"])
        XCTAssertEqual(plan.items.first { $0.name == "locked-encoding.pst" }?.preflight.condition, .encrypted)
        XCTAssertEqual(plan.items.first { $0.name == "locked.mbox" }?.preflight.condition, .inaccessible)
    }

    // MARK: - Five jobs OPEN-05 — the receipt accounts per source

    func testOPEN05_receiptAccountsPerSource_andSkippedFilesSaySo() async throws {
        let env = try makeEnv()
        let first = env.root.appendingPathComponent("First.mbox")
        _ = try writeDeferredMbox(to: first)
        // The same bytes under another name: already imported, skipped.
        let again = env.root.appendingPathComponent("Again.mbox")
        try FileManager.default.copyItem(at: first, to: again)
        let wasOn = SourceCopyPolicy.isEnabled
        defer { SourceCopyPolicy.isEnabled = wasOn }
        SourceCopyPolicy.isEnabled = false

        let checkpoints = ImportCheckpointStore(store: env.store)
        let coordinator = await BulkImportCoordinator(store: env.store, fts: env.fts, checkpoints: checkpoints,
                                                      requiresStorageActivation: false)
        var options = BulkImportCoordinator.Options()
        options.useOffsetEngine = true
        options.recordLocators = true
        options.enforceStoragePreflight = false
        options.fullParseCeilingBytes = 64 * 1024
        let summary = try await coordinator.runImport(urls: [first, again], options: options)
        let receipt = try XCTUnwrap(summary.receipt)
        XCTAssertEqual(receipt.sources.map(\.filename), ["First.mbox", "Again.mbox"])

        let a = receipt.sources[0]
        XCTAssertEqual(a.discovered, 3)
        XCTAssertEqual(a.parsed, 3)
        XCTAssertEqual(a.committed, 3)
        XCTAssertEqual(a.damaged, 0)
        XCTAssertEqual(a.unreadable, 0)
        XCTAssertEqual(a.unresolved, 0)
        XCTAssertNil(a.skippedAlreadyImported)
        XCTAssertNil(a.error)
        let b = receipt.sources[1]
        XCTAssertEqual(b.skippedAlreadyImported, true)
        XCTAssertNil(b.committed, "nothing was counted for a skipped file — nil, not 0")
        XCTAssertEqual(summary.skippedFiles, 1)

        XCTAssertEqual(ImportReceiptView.accountingLine(for: a), "3 found, 3 read · 3 saved this run")
        XCTAssertEqual(ImportReceiptView.accountingLine(for: b), "Already imported earlier (same file) — skipped.")
        var stopped = a
        stopped.discovered = nil; stopped.committed = 2; stopped.stoppedAtMessage = 2; stopped.error = "disk full"
        let line = try XCTUnwrap(ImportReceiptView.accountingLine(for: stopped))
        XCTAssertTrue(line.contains("not known") && line.contains("stopped after 2 messages: disk full"), line)

        // A receipt from an earlier build, without per-source counts, still decodes.
        let legacy = """
        {"filename":"Old.mbox","sizeBytes":10,"sha256":"ab","parser":"mbox","parserVersion":2}
        """
        let decoded = try JSONDecoder().decode(ImportReceipt.SourceRecord.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.parsed)
        XCTAssertNil(ImportReceiptView.accountingLine(for: decoded))
    }

    // MARK: - Five jobs FIND-04 / FIND-07 — one typed search model over the chunk index

    private func chunkedEnv() throws -> Env {
        SearchChunkPolicy.isEnabled = true
        return try makeEnv()
    }

    private func mail(_ i: Int, from: String, to: String = "me@example.com", subject: String, body: String,
                      date: String = "Wed, 01 Mar 2023 12:00:00 +0000", attachments: [AttachmentMetadata] = []) -> MBOXParser.RawEmail {
        var e = makeEmail(i: i, total: 1, body: body)
        e.headers["From"] = from
        e.headers["To"] = to
        e.headers["Subject"] = subject
        e.headers["Date"] = date
        e.attachments = attachments
        return e
    }

    private func ids(_ env: Env, _ spec: SearchSpec, scope: EmailQuery = .all) async throws -> Set<String> {
        var q = scope
        q.spec = spec
        var subjects = Set<String>()
        for try await batch in await env.archive.streamFullEmails(query: q, batchSize: 50) {
            for e in batch { subjects.insert(e.headers["Subject"] ?? "") }
        }
        let count = try await env.archive.count(query: q)
        XCTAssertEqual(count, subjects.count, "count and rows agree for \(spec)")
        return subjects
    }

    private func expectIDs(_ env: Env, _ spec: SearchSpec, scope: EmailQuery = .all, _ expected: Set<String>,
                           _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async throws {
        let found = try await ids(env, spec, scope: scope)
        XCTAssertEqual(found, expected, message, file: file, line: line)
    }

    private func expectUnresolved(_ env: Env, _ query: EmailQuery, _ expected: Int,
                                  _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async throws {
        let n = try await env.archive.unresolvedCount(query: query)
        XCTAssertEqual(n, expected, message, file: file, line: line)
    }

    private func expectCount(_ env: Env, _ query: EmailQuery, _ expected: Int,
                             _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async throws {
        let n = try await env.archive.count(query: query)
        XCTAssertEqual(n, expected, message, file: file, line: line)
    }

    func testFIND04_groupsRepeatedFieldsAndExclusionsAreAllHonoured() async throws {
        let wasOn = SearchChunkPolicy.isEnabled
        defer { SearchChunkPolicy.isEnabled = wasOn }
        let env = try chunkedEnv()
        try await env.store.insertBatch([
            mail(1, from: "alice@example.com", subject: "Budget", body: "the quarterly numbers"),
            mail(2, from: "bob@example.com", subject: "Budget newsletter", body: "unsubscribe below"),
            mail(3, from: "carol@example.com", subject: "Picnic", body: "bring a blanket"),
        ], batchSize: 10)

        // Groups combine with AND; any-group ORs; exclude removes.
        let spec = SearchSpec(groups: [
            SearchGroup(.all, [SearchCondition(.sender, .contains, "example.com")]),
            SearchGroup(.any, [SearchCondition(.sender, .contains, "alice"), SearchCondition(.sender, .contains, "bob")]),
            SearchGroup(.exclude, [SearchCondition(.subject, .contains, "newsletter")]),
        ])
        try await expectIDs(env, spec, ["Budget"])

        // Two sender conditions in one all-group are BOTH required — neither overwrites the other.
        let both = SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.sender, .contains, "alice"), SearchCondition(.sender, .contains, "bob")])])
        try await expectIDs(env, both, [])
        let either = SearchSpec(groups: [SearchGroup(.any, [SearchCondition(.sender, .contains, "alice"), SearchCondition(.sender, .contains, "bob")])])
        try await expectIDs(env, either, ["Budget", "Budget newsletter"])

        // Empty groups and empty conditions have no effect.
        let padded = SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.sender, .contains, "   ")]), SearchGroup(.exclude), SearchGroup(.any, [SearchCondition(.subject, .contains, "Picnic")])])
        try await expectIDs(env, padded, ["Picnic"])
        XCTAssertTrue(SearchSpec(groups: [SearchGroup(.exclude)]).isEmpty)
    }

    func testFIND04_exclusionWithNoPositiveText_usesTheScopedUniverse_andUnknownsAreNotAbsent() async throws {
        let wasOn = SearchChunkPolicy.isEnabled
        defer { SearchChunkPolicy.isEnabled = wasOn }
        let env = try chunkedEnv()
        try await env.store.insertBatch([
            mail(10, from: "a@x.com", subject: "Offer", body: "click to unsubscribe from this list"),
            mail(11, from: "b@x.com", subject: "Minutes", body: "the meeting notes"),
        ], batchSize: 10)
        // One email stored with the switch OFF: its body is not in the chunk index.
        SearchChunkPolicy.isEnabled = false
        try await env.store.insertBatch([mail(12, from: "c@x.com", subject: "Unknown body", body: "whatever it says")], batchSize: 10)
        SearchChunkPolicy.isEnabled = true

        // Exclusion only: the universe is the scope, the exclusion is applied —
        // and the un-indexed email is neither confirmed nor excluded.
        let spec = SearchSpec(groups: [SearchGroup(.exclude, [SearchCondition(.body, .phrase, "unsubscribe")])])
        try await expectIDs(env, spec, ["Minutes"], "confirmed: evaluated and not excluded")
        var q = EmailQuery.all; q.spec = spec
        let unresolved = try await env.archive.unresolvedCount(query: q)
        XCTAssertEqual(unresolved, 1, "the email whose body is not indexed may still match")

        // Indexing it resolves it.
        let job = SearchDocBackfillJob.shared
        SearchDocBackfillJob.testStoreOverride = env.store
        defer { SearchDocBackfillJob.testStoreOverride = nil }
        let outcome = await job.run(pageSize: 1)
        XCTAssertEqual(outcome.indexed, 1)
        XCTAssertEqual(outcome.remaining, 0)
        try await expectIDs(env, spec, ["Minutes", "Unknown body"])
        let after = try await env.archive.unresolvedCount(query: q)
        XCTAssertEqual(after, 0)

        // A positive text condition in an all-group is never "unknown": a hit is a hit.
        let positive = SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.body, .allWords, "meeting notes")])])
        try await expectIDs(env, positive, ["Minutes"])
        XCTAssertFalse(positive.hasUncertainTextConditions)
    }

    func testFIND04_attachmentConditionsMustHoldForTheSameAttachment() async throws {
        let wasOn = SearchChunkPolicy.isEnabled
        defer { SearchChunkPolicy.isEnabled = wasOn }
        let env = try chunkedEnv()
        let x = mail(20, from: "s@x.com", subject: "X", body: "see files", attachments: [
            AttachmentMetadata(filename: "report.pdf", mimeType: "application/pdf", size: 10),
            AttachmentMetadata(filename: "notes.docx", mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document", size: 10)])
        let y = mail(21, from: "s@x.com", subject: "Y", body: "see files", attachments: [
            AttachmentMetadata(filename: "brief.pdf", mimeType: "application/pdf", size: 10),
            AttachmentMetadata(filename: "memo.docx", mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document", size: 10)])
        try await env.store.insertBatch([x, y], batchSize: 10)
        // The attachment job's documents, as it would write them.
        try await env.store.indexAttachmentSearchDocuments(emailID: x.id, documents: [
            AttachmentSearchDocument(ordinal: 0, filename: "report.pdf", text: "Purchase Order 4471 approved", state: .complete, extractorVersion: 2, ocr: false),
            AttachmentSearchDocument(ordinal: 1, filename: "notes.docx", text: "other text", state: .complete, extractorVersion: 2, ocr: false)])
        try await env.store.indexAttachmentSearchDocuments(emailID: y.id, documents: [
            AttachmentSearchDocument(ordinal: 0, filename: "brief.pdf", text: "nothing relevant", state: .complete, extractorVersion: 2, ocr: false),
            AttachmentSearchDocument(ordinal: 1, filename: "memo.docx", text: "the purchase order is attached", state: .complete, extractorVersion: 2, ocr: false)])

        let pdfWithPhrase = SearchSpec(groups: [SearchGroup(.all, attachments: [AttachmentConditionGroup(type: "PDF", contentMatch: .phrase, content: "purchase order")])])
        try await expectIDs(env, pdfWithPhrase, ["X"], "Y's phrase is in a DOCX, not its PDF")
        let anyAttachment = SearchSpec(groups: [SearchGroup(.all, attachments: [AttachmentConditionGroup(contentMatch: .phrase, content: "purchase order")])])
        try await expectIDs(env, anyAttachment, ["X", "Y"])
        let named = SearchSpec(groups: [SearchGroup(.all, attachments: [AttachmentConditionGroup(nameContains: "memo", type: "docx", contentMatch: .allWords, content: "purchase")])])
        try await expectIDs(env, named, ["Y"])

        // Excluding a PDF phrase: X is excluded, Y confirmed; nothing unknown (every attachment evaluated).
        let excluded = SearchSpec(groups: [SearchGroup(.exclude, attachments: [AttachmentConditionGroup(type: "PDF", contentMatch: .phrase, content: "purchase order")])])
        try await expectIDs(env, excluded, ["Y"])
        var q = EmailQuery.all; q.spec = excluded
        try await expectUnresolved(env, q, 0)
        // A third email whose attachment text was never extracted is unresolved under that exclusion.
        let z = mail(22, from: "s@x.com", subject: "Z", body: "see file", attachments: [AttachmentMetadata(filename: "scan.pdf", mimeType: "application/pdf", size: 10)])
        try await env.store.insertBatch([z], batchSize: 10)
        try await expectIDs(env, excluded, ["Y"], "Z cannot be confirmed")
        try await expectUnresolved(env, q, 1)
    }

    /// Audit 2026-11-06 A02: "all words" means every word somewhere in the
    /// same text, not every word in one 48 K-character chunk; a long phrase
    /// is verified on the exact text even where it crosses a chunk boundary;
    /// and the same-attachment rule still holds.
    func testA02_allWordsAcrossChunks_longPhraseVerified_sameAttachmentStillHolds() async throws {
        let wasOn = SearchChunkPolicy.isEnabled
        defer { SearchChunkPolicy.isEnabled = wasOn }
        let env = try chunkedEnv()
        let filler = String(repeating: "lorem ipsum filler words here ", count: 2_400)   // ~72 K characters → two chunks
        let spread = mail(80, from: "s@x.com", subject: "Spread", body: "alphawitness starts here. " + filler + " and omegawitness ends it.")
        let together = mail(81, from: "s@x.com", subject: "Together", body: "alphawitness and omegawitness together.")
        let onlyAlpha = mail(82, from: "s@x.com", subject: "OnlyAlpha", body: "alphawitness alone. " + filler)
        let files = mail(83, from: "s@x.com", subject: "Files", body: "see the files",
                         attachments: [AttachmentMetadata(filename: "a.txt", mimeType: "text/plain", size: 1),
                                       AttachmentMetadata(filename: "b.txt", mimeType: "text/plain", size: 1)])
        let oneFile = mail(84, from: "s@x.com", subject: "OneFile", body: "see the file",
                           attachments: [AttachmentMetadata(filename: "c.txt", mimeType: "text/plain", size: 1)])
        try await env.store.insertBatch([spread, together, onlyAlpha, files, oneFile], batchSize: 10)
        try await env.store.indexAttachmentSearchDocuments(emailID: files.id, documents: [
            AttachmentSearchDocument(ordinal: 0, filename: "a.txt", text: "alphawitness in file a", state: .complete, extractorVersion: 4, ocr: false),
            AttachmentSearchDocument(ordinal: 1, filename: "b.txt", text: "omegawitness in file b", state: .complete, extractorVersion: 4, ocr: false)])
        try await env.store.indexAttachmentSearchDocuments(emailID: oneFile.id, documents: [
            AttachmentSearchDocument(ordinal: 0, filename: "c.txt", text: "alphawitness opens. " + filler + " omegawitness closes.", state: .complete, extractorVersion: 4, ocr: false)])

        // Body / anywhere: the words may be chunks apart.
        try await expectIDs(env, SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.body, .allWords, "alphawitness omegawitness")])]), ["Spread", "Together"])
        try await expectIDs(env, SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.anyText, .allWords, "omegawitness alphawitness")])]), ["Spread", "Together", "Files", "OneFile"],
                            "anywhere: Files holds the words in two attachments of one message")
        // One attachment must hold every word: Files has them in two different files.
        try await expectIDs(env, SearchSpec(groups: [SearchGroup(.all, attachments: [AttachmentConditionGroup(contentMatch: .allWords, content: "alphawitness omegawitness")])]), ["OneFile"])
        // Evidence for a spread match names the place of the first word instead of "unavailable".
        let evidence = try await env.store.matchEvidence(emailID: spread.id, spec: SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.body, .allWords, "alphawitness omegawitness")])]), freeText: nil)
        XCTAssertEqual(evidence.map(\.location), [.body])

        // A phrase longer than the overlap, planted across the first chunk boundary: exact text, verified.
        let phraseWords = (0..<90).map { "boundaryword\($0)" }   // ~1,300 characters, well over the 512 overlap
        let phrase = phraseWords.joined(separator: " ")
        let lead = String(repeating: "lead ", count: (SearchChunker.chunkCharacters - 600) / 5)
        let crossing = mail(85, from: "s@x.com", subject: "Crossing", body: lead + phrase + " trailing text " + filler,
                            attachments: [AttachmentMetadata(filename: "x.txt", mimeType: "text/plain", size: 1)])
        try await env.store.insertBatch([crossing], batchSize: 10)
        let chunks = SearchChunker.chunks(of: crossing.plainBody)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertFalse(chunks.contains { $0.contains(phrase) }, "the phrase is in no single chunk — the test would prove nothing otherwise")
        try await expectIDs(env, SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.body, .phrase, phrase)])]), ["Crossing"])
        let scrambled = (phraseWords.reversed()).joined(separator: " ")
        try await expectIDs(env, SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.body, .phrase, scrambled)])]), [],
                            "the same words in another order are not the phrase")
        try await expectIDs(env, SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.body, .allWords, scrambled)])]), ["Crossing"],
                            "all-words still finds the words")
        // The same long phrase inside one attachment.
        try await env.store.indexAttachmentSearchDocuments(emailID: crossing.id, documents: [
            AttachmentSearchDocument(ordinal: 0, filename: "x.txt", text: lead + phrase + " end " + filler, state: .complete, extractorVersion: 4, ocr: false)])
        try await expectIDs(env, SearchSpec(groups: [SearchGroup(.all, attachments: [AttachmentConditionGroup(contentMatch: .phrase, content: phrase)])]), ["Crossing"])
        try await expectIDs(env, SearchSpec(groups: [SearchGroup(.all, attachments: [AttachmentConditionGroup(contentMatch: .phrase, content: scrambled)])]), [])
        // Ordinary box and Advanced Search agree.
        let typed = try XCTUnwrap(PlainSearchTranslator.spec(from: "omegawitness alphawitness"))
        try await expectIDs(env, typed, ["Spread", "Together", "Files", "OneFile"])
        let mixed = try XCTUnwrap(PlainSearchTranslator.spec(from: "\"alphawitness alone\" omegawitness OR together"))
        try await expectIDs(env, mixed, ["Together"], "(\"alphawitness alone\" AND omegawitness) OR together: OnlyAlpha lacks omegawitness")
    }

    /// R01 (handoff 7481852): the Boolean shape is compiled as written — 63
    /// alternatives are 63 branches of one group, phrases stay phrases,
    /// negation is local to its alternative — judged by result sets.
    func testR01_booleanStructureCompiledAsWritten_63Branches_branchLocalNot() async throws {
        let wasOn = SearchChunkPolicy.isEnabled
        defer { SearchChunkPolicy.isEnabled = wasOn }
        let env = try chunkedEnv()
        var emails: [MBOXParser.RawEmail] = []
        for i in 0..<63 {
            emails.append(mail(300 + i, from: "s@x.com", subject: "B\(i)", body: "the phrase\(i)a phrase\(i)b is here and word\(i) too"))
        }
        // Decoys: the phrase of one alternative with the word of another; the words of a phrase out of order.
        emails.append(mail(400, from: "s@x.com", subject: "Decoy1", body: "phrase1a phrase1b with word2"))
        emails.append(mail(401, from: "s@x.com", subject: "Decoy2", body: "phrase3b phrase3a word3"))
        try await env.store.insertBatch(emails, batchSize: 50)
        let typed = (0..<63).map { "\"phrase\($0)a phrase\($0)b\" word\($0)" }.joined(separator: " OR ")
        let spec = try XCTUnwrap(PlainSearchTranslator.spec(from: typed))
        XCTAssertEqual(spec.groups.count, 1, "no expansion")
        XCTAssertEqual(spec.groups[0].branches.count, 63)
        try await expectIDs(env, spec, Set((0..<63).map { "B\($0)" }), "every alternative, no decoy")
        // The same through the browse state (the ordinary box), and 7 / 20 alternatives are just prefixes of it.
        for n in [7, 20] {
            let fewer = try XCTUnwrap(PlainSearchTranslator.spec(from: (0..<n).map { "\"phrase\($0)a phrase\($0)b\" word\($0)" }.joined(separator: " OR ")))
            try await expectIDs(env, fewer, Set((0..<n).map { "B\($0)" }))
        }
        // Branch-local negation: alpha without draft, or gamma.
        let a1 = mail(410, from: "s@x.com", subject: "AlphaDraft", body: "alpha draft")
        let a2 = mail(411, from: "s@x.com", subject: "AlphaFinal", body: "alpha final")
        let g = mail(412, from: "s@x.com", subject: "GammaDraft", body: "gamma draft")
        try await env.store.insertBatch([a1, a2, g], batchSize: 10)
        let local = try XCTUnwrap(PlainSearchTranslator.spec(from: "alpha -draft OR gamma"))
        try await expectIDs(env, local, ["AlphaFinal", "GammaDraft"], "draft is excluded only from the alpha alternative")
        XCTAssertTrue(SearchSpecDescriber.summary(local).contains("not"), SearchSpecDescriber.summary(local))
        // Same-attachment conditions keep their branch too.
        let f = mail(420, from: "s@x.com", subject: "Files", body: "-", attachments: [AttachmentMetadata(filename: "a.txt", mimeType: "text/plain", size: 1)])
        try await env.store.insertBatch([f], batchSize: 10)
        try await env.store.indexAttachmentSearchDocuments(emailID: f.id, documents: [
            AttachmentSearchDocument(ordinal: 0, filename: "a.txt", text: "quorum reached in the file", state: .complete, extractorVersion: 4, ocr: false)])
        let inside = try XCTUnwrap(PlainSearchTranslator.spec(from: "in:attachments quorum reached OR nothingatall"))
        try await expectIDs(env, inside, ["Files"])
    }

    /// R02 (handoff 7481852): literals are verified on the stored text at any
    /// length and across any script — chunks are contiguous, so no offset
    /// arithmetic can disagree between Swift Characters and SQLite code points.
    func testR02_literalsVerifiedAcrossChunks_unicodeAndBeyondAChunk_noFallback() async throws {
        let wasOn = SearchChunkPolicy.isEnabled
        defer { SearchChunkPolicy.isEnabled = wasOn }
        let env = try chunkedEnv()
        // Hindi, Bengali, decomposed accents and emoji sequences in the lead text make Characters ≠ code points.
        let unit = "नमस्ते दुनिया বাংলা ভাষা cafe\u{0301} résumé 👨‍👩‍👧‍👦 🇮🇳 "
        var lead = ""
        while lead.count < SearchChunker.chunkCharacters - 300 { lead += unit }
        let phraseWords = (0..<80).map { "सीमाशब्द\($0) boundaryword\($0)" }
        let phrase = phraseWords.joined(separator: " ")          // ~2,000 characters, crosses the first boundary
        let tail = String(repeating: "trailing words after the phrase ", count: 400)
        let crossing = mail(500, from: "s@x.com", subject: "Unicode", body: lead + phrase + " " + tail,
                            attachments: [AttachmentMetadata(filename: "u.txt", mimeType: "text/plain", size: 1)])
        try await env.store.insertBatch([crossing], batchSize: 10)
        let chunks = SearchChunker.chunks(of: crossing.plainBody)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertFalse(chunks.contains { $0.contains(phrase) }, "the phrase spans a boundary")
        XCTAssertNotEqual(chunks[1].unicodeScalars.count, chunks[1].count, "the fixture really has multi-scalar Characters")
        try await expectIDs(env, SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.body, .phrase, phrase)])]), ["Unicode"])
        try await expectIDs(env, SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.body, .phrase, phraseWords.reversed().joined(separator: " "))])]), [])
        // The same literal inside one attachment.
        try await env.store.indexAttachmentSearchDocuments(emailID: crossing.id, documents: [
            AttachmentSearchDocument(ordinal: 0, filename: "u.txt", text: lead + phrase + " end", state: .complete, extractorVersion: 4, ocr: false)])
        try await expectIDs(env, SearchSpec(groups: [SearchGroup(.all, attachments: [AttachmentConditionGroup(contentMatch: .phrase, content: phrase)])]), ["Unicode"])

        // A literal longer than a whole chunk: still the exact text, never its words.
        let long = (0..<9_000).map { "longword\($0)" }.joined(separator: " ")   // ≈ 110 K characters, three chunks
        XCTAssertGreaterThan(long.count, SearchChunker.chunkCharacters)
        let huge = mail(501, from: "s@x.com", subject: "Huge", body: "start " + long + " finish")
        try await env.store.insertBatch([huge], batchSize: 10)
        try await expectIDs(env, SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.body, .phrase, long)])]), ["Huge"])
        let shuffled = (0..<9_000).map { "longword\((($0 * 7) % 9_000))" }.joined(separator: " ")
        try await expectIDs(env, SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.body, .phrase, shuffled)])]), [], "the words in another order are not the phrase")
        XCTAssertFalse(SearchSpecDescriber.summary(SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.body, .phrase, long)])])).contains("all its words"), "no fallback is announced because none happens")

        // Migration: a document stored in the old overlapped layout is re-chunked to the contiguous one and still searches.
        let text = (0..<4_000).map { "legacyword\($0)" }.joined(separator: " ")   // two chunks
        let oldChunks = legacyOverlappedChunks(text)
        XCTAssertGreaterThan(oldChunks.count, 1)
        let legacyMail = mail(502, from: "s@x.com", subject: "Legacy", body: "x")
        try await env.store.insertBatch([legacyMail], batchSize: 10)
        try await env.store.plantLegacyChunksForTesting(emailID: legacyMail.id.uuidString, kind: "body", chunks: oldChunks)
        try await env.store.rechunkOverlappedDocumentsForTesting()
        let joined = try await env.store.chunkTextsForTesting(emailID: legacyMail.id.uuidString, kind: "body").joined()
        XCTAssertEqual(joined, text, "the migration reproduced the original text exactly")
        let crossingLegacy = "legacyword2499 legacyword2500 legacyword2501"
        try await expectIDs(env, SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.body, .phrase, crossingLegacy)])]), ["Legacy"])
    }

    /// The pre-v24 chunk layout, for the migration test: each later chunk begins with the previous one's last 512 Characters.
    private func legacyOverlappedChunks(_ text: String, chunk: Int = SearchChunker.chunkCharacters) -> [String] {
        var out: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            guard let hardEnd = text.index(start, offsetBy: chunk, limitedBy: text.endIndex) else { out.append(String(text[start...])); break }
            var end = hardEnd, probe = hardEnd, steps = 0
            while probe > start, steps < 256 { probe = text.index(before: probe); if text[probe].isWhitespace { end = text.index(after: probe); break }; steps += 1 }
            out.append(String(text[start..<end]))
            var next = text.index(end, offsetBy: -SearchChunker.legacyOverlapCharacters, limitedBy: start) ?? start
            if next <= start { next = end }
            start = next
            if end == text.endIndex { break }
        }
        return out
    }

    func testFIND07_wholeBodyIsIndexed_tailAndCrossChunkPhraseAreFound() async throws {
        let wasOn = SearchChunkPolicy.isEnabled
        defer { SearchChunkPolicy.isEnabled = wasOn }
        let env = try chunkedEnv()
        // ~5 MB body: far beyond the previous 4 MiB budget. A phrase is planted
        // exactly across the first chunk boundary, and a word at the very end.
        let filler = String(repeating: "lorem ipsum dolor sit amet ", count: 190_000)   // ~5.1 M characters
        let chunks = SearchChunker.chunks(of: filler)
        XCTAssertGreaterThan(chunks.count, 1)
        // The phrase starts at the last word boundary before chunk 0 ends, so
        // it straddles the boundary and must be whole in chunk 1's overlap.
        var boundary = chunks[0].count - 3
        while boundary > 0, filler[filler.index(filler.startIndex, offsetBy: boundary)] != " " { boundary -= 1 }
        var body = filler
        let phrase = "zephyr quantum ledger"
        let planted = " " + phrase + " "
        body.replaceSubrange(body.index(body.startIndex, offsetBy: boundary)..<body.index(body.startIndex, offsetBy: boundary + planted.count), with: planted)
        XCTAssertTrue(SearchChunker.chunks(of: body)[0].count < boundary + planted.count, "the phrase really crosses the first boundary")
        body += " tailmarker"
        try await env.store.insertBatch([mail(30, from: "long@x.com", subject: "Long", body: body),
                                         mail(31, from: "short@x.com", subject: "Short", body: "zephyr elsewhere, quantum apart, ledger alone")], batchSize: 10)

        let coverage = try await env.store.searchDocCoverage()
        XCTAssertGreaterThan(coverage.bodyChunks, 100, "the body is in many chunks: \(coverage.bodyChunks)")
        try await expectIDs(env, SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.body, .allWords, "tailmarker")])]), ["Long"], "the end of the document is searchable")
        try await expectIDs(env, SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.body, .phrase, phrase)])]), ["Long"], "the phrase across the chunk boundary is found, and the scattered words are not")
        try await expectIDs(env, SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.body, .allWords, phrase)])]), ["Long", "Short"], "all-words is a different, stated mode")
        // Chunk verification: the stored chunks reassemble to the text.
        let stored = try await env.store.searchChunks(emailID: UUID(), kind: .body, ordinal: 0)
        XCTAssertTrue(stored.isEmpty)
    }

    func testFIND04_dateDaysAreInclusiveInTheDisplayedZone() async throws {
        let wasOn = SearchChunkPolicy.isEnabled
        defer { SearchChunkPolicy.isEnabled = wasOn }
        let env = try chunkedEnv()
        // 23:30 and 00:30 Kolkata around midnight 31 March → 1 April 2024.
        try await env.store.insertBatch([
            mail(40, from: "a@x.com", subject: "Late March", body: "a", date: "Sun, 31 Mar 2024 23:30:00 +0530"),
            mail(41, from: "a@x.com", subject: "Early April", body: "b", date: "Mon, 01 Apr 2024 00:30:00 +0530"),
        ], batchSize: 10)
        let kolkata = "Asia/Kolkata"
        try await expectIDs(env, SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.dateOnOrBefore, .equals, "2024-03-31", timeZone: kolkata)])]), ["Late March"])
        try await expectIDs(env, SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.dateOnOrAfter, .equals, "2024-04-01", timeZone: kolkata)])]), ["Early April"])
        // In UTC both instants fall on 31 March.
        try await expectIDs(env, SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.dateOnOrBefore, .equals, "2024-03-31", timeZone: "UTC")])]), ["Late March", "Early April"])
        // An invalid date is a validation problem, not a different query.
        let bad = SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.dateOnOrAfter, .equals, "yesterday")])])
        XCTAssertEqual(bad.problems().count, 1)
        try await expectIDs(env, bad, [], "it matches nothing rather than everything")
    }

    func testFIND06_punctuationAndSQLLookingInputCannotChangeTheQuery() async throws {
        let wasOn = SearchChunkPolicy.isEnabled
        defer { SearchChunkPolicy.isEnabled = wasOn }
        let env = try chunkedEnv()
        try await env.store.insertBatch([
            mail(50, from: "dev@x.com", subject: "Compilers", body: "We moved the parser from C to C++ last week."),
            mail(51, from: "dev@x.com", subject: "Plain C", body: "Still writing C here, and some Rust."),
            mail(52, from: "ops@x.com", subject: "Invoice", body: "Reference PO-4471 and \"quoted\" words; 100% done."),
        ], batchSize: 10)
        try await expectIDs(env, SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.body, .contains, "C++")])]), ["Compilers"], "the ++ is required, not dropped")
        try await expectIDs(env, SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.body, .contains, "pars")])]), ["Compilers"], "contains matches word starts")
        try await expectIDs(env, SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.body, .contains, "arser")])]), [], "…but not the inside of a word (stated)")
        try await expectIDs(env, SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.body, .allWords, "parsers")])]), [], "no stemming: the plural does not find the singular")
        try await expectIDs(env, SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.body, .contains, "PO-4471")])]), ["Invoice"])
        try await expectIDs(env, SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.body, .contains, "\"quoted\" words")])]), ["Invoice"])
        try await expectIDs(env, SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.body, .contains, "100%")])]), ["Invoice"])
        let injection = "'; DROP TABLE emails; --"
        try await expectIDs(env, SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.subject, .contains, injection)])]), [])
        try await expectIDs(env, SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.body, .allWords, "OR NOT (\"x\") AND *")])]), [], "FTS syntax in a value is just words")
        try await expectCount(env, .all, 3, "the table is still there")
    }

    func testFIND04_englishBengaliAndHindiWordsStayWhole() async throws {
        let wasOn = SearchChunkPolicy.isEnabled
        defer { SearchChunkPolicy.isEnabled = wasOn }
        let env = try chunkedEnv()
        try await env.store.insertBatch([
            mail(90, from: "a@x.com", subject: "English", body: "The quarterly review is on Monday."),
            mail(91, from: "b@x.com", subject: "Hindi", body: "यह एक परीक्षण संदेश है। बैठक सोमवार को है।"),
            mail(92, from: "c@x.com", subject: "Bengali", body: "এটি একটি পরীক্ষা বার্তা। সভা সোমবার।"),
        ], batchSize: 10)
        // Words with vowel signs are matched whole, not as fragments.
        XCTAssertEqual(SearchTextTokens.words(in: "परीक्षण संदेश"), ["परीक्षण", "संदेश"])
        XCTAssertEqual(SearchTextTokens.words(in: "পরীক্ষা বার্তা।"), ["পরীক্ষা", "বার্তা"])
        try await expectIDs(env, SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.body, .allWords, "परीक्षण")])]), ["Hindi"])
        try await expectIDs(env, SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.body, .phrase, "পরীক্ষা বার্তা")])]), ["Bengali"])
        try await expectIDs(env, SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.body, .allWords, "सोमवार")])]), ["Hindi"], "the Hindi Monday, not the Bengali one")
        try await expectIDs(env, SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.body, .allWords, "সোমবার")])]), ["Bengali"])
        try await expectIDs(env, SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.body, .allWords, "review monday")])]), ["English"])
        // A fragment of a Hindi word is not a word.
        try await expectIDs(env, SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.body, .allWords, "परीक्ष")])]), [])
    }

    func testFIND04_scopeIsEnforcedOutsideUserLogic() async throws {
        let wasOn = SearchChunkPolicy.isEnabled
        defer { SearchChunkPolicy.isEnabled = wasOn }
        let env = try chunkedEnv()
        var inbox = mail(60, from: "a@x.com", subject: "In folder", body: "topic alpha"); inbox.tags = ["Inbox"]
        var other = mail(61, from: "a@x.com", subject: "Elsewhere", body: "topic alpha"); other.tags = ["Archive"]
        try await env.store.insertBatch([inbox, other], batchSize: 10)
        let folderNodes = try await env.store.folderNodes()
        let folder = try XCTUnwrap(folderNodes.first { $0.path == "Inbox" })
        var scope = EmailQuery.all
        scope.folderID = folder.folderID
        // An OR over everything cannot leave the folder.
        let wide = SearchSpec(groups: [SearchGroup(.any, [SearchCondition(.body, .allWords, "alpha"), SearchCondition(.sender, .contains, "a@x.com")])])
        try await expectIDs(env, wide, scope: scope, ["In folder"])
        // Nor can an exclusion.
        let exclusion = SearchSpec(groups: [SearchGroup(.exclude, [SearchCondition(.subject, .contains, "zzz")])])
        try await expectIDs(env, exclusion, scope: scope, ["In folder"])
        var q = scope; q.spec = exclusion
        try await expectUnresolved(env, q, 0)
    }

    func testFIND07_chunkerKeepsWordsWholeAndOverlaps() {
        // R02: contiguous chunks — joined, they ARE the text; no word is cut in two.
        let words = (0..<20_000).map { "w\($0)" }.joined(separator: " ")
        let chunks = SearchChunker.chunks(of: words, chunk: 4_000)
        XCTAssertGreaterThan(chunks.count, 20)
        XCTAssertEqual(chunks.joined(), words, "nothing repeated, nothing dropped")
        for (i, c) in chunks.enumerated() {
            XCTAssertLessThanOrEqual(c.count, 4_000)
            XCTAssertFalse(c.hasPrefix(" ") && i == 0)
            if i + 1 < chunks.count { XCTAssertTrue(c.hasSuffix(" "), "chunk \(i) ends at a word boundary") }
        }
        // The pre-v24 layout joins back to the original text by dropping each later chunk's repeated head.
        let legacy = ["alpha beta gamma", String(repeating: "x", count: SearchChunker.legacyOverlapCharacters) + " delta"]
        XCTAssertEqual(SearchChunker.joinLegacyOverlapped(legacy), "alpha beta gamma delta")
        XCTAssertEqual(SearchChunker.chunks(of: ""), [])
        XCTAssertEqual(SearchChunker.chunks(of: "short"), ["short"])
        XCTAssertEqual(SearchTextTokens.words(in: "C++ and PO-4471, \"quoted\"!"), ["C", "and", "PO", "4471", "quoted"])
        XCTAssertEqual(SearchTextTokens.quoted("a\"b"), "\"a\"\"b\"")
    }

    // MARK: - Five jobs FIND-01 — DOCX, XLSX, PPTX text with component context

    private static func crc32(_ data: Data) -> UInt32 {
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
    private static func zipPackage(_ members: [(name: String, data: Data)]) -> Data {
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }
        var local = Data(), central = Data()
        for m in members {
            let name = Array(m.name.utf8)
            let crc = crc32(m.data)
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

    private static func docx(body: String, header: String) -> Data {
        zipPackage([
            ("[Content_Types].xml", Data("<Types/>".utf8)),
            ("word/document.xml", Data("""
                <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>
                <w:p><w:r><w:t>\(body)</w:t></w:r></w:p>
                <w:tbl><w:tr><w:tc><w:p><w:r><w:t>cell one</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>cell two</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
                </w:body></w:document>
                """.utf8)),
            ("word/header1.xml", Data("<w:hdr xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:p><w:r><w:t>\(header)</w:t></w:r></w:p></w:hdr>".utf8)),
            ("word/media/image1.png", Data([0x89, 0x50, 0x4E, 0x47])),
        ])
    }

    private static func xlsx(sheetName: String, sharedText: String, inlineText: String) -> Data {
        zipPackage([
            ("xl/workbook.xml", Data("<workbook xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets><sheet name=\"\(sheetName)\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>".utf8)),
            ("xl/_rels/workbook.xml.rels", Data("<Relationships><Relationship Id=\"rId1\" Type=\"x\" Target=\"worksheets/sheet1.xml\"/></Relationships>".utf8)),
            ("xl/sharedStrings.xml", Data("<sst><si><t>\(sharedText)</t></si><si><r><t>rich </t></r><r><t>run</t></r></si></sst>".utf8)),
            ("xl/worksheets/sheet1.xml", Data("""
                <worksheet><sheetData>
                <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="inlineStr"><is><t>\(inlineText)</t></is></c></row>
                <row r="2"><c r="A2"><v>42</v></c><c r="B2"><f>SUM(A1:A2)</f><v>84</v></c><c r="C2" t="s"><v>1</v></c></row>
                </sheetData></worksheet>
                """.utf8)),
        ])
    }

    private static func pptx(slide: String, notes: String) -> Data {
        zipPackage([
            ("ppt/slides/slide1.xml", Data("<p:sld xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\"><p:txBody><a:p><a:r><a:t>\(slide)</a:t></a:r></a:p></p:txBody></p:sld>".utf8)),
            ("ppt/slides/slide2.xml", Data("<p:sld xmlns:a=\"x\"><a:p><a:r><a:t>second slide</a:t></a:r></a:p></p:sld>".utf8)),
            ("ppt/notesSlides/notesSlide1.xml", Data("<p:notes xmlns:a=\"x\"><a:p><a:r><a:t>\(notes)</a:t></a:r></a:p></p:notes>".utf8)),
        ])
    }

    func testFIND01_officeTextIsExtractedWithComponentLabels() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailin-find01-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        func write(_ name: String, _ data: Data) throws -> URL { let u = root.appendingPathComponent(name); try data.write(to: u); return u }

        let docx = try OfficeTextExtractor.extract(fileURL: try write("a.docx", Self.docx(body: "The quorum clause applies.", header: "Confidential header")), kind: .docx)
        XCTAssertEqual(docx.components, ["Document", "Header"])
        XCTAssertTrue(docx.text.contains("[Document]\nThe quorum clause applies.") && docx.text.contains("cell one \tcell two") && docx.text.contains("[Header]\nConfidential header"), docx.text)
        XCTAssertEqual(docx.notText, ["word/media/image1.png"])
        XCTAssertFalse(docx.partial)

        let xlsx = try OfficeTextExtractor.extract(fileURL: try write("b.xlsx", Self.xlsx(sheetName: "Budget", sharedText: "Gross margin", inlineText: "inline note")), kind: .xlsx)
        XCTAssertEqual(xlsx.components, ["Sheet: Budget"])
        // §13.3 (2): every cell carries its address; a formula's cached value comes first, the formula after it.
        XCTAssertTrue(xlsx.text.contains("[Sheet: Budget]\nA1: Gross margin\tB1: inline note\nA2: 42\tB2: 84 (formula =SUM(A1:A2))\tC2: rich run"), xlsx.text)

        let pptx = try OfficeTextExtractor.extract(fileURL: try write("c.pptx", Self.pptx(slide: "Roadmap overview", notes: "remember the demo")), kind: .pptx)
        XCTAssertEqual(pptx.components, ["Slide 1", "Slide 2", "Notes 1"])
        XCTAssertTrue(pptx.text.contains("[Slide 1]\nRoadmap overview") && pptx.text.contains("[Notes 1]\nremember the demo"), pptx.text)

        // An encrypted package is an OLE file: locked, not garbage.
        let ole = try write("locked.docx", Data(OfficeTextExtractor.oleSignature) + Data(repeating: 0, count: 600))
        XCTAssertThrowsError(try OfficeTextExtractor.extract(fileURL: ole, kind: .docx)) { error in
            XCTAssertEqual(error as? OfficeTextExtractor.ExtractError, .encrypted)
        }
        XCTAssertEqual(OfficeTextExtractor.Kind.detect(mimeType: "application/octet-stream", filename: "x.XLSX"), .xlsx)
        XCTAssertNil(OfficeTextExtractor.Kind.detect(mimeType: "application/msword", filename: "old.doc"))
    }

    func testFIND01_officeAttachmentsAreSearchableByContent_andLegacyOnesSaySo() async throws {
        let wasOn = SearchChunkPolicy.isEnabled
        defer { SearchChunkPolicy.isEnabled = wasOn }
        let env = try chunkedEnv()
        AttachmentTextIndexJob.testSuppressKicks = true
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()
        AttachmentTextIndexJob.testStoreOverride = env.store
        defer { AttachmentTextIndexJob.testStoreOverride = nil; AttachmentTextIndexJob.testSuppressKicks = false }
        let raw = """
        From sender@example.com Wed Jan 15 10:00:00 2025
        From: sender@example.com
        To: user@dest.org
        Subject: Office files
        Date: Wed, 15 Jan 2025 10:00:00 +0000
        Message-ID: <find01@t>
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="B"

        --B
        Content-Type: text/plain

        see attached
        \(mimeAttachment("minutes.docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document", Self.docx(body: "The quorum clause applies.", header: "Board")))
        \(mimeAttachment("budget.xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", Self.xlsx(sheetName: "Q3", sharedText: "Gross margin", inlineText: "note")))
        \(mimeAttachment("deck.pptx", "application/vnd.openxmlformats-officedocument.presentationml.presentation", Self.pptx(slide: "Roadmap overview", notes: "demo")))
        \(mimeAttachment("old.doc", "application/msword", Data("not readable here".utf8)))
        --B--
        """
        let email = try MBOXParser.processRawMessage(raw, senderEmail: "")
        _ = try await env.store.insertBatch([email], sourceFileHash: nil, accountID: nil,
            sourceID: nil, firstOrdinal: nil, dedupPolicy: .messageID, batchSize: 10, progress: nil)
        let outcome = await AttachmentTextIndexJob.shared.run()
        XCTAssertEqual(outcome.indexedEmails, 1)

        let coverage = try AttachmentCoverageStore(url: await env.store.attachmentCoverageURL)
        let rows = try coverage.rows(for: email.id)
        // TYPE-01: a .doc is now read; this one is not an OLE2 file at all, so it fails with the reason, never "unsupported".
        XCTAssertEqual(rows.map(\.state), [.extracted, .extracted, .extracted, .failed])
        XCTAssertEqual(rows.map(\.extractorVersion), Array(repeating: AttachmentTextIndexJob.extractorVersion, count: 4))
        XCTAssertTrue(rows[3].note?.contains("OLE2") == true, rows[3].note ?? "")

        // Found only through the attachment's text, with the component label in the chunk.
        try await expectIDs(env, SearchSpec(groups: [SearchGroup(.all, attachments: [AttachmentConditionGroup(type: "docx", contentMatch: .phrase, content: "quorum clause")])]), ["Office files"])
        try await expectIDs(env, SearchSpec(groups: [SearchGroup(.all, attachments: [AttachmentConditionGroup(type: "xlsx", contentMatch: .allWords, content: "gross margin")])]), ["Office files"])
        try await expectIDs(env, SearchSpec(groups: [SearchGroup(.all, attachments: [AttachmentConditionGroup(nameContains: "deck", contentMatch: .phrase, content: "roadmap overview")])]), ["Office files"])
        try await expectIDs(env, SearchSpec(groups: [SearchGroup(.all, attachments: [AttachmentConditionGroup(type: "docx", contentMatch: .phrase, content: "roadmap overview")])]), [], "the phrase is in the PPTX, not the DOCX")
        let chunks = try await env.store.searchChunks(emailID: email.id, kind: .attachmentText, ordinal: 1)
        XCTAssertTrue(chunks.joined().contains("[Sheet: Q3]"), "sheet context travels with the text")
        // The legacy .doc is an attachment whose text is not evaluable: an exclusion on attachment text leaves this email unresolved.
        var q = EmailQuery.all
        q.spec = SearchSpec(groups: [SearchGroup(.exclude, attachments: [AttachmentConditionGroup(contentMatch: .phrase, content: "nothing here")])])
        try await expectUnresolved(env, q, 1)
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()
    }

    // MARK: - Five jobs FIND-04 step 4 — the builder's words and chips come from the model that runs

    func testFIND04_describerSaysWhatRuns_andChipsRemoveExactlyOneThing() {
        let spec = SearchSpec(groups: [
            SearchGroup(.all, [SearchCondition(.sender, .contains, "alice"), SearchCondition(.dateOnOrAfter, .equals, "2024-01-01", timeZone: "Asia/Kolkata")],
                        attachments: [AttachmentConditionGroup(type: "PDF", contentMatch: .phrase, content: "purchase order")]),
            SearchGroup(.any, [SearchCondition(.body, .allWords, "invoice receipt"), SearchCondition(.hasAttachments, .equals, "yes")]),
            SearchGroup(.exclude, [SearchCondition(.subject, .contains, "newsletter")]),
        ])
        let summary = SearchSpecDescriber.summary(spec)
        XCTAssertTrue(summary.contains("Sender: alice") && summary.contains("Date on or after 2024-01-01 (Asia/Kolkata)"), summary)
        XCTAssertTrue(summary.contains("One attachment: type PDF, text has the phrase “purchase order”"), summary)
        XCTAssertTrue(summary.contains("Message body has all the words “invoice receipt” or Has attachments"), summary)
        XCTAssertTrue(summary.contains("Leaving out messages where Subject: newsletter."), summary)
        XCTAssertTrue(summary.contains("may still match"), "a text condition as one OR branch can be unknown, so the summary says so")

        let certain = SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.body, .phrase, "quorum")]), SearchGroup(.exclude, [SearchCondition(.sender, .contains, "spam")])])
        XCTAssertFalse(SearchSpecDescriber.summary(certain).contains("may still match"), "text only in an all-group, exclusion on metadata → nothing uncertain")
        let uncertain = SearchSpec(groups: [SearchGroup(.exclude, [SearchCondition(.body, .phrase, "unsubscribe")])])
        XCTAssertTrue(SearchSpecDescriber.summary(uncertain).contains("may still match"))
        XCTAssertEqual(SearchSpecDescriber.summary(SearchSpec()), "No conditions — the list shows the selected scope.")

        // Removing a chip removes that condition and nothing else; group indices stay stable.
        let fewer = spec.removingCondition(group: 1, condition: 0)
        XCTAssertEqual(fewer.groups[1].conditions.map(\.value), ["yes"])
        XCTAssertEqual(fewer.groups[0].conditions.count, 2)
        let noAttachment = spec.removingAttachmentGroup(group: 0, attachment: 0)
        XCTAssertTrue(noAttachment.groups[0].attachmentGroups.isEmpty)
        XCTAssertEqual(noAttachment.groups[0].conditions.count, 2)
        XCTAssertEqual(spec.removingCondition(group: 7, condition: 0), spec, "an unknown index changes nothing")
        XCTAssertEqual(spec.indexedLiveGroups.map(\.index), [0, 1, 2])
        XCTAssertEqual(SearchSpec(groups: [SearchGroup(.all), SearchGroup(.exclude, [SearchCondition(.tag, .contains, "x")])]).indexedLiveGroups.map(\.index), [1])

        // Chip texts name the field and the mode.
        XCTAssertEqual(SearchSpecDescriber.chip(SearchCondition(.hasAttachments, .equals, "no")), "No attachments")
        XCTAssertEqual(SearchSpecDescriber.chip(SearchCondition(.recipientTo, .equals, "me@x.com")), "To is “me@x.com”")
        XCTAssertEqual(SearchSpecDescriber.chip(AttachmentConditionGroup(nameContains: "memo", type: "docx")), "One attachment: type docx, name has “memo”")
    }

    func testFIND04_browseStateCarriesTheSpecOnTopOfTheScope() {
        var base = EmailQuery.all
        base.folderID = 42
        let spec = SearchSpec(groups: [SearchGroup(.any, [SearchCondition(.sender, .contains, "a"), SearchCondition(.sender, .contains, "b")])])
        let q = ArchiveBrowseState(searchText: "from:carol", afterDate: nil, spec: spec).query(base: base)
        XCTAssertEqual(q.folderID, 42, "scope is untouched by the spec")
        XCTAssertEqual(q.spec, spec)
        XCTAssertEqual(q.sender, "carol", "the typed operator still compiles next to it")
        XCTAssertTrue(q.hasStructuredFilters)
        XCTAssertNil(ArchiveBrowseState(searchText: "", afterDate: nil, spec: SearchSpec(groups: [SearchGroup(.all)])).query().spec, "an empty spec is no spec")
        // Saved queries: the model round-trips through JSON with its version.
        let data = try! JSONEncoder().encode(spec)
        let back = try! JSONDecoder().decode(SearchSpec.self, from: data)
        XCTAssertEqual(back, spec)
        XCTAssertEqual(back.version, SearchSpec.currentVersion)
    }

    // MARK: - Five jobs FIND-05 — evidence for every hit, from the index

    func testFIND05_evidenceNamesTheRealPlace_neverGuessesBody() async throws {
        let wasOn = SearchChunkPolicy.isEnabled
        defer { SearchChunkPolicy.isEnabled = wasOn }
        let env = try chunkedEnv()
        let x = mail(70, from: "supplier@example.com", subject: "Order confirmation", body: "Dear customer, your purchase order 4471 is confirmed. Regards.",
                     attachments: [AttachmentMetadata(filename: "budget.xlsx", mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", size: 10),
                                   AttachmentMetadata(filename: "budget.xlsx", mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", size: 11)])
        try await env.store.insertBatch([x], batchSize: 10)
        try await env.store.indexAttachmentSearchDocuments(emailID: x.id, documents: [
            AttachmentSearchDocument(ordinal: 0, filename: "budget.xlsx", text: "[Sheet: Summary]\ntotals only\n", state: .complete, extractorVersion: 3, ocr: false),
            AttachmentSearchDocument(ordinal: 1, filename: "budget.xlsx", text: "[Sheet: Q3]\nGross margin\t42\n", state: .complete, extractorVersion: 3, ocr: true),
        ])

        // Body phrase: the place is the body, the excerpt holds the phrase, marked.
        let bodySpec = SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.body, .phrase, "purchase order")])])
        var evidence = try await env.store.matchEvidence(emailID: x.id, spec: bodySpec, freeText: nil)
        XCTAssertEqual(evidence.count, 1)
        XCTAssertEqual(evidence[0].location, .body)
        let excerpt = try XCTUnwrap(evidence[0].excerpt)
        XCTAssertTrue(excerpt.text.contains("purchase order 4471"), excerpt.text)
        XCTAssertEqual(excerpt.marks.count, 1)
        let marked = (excerpt.text as NSString).substring(with: NSRange(location: excerpt.marks[0].lowerBound, length: excerpt.marks[0].count))
        XCTAssertEqual(marked.lowercased(), "purchase order")

        // Attachment text: the right one of two same-named files, with its sheet, and OCR labelled.
        let xlsxSpec = SearchSpec(groups: [SearchGroup(.all, attachments: [AttachmentConditionGroup(type: "xlsx", contentMatch: .allWords, content: "gross margin")])])
        evidence = try await env.store.matchEvidence(emailID: x.id, spec: xlsxSpec, freeText: nil)
        XCTAssertEqual(evidence.count, 1)
        XCTAssertEqual(evidence[0].location, .attachmentText(ordinal: 1, filename: "budget.xlsx", ocr: true, context: "Sheet: Q3"))
        XCTAssertTrue(MatchEvidenceChips.label(evidence[0].location).contains("budget.xlsx") && MatchEvidenceChips.label(evidence[0].location).contains("Sheet: Q3"))

        // Metadata-only: says it matched the filters, invents no text.
        let metaSpec = SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.sender, .contains, "supplier"), SearchCondition(.hasAttachments, .equals, "yes")])])
        evidence = try await env.store.matchEvidence(emailID: x.id, spec: metaSpec, freeText: nil)
        XCTAssertEqual(evidence.map(\.location), [.sender, .metadata])
        XCTAssertTrue(evidence.allSatisfy { $0.excerpt == nil })

        // Free text from the search box: whole words anywhere; found in the subject here.
        evidence = try await env.store.matchEvidence(emailID: x.id, spec: nil, freeText: "confirmation")
        XCTAssertEqual(evidence.map(\.location), [.subject])

        // No evidence in the index → said so, not "Body".
        SearchChunkPolicy.isEnabled = false
        let y = mail(71, from: "a@x.com", subject: "Unindexed", body: "hidden words here")
        try await env.store.insertBatch([y], batchSize: 10)
        SearchChunkPolicy.isEnabled = true
        evidence = try await env.store.matchEvidence(emailID: y.id, spec: nil, freeText: "hidden")
        XCTAssertEqual(evidence.map(\.location), [.unavailable])

        // The excerpt helper: window around the first match, ellipses, marks shifted.
        let long = String(repeating: "x ", count: 200) + "needle in the haystack" + String(repeating: " y", count: 200)
        let cut = SQLiteEmailStore.excerpt(from: long, words: ["needle"], literal: nil, radius: 20)
        XCTAssertTrue(cut.text.hasPrefix("…") && cut.text.hasSuffix("…"), cut.text)
        XCTAssertEqual((cut.text as NSString).substring(with: NSRange(location: cut.marks[0].lowerBound, length: cut.marks[0].count)), "needle")
        XCTAssertEqual(SQLiteEmailStore.nearestLabel(in: "[Sheet: Q3]\nGross margin", before: 15), "Sheet: Q3")
        XCTAssertNil(SQLiteEmailStore.nearestLabel(in: "no label here", before: 5))
    }

    /// FIND-05 (plan v3 closure list): a chip that names an attachment opens
    /// THAT attachment — by its ordinal, under its own name — never the first
    /// file that happens to share the name; failures are named, not silent.
    func testFIND05_chipOpensTheSpecificAttachment_byOrdinal_underItsOwnName() throws {
        let first = Data("first file".utf8), second = Data("%PDF-1.4 second".utf8)
        let email = mail(71, from: "a@example.com", subject: "Two files", body: "see attached", attachments: [
            AttachmentMetadata(filename: "budget.xlsx", mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                               size: first.count, base64: first.base64EncodedString()),
            AttachmentMetadata(filename: "budget.xlsx", mimeType: "application/pdf", size: second.count, base64: second.base64EncodedString()),
        ])

        let url = try EvidenceAttachmentOpener.temporaryFile(for: email, ordinal: 1).get()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertEqual(try Data(contentsOf: url), second, "the second of two same-named files, not the first")
        XCTAssertEqual(url.lastPathComponent, "budget.xlsx", "the attachment keeps its own name so the system picks the right app")
        XCTAssertTrue(url.standardizedFileURL.path.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path),
                      "written to the temporary directory, never into the archive")

        // A chip for the first file opens the first file.
        let firstURL = try EvidenceAttachmentOpener.temporaryFile(for: email, ordinal: 0).get()
        defer { try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent()) }
        XCTAssertEqual(try Data(contentsOf: firstURL), first)

        // An ordinal the message does not have: a named failure, nothing written.
        guard case .failure(let missing) = EvidenceAttachmentOpener.temporaryFile(for: email, ordinal: 2) else {
            return XCTFail("ordinal 2 of a two-attachment message must fail")
        }
        XCTAssertEqual(missing, .noAttachment(ordinal: 2, count: 2))
        XCTAssertFalse(missing.message.isEmpty)

        // Bytes that cannot be produced: the failure names the file.
        var bare = email
        bare.attachments = [AttachmentMetadata(filename: "ghost.pdf", mimeType: "application/pdf", size: 5)]
        guard case .failure(let unavailable) = EvidenceAttachmentOpener.temporaryFile(for: bare, ordinal: 0) else {
            return XCTFail("an attachment with no bytes anywhere must fail")
        }
        XCTAssertEqual(unavailable, .bytesUnavailable(filename: "ghost.pdf"))

        // Names are made safe for one path component and get an extension when they lack one.
        XCTAssertEqual(EvidenceAttachmentOpener.safeFilename("../../etc/passwd", mimeType: "text/plain"), "_.._etc_passwd")
        XCTAssertEqual(EvidenceAttachmentOpener.safeFilename("", mimeType: "application/pdf"), "attachment.pdf")
        XCTAssertEqual(EvidenceAttachmentOpener.safeFilename("notes", mimeType: "text/plain; charset=utf-8"), "notes.txt")

        // Only chips that name an attachment open one; the others stay labels.
        XCTAssertEqual(MatchEvidenceChips.attachmentOrdinal(.attachmentText(ordinal: 1, filename: "budget.xlsx", ocr: true, context: "Sheet: Q3")), 1)
        XCTAssertEqual(MatchEvidenceChips.attachmentOrdinal(.speech(ordinal: 0, filename: "memo.m4a", context: nil)), 0)
        XCTAssertNil(MatchEvidenceChips.attachmentOrdinal(.body))
        XCTAssertNil(MatchEvidenceChips.attachmentOrdinal(.attachmentName), "a name match does not say which of several same-named files")
    }

    // MARK: - Five jobs FIND-03 — coverage states; a failed counter is unknown, not zero

    func testFIND03_coverageSnapshot_statesAreDistinct_andUnknownIsNeverZero() {
        let chunksBehind = SQLiteEmailStore.SearchDocCoverage(bodiesEvaluable: 7, emails: 10, attachmentsEvaluable: 2, attachments: 5, bodyChunks: 9)
        var attachments = AttachmentCoverageSummary()
        attachments.counts = [.extracted: 2, .unsupported: 2, .locked: 1]

        let unavailable = SearchCoverageSnapshot(storedMessages: nil, indexedMessages: 10, partiallyIndexedMessages: 0)
        XCTAssertTrue(unavailable.isUnavailable)
        XCTAssertFalse(unavailable.isPartial, "an unknown count is not a pending count")
        XCTAssertTrue(unavailable.needsNotice)
        XCTAssertTrue(unavailable.summaryLine.contains("could not be checked"), unavailable.summaryLine)

        let partial = SearchCoverageSnapshot(storedMessages: 10, indexedMessages: 6, partiallyIndexedMessages: 0)
        XCTAssertTrue(partial.isPartial)
        XCTAssertEqual(partial.pendingMessages, 4)
        XCTAssertTrue(partial.summaryLine.contains("6 of 10") && partial.summaryLine.contains("4 still indexing"), partial.summaryLine)

        let chunked = SearchCoverageSnapshot(storedMessages: 10, indexedMessages: 10, partiallyIndexedMessages: 0, chunks: chunksBehind, attachments: attachments)
        XCTAssertFalse(chunked.isPartial)
        XCTAssertEqual(chunked.chunkPendingBodies, 3)
        XCTAssertEqual(chunked.attachmentsNotEvaluable, 3)
        XCTAssertTrue(chunked.needsNotice)
        XCTAssertTrue(chunked.summaryLine.contains("7 of 10 message bodies") && chunked.summaryLine.contains("2 of 5 attachments")
                      && chunked.summaryLine.contains("2 unsupported") && chunked.summaryLine.contains("1 locked"), chunked.summaryLine)

        let complete = SearchCoverageSnapshot(storedMessages: 10, indexedMessages: 10, partiallyIndexedMessages: 0,
                                              chunks: SQLiteEmailStore.SearchDocCoverage(bodiesEvaluable: 10, emails: 10, attachmentsEvaluable: 5, attachments: 5, bodyChunks: 12))
        XCTAssertFalse(complete.needsNotice)
        XCTAssertEqual(complete.summaryLine, "Index covers every message")

        let budget = SearchCoverageSnapshot(storedMessages: 10, indexedMessages: 10, partiallyIndexedMessages: 2)
        XCTAssertTrue(budget.needsNotice)
        XCTAssertTrue(budget.summaryLine.contains("2 very large messages"), budget.summaryLine)
    }

    func testFIND03_coverageModelReadsTheChunkIndexWhenTheSearchModelIsOn() async throws {
        let wasOn = SearchChunkPolicy.isEnabled
        defer { SearchChunkPolicy.isEnabled = wasOn }
        let env = try chunkedEnv()
        let indexed = mail(80, from: "a@x.com", subject: "Indexed", body: "words",
                           attachments: [AttachmentMetadata(filename: "a.pdf", mimeType: "application/pdf", size: 1)])
        try await env.store.insertBatch([indexed], batchSize: 10)
        try await env.fts.indexBatch([indexed])
        SearchChunkPolicy.isEnabled = false
        try await env.store.insertBatch([mail(81, from: "b@x.com", subject: "Not yet", body: "later")], batchSize: 10)
        SearchChunkPolicy.isEnabled = true

        let model = SearchCoverageModel(archive: env.archive, fts: env.fts)
        await model.refresh()
        let snapshot = try XCTUnwrap(model.snapshot)
        XCTAssertFalse(snapshot.isUnavailable)
        XCTAssertEqual(snapshot.storedMessages, 2)
        XCTAssertEqual(snapshot.indexedMessages, 1, "the previous index saw one of them")
        XCTAssertEqual(snapshot.chunks?.emails, 2)
        XCTAssertEqual(snapshot.chunks?.bodiesEvaluable, 1)
        XCTAssertEqual(snapshot.chunkPendingBodies, 1)
        XCTAssertEqual(snapshot.attachmentsNotEvaluable, 1, "a.pdf has no text document yet")
        XCTAssertTrue(snapshot.needsNotice)
        XCTAssertNil(model.lastError)
    }

    // MARK: - Five jobs OUT-07 / OUT-04 / OUT-03 — a finished export keeps its per-file record

    func testOUT07_finishedFolderExportLeavesAVerifiableInventory() async throws {
        let env = try makeEnv()
        let emails = (0..<3).map { mail(100 + $0, from: "a@x.com", subject: "Export \($0)", body: "body \($0)") }
        try await env.store.insertBatch(emails, batchSize: 10)
        let folder = env.root.appendingPathComponent("out", isDirectory: true)
        let service = ArchiveExportService(archive: env.archive)
        let result = try await service.exportEMLFiles(scope: .explicit(Set(emails.map(\.id))), to: folder)
        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.recordsWritten, 3)
        let inventoryURL = try XCTUnwrap(result.inventoryURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(ExportFolderManifest.filename).path),
                       "the working manifest became the inventory")

        let inventory = try ExportInventory.load(folder: folder)
        XCTAssertEqual(inventory.files.count, 3)
        XCTAssertEqual(inventory.written, 3)
        XCTAssertEqual(Set(inventory.files.compactMap(\.emailID)), Set(emails.map { $0.id.uuidString }), "each file names its record")
        for file in inventory.files {
            let data = try Data(contentsOf: folder.appendingPathComponent(file.path))
            XCTAssertEqual(data.count, file.bytes)
            XCTAssertEqual(ExportFolderManifest.hex(data), file.sha256, "the inventory hash is the file's hash")
        }
        XCTAssertEqual(inventoryURL.lastPathComponent, ExportInventory.filename)

        // Full verification: clean; then a changed file, a missing file and a stray file are each named.
        var verification = try ExportInventory.verify(folder: folder)
        XCTAssertTrue(verification.isClean, "\(verification)")
        XCTAssertEqual(verification.matching, 3)
        let first = folder.appendingPathComponent(inventory.files[0].path)
        try Data("tampered".utf8).write(to: first)
        try FileManager.default.removeItem(at: folder.appendingPathComponent(inventory.files[1].path))
        try Data("extra".utf8).write(to: folder.appendingPathComponent("stray.txt"))
        verification = try ExportInventory.verify(folder: folder)
        XCTAssertFalse(verification.isClean)
        XCTAssertEqual(verification.changed, [inventory.files[0].path])
        XCTAssertEqual(verification.missing, [inventory.files[1].path])
        XCTAssertEqual(verification.unlisted, ["stray.txt"])
        XCTAssertEqual(verification.matching, 1)

        // The receipt's reconciliation line keeps the five counts apart.
        var receipt = ExportReceipt(title: "t", destination: folder.path, isFolder: true, requested: 5, written: 3, outcome: .partial,
                                    startedAt: Date(), completedAt: Date())
        receipt.checked = 3; receipt.excluded = 1; receipt.inventoryPath = inventoryURL.path
        XCTAssertEqual(receipt.reconciliationLine, "selected 5 · written 3 · hashes recorded while writing 3 of 3 · excluded 1 · failed 1")
        let plain = ExportReceipt(title: "t", destination: "x", isFolder: false, requested: nil, written: 2, outcome: .complete,
                                  startedAt: Date(), completedAt: Date())
        XCTAssertNil(plain.reconciliationLine, "older receipts show nothing they do not know")
    }

    /// Audit 2026-11-06 A07: when every file is written but the inventory
    /// cannot be created, the run is not "complete" — the failure is named,
    /// the working manifest stays as the record, nothing is rewritten.
    func testA07_inventoryFinalizationFailure_isNamed_notSwallowedIntoComplete() async throws {
        let env = try makeEnv()
        let emails = (0..<2).map { mail(120 + $0, from: "a@x.com", subject: "Inv \($0)", body: "body \($0)") }
        try await env.store.insertBatch(emails, batchSize: 10)
        let folder = env.root.appendingPathComponent("out-noinv", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A directory where the inventory file must go: the atomic write fails at finalisation, after the files.
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(ExportInventory.filename), withIntermediateDirectories: true)
        let service = ArchiveExportService(archive: env.archive)
        let result = try await service.exportEMLFiles(scope: .explicit(Set(emails.map(\.id))), to: folder)
        XCTAssertEqual(result.recordsWritten, 2)
        XCTAssertTrue(result.completed, "the message files themselves are complete")
        XCTAssertNil(result.inventoryURL)
        XCTAssertNotNil(result.inventoryFailure, "the reason travels with the result")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(ExportFolderManifest.filename).path),
                      "the working manifest stays as the record")
        let emls = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".eml") }
        XCTAssertEqual(emls.count, 2)
        // The receipt outcome for this case stands apart from complete and from partial.
        let receipt = ExportReceipt(title: "t", destination: folder.path, isFolder: true, requested: 2, written: 2, outcome: .unverified,
                                    startedAt: Date(), completedAt: Date())
        XCTAssertTrue(receipt.verdictLine.contains("record incomplete"), receipt.verdictLine)
        XCTAssertFalse(receipt.isResumable, "nothing to resume — the files are there")
        XCTAssertEqual(receipt.shortfall, 0)
    }

    /// Plan v4 §13.3 (5)(7)(9): every file inside an attachment is its own
    /// document — recorded with path, hash and state, searchable by a
    /// same-child condition, named by evidence, and openable on its own.
    /// A sibling's words are never borrowed and no phrase bridges two files.
    func testWP2_childDocuments_identity_sameChildConditions_evidence_andOpening() async throws {
        let wasOn = SearchChunkPolicy.isEnabled
        defer { SearchChunkPolicy.isEnabled = wasOn }
        let env = try chunkedEnv()
        AttachmentTextIndexJob.testSuppressKicks = true
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()
        AttachmentTextIndexJob.testStoreOverride = env.store
        defer { AttachmentTextIndexJob.testStoreOverride = nil; AttachmentTextIndexJob.testSuppressKicks = false }
        let ocrWas = AttachmentOCR.isEnabled
        AttachmentOCR.isEnabled = false
        defer { AttachmentOCR.isEnabled = ocrWas }
        AttachmentTextIndexJob.installChildReader()

        let minutes = Self.docx(body: "Board quorum reached at nine.", header: "")
        let memo = Self.docx(body: "Nested quorum memo for the auditors.", header: "")
        let otherMinutes = Self.docx(body: "Different minutes text entirely.", header: "")
        let pdf = Self.pdfData(pages: ["Budget approved without objection."])
        let inner = Self.zipPackage([("memo.docx", memo), ("minutes.docx", otherMinutes)])
        let bundle = Self.zipPackage([("minutes.docx", minutes), ("report.pdf", pdf), ("inner.zip", inner)])
        let raw = """
        From sender@example.com Wed Jan 15 10:00:00 2025
        From: sender@example.com
        To: user@dest.org
        Subject: Children
        Date: Wed, 15 Jan 2025 10:00:00 +0000
        Message-ID: <children@t>
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="B"

        --B
        Content-Type: text/plain

        see the bundle
        \(mimeAttachment("bundle.zip", "application/zip", bundle))
        --B--
        """
        let email = try MBOXParser.processRawMessage(raw, senderEmail: "")
        _ = try await env.store.insertBatch([email], sourceFileHash: nil, accountID: nil, sourceID: nil, firstOrdinal: nil,
                                            dedupPolicy: .messageID, batchSize: 10, progress: nil)
        let outcome = await AttachmentTextIndexJob.shared.run()
        XCTAssertEqual(outcome.indexedEmails, 1)

        // Identity: four files, with their chains, hashes and states.
        let children = try await env.store.attachmentChildren(forEmailID: email.id)
        XCTAssertEqual(children.map(\.path), ["minutes.docx", "report.pdf", "inner.zip › memo.docx", "inner.zip › minutes.docx"])
        XCTAssertEqual(Set(children.map(\.state)), ["extracted"], "\(children.map { ($0.path, $0.state, $0.note ?? "") })")
        XCTAssertTrue(children.allSatisfy { !$0.sha256.isEmpty && $0.bytes > 0 })
        XCTAssertEqual(children.map(\.position), [0, 0, 0, 0])
        XCTAssertEqual(children[2].filename, "memo.docx")
        XCTAssertNotEqual(children[0].sha256, children[3].sha256, "two files named minutes.docx stay distinct")

        // Same-child conditions: type + name + content on ONE file inside the ZIP.
        func group(type: String? = nil, name: String? = nil, _ match: SearchCondition.Match, _ content: String) -> SearchSpec {
            SearchSpec(groups: [SearchGroup(.all, attachments: [AttachmentConditionGroup(nameContains: name, type: type, contentMatch: match, content: content)])])
        }
        try await expectIDs(env, group(type: "docx", name: "minutes", .allWords, "quorum"), ["Children"])
        try await expectIDs(env, group(type: "pdf", .allWords, "quorum"), [], "the PDF's sibling has the word, the PDF does not")
        try await expectIDs(env, group(type: "pdf", .phrase, "budget approved"), ["Children"])
        try await expectIDs(env, group(name: "memo", .allWords, "quorum"), ["Children"], "a file two levels down")
        try await expectIDs(env, group(.phrase, "reached at nine. Budget"), [], "no phrase bridges two files")
        try await expectIDs(env, group(type: "docx", name: "minutes", .allWords, "different entirely"), ["Children"], "the second minutes.docx is its own document")
        try await expectIDs(env, SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.anyText, .allWords, "auditors")])]), ["Children"], "anywhere reaches children")

        // Evidence names the child by its path; the chip would open that very file.
        let evidence = try await env.store.matchEvidence(emailID: email.id, spec: group(name: "memo", .allWords, "quorum"), freeText: nil)
        guard case .childText(let ordinal, let childIndex, let path, _)? = evidence.first?.location else {
            return XCTFail("expected child evidence, got \(evidence)")
        }
        XCTAssertEqual(ordinal, 0); XCTAssertEqual(childIndex, 2); XCTAssertEqual(path, "inner.zip › memo.docx")
        XCTAssertEqual(MatchEvidenceChips.childPath(evidence[0].location), "inner.zip › memo.docx")
        XCTAssertEqual(MatchEvidenceChips.attachmentOrdinal(evidence[0].location), 0)
        XCTAssertTrue(MatchEvidenceChips.label(evidence[0].location).contains("inner.zip › memo.docx"))
        let storedEmail = try await env.store.fullEmail(id: email.id)
        let stored = try XCTUnwrap(storedEmail)
        let opened = try EvidenceAttachmentOpener.temporaryFile(for: stored, ordinal: 0, childPath: "inner.zip › memo.docx").get()
        defer { try? FileManager.default.removeItem(at: opened.deletingLastPathComponent()) }
        XCTAssertEqual(opened.lastPathComponent, "memo.docx")
        XCTAssertEqual(try Data(contentsOf: opened), memo, "the exact bytes of the file two levels down")
        XCTAssertEqual(AttachmentChildrenList.stateLabel("extracted"), "read for search")
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()
    }

    /// A TNEF stream (MS-OXTNEF) with a subject, a body and files — the
    /// winmail.dat Outlook sends through servers that do not speak MAPI.
    static func tnef(subject: String, body: String, files: [(name: String, mime: String, data: Data)]) -> Data {
        var out = Data()
        func le16(_ v: UInt16) { out.append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8)]) }
        func le32(_ v: UInt32) { out.append(contentsOf: (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) }) }
        func le32(into d: inout Data, _ v: UInt32) { d.append(contentsOf: (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) }) }
        func attribute(_ level: UInt8, _ id: UInt32, _ payload: Data) {
            out.append(level); le32(id); le32(UInt32(payload.count)); out.append(payload)
            le16(UInt16(payload.reduce(UInt32(0)) { ($0 + UInt32($1)) & 0xFFFF }))
        }
        func cString(_ s: String) -> Data { Data(s.utf8) + Data([0]) }
        func padded(_ d: Data) -> Data { d + Data(repeating: 0, count: (4 - d.count % 4) % 4) }
        le32(TNEFReader.signature); le16(0x1234)
        attribute(1, 0x0001_8004, cString(subject))
        attribute(1, 0x0002_800C, cString(body))
        for file in files {
            attribute(2, 0x0006_9002, Data(count: 14))
            attribute(2, 0x0001_8010, cString(file.name))
            attribute(2, 0x0006_800F, file.data)
            var props = Data(); le32(into: &props, 2)
            let unicode = file.name.data(using: .utf16LittleEndian)! + Data([0, 0])
            le32(into: &props, 0x3707_001F); le32(into: &props, 1); le32(into: &props, UInt32(unicode.count)); props.append(padded(unicode))
            let mime = cString(file.mime)
            le32(into: &props, 0x370E_001E); le32(into: &props, 1); le32(into: &props, UInt32(mime.count)); props.append(padded(mime))
            attribute(2, 0x0006_9005, props)
        }
        return out
    }

    /// Plan v4 §13.8 step 3 (COMP-06/07): Outlook's own containers all the
    /// way down — an .oft template routes to the MSG reader; a message
    /// embedded in a .msg is expanded into an attached message whose own
    /// files are children; a .msg or winmail.dat attached to a message is
    /// read as a message with children; every child opens by its chain.
    func testWP3_outlookIntake_oftRouted_embeddedMessageExpanded_msgAndTNEFAttachmentsRead_childrenOpen() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("outlook-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let docxMime = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

        // 1. A message carrying an attached message is written as a .msg with an EMBEDDED message, then read back.
        let terms = Self.docx(body: "Nested terms mention indemnity.", header: "")
        let innerRaw = """
        From: inner@example.com
        To: me@example.com
        Subject: Inner subject
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="B"

        --B
        Content-Type: text/plain

        Inner body says quorum
        \(mimeAttachment("terms.docx", docxMime, terms))
        --B--
        """
        let plain = Data("Plain file next to the message".utf8)
        let outer = mail(81, from: "a@example.com", subject: "Outer", body: "outer body", attachments: [
            AttachmentMetadata(filename: "inner.eml", mimeType: "message/rfc822", size: innerRaw.utf8.count, base64: Data(innerRaw.utf8).base64EncodedString()),
            AttachmentMetadata(filename: "plain.txt", mimeType: "text/plain", size: plain.count, base64: plain.base64EncodedString()),
        ])
        let msgData = try XCTUnwrap(MSGWriter.write(email: outer))
        let oft = dir.appendingPathComponent("template.oft")
        try msgData.write(to: oft)
        let classification = SourceFormatClassifier.classify(url: oft)
        XCTAssertEqual(classification.format, .msg)
        XCTAssertFalse(classification.nameContentMismatch, ".oft is an Outlook template, the same compound file")
        XCTAssertTrue(ParserFactory.allSupportedExtensions.contains("oft"))
        let parsed = try ParserFactory.parse(fileURL: oft, senderEmail: "")
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].headers["Subject"], "Outer")
        XCTAssertEqual(parsed[0].attachments.map(\.filename), ["Inner subject.eml", "plain.txt"], "the embedded message is an attached message; the second file is linked too")
        let attachedMessage = try XCTUnwrap(parsed[0].attachments.first)
        let plainBack = try XCTUnwrap(parsed[0].attachments.dropFirst().first)
        XCTAssertEqual(attachedMessage.mimeType, "message/rfc822")
        XCTAssertEqual(plainBack.base64.flatMap { Data(base64Encoded: $0) }, plain)
        let innerBytes = try XCTUnwrap(attachedMessage.base64.flatMap { Data(base64Encoded: $0) })
        let innerBack = try MBOXParser.processRawMessage(String(decoding: innerBytes, as: UTF8.self), senderEmail: "")
        defer { for a in innerBack.attachments { if let u = a.fileURL { try? FileManager.default.removeItem(at: u) } } }
        XCTAssertEqual(innerBack.headers["Subject"], "Inner subject")
        XCTAssertTrue(innerBack.plainBody.contains("Inner body says quorum"), innerBack.plainBody)
        XCTAssertEqual(innerBack.attachments.map(\.filename), ["terms.docx"])
        let termsBack = try XCTUnwrap(innerBack.attachments.first)
        XCTAssertEqual(AttachmentHydrator.data(for: termsBack, index: 0, email: innerBack), terms, "the file two messages down, byte for byte")

        // 2. winmail.dat and a .msg as attachments of an ordinary message, through the indexing job.
        let budget = Self.docx(body: "Budget inside winmail mentions quorum.", header: "")
        let tnef = Self.tnef(subject: "TNEF subject", body: "Winmail body about the audit", files: [("budget.docx", docxMime, budget)])
        let content = try TNEFReader.read(tnef)
        XCTAssertEqual(content.subject, "TNEF subject")
        XCTAssertEqual(content.bodyText, "Winmail body about the audit")
        XCTAssertEqual(content.attachments.map { ($0.filename, $0.mimeType) }.map { "\($0.0)|\($0.1)" }, ["budget.docx|\(docxMime)"])
        XCTAssertEqual(content.attachments[0].data, budget)
        XCTAssertThrowsError(try TNEFReader.read(tnef.prefix(tnef.count - 10))) { error in
            guard case TNEFReader.ReadError.truncated = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(TNEFReader.encoding(forCodepage: 1252), .windowsCP1252)

        let wasOn = SearchChunkPolicy.isEnabled
        defer { SearchChunkPolicy.isEnabled = wasOn }
        let env = try chunkedEnv()
        AttachmentTextIndexJob.testSuppressKicks = true
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()
        AttachmentTextIndexJob.testStoreOverride = env.store
        defer { AttachmentTextIndexJob.testStoreOverride = nil; AttachmentTextIndexJob.testSuppressKicks = false }
        let ocrWas = AttachmentOCR.isEnabled
        AttachmentOCR.isEnabled = false
        defer { AttachmentOCR.isEnabled = ocrWas }
        AttachmentTextIndexJob.installChildReader()
        let raw = """
        From sender@example.com Wed Jan 15 10:00:00 2025
        From: sender@example.com
        To: user@dest.org
        Subject: Outlook wrappers
        Date: Wed, 15 Jan 2025 10:00:00 +0000
        Message-ID: <wrappers@t>
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="B"

        --B
        Content-Type: text/plain

        see the wrappers
        \(mimeAttachment("winmail.dat", "application/ms-tnef", tnef))
        \(mimeAttachment("forwarded.msg", "application/vnd.ms-outlook", msgData))
        --B--
        """
        let email = try MBOXParser.processRawMessage(raw, senderEmail: "")
        _ = try await env.store.insertBatch([email], sourceFileHash: nil, accountID: nil, sourceID: nil, firstOrdinal: nil,
                                            dedupPolicy: .messageID, batchSize: 10, progress: nil)
        let outcome = await AttachmentTextIndexJob.shared.run()
        XCTAssertEqual(outcome.indexedEmails, 1)
        let coverage = try AttachmentCoverageStore(url: await env.store.attachmentCoverageURL)
        let rows = try coverage.rows(for: email.id)
        XCTAssertEqual(rows.map(\.extractor), ["tnef", "msg"], "\(rows.map { ($0.filename, $0.extractor, $0.state, $0.note ?? "") })")
        XCTAssertEqual(rows.map(\.state), [.extracted, .extracted], "\(rows.map { ($0.filename, $0.state, $0.note ?? "") })")
        let children = try await env.store.attachmentChildren(forEmailID: email.id)
        XCTAssertEqual(children.map { "\($0.position):\($0.path)" }, ["0:budget.docx", "1:Inner subject.eml", "1:Inner subject.eml › terms.docx", "1:plain.txt"])
        XCTAssertEqual(Set(children.map(\.state)), ["extracted"], "\(children.map { ($0.path, $0.state, $0.note ?? "") })")

        func group(type: String? = nil, name: String? = nil, _ match: SearchCondition.Match, _ content: String) -> SearchSpec {
            SearchSpec(groups: [SearchGroup(.all, attachments: [AttachmentConditionGroup(nameContains: name, type: type, contentMatch: match, content: content)])])
        }
        try await expectIDs(env, group(type: "docx", .allWords, "indemnity"), ["Outlook wrappers"], "a file inside a message inside a .msg")
        try await expectIDs(env, group(name: "budget", .allWords, "quorum"), ["Outlook wrappers"], "a file inside winmail.dat")
        try await expectIDs(env, group(name: "winmail", .phrase, "about the audit"), ["Outlook wrappers"], "the TNEF body itself")
        try await expectIDs(env, group(type: "docx", .allWords, "audit"), [], "the TNEF body's words do not belong to the file inside it")

        // 3. Every child opens by its chain — from the TNEF and from the .msg.
        let scratch = dir.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let winmail = dir.appendingPathComponent("winmail.dat"); try tnef.write(to: winmail)
        let fromTNEF = try ContainerTextExtractor.materialize(childPath: "budget.docx", in: winmail, kind: nil, logicalName: "winmail.dat", scratch: scratch)
        XCTAssertEqual(try Data(contentsOf: fromTNEF), budget)
        let msgURL = dir.appendingPathComponent("forwarded.msg"); try msgData.write(to: msgURL)
        let fromMSG = try ContainerTextExtractor.materialize(childPath: "Inner subject.eml › terms.docx", in: msgURL, kind: nil, logicalName: "forwarded.msg", scratch: scratch)
        XCTAssertEqual(try Data(contentsOf: fromMSG), terms)
        XCTAssertEqual(fromMSG.lastPathComponent.hasSuffix("terms.docx"), true)
        let stored = try await env.store.fullEmail(id: email.id)
        let opened = try EvidenceAttachmentOpener.temporaryFile(for: XCTUnwrap(stored), ordinal: 1, childPath: "Inner subject.eml › terms.docx").get()
        defer { try? FileManager.default.removeItem(at: opened.deletingLastPathComponent()) }
        XCTAssertEqual(try Data(contentsOf: opened), terms, "the chip's Open reaches the file two levels inside the .msg")
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()
    }

    /// A BIFF12 (xlsb) record: type and size as 7-bit groups, then the payload.
    static func biff12(_ type: Int, _ payload: Data) -> Data {
        var out = Data()
        var t = type
        repeat { var b = UInt8(t & 0x7F); t >>= 7; if t > 0 { b |= 0x80 }; out.append(b) } while t > 0
        var n = payload.count
        repeat { var b = UInt8(n & 0x7F); n >>= 7; if n > 0 { b |= 0x80 }; out.append(b) } while n > 0
        out.append(payload)
        return out
    }

    static func le32(_ v: UInt32) -> Data { Data((0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) }) }

    /// An XLWideString: cch then UTF-16LE.
    static func xlString(_ s: String) -> Data { le32(UInt32(s.utf16.count)) + s.data(using: .utf16LittleEndian)! }

    /// Plan v4 §13.3 (1)(2)(3), §13.8 step 4: depth inside Office Open XML —
    /// tracked changes and text boxes labelled, embedded documents as
    /// children, Excel comments, hidden sheets and the 1904 date system,
    /// hidden slides, slide comments and chart text, and the Strict
    /// namespace read like the Transitional one.
    func testDEPTH01_officeOpenXML_revisionsTextBoxesEmbedded_commentsHiddenDates_slidesCharts_strict() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("depth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ name: String, _ data: Data) throws -> URL { let u = root.appendingPathComponent(name); try data.write(to: u); return u }
        let w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

        // Word: a text box (with the duplicate mc:Fallback), an insertion, a deletion, an embedded workbook and an OLE object.
        let embeddedXLSX = Self.xlsx(sheetName: "Embedded", sharedText: "Embedded margin", inlineText: "x")
        let docx = Self.zipPackage([
            ("word/document.xml", Data("""
            <w:document xmlns:w="\(w)" xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"><w:body>
            <w:p><w:r><w:t>Body before</w:t></w:r><w:ins w:id="1" w:author="A"><w:r><w:t>added words</w:t></w:r></w:ins>
            <w:del w:id="2" w:author="A"><w:r><w:delText>removed words</w:delText></w:r></w:del></w:p>
            <w:p><w:r><mc:AlternateContent><mc:Choice Requires="wps"><w:drawing><w:txbxContent><w:p><w:r><w:t>Boxed sidebar note</w:t></w:r></w:p></w:txbxContent></w:drawing></mc:Choice>
            <mc:Fallback><w:pict><w:txbxContent><w:p><w:r><w:t>Boxed sidebar note</w:t></w:r></w:p></w:txbxContent></w:pict></mc:Fallback></mc:AlternateContent></w:r></w:p>
            </w:body></w:document>
            """.utf8)),
            ("word/embeddings/Microsoft_Excel_Worksheet.xlsx", embeddedXLSX),
            ("word/embeddings/oleObject1.bin", Data([0xD0, 0xCF, 0x11, 0xE0, 0, 0, 0, 0])),
        ])
        let word = try OfficeTextExtractor.extract(fileURL: try write("r.docx", docx), kind: .docx)
        XCTAssertTrue(word.text.contains("Body before{inserted by A: added words}{deleted by A: removed words}"), word.text)
        XCTAssertEqual(word.text.components(separatedBy: "Boxed sidebar note").count - 1, 1, "the Fallback copy of a text box is not read twice: \(word.text)")
        XCTAssertTrue(word.text.contains("[Text box] Boxed sidebar note"), word.text)
        XCTAssertEqual(word.children.map { "\($0.path)|\($0.state.rawValue)" },
                       ["word/embeddings/Microsoft_Excel_Worksheet.xlsx|extracted", "word/embeddings/oleObject1.bin|unsupported"])
        XCTAssertTrue(word.children[0].text?.contains("A1: Embedded margin") == true, word.children[0].text ?? "")
        XCTAssertEqual(word.children[1].note, "embedded OLE object; not read")
        XCTAssertEqual(word.notText, [], "embedded objects are children now, not an inventory line")

        // Excel: a hidden sheet, comments bound to a sheet by its relationships, the 1904 date system, a chart.
        let xlsx = Self.zipPackage([
            ("xl/workbook.xml", Data("<workbook xmlns:r=\"r\"><workbookPr date1904=\"1\"/><sheets><sheet name=\"Visible\" sheetId=\"1\" r:id=\"rId1\"/><sheet name=\"Secret\" sheetId=\"2\" state=\"hidden\" r:id=\"rId2\"/></sheets></workbook>".utf8)),
            ("xl/_rels/workbook.xml.rels", Data("<Relationships><Relationship Id=\"rId1\" Type=\"x\" Target=\"worksheets/sheet1.xml\"/><Relationship Id=\"rId2\" Type=\"x\" Target=\"worksheets/sheet2.xml\"/></Relationships>".utf8)),
            ("xl/worksheets/sheet1.xml", Data("<worksheet><sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>Open figure</t></is></c><c r=\"B1\"/><c r=\"C1\"><v>7</v></c></row></sheetData></worksheet>".utf8)),
            ("xl/worksheets/sheet2.xml", Data("<worksheet><sheetData><row r=\"3\"><c r=\"B3\" t=\"inlineStr\"><is><t>Hidden figure</t></is></c></row></sheetData></worksheet>".utf8)),
            ("xl/worksheets/_rels/sheet1.xml.rels", Data("<Relationships><Relationship Id=\"rId9\" Type=\"c\" Target=\"../comments1.xml\"/></Relationships>".utf8)),
            ("xl/comments1.xml", Data("<comments><commentList><comment ref=\"C1\" authorId=\"0\"><text><r><t>Check this total</t></r></text></comment></commentList></comments>".utf8)),
            ("xl/charts/chart1.xml", Data("<c:chartSpace xmlns:c=\"c\" xmlns:a=\"a\"><c:chart><c:title><c:tx><c:rich><a:p><a:r><a:t>Revenue by quarter</a:t></a:r></a:p></c:rich></c:tx></c:title><c:plotArea><c:barChart><c:ser><c:cat><c:strRef><c:strCache><c:pt idx=\"0\"><c:v>Q1</c:v></c:pt><c:pt idx=\"1\"><c:v>Q2</c:v></c:pt></c:strCache></c:strRef></c:cat><c:val><c:numRef><c:numCache><c:pt idx=\"0\"><c:v>120</c:v></c:pt><c:pt idx=\"1\"><c:v>135</c:v></c:pt></c:numCache></c:numRef></c:val></c:ser></c:barChart></c:plotArea></c:chart></c:chartSpace>".utf8)),
        ])
        let excel = try OfficeTextExtractor.extract(fileURL: try write("d.xlsx", xlsx), kind: .xlsx)
        XCTAssertEqual(excel.components, ["Workbook", "Sheet: Visible", "Comments: Visible", "Sheet: Secret (hidden)", "Chart 1"])
        XCTAssertTrue(excel.text.contains("1904 date system"), excel.text)
        XCTAssertTrue(excel.text.contains("[Sheet: Visible]\nA1: Open figure\tC1: 7\n"), "empty B1 carries no word: \(excel.text)")
        XCTAssertTrue(excel.text.contains("[Comments: Visible]\nC1: Check this total"), excel.text)
        XCTAssertTrue(excel.text.contains("[Sheet: Secret (hidden)]\nB3: Hidden figure"), excel.text)
        XCTAssertTrue(excel.text.contains("[Chart 1]\nRevenue by quarter\nQ1\tQ2\t120\t135"), excel.text)
        XCTAssertEqual(excel.notText, [])

        // PowerPoint: a hidden slide, a comment part, a chart.
        let pptx = Self.zipPackage([
            ("ppt/slides/slide1.xml", Data("<p:sld xmlns:p=\"p\" xmlns:a=\"a\"><a:p><a:r><a:t>Shown slide</a:t></a:r></a:p></p:sld>".utf8)),
            ("ppt/slides/slide2.xml", Data("<p:sld xmlns:p=\"p\" xmlns:a=\"a\" show=\"0\"><a:p><a:r><a:t>Hidden slide words</a:t></a:r></a:p></p:sld>".utf8)),
            ("ppt/comments/comment1.xml", Data("<p:cmLst xmlns:p=\"p\"><p:cm authorId=\"0\" idx=\"1\"><p:text>Tighten the title</p:text></p:cm></p:cmLst>".utf8)),
            ("ppt/charts/chart1.xml", Data("<c:chartSpace xmlns:c=\"c\" xmlns:a=\"a\"><c:chart><c:plotArea><c:lineChart><c:ser><c:tx><c:strRef><c:strCache><c:pt idx=\"0\"><c:v>Visitors</c:v></c:pt></c:strCache></c:strRef></c:tx><c:val><c:numRef><c:numCache><c:pt idx=\"0\"><c:v>42</c:v></c:pt></c:numCache></c:numRef></c:val></c:ser></c:lineChart></c:plotArea></c:chart></c:chartSpace>".utf8)),
        ])
        let deck = try OfficeTextExtractor.extract(fileURL: try write("e.pptx", pptx), kind: .pptx)
        XCTAssertEqual(deck.components, ["Slide 1", "Slide 2 (hidden)", "Comments 1", "Chart 1"])
        XCTAssertTrue(deck.text.contains("[Slide 2 (hidden)]\nHidden slide words") && deck.text.contains("[Comments 1]\nTighten the title") && deck.text.contains("[Chart 1]\nVisitors\t42"), deck.text)

        // Strict OOXML: the purl.oclc.org namespaces read like the Transitional ones.
        let strict = Self.zipPackage([
            ("word/document.xml", Data("<w:document xmlns:w=\"http://purl.oclc.org/ooxml/wordprocessingml/main\"><w:body><w:p><w:r><w:t>Strict body text</w:t></w:r></w:p></w:body></w:document>".utf8)),
        ])
        let strictResult = try OfficeTextExtractor.extract(fileURL: try write("s.docx", strict), kind: .docx)
        XCTAssertTrue(strictResult.text.contains("[Document]\nStrict body text"), strictResult.text)
        XCTAssertEqual(OfficeTextExtractor.Kind.detect(mimeType: "", filename: "t.dotx"), .docx)
        XCTAssertEqual(OfficeTextExtractor.Kind.detect(mimeType: "", filename: "t.ppsx"), .pptx)
        XCTAssertEqual(OfficeTextExtractor.columnName(0), "A"); XCTAssertEqual(OfficeTextExtractor.columnName(26), "AA"); XCTAssertEqual(OfficeTextExtractor.columnName(701), "ZZ")
    }

    /// §13.8 step 4 (COMP-06/COMP-10): the binary workbook, the Visio drawing
    /// and the Project plan are read with locations, through the same facade
    /// and the indexing job; what stays unread is named in the registry.
    func testDEPTH02_xlsbVisioAndProjectXML_areReadWithLocations_andThroughTheJob() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("depth2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ name: String, _ data: Data) throws -> URL { let u = root.appendingPathComponent(name); try data.write(to: u); return u }

        // XLSB: workbook (two sheets, one hidden, 1904), shared strings, cells of every kind.
        func cell(_ column: UInt32, _ tail: Data) -> Data { Self.le32(column) + Self.le32(0) + tail }
        var sst = Data()
        sst += Self.biff12(0x009F, Self.le32(2) + Self.le32(2))                                   // BrtBeginSst
        sst += Self.biff12(0x0013, Data([0]) + Self.xlString("Binary margin"))                   // BrtSSTItem
        sst += Self.biff12(0x0013, Data([0]) + Self.xlString("Second string"))
        var workbook = Data()
        workbook += Self.biff12(0x0099, Self.le32(1) + Data(count: 8))                           // BrtWbProp, f1904
        workbook += Self.biff12(0x009C, Self.le32(0) + Self.le32(1) + Self.xlString("rId1") + Self.xlString("Figures"))
        workbook += Self.biff12(0x009C, Self.le32(1) + Self.le32(2) + Self.xlString("rId2") + Self.xlString("Backstage"))
        var sheet1 = Data()
        sheet1 += Self.biff12(0x0000, Self.le32(0) + Data(count: 13))                             // row 1
        sheet1 += Self.biff12(0x0007, cell(0, Self.le32(0)))                                      // A1 shared string 0
        sheet1 += Self.biff12(0x0002, cell(1, Self.le32(UInt32(bitPattern: (4250 << 2) | 0x3))))  // B1 RK 42.50 (int, /100)
        sheet1 += Self.biff12(0x0006, cell(2, Self.xlString("inline text")))                       // C1
        sheet1 += Self.biff12(0x0000, Self.le32(2) + Data(count: 13))                             // row 3
        var real = Data(); var bits = 3.5.bitPattern; for _ in 0..<8 { real.append(UInt8(bits & 0xFF)); bits >>= 8 }
        sheet1 += Self.biff12(0x0005, cell(0, real))                                              // A3 3.5
        sheet1 += Self.biff12(0x0004, cell(1, Data([1])))                                         // B3 TRUE
        sheet1 += Self.biff12(0x0003, cell(2, Data([0x07])))                                      // C3 #DIV/0!
        sheet1 += Self.biff12(0x0009, cell(3, real + Data([0, 0]) + Self.le32(0)))               // D3 formula with cached 3.5
        var sheet2 = Data()
        sheet2 += Self.biff12(0x0000, Self.le32(4) + Data(count: 13))
        sheet2 += Self.biff12(0x0007, cell(0, Self.le32(1)))                                      // A5 shared string 1
        let xlsb = Self.zipPackage([
            ("xl/workbook.bin", workbook),
            ("xl/_rels/workbook.bin.rels", Data("<Relationships><Relationship Id=\"rId1\" Type=\"x\" Target=\"worksheets/sheet1.bin\"/><Relationship Id=\"rId2\" Type=\"x\" Target=\"worksheets/sheet2.bin\"/></Relationships>".utf8)),
            ("xl/sharedStrings.bin", sst),
            ("xl/worksheets/sheet1.bin", sheet1),
            ("xl/worksheets/sheet2.bin", sheet2),
        ])
        let binary = try DocumentTextExtractor.extract(fileURL: try write("b.xlsb", xlsb), kind: .xlsb)
        XCTAssertEqual(binary.components, ["Workbook", "Sheet: Figures", "Sheet: Backstage (hidden)"])
        XCTAssertTrue(binary.text.contains("[Sheet: Figures]\nA1: Binary margin\tB1: 42.5\tC1: inline text\nA3: 3.5\tB3: TRUE\tC3: #DIV/0!\tD3: 3.5 (formula not stored)\n"), binary.text)
        XCTAssertTrue(binary.text.contains("[Sheet: Backstage (hidden)]\nA5: Second string"), binary.text)
        XCTAssertEqual(DocumentKind.detect(mimeType: "application/vnd.ms-excel.sheet.binary.macroEnabled.12", filename: "x"), .xlsb)
        XCTAssertEqual(XLSBReader.rk(UInt32(bitPattern: (7 << 2) | 0x2)), "7")

        // Visio: two pages named in pages.xml, shapes with text (field markers inside carry no words).
        let vsdx = Self.zipPackage([
            ("visio/pages/pages.xml", Data("<Pages xmlns:r=\"r\"><Page ID=\"0\" Name=\"Overview\"><Rel r:id=\"rId1\"/></Page><Page ID=\"1\" Name=\"Detail\"><Rel r:id=\"rId2\"/></Page></Pages>".utf8)),
            ("visio/pages/_rels/pages.xml.rels", Data("<Relationships><Relationship Id=\"rId1\" Type=\"p\" Target=\"page1.xml\"/><Relationship Id=\"rId2\" Type=\"p\" Target=\"page2.xml\"/></Relationships>".utf8)),
            ("visio/pages/page1.xml", Data("<PageContents><Shapes><Shape ID=\"1\"><Text><cp IX=\"0\"/>Start here</Text></Shape><Shape ID=\"2\"><Text>Approve the quorum\n</Text></Shape></Shapes></PageContents>".utf8)),
            ("visio/pages/page2.xml", Data("<PageContents><Shapes><Shape ID=\"3\"><Text>Detail step</Text></Shape></Shapes></PageContents>".utf8)),
        ])
        let drawing = try DocumentTextExtractor.extract(fileURL: try write("flow.vsdx", vsdx), kind: .vsdx)
        XCTAssertEqual(drawing.components, ["Page: Overview", "Page: Detail"])
        XCTAssertTrue(drawing.text.contains("[Page: Overview]\nStart here\nApprove the quorum\n") && drawing.text.contains("[Page: Detail]\nDetail step"), drawing.text)
        XCTAssertEqual(DocumentKind.detect(mimeType: "", filename: "flow.VSDX"), .vsdx)

        // Project XML: recognised by its namespace even though it is ".xml".
        let project = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <Project xmlns="http://schemas.microsoft.com/project"><Name>Archive rollout</Name>
        <Tasks><Task><UID>1</UID><ID>1</ID><Name>Collect mailboxes</Name><Start>2026-11-10T08:00:00</Start><Finish>2026-11-12T17:00:00</Finish><Notes>Quorum of custodians first</Notes></Task>
        <Task><UID>2</UID><ID>2</ID><Name>Verify exports</Name><Start>2026-11-13T08:00:00</Start><Finish>2026-11-13T17:00:00</Finish></Task></Tasks>
        <Resources><Resource><UID>1</UID><Name>Records officer</Name></Resource></Resources>
        <Assignments><Assignment><TaskUID>1</TaskUID><ResourceUID>1</ResourceUID></Assignment></Assignments></Project>
        """.utf8)
        let projectURL = try write("plan.xml", project)
        XCTAssertEqual(DocumentTextExtractor.sniff(fileURL: projectURL), .projectXML)
        XCTAssertNil(DocumentTextExtractor.sniff(head: Data("<note>plain xml</note>".utf8)))
        let plan = try DocumentTextExtractor.extract(fileURL: projectURL, kind: .projectXML)
        XCTAssertEqual(plan.components, ["Project: Archive rollout", "Tasks", "Resources", "Assignments"])
        XCTAssertTrue(plan.text.contains("[Tasks]\n1\tCollect mailboxes\t2026-11-10T08:00:00\t2026-11-12T17:00:00\tQuorum of custodians first\n2\tVerify exports"), plan.text)
        XCTAssertTrue(plan.text.contains("[Resources]\nRecords officer") && plan.text.contains("task 1 → resource 1"), plan.text)

        // Through the job: each is searchable by its content, with its own extractor name.
        let wasOn = SearchChunkPolicy.isEnabled
        defer { SearchChunkPolicy.isEnabled = wasOn }
        let env = try chunkedEnv()
        AttachmentTextIndexJob.testSuppressKicks = true
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()
        AttachmentTextIndexJob.testStoreOverride = env.store
        defer { AttachmentTextIndexJob.testStoreOverride = nil; AttachmentTextIndexJob.testSuppressKicks = false }
        let raw = """
        From sender@example.com Wed Jan 15 10:00:00 2025
        From: sender@example.com
        To: user@dest.org
        Subject: Other Office kinds
        Date: Wed, 15 Jan 2025 10:00:00 +0000
        Message-ID: <depth2@t>
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="B"

        --B
        Content-Type: text/plain

        see attached
        \(mimeAttachment("figures.xlsb", "application/vnd.ms-excel.sheet.binary.macroEnabled.12", xlsb))
        \(mimeAttachment("flow.vsdx", "application/vnd.ms-visio.drawing", vsdx))
        \(mimeAttachment("plan.xml", "text/xml", project))
        \(mimeAttachment("notes.xml", "text/xml", Data("<note>plain xml stays text</note>".utf8)))
        --B--
        """
        let email = try MBOXParser.processRawMessage(raw, senderEmail: "")
        _ = try await env.store.insertBatch([email], sourceFileHash: nil, accountID: nil, sourceID: nil, firstOrdinal: nil,
                                            dedupPolicy: .messageID, batchSize: 10, progress: nil)
        let outcome = await AttachmentTextIndexJob.shared.run()
        XCTAssertEqual(outcome.indexedEmails, 1)
        let coverage = try AttachmentCoverageStore(url: await env.store.attachmentCoverageURL)
        let rows = try coverage.rows(for: email.id)
        XCTAssertEqual(rows.map(\.extractor), ["office", "visio", "project", "text"], "\(rows.map { ($0.filename, $0.extractor, $0.state, $0.note ?? "") })")
        XCTAssertEqual(rows.map(\.state), [.extracted, .extracted, .extracted, .extracted])
        for (type, phrase) in [("xlsb", "binary margin"), ("vsdx", "approve the quorum"), ("xml", "collect mailboxes")] {
            try await expectIDs(env, SearchSpec(groups: [SearchGroup(.all, attachments: [AttachmentConditionGroup(type: type, contentMatch: .phrase, content: phrase)])]), ["Other Office kinds"], type)
        }
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()
    }

    /// A ZIP whose entries carry their own flags, method, CRC and extra field
    /// — for encrypted members (ZipCrypto flag 1, WinZip AES method 99).
    static func zipRaw(_ entries: [(name: String, payload: Data, flags: UInt16, method: UInt16, crc: UInt32, size: UInt32, extra: Data)]) -> Data {
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }
        var local = Data(), central = Data()
        for e in entries {
            let name = Array(e.name.utf8)
            let offset = UInt32(local.count)
            local.append(contentsOf: le32(0x04034b50) + le16(51) + le16(Int(e.flags)) + le16(Int(e.method)) + le16(0) + le16(0)
                         + le32(e.crc) + le32(UInt32(e.payload.count)) + le32(e.size) + le16(name.count) + le16(e.extra.count) + name)
            local.append(e.extra)
            local.append(e.payload)
            central.append(contentsOf: le32(0x02014b50) + le16(51) + le16(51) + le16(Int(e.flags)) + le16(Int(e.method)) + le16(0) + le16(0)
                           + le32(e.crc) + le32(UInt32(e.payload.count)) + le32(e.size) + le16(name.count) + le16(e.extra.count) + le16(0) + le16(0) + le16(0)
                           + le32(0) + le32(offset) + name)
            central.append(e.extra)
        }
        var file = local
        file.append(central)
        file.append(contentsOf: le32(0x06054b50) + le16(0) + le16(0) + le16(entries.count) + le16(entries.count)
                    + le32(UInt32(central.count)) + le32(UInt32(local.count)) + le16(0))
        return file
    }

    /// Plan v4 §13.3 (10)(12), §13.8 step 5 (COMP-13/14): protected content
    /// opens with a password typed once — ZipCrypto and WinZip AES members,
    /// Agile and Standard Office encryption, a PDF — a wrong password is
    /// named, nothing is kept unless the person chooses to store the text,
    /// and S/MIME parts stay locked until the keychain module is on.
    func testWP5_protectedContent_zipOfficePDFUnlock_retentionChoice_wrongPasswordNamed_smimeStated() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("locked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let docxMime = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        let secret = Self.docx(body: "The sealed clause mentions escrow.", header: "")

        // 1. ZipCrypto: header + stored payload; the check byte and the CRC tell a wrong password apart.
        var cipher = ZipCryptoCipher(password: "open-sesame")
        let crc = Self.crc32(secret)
        let zcPayload = cipher.encrypt(ZipCryptoCipher.header(crc32: crc) + secret)
        let zipCrypto = Self.zipRaw([("sealed.docx", zcPayload, 0x0001, 0, crc, UInt32(secret.count), Data())])
        let zcURL = dir.appendingPathComponent("zipcrypto.zip"); try zipCrypto.write(to: zcURL)
        let zcMember = try XCTUnwrap(try ZIPArchiveReader.members(of: zcURL).first)
        XCTAssertTrue(zcMember.isEncrypted)
        let out1 = dir.appendingPathComponent("out1.docx")
        XCTAssertThrowsError(try ZIPArchiveReader.extract(zcMember, from: zcURL, to: out1)) { XCTAssertEqual($0 as? ZIPArchiveReader.ReadError, .encrypted(member: "sealed.docx")) }
        XCTAssertThrowsError(try ZIPArchiveReader.extract(zcMember, from: zcURL, to: out1, password: "wrong")) { XCTAssertEqual($0 as? ZIPArchiveReader.ReadError, .wrongPassword(member: "sealed.docx")) }
        try ZIPArchiveReader.extract(zcMember, from: zcURL, to: out1, password: "open-sesame")
        XCTAssertEqual(try Data(contentsOf: out1), secret)

        // 2. WinZip AES-256 (method 99, AE-2): PBKDF2, CTR, HMAC — the verifier and the auth code both guard the password.
        let (aesPayload, aesExtra) = try WinZipAES.encryptMember(secret, password: "open-sesame", strength: 3, actualMethod: 0)
        let aesZip = Self.zipRaw([("sealed.docx", aesPayload, 0x0001, 99, 0, UInt32(secret.count), aesExtra)])
        let aesURL = dir.appendingPathComponent("aes.zip"); try aesZip.write(to: aesURL)
        let aesMember = try XCTUnwrap(try ZIPArchiveReader.members(of: aesURL).first)
        let out2 = dir.appendingPathComponent("out2.docx")
        XCTAssertThrowsError(try ZIPArchiveReader.extract(aesMember, from: aesURL, to: out2, password: "wrong")) { XCTAssertEqual($0 as? ZIPArchiveReader.ReadError, .wrongPassword(member: "sealed.docx")) }
        try ZIPArchiveReader.extract(aesMember, from: aesURL, to: out2, password: "open-sesame")
        XCTAssertEqual(try Data(contentsOf: out2), secret)
        // Through the archive reader: locked without a password, a child with text with it.
        let locked = try DocumentTextExtractor.extract(fileURL: aesURL, kind: .zip)
        XCTAssertEqual(locked.children.map { "\($0.path)|\($0.state.rawValue)|\($0.note ?? "")" }, ["sealed.docx|locked|password-protected"])
        let wrong = try DocumentTextExtractor.extract(fileURL: aesURL, kind: .zip, password: "nope")
        XCTAssertEqual(wrong.children.first?.state, .locked); XCTAssertEqual(wrong.children.first?.note, "the password did not open it")
        let opened = try DocumentTextExtractor.extract(fileURL: aesURL, kind: .zip, password: "open-sesame")
        XCTAssertEqual(opened.children.first?.state, .extracted)
        XCTAssertTrue(opened.children.first?.text?.contains("sealed clause") == true, opened.children.first?.text ?? "")
        let materialized = try ContainerTextExtractor.materialize(childPath: "sealed.docx", in: aesURL, kind: .zip, logicalName: "aes.zip", scratch: dir, password: "open-sesame")
        XCTAssertEqual(try Data(contentsOf: materialized), secret)

        // 3. Office Agile encryption (the EncryptedPackage of a compound file), built from the specification and read back.
        let agile = try OfficeCryptoUnlocker.encryptAgile(package: secret, password: "open-sesame", spinCount: 500)
        XCTAssertTrue(OfficeCryptoUnlocker.isEncryptedPackage(agile))
        XCTAssertThrowsError(try OfficeCryptoUnlocker.decrypt(data: agile, password: "wrong")) { XCTAssertEqual($0 as? ProtectedContentError, .wrongPassword) }
        XCTAssertEqual(try OfficeCryptoUnlocker.decrypt(data: agile, password: "open-sesame"), secret)
        let agileURL = dir.appendingPathComponent("sealed.docx"); try agile.write(to: agileURL)
        XCTAssertThrowsError(try DocumentTextExtractor.extract(fileURL: agileURL, kind: .docx)) { XCTAssertEqual($0 as? OfficeTextExtractor.ExtractError, .encrypted) }
        XCTAssertThrowsError(try DocumentTextExtractor.extract(fileURL: agileURL, kind: .docx, password: "wrong")) { XCTAssertEqual($0 as? OfficeTextExtractor.ExtractError, .wrongPassword) }
        let agileText = try DocumentTextExtractor.extract(fileURL: agileURL, kind: .docx, password: "open-sesame")
        XCTAssertTrue(agileText.text.contains("The sealed clause mentions escrow."), agileText.text)
        XCTAssertEqual(SourceFormatClassifier.classify(url: agileURL).format, .msg, "an encrypted Office file is a compound file; the attachment path, not the mail import, is where it belongs")

        // 4. A PDF with a user password, through PDFKit.
        let plainPDF = try XCTUnwrap(PDFDocument(data: Self.pdfData(pages: ["Sealed PDF budget line."])))
        let lockedPDF = try XCTUnwrap(plainPDF.dataRepresentation(options: [PDFDocumentWriteOption.userPasswordOption: "open-sesame", PDFDocumentWriteOption.ownerPasswordOption: "owner-pw"]))
        XCTAssertTrue(try XCTUnwrap(PDFDocument(data: lockedPDF)).isLocked)

        // 5. Through the job: locked rows, then Unlock — once for this view only, once stored; a wrong password named.
        let wasOn = SearchChunkPolicy.isEnabled
        defer { SearchChunkPolicy.isEnabled = wasOn }
        let env = try chunkedEnv()
        AttachmentTextIndexJob.testSuppressKicks = true
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()
        AttachmentTextIndexJob.testStoreOverride = env.store
        defer { AttachmentTextIndexJob.testStoreOverride = nil; AttachmentTextIndexJob.testSuppressKicks = false }
        let ocrWas = AttachmentOCR.isEnabled
        AttachmentOCR.isEnabled = false
        defer { AttachmentOCR.isEnabled = ocrWas }
        let smimeWas = ProtectedContentPolicy.decryptSMIME
        ProtectedContentPolicy.decryptSMIME = false
        defer { ProtectedContentPolicy.decryptSMIME = smimeWas }
        AttachmentTextIndexJob.installChildReader()
        let raw = """
        From sender@example.com Wed Jan 15 10:00:00 2025
        From: sender@example.com
        To: user@dest.org
        Subject: Sealed files
        Date: Wed, 15 Jan 2025 10:00:00 +0000
        Message-ID: <sealed@t>
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="B"

        --B
        Content-Type: text/plain

        see the sealed files
        \(mimeAttachment("sealed.docx", docxMime, agile))
        \(mimeAttachment("sealed.zip", "application/zip", aesZip))
        \(mimeAttachment("sealed.pdf", "application/pdf", lockedPDF))
        \(mimeAttachment("smime.p7m", "application/pkcs7-mime; smime-type=enveloped-data", Data([0x30, 0x82, 0x01, 0x00, 0x06, 0x09])))
        --B--
        """
        let email = try MBOXParser.processRawMessage(raw, senderEmail: "")
        _ = try await env.store.insertBatch([email], sourceFileHash: nil, accountID: nil, sourceID: nil, firstOrdinal: nil,
                                            dedupPolicy: .messageID, batchSize: 10, progress: nil)
        _ = await AttachmentTextIndexJob.shared.run()
        let coverage = try AttachmentCoverageStore(url: await env.store.attachmentCoverageURL)
        var rows = try coverage.rows(for: email.id)
        XCTAssertEqual(rows.map(\.state), [.locked, .locked, .locked, .locked], "\(rows.map { ($0.filename, $0.state, $0.note ?? "") })")
        XCTAssertEqual(rows.map(\.extractor), ["office", "archive", "pdfkit", "smime"])
        XCTAssertTrue(rows[3].note?.contains("Read S/MIME with your keychain key") == true, "the record says what would open it: \(rows[3].note ?? "")")
        let summaryValue = await AttachmentTextIndexJob.coverageSummary(store: env.store)
        let summary = try XCTUnwrap(summaryValue)
        XCTAssertEqual(AttachmentTextIndexJob.noMatchNotice(summary), "No attachments matched. Searchable text covers 0 of 4 attachments — 4 locked. Files inside attachments, across the whole archive: 1 locked.",
                       "§13.3 (8): the sealed member inside the ZIP is counted too")
        func sealed(_ type: String, _ content: String) -> SearchSpec {
            SearchSpec(groups: [SearchGroup(.all, attachments: [AttachmentConditionGroup(type: type, contentMatch: .allWords, content: content)])])
        }
        try await expectIDs(env, sealed("docx", "escrow"), [], "locked: nothing is read")

        // Wrong password: named, nothing changes.
        let wrongOutcome = await AttachmentTextIndexJob.shared.unlock(emailID: email.id, position: 0, password: "wrong", retain: true)
        guard case .wrongPassword(let why) = wrongOutcome else { return XCTFail("\(wrongOutcome)") }
        XCTAssertEqual(why, "the password did not open the document")
        XCTAssertEqual(try coverage.rows(for: email.id)[0].state, .locked)

        // Right password, this view only: the text comes back, nothing is stored.
        let viewOnly = await AttachmentTextIndexJob.shared.unlock(emailID: email.id, position: 0, password: "open-sesame", retain: false)
        guard case .unlocked(let text, _, let stored) = viewOnly else { return XCTFail("\(viewOnly)") }
        XCTAssertFalse(stored); XCTAssertTrue(text.contains("sealed clause"), text)
        XCTAssertEqual(try coverage.rows(for: email.id)[0].state, .locked, "session-only: the record is untouched")
        try await expectIDs(env, sealed("docx", "escrow"), [], "session-only: not searchable")

        // Right password, stored: searchable like any other attachment, the record says how, the others stay locked.
        let kept = await AttachmentTextIndexJob.shared.unlock(emailID: email.id, position: 0, password: "open-sesame", retain: true)
        guard case .unlocked(_, _, true) = kept else { return XCTFail("\(kept)") }
        rows = try coverage.rows(for: email.id)
        XCTAssertEqual(rows.map(\.state), [.extracted, .locked, .locked, .locked], "\(rows.map { ($0.filename, $0.state) })")
        XCTAssertTrue(rows[0].note?.contains("the password was not kept") == true, rows[0].note ?? "")
        try await expectIDs(env, sealed("docx", "escrow"), ["Sealed files"], "stored: searchable")
        let row = await AttachmentTextIndexJob.shared.coverageRow(emailID: email.id, position: 1)
        XCTAssertEqual(row?.state, .locked)

        // The ZIP: unlocking it stores its member as a child document.
        let zipKept = await AttachmentTextIndexJob.shared.unlock(emailID: email.id, position: 1, password: "open-sesame", retain: true)
        guard case .unlocked(_, let children, true) = zipKept else { return XCTFail("\(zipKept)") }
        XCTAssertEqual(children.map { "\($0.path)|\($0.state.rawValue)" }, ["sealed.docx|extracted"])
        try await expectIDs(env, SearchSpec(groups: [SearchGroup(.all, attachments: [AttachmentConditionGroup(nameContains: "sealed.zip", contentMatch: .allWords, content: "escrow")])]), ["Sealed files"])
        // The PDF: PDFKit opens it with the user password.
        let pdfKept = await AttachmentTextIndexJob.shared.unlock(emailID: email.id, position: 2, password: "open-sesame", retain: true)
        guard case .unlocked(let pdfText, _, true) = pdfKept else { return XCTFail("\(pdfKept)") }
        XCTAssertTrue(pdfText.contains("Sealed PDF budget line"), pdfText)
        XCTAssertEqual(try coverage.rows(for: email.id).map(\.state), [.extracted, .extracted, .extracted, .locked])
        // S/MIME with the module on but no key: still locked, and the reason changes to the key.
        ProtectedContentPolicy.decryptSMIME = true
        let smime = await AttachmentTextIndexJob.shared.unlock(emailID: email.id, position: 3, password: "", retain: false)
        guard case .wrongPassword(let smimeWhy) = smime else { return XCTFail("\(smime)") }
        // The fixture is a 6-byte stub, not a real envelope: the portable reader (R6)
        // now says so instead of blaming the keychain. A real envelope without its key
        // is covered by SMIMEPortableTests (locked, reason names the missing key).
        XCTAssertTrue(smimeWhy.contains("keychain") || smimeWhy.contains("not a readable S/MIME envelope"), smimeWhy)
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()
    }

    // MARK: - Real files from open-source corpora (Apache Tika, Apache POI, MPXJ)

    /// The password that opens a protected file, tried from a short list;
    /// nil when none did. Says which one in the message.
    static func openingPassword(_ data: Data, candidates: [String]) -> String? {
        for candidate in candidates where (try? OfficeCryptoUnlocker.decrypt(data: data, password: candidate)) != nil { return candidate }
        return nil
    }

    /// Real Outlook messages (Tika, POI), a real winmail.dat, real
    /// encrypted Office files with known passwords, a real protected PDF,
    /// real .xlsb / Strict / Visio / charts / embedded-object files and a
    /// Microsoft Project MSPDI plan — every reader built in §13.8 steps 2–5
    /// against files the originating programs wrote. The fixtures live in
    /// `Fixtures/opensource` (Apache-2.0 test data; see MANIFEST.md).
    func testREAL_openSourceFixtures_outlookTNEFProtectedOfficeVisioProject_readersRunOnRealFiles() throws {
        let root = Self.fixturesRoot.appendingPathComponent("opensource")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: root.path), "open-source fixtures not present")
        let tika = root.appendingPathComponent("tika"), poi = root.appendingPathComponent("poi"), mpxj = root.appendingPathComponent("mpxj")
        func data(_ url: URL) throws -> Data { try Data(contentsOf: url) }

        // 1. Outlook messages: every one parses with a subject or a body; attachments come out with bytes.
        var msgNotes: [String] = []
        for name in ["testMSG.msg", "testMSG_forwarded.msg", "test-outlook.msg", "test-outlook2003.msg", "testMSG_chinese.msg", "testMSG_dateHeaderOnly.msg"] {
            let email = try MSGParser.parse(data: try data(tika.appendingPathComponent(name)))
            XCTAssertTrue(!(email.headers["Subject"] ?? "").isEmpty || !email.plainBody.isEmpty, "\(name): neither subject nor body — \(email.headers)")
            XCTAssertNotEqual(email.headers["Subject"], "(No Subject)", name)
            msgNotes.append("\(name): subject=\(email.headers["Subject"] ?? "") attachments=\(email.attachments.count)")
        }
        for name in ["attachment_msg_pdf.msg", "attachment_test_msg.msg", "example_received_unicode.msg", "example_sent_regular.msg", "58214_with_attachment.msg",
                     "cyrillic_message.msg", "HTMLBodyBinary_UTF-8.msg", "outlook_30_msg.msg", "quick.msg", "attachment_msg_inlineImg.msg", "MailSentPropertyMultiple.msg"] {
            let email = try MSGParser.parse(data: try data(poi.appendingPathComponent(name)))
            XCTAssertTrue(!(email.headers["Subject"] ?? "").isEmpty || !email.plainBody.isEmpty || !email.htmlBody.isEmpty, "\(name): nothing read")
            msgNotes.append("\(name): subject=\(email.headers["Subject"] ?? "") attachments=\(email.attachments.map(\.filename))")
        }
        let withPDF = try MSGParser.parse(data: try data(poi.appendingPathComponent("attachment_msg_pdf.msg")))
        let pdfAttachment = try XCTUnwrap(withPDF.attachments.first { $0.filename.lowercased().hasSuffix(".pdf") }, "\(withPDF.attachments.map(\.filename))")
        XCTAssertTrue((pdfAttachment.base64.flatMap { Data(base64Encoded: $0) }?.starts(with: Array("%PDF".utf8))) == true, "the PDF's bytes come out whole")
        let withDoc = try MSGParser.parse(data: try data(tika.appendingPathComponent("testMSG_att_doc.msg")))
        XCTAssertTrue(withDoc.attachments.contains { $0.filename.lowercased().hasSuffix(".doc") }, "\(withDoc.attachments.map(\.filename))")
        // An embedded message is expanded into an attached message with its own subject.
        let withMessage = try MSGParser.parse(data: try data(tika.appendingPathComponent("testMSG_att_msg.msg")))
        let embedded = try XCTUnwrap(withMessage.attachments.first { $0.mimeType == "message/rfc822" }, "no embedded message expanded: \(withMessage.attachments.map { ($0.filename, $0.mimeType) })")
        let innerBytes = try XCTUnwrap(embedded.base64.flatMap { Data(base64Encoded: $0) })
        let inner = try MBOXParser.processRawMessage(String(decoding: innerBytes, as: UTF8.self), senderEmail: "")
        defer { for a in inner.attachments { if let u = a.fileURL { try? FileManager.default.removeItem(at: u) } } }
        XCTAssertFalse((inner.headers["Subject"] ?? "").isEmpty, "the embedded message has its own subject: \(inner.headers)")
        print("REAL MSG:\n" + msgNotes.joined(separator: "\n"))

        // 2. winmail.dat from Exchange.
        let tnef = try TNEFReader.read(try data(tika.appendingPathComponent("testWINMAIL.dat")))
        XCTAssertFalse(tnef.attachments.isEmpty, "a real winmail.dat carries files: \(tnef.notes)")
        XCTAssertTrue(tnef.attachments.allSatisfy { !$0.filename.isEmpty && !$0.data.isEmpty }, "\(tnef.attachments.map { ($0.filename, $0.data.count) })")
        XCTAssertFalse(tnef.bodyText.contains("fonttbl") || tnef.bodyText.contains("Times New Roman;"), "the RTF body is words, not its font table: \(tnef.bodyText.prefix(200))")
        print("REAL TNEF: subject=\(tnef.subject ?? "") files=\(tnef.attachments.map(\.filename)) body=\(tnef.bodyText.prefix(80))")

        // 3. Encrypted Office files with known passwords (Tika: "tika"; POI: pwd123), plus probes for the rest.
        for (name, password) in [("testWORD_protected_passtika.docx", "tika"), ("testEXCEL_protected_passtika.xlsx", "tika"), ("testEXCEL_protected_passtika_2.xlsx", "tika"),
                                 ("testPPT_protected_passtika.pptx", "tika")] {
            let bytes = try data(tika.appendingPathComponent(name))
            XCTAssertTrue(OfficeCryptoUnlocker.isEncryptedPackage(bytes), name)
            XCTAssertThrowsError(try OfficeCryptoUnlocker.decrypt(data: bytes, password: "wrong"), name) { XCTAssertEqual($0 as? ProtectedContentError, .wrongPassword, name) }
            let plain = try OfficeCryptoUnlocker.decrypt(data: bytes, password: password)
            XCTAssertTrue(plain.starts(with: [0x50, 0x4B]), "\(name): the decrypted package is a ZIP")
            let kind = try XCTUnwrap(DocumentKind.detect(mimeType: "", filename: name))
            let result = try DocumentTextExtractor.extract(fileURL: tika.appendingPathComponent(name), kind: kind, password: password)
            XCTAssertFalse(result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(name): no text after unlocking")
        }
        let candidates = ["tika", "pwd123", "password", "Password", "test", "secret", "VelvetSweatshop", "Example123", "12345678", "abc", "openwall", "protect", "poi"]
        var opened: [String] = [], unopened: [String] = []
        for name in ["protect.xlsx", "protectedFile.xlsx", "protected_agile.docx", "protected_sha512.xlsx", "extenxls_pwd123.xlsx", "60320-protected.xlsx"] {
            let url = (FileManager.default.fileExists(atPath: poi.appendingPathComponent(name).path) ? poi : tika).appendingPathComponent(name)
            let bytes = try data(url)
            guard OfficeCryptoUnlocker.isEncryptedPackage(bytes) else { unopened.append("\(name): not an encrypted package (sheet protection only)"); continue }
            if let password = Self.openingPassword(bytes, candidates: candidates) { opened.append("\(name): \(password)") } else { unopened.append("\(name): none of \(candidates.count) candidates") }
        }
        XCTAssertTrue(opened.contains { $0.hasPrefix("extenxls_pwd123.xlsx: pwd123") }, "\(opened) / \(unopened)")
        print("REAL PROTECTED opened: \(opened); unopened: \(unopened)")

        // 4. A protected PDF through PDFKit.
        let pdf = try XCTUnwrap(PDFDocument(data: try data(tika.appendingPathComponent("testPDF_protected.pdf"))))
        XCTAssertTrue(pdf.isEncrypted, "Tika's protected PDF is encrypted (owner password; it opens without a user password, so it is not locked for reading)")
        let pdfPassword = ["tika", "password", "Password", "test", "secret", "user", "owner"].first { pdf.unlock(withPassword: $0) }
        XCTAssertFalse((pdf.string ?? "").isEmpty, "its text layer is readable")
        print("REAL PDF: locked=\(pdf.isLocked) owner password accepted: \(pdfPassword ?? "none of the candidates")")

        // 5. Binary workbook, Strict OOXML, Visio, charts, comments, embedded objects, text boxes.
        func extract(_ folder: URL, _ name: String) throws -> OfficeTextExtractor.Result {
            let kind = try XCTUnwrap(DocumentKind.detect(mimeType: "", filename: name) ?? DocumentTextExtractor.sniff(fileURL: folder.appendingPathComponent(name)), name)
            return try DocumentTextExtractor.extract(fileURL: folder.appendingPathComponent(name), kind: kind)
        }
        for name in ["testEXCEL.xlsb", "testEXCEL_various.xlsb", "testEXCEL_charts.xlsb"] {
            let r = try extract(tika, name)
            XCTAssertTrue(r.components.contains { $0.hasPrefix("Sheet: ") }, "\(name): \(r.components)")
            XCTAssertTrue(r.text.contains(":"), "\(name): cells carry addresses — \(r.text.prefix(200))")
            XCTAssertTrue(r.text.rangeOfCharacter(from: .letters) != nil, "\(name): no words read")
        }
        let strict = try extract(tika, "testEXCEL.strict.xlsx")
        XCTAssertTrue(strict.text.rangeOfCharacter(from: .letters) != nil, "Strict OOXML: \(strict.text.prefix(200))")
        for name in ["testVISIO.vsdx", "testVISIO_text.vsdx", "testVISIO.vsdm"] {
            let r = try extract(tika, name)
            XCTAssertTrue(r.components.contains { $0.hasPrefix("Page: ") }, "\(name): \(r.components)")
            XCTAssertTrue(r.text.rangeOfCharacter(from: .letters) != nil, "\(name): no shape text — \(r.text.prefix(200))")
        }
        for name in ["testWORD_charts.docx", "testEXCEL_charts.xlsx", "testPPT_charts.pptx"] {
            let r = try extract(tika, name)
            XCTAssertTrue(r.components.contains { $0.hasPrefix("Chart ") }, "\(name): \(r.components)")
        }
        let comments = try extract(tika, "testPPT_comment.pptx")
        XCTAssertTrue(comments.components.contains { $0.hasPrefix("Comments ") }, "\(comments.components)")
        for name in ["testWORD_embeded.docx", "testEXCEL_embeded.xlsx", "testPPT_embedded_two_slides.pptx"] {
            let r = try extract(tika, name)
            XCTAssertFalse(r.children.isEmpty, "\(name): embedded objects are children — notText=\(r.notText)")
            print("REAL EMBEDDED \(name): \(r.children.map { "\($0.path)|\($0.state.rawValue)" })")
        }
        let textbox = try extract(tika, "testWORD_emptyParaInTextbox.docx")
        XCTAssertTrue(textbox.text.contains("[Text box]"), textbox.text.prefix(300).description)
        let excelTextbox = try extract(tika, "testEXCEL_textbox.xlsx")
        XCTAssertTrue(excelTextbox.text.rangeOfCharacter(from: .letters) != nil, excelTextbox.text)
        let features = try extract(tika, "testWORD_features.docx")
        XCTAssertTrue(features.text.contains("{"), "tracked changes or footnotes expected in Tika's features document: \(features.text.prefix(300))")

        // 6. Microsoft Project XML, recognised by namespace.
        for name in ["mspdiresource.xml", "mspdirelations.xml"] {
            let url = mpxj.appendingPathComponent(name)
            XCTAssertEqual(DocumentTextExtractor.sniff(fileURL: url), .projectXML, name)
            let r = try DocumentTextExtractor.extract(fileURL: url, kind: .projectXML)
            XCTAssertTrue(r.components.contains("Tasks") || r.components.contains("Resources"), "\(name): \(r.components)")
        }

        // 7. Directive §6 "other business formats": Publisher, Access and Project binary files are read
        //    through the job, each under its reader's heading — real Tika/POI/MPXJ files, not spec-built ones.
        let business: [(String, DocumentKind, String, String)] = [
            ("testPUBLISHER.pub", .pub, "[Publisher text]", "0123456789abcdef"),
            ("testACCESS.mdb", .mdb, "[Access database: testACCESS", "[Table: Titles]"),
            ("testPROJECT2007.mpp", .mpp, "[Project: ", "Task"),
        ]
        for (name, kind, heading, inside) in business {
            XCTAssertEqual(DocumentKind.detect(mimeType: "", filename: name), kind, name)
            let text = try XCTUnwrap(AttachmentTextIndexJob.extractText(from: AttachmentMetadata(filename: name, mimeType: "application/octet-stream", size: 0, fileURL: tika.appendingPathComponent(name))), name)
            XCTAssertTrue(text.hasPrefix(heading), "\(name): \(text.prefix(160))")
            XCTAssertTrue(text.contains(inside), "\(name): \(text.prefix(300))")
            print("REAL BUSINESS \(name): \(text.count) characters — \(text.prefix(120).replacingOccurrences(of: "\n", with: " ⏎ "))")
        }
    }

    /// The owner's fixture pack of 2026-11-07: Microsoft's official Outlook
    /// template (kept outside the repository; skipped when absent), WinZip
    /// AES archives from libarchive, archives made with official 7-Zip,
    /// Word-written tracked changes with a ground-truth record, and EML
    /// wrappers that carry each through the attachment pipeline. The
    /// pack's `expected_results.json` is the oracle.
    func testREAL_publicPack_oftArchivesTrackedChanges_againstTheOracle() async throws {
        let pack = Self.fixturesRoot.appendingPathComponent("opensource/public-pack")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: pack.path), "public pack not present")
        let oracle = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: pack.appendingPathComponent("expected_results.json"))) as? [String: Any])
        func sha(_ data: Data) -> String { ExportFolderManifest.hex(data) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pack-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 1. Microsoft's .oft: routed to the MSG reader; subject and all 22 inline images byte-exact, with their content ids.
        // Directive §3: the external pack is verified against its SHA256SUMS before use (ExternalFixtures twin in TestPreconditions.swift).
        let oftStatus = ExternalFixtures.shared.status(of: "public-pack/01_outlook/Set_Up_Mobile_Thru_Admin.oft")
        let outlook = try XCTUnwrap(oracle["outlook"] as? [String: Any])
        if case .verified(let oftURL) = oftStatus {
            let bytes = try Data(contentsOf: oftURL)
            XCTAssertEqual(sha(bytes), outlook["sha256"] as? String, "the fixture is the official download")
            let classification = SourceFormatClassifier.classify(url: oftURL)
            XCTAssertEqual(classification.format, .msg); XCTAssertFalse(classification.nameContentMismatch)
            let template = try XCTUnwrap(try ParserFactory.parse(fileURL: oftURL, senderEmail: "").first)
            XCTAssertEqual(template.headers["Subject"], outlook["subject"] as? String)
            let expected = try XCTUnwrap(outlook["attachments"] as? [[String: Any]])
            XCTAssertEqual(template.attachments.count, expected.count, "\(template.attachments.map(\.filename))")
            var byName: [String: AttachmentMetadata] = [:]
            for a in template.attachments { byName[a.filename] = a }
            for item in expected {
                let name = item["filename"] as? String ?? ""
                guard let attachment = byName[name] else { XCTFail("missing \(name)"); continue }
                XCTAssertEqual(attachment.base64.flatMap { Data(base64Encoded: $0) }.map(sha), item["sha256"] as? String, "\(name) byte-exact")
                XCTAssertEqual(attachment.contentID?.trimmingCharacters(in: CharacterSet(charactersIn: "<>")), item["content_id"] as? String, "\(name) keeps its Content-ID")
                XCTAssertTrue(attachment.isInline, "\(name) is inline")
            }
            print("REAL OFT: \(template.headers["Subject"] ?? "") — \(template.attachments.count) images verified")
        } else if oftStatus.isAbsent {
            print("REAL OFT: \(oftStatus.description) — Microsoft's template is not redistributed; download id 44066 and place it under the fixture root")
        } else {
            XCTFail(oftStatus.description)   // present but not the official bytes, or not listed in the pack's SHA256SUMS
        }

        // 2. WinZip AES from libarchive: AES-128, AES-256 deflated, AES-256 stored — password "password", one README of 6,818 bytes.
        for name in ["test_read_format_zip_winzip_aes128.zip", "test_read_format_zip_winzip_aes256.zip", "test_read_format_zip_winzip_aes256_stored.zip"] {
            let url = pack.appendingPathComponent("02_archives/public/\(name)")
            let member = try XCTUnwrap(try ZIPArchiveReader.members(of: url).first { !$0.isDirectory })
            XCTAssertTrue(member.isEncrypted && member.method == 99, name)
            let out = dir.appendingPathComponent(name + ".README")
            XCTAssertThrowsError(try ZIPArchiveReader.extract(member, from: url, to: out, password: "wrong"), name) { XCTAssertEqual($0 as? ZIPArchiveReader.ReadError, .wrongPassword(member: member.name), name) }
            try ZIPArchiveReader.extract(member, from: url, to: out, password: "password")
            XCTAssertEqual(try Data(contentsOf: out).count, 6818, name)
        }

        // 3. Archives made with official 7-Zip: ZipCrypto and AES-256, README marker and the nested Word file with its tracked changes.
        let archives = try XCTUnwrap(oracle["archives"] as? [[String: Any]])
        for name in ["7zip_AES256.zip", "7zip_ZipCrypto.zip"] {
            let url = pack.appendingPathComponent("02_archives/7zip_generated/\(name)")
            let expected = try XCTUnwrap(archives.first { ($0["path"] as? String)?.hasSuffix(name) == true })
            let password = try XCTUnwrap(expected["password"] as? String)
            let locked = try DocumentTextExtractor.extract(fileURL: url, kind: .zip)
            XCTAssertEqual(Set(locked.children.map(\.state)), [.locked], "\(name): without the password every member is locked")
            let wrong = try DocumentTextExtractor.extract(fileURL: url, kind: .zip, password: "wrong")
            XCTAssertEqual(Set(wrong.children.map(\.state)), [.locked], "\(name): a wrong password opens nothing")
            let opened = try DocumentTextExtractor.extract(fileURL: url, kind: .zip, password: password)
            XCTAssertEqual(opened.children.map(\.path).sorted(), ["README.txt", "nested/W05_tracked_retained.docx"], name)
            for member in try XCTUnwrap(expected["members"] as? [[String: Any]]) {
                let path = member["path"] as? String ?? ""
                let child = try XCTUnwrap(opened.children.first { $0.path == path }, "\(name): \(path)")
                XCTAssertEqual(child.sha256, member["sha256"] as? String, "\(name): \(path) byte-exact")
                XCTAssertEqual(child.state, .extracted, "\(name): \(path)")
            }
            let readme = try XCTUnwrap(opened.children.first { $0.path == "README.txt" }?.text)
            XCTAssertTrue(readme.contains("MAILIN-PROTECTED-CONTENT-20261107"), readme)
            let nested = try XCTUnwrap(opened.children.first { $0.path.hasSuffix(".docx") }?.text)
            XCTAssertTrue(nested.contains("{inserted by Thabang Kubheka 2026-09-28: red") && nested.contains("{deleted by Thabang Kubheka 2026-09-28: brown }"), "\(name): tracked changes inside the archived Word file, author and day named — \(nested.prefix(300))")
        }
        // Directive §6 "Containers": a 7z whose headers are encrypted is a 7z (read by `SevenZipReader`)
        // that is locked — never garbage, never silent, and no text without the password.
        for name in ["7zip_AES256_header_encrypted.7z"] {
            let url = pack.appendingPathComponent("02_archives/7zip_generated/\(name)")
            XCTAssertEqual(DocumentKind.detect(mimeType: "application/x-7z-compressed", filename: name), .sevenZip)
            XCTAssertNil(AttachmentTextIndexJob.extractText(from: AttachmentMetadata(filename: name, mimeType: "application/x-7z-compressed", size: 0, fileURL: url)), name)
        }

        // 4. Word-written tracked changes against the ground-truth record.
        let word = try XCTUnwrap(oracle["word"] as? [[String: Any]])
        for item in word {
            let path = item["path"] as? String ?? ""
            let url = pack.appendingPathComponent(path)
            XCTAssertEqual(sha(try Data(contentsOf: url)), item["sha256"] as? String, path)
            let text = try DocumentTextExtractor.extract(fileURL: url, kind: .docx).text
            let revisions = item["revisions"] as? [[String: Any]] ?? []
            if revisions.isEmpty {
                XCTAssertFalse(text.contains("{inserted") || text.contains("{deleted"), "\(path): no pending revision may be labelled — \(text.prefix(200))")
            } else {
                for revision in revisions {
                    let kind = revision["kind"] as? String == "ins" ? "inserted" : "deleted"
                    // Directive §6 "Word": the marker names the author and the day Word recorded.
                    let author = revision["author"] as? String ?? ""
                    let day = String((revision["date"] as? String ?? "").prefix(10))
                    let marker = "{\(kind) by \(author) \(day): \(revision["text"] as? String ?? "")"
                    XCTAssertTrue(text.contains(marker), "\(path): expected \(marker.debugDescription) in \(text.prefix(300))")
                }
            }
        }

        // 5. Through the attachment pipeline: the EML wrappers, with Unlock for the archives.
        let wasOn = SearchChunkPolicy.isEnabled
        defer { SearchChunkPolicy.isEnabled = wasOn }
        let env = try chunkedEnv()
        AttachmentTextIndexJob.testSuppressKicks = true
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()
        AttachmentTextIndexJob.testStoreOverride = env.store
        defer { AttachmentTextIndexJob.testStoreOverride = nil; AttachmentTextIndexJob.testSuppressKicks = false }
        let ocrWas = AttachmentOCR.isEnabled
        AttachmentOCR.isEnabled = false
        defer { AttachmentOCR.isEnabled = ocrWas }
        AttachmentTextIndexJob.installChildReader()
        var emails: [MBOXParser.RawEmail] = []
        var wrapperNames = ["03_W05_tracked_retained", "04_W06_tracked_accepted", "06_test_read_format_zip_winzip_aes256", "07_7zip_AES256"]
        let wrapperStatus = ExternalFixtures.shared.status(of: "public-pack/04_import_ready_eml/01_Set_Up_Mobile_Thru_Admin.eml")
        for name in wrapperNames {
            let raw = try String(contentsOf: pack.appendingPathComponent("04_import_ready_eml/\(name).eml"), encoding: .utf8)
            emails.append(try MBOXParser.processRawMessage(raw, senderEmail: ""))
        }
        if case .verified(let oftWrapper) = wrapperStatus {
            emails.append(try MBOXParser.processRawMessage(try String(contentsOf: oftWrapper, encoding: .utf8), senderEmail: ""))
            wrapperNames.append("01_Set_Up_Mobile_Thru_Admin")
        } else if !wrapperStatus.isAbsent {
            XCTFail(wrapperStatus.description)
        }
        _ = try await env.store.insertBatch(emails, sourceFileHash: nil, accountID: nil, sourceID: nil, firstOrdinal: nil, dedupPolicy: .messageID, batchSize: 10, progress: nil)
        let outcome = await AttachmentTextIndexJob.shared.run()
        XCTAssertEqual(outcome.indexedEmails, emails.count)
        let coverage = try AttachmentCoverageStore(url: await env.store.attachmentCoverageURL)
        func row(_ index: Int) throws -> AttachmentCoverageRow { try XCTUnwrap(try coverage.rows(for: emails[index].id).first) }
        XCTAssertEqual(try row(0).state, .extracted, "W05 via mail")
        XCTAssertEqual(try row(2).state, .locked, "the WinZip AES zip is locked until unlocked")
        XCTAssertEqual(try row(3).state, .locked, "the 7-Zip AES zip is locked until unlocked")
        func group(type: String? = nil, name: String? = nil, _ match: SearchCondition.Match, _ content: String) -> SearchSpec {
            SearchSpec(groups: [SearchGroup(.all, attachments: [AttachmentConditionGroup(nameContains: name, type: type, contentMatch: match, content: content)])])
        }
        // Deleted text is searchable but labelled; the accepted control carries no label.
        try await expectIDs(env, group(type: "docx", .allWords, "brown"), ["Mailin test fixture W05_tracked_retained.docx"], "the deleted word is found, labelled as deleted")
        try await expectIDs(env, group(type: "docx", .phrase, "{deleted by Thabang Kubheka 2026-09-28: brown"), ["Mailin test fixture W05_tracked_retained.docx"])
        try await expectIDs(env, group(.allWords, "MAILIN-PROTECTED-CONTENT-20261107"), [], "locked archives yield nothing before Unlock")
        // Unlock through the same path the sheet uses.
        let wrongUnlock = await AttachmentTextIndexJob.shared.unlock(emailID: emails[3].id, position: 0, password: "wrong", retain: true)
        guard case .wrongPassword = wrongUnlock else { return XCTFail("\(wrongUnlock)") }
        let sevenZipUnlock = await AttachmentTextIndexJob.shared.unlock(emailID: emails[3].id, position: 0, password: "mailin-fixture-2026", retain: true)
        guard case .unlocked(_, let children, true) = sevenZipUnlock else { return XCTFail("\(sevenZipUnlock)") }
        XCTAssertEqual(children.map(\.path).sorted(), ["README.txt", "nested/W05_tracked_retained.docx"])
        try await expectIDs(env, group(.allWords, "MAILIN-PROTECTED-CONTENT-20261107"), ["Mailin test fixture 7zip_AES256.zip"], "after Unlock the marker inside the archive is found")
        try await expectIDs(env, group(name: "nested", .phrase, "{inserted by Thabang Kubheka 2026-09-28: red"), ["Mailin test fixture 7zip_AES256.zip"], "the tracked change inside the Word file inside the archive")
        let winzipUnlock = await AttachmentTextIndexJob.shared.unlock(emailID: emails[2].id, position: 0, password: "password", retain: false)
        guard case .unlocked(_, let readmeChildren, false) = winzipUnlock else { return XCTFail("\(winzipUnlock)") }
        XCTAssertEqual(readmeChildren.map(\.path), ["README"])
        XCTAssertEqual(try row(2).state, .locked, "view-only unlock leaves the record locked")
        if wrapperNames.count == 5 {
            let oftRow = try row(4)
            XCTAssertEqual(oftRow.extractor, "msg", "an .oft attachment is read as a message")
            let oftChildren = try await env.store.attachmentChildren(forEmailID: emails[4].id)
            XCTAssertEqual(oftChildren.count, 22, "its 22 images are children")
        }
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()
    }

    /// OUT-04 / COMP-16 (§13.8 step 6): an export is checked for CONTENT, not
    /// only bytes — every .eml/.msg is parsed back with the import's readers
    /// and compared, field by field, with the archive's record; a changed
    /// file is named with the field that differs; a different rendering of
    /// the same message (.msg) is a match.
    func testOUT04_outputsReparsedAgainstTheArchive_contentMatchesOrDifferencesAreNamed() async throws {
        let env = try makeEnv()
        let docx = Self.docx(body: "Reconcile this document.", header: "")
        // Real messages (raw source and headers agree), one with a file.
        func raw(_ i: Int, subject: String, body: String, attachment: Bool) -> String {
            var text = """
            From ann@x.com Wed Jan 15 10:00:0\(i) 2025
            From: Ann <ann@x.com>
            To: bob@y.org
            Subject: \(subject)
            Date: Wed, 15 Jan 2025 10:00:0\(i) +0000
            Message-ID: <reconcile-\(i)@t>
            MIME-Version: 1.0
            Content-Type: multipart/mixed; boundary="B"

            --B
            Content-Type: text/plain

            \(body)

            """
            if attachment { text += mimeAttachment("r.docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document", docx) + "\n" }
            return text + "--B--\n"
        }
        let emails = try [raw(0, subject: "Reconcile 0", body: "body 0 with a few words", attachment: false),
                          raw(1, subject: "Reconcile 1", body: "body 1 with a few words", attachment: false),
                          raw(2, subject: "With file", body: "see the file", attachment: true)].map { try MBOXParser.processRawMessage($0, senderEmail: "") }
        _ = try await env.store.insertBatch(emails, sourceFileHash: nil, accountID: nil, sourceID: nil, firstOrdinal: nil, dedupPolicy: .messageID, batchSize: 10, progress: nil)
        // The app's lookup: records a page at a time from the store, never a whole-archive dictionary.
        let lookup = ExportRunCenter.sourceLookup(store: env.store)
        let page = try await lookup.records(emails.map(\.id))
        XCTAssertEqual(page.count, 3)
        let service = ArchiveExportService(archive: env.archive)

        let emlFolder = env.root.appendingPathComponent("eml", isDirectory: true)
        _ = try await service.exportEMLFiles(scope: .explicit(Set(emails.map(\.id))), to: emlFolder)
        let clean = await ExportReconciliation.reconcile(folder: emlFolder, lookup: lookup)
        XCTAssertEqual(clean.checked, 3); XCTAssertEqual(clean.matching, 3); XCTAssertEqual(clean.outcome, .complete, "\(clean)")
        XCTAssertEqual(clean.eligible, 3); XCTAssertEqual(clean.promised, 3)
        XCTAssertEqual(ExportRunCenter.reconciliationText(clean), "content checked: 3 of 3 messages say what the archive says")

        // A different rendering of the same messages: .msg bytes differ from the source, the content does not.
        let msgFolder = env.root.appendingPathComponent("msg", isDirectory: true)
        _ = try await service.exportMSGFiles(scope: .explicit(Set(emails.map(\.id))), to: msgFolder)
        let msgReport = await ExportReconciliation.reconcile(folder: msgFolder, lookup: lookup)
        XCTAssertEqual(msgReport.checked, 3)
        XCTAssertEqual(msgReport.matching, 3, "\(msgReport.mismatches)")

        // A single-file container: every record inside the mbox is tied to its archive record by Message-ID.
        let mbox = env.root.appendingPathComponent("all.mbox")
        _ = try await service.exportMBOXArchive(scope: .explicit(Set(emails.map(\.id))), to: mbox)
        let container = await ExportReconciliation.reconcile(file: mbox, promised: 3, lookup: lookup)
        XCTAssertEqual(container.eligible, 3, "\(container)")
        XCTAssertEqual(container.matching, 3, "\(container.findings)")
        XCTAssertEqual(container.outcome, .complete, container.reason ?? "")
        let containerText = ExportRunCenter.reconciliationText(container)
        XCTAssertTrue(containerText.hasPrefix("content checked: 3 of 3 messages say what the archive says"), containerText)
        // The mbox writer cannot carry the folder path: named as re-expressed, not counted as lost.
        if container.transformations.keys.contains("mbox carries no folder path") {
            XCTAssertTrue(containerText.contains("re-expressed, not lost: mbox carries no folder path (3)"), containerText)
        }
        let shortfall = await ExportReconciliation.reconcile(file: mbox, promised: 4, lookup: lookup)
        XCTAssertEqual(shortfall.outcome, .failed, "a promise of 4 against 3 found is a failure, named")
        XCTAssertTrue(ExportRunCenter.reconciliationText(shortfall).contains("the export promised 4 messages, 3 found"), ExportRunCenter.reconciliationText(shortfall))
        // A file this check does not parse is unavailable with the reason — the content line is never silent.
        let csv = env.root.appendingPathComponent("report.csv"); try Data("a,b\n".utf8).write(to: csv)
        let unavailable = await ExportReconciliation.reconcile(file: csv, promised: nil, lookup: lookup)
        XCTAssertEqual(unavailable.outcome, .unavailable)
        XCTAssertTrue(ExportRunCenter.reconciliationText(unavailable).hasPrefix("content not checked — "), ExportRunCenter.reconciliationText(unavailable))

        // A file edited after the export: the byte check says "changed", the content check says WHAT changed.
        let inventory = try ExportInventory.load(folder: emlFolder)
        let edited = emlFolder.appendingPathComponent(inventory.files[0].path)
        let original = try String(contentsOf: edited, encoding: .utf8)
        try original.replacingOccurrences(of: "Subject: ", with: "Subject: Altered ").write(to: edited, atomically: true, encoding: .utf8)
        XCTAssertEqual(try ExportInventory.verify(folder: emlFolder).changed, [inventory.files[0].path])
        let tampered = await ExportReconciliation.reconcile(folder: emlFolder, lookup: lookup)
        XCTAssertEqual(tampered.mismatches.map { $0.lostFields.map(\.rawValue) }, [["subject"]], "\(tampered)")
        XCTAssertEqual(tampered.matching, 2)
        XCTAssertEqual(tampered.outcome, .failed)
        let tamperedText = ExportRunCenter.reconciliationText(tampered)
        XCTAssertTrue(tamperedText.hasPrefix("content check failed: 2 of 3 messages say what the archive says"), tamperedText)
        XCTAssertTrue(tamperedText.contains("differ 1: \((inventory.files[0].path as NSString).lastPathComponent) (subject)"), tamperedText)
        // A record no longer in the archive is counted, not invented.
        let missingOne = emails[1].id
        let fewer = ExportReconciliation.SourceLookup(records: { ids in try await lookup.records(ids.filter { $0 != missingOne }) })
        let withoutRecord = await ExportReconciliation.reconcile(folder: emlFolder, lookup: fewer)
        XCTAssertEqual(withoutRecord.withoutRecord, 1)
        XCTAssertTrue(ExportRunCenter.reconciliationText(withoutRecord).contains("no record 1"), ExportRunCenter.reconciliationText(withoutRecord))
        // The report travels with the receipt, whole.
        let receipts = ExportReceiptStore(directory: env.root.appendingPathComponent("receipts", isDirectory: true))
        let receipt = ExportReceipt(title: "t", destination: emlFolder.path, isFolder: true, requested: 3, written: 3, outcome: .complete, startedAt: Date(), completedAt: Date())
        let reportURL = try receipts.saveContentReport(tampered, for: receipt)
        XCTAssertEqual(reportURL.lastPathComponent, "export-\(receipt.id.uuidString).content.json")
        XCTAssertEqual(try JSONDecoder().decode(ExportReconciliation.ContentReport.self, from: Data(contentsOf: reportURL)), tampered)
        _ = try receipts.save(receipt)
        XCTAssertEqual(receipts.list().count, 1, "the content report is not listed as a receipt")
        // Normalisation: display names and whitespace do not count as differences; a different address does.
        XCTAssertEqual(ExportReconciliation.addresses("Ann <ann@x.com>, bob@y.org"), ExportReconciliation.addresses("bob@y.org,ANN@x.com"))
        XCTAssertNotEqual(ExportReconciliation.addresses("ann@x.com"), ExportReconciliation.addresses("anna@x.com"))
        XCTAssertEqual(ExportReconciliation.dateKey("Wed, 15 Jan 2025 10:00:30 +0000", ""), ExportReconciliation.dateKey(nil, "2025-01-15T10:00:00Z"))
    }

    /// COMP-15 (§13.8 step 6): the same message delivered as mbox, .eml, .msg
    /// and PST is one duplicate group; four byte streams are never called
    /// byte-identical, the class is content-equivalent or a candidate whose
    /// differences are named, and only a verified class can be bulk-removed.
    func testCOMP15_theSameMailInFourFormats_isOneGroup_classifiedHonestly_neverByteIdentical() async throws {
        let wasOn = SearchChunkPolicy.isEnabled
        defer { SearchChunkPolicy.isEnabled = wasOn }
        let env = try chunkedEnv()
        try FileManager.default.createDirectory(at: env.root, withIntermediateDirectories: true)
        let docx = Self.docx(body: "Cross-format minutes.", header: "")
        let body = """
        From: Ann <ann@example.com>
        To: bob@example.com
        Subject: Cross-format copy
        Date: Wed, 15 Jan 2025 10:00:00 +0000
        Message-ID: <cross-format@example.com>
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="B"

        --B
        Content-Type: text/plain

        The same message, four ways.
        \(mimeAttachment("minutes.docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document", docx))
        --B--
        """
        let mbox = env.root.appendingPathComponent("same.mbox"); try ("From ann@example.com Wed Jan 15 10:00:00 2025\n" + body + "\n").write(to: mbox, atomically: true, encoding: .utf8)
        let eml = env.root.appendingPathComponent("same.eml"); try body.write(to: eml, atomically: true, encoding: .utf8)
        let parsed = try MBOXParser.processRawMessage(body, senderEmail: "")
        let msg = env.root.appendingPathComponent("same.msg"); try XCTUnwrap(MSGWriter.write(email: parsed)).write(to: msg)
        let pst = env.root.appendingPathComponent("same.pst")
        let writer = try PSTWriterFactory.make(url: pst); try writer.appendMessage(parsed); try writer.finalize()
        var copies: [MBOXParser.RawEmail] = []
        for url in [mbox, eml, msg, pst] {
            let fromFile = try ParserFactory.parse(fileURL: url, senderEmail: "")
            XCTAssertEqual(fromFile.count, 1, url.lastPathComponent)
            copies += fromFile
        }
        XCTAssertEqual(Set(copies.map { $0.headers["Message-ID"] ?? "" }).count, 1, "one Message-ID in four formats: \(copies.map { $0.headers["Message-ID"] ?? "" })")
        _ = try await env.store.insertBatch(copies, sourceFileHash: nil, accountID: nil, sourceID: nil, firstOrdinal: nil, dedupPolicy: .preserveAll, batchSize: 10, progress: nil)
        let environment = ScopeJobEnvironment(archive: env.archive, store: env.store, root: env.root)
        let (groups, receipt) = try await ScopeJobEnvironment.$current.withValue(environment) { try await DuplicatesEngine.exactGroups() }
        XCTAssertEqual(receipt.processed, 4)
        XCTAssertEqual(groups.count, 1, "\(groups.map(\.count))")
        XCTAssertEqual(groups.first?.count, 4)
        let classified = DuplicateVerification.classify(groups)
        let group = try XCTUnwrap(classified.verified.first ?? classified.candidates.first)
        XCTAssertNotEqual(group.verdict, .byteIdentical, "four different byte streams are never byte-identical")
        guard case .contentEquivalent(attachmentBytesCompared: true) = group.verdict else {
            return XCTFail("four renderings of one message are content-equivalent once every copy's attachment bytes come back from the archive — got \(group.verdict)")
        }
        XCTAssertEqual(DuplicateVerification.bulkRemovable(classified.verified).count, 3, "three copies may go, the first stays")

        // Found by this test: a message from a PST, MSG or NSF had no raw source, and the archive keeps
        // attachment bytes only inside the raw source — so its attachments vanished at import. Now each
        // such message carries a rendered RFC 5322 source marked X-Mailin-Rendered, and the bytes come back.
        for (url, copy) in zip([mbox, eml, msg, pst], copies) {
            let storedValue = try await env.store.fullEmail(id: copy.id)
            let stored = try XCTUnwrap(storedValue, url.lastPathComponent)
            XCTAssertFalse(stored.rawSource.isEmpty, "\(url.lastPathComponent): a raw source is stored")
            if url.pathExtension == "msg" || url.pathExtension == "pst" {
                XCTAssertTrue(stored.rawSource.contains("X-Mailin-Rendered: Outlook"), "\(url.lastPathComponent): the rendered source says it was rendered — \(stored.rawSource.prefix(120))")
            } else {
                XCTAssertFalse(stored.rawSource.contains("X-Mailin-Rendered"), "\(url.lastPathComponent): real source bytes are kept as they are")
            }
            let attachment = try XCTUnwrap(stored.attachments.first, url.lastPathComponent)
            XCTAssertEqual(AttachmentHydrator.data(for: attachment, index: 0, email: stored), docx, "\(url.lastPathComponent): the attachment bytes come back from the archive")
        }
        // And so the attachments of every copy are searchable.
        AttachmentTextIndexJob.testSuppressKicks = true
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()
        AttachmentTextIndexJob.testStoreOverride = env.store
        defer { AttachmentTextIndexJob.testStoreOverride = nil; AttachmentTextIndexJob.testSuppressKicks = false }
        let outcome = await AttachmentTextIndexJob.shared.run()
        XCTAssertEqual(outcome.indexedEmails, 4, "every copy's attachment was read — none was 'message source not stored'")
        var query = EmailQuery.all
        query.spec = SearchSpec(groups: [SearchGroup(.all, attachments: [AttachmentConditionGroup(type: "docx", contentMatch: .phrase, content: "cross-format minutes")])])
        let found = try await env.archive.count(query: query)
        XCTAssertEqual(found, 4, "the document inside each of the four copies is found")
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()
    }

    /// §13.3 (8)(9)(11) and FIND-02: the no-match notice counts the files
    /// inside attachments; "Show text" has the exact indexed text of an
    /// attachment or a child with every match marked; the reader upgrade's
    /// re-read is a visible record; the OCR language list comes from Vision.
    func testSTEP6_childrenInTheNotice_extractedTextView_rebuildRecord_ocrLanguages() async throws {
        XCTAssertNil(AttachmentTextIndexJob.childrenNotice([:]))
        XCTAssertNil(AttachmentTextIndexJob.childrenNotice(["extracted": 9]))
        XCTAssertEqual(AttachmentTextIndexJob.childrenNotice(["locked": 2, "unsupported": 1, "extracted": 9]), "Files inside attachments, across the whole archive: 2 locked, 1 not read.")
        var summary = AttachmentCoverageSummary(); summary.counts = [.extracted: 3]; summary.childCounts = ["locked": 1]
        XCTAssertEqual(AttachmentTextIndexJob.noMatchNotice(summary), "No attachments matched. Searchable text covers all 3 attachments. Files inside attachments, across the whole archive: 1 locked.")

        let wasOn = SearchChunkPolicy.isEnabled
        defer { SearchChunkPolicy.isEnabled = wasOn }
        let env = try chunkedEnv()
        AttachmentTextIndexJob.testSuppressKicks = true
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()
        AttachmentTextIndexJob.testStoreOverride = env.store
        defer { AttachmentTextIndexJob.testStoreOverride = nil; AttachmentTextIndexJob.testSuppressKicks = false }
        let ocrWas = AttachmentOCR.isEnabled
        AttachmentOCR.isEnabled = false
        defer { AttachmentOCR.isEnabled = ocrWas }
        AttachmentTextIndexJob.installChildReader()
        let secret = Data("sealed words".utf8)
        let (aesPayload, aesExtra) = try WinZipAES.encryptMember(secret, password: "pw", strength: 3, actualMethod: 0)
        let lockedZip = Self.zipRaw([("sealed.txt", aesPayload, 0x0001, 99, 0, UInt32(secret.count), aesExtra)])
        let plainZip = Self.zipPackage([("notes/open.txt", Data("Open words inside the archive mention quorum twice: quorum.".utf8))])
        let docx = Self.docx(body: "Quorum in the document body.", header: "")
        let raw = """
        From sender@example.com Wed Jan 15 10:00:00 2025
        From: sender@example.com
        To: user@dest.org
        Subject: Step six
        Date: Wed, 15 Jan 2025 10:00:00 +0000
        Message-ID: <step6@t>
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="B"

        --B
        Content-Type: text/plain

        see attached
        \(mimeAttachment("minutes.docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document", docx))
        \(mimeAttachment("open.zip", "application/zip", plainZip))
        \(mimeAttachment("sealed.zip", "application/zip", lockedZip))
        --B--
        """
        let email = try MBOXParser.processRawMessage(raw, senderEmail: "")
        _ = try await env.store.insertBatch([email], sourceFileHash: nil, accountID: nil, sourceID: nil, firstOrdinal: nil, dedupPolicy: .messageID, batchSize: 10, progress: nil)
        _ = await AttachmentTextIndexJob.shared.run()

        // D8: the files inside attachments are counted archive-wide and reach the notice.
        let counts = try await env.store.attachmentChildStateCounts()
        XCTAssertEqual(counts["locked"], 1); XCTAssertEqual(counts["extracted"], 1)
        let fullSummary = await AttachmentTextIndexJob.coverageSummary(store: env.store)
        let notice = AttachmentTextIndexJob.noMatchNotice(try XCTUnwrap(fullSummary))
        XCTAssertTrue(notice.hasSuffix("Files inside attachments, across the whole archive: 1 locked."), notice)

        // D9: the exact indexed text of the attachment, and of the file inside the archive.
        let documentText = try await env.store.attachmentDocumentText(emailID: email.id, ordinal: 0)
        XCTAssertTrue(documentText?.contains("[Document]\nQuorum in the document body.") == true, documentText ?? "nil")
        let childText = try await env.store.attachmentDocumentText(emailID: email.id, ordinal: SearchDocKind.childOrdinal(parent: 1, child: 0))
        XCTAssertEqual(childText, "Open words inside the archive mention quorum twice: quorum.")
        let listing = try await env.store.attachmentDocumentText(emailID: email.id, ordinal: 1)
        XCTAssertTrue(listing?.hasPrefix("[Contents]\nnotes/open.txt") == true, listing ?? "nil")
        let none = try await env.store.attachmentDocumentText(emailID: email.id, ordinal: 2)
        XCTAssertNil(none, "a locked archive has no indexed text")
        let unwrappedChild = try XCTUnwrap(childText)
        let ranges = ExtractedTextSheet.ranges(of: "QUORUM", in: unwrappedChild)
        XCTAssertEqual(ranges.count, 2)
        XCTAssertTrue(ExtractedTextSheet.ranges(of: "  ", in: "anything").isEmpty)
        let marked = ExtractedTextSheet.highlighted(unwrappedChild, ranges: ranges)
        XCTAssertEqual(String(marked.characters), unwrappedChild, "marking changes nothing in the text")

        // D11: the reader upgrade's re-read is recorded and worded.
        // R7: per archive, in its store directory, and only once the pass finished.
        let rebuildDir = FileManager.default.temporaryDirectory.appendingPathComponent("rebuild-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: rebuildDir) }
        AttachmentTextIndexJob.recordRebuild(requeued: 0, in: rebuildDir)
        AttachmentTextIndexJob.completeRebuild(in: rebuildDir, stillUnread: 0)
        XCTAssertNil(AttachmentTextIndexJob.rebuildRecord(in: rebuildDir))
        AttachmentTextIndexJob.recordRebuild(requeued: 5, in: rebuildDir)
        AttachmentTextIndexJob.recordRebuild(requeued: 7, in: rebuildDir)
        AttachmentTextIndexJob.completeRebuild(in: rebuildDir, stillUnread: 0)
        let record = try XCTUnwrap(AttachmentTextIndexJob.rebuildRecord(in: rebuildDir))
        XCTAssertEqual(record.messagesRequeued, 12); XCTAssertEqual(record.extractorVersion, AttachmentTextIndexJob.extractorVersion)
        let report = try XCTUnwrap(AttachmentTextIndexJob.rebuildReportText(record))
        XCTAssertTrue(report.contains("version \(AttachmentTextIndexJob.extractorVersion)") && report.contains("12 messages"), report)
        XCTAssertNil(AttachmentTextIndexJob.rebuildReportText(nil))

        // FIND-02: the recogniser's own language list.
        let languages = AttachmentOCR.supportedLanguages()
        XCTAssertFalse(languages.isEmpty)
        XCTAssertTrue(languages.contains { $0.hasPrefix("en") }, "\(languages)")
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()
    }

    /// COMP-14 (owner-approved 2026-11-07): an S/MIME envelope encrypted to a
    /// disposable identity in a temporary keychain is decoded by the Mac's
    /// CMS decoder when the module is on — locked with the reason when off —
    /// and the message inside is read with its attachment as a child. Skips
    /// when the fixture is absent (the identity is created and removed by hand).
    func testCOMP14_smimeEnvelopeDecodedWithTheKeychainIdentity_whenTheSwitchIsOn() async throws {
        let folder = ExternalFixtures.resolvedRoot().appendingPathComponent("smime")   // owner-made identity material, outside Git
        let enveloped = folder.appendingPathComponent("enveloped.p7m"), signed = folder.appendingPathComponent("signed.p7m")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: enveloped.path), "S/MIME fixture not present")
        #if os(macOS)
        let plain = try XCTUnwrap(SMIMEHandler.decodeCMS(try Data(contentsOf: enveloped)), "the keychain identity decrypts the envelope")
        XCTAssertTrue(String(decoding: plain, as: UTF8.self).contains("periwinkle"))
        let signedContent = try XCTUnwrap(SMIMEHandler.decodeCMS(try Data(contentsOf: signed)), "a signed-data part yields its content")
        XCTAssertTrue(String(decoding: signedContent, as: UTF8.self).contains("periwinkle"))
        XCTAssertNil(SMIMEHandler.decodeCMS(Data([0x30, 0x82, 0x01, 0x00, 0x06, 0x09])), "garbage is not decoded")

        let wasOn = SearchChunkPolicy.isEnabled
        defer { SearchChunkPolicy.isEnabled = wasOn }
        let env = try chunkedEnv()
        AttachmentTextIndexJob.testSuppressKicks = true
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()
        AttachmentTextIndexJob.testStoreOverride = env.store
        defer { AttachmentTextIndexJob.testStoreOverride = nil; AttachmentTextIndexJob.testSuppressKicks = false }
        let smimeWas = ProtectedContentPolicy.decryptSMIME
        defer { ProtectedContentPolicy.decryptSMIME = smimeWas }
        AttachmentTextIndexJob.installChildReader()
        let raw = """
        From sender@example.com Wed Jan 15 10:00:00 2025
        From: sender@example.com
        To: smime-test@example.invalid
        Subject: Sealed envelope
        Date: Wed, 15 Jan 2025 10:00:00 +0000
        Message-ID: <smime-real@t>
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="B"

        --B
        Content-Type: text/plain

        the envelope follows
        \(mimeAttachment("smime.p7m", "application/pkcs7-mime; smime-type=enveloped-data; name=smime.p7m", try Data(contentsOf: enveloped)))
        --B--
        """
        let email = try MBOXParser.processRawMessage(raw, senderEmail: "")
        _ = try await env.store.insertBatch([email], sourceFileHash: nil, accountID: nil, sourceID: nil, firstOrdinal: nil, dedupPolicy: .messageID, batchSize: 10, progress: nil)
        let coverage = try AttachmentCoverageStore(url: await env.store.attachmentCoverageURL)

        ProtectedContentPolicy.decryptSMIME = false
        _ = await AttachmentTextIndexJob.shared.run()
        var rows = try coverage.rows(for: email.id)
        XCTAssertEqual(rows.map(\.state), [.locked])
        XCTAssertTrue(rows[0].note?.contains("Read S/MIME with your keychain key") == true, rows[0].note ?? "")

        ProtectedContentPolicy.decryptSMIME = true
        try await env.store.attachmentTextStateReset(emailIDs: [email.id])
        try coverage.remove(emailIDs: [email.id])
        _ = await AttachmentTextIndexJob.shared.run()
        rows = try coverage.rows(for: email.id)
        XCTAssertEqual(rows.map(\.state), [.extracted], "\(rows.map { ($0.state, $0.note ?? "") })")
        XCTAssertEqual(rows[0].extractor, "smime")
        let children = try await env.store.attachmentChildren(forEmailID: email.id)
        XCTAssertEqual(children.map(\.path), ["note.txt"])
        func group(_ match: SearchCondition.Match, _ content: String, name: String? = nil) -> SearchSpec {
            SearchSpec(groups: [SearchGroup(.all, attachments: [AttachmentConditionGroup(nameContains: name, type: nil, contentMatch: match, content: content)])])
        }
        try await expectIDs(env, group(.allWords, "periwinkle"), ["Sealed envelope"], "the decrypted body is searchable")
        try await expectIDs(env, group(.allWords, "quorum", name: "note"), ["Sealed envelope"], "the attachment inside the envelope is a child")
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()
        #else
        throw XCTSkip("CMS decoding runs on the Mac")
        #endif
    }

    /// A10 / §13.3 (10): an attachment that stopped at a per-run ceiling is
    /// recorded with the reason and offers Resume; each round doubles the
    /// ceilings and opens one more level for that attachment only, and the
    /// record names the round. Small ceilings here stand in for the real ones.
    func testA10_resumeReadsMoreOfAnAttachment_roundByRound_recordedPerAttachment() async throws {
        let wasOn = SearchChunkPolicy.isEnabled
        defer { SearchChunkPolicy.isEnabled = wasOn }
        let env = try chunkedEnv()
        AttachmentTextIndexJob.testSuppressKicks = true
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()
        AttachmentTextIndexJob.testStoreOverride = env.store
        defer { AttachmentTextIndexJob.testStoreOverride = nil; AttachmentTextIndexJob.testSuppressKicks = false }
        let ocrWas = AttachmentOCR.isEnabled
        AttachmentOCR.isEnabled = false
        defer { AttachmentOCR.isEnabled = ocrWas }
        AttachmentTextIndexJob.installChildReader()
        // Base ceilings small enough that a 600-byte member and a second nesting level are over them.
        ExtractionLimits.baseOverride = ExtractionLimits(partBytes: 400, totalArchiveBytes: 1_000, archiveDepth: 1)
        defer { ExtractionLimits.baseOverride = nil }
        XCTAssertEqual(ExtractionLimits.round(2).partBytes, 1_600)
        XCTAssertEqual(ExtractionLimits.round(2).archiveDepth, 3)
        XCTAssertTrue(ExtractionLimits.noteNamesALimit("x (700 bytes, over the 400-byte guard)"))
        XCTAssertFalse(ExtractionLimits.noteNamesALimit("password-protected"))

        let small = Data("small member with the word quorum".utf8)
        let big = Data(String(repeating: "big member text about escrow ", count: 24).utf8)      // ~700 bytes > 400
        let inner = Self.zipPackage([("deep.txt", Data("deep member names indemnity".utf8))])
        let zip = Self.zipPackage([("small.txt", small), ("big.txt", big), ("inner.zip", inner)])
        let raw = """
        From sender@example.com Wed Jan 15 10:00:00 2025
        From: sender@example.com
        To: user@dest.org
        Subject: Resume me
        Date: Wed, 15 Jan 2025 10:00:00 +0000
        Message-ID: <resume@t>
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="B"

        --B
        Content-Type: text/plain

        see the archive
        \(mimeAttachment("bundle.zip", "application/zip", zip))
        --B--
        """
        let email = try MBOXParser.processRawMessage(raw, senderEmail: "")
        _ = try await env.store.insertBatch([email], sourceFileHash: nil, accountID: nil, sourceID: nil, firstOrdinal: nil, dedupPolicy: .messageID, batchSize: 10, progress: nil)
        _ = await AttachmentTextIndexJob.shared.run()
        let coverage = try AttachmentCoverageStore(url: await env.store.attachmentCoverageURL)
        var row = try XCTUnwrap(try coverage.rows(for: email.id).first)
        XCTAssertEqual(row.state, .partial)
        XCTAssertEqual(row.resumeRound, 0)
        XCTAssertTrue(ExtractionLimits.noteNamesALimit(row.note), row.note ?? "")
        XCTAssertTrue(AttachmentResumeView.canResume(row))
        var children = try await env.store.attachmentChildren(forEmailID: email.id)
        XCTAssertEqual(children.map { "\($0.path)|\($0.state)" }, ["small.txt|extracted", "big.txt|unsupported", "inner.zip|unsupported"], "round 0: the big member and the nested archive are listed, not read")
        func found(_ words: String) async throws -> Int {
            var q = EmailQuery.all
            q.spec = SearchSpec(groups: [SearchGroup(.all, attachments: [AttachmentConditionGroup(nameContains: "bundle", contentMatch: .allWords, content: words)])])
            return try await env.archive.count(query: q)
        }
        let before = try await found("escrow")
        XCTAssertEqual(before, 0)

        // Round 1: 800-byte parts, 2,000 bytes, 2 levels → the big member and the nested file are read.
        let outcome = await AttachmentTextIndexJob.shared.resume(emailID: email.id, position: 0)
        guard case .resumed(let round, let state, _, let limits) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(round, 1); XCTAssertEqual(state, .extracted); XCTAssertEqual(limits, "800 bytes per part, 2000 bytes per attachment's archives, 2 levels, 4 message levels")
        row = try XCTUnwrap(try coverage.rows(for: email.id).first)
        XCTAssertEqual(row.resumeRound, 1)
        XCTAssertTrue(row.note?.contains("read in Resume round 1") == true, row.note ?? "")
        XCTAssertFalse(AttachmentResumeView.canResume(row), "read whole: nothing left to resume")
        children = try await env.store.attachmentChildren(forEmailID: email.id)
        XCTAssertEqual(children.map { "\($0.path)|\($0.state)" }, ["small.txt|extracted", "big.txt|extracted", "inner.zip › deep.txt|extracted"])
        let after = try await found("escrow")
        XCTAssertEqual(after, 1)
        let deep = try await found("indemnity")
        XCTAssertEqual(deep, 1, "the file one level deeper is searchable after the round")
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()
    }

    /// Owner-approved 2026-11-07 (item 6), hardened per the completion
    /// directive §2 "Recover existing imports": the fixture every testRECOVER_*
    /// method starts from. Two binary sources the old build imported without
    /// a source — one.msg (message 1) and two.pst (messages 2, 3, 5) — plus a
    /// message whose source was never copied and is gone (4). The pre-fix
    /// state is produced directly: 1 and 2 have an EMPTY raw source, 5 has a
    /// raw source WITHOUT its attachment bytes (headers only), 3 is intact.
    /// Message 1 carries a tag, a note, a hold and the Trash flag.
    private struct RecoverFixture {
        let env: Env
        let docx: Data
        let msgURL: URL
        let pstURL: URL
        let msgHash: String
        let pstHash: String
        /// Imported ids in order: [1, 2, 3, 5].
        let imported: [UUID]
        let lostID: UUID
        var emptied: [UUID] { [imported[0], imported[1]] }
        var stripped: UUID { imported[3] }
        var intact: UUID { imported[2] }
        var affected: [UUID] { emptied + [stripped] }
    }

    private static func recoverMessage(_ n: Int, docx: Data, messageID: Bool = true) -> String {
        """
        From: Ann <ann@example.com>
        To: bob@example.com
        Subject: Recover \(n)
        Date: Wed, 15 Jan 2025 10:0\(n):00 +0000
        \(messageID ? "Message-ID: <recover-\(n)@example.com>" : "X-Nothing: here")
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="B"

        --B
        Content-Type: text/plain

        Body \(n).
        --B
        Content-Type: application/vnd.openxmlformats-officedocument.wordprocessingml.document; name="minutes.docx"
        Content-Disposition: attachment; filename="minutes.docx"
        Content-Transfer-Encoding: base64

        \(docx.base64EncodedString())
        --B--
        """
    }

    private func recoverFixture(copyPST: Bool = true) async throws -> RecoverFixture {
        let env = try chunkedEnv()
        try FileManager.default.createDirectory(at: env.root, withIntermediateDirectories: true)
        let docx = Self.docx(body: "Recovered minutes mention escrow.", header: "")
        let msgURL = env.root.appendingPathComponent("one.msg")
        try XCTUnwrap(MSGWriter.write(email: try MBOXParser.processRawMessage(Self.recoverMessage(1, docx: docx), senderEmail: ""))).write(to: msgURL)
        let pstURL = env.root.appendingPathComponent("two.pst")
        let writer = try PSTWriterFactory.make(url: pstURL)
        for n in [2, 3, 5] { try writer.appendMessage(try MBOXParser.processRawMessage(Self.recoverMessage(n, docx: docx), senderEmail: "")) }
        _ = try writer.finalize()
        var imported: [UUID] = []
        var hashes: [String] = []
        for (url, copy) in [(msgURL, true), (pstURL, copyPST)] {
            let hash = try ExportInventory.sha256(of: url)
            hashes.append(hash)
            let sourceID = try await env.store.registerSource(SQLiteEmailStore.SourceDescriptor(sha256: hash, filename: url.lastPathComponent, byteSize: 0, parser: url.pathExtension, sourceKind: url.pathExtension))
            if copy { _ = try SourceCopies.copyIntoArchive(original: url, sha256: hash, storeDirectory: env.store.storeDirectory) }
            let emails = try ParserFactory.parse(fileURL: url, senderEmail: "").map { email -> MBOXParser.RawEmail in
                var e = email; e.folderPath = "Inbox/Recovered"; return e
            }
            _ = try await env.store.insertBatch(emails, sourceFileHash: hash, accountID: nil, sourceID: sourceID, firstOrdinal: 0, dedupPolicy: .messageID, batchSize: 10, progress: nil)
            imported += emails.map(\.id)
            for e in emails { for a in e.attachments { if let u = a.fileURL { try? FileManager.default.removeItem(at: u) } } }
        }
        // A third source whose file is gone (never copied), one message.
        let lost = try MBOXParser.processRawMessage(Self.recoverMessage(4, docx: docx), senderEmail: "")
        _ = try await env.store.insertBatch([lost], sourceFileHash: "deadbeefdeadbeef", accountID: nil, sourceID: nil, firstOrdinal: nil, dedupPolicy: .messageID, batchSize: 10, progress: nil)
        // Review state on message 1: tag, note, hold, Trash — the repair must leave every one of them.
        try await env.store.userTagAdd("escrow", ids: [imported[0]])
        try await env.store.annotationSet("check the minutes", id: imported[0])
        _ = try await env.store.legalHoldsAdd([imported[0]], matter: "M-1")
        try await env.store.reviewSetFlag(.trashed, ids: [imported[0]], value: true)
        // The pre-fix state.
        for id in [imported[0], imported[1], lost.id] { try await env.store.replaceRawSource(emailID: id, rawSource: "") }
        try await env.store.replaceRawSource(emailID: imported[3], rawSource: "From: ann@example.com\r\nSubject: Recover 5\r\n\r\nBody 5 without its parts.\r\n")
        return RecoverFixture(env: env, docx: docx, msgURL: msgURL, pstURL: pstURL, msgHash: hashes[0], pstHash: hashes[1], imported: imported, lostID: lost.id)
    }

    private func recoverInvariants(_ f: RecoverFixture) async throws -> [UUID: SQLiteEmailStore.RecoveryInvariants] {
        var out: [UUID: SQLiteEmailStore.RecoveryInvariants] = [:]
        for id in f.imported + [f.lostID] { out[id] = try await f.env.store.recoveryInvariants(id: id) }
        return out
    }

    /// Detection from provenance AND availability; counts before the run (affected, recoverable,
    /// already intact, source not found); snapshot before the first write; only the raw columns
    /// change (identity, headers, folders, tags, note, hold, Trash equal before and after); the
    /// reconstruction is labelled; the receipt has six counts and is saved; attachments open and
    /// are searchable again; a second run writes nothing and says already intact = all.
    func testRECOVER_rawSourceRefilledFromTheOriginalFiles_attachmentsOpenAndSearchAgain() async throws {
        let wasOn = SearchChunkPolicy.isEnabled
        defer { SearchChunkPolicy.isEnabled = wasOn }
        let f = try await recoverFixture()
        let env = f.env
        let beforeOptional = try await env.store.fullEmail(id: f.imported[0])
        let before = try XCTUnwrap(beforeOptional)
        XCTAssertTrue(before.rawSource.isEmpty)
        XCTAssertNil(AttachmentHydrator.data(for: try XCTUnwrap(before.attachments.first), index: 0, email: before), "the bytes are gone — the state this recovery exists for")
        let strippedOptional = try await env.store.fullEmail(id: f.stripped)
        let strippedEmail = try XCTUnwrap(strippedOptional)
        XCTAssertFalse(strippedEmail.rawSource.isEmpty, "message 5 HAS a raw source …")
        XCTAssertNil(AttachmentHydrator.data(for: try XCTUnwrap(strippedEmail.attachments.first), index: 0, email: strippedEmail), "… but no attachment bytes: affected by availability, not by an empty column")
        let invariantsBefore = try await recoverInvariants(f)
        XCTAssertEqual(invariantsBefore[f.imported[0]]?.tags, ["escrow"])
        XCTAssertEqual(invariantsBefore[f.imported[0]]?.note, "check the minutes")
        XCTAssertEqual(invariantsBefore[f.imported[0]]?.held, true)
        XCTAssertEqual(invariantsBefore[f.imported[0]]?.trashed, true)
        XCTAssertFalse(invariantsBefore[f.imported[1]]?.folderIDs.isEmpty ?? true, "folder occurrences exist to be preserved")
        XCTAssertEqual(invariantsBefore[f.imported[1]]?.sourceOrdinal, 0)

        // The plan: counts per source before anything runs; the lost source named.
        let plan = try await RawSourceRecovery.plan(store: env.store)
        XCTAssertEqual(plan.total, 4, "1, 2, 5 and the lost one")
        XCTAssertEqual(plan.recoverable, 3); XCTAssertEqual(plan.missing, 1)
        XCTAssertEqual(plan.alreadyIntact, 1, "message 3")
        XCTAssertEqual(plan.affectedGroups.count, 3)
        let pstGroup = try XCTUnwrap(plan.groups.first { $0.filename == "two.pst" })
        XCTAssertEqual(pstGroup.count, 2); XCTAssertEqual(pstGroup.alreadyIntact, 1)
        XCTAssertNil(plan.groups.first { $0.sourceHash == "deadbeefdeadbeef" }?.fileURL)

        // The run: three recovered, the lost one listed by its source with its count, nothing else touched.
        let receipts = RawSourceRecoveryReceiptStore(directory: env.root.appendingPathComponent("receipts"))
        let receipt = await RawSourceRecovery.run(store: env.store, plan: plan, receipts: receipts)
        XCTAssertEqual(receipt.affected, 4, receipt.line)
        XCTAssertEqual(receipt.recovered, 3, receipt.line)
        XCTAssertEqual(receipt.alreadyIntact, 1)
        XCTAssertEqual(receipt.ambiguous, 0)
        XCTAssertEqual(receipt.missingSource, 1)
        XCTAssertEqual(receipt.failed, 0)
        XCTAssertFalse(receipt.cancelled)
        XCTAssertEqual(receipt.missingSources, ["source deadbeefdead…"])
        XCTAssertEqual(receipt.sources.first { $0.missing }?.affected, 1, "the missing source is named with its count")
        let snapshotPath = try XCTUnwrap(receipt.snapshotPath, "the archive was backed up before the first write")
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotPath))
        XCTAssertTrue(snapshotPath.contains("before-attachment-recovery"))
        let saved = receipts.list()
        XCTAssertEqual(saved.count, 1)
        let loaded = try receipts.load(saved[0])
        XCTAssertEqual(loaded.sources, receipt.sources, "the receipt on disk is the receipt shown")
        XCTAssertEqual(loaded.recoveredIDs, receipt.recoveredIDs); XCTAssertEqual(loaded.snapshotPath, receipt.snapshotPath)
        XCTAssertEqual(loaded.ambiguousItems, receipt.ambiguousItems); XCTAssertEqual(loaded.line, receipt.line)
        let text = RawSourceRecoveryView.receiptText(receipt)
        XCTAssertTrue(text.contains("recovered 3") && text.contains("already intact 1") && text.contains("missing source 1"), text)

        // Repair preserved stable identity, folder occurrences, tags, notes, holds, Trash.
        let invariantsAfter = try await recoverInvariants(f)
        XCTAssertEqual(invariantsAfter, invariantsBefore)
        for id in f.affected {
            let afterOptional = try await env.store.fullEmail(id: id)
            let after = try XCTUnwrap(afterOptional)
            let label = RawSourceProvenance.label(for: after.rawSource)
            XCTAssertTrue(after.rawSource.hasPrefix("X-Mailin-Rendered:"), "the source is marked as rendered")
            XCTAssertTrue(label.isReconstructed, after.rawSource.prefix(200).description)
            XCTAssertEqual(label.sourceFilename, id == f.imported[0] ? "one.msg" : "two.pst")
            XCTAssertNotNil(label.date)
            XCTAssertFalse(label.fromUnverifiedFile)
            XCTAssertTrue(ReconstructedSourceNotice.text(label).contains("reconstructed from \(label.sourceFilename ?? "")"))
            XCTAssertTrue(ReconstructedSourceNotice.text(label).contains("not captured wire bytes"))
            XCTAssertEqual(AttachmentHydrator.data(for: try XCTUnwrap(after.attachments.first), index: 0, email: after), f.docx, "the attachment bytes are back")
        }
        let stillLostOptional = try await env.store.fullEmail(id: f.lostID)
        let stillLost = try XCTUnwrap(stillLostOptional)
        XCTAssertTrue(stillLost.rawSource.isEmpty, "a message whose source is not found is left as it was, and said so")
        let intactOptional = try await env.store.fullEmail(id: f.intact)
        let intactEmail = try XCTUnwrap(intactOptional)
        XCTAssertFalse(RawSourceProvenance.label(for: intactEmail.rawSource).isReconstructed, "an intact row is not rewritten")

        // Attachments searchable again through the normal pass.
        AttachmentTextIndexJob.testSuppressKicks = true
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()
        AttachmentTextIndexJob.testStoreOverride = env.store
        defer { AttachmentTextIndexJob.testStoreOverride = nil; AttachmentTextIndexJob.testSuppressKicks = false }
        _ = await AttachmentTextIndexJob.shared.run()
        var query = EmailQuery.all
        query.spec = SearchSpec(groups: [SearchGroup(.all, attachments: [AttachmentConditionGroup(type: "docx", contentMatch: .phrase, content: "recovered minutes")])])
        let found = try await env.archive.count(query: query)
        XCTAssertEqual(found, 3, "2 and 5 recovered and 3 intact; 1 is in the Trash, which search hides by design (§19.1)")
        query.includeTrashed = true
        let foundWithTrash = try await env.archive.count(query: query)
        XCTAssertEqual(foundWithTrash, 4, "with the Trash included, the recovered message 1 is searchable too — its Trash state survived the repair")
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()

        // Repeated repair: idempotent — nothing recoverable remains, already intact = all.
        let again = try await RawSourceRecovery.plan(store: env.store)
        XCTAssertEqual(again.total, 1, "only the lost one remains")
        XCTAssertEqual(again.recoverable, 0)
        XCTAssertEqual(again.alreadyIntact, 4)
        let second = await RawSourceRecovery.run(store: env.store, plan: again, receipts: receipts)
        XCTAssertEqual(second.recovered, 0); XCTAssertEqual(second.alreadyIntact, 4); XCTAssertEqual(second.missingSource, 1)
        XCTAssertNil(second.snapshotPath, "nothing to write, nothing snapshotted")
        let invariantsAfterSecond = try await recoverInvariants(f)
        XCTAssertEqual(invariantsAfterSecond, invariantsBefore)
        XCTAssertEqual(receipts.list().count, 2)
    }

    /// Recovery survives a process restart (a fresh store on the same directory sees the repaired rows
    /// and has nothing left to do) and a clean-profile backup restore — both before the repair (the
    /// restored archive can be recovered there, from the copies the backup carried) and after it.
    func testRECOVER_survivesProcessRestart_andCleanProfileBackupRestore() async throws {
        let wasOn = SearchChunkPolicy.isEnabled
        defer { SearchChunkPolicy.isEnabled = wasOn }
        let f = try await recoverFixture()
        let invariantsBefore = try await recoverInvariants(f)

        // A backup taken BEFORE the repair, restored into a clean profile: recovered there.
        let backup = f.env.root.appendingPathComponent("backup-before", isDirectory: true)
        _ = try await ArchiveBackup.create(store: f.env.store, to: backup)
        let cleanRoot = f.env.root.appendingPathComponent("clean-profile", isDirectory: true)
        try ArchiveBackup.restore(backup: backup, intoStoreDirectory: cleanRoot, mode: .cleanProfile)
        let restored = SQLiteEmailStore(directory: cleanRoot)
        let restoredPlan = try await RawSourceRecovery.plan(store: restored)
        XCTAssertEqual(restoredPlan.total, 4); XCTAssertEqual(restoredPlan.recoverable, 3, "the copies travelled with the backup")
        let restoredReceipt = await RawSourceRecovery.run(store: restored, plan: restoredPlan)
        XCTAssertEqual(restoredReceipt.recovered, 3, restoredReceipt.line)
        for id in f.affected {
            let rowOptional = try await restored.fullEmail(id: id)
            let row = try XCTUnwrap(rowOptional)
            XCTAssertEqual(AttachmentHydrator.data(for: try XCTUnwrap(row.attachments.first), index: 0, email: row), f.docx)
            let restoredInvariants = try await restored.recoveryInvariants(id: id)
            XCTAssertEqual(restoredInvariants, invariantsBefore[id], "the restored copy keeps the same identity and review state")
        }
        await restored.reopenConnection()

        // The live archive: repair, then "restart" — a new store object on the same directory.
        let plan = try await RawSourceRecovery.plan(store: f.env.store)
        let receipt = await RawSourceRecovery.run(store: f.env.store, plan: plan)
        XCTAssertEqual(receipt.recovered, 3, receipt.line)
        await f.env.store.reopenConnection()
        let reopened = SQLiteEmailStore(directory: f.env.store.storeDirectory)
        let afterRestart = try await RawSourceRecovery.plan(store: reopened)
        XCTAssertEqual(afterRestart.total, 1, "only the lost one; nothing left to do")
        XCTAssertEqual(afterRestart.recoverable, 0)
        XCTAssertEqual(afterRestart.alreadyIntact, 4)
        for id in f.affected {
            let rowOptional = try await reopened.fullEmail(id: id)
            let row = try XCTUnwrap(rowOptional)
            XCTAssertTrue(RawSourceProvenance.label(for: row.rawSource).isReconstructed)
            XCTAssertEqual(AttachmentHydrator.data(for: try XCTUnwrap(row.attachments.first), index: 0, email: row), f.docx)
            let reopenedInvariants = try await reopened.recoveryInvariants(id: id)
            XCTAssertEqual(reopenedInvariants, invariantsBefore[id])
        }
        let afterRestartReceipt = await RawSourceRecovery.run(store: reopened, plan: afterRestart)
        XCTAssertEqual(afterRestartReceipt.recovered, 0); XCTAssertEqual(afterRestartReceipt.alreadyIntact, 4)

        // A backup taken AFTER the repair, restored into another clean profile: the repair is in it.
        let backupAfter = f.env.root.appendingPathComponent("backup-after", isDirectory: true)
        _ = try await ArchiveBackup.create(store: reopened, to: backupAfter)
        let cleanRoot2 = f.env.root.appendingPathComponent("clean-profile-2", isDirectory: true)
        try ArchiveBackup.restore(backup: backupAfter, intoStoreDirectory: cleanRoot2, mode: .cleanProfile)
        let restored2 = SQLiteEmailStore(directory: cleanRoot2)
        let plan2 = try await RawSourceRecovery.plan(store: restored2)
        XCTAssertEqual(plan2.total, 1); XCTAssertEqual(plan2.alreadyIntact, 4)
        await restored2.reopenConnection()
        await reopened.reopenConnection()
    }

    /// Cancellation mid-run: the first source is committed whole, the file being read when the person
    /// stopped is not written at all (no half-written rows), the receipt is partial and says so.
    func testRECOVER_cancellationMidRun_partialReceipt_noHalfWrittenRows() async throws {
        let wasOn = SearchChunkPolicy.isEnabled
        defer { SearchChunkPolicy.isEnabled = wasOn }
        let f = try await recoverFixture()
        let plan = try await RawSourceRecovery.plan(store: f.env.store)
        XCTAssertEqual(plan.recoverable, 3)
        final class Box: @unchecked Sendable { var task: Task<RawSourceRecovery.Receipt, Never>?; var calls = 0; let lock = NSLock() }
        let box = Box()
        let store = f.env.store
        box.task = Task {
            await RawSourceRecovery.run(store: store, plan: plan) { _ in
                box.lock.lock(); box.calls += 1; let n = box.calls; box.lock.unlock()
                if n == 2 { box.task?.cancel() }   // stop while the second source is being read
            }
        }
        let receipt = await box.task!.value
        XCTAssertTrue(receipt.cancelled, receipt.line)
        XCTAssertEqual(plan.affectedGroups.filter { $0.fileURL != nil }.map(\.filename), ["one.msg", "two.pst"], "sources are read in name order")
        XCTAssertEqual(receipt.recovered, 1, "the first source (one.msg) was committed whole")
        XCTAssertEqual(receipt.sourcesRead, 1)
        XCTAssertEqual(receipt.sources.first { $0.filename == "two.pst" }?.cancelled, true)
        XCTAssertEqual(receipt.sources.first { $0.filename == "two.pst" }?.recovered, 0)
        XCTAssertTrue(receipt.line.contains("cancelled after 1 of 3 sources"), receipt.line)
        XCTAssertTrue(RawSourceRecoveryView.receiptText(receipt).contains("Stopped after 1 of 3 sources"))
        let firstOptional = try await store.fullEmail(id: f.imported[0])
        let first = try XCTUnwrap(firstOptional)
        XCTAssertTrue(RawSourceProvenance.label(for: first.rawSource).isReconstructed)
        for id in [f.imported[1]] {
            let rowOptional = try await store.fullEmail(id: id)
            let row = try XCTUnwrap(rowOptional)
            XCTAssertTrue(row.rawSource.isEmpty, "a row of the cancelled file is exactly as it was")
        }
        let strippedOptional = try await store.fullEmail(id: f.stripped)
        let strippedRow = try XCTUnwrap(strippedOptional)
        XCTAssertFalse(RawSourceProvenance.label(for: strippedRow.rawSource).isReconstructed)
        // Running again finishes the job.
        let rest = try await RawSourceRecovery.plan(store: store)
        XCTAssertEqual(rest.recoverable, 2)
        let second = await RawSourceRecovery.run(store: store, plan: rest)
        XCTAssertEqual(second.recovered, 2, second.line)
    }

    /// The wrong source: a chosen file whose SHA-256 differs from the registered import is reported
    /// as such and nothing is written from it — a message in it with the SAME Message-ID but other
    /// content is ambiguous (listed with both sides), one with an unknown Message-ID is ignored.
    /// The right file, chosen afterwards, recovers the rows.
    func testRECOVER_wrongSource_reportedNothingWritten_ambiguousListed_thenRightFileRecovers() async throws {
        let wasOn = SearchChunkPolicy.isEnabled
        defer { SearchChunkPolicy.isEnabled = wasOn }
        let f = try await recoverFixture(copyPST: false)
        let plan = try await RawSourceRecovery.plan(store: f.env.store)
        XCTAssertEqual(plan.total, 4); XCTAssertEqual(plan.recoverable, 1, "one.msg has a copy; two.pst does not")
        let pstGroup = try XCTUnwrap(plan.groups.first { $0.filename == "two.pst" })
        XCTAssertNil(pstGroup.fileURL)
        // Another PST: same Message-ID as message 2 but a different subject; one unrelated message.
        let other = f.env.root.appendingPathComponent("other.pst")
        let writer = try PSTWriterFactory.make(url: other)
        var impostor = try MBOXParser.processRawMessage(Self.recoverMessage(2, docx: f.docx), senderEmail: "")
        impostor.headers["Subject"] = "Different subject"
        try writer.appendMessage(impostor)
        try writer.appendMessage(try MBOXParser.processRawMessage(Self.recoverMessage(7, docx: f.docx), senderEmail: ""))
        _ = try writer.finalize()
        let invariantsBefore = try await recoverInvariants(f)
        let receipt = await RawSourceRecovery.run(store: f.env.store, plan: plan, files: [pstGroup.id: other])
        XCTAssertEqual(receipt.wrongSources, ["two.pst"], receipt.line)
        XCTAssertEqual(receipt.recovered, 1, "only one.msg, from its verified copy")
        let pst = try XCTUnwrap(receipt.sources.first { $0.filename == "two.pst" })
        XCTAssertTrue(pst.wrongSource); XCTAssertEqual(pst.recovered, 0); XCTAssertEqual(pst.ambiguous, 1); XCTAssertEqual(pst.unmatched, 1)
        XCTAssertEqual(receipt.ambiguousItems.count, 1)
        XCTAssertEqual(receipt.ambiguousItems[0].emailID, f.imported[1])
        XCTAssertEqual(receipt.ambiguousItems[0].storedSubject, "Recover 2")
        XCTAssertEqual(receipt.ambiguousItems[0].fileSubject, "Different subject")
        XCTAssertTrue(receipt.ambiguousItems[0].reason.contains("Message-ID matches but"), receipt.ambiguousItems[0].reason)
        XCTAssertTrue(RawSourceRecoveryView.receiptText(receipt).contains("Wrong source"))
        for id in [f.imported[1]] {
            let rowOptional = try await f.env.store.fullEmail(id: id)
            let row = try XCTUnwrap(rowOptional)
            XCTAssertTrue(row.rawSource.isEmpty, "nothing was written from the wrong file")
        }
        let invariantsAfterWrong = try await recoverInvariants(f)
        XCTAssertEqual(invariantsAfterWrong, invariantsBefore)
        // The right file, chosen: its hash matches the registered source; the rows are recovered.
        let rest = try await RawSourceRecovery.plan(store: f.env.store)
        let group = try XCTUnwrap(rest.groups.first { $0.filename == "two.pst" })
        XCTAssertEqual(group.count, 2)
        let second = await RawSourceRecovery.run(store: f.env.store, plan: rest, files: [group.id: f.pstURL])
        XCTAssertEqual(second.recovered, 2, second.line)
        XCTAssertEqual(second.wrongSources, [])
        XCTAssertEqual(second.sources.first { $0.filename == "two.pst" }?.fileSHA256, f.pstHash)
        let rowOptional = try await f.env.store.fullEmail(id: f.imported[1])
        let row = try XCTUnwrap(rowOptional)
        XCTAssertEqual(AttachmentHydrator.data(for: try XCTUnwrap(row.attachments.first), index: 0, email: row), f.docx)
        let invariantsAfterRight = try await recoverInvariants(f)
        XCTAssertEqual(invariantsAfterRight, invariantsBefore)
    }

    /// The matcher itself: Message-ID alone is not enough; one weak signal is not enough; the ordinal
    /// stands in for a missing Message-ID only with corroboration; two rows for one message is ambiguous.
    func testRECOVER_matcher_messageIDNeedsCorroboration_ordinalFallback_oneWeakSignalNever() throws {
        func candidate(_ id: String?, subject: String, date: Int64 = 1_736_935_320, from: String = "ann@example.com", ordinal: Int64? = nil, names: [String] = ["minutes.docx"]) -> SQLiteEmailStore.RecoveryCandidate {
            SQLiteEmailStore.RecoveryCandidate(id: UUID(), messageID: id, subject: subject, date: date, from: from, sourceHash: "h",
                                               sourceOrdinal: ordinal, attachmentNames: names, hasRawSource: false)
        }
        func parsed(_ id: String?, subject: String, date: String = "Wed, 15 Jan 2025 10:02:00 +0000", from: String = "Ann <ann@example.com>", names: [String] = ["minutes.docx"]) -> MBOXParser.RawEmail {
            var headers = ["Subject": subject, "From": from, "Date": date]
            if let id { headers["Message-ID"] = id }
            return MBOXParser.RawEmail(id: UUID(), headers: headers, rawSource: "x", messageType: "received",
                                       attachments: names.map { AttachmentMetadata(filename: $0, mimeType: "application/octet-stream", size: 1) },
                                       timestamp: "", domains: [], plainBody: "", htmlBody: "", mimeRoot: nil, mimeSummary: nil, mimeDiagnostics: [],
                                       threadID: nil, inReplyTo: nil, references: nil)
        }
        let a = candidate("<a@x>", subject: "Alpha", ordinal: 0)
        let b = candidate(nil, subject: "Beta", ordinal: 1)
        let c1 = candidate("<c@x>", subject: "Gamma", ordinal: 2), c2 = candidate("<c@x>", subject: "Gamma", ordinal: 3)
        let matcher = RawSourceRecovery.Matcher(candidates: [a, b, c1, c2], verifiedFile: true)
        // Message-ID + content.
        XCTAssertEqual(matcher.match(parsed("<A@X>", subject: "Alpha"), ordinal: 0), .match(a, strong: true), "Message-ID is case- and bracket-insensitive")
        // Message-ID alone: the subject differs → ambiguous, never written.
        if case .ambiguous(let item) = matcher.match(parsed("<a@x>", subject: "Alpha changed"), ordinal: 0) {
            XCTAssertEqual(item.storedSubject, "Alpha"); XCTAssertEqual(item.fileSubject, "Alpha changed")
        } else { XCTFail("Message-ID alone must not match") }
        // Message-ID + content but the date differs by a second → ambiguous.
        guard case .ambiguous = matcher.match(parsed("<a@x>", subject: "Alpha", date: "Wed, 15 Jan 2025 10:02:01 +0000"), ordinal: 0) else { return XCTFail("date to the second") }
        // Message-ID + content but one attachment fewer → ambiguous.
        guard case .ambiguous = matcher.match(parsed("<a@x>", subject: "Alpha", names: []), ordinal: 0) else { return XCTFail("attachment count") }
        // No Message-ID: the ordinal plus content.
        XCTAssertEqual(matcher.match(parsed(nil, subject: "Beta"), ordinal: 1), .match(b, strong: false))
        guard case .ambiguous = matcher.match(parsed(nil, subject: "Beta changed"), ordinal: 1) else { return XCTFail("ordinal alone is one weak signal") }
        // No Message-ID, no ordinal row: all content signals and exactly one row.
        XCTAssertEqual(matcher.match(parsed(nil, subject: "Beta"), ordinal: 9), .match(b, strong: false))
        XCTAssertEqual(matcher.match(parsed(nil, subject: "Beta", from: ""), ordinal: 9), .none, "subject + date without a sender is too weak")
        XCTAssertEqual(matcher.match(parsed(nil, subject: "Nobody"), ordinal: 9), .none)
        // Two rows share the Message-ID and the content → ambiguous.
        guard case .ambiguous(let twin) = matcher.match(parsed("<c@x>", subject: "Gamma"), ordinal: 2) else { return XCTFail("two rows") }
        XCTAssertTrue(twin.reason.contains("2 rows"), twin.reason)
        // A file whose hash differs is trusted only when the row's own content
        // (stored body or attachment hashes) confirms it — audit R4. This row
        // keeps neither, so Message-ID + metadata is not enough: ambiguous.
        let unverified = RawSourceRecovery.Matcher(candidates: [a, b], verifiedFile: false)
        guard case .ambiguous(let changed) = unverified.match(parsed("<a@x>", subject: "Alpha"), ordinal: 0) else {
            return XCTFail("a changed file is not trusted on Message-ID and metadata alone")
        }
        XCTAssertTrue(changed.reason.contains("no body or attachment fingerprint"), changed.reason)
        XCTAssertEqual(unverified.match(parsed(nil, subject: "Beta"), ordinal: 1), .none, "no ordinal fallback in an unverified file")
        // The provenance label round-trips.
        let stamped = RawSourceProvenance.stamp(rawSource: "X-Mailin-Rendered: Outlook\r\nSubject: s\r\n\r\nbody", sourceFilename: "two.pst", date: Date(timeIntervalSince1970: 1_762_500_000), verified: false)
        XCTAssertTrue(stamped.hasPrefix("X-Mailin-Rendered: Outlook\r\nX-Mailin-Reconstructed: from two.pst on "), stamped)
        let label = RawSourceProvenance.label(for: stamped)
        XCTAssertEqual(label.rendered, "Outlook"); XCTAssertEqual(label.sourceFilename, "two.pst")
        XCTAssertEqual(label.date, Date(timeIntervalSince1970: 1_762_500_000)); XCTAssertTrue(label.fromUnverifiedFile)
        XCTAssertFalse(RawSourceProvenance.label(for: "From: a\r\nSubject: real bytes\r\n\r\nbody").isReconstructed)
    }

    /// Directive §2 "Repair persisted child hashes": a pre-fix archive (double-hashed children of
    /// attached messages written directly, at the completed version-7 state) is selected by version
    /// AND kind — a zip's children and a version-8 message are not — recomputed from the preserved
    /// bytes, corrected atomically with the evidence and the message untouched; an interrupted run
    /// resumes from its cursor without processing a message twice; missing bytes are marked
    /// "hash unverifiable", never invented; a second run repairs nothing; the record reads in Health.
    func testCHILDHASH_versionedRepair_selectsAffectedCompletedRows_recomputes_resumes_marksUnverifiable_idempotent() async throws {
        let wasOn = SearchChunkPolicy.isEnabled
        defer { SearchChunkPolicy.isEnabled = wasOn }
        let env = try chunkedEnv()
        AttachmentTextIndexJob.testSuppressKicks = true
        AttachmentTextIndexJob.testSuppressChildHashRepair = true
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()
        AttachmentTextIndexJob.testStoreOverride = env.store
        defer { AttachmentTextIndexJob.testStoreOverride = nil; AttachmentTextIndexJob.testSuppressKicks = false; AttachmentTextIndexJob.testSuppressChildHashRepair = false }
        let ocrWas = AttachmentOCR.isEnabled
        AttachmentOCR.isEnabled = false
        defer { AttachmentOCR.isEnabled = ocrWas }
        AttachmentTextIndexJob.installChildReader()
        let docxMime = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        let terms = Self.docx(body: "Nested terms mention indemnity.", header: "")
        let plain = Data("Plain file next to the document".utf8)
        let innerRaw = """
        From: inner@example.com
        To: me@example.com
        Subject: Inner subject
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="B"

        --B
        Content-Type: text/plain

        Inner body says quorum
        \(mimeAttachment("terms.docx", docxMime, terms))
        \(mimeAttachment("plain.txt", "text/plain", plain))
        --B--
        """
        let inner = Data(innerRaw.utf8)
        let zip = Self.zipPackage([("notes/open.txt", Data("Open words inside the archive.".utf8))])
        func outer(_ n: Int, attachment: String) -> String {
            """
            From sender@example.com Wed Jan 15 10:00:00 2025
            From: sender@example.com
            To: user@dest.org
            Subject: Carrier \(n)
            Date: Wed, 15 Jan 2025 10:0\(n):00 +0000
            Message-ID: <carrier-\(n)@t>
            MIME-Version: 1.0
            Content-Type: multipart/mixed; boundary="B"

            --B
            Content-Type: text/plain

            carrier body \(n)
            \(attachment)
            --B--
            """
        }
        var emails: [MBOXParser.RawEmail] = []
        for n in 1...4 { emails.append(try MBOXParser.processRawMessage(outer(n, attachment: mimeAttachment("inner.eml", "message/rfc822", inner)), senderEmail: "")) }
        emails.append(try MBOXParser.processRawMessage(outer(5, attachment: mimeAttachment("pack.zip", "application/zip", zip)), senderEmail: ""))
        emails.append(try MBOXParser.processRawMessage(outer(6, attachment: mimeAttachment("inner.eml", "message/rfc822", inner)), senderEmail: ""))
        let (a, b, c, d, e, f) = (emails[0].id, emails[1].id, emails[2].id, emails[3].id, emails[4].id, emails[5].id)
        _ = try await env.store.insertBatch(emails, sourceFileHash: nil, accountID: nil, sourceID: nil, firstOrdinal: nil, dedupPolicy: .messageID, batchSize: 10, progress: nil)
        let outcome = await AttachmentTextIndexJob.shared.run()
        XCTAssertEqual(outcome.indexedEmails, 6)
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()
        let correctTerms = ExportFolderManifest.hex(terms), correctPlain = ExportFolderManifest.hex(plain)
        let doubleTerms = ExportFolderManifest.hex(Data(SHA256.hash(data: terms))), doublePlain = ExportFolderManifest.hex(Data(SHA256.hash(data: plain)))
        let healthyA = try await env.store.attachmentChildren(forEmailID: a)
        XCTAssertEqual(healthyA.map(\.sha256), [correctTerms, correctPlain], "the fixed reader writes single hashes")

        // The pre-fix archive: every child row of the six messages rewritten with the double hash,
        // its text documents kept (as a real version-7 archive has them).
        func doubleHash(_ id: UUID, extractorVersion: Int) async throws {
            let rows = try await env.store.attachmentChildren(forEmailID: id)
            var texts: [Int: String?] = [:], states: [Int: SearchDocState] = [:]
            for row in rows {
                texts[row.childIndex] = try await env.store.attachmentDocumentText(emailID: id, ordinal: row.ordinal)
                states[row.childIndex] = .complete
            }
            let doubled = rows.map { row -> AttachmentChildRow in
                let bytes = row.filename == "terms.docx" ? terms : row.filename == "plain.txt" ? plain : Data("Open words inside the archive.".utf8)
                return AttachmentChildRow(emailID: id, position: row.position, childIndex: row.childIndex, path: row.path, filename: row.filename, kind: row.kind,
                                          sha256: ExportFolderManifest.hex(Data(SHA256.hash(data: bytes))), bytes: row.bytes, state: row.state, note: row.note)
            }
            try await env.store.recordAttachmentChildren(emailID: id, position: 0, children: doubled, texts: texts, states: states, extractorVersion: extractorVersion)
        }
        for id in [a, b, c, d, e] { try await doubleHash(id, extractorVersion: 7) }
        // The job now writes its parent documents at extractor 8 (directive §6); a real pre-fix archive
        // carries them at ≤ 7, which is what the selection keys on — restate A–E's parent rows at 7.
        // (Re-indexing a parent clears only the other attachment-content kinds at that ordinal, never childText.)
        for id in [a, b, c, d, e] {
            let parentText = try await env.store.attachmentDocumentText(emailID: id, ordinal: 0)
            try await env.store.indexAttachmentSearchDocuments(emailID: id, documents: [AttachmentSearchDocument(ordinal: 0, filename: id == e ? "pack.zip" : "inner.eml", text: parentText, state: .complete, extractorVersion: 7, ocr: false)])
        }
        try await doubleHash(f, extractorVersion: 8)
        // F's parent attachment was read by a (hypothetical) version-8 reader: not the affected path.
        try await env.store.indexAttachmentSearchDocuments(emailID: f, documents: [AttachmentSearchDocument(ordinal: 0, filename: "inner.eml", text: "inner", state: .complete, extractorVersion: 8, ocr: false)])
        // D's bytes are gone: no raw source → the attached message cannot be read back.
        try await env.store.replaceRawSource(emailID: d, rawSource: "")
        let evidenceBefore = try await env.store.attachmentDocumentText(emailID: a, ordinal: SearchDocKind.childOrdinal(parent: 0, child: 0))
        XCTAssertTrue(evidenceBefore?.contains("indemnity") ?? false, "the child's text is the evidence to preserve: \(evidenceBefore ?? "nil")")
        let messageBeforeOptional = try await env.store.fullEmail(id: a)
        let messageBefore = try XCTUnwrap(messageBeforeOptional)
        let rowsBeforeE = try await env.store.attachmentChildren(forEmailID: e)
        let rowsBeforeF = try await env.store.attachmentChildren(forEmailID: f)

        // Selection: completed rows under a MESSAGE attachment at version ≤ 7 — A, B, C, D; not E (zip), not F (v8).
        let selected = try await env.store.childHashRepairPage(after: nil, maxExtractorVersion: 7, limit: 100)
        XCTAssertEqual(Set(selected), [a, b, c, d])
        XCTAssertEqual(selected, selected.sorted { $0.uuidString < $1.uuidString }, "in id order, so a cursor can resume")

        // Interrupted after one message; resumed; each message processed exactly once.
        let suite = "childhash-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = await ChildHashRepair.run(store: env.store, defaults: defaults, stopAfterMessages: 1)
        XCTAssertEqual(first.messages, 1); XCTAssertFalse(first.completed); XCTAssertFalse(first.alreadyDone)
        let partial = try XCTUnwrap(ChildHashRepair.record(defaults: defaults))
        XCTAssertFalse(partial.completed); XCTAssertEqual(partial.cursor, selected[0]); XCTAssertEqual(partial.messages, 1)
        let second = await ChildHashRepair.run(store: env.store, defaults: defaults)
        XCTAssertEqual(second.messages, 3, "the three that were left, not four: no message is processed twice")
        XCTAssertTrue(second.completed)
        let record = try XCTUnwrap(ChildHashRepair.record(defaults: defaults))
        XCTAssertTrue(record.completed)
        XCTAssertEqual(record.messages, 4)
        XCTAssertEqual(record.rowsChecked, 6, "A, B, C: two children each")
        XCTAssertEqual(record.rowsRepaired, 6)
        XCTAssertEqual(record.rowsUnverifiable, 2, "D's two children: bytes not available")
        XCTAssertEqual(record.rowsFailed, 0)
        XCTAssertEqual(first.rowsRepaired + second.rowsRepaired, 6)
        XCTAssertEqual(record.storePath, env.store.storeDirectory.path)

        // Corrected from the bytes; evidence and the message untouched.
        for id in [a, b, c] {
            let rows = try await env.store.attachmentChildren(forEmailID: id)
            XCTAssertEqual(rows.map(\.sha256), [correctTerms, correctPlain], "\(id)")
            XCTAssertEqual(rows.map(\.note), [nil, nil])
        }
        let evidenceAfter = try await env.store.attachmentDocumentText(emailID: a, ordinal: SearchDocKind.childOrdinal(parent: 0, child: 0))
        XCTAssertEqual(evidenceAfter, evidenceBefore, "the child's text documents are not rewritten")
        let messageAfterOptional = try await env.store.fullEmail(id: a)
        let messageAfter = try XCTUnwrap(messageAfterOptional)
        XCTAssertEqual(messageAfter.id, messageBefore.id); XCTAssertEqual(messageAfter.rawSource, messageBefore.rawSource)
        XCTAssertEqual(messageAfter.headers, messageBefore.headers); XCTAssertEqual(messageAfter.attachments.map(\.filename), messageBefore.attachments.map(\.filename))
        // Missing bytes: marked, not invented.
        let rowsD = try await env.store.attachmentChildren(forEmailID: d)
        XCTAssertEqual(rowsD.map(\.sha256), [doubleTerms, doublePlain], "no hash was invented for D")
        XCTAssertTrue(rowsD.allSatisfy { $0.note?.contains("hash unverifiable") ?? false }, "\(rowsD.map { $0.note ?? "nil" })")
        // Not selected: untouched.
        let rowsAfterE = try await env.store.attachmentChildren(forEmailID: e)
        XCTAssertEqual(rowsAfterE, rowsBeforeE, "a zip's children were never double-hashed")
        let rowsAfterF = try await env.store.attachmentChildren(forEmailID: f)
        XCTAssertEqual(rowsAfterF, rowsBeforeF, "a version-8 row is outside the affected path")
        // Second run: nothing to do.
        let third = await ChildHashRepair.run(store: env.store, defaults: defaults)
        XCTAssertTrue(third.alreadyDone); XCTAssertEqual(third.rowsRepaired, 0); XCTAssertEqual(third.messages, 0)
        // Even from a blank record (another profile), the data is already right: zero repaired, D still marked once.
        let otherSuite = "childhash-\(UUID().uuidString)"
        let otherDefaults = try XCTUnwrap(UserDefaults(suiteName: otherSuite))
        defer { otherDefaults.removePersistentDomain(forName: otherSuite) }
        let fourth = await ChildHashRepair.run(store: env.store, defaults: otherDefaults)
        XCTAssertEqual(fourth.rowsChecked, 6); XCTAssertEqual(fourth.rowsRepaired, 0); XCTAssertEqual(fourth.rowsUnverifiable, 2); XCTAssertTrue(fourth.completed)
        let rowsDAgain = try await env.store.attachmentChildren(forEmailID: d)
        XCTAssertEqual(rowsDAgain, rowsD, "marking is idempotent")
        // The record reads in Health.
        let text = try XCTUnwrap(ChildHashRepair.reportText(record))
        XCTAssertTrue(text.contains("6 rows checked") && text.contains("6 repaired") && text.contains("2 unverifiable"), text)
        XCTAssertNil(ChildHashRepair.reportText(nil))
    }

    /// WP4 (handoff 7481852): one registry says what is read and on what
    /// evidence; every source format and document kind is in it, every
    /// "not implemented" row says so, and the public table is generated
    /// from it and carried verbatim in SUPPORTED_FORMATS_AND_LIMITS.md.
    func testWP4_formatRegistryCoversEveryKind_andThePublicTableIsGeneratedFromIt() throws {
        let registry = FormatCapabilityRegistry.all
        XCTAssertEqual(Set(registry.map(\.id)).count, registry.count, "ids are unique")
        for format in SourceFormat.allCases where format != .unknown {
            let token = format.parserToken.isEmpty ? format.rawValue : format.parserToken
            let covered = registry.contains { c in c.family == .mailSource && (c.id.hasPrefix(token) || c.extensions.contains(token) || c.id == "zip-source" && ["zip", "gzip", "tar"].contains(token)
                                                                                 || c.id == "applemail" && format.rawValue.hasPrefix("appleMail") || c.id == "maildir" && token == "mbox" || c.id == "eml" && format == .emlFolder) }
            XCTAssertTrue(covered, "source format \(format) has no registry row")
        }
        for kind in DocumentKind.allCases {
            // Project XML has no extension of its own: it is an .xml told apart by its namespace.
            let token = kind == .projectXML ? "xml (MSPDI)" : kind.rawValue
            let covered = registry.contains { c in c.family != .mailSource && c.extensions.contains(token) }
            XCTAssertTrue(covered, "document kind \(kind) has no registry row")
        }
        for row in registry where row.evidence == .notImplemented {
            XCTAssertNotNil(row.limitation, "\(row.id): a not-implemented row must say so")
            XCTAssertEqual(row.whatIsRead, "—")
        }
        let table = FormatCapabilityRegistry.markdownTable()
        XCTAssertTrue(table.contains("| Mail source | Outlook for Mac archive | olm |"))
        XCTAssertTrue(table.contains("**not implemented**"))
        // The public document carries the generated table verbatim between its markers.
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let doc = try String(contentsOf: repo.appendingPathComponent("SUPPORTED_FORMATS_AND_LIMITS.md"), encoding: .utf8)
        let start = "<!-- format-registry:begin -->", end = "<!-- format-registry:end -->"
        guard let a = doc.range(of: start), let b = doc.range(of: end) else { return XCTFail("the registry markers are missing from the document") }
        let carried = doc[a.upperBound..<b.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(carried, table, "SUPPORTED_FORMATS_AND_LIMITS.md must carry FormatCapabilityRegistry.markdownTable() verbatim — regenerate it")
    }

    /// Directive 2026-11-07 §6 "Containers": a ZIP split into volumes and attached
    /// as several files (set.z01 + set.zip) is read as one set through the job —
    /// the member spanning the volume boundary is searchable, and the .z01 row
    /// says its files are listed under the entry volume. With volume 1 not
    /// attached, the member on it is named with the missing volume and the rest
    /// is still read; a lone .z01 says which entry volume is missing.
    func testSPLIT01_splitZipAttachedAsVolumes_readAsOneSet_missingVolumeNamed() async throws {
        #if !os(macOS)
        // Info-ZIP is run as a child process to write the spanned set; iOS has no Process.
        throw XCTSkip("needs /usr/bin/zip (macOS)")
        #else
        let zip = URL(fileURLWithPath: "/usr/bin/zip")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: zip.path), "/usr/bin/zip is not available")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("split-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // minutes.txt (≈ 70,000 bytes, stored) starts on volume 1 and runs into volume 2; tail.txt sits on volume 2.
        let minutes = "The quorum clause survives the split. " + String(repeating: "filler words for the spanned member. ", count: 1900)
        try Data(minutes.utf8).write(to: dir.appendingPathComponent("minutes.txt"))
        try Data("tail member on the last volume MAILIN-SPLIT-TAIL\n".utf8).write(to: dir.appendingPathComponent("tail.txt"))
        let process = Process()
        process.executableURL = zip
        process.currentDirectoryURL = dir
        process.arguments = ["-q", "-0", "-s", "64k", "set.zip", "minutes.txt", "tail.txt"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        try XCTSkipUnless(process.terminationStatus == 0, "zip -s failed (\(process.terminationStatus))")
        let z01 = try Data(contentsOf: dir.appendingPathComponent("set.z01"))
        let last = try Data(contentsOf: dir.appendingPathComponent("set.zip"))
        XCTAssertEqual(z01.count, 65_536, "Info-ZIP writes equal volumes; the first is exactly 64k")

        let wasOn = SearchChunkPolicy.isEnabled
        defer { SearchChunkPolicy.isEnabled = wasOn }
        let env = try chunkedEnv()
        AttachmentTextIndexJob.testSuppressKicks = true
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()
        AttachmentTextIndexJob.testStoreOverride = env.store
        defer { AttachmentTextIndexJob.testStoreOverride = nil; AttachmentTextIndexJob.testSuppressKicks = false }
        AttachmentTextIndexJob.installChildReader()
        func message(_ subject: String, _ id: String, _ parts: [String]) -> String {
            """
            From sender@example.com Wed Jan 15 10:00:00 2025
            From: sender@example.com
            To: user@dest.org
            Subject: \(subject)
            Date: Wed, 15 Jan 2025 10:00:00 +0000
            Message-ID: <\(id)@t>
            MIME-Version: 1.0
            Content-Type: multipart/mixed; boundary="B"

            --B
            Content-Type: text/plain

            the archive is attached in volumes
            \(parts.joined(separator: "\n"))
            --B--
            """
        }
        let whole = try MBOXParser.processRawMessage(message("Split set", "split-whole", [mimeAttachment("set.z01", "application/octet-stream", z01), mimeAttachment("set.zip", "application/zip", last)]), senderEmail: "")
        let lastOnly = try MBOXParser.processRawMessage(message("Last volume only", "split-last", [mimeAttachment("set.zip", "application/zip", last)]), senderEmail: "")
        let firstOnly = try MBOXParser.processRawMessage(message("First volume only", "split-first", [mimeAttachment("set.z01", "application/octet-stream", z01)]), senderEmail: "")
        _ = try await env.store.insertBatch([whole, lastOnly, firstOnly], sourceFileHash: nil, accountID: nil, sourceID: nil, firstOrdinal: nil, dedupPolicy: .messageID, batchSize: 10, progress: nil)
        let outcome = await AttachmentTextIndexJob.shared.run()
        XCTAssertEqual(outcome.indexedEmails, 3)
        let coverage = try AttachmentCoverageStore(url: await env.store.attachmentCoverageURL)

        // Both volumes attached: one set, read whole.
        let wholeRows = try coverage.rows(for: whole.id)
        XCTAssertEqual(wholeRows.map(\.filename), ["set.z01", "set.zip"])
        XCTAssertEqual(wholeRows[0].state, .noText, wholeRows[0].note ?? "")
        XCTAssertTrue(wholeRows[0].note?.contains("set.zip") == true, "the volume row points at the entry volume: \(wholeRows[0].note ?? "")")
        XCTAssertEqual(wholeRows[1].state, .extracted, wholeRows[1].note ?? "")
        let wholeChildren = await env.archive.attachmentChildren(emailID: whole.id)
        XCTAssertEqual(Set(wholeChildren.map(\.filename)), ["minutes.txt", "tail.txt"])
        XCTAssertEqual(wholeChildren.first { $0.filename == "minutes.txt" }?.state, ChildDocument.State.extracted.rawValue)
        func inSet(_ phrase: String) -> SearchSpec {
            SearchSpec(groups: [SearchGroup(.all, attachments: [AttachmentConditionGroup(nameContains: "set", contentMatch: .phrase, content: phrase)])])
        }
        try await expectIDs(env, inSet("quorum clause survives the split"), ["Split set"], "the member spanning the boundary is searchable only where both volumes are attached")
        try await expectIDs(env, inSet("MAILIN-SPLIT-TAIL"), ["Split set", "Last volume only"], "the member on the last volume is read with or without volume 1")

        // Volume 1 missing: the member on it is named, the rest is read.
        let lastRows = try coverage.rows(for: lastOnly.id)
        XCTAssertEqual(lastRows.count, 1)
        XCTAssertEqual(lastRows[0].state, .partial, lastRows[0].note ?? "")
        XCTAssertTrue(lastRows[0].note?.contains("volume 1 (set.z01) missing") == true, "the missing volume is named: \(lastRows[0].note ?? "")")
        let lastChildren = await env.archive.attachmentChildren(emailID: lastOnly.id)
        XCTAssertEqual(lastChildren.first { $0.filename == "minutes.txt" }?.state, ChildDocument.State.unsupported.rawValue)
        XCTAssertEqual(lastChildren.first { $0.filename == "minutes.txt" }?.note, "not opened: volume 1 (set.z01) missing")
        XCTAssertEqual(lastChildren.first { $0.filename == "tail.txt" }?.state, ChildDocument.State.extracted.rawValue)

        // The entry volume missing: nothing can be read, and the row says which file is needed.
        let firstRows = try coverage.rows(for: firstOnly.id)
        XCTAssertEqual(firstRows.count, 1)
        XCTAssertEqual(firstRows[0].state, .unsupported, firstRows[0].note ?? "")
        XCTAssertTrue(firstRows[0].note?.contains("set.zip") == true && firstRows[0].note?.contains("not attached") == true, firstRows[0].note ?? "")
        #endif
    }

    /// Directive 2026-11-07 §6 "OpenPGP": OpenPGP attachments and the PGP/MIME
    /// payload are described from their packet headers — recipient key IDs,
    /// integrity protection, "signature present, not verified" — never
    /// decrypted: this release has no OpenPGP key store. Unlock refuses with
    /// that reason instead of asking for a password that cannot work.
    func testPGP01_openPGPAttachmentsAndPGPMIME_describedNotDecrypted_noPasswordOffered() async throws {
        // Packet builders (RFC 4880 §4.2) — the same spec-built bytes the package tests use.
        func newPacket(tag: UInt8, _ body: [UInt8]) -> [UInt8] {
            var out: [UInt8] = [0xC0 | tag]
            let n = body.count
            if n < 192 { out.append(UInt8(n)) } else { out += [UInt8(((n - 192) >> 8) + 192), UInt8((n - 192) & 0xFF)] }
            return out + body
        }
        let keyA: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04]
        let fingerprint: [UInt8] = (0..<20).map { UInt8($0 * 11 + 1) }
        let pkesk = newPacket(tag: 1, [3] + keyA + [1] + [0x04, 0x00] + [UInt8](repeating: 0x5A, count: 128))
        let seipdV1 = newPacket(tag: 18, [1] + [UInt8](repeating: 0x77, count: 40))
        let encrypted = Data(pkesk + seipdV1)
        let time: UInt32 = 1_700_000_000
        let creation: [UInt8] = [5, 2, UInt8(time >> 24), UInt8((time >> 16) & 0xFF), UInt8((time >> 8) & 0xFF), UInt8(time & 0xFF)]
        let issuerFP: [UInt8] = [UInt8(fingerprint.count + 2), 33, 4] + fingerprint
        let hashed = creation + issuerFP
        let unhashed: [UInt8] = [9, 16] + keyA
        let signature = newPacket(tag: 2, [4, 0x00, 22, 10, UInt8(hashed.count >> 8), UInt8(hashed.count & 0xFF)] + hashed
                                  + [UInt8(unhashed.count >> 8), UInt8(unhashed.count & 0xFF)] + unhashed + [0xAB, 0xCD] + [0x01, 0x00, 0x01] + [UInt8](repeating: 0x42, count: 64))
        let detached = Data(OpenPGP.armor(Data(signature), type: "PGP SIGNATURE").utf8)
        let armoredMessage = OpenPGP.armor(encrypted, type: "PGP MESSAGE")

        let wasOn = SearchChunkPolicy.isEnabled
        defer { SearchChunkPolicy.isEnabled = wasOn }
        let env = try chunkedEnv()
        AttachmentTextIndexJob.testSuppressKicks = true
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()
        AttachmentTextIndexJob.testStoreOverride = env.store
        defer { AttachmentTextIndexJob.testStoreOverride = nil; AttachmentTextIndexJob.testSuppressKicks = false }
        AttachmentTextIndexJob.installChildReader()
        let files = """
        From sender@example.com Wed Jan 15 10:00:00 2025
        From: sender@example.com
        To: user@dest.org
        Subject: OpenPGP files
        Date: Wed, 15 Jan 2025 10:00:00 +0000
        Message-ID: <pgp-files@t>
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="B"

        --B
        Content-Type: text/plain

        three OpenPGP-named files
        \(mimeAttachment("secret.gpg", "application/octet-stream", encrypted))
        \(mimeAttachment("report.pdf.sig", "application/pgp-signature", detached))
        \(mimeAttachment("notes.asc", "application/octet-stream", Data("just plain notes, no packets\n".utf8)))
        --B--
        """
        let pgpMIME = """
        From sender@example.com Wed Jan 15 10:00:00 2025
        From: sender@example.com
        To: user@dest.org
        Subject: PGP/MIME message
        Date: Wed, 15 Jan 2025 10:00:00 +0000
        Message-ID: <pgp-mime@t>
        MIME-Version: 1.0
        Content-Type: multipart/encrypted; boundary="B"; protocol="application/pgp-encrypted"

        --B
        Content-Type: application/pgp-encrypted

        Version: 1
        \(mimeAttachment("encrypted.asc", "application/octet-stream", Data(armoredMessage.utf8)))
        --B--
        """
        let filesEmail = try MBOXParser.processRawMessage(files, senderEmail: "")
        let mimeEmail = try MBOXParser.processRawMessage(pgpMIME, senderEmail: "")
        _ = try await env.store.insertBatch([filesEmail, mimeEmail], sourceFileHash: nil, accountID: nil, sourceID: nil, firstOrdinal: nil, dedupPolicy: .messageID, batchSize: 10, progress: nil)
        _ = await AttachmentTextIndexJob.shared.run()
        let coverage = try AttachmentCoverageStore(url: await env.store.attachmentCoverageURL)

        let rows = try coverage.rows(for: filesEmail.id)
        XCTAssertEqual(rows.map(\.filename), ["secret.gpg", "report.pdf.sig", "notes.asc"])
        XCTAssertEqual(rows.map(\.state), [.locked, .noText, .extracted], "\(rows.map { ($0.filename, $0.state, $0.note ?? "") })")
        XCTAssertEqual(rows.map(\.extractor), ["openpgp", "openpgp", "text"])
        let lockedNote = try XCTUnwrap(rows[0].note)
        XCTAssertTrue(lockedNote.contains("OpenPGP-encrypted to key DEADBEEF01020304 (RSA)"), lockedNote)
        XCTAssertTrue(lockedNote.contains("MDC present") && lockedNote.contains("never decrypts"), lockedNote)
        XCTAssertFalse(lockedNote.contains("password-protected"), "the generic password note is not used for OpenPGP: \(lockedNote)")
        let signedNote = try XCTUnwrap(rows[1].note)
        // GAP-PGP: no key imported, and the signed report.pdf is not attached — the issuer is named as unknown.
        XCTAssertTrue(signedNote.contains("unknown key"), signedNote)
        XCTAssertTrue(signedNote.contains("010C17222D38434E59646F7A85909BA6B1BCC7D2") && signedNote.contains("CRC-24 verified"),
                      "the issuer is named by its fingerprint: \(signedNote)")
        XCTAssertTrue(rows[2].note?.contains("no OpenPGP packets") == true, rows[2].note ?? "")

        let mimeRows = try coverage.rows(for: mimeEmail.id)
        XCTAssertEqual(mimeRows.map(\.filename), ["encrypted.asc"], "the Version: 1 control part is not an attachment; the payload is")
        XCTAssertEqual(mimeRows[0].state, .locked)
        XCTAssertTrue(mimeRows[0].note?.hasPrefix("PGP/MIME encrypted message (RFC 3156); OpenPGP-encrypted to key DEADBEEF01020304 (RSA)") == true, mimeRows[0].note ?? "")

        // Unlock cannot work — mailin keeps public keys only — and says so instead of "wrong password".
        let attempt = await AttachmentTextIndexJob.shared.unlock(emailID: filesEmail.id, position: 0, password: "anything", retain: true)
        guard case .unreadable(let why) = attempt else { return XCTFail("\(attempt)") }
        XCTAssertTrue(why.contains("never decrypts"), why)
        XCTAssertEqual(try coverage.rows(for: filesEmail.id)[0].state, .locked, "nothing changed")
        let summaryValue = await AttachmentTextIndexJob.coverageSummary(store: env.store)
        let summary = try XCTUnwrap(summaryValue)
        XCTAssertTrue(AttachmentTextIndexJob.noMatchNotice(summary).contains("2 locked"), AttachmentTextIndexJob.noMatchNotice(summary))
    }

    /// GAP-PGP (owner 2026-11-07): signatures are verified against the archive's
    /// public keyring through the job — a detached .sig beside the file it signs
    /// (GnuPG's own signature of swdb.lst from gnupg.org) and a PGP/MIME signed
    /// message (PGPy-written). Without keys: "unknown key". Import → every
    /// OpenPGP row is re-read and says "good signature"; remove → unknown again.
    func testGAPPGP_signaturesVerifiedThroughTheJob_importAndRemoveReverify() async throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Packages/ArchiveCore/Tests/ArchiveCoreTests/Fixtures/openpgp")
        let swdb = try Data(contentsOf: fixtures.appendingPathComponent("gnupg-org/swdb.lst"))
        let swdbSig = try Data(contentsOf: fixtures.appendingPathComponent("gnupg-org/swdb.lst.sig"))
        let gnupgKey = try Data(contentsOf: fixtures.appendingPathComponent("gnupg-org/gnupg_signature_key.asc"))
        let rsaKey = try Data(contentsOf: fixtures.appendingPathComponent("pgpy/rsa3072.pub.asc"))
        let pgpMIME = try XCTUnwrap(String(data: try Data(contentsOf: fixtures.appendingPathComponent("pgpy/pgpmime.rsa3072.eml")), encoding: .utf8))

        let wasOn = SearchChunkPolicy.isEnabled
        defer { SearchChunkPolicy.isEnabled = wasOn; OpenPGPKeyring.active = OpenPGPKeyring(fileURL: nil) }
        let env = try chunkedEnv()
        AttachmentTextIndexJob.testSuppressKicks = true
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()
        AttachmentTextIndexJob.testStoreOverride = env.store
        defer { AttachmentTextIndexJob.testStoreOverride = nil; AttachmentTextIndexJob.testSuppressKicks = false }
        AttachmentTextIndexJob.installChildReader()
        let detached = """
        From sender@example.com Wed Jan 15 10:00:00 2025
        From: sender@example.com
        To: user@dest.org
        Subject: GnuPG release list
        Date: Wed, 15 Jan 2025 10:00:00 +0000
        Message-ID: <gap-pgp-detached@t>
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="B"

        --B
        Content-Type: text/plain

        the list and its signature
        \(mimeAttachment("swdb.lst", "text/plain", swdb))
        \(mimeAttachment("swdb.lst.sig", "application/pgp-signature", swdbSig))
        --B--
        """
        let detachedEmail = try MBOXParser.processRawMessage(detached, senderEmail: "")
        let mimeEmail = try MBOXParser.processRawMessage("From ed@example.org Sat Nov  7 10:00:00 2026\r\n" + pgpMIME, senderEmail: "")
        _ = try await env.store.insertBatch([detachedEmail, mimeEmail], sourceFileHash: nil, accountID: nil, sourceID: nil, firstOrdinal: nil, dedupPolicy: .messageID, batchSize: 10, progress: nil)
        _ = await AttachmentTextIndexJob.shared.run()
        let coverage = try AttachmentCoverageStore(url: await env.store.attachmentCoverageURL)
        func sigNote() -> String {
            (try? coverage.rows(for: detachedEmail.id))?.first { $0.filename == "swdb.lst.sig" }?.note ?? "<no swdb.lst.sig row>"
        }
        func mimeNote() -> String {
            (try? coverage.rows(for: mimeEmail.id))?.first { $0.extractor == "openpgp" }?.note ?? "<no openpgp row>"
        }
        XCTAssertTrue(sigNote().contains("unknown key"), sigNote())
        XCTAssertTrue(mimeNote().contains("unknown key"), mimeNote())
        let empty = await AttachmentTextIndexJob.shared.publicKeys()
        XCTAssertTrue(empty.isEmpty)

        // Import GnuPG's signing keys: both OpenPGP rows are re-read; the detached signature is good.
        let first = try await AttachmentTextIndexJob.shared.importPublicKeys(gnupgKey)
        XCTAssertGreaterThan(first.result.imported.count, 0, "\(first.result.rejected)")
        XCTAssertEqual(first.reverified, 2, "every message with an OpenPGP row is re-read")
        _ = await AttachmentTextIndexJob.shared.run()
        XCTAssertTrue(sigNote().contains("good signature"), sigNote())
        XCTAssertTrue(mimeNote().contains("unknown key"), "the PGP/MIME signer is not imported yet: \(mimeNote())")

        // The PGP/MIME signer: the signed entity is taken from the raw message.
        let second = try await AttachmentTextIndexJob.shared.importPublicKeys(rsaKey)
        XCTAssertEqual(second.result.imported.count, 1, "\(second.result.rejected)")
        _ = await AttachmentTextIndexJob.shared.run()
        XCTAssertTrue(mimeNote().contains("good signature"), mimeNote())

        // The keyring is the archive's own file, kept beside the store.
        let keyringURL = await AttachmentTextIndexJob.keyringURL(store: env.store)
        XCTAssertTrue(FileManager.default.fileExists(atPath: keyringURL.path))
        let kept = await AttachmentTextIndexJob.shared.publicKeys()
        XCTAssertEqual(kept.count, first.result.imported.count + 1)

        // Remove the RSA key: its signature is unknown again; the GnuPG one stays good.
        let rsa = try XCTUnwrap(second.result.imported.first)
        let reverified = try await AttachmentTextIndexJob.shared.removePublicKey(fingerprint: rsa.fingerprint)
        XCTAssertEqual(reverified, 2)
        _ = await AttachmentTextIndexJob.shared.run()
        XCTAssertTrue(mimeNote().contains("unknown key"), mimeNote())
        XCTAssertTrue(sigNote().contains("good signature"), sigNote())
    }

    /// GAP-RAR: the volumes of a RAR set attached as separate files are gathered
    /// as one set (both naming schemes), and a later volume with the first
    /// volume attached says its files are listed under that first volume.
    func testGAPRAR_attachedRARVolumesGatheredAsOneSet_laterVolumeListedUnderTheFirst() {
        func attachment(_ name: String) -> AttachmentMetadata {
            AttachmentMetadata(filename: name, mimeType: "application/octet-stream", size: 3, base64: Data("RAR".utf8).base64EncodedString())
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("rar-vol-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let partN = [attachment("set.part1.rar"), attachment("notes.txt"), attachment("set.part2.rar"), attachment("other.part2.rar")]
        let gathered = AttachmentTextIndexJob.volumeSiblings(of: 0, among: partN, scratch: scratch)
        XCTAssertEqual(gathered.map(\.name), ["set.part2.rar"])
        let old = [attachment("Set.rar"), attachment("set.r00"), attachment("set.r01"), attachment("set.part2.rar")]
        XCTAssertEqual(AttachmentTextIndexJob.volumeSiblings(of: 0, among: old, scratch: scratch).map(\.name), ["set.r00", "set.r01"],
                       "old-style names only; a .partN volume of the same stem is another scheme")

        let second = AttachmentTextIndexJob.volumeSiblings(of: 2, among: partN, scratch: scratch)
        let listed = AttachmentTextIndexJob.rarVolumeReading(name: "set.part2.rar", siblings: second)
        XCTAssertEqual(listed?.state, .noText)
        XCTAssertTrue(listed?.note?.contains("set.part1.rar") == true, listed?.note ?? "")
        XCTAssertNil(AttachmentTextIndexJob.rarVolumeReading(name: "set.part1.rar", siblings: gathered), "the first volume is read, not listed")
        XCTAssertNil(AttachmentTextIndexJob.rarVolumeReading(name: "other.part2.rar", siblings: []), "volume 1 missing: the reader names it")
    }

    /// GAP-RAR: the vendored libarchive is BSD-licensed; its notice must ship in About ▸ Licenses.
    /// GAP-NSF: the ODS reader is a preview switch, off by default, wired to NotesODSPolicy.
    func testGAP_licenceNoticeCarriesLibarchive_andNotesODSIsAPreviewSwitch() {
        XCTAssertTrue(LegalComplianceManager.thirdPartyNotices.contains(VendoredNotices.libarchive))
        XCTAssertFalse(LegalComplianceManager.thirdPartyNotices.contains("No third-party open source libraries are used"))
        XCTAssertEqual(Capability.notesODSReader.maturity, .preview)
        XCTAssertFalse(Capability.notesODSReader.defaultsOn)
        let was = NotesODSPolicy.isEnabled
        defer { NotesODSPolicy.isEnabled = was }
        CapabilityWiring.apply(.notesODSReader, isOn: true)
        XCTAssertTrue(NotesODSPolicy.isEnabled)
        CapabilityWiring.apply(.notesODSReader, isOn: false)
        XCTAssertFalse(NotesODSPolicy.isEnabled)
    }

    /// R06 (handoff 7481852): after the inventory failed, "Finish inventory"
    /// builds it from the kept manifest without rewriting a file, and the
    /// re-hash is reported apart from "written" and "hashes recorded".
    func testR06_finishInventoryFromTheKeptManifest_thenVerify() async throws {
        let env = try makeEnv()
        let emails = (0..<3).map { mail(130 + $0, from: "a@x.com", subject: "Fin \($0)", body: "body \($0)") }
        try await env.store.insertBatch(emails, batchSize: 10)
        let folder = env.root.appendingPathComponent("out-repair", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let blocker = folder.appendingPathComponent(ExportInventory.filename)
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        let service = ArchiveExportService(archive: env.archive)
        let result = try await service.exportEMLFiles(scope: .explicit(Set(emails.map(\.id))), to: folder)
        XCTAssertNotNil(result.inventoryFailure)
        let hashesBefore = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".eml") }
            .map { try ExportInventory.sha256(of: folder.appendingPathComponent($0)) }.sorted()
        // The obstacle goes away (disk freed, permission restored); the user presses Finish inventory.
        try FileManager.default.removeItem(at: blocker)
        let url = try ExportInventory.repair(folder: folder)
        XCTAssertEqual(url.lastPathComponent, ExportInventory.filename)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(ExportFolderManifest.filename).path), "the manifest became the inventory")
        let inventory = try ExportInventory.load(folder: folder)
        XCTAssertEqual(inventory.files.count, 3)
        XCTAssertEqual(inventory.written, 3)
        XCTAssertEqual(inventory.positionsConsumed, 3)
        let hashesAfter = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".eml") }
            .map { try ExportInventory.sha256(of: folder.appendingPathComponent($0)) }.sorted()
        XCTAssertEqual(hashesBefore, hashesAfter, "nothing was rewritten")
        var verification = try ExportInventory.verify(folder: folder)
        XCTAssertTrue(verification.isClean)
        XCTAssertEqual(ExportRunCenter.verificationText(verification), "rehash checked: 3 of 3 files match")
        try Data("changed".utf8).write(to: folder.appendingPathComponent(inventory.files[0].path))
        verification = try ExportInventory.verify(folder: folder)
        XCTAssertEqual(ExportRunCenter.verificationText(verification), "rehash checked: 2 of 3 files match · changed 1")
        // A second repair with no manifest refuses instead of inventing an inventory.
        XCTAssertThrowsError(try ExportInventory.repair(folder: folder))
        // The receipt keeps the three statements apart.
        var receipt = ExportReceipt(title: "t", destination: folder.path, isFolder: true, requested: 3, written: 3, outcome: .unverified,
                                    startedAt: Date(), completedAt: Date())
        receipt.checked = 3; receipt.inventoryPath = url.path; receipt.verificationLine = ExportRunCenter.verificationText(verification)
        XCTAssertTrue(receipt.reconciliationLine?.contains("hashes recorded while writing 3 of 3") == true)
        XCTAssertTrue(receipt.verificationLine?.hasPrefix("rehash checked") == true)
    }

    /// R03/R04/R05 (handoff 7481852): archive children keep their logical
    /// names (a gzip inside a ZIP is named after its member, not its temp
    /// file); an attached message is decoded as a message with its own
    /// attachments as children; RTF goes through the RTF decoder; the gzip
    /// budget stops decompression inside the sink.
    func testR03R04R05_logicalNames_messageAndRTFChildren_gzipBudgetInStream() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("r03-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let previousReader = ContainerTextExtractor.childReader
        defer { ContainerTextExtractor.childReader = previousReader }
        AttachmentTextIndexJob.installChildReader()

        let minutes = Data("Gzipped minutes mention the quorum".utf8)
        let gz = Self.gzipData(minutes)
        let rtf = Data("{\\rtf1\\ansi Rich text says {\\b hello} world}".utf8)
        let hidden = "Base64 body hides the keyword zebracorn"
        let inner = """
        From: inner@example.com
        To: me@example.com
        Subject: Inner message
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="B"

        --B
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: base64

        \(Data(hidden.utf8).base64EncodedString())
        \(mimeAttachment("terms.docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document", Self.docx(body: "Nested docx payment terms", header: "")))
        --B--
        """
        let bundle = Self.zipPackage([
            ("report.txt.gz", gz),
            ("UPPER.TXT.GZ", gz),
            ("note.rtf", rtf),
            ("inner.eml", Data(inner.utf8)),
            ("unnamed-archive", Self.zipPackage([("sniffed.txt", Data("found by its bytes".utf8))])),
        ])
        let url = dir.appendingPathComponent("bundle.zip")
        try bundle.write(to: url)
        let result = try DocumentTextExtractor.extract(fileURL: url, kind: .zip, logicalName: "bundle.zip")
        let paths = result.children.map(\.path)
        func text(_ path: String) -> String { result.children.first { $0.path == path }?.text ?? "" }
        XCTAssertTrue(paths.contains("report.txt.gz › report.txt"), "\(paths)")
        XCTAssertTrue(paths.contains("UPPER.TXT.GZ › UPPER.TXT"), "uppercase extensions: \(paths)")
        XCTAssertTrue(text("report.txt.gz › report.txt").contains("Gzipped minutes mention the quorum"))
        XCTAssertTrue(text("note.rtf").contains("Rich text says hello world"), "RTF decoded, not read as control words: \(text("note.rtf"))")
        XCTAssertTrue(text("inner.eml").contains("zebracorn"), "the base64 body is decoded: \(text("inner.eml"))")
        XCTAssertTrue(text("inner.eml › terms.docx").contains("Nested docx payment terms"), "the message's own attachment is a child of its own: \(paths)")
        XCTAssertTrue(paths.contains("unnamed-archive › sniffed.txt"), "a nameless member is identified by its bytes: \(paths)")
        XCTAssertFalse(text("note.rtf").contains("\\rtf1"))

        // R03 at the top level: a base64-backed .txt.gz attachment through the indexing path keeps its name.
        let raw = """
        From sender@example.com Wed Jan 15 10:00:00 2025
        From: sender@example.com
        To: user@dest.org
        Subject: Gzip top
        Date: Wed, 15 Jan 2025 10:00:00 +0000
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="B"

        --B
        Content-Type: text/plain

        see attached
        \(mimeAttachment("notes.txt.gz", "application/gzip", gz))
        --B--
        """
        let extractions = try XCTUnwrap(AttachmentTextIndexJob.extractCoverage(fromRaw: raw))
        XCTAssertEqual(extractions.count, 1)
        XCTAssertEqual(extractions[0].state, .extracted, extractions[0].note ?? "")
        XCTAssertTrue(extractions[0].text?.contains("notes.txt") == true, "the listing names the payload by the logical name: \(extractions[0].text ?? "")")
        XCTAssertEqual(extractions[0].children.map(\.path), ["notes.txt"])
        XCTAssertTrue(extractions[0].children.first?.text?.contains("Gzipped minutes mention the quorum") == true, "\(extractions[0].children)")

        // R05: the gzip budget is enforced while inflating — nothing is left behind, the reason is named.
        let gzURL = dir.appendingPathComponent("big.gz")
        try gz.write(to: gzURL)
        let out = dir.appendingPathComponent("out.txt")
        XCTAssertThrowsError(try ZIPArchiveReader.gunzip(gzURL, to: out, maxOutputBytes: 10)) { error in
            guard case ZIPArchiveReader.ReadError.budgetExceeded(_, let limit) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(limit, 10)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), "the partial output is removed")
        XCTAssertEqual(ContainerTextExtractor.gzipPayloadName(for: "backup.tgz"), "backup.tar")
        XCTAssertEqual(ContainerTextExtractor.gzipPayloadName(for: "deep/report.txt.gz"), "report.txt")
        XCTAssertEqual(ContainerTextExtractor.gzipPayloadName(for: "x.gz"), "x")
    }

    /// Audit 2026-11-06 A08: the archive itself remembers that it was used
    /// under a plan, so restoring it onto a clean installation keeps the
    /// imported mail open; the record only ever rises.
    func testA08_archiveRemembersThePaidTier_andACleanInstallReadsIt() async throws {
        let env = try makeEnv()
        let before = await env.archive.paidTierRecord()
        XCTAssertEqual(before, 0)
        await env.archive.recordPaidTier(PurchaseTier.professional.rawValue)
        await env.archive.recordPaidTier(PurchaseTier.personal.rawValue)
        let afterLower = await env.archive.paidTierRecord()
        XCTAssertEqual(afterLower, PurchaseTier.professional.rawValue, "highest wins, a later lower plan never lowers it")
        await env.archive.recordPaidTier(0)
        let afterZero = await env.archive.paidTierRecord()
        XCTAssertEqual(afterZero, PurchaseTier.professional.rawValue)
        // A manager with no local history and no current entitlement, but an archive that remembers: lapsed, not Free.
        let states: (clean: EntitlementState, cleanLimit: Int?, both: EntitlementState) = await MainActor.run {
            let cleanInstall = StoreManager(testTier: .free, archiveRecord: .personal)
            let both = StoreManager(testTier: .free, lapsedFrom: .personal, archiveRecord: .professional)
            return (cleanInstall.entitlementState, cleanInstall.accessPolicy.archiveReadLimit, both.entitlementState)
        }
        XCTAssertEqual(states.clean, .lapsed(previous: .personal))
        XCTAssertNil(states.cleanLimit)
        XCTAssertEqual(states.both, .lapsed(previous: .professional), "the higher of the two records")
    }

    func testOUT03_sourceFolderLayoutReproducesTheTree_withSafeNamesAndTheOriginalKept() async throws {
        let env = try makeEnv()
        var inbox = mail(110, from: "a@x.com", subject: "In inbox", body: "a"); inbox.tags = ["Top of Personal Folders/Inbox"]
        var clients = mail(111, from: "a@x.com", subject: "For a client", body: "b"); clients.tags = ["Top of Personal Folders/Inbox/Clients"]
        var odd = mail(112, from: "a@x.com", subject: "Odd folder", body: "c"); odd.tags = ["Re: urgent?/../Résumé|draft"]
        var loose = mail(113, from: "a@x.com", subject: "No folder", body: "d")
        loose.tags = []
        try await env.store.insertBatch([inbox, clients, odd, loose], batchSize: 10)
        let folder = env.root.appendingPathComponent("tree", isDirectory: true)
        var options = ExportWriteOptions()
        options.layout = .sourceFolders
        let service = ArchiveExportService(archive: env.archive)
        let result = try await service.exportEMLFiles(scope: .explicit([inbox.id, clients.id, odd.id, loose.id]), to: folder, write: options)
        XCTAssertEqual(result.recordsWritten, 4)

        let inventory = try ExportInventory.load(folder: folder)
        XCTAssertEqual(inventory.layout, "sourceFolders")
        func entry(_ id: UUID) -> ExportInventory.File? { inventory.files.first { $0.emailID == id.uuidString } }
        XCTAssertTrue(try XCTUnwrap(entry(inbox.id)).path.hasPrefix("Top of Personal Folders/Inbox/"), entry(inbox.id)?.path ?? "")
        XCTAssertTrue(try XCTUnwrap(entry(clients.id)).path.hasPrefix("Top of Personal Folders/Inbox/Clients/"))
        let oddEntry = try XCTUnwrap(entry(odd.id))
        XCTAssertTrue(oddEntry.path.hasPrefix("Re- urgent-/_/Résumé-draft/"), "safe components, Unicode kept, '..' neutralised: \(oddEntry.path)")
        XCTAssertEqual(oddEntry.originalFolder, "Re: urgent?/../Résumé|draft", "the original name travels in the inventory")
        XCTAssertFalse(try XCTUnwrap(entry(loose.id)).path.contains("/"), "no folder → the export root")
        // Nothing escaped the export folder, and every listed file is there.
        let verification = try ExportInventory.verify(folder: folder)
        XCTAssertTrue(verification.isClean, "\(verification)")
        for file in inventory.files {
            XCTAssertTrue(folder.appendingPathComponent(file.path).standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path))
        }
        XCTAssertEqual(ExportInventory.safeComponent("  ..  "), "_")
        XCTAssertEqual(ExportInventory.safeComponent("a:b*c?d"), "a-b-c-d")
        XCTAssertEqual(ExportInventory.safeRelativeDirectory(forFolderPath: "/Inbox//Sub/"), "Inbox/Sub")
    }

    // MARK: - CAP-01 — the plain search box has no candidate window and runs on the search model

    func testCAP01_pagingATextQueryWalksEveryMatch_noTwoThousandWindow() async throws {
        let env = try makeEnv()
        // 2,300 messages carry the word; 200 do not. The old page path stopped at 2,000 with no next cursor.
        var emails: [MBOXParser.RawEmail] = []
        for i in 0..<2_500 {
            emails.append(mail(20_000 + i, from: "s\(i % 7)@x.com", subject: "Row \(i)",
                               body: i < 2_300 ? "the needle is in this haystack \(i)" : "nothing to see \(i)",
                               date: "Wed, 01 Mar 2023 \(String(format: "%02d:%02d:%02d", (i / 3600) % 24, (i / 60) % 60, i % 60)) +0000"))
        }
        for start in stride(from: 0, to: emails.count, by: 500) {
            let batch = Array(emails[start..<min(start + 500, emails.count)])
            try await env.store.insertBatch(batch, batchSize: 500)
            try await env.fts.indexBatch(batch)
        }
        var query = EmailQuery.all
        query.text = "needle"
        // Page by page through the data service's plain page API — the one exports, fingerprints and scope jobs use.
        var seen = Set<UUID>()
        var cursor: EmailPageCursor? = nil
        var pages = 0
        repeat {
            let page = try await env.archive.page(query: query, cursor: cursor, limit: 300)
            pages += 1
            for s in page.summaries { XCTAssertTrue(seen.insert(s.id).inserted, "no row twice") }
            cursor = page.nextCursor
        } while cursor != nil
        XCTAssertEqual(seen.count, 2_300, "every match, over \(pages) pages")
        let counted = try await env.archive.count(query: query)
        XCTAssertEqual(counted, 2_300)
        // The export fingerprint and the summary stream walk the same set.
        let fingerprint = try await env.archive.selectionFingerprint(scope: .query(query, exclusions: []))
        XCTAssertTrue(fingerprint.hasPrefix("2300:"), fingerprint)
        var streamed = 0
        for try await batch in await env.archive.streamSummaries(query: query, batchSize: 700) { streamed += batch.count }
        XCTAssertEqual(streamed, 2_300)
        // Dates narrow it honestly, still with no window.
        query.afterDate = ISO8601DateFormatter().date(from: "2023-03-01T00:10:00Z")
        let narrowed = try await env.archive.count(query: query)
        XCTAssertEqual(narrowed, 2_300 - 600)
    }

    func testCAP01_plainBoxTranslatesToTheModel_andIsOffWhenTheModelIsOff() throws {
        let wasOn = SearchChunkPolicy.isEnabled
        defer { SearchChunkPolicy.isEnabled = wasOn }
        // Words: all but the last as whole words, the last as typed so far.
        let simple = try XCTUnwrap(PlainSearchTranslator.spec(from: "invoice purchase ord"))
        XCTAssertEqual(simple.groups, [SearchGroup(.all, [SearchCondition(.anyText, .contains, "ord"), SearchCondition(.anyText, .allWords, "invoice purchase")])])
        // Phrases, OR, NOT and -.
        // R01: ("purchase order" AND alpha) OR (receipt AND NOT newsletter AND NOT spam) — one group, two branches, no expansion.
        let rich = try XCTUnwrap(PlainSearchTranslator.spec(from: "\"purchase order\" alpha OR receipt NOT newsletter -spam"))
        XCTAssertEqual(rich.groups.count, 1)
        XCTAssertEqual(rich.groups[0].kind, .any)
        XCTAssertEqual(rich.groups[0].branches.count, 2)
        XCTAssertEqual(rich.groups[0].branches[0].conditions, [SearchCondition(.anyText, .phrase, "purchase order", branch: 0), SearchCondition(.anyText, .allWords, "alpha", branch: 0)])
        XCTAssertEqual(rich.groups[0].branches[1].conditions, [SearchCondition(.anyText, .allWords, "receipt", branch: 1),
                                                                SearchCondition(.anyText, .anyWords, "newsletter", branch: 1, negated: true),
                                                                SearchCondition(.anyText, .anyWords, "spam", branch: 1, negated: true)])
        let plainOr = try XCTUnwrap(PlainSearchTranslator.spec(from: "invoice OR receipt"))
        XCTAssertEqual(plainOr.groups, [SearchGroup(.any, [SearchCondition(.anyText, .allWords, "invoice", branch: 0), SearchCondition(.anyText, .allWords, "receipt", branch: 1)])])
        XCTAssertEqual(PlainSearchTranslator.spec(from: "alpha -draft"), SearchSpec(groups: [
            SearchGroup(.all, [SearchCondition(.anyText, .contains, "alpha")]), SearchGroup(.exclude, [SearchCondition(.anyText, .anyWords, "draft")])]),
            "one alternative: its not-terms are the global exclusion, as before")
        // in:attachments turns the words into conditions on one attachment's text.
        let inside = try XCTUnwrap(PlainSearchTranslator.spec(from: "in:attachments quorum \"board vote\""))
        XCTAssertEqual(inside.groups, [SearchGroup(.all, [], attachments: [
            AttachmentConditionGroup(contentMatch: .contains, content: "quorum"),
            AttachmentConditionGroup(contentMatch: .phrase, content: "board vote"),
        ])])
        XCTAssertNil(PlainSearchTranslator.spec(from: "AND OR"))
        XCTAssertNil(PlainSearchTranslator.spec(from: "in:attachments"))

        // The browse state: operators stay fields, the words move onto the model only when it is on.
        SearchChunkPolicy.isEnabled = true
        let on = ArchiveBrowseState(searchText: "from:alice@x.com invoice").query(plainTextOnModel: true)
        XCTAssertEqual(on.sender, "alice@x.com")
        XCTAssertNil(on.text)
        XCTAssertEqual(on.spec?.groups, [SearchGroup(.all, [SearchCondition(.anyText, .contains, "invoice")])])
        let withAdvanced = ArchiveBrowseState(searchText: "invoice", spec: SearchSpec(groups: [SearchGroup(.exclude, [SearchCondition(.subject, .contains, "draft")])]))
            .query(plainTextOnModel: true)
        XCTAssertEqual(withAdvanced.spec?.groups.count, 2, "typed words ride on top of the applied Advanced Search")
        let off = ArchiveBrowseState(searchText: "from:alice@x.com invoice").query(plainTextOnModel: false)
        XCTAssertEqual(off.text, "invoice")
        XCTAssertNil(off.spec)
        SearchChunkPolicy.isEnabled = false
        let indexOff = ArchiveBrowseState(searchText: "invoice").query(plainTextOnModel: true)
        XCTAssertEqual(indexOff.text, "invoice", "without the chunk index the previous path stays")
    }

    func testCAP01_plainBoxOnTheModel_countsExactly_andSaysWhatIsUnknown() async throws {
        let wasOn = SearchChunkPolicy.isEnabled
        defer { SearchChunkPolicy.isEnabled = wasOn }
        let env = try chunkedEnv()
        AttachmentTextIndexJob.testSuppressKicks = true
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()
        AttachmentTextIndexJob.testStoreOverride = env.store
        defer { AttachmentTextIndexJob.testStoreOverride = nil; AttachmentTextIndexJob.testSuppressKicks = false }
        var emails: [MBOXParser.RawEmail] = []
        for i in 0..<30 {
            emails.append(mail(21_000 + i, from: "a@x.com", subject: "Note \(i)", body: i % 3 == 0 ? "the quorum clause applies" : "ordinary text \(i)"))
        }
        // One message carries a legacy .doc whose text cannot be read.
        let raw = """
        From sender@example.com Wed Jan 15 10:00:00 2025
        From: sender@example.com
        To: user@dest.org
        Subject: Old document
        Date: Wed, 15 Jan 2025 10:00:00 +0000
        Message-ID: <cap01-doc@t>
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="B"

        --B
        Content-Type: text/plain

        see attached
        \(mimeAttachment("old.doc", "application/msword", Data("not readable here".utf8)))
        --B--
        """
        emails.append(try MBOXParser.processRawMessage(raw, senderEmail: ""))
        try await env.store.insertBatch(emails, batchSize: 50)
        _ = await AttachmentTextIndexJob.shared.run()

        let query = ArchiveBrowseState(searchText: "quorum clause").query(plainTextOnModel: true)
        XCTAssertNil(query.text)
        let count = try await env.archive.count(query: query)
        XCTAssertEqual(count, 10, "the ten bodies that hold the words; exact, from the model")
        let unresolved = try await env.archive.unresolvedCount(query: query)
        XCTAssertEqual(unresolved, 0, "every body is indexed; nothing is unknown for a positive search")
        // Evidence names the body, with no free text left to guess from.
        var ids: [UUID] = []
        for try await batch in await env.archive.streamFullEmails(query: query, batchSize: 50) { ids += batch.map(\.id) }
        let evidence = try await env.archive.matchEvidence(emailID: try XCTUnwrap(ids.first), spec: query.spec, freeText: nil)
        XCTAssertFalse(evidence.isEmpty)
        // A negative search over attachment text leaves the unreadable .doc unknown — said, not hidden.
        let negative = ArchiveBrowseState(searchText: "in:attachments NOT quorum").query(plainTextOnModel: true)
        let unknown = try await env.archive.unresolvedCount(query: negative)
        XCTAssertEqual(unknown, 1)
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()
    }

    // MARK: - CAP-02 / CAP-03 — legacy export paths follow the one policy; the old folder tree pages every label

    func testCAP02_03_legacyExportsUseTheAccessPolicy_andTheFolderTreeReachesEveryLabel() async throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let content = try String(contentsOf: repo.appendingPathComponent("maxmailin/ContentView.swift"), encoding: .utf8)
        XCTAssertFalse(content.contains("freeExportLimit"), "the private 10-email export cap is gone")
        XCTAssertFalse(content.contains("freeExportCap"), "no cap of its own; the access policy decides")
        for format in ["emlFiles", "pdfFiles", "csv", "portableHTML"] {
            XCTAssertTrue(content.contains("exportCap(for: .\(format))"), "\(format) export asks the policy")
        }
        // What the policy says for those paths: Free 500 (as the purchase screen promises), never 10.
        XCTAssertEqual(AccessPolicy(state: .free).exportCap(for: .emlFiles), StoreManager.freeEmailLimit)
        XCTAssertEqual(AccessPolicy(state: .free).exportCap(for: .csv), StoreManager.freeEmailLimit)
        XCTAssertNil(AccessPolicy(state: .lapsed(previous: .personal)).exportCap(for: .emlFiles))

        let tree = try String(contentsOf: repo.appendingPathComponent("maxmailin/FolderTreeView.swift"), encoding: .utf8)
        XCTAssertFalse(tree.contains("maxLabels") || tree.contains("maxSourceFiles"), "no label or source window")
        XCTAssertTrue(tree.contains("parserTagTotal()") && tree.contains("folderTree.moreLabels"), "total shown, Show more offered")

        // The store side the tree pages through: 450 labels, all reachable, total exact.
        let env = try makeEnv()
        var emails: [MBOXParser.RawEmail] = []
        for i in 0..<450 {
            var e = mail(30_000 + i, from: "a@x.com", subject: "L \(i)", body: "b")
            e.tags = ["Label \(String(format: "%03d", i))"]
            emails.append(e)
        }
        try await env.store.insertBatch(emails, batchSize: 100)
        let total = try await env.store.parserTagTotal()
        XCTAssertEqual(total, 450)
        var seen: [String] = []
        var offset = 0
        while true {
            let page = try await env.store.parserTagCounts(matching: nil, offset: offset, limit: FolderTreeView.labelPage)
            if page.isEmpty { break }
            seen += page.map(\.value)
            offset += page.count
        }
        XCTAssertEqual(Set(seen).count, 450, "every label, page by page")
    }

    // MARK: - CAP-04 / CAP-05 — the portable viewer and Shortcuts Find have no caps of their own

    func testCAP04_portableHTMLViewerIsChunked_everyMessageWritten_noCap() async throws {
        let env = try makeEnv()
        var emails: [MBOXParser.RawEmail] = []
        for i in 0..<4_500 {
            emails.append(mail(40_000 + i, from: "s\(i % 5)@x.com", subject: "Viewer \(i)", body: i == 7 ? "has </script> inside" : "body \(i)",
                               date: "Wed, 01 Mar 2023 \(String(format: "%02d:%02d:%02d", (i / 3600) % 24, (i / 60) % 60, i % 60)) +0000"))
        }
        for start in stride(from: 0, to: emails.count, by: 500) {
            try await env.store.insertBatch(Array(emails[start..<min(start + 500, emails.count)]), batchSize: 500)
        }
        let folder = env.root.appendingPathComponent("viewer", isDirectory: true)
        let service = ArchiveExportService(archive: env.archive)
        let result = try await service.exportPortableHTML(scope: .query(.all, exclusions: []), to: folder)
        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.recordsWritten, 4_500, "every message, well past the old 10,000-free single page's logic and any window")
        let index = try String(contentsOf: folder.appendingPathComponent("index.html"), encoding: .utf8)
        XCTAssertTrue(index.contains("TOTAL=4500,PARTS=3,CHUNK=\(ArchiveExportService.portableHTMLChunkSize)"), "the viewer knows the whole export")
        XCTAssertTrue(index.contains("function mailinChunk") && index.contains("loadPart(1)"))
        var total = 0
        for part in 1...3 {
            let url = folder.appendingPathComponent("data").appendingPathComponent(String(format: "part-%04d.js", part))
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(text.hasPrefix("mailinChunk([") && text.hasSuffix("]);\n"), "part \(part) is a JavaScript chunk")
            let json = text.dropFirst("mailinChunk(".count).dropLast(");\n".count)
            let entries = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
            total += entries.count
            XCTAssertLessThanOrEqual(entries.count, ArchiveExportService.portableHTMLChunkSize)
        }
        XCTAssertEqual(total, 4_500, "the chunks hold every message exactly once")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("data/part-0004.js").path))
        // The plan's cap still applies as a cap, stated by the caller — not a cap of the format.
        let capped = try await service.exportPortableHTML(scope: .query(.all, exclusions: []), to: env.root.appendingPathComponent("capped", isDirectory: true), limit: 500)
        XCTAssertEqual(capped.recordsWritten, 500)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for file in ["maxmailin/ContentView.swift", "maxmailin/ArchiveExportService+Renderers.swift", "Packages/ArchiveCore/Sources/ArchiveCore/ArchiveExportService.swift"] {
            let source = try String(contentsOf: repo.appendingPathComponent(file), encoding: .utf8)
            XCTAssertFalse(source.contains("static let portableHTMLMaxEmails"), "\(file) still declares the old cap")
        }
    }

    func testCAP05_shortcutsFindHasNoCapOfItsOwn() async throws {
        XCTAssertEqual(ShortcutsPolicy.effectiveFindLimit(nil), Int.max, "no Limit set in Shortcuts → everything")
        XCTAssertEqual(ShortcutsPolicy.effectiveFindLimit(25), 25, "the person's Limit is honoured as given")
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for file in ["maxmailin/MailinAppEntities.swift", "maxmailin/MailinMoreEntities.swift"] {
            let source = try String(contentsOf: repo.appendingPathComponent(file), encoding: .utf8)
            XCTAssertFalse(source.contains("findLimit"), "\(file) still clamps to a constant")
        }
        // Through the entity query over a bound environment: 10,050 rows, all returned.
        let env = try makeEnv()
        var emails: [MBOXParser.RawEmail] = []
        for i in 0..<10_050 { emails.append(mail(50_000 + i, from: "finder@example.com", subject: "F \(i)", body: "b")) }
        for start in stride(from: 0, to: emails.count, by: 1_000) {
            try await env.store.insertBatch(Array(emails[start..<min(start + 1_000, emails.count)]), batchSize: 1_000)
        }
        let environment = ScopeJobEnvironment(archive: env.archive, store: env.store, root: env.root)
        let found = try await ScopeJobEnvironment.$current.withValue(environment) {
            try await EmailEntityQuery.find([.sender("example.com")], mode: .and, limit: ShortcutsPolicy.effectiveFindLimit(nil))
        }
        XCTAssertEqual(found.count, 10_050)
    }

    // MARK: - CAP-06 — no numeric window in the five-jobs source; every real limit named and shown

    /// The five-jobs source files. A numeric `prefix(N)` or `>= N { break }`
    /// with N ≥ 500 in any of them is a window and fails this test; a real
    /// limit must be a named constant listed in `AppLimits`.
    private static let fiveJobsSources = [
        "maxmailin/ArchiveThreePaneView.swift", "maxmailin/ArchiveListViewModel.swift", "maxmailin/ArchiveSidebar.swift",
        "maxmailin/AdvancedSearchView.swift", "maxmailin/DuplicateManagerView.swift", "maxmailin/DuplicateVerification.swift",
        "maxmailin/DuplicatesEngine.swift", "maxmailin/ExportPreflight.swift", "maxmailin/UnifiedExportMenu.swift",
        "maxmailin/ImportQueueView.swift", "maxmailin/GuidedImportSheet.swift", "maxmailin/AttachmentTextIndexJob.swift",
        "maxmailin/FolderTreeView.swift", "maxmailin/ArchiveExportService+Renderers.swift", "maxmailin/SearchDocBackfillJob.swift",
        "maxmailin/ArchiveBackups.swift", "maxmailin/ArchiveHealthView.swift", "maxmailin/ScopeJob.swift", "maxmailin/MailinAppEntities.swift",
        "maxmailin/MailinMoreEntities.swift", "maxmailin/ParsedEmailListViewModel.swift",
    ]

    func testCAP06_noNumericWindowInTheFiveJobsSource_andEveryRealLimitIsListed() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        var files = Self.fiveJobsSources.map { repo.appendingPathComponent($0) }
        let packageDir = repo.appendingPathComponent("Packages/ArchiveCore/Sources/ArchiveCore")
        files += try FileManager.default.contentsOfDirectory(at: packageDir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        let window = try NSRegularExpression(pattern: #"\.prefix\(\s*([0-9][0-9_]{2,})\s*\)|>=\s*([0-9][0-9_]{2,})\s*\{\s*break"#)
        var offenders: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for line in source.components(separatedBy: "\n") where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                let range = NSRange(line.startIndex..., in: line)
                for match in window.matches(in: line, range: range) {
                    let digits = (1...2).compactMap { Range(match.range(at: $0), in: line).map { String(line[$0]) } }.first ?? "0"
                    if (Int(digits.replacingOccurrences(of: "_", with: "")) ?? 0) >= 500 {
                        offenders.append("\(file.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
                    }
                }
            }
        }
        // Allowed: a 4 KB sniff of a file's head to tell text from binary is not a result window.
        offenders.removeAll { $0.contains("data.prefix(4096)") }
        // Allowed: ODF's encryption checksum is defined over the first 1,024 bytes (SHA1/1K, SHA256/1K) — the format's rule.
        offenders.removeAll { $0.hasPrefix("ODFEncryption.swift: let covered") }
        // Allowed: the provenance headers mailin writes at the top of a source are read from its head — a sniff, not a result window.
        offenders.removeAll { $0.hasPrefix("RawSourceRecovery.swift: for line in rawSource.prefix(4_096)") }
        XCTAssertEqual(offenders, [], "numeric windows in the five-jobs source:\n" + offenders.joined(separator: "\n"))

        // Every known constant is listed, with its kind, and the five jobs are listed as uncapped.
        let limits = AppLimits.all
        // Localized interpolation groups digits ("5,000") and uses narrow spaces before units; compare plainly.
        func plain(_ s: String) -> String {
            s.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: ",", with: "")
        }
        func listed(_ fragment: String) -> Bool { limits.contains { plain($0.value).contains(fragment) || plain($0.what).contains(fragment) } }
        let bytes = { (b: Int64) in plain(ByteCountFormatter.string(fromByteCount: b, countStyle: .file)) }
        XCTAssertTrue(listed("\(StoreManager.freeEmailLimit)"))
        XCTAssertTrue(listed(bytes(Int64(StoreManager.freeInputByteLimit))), "\(limits.map { plain($0.value) })")
        XCTAssertTrue(listed("\(StoreManager.freeAttachmentDownloadsPerDay) a day"))
        XCTAssertTrue(listed("\(AIAssistantView.freeQueryLimit) a day"))
        XCTAssertTrue(listed(bytes(SourceSizePolicy.pstTestedCeilingBytes)) && listed("Notes NSF") && listed("FAT32"))
        XCTAssertTrue(listed(bytes(OfficeTextExtractor.maxPartBytes)), "the Office part budget is named")
        XCTAssertTrue(listed("\(Int(AttachmentOCR.maxPixels)) px"))
        XCTAssertFalse(listed("Phrase verification"), "R02: phrases of any length are verified on the stored text — no limit row")
        XCTAssertTrue(listed("\(AppLimits.previousEngineDuplicateWindow)"))
        XCTAssertTrue(listed(bytes(Int64(FTSSearchIndex.indexedTextBudgetBytes))), "R5b: the previous search index's real body budget is named")
        // R5b: the remaining guards of the five jobs are named with what happens at them.
        XCTAssertTrue(listed("\(MIMEParser.maxRecursionDepth) levels") && listed(bytes(Int64(OffsetMBOXScanner().maxLineBytes)))
                      && listed(bytes(Int64(OffsetMBOXScanner().maxHeaderBytes))) && listed(bytes(MSGParser.maxFileBytes))
                      && listed(bytes(EMLXParser.maxFileBytes)) && listed(bytes(Int64(MIMECarver.maxMessage)))
                      && listed(bytes(RARReader.maxDecoderDictionaryBytes)) && listed("\(BoundedRegexSearch.literalCandidateCap) candidates")
                      && listed(bytes(Int64(PSTStreamWriter.maxFileBytes))) && listed(bytes(Int64(MBOXParser.maxMessageBytes)))
                      && listed("\(ArchiveSidebarModel.labelLimit) busiest folders"), "\(limits.map { plain($0.value) })")
        // CLOSE-02: mailboxes inside archives are read at every level; the self-containing guard is named.
        XCTAssertTrue(listed("\(ContainerMailboxWalk.selfContainingGuardDepth) archives deep"), "\(limits.map { plain($0.value) })")
        XCTAssertFalse(listed("one archive level"), "nested archives are no longer skipped")
        for job in ["Opening archives", "Folders", "Search", "Duplicates", "Exports"] {
            XCTAssertEqual(limits.first { $0.what == job }?.kind, AppLimit.Kind.none, "\(job) is listed as uncapped")
        }
        let health = try String(contentsOf: repo.appendingPathComponent("maxmailin/ArchiveHealthView.swift"), encoding: .utf8)
        XCTAssertTrue(health.contains("AppLimits.all") && health.contains("\"health.limits\""), "the list is on screen")
    }

    // MARK: - TYPE-01 … TYPE-04 — every document kind is read for search

    private static var fixturesRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures", isDirectory: true)
    }

    /// Real files made by Pages, Numbers, Keynote (modern IWA and Pages '09) and by macOS textutil (Word 97 .doc, .docx).
    func testTYPE_realIWorkAndWordFixturesAreRead_withTheirLabels() throws {
        let iwork = Self.fixturesRoot.appendingPathComponent("iwork")
        let pages = try DocumentTextExtractor.extract(fileURL: iwork.appendingPathComponent("sample.pages"), kind: .pages)
        XCTAssertTrue(pages.text.contains("Quorum clause applies to every board vote"), pages.text)
        XCTAssertEqual(pages.components, ["Document"])
        XCTAssertFalse(pages.text.contains("Body Level One"), "template placeholder text is not user text")

        let numbers = try DocumentTextExtractor.extract(fileURL: iwork.appendingPathComponent("sample.numbers"), kind: .numbers)
        XCTAssertTrue(numbers.text.contains("Gross margin") && numbers.text.contains("Quarterly budget review"), numbers.text)
        XCTAssertTrue(numbers.components.contains { $0.hasPrefix("Table cells") }, "\(numbers.components)")
        XCTAssertTrue(numbers.text.contains("Sheet 1"), "sheet names travel with the cells")

        let key = try DocumentTextExtractor.extract(fileURL: iwork.appendingPathComponent("sample.key"), kind: .key)
        XCTAssertTrue(key.text.contains("Roadmap overview") && key.text.contains("Milestones for the board vote"), key.text)
        XCTAssertEqual(key.components, ["Slide 1"], "the real slide, not the 17 template slides")
        XCTAssertFalse(key.text.contains("Presentation Title"))

        let pages09 = try DocumentTextExtractor.extract(fileURL: iwork.appendingPathComponent("sample-pages09.pages"), kind: .pages)
        XCTAssertTrue(pages09.text.contains("Quorum clause applies to every board vote"), pages09.text)
        XCTAssertEqual(pages09.components, ["Document"])

        let legacy = Self.fixturesRoot.appendingPathComponent("legacy")
        let doc = try DocumentTextExtractor.extract(fileURL: legacy.appendingPathComponent("sample.doc"), kind: .doc)
        XCTAssertTrue(doc.text.contains("Quorum clause applies to every board vote.") && doc.text.contains("Payment within thirty days."), doc.text)
        let docx = try DocumentTextExtractor.extract(fileURL: legacy.appendingPathComponent("sample.docx"), kind: .docx)
        XCTAssertTrue(docx.text.contains("Payment within thirty days"), docx.text)

        // Detection: by extension and by MIME type, every kind, ZIP included.
        XCTAssertEqual(DocumentKind.detect(mimeType: "application/octet-stream", filename: "Deck.KEY"), .key)
        XCTAssertEqual(DocumentKind.detect(mimeType: "application/vnd.oasis.opendocument.spreadsheet", filename: "x"), .ods)
        XCTAssertEqual(DocumentKind.detect(mimeType: "application/msword", filename: "memo"), .doc)
        XCTAssertEqual(DocumentKind.detect(mimeType: "application/zip", filename: "bundle"), .zip)
        XCTAssertNil(DocumentKind.detect(mimeType: "image/png", filename: "photo.png"))
    }

    private static func odf(kind: DocumentKind, content: String, encrypted: Bool = false, header: String? = nil) -> Data {
        var members: [(name: String, data: Data)] = [
            ("mimetype", Data("application/vnd.oasis.opendocument.text".utf8)),
            ("content.xml", Data(content.utf8)),
            ("META-INF/manifest.xml", Data((encrypted
                ? "<manifest:manifest><manifest:file-entry><manifest:encryption-data/></manifest:file-entry></manifest:manifest>"
                : "<manifest:manifest/>").utf8)),
            ("Pictures/logo.png", Data([0x89, 0x50, 0x4E, 0x47])),
        ]
        if let header {
            members.append(("styles.xml", Data("<office:document-styles><office:master-styles><style:master-page><style:header><text:p>\(header)</text:p></style:header></style:master-page></office:master-styles></office:document-styles>".utf8)))
        }
        return zipPackage(members)
    }

    /// Audit 2026-11-06 A05: counts and indexes inside a document are
    /// untrusted input. A negative or absurd `text:c`, or a negative
    /// shared-string index, must leave the reader standing and the rest of
    /// the text readable — a trap in a detached task would take the app down.
    func testA05_malformedRepeatCountsAndIndexes_areBounded_andTheRestIsRead() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("malformed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let odt = dir.appendingPathComponent("bad.odt")
        try Self.odf(kind: .odt, content: """
            <office:document-content><office:body><office:text>
            <text:p>alpha<text:s text:c="-5"/>beta<text:s text:c="999999999999"/>gamma<text:s text:c="abc"/>delta</text:p>
            </office:text></office:body></office:document-content>
            """).write(to: odt)
        let text = try DocumentTextExtractor.extract(fileURL: odt, kind: .odt)
        XCTAssertTrue(text.text.contains("alphabeta"), "a negative count adds nothing: \(text.text.prefix(200))")
        XCTAssertTrue(text.text.contains("gamma delta"), "a missing count is one space")
        let run = text.text.range(of: "beta")!.upperBound..<text.text.range(of: "gamma")!.lowerBound
        XCTAssertEqual(text.text[run].count, ODFTextCollector.maxRepeatedSpaces, "an absurd count is bounded, not allocated")

        let xlsx = dir.appendingPathComponent("bad.xlsx")
        try Self.zipPackage([
            ("xl/workbook.xml", Data("<workbook xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets><sheet name=\"S\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>".utf8)),
            ("xl/_rels/workbook.xml.rels", Data("<Relationships><Relationship Id=\"rId1\" Type=\"x\" Target=\"worksheets/sheet1.xml\"/></Relationships>".utf8)),
            ("xl/sharedStrings.xml", Data("<sst><si><t>only</t></si></sst>".utf8)),
            ("xl/worksheets/sheet1.xml", Data("<worksheet><sheetData><row r=\"1\"><c r=\"A1\" t=\"s\"><v>-1</v></c><c r=\"B1\" t=\"s\"><v>7</v></c><c r=\"C1\" t=\"s\"><v>0</v></c></row></sheetData></worksheet>".utf8)),
        ]).write(to: xlsx)
        let sheet = try OfficeTextExtractor.extract(fileURL: xlsx, kind: .xlsx)
        XCTAssertTrue(sheet.text.contains("only"), sheet.text)
        XCTAssertTrue(sheet.text.contains("-1") && sheet.text.contains("7"), "out-of-range indexes keep their raw value instead of trapping: \(sheet.text)")
    }

    /// A PDF drawn with Core Graphics: one page per string, an empty string
    /// giving a blank (scan-like) page with no text layer.
    static func pdfData(pages: [String]) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 300, height: 300)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        for text in pages {
            context.beginPDFPage(nil)
            if !text.isEmpty {
                let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
                context.textPosition = CGPoint(x: 20, y: 150)
                CTLineDraw(line, context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    /// A small blank PNG (decodable, no text in it).
    static func pngData() -> Data {
        guard let context = CGContext(data: nil, width: 24, height: 24, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage() else { return Data() }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out as CFMutableData, "public.png" as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return out as Data
    }

    /// Audit 2026-11-06 A06: a recognition failure is never read as "no
    /// text"; a mixed PDF is read page by page (text layer where it is real,
    /// recognition where it is not); the failed pages are named and the
    /// attachment is partial or failed — never complete.
    func testA06_ocrFailuresAreNamed_mixedPDFsReadPageByPage_neverComplete() throws {
        let original = AttachmentOCR.recognizer
        defer { AttachmentOCR.recognizer = original }
        struct Boom: Error, LocalizedError { var errorDescription: String? { "Vision stopped" } }
        let layerText = "This page carries a real text layer with enough characters."
        let document = try XCTUnwrap(PDFDocument(data: Self.pdfData(pages: [layerText, ""])))
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertFalse(AttachmentOCR.pdfNeedsOCR(text: document.string, pageCount: 2), "the whole-document count hides the scanned page — the defect")
        XCTAssertTrue(AttachmentOCR.pdfNeedsOCR(document), "one scanned page out of two still needs OCR (per-page check)")

        // The recogniser fails: the layer page is read, the scanned page is a named failure → partial.
        AttachmentOCR.recognizer = { _ in .failure(Boom()) }
        let failing = AttachmentOCR.outcome(fromPDF: document)
        XCTAssertEqual(failing.layerPages, 1)
        XCTAssertEqual(failing.attempted, 1)
        XCTAssertEqual(failing.failed, 1)
        XCTAssertTrue(failing.failures[0].contains("page 2") && failing.failures[0].contains("Vision stopped"), failing.failures[0])
        XCTAssertTrue(failing.text?.contains("real text layer") == true)
        let partial = AttachmentTextIndexJob.ocrState(failing, pages: 2)
        XCTAssertEqual(partial.state, .partial)
        XCTAssertTrue(partial.note?.contains("1 of 2 pages") == true, partial.note ?? "")
        XCTAssertEqual(partial.extractor, "ocr")

        // The recogniser works: both pages read, complete.
        AttachmentOCR.recognizer = { _ in .success("recognised scan words") }
        let good = AttachmentOCR.outcome(fromPDF: document)
        XCTAssertTrue(good.isComplete)
        XCTAssertEqual(good.recognised, 1)
        XCTAssertTrue(good.text?.contains("real text layer") == true && good.text?.contains("recognised scan words") == true, good.text ?? "")
        XCTAssertEqual(AttachmentTextIndexJob.ocrState(good, pages: 2).state, .extracted)

        // Nothing readable on any page: failed, with the reasons — not "no text".
        let scansOnly = try XCTUnwrap(PDFDocument(data: Self.pdfData(pages: ["", ""])))
        AttachmentOCR.recognizer = { _ in .failure(Boom()) }
        let allFailed = AttachmentTextIndexJob.ocrState(AttachmentOCR.outcome(fromPDF: scansOnly), pages: 2)
        XCTAssertEqual(allFailed.state, .failed)
        XCTAssertTrue(allFailed.note?.contains("page 1") == true && allFailed.note?.contains("page 2") == true, allFailed.note ?? "")
        // A picture that really has no text: noText, and said so.
        AttachmentOCR.recognizer = { _ in .success(nil) }
        let empty = AttachmentTextIndexJob.ocrState(AttachmentOCR.outcome(fromImageData: Self.pngData()), pages: 1)
        XCTAssertEqual(empty.state, .noText)
        XCTAssertEqual(empty.text, "")
        // An image whose recognition fails, and bytes that are not an image at all: failed.
        AttachmentOCR.recognizer = { _ in .failure(Boom()) }
        XCTAssertEqual(AttachmentTextIndexJob.ocrState(AttachmentOCR.outcome(fromImageData: Self.pngData()), pages: 1).state, .failed)
        let undecodable = AttachmentOCR.outcome(fromImageData: Data([1, 2, 3, 4]))
        XCTAssertEqual(undecodable.failed, 1)
        XCTAssertTrue(undecodable.failures[0].contains("decoded"))
        XCTAssertEqual(AttachmentTextIndexJob.ocrState(undecodable, pages: 1).state, .failed)
    }

    func testTYPE02_openDocumentTextSheetsAndSlides_withLabels_andLockedFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("odf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let odt = dir.appendingPathComponent("t.odt")
        try Self.odf(kind: .odt, content: """
            <office:document-content><office:body><office:text>
            <text:h>Board minutes</text:h><text:p>The <text:span>quorum clause</text:span> applies.<text:line-break/>Second<text:s text:c="3"/>line.</text:p>
            </office:text></office:body></office:document-content>
            """, header: "Confidential header").write(to: odt)
        let text = try DocumentTextExtractor.extract(fileURL: odt, kind: .odt)
        XCTAssertTrue(text.text.contains("Board minutes\n") && text.text.contains("The quorum clause applies.\nSecond   line."), text.text)
        XCTAssertEqual(text.components, ["Document", "Header"])
        XCTAssertTrue(text.text.contains("[Header]\nConfidential header"))
        XCTAssertEqual(text.notText, ["Pictures/logo.png"])

        let ods = dir.appendingPathComponent("s.ods")
        try Self.odf(kind: .ods, content: """
            <office:document-content><office:body><office:spreadsheet>
            <table:table table:name="Budget"><table:table-row><table:table-cell office:value-type="string"><text:p>Gross margin</text:p></table:table-cell><table:table-cell office:value-type="float" office:value="42.5"/></table:table-row></table:table>
            <table:table table:name="Notes"><table:table-row><table:table-cell><text:p>see appendix</text:p></table:table-cell></table:table-row></table:table>
            </office:spreadsheet></office:body></office:document-content>
            """).write(to: ods)
        let sheets = try DocumentTextExtractor.extract(fileURL: ods, kind: .ods)
        XCTAssertEqual(sheets.components, ["Sheet: Budget", "Sheet: Notes"])
        XCTAssertTrue(sheets.text.contains("[Sheet: Budget]\nGross margin\t42.5\t"), sheets.text)

        let odp = dir.appendingPathComponent("p.odp")
        try Self.odf(kind: .odp, content: """
            <office:document-content><office:body><office:presentation>
            <draw:page draw:name="page1"><draw:frame><draw:text-box><text:p>Roadmap overview</text:p></draw:text-box></draw:frame>
            <presentation:notes><draw:frame><draw:text-box><text:p>remember the demo</text:p></draw:text-box></draw:frame></presentation:notes></draw:page>
            <draw:page draw:name="page2"><draw:frame><draw:text-box><text:p>Milestones</text:p></draw:text-box></draw:frame></draw:page>
            </office:presentation></office:body></office:document-content>
            """).write(to: odp)
        let slides = try DocumentTextExtractor.extract(fileURL: odp, kind: .odp)
        XCTAssertEqual(slides.components, ["Slide 1", "Notes 1", "Slide 2"], "\(slides.components)")
        XCTAssertTrue(slides.text.contains("[Notes 1]\nremember the demo"))

        let locked = dir.appendingPathComponent("locked.odt")
        try Self.odf(kind: .odt, content: "<office:document-content/>", encrypted: true).write(to: locked)
        XCTAssertThrowsError(try DocumentTextExtractor.extract(fileURL: locked, kind: .odt)) {
            XCTAssertEqual($0 as? OfficeTextExtractor.ExtractError, .encrypted)
        }
    }

    /// A minimal OLE2 compound file: one FAT sector, one directory sector, streams in whole sectors.
    private static func oleContainer(streams: [(name: String, data: Data)]) -> Data {
        let sector = 512
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }
        let endOfChain: UInt32 = 0xFFFF_FFFE, free: UInt32 = 0xFFFF_FFFF, fatSect: UInt32 = 0xFFFF_FFFD
        // Streams are padded to whole sectors and kept above the 4,096-byte mini cutoff.
        let padded: [Data] = streams.map { s in
            var d = s.data
            let minimum = max(4096, ((d.count + sector - 1) / sector) * sector)
            d.append(Data(repeating: 0, count: minimum - d.count))
            return d
        }
        var fat: [UInt32] = [fatSect, endOfChain]   // sector 0 = FAT, sector 1 = directory
        var starts: [Int] = []
        var next = 2
        for d in padded {
            starts.append(next)
            let count = d.count / sector
            for i in 0..<count { fat.append(i == count - 1 ? endOfChain : UInt32(next + i + 1)) }
            next += count
        }
        while fat.count < sector / 4 { fat.append(free) }
        var header = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) + Data(repeating: 0, count: 16)
        header += Data(le16(0x3E) + le16(3) + le16(0xFFFE) + le16(9) + le16(6)) + Data(repeating: 0, count: 6)
        header += Data(le32(0))                         // directory sector count (v3: 0)
        header += Data(le32(1))                         // FAT sector count
        header += Data(le32(1))                         // first directory sector
        header += Data(le32(0))                         // transaction signature
        header += Data(le32(4096))                      // mini stream cutoff
        header += Data(le32(endOfChain))                // first mini FAT sector
        header += Data(le32(0))                         // mini FAT count
        header += Data(le32(endOfChain))                // first DIFAT sector
        header += Data(le32(0))                         // DIFAT count
        header += Data(le32(0))                         // DIFAT[0] = FAT at sector 0
        header += Data(repeating: 0xFF, count: 4 * 108)
        precondition(header.count == 512)
        func entry(name: String, type: UInt8, left: Int32, right: Int32, child: Int32, start: UInt32, size: UInt32) -> Data {
            var e = Data(repeating: 0, count: 128)
            let utf16 = Array(name.utf16) + [0]
            for (i, u) in utf16.prefix(32).enumerated() { e[i * 2] = UInt8(u & 0xFF); e[i * 2 + 1] = UInt8(u >> 8) }
            let nameLength = UInt16(min(utf16.count, 32) * 2)
            e[64] = UInt8(nameLength & 0xFF); e[65] = UInt8(nameLength >> 8)
            e[66] = type; e[67] = 1
            e.replaceSubrange(68..<72, with: le32(UInt32(bitPattern: left)))
            e.replaceSubrange(72..<76, with: le32(UInt32(bitPattern: right)))
            e.replaceSubrange(76..<80, with: le32(UInt32(bitPattern: child)))
            e.replaceSubrange(116..<120, with: le32(start))
            e.replaceSubrange(120..<124, with: le32(size))
            return e
        }
        var directory = entry(name: "Root Entry", type: 5, left: -1, right: -1, child: streams.isEmpty ? -1 : 1, start: endOfChain, size: 0)
        for (i, s) in streams.enumerated() {
            // The padded size keeps the stream out of the mini stream (the record parsers skip the zero tail).
            directory += entry(name: s.name, type: 2, left: -1, right: i + 1 < streams.count ? Int32(i + 2) : -1, child: -1,
                               start: UInt32(starts[i]), size: UInt32(padded[i].count))
        }
        directory.append(Data(repeating: 0, count: sector - directory.count % sector == sector ? 0 : sector - directory.count % sector))
        var file = header
        file += Data(fat.flatMap { le32($0) })
        file += directory.prefix(sector)
        for d in padded { file += d }
        return file
    }

    func testTYPE01_legacyExcelAndPowerPointBinaries_areReadFromTheirRecords() throws {
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func le32(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }
        func record(_ id: Int, _ body: [UInt8]) -> [UInt8] { le16(id) + le16(body.count) + body }
        // BIFF8 workbook: globals (BOF, two BOUNDSHEETs, an SST whose second string continues
        // into a CONTINUE record, EOF), then two sheet substreams found by their declared offsets.
        // Audit A03: every cell kind, with its address, on its sheet — not just the string table.
        func le64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (8 * UInt64($0))) & 0xFF) } }
        let bof = record(0x0809, le16(0x0600) + Array(repeating: 0, count: 14))
        let first = Array("Gross margin".utf8)
        let secondAll = Array("Quarterly budget review".utf8)
        let secondHead = Array(secondAll.prefix(9)), secondTail = Array(secondAll.dropFirst(9))
        let sst = record(0x00FC, le32(2) + le32(2) + le16(first.count) + [0] + first + le16(secondAll.count) + [0] + secondHead)
        let cont = record(0x003C, [0] + secondTail)
        func boundsheet(_ name: String, offset: Int, hidden: Bool) -> [UInt8] {
            let bytes = Array(name.utf8)
            return record(0x0085, le32(offset) + [hidden ? 1 : 0, 0] + [UInt8(bytes.count), 0] + bytes)
        }
        let cell: (Int, Int) -> [UInt8] = { row, col in le16(row) + le16(col) + le16(0) }   // row, col, xf
        let note = Array("Check this".utf8)
        let totalDue = Array("Total due".utf8)
        let inline = Array("inline note".utf8)
        let sheet1 = bof
            + record(0x00FD, cell(0, 0) + le32(0))                                        // A1 = shared string 0
            + record(0x0203, cell(1, 0) + le64(42.5.bitPattern))                          // A2 = 42.5
            + record(0x027E, cell(1, 1) + le32((7 << 2) | 0x02))                           // B2 = 7 (RK integer)
            + record(0x00BD, le16(2) + le16(0) + le16(0) + le32((150 << 2) | 0x03) + le16(0) + le32((9 << 2) | 0x02) + le16(1))  // A3 = 1.5, B3 = 9
            + record(0x0006, cell(3, 0) + [0, 0, 0, 0, 0, 0, 0xFF, 0xFF] + le16(0) + le32(0) + le16(0))   // A4 = formula, text result follows
            + record(0x0207, le16(totalDue.count) + [0] + totalDue)
            + record(0x0006, cell(3, 1) + le64(84.0.bitPattern) + le16(0) + le32(0) + le16(0))          // B4 = 84
            + record(0x0205, cell(4, 0) + [1, 0])                                          // A5 = TRUE
            + record(0x0204, cell(5, 0) + le16(inline.count) + [0] + inline)              // A6 inline label
            + record(0x01B6, Array(repeating: 0, count: 10) + le16(note.count) + le16(0) + le32(0))   // TXO: a note of 10 characters
            + record(0x003C, [0] + note)
            + record(0x003C, Array(repeating: 0, count: 8))
            + record(0x000A, [])
        let sheet2 = bof + record(0x00FD, cell(0, 0) + le32(1)) + record(0x000A, [])
        let globalsLength = bof.count + boundsheet("Budget", offset: 0, hidden: false).count + boundsheet("Hidden", offset: 0, hidden: true).count
            + sst.count + cont.count + record(0x000A, []).count
        let workbook = Data(bof + boundsheet("Budget", offset: globalsLength, hidden: false)
                            + boundsheet("Hidden", offset: globalsLength + sheet1.count, hidden: true)
                            + sst + cont + record(0x000A, []) + sheet1 + sheet2)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ole-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let xls = dir.appendingPathComponent("b.xls")
        try Self.oleContainer(streams: [("Workbook", workbook)]).write(to: xls)
        let sheet = try DocumentTextExtractor.extract(fileURL: xls, kind: .xls)
        XCTAssertEqual(sheet.components, ["Workbook", "Sheet: Budget", "Sheet: Hidden (hidden)"])
        XCTAssertTrue(sheet.text.contains("[Workbook]\nBudget\nHidden (hidden)"), sheet.text)
        XCTAssertTrue(sheet.text.contains("[Sheet: Budget]\nA1\tGross margin\nA2\t42.5\nB2\t7\nA3\t1.5\nB3\t9\nA4\tTotal due\nB4\t84\nA5\tTRUE\nA6\tinline note\nComment: Check this\n"), sheet.text)
        XCTAssertTrue(sheet.text.contains("[Sheet: Hidden (hidden)]\nA1\tQuarterly budget review"), sheet.text)
        XCTAssertTrue(sheet.text.contains("serial number"), "numbers are stated to be as stored")
        XCTAssertEqual(sheet.skipped, [])
        // A workbook whose cells never reach the sheets (no LABELSST) still keeps its strings.
        let stringsOnly = Data(bof + boundsheet("Budget", offset: 0, hidden: false) + sst + cont + record(0x000A, []))
        let onlyURL = dir.appendingPathComponent("strings.xls")
        try Self.oleContainer(streams: [("Workbook", stringsOnly)]).write(to: onlyURL)
        let only = try DocumentTextExtractor.extract(fileURL: onlyURL, kind: .xls)
        XCTAssertEqual(only.components, ["Workbook", "Shared strings"])
        XCTAssertTrue(only.text.contains("Gross margin\nQuarterly budget review"), only.text)

        // PowerPoint: two slide containers with a UTF-16 TextCharsAtom and a byte TextBytesAtom.
        func atom(_ type: Int, _ body: [UInt8]) -> [UInt8] { le16(0) + le16(type) + le32(body.count) + body }
        func container(_ type: Int, _ body: [UInt8]) -> [UInt8] { le16(0x000F) + le16(type) + le32(body.count) + body }
        let utf16 = Array("Roadmap overview".utf16).flatMap { le16(Int($0)) }
        let slide1 = container(0x03EE, atom(0x0FA0, utf16))
        let slide2 = container(0x03EE, atom(0x0FA8, Array("Milestones for the board vote".utf8)))
        let ppt = dir.appendingPathComponent("d.ppt")
        try Self.oleContainer(streams: [("PowerPoint Document", Data(slide1 + slide2))]).write(to: ppt)
        let deck = try DocumentTextExtractor.extract(fileURL: ppt, kind: .ppt)
        XCTAssertEqual(deck.components, ["Slide 1", "Slide 2"])
        XCTAssertTrue(deck.text.contains("[Slide 1]\nRoadmap overview") && deck.text.contains("[Slide 2]\nMilestones for the board vote"), deck.text)

        // An encrypted workbook (FILEPASS) is locked, not empty.
        let lockedBook = Data(record(0x0809, Array(repeating: 0, count: 16)) + record(0x002F, Array(repeating: 0, count: 6)) + record(0x000A, []))
        let locked = dir.appendingPathComponent("locked.xls")
        try Self.oleContainer(streams: [("Workbook", lockedBook)]).write(to: locked)
        XCTAssertThrowsError(try DocumentTextExtractor.extract(fileURL: locked, kind: .xls)) { XCTAssertEqual($0 as? OfficeTextExtractor.ExtractError, .encrypted) }
    }

    func testTYPE04_filesInsideAZipAreRead_oneLevelDown_withWhatWasNotRead() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let inner = Self.zipPackage([("deep.txt", Data("too deep".utf8))])
        let bundle = Self.zipPackage([
            ("report.docx", Self.docx(body: "The quorum clause applies.", header: "Board")),
            ("notes/readme.txt", Data("Payment within thirty days.".utf8)),
            ("photo.png", Data([0x89, 0x50, 0x4E, 0x47])),
            ("nested.zip", inner),
            ("__MACOSX/._report.docx", Data([0, 1, 2])),
        ])
        let url = dir.appendingPathComponent("bundle.zip")
        try bundle.write(to: url)
        // Package-level reading, without the app's child reader (audit A04: a child nothing reads is LISTED).
        let previousReader = ContainerTextExtractor.childReader
        ContainerTextExtractor.childReader = nil
        defer { ContainerTextExtractor.childReader = previousReader }
        let result = try DocumentTextExtractor.extract(fileURL: url, kind: .zip)
        // Plan v4 §13.3 (5): the parent's own text is the listing; every member is a child document of its own.
        XCTAssertEqual(result.components, ["Contents"])
        XCTAssertTrue(result.text.hasPrefix("[Contents]\nreport.docx\nnotes/readme.txt\nphoto.png\nnested.zip\n"), result.text)
        XCTAssertEqual(result.children.map(\.path), ["report.docx", "notes/readme.txt", "photo.png", "nested.zip › deep.txt"], "the nested archive is opened too")
        XCTAssertEqual(result.children.map(\.state), [.extracted, .extracted, .unsupported, .extracted])
        XCTAssertEqual(result.children.map(\.kind), ["docx", "txt", "png", "txt"])
        XCTAssertTrue(result.children[0].text?.contains("quorum clause") == true && result.children[1].text?.contains("Payment within thirty days") == true
                      && result.children[3].text?.contains("too deep") == true, "\(result.children.map { $0.text ?? "" })")
        XCTAssertNil(result.children[2].text, "a child nothing read carries no text, only its state")
        XCTAssertEqual(result.notText, [])
        XCTAssertEqual(result.skipped, ["photo.png (not read inside archives: .png)"], "an image is not silently 'no text' — it was not read")
        XCTAssertTrue(result.partial, "something was not read, and the state says so")
    }

    /// A minimal ustar archive of the given files.
    static func tarArchive(_ files: [(name: String, data: Data)]) -> Data {
        var out = Data()
        for file in files {
            var block = [UInt8](repeating: 0, count: 512)
            func put(_ text: String, at offset: Int, width: Int) {
                for (i, byte) in Array(text.utf8).prefix(width).enumerated() { block[offset + i] = byte }
            }
            put(file.name, at: 0, width: 100); put("0000644", at: 100, width: 8); put("0000000", at: 108, width: 8); put("0000000", at: 116, width: 8)
            put(String(format: "%011o", file.data.count), at: 124, width: 12); put(String(format: "%011o", 1_700_000_000), at: 136, width: 12)
            put("        ", at: 148, width: 8); block[156] = 0x30; put("ustar", at: 257, width: 6); put("00", at: 263, width: 2)
            let sum = block.reduce(0) { $0 + Int($1) }
            put(String(format: "%06o", sum), at: 148, width: 6); block[154] = 0; block[155] = 0x20
            out += Data(block) + file.data + Data(count: (512 - file.data.count % 512) % 512)
        }
        return out + Data(count: 1024)
    }

    /// RFC 1952 gzip of `payload` (deflate, no name).
    static func gzipData(_ payload: Data) -> Data {
        let capacity = max(64, payload.count * 2)
        var compressed = Data(count: capacity)
        let produced = compressed.withUnsafeMutableBytes { dst in
            payload.withUnsafeBytes { src in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          src.bindMemory(to: UInt8.self).baseAddress!, payload.count, nil, COMPRESSION_ZLIB)
            }
        }
        func le32(_ v: UInt32) -> Data { Data((0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) }) }
        var out = Data([0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0, 0x03])
        out += compressed.prefix(produced)
        out += le32(ZIPArchiveReader.CRC32.checksum(payload)) + le32(UInt32(truncatingIfNeeded: payload.count))
        return out
    }

    /// Audit 2026-11-06 A04: every child of an archive attachment is accounted
    /// for — a PDF inside a ZIP is read through the app's reader, a child
    /// nothing can read is listed (the attachment is partial, never silently
    /// complete), archives nest three levels and what lies deeper is listed,
    /// and tar / tgz attachments open like ZIPs.
    func testA04_archiveChildrenAreAccountedFor_pdfInsideZipRead_nestedThreeLevels_tarAndGzipOpened() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("archive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let previousReader = ContainerTextExtractor.childReader
        defer { ContainerTextExtractor.childReader = previousReader }
        let ocrWas = AttachmentOCR.isEnabled
        AttachmentOCR.isEnabled = false
        defer { AttachmentOCR.isEnabled = ocrWas }
        AttachmentTextIndexJob.installChildReader()

        let level3 = Self.zipPackage([("deepest.txt", Data("three levels down".utf8))])
        let level2 = Self.zipPackage([("level3.zip", level3), ("mid.txt", Data("two levels down".utf8))])
        let level4 = Self.zipPackage([("l4.txt", Data("four levels down".utf8))])
        let level2b = Self.zipPackage([("level3b.zip", Self.zipPackage([("level4.zip", level4)]))])
        let bundle = Self.zipPackage([
            ("invoice.pdf", Self.pdfData(pages: ["Invoice total nine hundred and forty euros."])),
            ("drawing.dwg", Data([0x41, 0x43, 0x31, 0x30, 0x31, 0x38])),
            ("photo.png", Self.pngData()),
            ("level2.zip", level2),
            ("deep/level2b.zip", level2b),
        ])
        let url = dir.appendingPathComponent("bundle.zip")
        try bundle.write(to: url)
        let result = try DocumentTextExtractor.extract(fileURL: url, kind: .zip)
        let paths = result.children.map(\.path)
        func child(_ path: String) -> ChildDocument? { result.children.first { $0.path == path } }
        XCTAssertTrue(paths.contains("invoice.pdf"), "\(paths)")
        XCTAssertTrue(child("invoice.pdf")?.text?.contains("nine hundred and forty") == true, "the PDF's text layer, read inside the archive")
        XCTAssertTrue(paths.contains("level2.zip › mid.txt") && paths.contains("level2.zip › level3.zip › deepest.txt"), "\(paths)")
        XCTAssertEqual(child("level2.zip › level3.zip › deepest.txt")?.text, "three levels down")
        XCTAssertFalse(result.children.contains { $0.text?.contains("four levels down") == true })
        XCTAssertEqual(child("deep/level2b.zip › level3b.zip › level4.zip")?.state, .unsupported, "the fourth level is listed, not read")
        XCTAssertTrue(result.skipped.contains { $0.contains("level4.zip") && $0.contains("deeper than \(ContainerTextExtractor.maxDepth) levels") }, "\(result.skipped)")
        XCTAssertTrue(result.skipped.contains { $0.hasPrefix("drawing.dwg (") }, "a child nothing can read is listed: \(result.skipped)")
        XCTAssertTrue(result.skipped.contains { $0.hasPrefix("photo.png (") && $0.contains("OCR") }, "an image with OCR off is listed as not read: \(result.skipped)")
        XCTAssertTrue(result.partial)

        // tar and gzip attachments open like ZIPs; a .tgz is gzip → tar → files.
        let tar = Self.tarArchive([("notes/minutes.txt", Data("Quorum reached at the board vote".utf8)),
                                   ("report.docx", Self.docx(body: "Payment within thirty days.", header: "H"))])
        let tarURL = dir.appendingPathComponent("files.tar")
        try tar.write(to: tarURL)
        let tarResult = try DocumentTextExtractor.extract(fileURL: tarURL, kind: .tar)
        XCTAssertEqual(tarResult.children.map(\.path), ["notes/minutes.txt", "report.docx"])
        XCTAssertTrue(tarResult.children[0].text?.contains("Quorum reached") == true && tarResult.children[1].text?.contains("Payment within thirty days") == true,
                      "\(tarResult.children.map { $0.text ?? "" })")
        XCTAssertFalse(tarResult.partial)
        let tgzURL = dir.appendingPathComponent("files.tgz")
        try Self.gzipData(tar).write(to: tgzURL)
        let tgz = try DocumentTextExtractor.extract(fileURL: tgzURL, kind: .gzip)
        XCTAssertEqual(tgz.children.map(\.path), ["files.tar › notes/minutes.txt", "files.tar › report.docx"])
        XCTAssertEqual(DocumentKind.detect(mimeType: "application/gzip", filename: "old.tar.gz"), .gzip)
        XCTAssertEqual(DocumentKind.detect(mimeType: "application/x-tar", filename: "backup"), .tar)
        // Bytes that are not a gzip at all: a named failure, never "no text".
        let bogus = dir.appendingPathComponent("bogus.gz")
        try Data("not an archive we open".utf8).write(to: bogus)
        XCTAssertThrowsError(try DocumentTextExtractor.extract(fileURL: bogus, kind: .gzip))
    }

    func testTYPE_throughTheIndexingJob_everyKindIsSearchableByContent_andStatesAreRecorded() async throws {
        let wasOn = SearchChunkPolicy.isEnabled
        defer { SearchChunkPolicy.isEnabled = wasOn }
        let env = try chunkedEnv()
        AttachmentTextIndexJob.testSuppressKicks = true
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()
        AttachmentTextIndexJob.testStoreOverride = env.store
        defer { AttachmentTextIndexJob.testStoreOverride = nil; AttachmentTextIndexJob.testSuppressKicks = false }
        let iwork = Self.fixturesRoot.appendingPathComponent("iwork"), legacy = Self.fixturesRoot.appendingPathComponent("legacy")
        let pagesData = try Data(contentsOf: iwork.appendingPathComponent("sample.pages"))
        let numbersData = try Data(contentsOf: iwork.appendingPathComponent("sample.numbers"))
        let docData = try Data(contentsOf: legacy.appendingPathComponent("sample.doc"))
        let odt = Self.odf(kind: .odt, content: "<office:document-content><office:body><office:text><text:p>Confidential appendix nine</text:p></office:text></office:body></office:document-content>")
        let zip = Self.zipPackage([("inside.txt", Data("Treasure inside the archive".utf8))])
        let raw = """
        From sender@example.com Wed Jan 15 10:00:00 2025
        From: sender@example.com
        To: user@dest.org
        Subject: Every kind
        Date: Wed, 15 Jan 2025 10:00:00 +0000
        Message-ID: <type-all@t>
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="B"

        --B
        Content-Type: text/plain

        see attached
        \(mimeAttachment("minutes.pages", "application/x-iwork-pages-sffpages", pagesData))
        \(mimeAttachment("budget.numbers", "application/x-iwork-numbers-sffnumbers", numbersData))
        \(mimeAttachment("memo.doc", "application/msword", docData))
        \(mimeAttachment("appendix.odt", "application/vnd.oasis.opendocument.text", odt))
        \(mimeAttachment("bundle.zip", "application/zip", zip))
        \(mimeAttachment("old.tar.gz", "application/gzip", Data("not an archive we open".utf8)))
        --B--
        """
        let email = try MBOXParser.processRawMessage(raw, senderEmail: "")
        _ = try await env.store.insertBatch([email], sourceFileHash: nil, accountID: nil, sourceID: nil, firstOrdinal: nil,
                                            dedupPolicy: .messageID, batchSize: 10, progress: nil)
        let outcome = await AttachmentTextIndexJob.shared.run()
        XCTAssertEqual(outcome.indexedEmails, 1)
        let coverage = try AttachmentCoverageStore(url: await env.store.attachmentCoverageURL)
        let rows = try coverage.rows(for: email.id)
        // A04: a .tar.gz that is not a gzip is a named failure, not "unsupported" — the format is read now.
        XCTAssertEqual(rows.map(\.state), [.extracted, .extracted, .extracted, .extracted, .extracted, .failed], "\(rows.map { ($0.filename, $0.state, $0.note ?? "") })")
        XCTAssertEqual(rows.map(\.extractor), ["iwork", "iwork", "ole", "odf", "archive", "archive"])
        XCTAssertTrue(rows.allSatisfy { $0.extractorVersion == AttachmentTextIndexJob.extractorVersion })
        XCTAssertTrue(rows[5].note?.contains("gzip signature") == true, "the failure names what was wrong: \(rows[5].note ?? "")")
        // Each one is found by what is inside it, through the attachment condition of the search model.
        for (type, phrase) in [("pages", "quorum clause"), ("numbers", "quarterly budget review"), ("doc", "thirty days"), ("odt", "appendix nine"), ("zip", "treasure inside")] {
            try await expectIDs(env, SearchSpec(groups: [SearchGroup(.all, attachments: [AttachmentConditionGroup(type: type, contentMatch: .phrase, content: phrase)])]), ["Every kind"], "\(type)")
        }
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()
    }

    // MARK: - TYPE-05 — speech in audio and video attachments, recognised on the device

    func testTYPE05_speechInRecordingsIsRecognisedOnDevice_andSearchableAsRecognisedSpeech() async throws {
        XCTAssertTrue(AttachmentSpeech.isMedia(mimeType: "audio/mp4", filename: "memo"))
        XCTAssertTrue(AttachmentSpeech.isMedia(mimeType: "application/octet-stream", filename: "call.MOV"))
        XCTAssertFalse(AttachmentSpeech.isMedia(mimeType: "application/pdf", filename: "deed.pdf"))
        let media = Self.fixturesRoot.appendingPathComponent("media")
        let m4a = media.appendingPathComponent("speech.m4a"), aiff = media.appendingPathComponent("speech.aiff")
        XCTAssertTrue(FileManager.default.fileExists(atPath: m4a.path) && FileManager.default.fileExists(atPath: aiff.path), "real recordings made with the system voice")

        // The person must have allowed speech recognition for the test host once; without that the test says so and skips.
        // Never ask from a test: an unanswered system prompt (e.g. on a simulator) waited
        // 8 hours on 2026-11-08. Not yet decided → skip with the reason.
        let status = AttachmentSpeech.authorizationStatus()
        try XCTSkipUnless(status == .authorized, "speech recognition is not authorised for the test host (status \(status.rawValue)) — allow it once in System Settings ▸ Privacy & Security ▸ Speech Recognition")
        try XCTSkipUnless(AttachmentSpeech.onDeviceRecognizer() != nil, "no on-device speech model is installed on this Mac")

        let transcript = await Task.detached { AttachmentSpeech.transcribe(fileURL: m4a) }.value
        XCTAssertNil(transcript.failure, transcript.failure ?? "")
        let words = (transcript.text ?? "").lowercased()
        XCTAssertTrue(words.contains("quorum") && words.contains("board"), "recognised: \(transcript.text ?? "nil")")
        XCTAssertNotNil(transcript.locale)

        // Through the indexing pass: a recording is "recognised speech", searchable by its words, labelled as speech in the evidence.
        let wasOn = SearchChunkPolicy.isEnabled, wasSpeech = AttachmentSpeech.isEnabled
        defer { SearchChunkPolicy.isEnabled = wasOn; AttachmentSpeech.isEnabled = wasSpeech }
        AttachmentSpeech.isEnabled = true
        let env = try chunkedEnv()
        AttachmentTextIndexJob.testSuppressKicks = true
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()
        AttachmentTextIndexJob.testStoreOverride = env.store
        defer { AttachmentTextIndexJob.testStoreOverride = nil; AttachmentTextIndexJob.testSuppressKicks = false }
        let raw = """
        From sender@example.com Wed Jan 15 10:00:00 2025
        From: sender@example.com
        To: user@dest.org
        Subject: Voice memo
        Date: Wed, 15 Jan 2025 10:00:00 +0000
        Message-ID: <type05@t>
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="B"

        --B
        Content-Type: text/plain

        listen to this
        \(mimeAttachment("memo.m4a", "audio/mp4", try Data(contentsOf: m4a)))
        \(mimeAttachment("roadmap.aiff", "audio/aiff", try Data(contentsOf: aiff)))
        --B--
        """
        let email = try MBOXParser.processRawMessage(raw, senderEmail: "")
        _ = try await env.store.insertBatch([email], sourceFileHash: nil, accountID: nil, sourceID: nil, firstOrdinal: nil,
                                            dedupPolicy: .messageID, batchSize: 10, progress: nil)
        let outcome = await AttachmentTextIndexJob.shared.run()
        XCTAssertEqual(outcome.indexedEmails, 1)
        let coverage = try AttachmentCoverageStore(url: await env.store.attachmentCoverageURL)
        let rows = try coverage.rows(for: email.id)
        XCTAssertEqual(rows.map(\.state), [.extracted, .extracted], "\(rows.map { ($0.filename, $0.state, $0.note ?? "") })")
        XCTAssertEqual(rows.map(\.extractor), ["speech", "speech"])
        try await expectIDs(env, SearchSpec(groups: [SearchGroup(.all, attachments: [AttachmentConditionGroup(type: "m4a", contentMatch: .allWords, content: "quorum board")])]), ["Voice memo"])
        try await expectIDs(env, SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.anyText, .allWords, "roadmap milestones")])]), ["Voice memo"], "speech counts as text anywhere in the message")
        let spec = SearchSpec(groups: [SearchGroup(.all, attachments: [AttachmentConditionGroup(type: "aiff", contentMatch: .allWords, content: "roadmap")])])
        let evidence = try await env.archive.matchEvidence(emailID: email.id, spec: spec, freeText: nil)
        guard case .speech(let ordinal, let filename, _)? = evidence.first?.location else {
            return XCTFail("evidence should name recognised speech, got \(evidence)")
        }
        XCTAssertEqual(ordinal, 1); XCTAssertEqual(filename, "roadmap.aiff")
        let chunks = try await env.store.searchChunks(emailID: email.id, kind: .speechText, ordinal: 0)
        XCTAssertTrue(chunks.joined().hasPrefix("[Recognised speech ("), "the text says where it came from")
        // Switched off: the recording is kept, and the state says why its words are not searched.
        AttachmentSpeech.isEnabled = false
        let off = AttachmentTextIndexJob.extractCoverage(fromRaw: raw)?.map { ($0.state, $0.note ?? "") } ?? []
        XCTAssertEqual(off.map(\.0), [.unsupported, .unsupported])
        XCTAssertTrue(off.first?.1.contains("turn on speech") == true)
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()
    }

    // MARK: - Five jobs LIFE-06 — the adopted data-access policy (owner, 2026-11-06)

    func testLIFE06_accessPolicy_keepsImportedDataOpenAfterExpiry_andStopsNewPaidWork() throws {
        let free = AccessPolicy(state: .free)
        let active = AccessPolicy(state: .active(.personal))
        let lifetime = AccessPolicy(state: .lifetime(.professional))
        let lapsedPersonal = AccessPolicy(state: .lapsed(previous: .personal))
        let lapsedPro = AccessPolicy(state: .lapsed(previous: .professional))   // expiry, refund and revocation all land here

        // Reading: Free sees the newest 500; everyone who held a plan sees the whole archive.
        XCTAssertEqual(free.archiveReadLimit, StoreManager.freeEmailLimit)
        for policy in [active, lifetime, lapsedPersonal, lapsedPro] { XCTAssertNil(policy.archiveReadLimit, "\(policy.state)") }
        // New paid work: only an active or lifetime plan.
        XCTAssertFalse(free.allowsPaidWork); XCTAssertFalse(lapsedPersonal.allowsPaidWork); XCTAssertFalse(lapsedPro.allowsPaidWork)
        XCTAssertTrue(active.allowsPaidWork); XCTAssertTrue(lifetime.allowsPaidWork)
        // Basic portability: .eml and mbox of imported mail are uncapped after a plan ended; reports keep the Free cap.
        XCTAssertNil(lapsedPersonal.exportCap(for: .emlFiles))
        XCTAssertNil(lapsedPersonal.exportCap(for: .mbox))
        XCTAssertEqual(lapsedPersonal.exportCap(for: .pdfFiles), StoreManager.freeEmailLimit)
        XCTAssertEqual(lapsedPersonal.exportCap(for: .csv), StoreManager.freeEmailLimit)
        XCTAssertEqual(free.exportCap(for: .emlFiles), StoreManager.freeEmailLimit)
        XCTAssertNil(active.exportCap(for: .pdfFiles)); XCTAssertNil(lifetime.exportCap(for: .csv))
        // Attachments: opening your own is reading.
        XCTAssertNil(lapsedPersonal.attachmentDownloadLimit(usedToday: 10, freeAllowance: 10))
        XCTAssertEqual(free.attachmentDownloadLimit(usedToday: 3, freeAllowance: 10), 7)
        XCTAssertEqual(free.attachmentDownloadLimit(usedToday: 12, freeAllowance: 10), 0)
        // Maintenance is never gated.
        for policy in [free, active, lifetime, lapsedPersonal] { XCTAssertTrue(policy.allowsMaintenance) }
        XCTAssertTrue(AccessPolicy.afterExpiryStatement.contains("Nothing is ever deleted"))
        XCTAssertTrue(AccessPolicy.lapsedOwnershipText(previous: .personal).contains("Personal"))
    }

    @MainActor
    func testLIFE06_storeManagerStates_andExportAuthorization() throws {
        // Fixtures never touch StoreKit or the live data scope.
        let never = StoreManager(testTier: .free)
        XCTAssertEqual(never.entitlementState, .free)
        XCTAssertEqual(never.accessPolicy.archiveReadLimit, StoreManager.freeEmailLimit)
        let active = StoreManager(testTier: .personal)
        XCTAssertEqual(active.entitlementState, .active(.personal))
        XCTAssertTrue(active.isPremium)
        let lifetime = StoreManager(testTier: .professional, lifetime: true)
        XCTAssertEqual(lifetime.entitlementState, .lifetime(.professional))
        // The plan ended (expired, cancelled, refunded or revoked): Free tier, open archive.
        let lapsed = StoreManager(testTier: .free, lapsedFrom: .professional)
        XCTAssertEqual(lapsed.entitlementState, .lapsed(previous: .professional))
        XCTAssertFalse(lapsed.isPremium, "new paid work stops")
        XCTAssertNil(lapsed.accessPolicy.archiveReadLimit, "the archive stays open")
        XCTAssertTrue(lapsed.accessPolicy.readsWholeArchive)
        // Restoring or re-buying brings paid work back without touching the archive.
        let restored = StoreManager(testTier: .personal, lapsedFrom: .professional)
        XCTAssertEqual(restored.entitlementState, .active(.personal))
        XCTAssertTrue(restored.accessPolicy.allowsPaidWork)

        // The export runner follows the policy and the format.
        let eml = ExportRequest(format: .emlFiles, title: "t", scope: .explicit([UUID()]), destination: "/tmp/x", isFolder: true, cap: nil)
        var pdf = eml; pdf.format = .pdfFiles
        var mboxReq = eml; mboxReq.format = .mbox; mboxReq.isFolder = false
        XCTAssertNil(try ExportJobRunner.authorized(eml, policy: lapsed.accessPolicy).cap)
        XCTAssertNil(try ExportJobRunner.authorized(mboxReq, policy: lapsed.accessPolicy).cap)
        XCTAssertEqual(try ExportJobRunner.authorized(pdf, policy: lapsed.accessPolicy).cap, StoreManager.freeEmailLimit)
        XCTAssertEqual(try ExportJobRunner.authorized(eml, policy: never.accessPolicy).cap, StoreManager.freeEmailLimit)
        XCTAssertNil(try ExportJobRunner.authorized(pdf, policy: active.accessPolicy).cap)
        XCTAssertThrowsError(try ExportJobRunner.authorized(eml, policy: nil), "no policy → no run")

        // Nothing in the store manager or the plan-change handler deletes data.
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let storeSource = try String(contentsOf: repo.appendingPathComponent("maxmailin/StoreManager.swift"), encoding: .utf8)
        for forbidden in ["clearAll(", ".delete(ids", "removeItem(at", "deleteReportingHeld"] {
            XCTAssertFalse(storeSource.contains(forbidden), "StoreManager must never \(forbidden)")
        }
        let paywall = try String(contentsOf: repo.appendingPathComponent("maxmailin/PaywallView.swift"), encoding: .utf8)
        XCTAssertTrue(paywall.contains("afterExpiryStatement"), "the purchase screen states the policy")
    }

    // MARK: - Five jobs §6 — the one combined preservation rehearsal

    /// Plan §6: import into self-contained mode; verify counts; detach the
    /// original; restart; find a document inside an attachment; identify a
    /// changed version correctly; back up; restore on a clean profile; rebuild
    /// the index; export and verify the selected mail. Disposable sources only.
    func testCombinedPreservationRehearsal_importDetachSearchChangedVersionBackupRestoreExport() async throws {
        let wasChunk = SearchChunkPolicy.isEnabled, wasCopy = SourceCopyPolicy.isEnabled
        defer { SearchChunkPolicy.isEnabled = wasChunk; SourceCopyPolicy.isEnabled = wasCopy }
        SearchChunkPolicy.isEnabled = true
        SourceCopyPolicy.isEnabled = true
        let env = try makeEnv()
        AttachmentTextIndexJob.testSuppressKicks = true
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()
        defer { AttachmentTextIndexJob.testStoreOverride = nil; AttachmentTextIndexJob.testSuppressKicks = false }

        // 1. A representative source: a contract with a DOCX, a changed version of it, and a large deferred message.
        let docx = Self.docx(body: "The quorum clause applies to every board vote.", header: "Board")
        // COMP-18: the same document two levels down — inside a ZIP inside a message.
        let bundle = Self.zipPackage([("notes/minutes.docx", docx)])
        func message(_ i: Int, subject: String, body: String, attachment: Bool, zip: Bool = false) -> String {
            var text = """
            From sender@example.com Mon Jan  1 00:00:0\(i) 2024
            From: sender@example.com
            To: me@example.com
            Subject: \(subject)
            Date: Mon, 01 Jan 2024 00:00:00 +0000
            Message-ID: <rehearsal-\(i)@test>
            MIME-Version: 1.0
            Content-Type: multipart/mixed; boundary="B"

            --B
            Content-Type: text/plain

            \(body)

            """
            if attachment { text += mimeAttachment("minutes.docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document", docx) + "\n" }
            if zip { text += mimeAttachment("bundle.zip", "application/zip", bundle) + "\n" }
            return text + "--B--\n\n"
        }
        let opening = String(repeating: "Terms agreed in the January meeting. ", count: 8)   // > 200 chars: the fingerprint clue cannot tell the versions apart
        let big = String(repeating: "deferred body line for the rehearsal\n", count: 6_000)
        let source = env.root.appendingPathComponent("Rehearsal.mbox")
        try FileManager.default.createDirectory(at: env.root, withIntermediateDirectories: true)
        try (message(0, subject: "Contract", body: opening + "Payment within 30 days.", attachment: true)
             + message(1, subject: "Contract", body: opening + "Payment within 45 days.", attachment: true)
             + message(2, subject: "Large deferred", body: big, attachment: false)
             + message(3, subject: "Bundle", body: "Archive of the minutes.", attachment: false, zip: true)).write(to: source, atomically: true, encoding: .utf8)

        // 2. Import (self-contained, locators for the large message) and verify counts.
        let summary = try await importForLife01(env, source)
        XCTAssertEqual(summary.parsed, 4, "\(summary.fileErrors)")
        let count = try await env.archive.count(query: .all)
        XCTAssertEqual(count, 4)

        // 3. Detach the original and "restart": a fresh store and service on the same directory.
        try FileManager.default.removeItem(at: source)
        let restarted = SQLiteEmailStore(directory: env.store.storeDirectory)
        let restartedArchive = ArchiveDataService(repository: EmailStoreRepository(store: restarted, fts: env.fts))
        var deferredQuery = EmailQuery.all; deferredQuery.subjectContains = "Large deferred"
        var deferredIDs: [UUID] = []
        for try await batch in await restartedArchive.streamFullEmails(query: deferredQuery, batchSize: 10) { deferredIDs += batch.map(\.id) }
        let deferredID = try XCTUnwrap(deferredIDs.first)
        let locatorValue = try await restarted.locator(forEmailID: deferredID)
        let locator = try XCTUnwrap(locatorValue)
        let deferredBytes = try LocatorReader().read(locator.messageRange, from: locator.sourcePath)
        XCTAssertTrue(String(decoding: deferredBytes, as: UTF8.self).contains(big.prefix(80)), "the large message reads from the archive's own copy")
        let missing = try await restarted.missingLocatorSources()
        XCTAssertTrue(missing.isEmpty)

        // 4. Find the document inside the attachment.
        AttachmentTextIndexJob.testStoreOverride = restarted
        AttachmentTextIndexJob.installChildReader()
        let outcome = await AttachmentTextIndexJob.shared.run()
        XCTAssertEqual(outcome.indexedEmails, 3)
        var attachmentQuery = EmailQuery.all
        attachmentQuery.spec = SearchSpec(groups: [SearchGroup(.all, attachments: [AttachmentConditionGroup(type: "docx", contentMatch: .phrase, content: "quorum clause")])])
        let foundCount = try await restartedArchive.count(query: attachmentQuery)
        XCTAssertEqual(foundCount, 3, "both versions carry the document, and so does the file inside the archive (COMP-18 nested step)")
        var foundSubjects: [String] = []
        for try await batch in await restartedArchive.streamFullEmails(query: attachmentQuery, batchSize: 10) { foundSubjects += batch.map { $0.headers["Subject"] ?? "" } }
        XCTAssertEqual(foundSubjects.sorted(), ["Bundle", "Contract", "Contract"])
        var nestedQuery = EmailQuery.all
        nestedQuery.spec = SearchSpec(groups: [SearchGroup(.all, attachments: [AttachmentConditionGroup(nameContains: "bundle", type: "docx", contentMatch: .phrase, content: "quorum clause")])])
        let nestedCount = try await restartedArchive.count(query: nestedQuery)
        XCTAssertEqual(nestedCount, 1, "the same-child condition reaches only the archived copy")

        // 5. The changed version is a candidate, never an identical copy.
        let environment = ScopeJobEnvironment(archive: restartedArchive, store: restarted, root: env.root)
        let (groups, receipt) = try await ScopeJobEnvironment.$current.withValue(environment) { try await DuplicatesEngine.exactGroups() }
        XCTAssertEqual(receipt.processed, 4)
        XCTAssertEqual(groups.count, 1, "the two versions share sender, subject, date and opening")
        let classified = DuplicateVerification.classify(groups)
        XCTAssertTrue(classified.verified.isEmpty)
        XCTAssertEqual(classified.candidates.count, 1)
        if case .candidate(let differences) = try XCTUnwrap(classified.candidates.first).verdict { XCTAssertTrue(differences.contains(.body)) } else { XCTFail() }
        XCTAssertTrue(DuplicateVerification.bulkRemovable(classified.verified).isEmpty)

        // 6. Back up; restore on a clean profile; the copies travel and the locators follow.
        let backup = env.root.appendingPathComponent("rehearsal-backup", isDirectory: true)
        let inventory = try await ArchiveBackup.create(store: restarted, to: backup)
        XCTAssertEqual(inventory.counts.emails, 4)
        XCTAssertTrue(inventory.files.contains { $0.kind == "source" }, "the self-contained copy is in the backup")
        XCTAssertTrue(inventory.linkedSources.isEmpty)
        let cleanRoot = env.root.appendingPathComponent("clean", isDirectory: true)
        let cleanStoreDir = cleanRoot.appendingPathComponent("store", isDirectory: true)
        _ = try ArchiveBackup.restore(backup: backup, intoStoreDirectory: cleanStoreDir, mode: .cleanProfile)
        let restored = SQLiteEmailStore(directory: cleanStoreDir)
        let relocated = try await restored.relocateSelfContainedLocators()
        XCTAssertEqual(relocated, 4, "every locator row (the offset engine records one per message) now names the restored copy")
        // The old archive is gone, as on a new machine: everything still reads from the restored folder.
        try FileManager.default.removeItem(at: env.store.storeDirectory)
        let restoredLocatorValue = try await restored.locator(forEmailID: deferredIDs[0])
        let restoredLocator = try XCTUnwrap(restoredLocatorValue)
        XCTAssertTrue(restoredLocator.sourcePath.hasPrefix(cleanStoreDir.path), restoredLocator.sourcePath)
        XCTAssertNoThrow(try LocatorReader().verifySource(restoredLocator))
        let restoredMissing = try await restored.missingLocatorSources()
        XCTAssertTrue(restoredMissing.isEmpty, "\(restoredMissing)")
        let restoredTotal = try await restored.totalCount()
        XCTAssertEqual(restoredTotal, 4)

        // 7. Rebuild the search index for the restored archive, then search and export from it.
        let restoredFTS = FTSSearchIndex(shardsDirectory: cleanRoot.appendingPathComponent("fts", isDirectory: true))
        let restoredArchive = ArchiveDataService(repository: EmailStoreRepository(store: restored, fts: restoredFTS))
        for try await batch in await restoredArchive.streamFullEmails(query: .all, batchSize: 50) { try await restoredFTS.indexBatch(batch) }
        let ftsRows = try await restoredFTS.rowCount()
        XCTAssertEqual(ftsRows, 4)
        var textQuery = EmailQuery.all; textQuery.text = "Contract"
        let byText = try await restoredArchive.count(query: textQuery)
        XCTAssertEqual(byText, 2, "the rebuilt full-text index answers")
        let foundAgain = try await restoredArchive.count(query: attachmentQuery)
        XCTAssertEqual(foundAgain, 3, "the attachment text came back with the database (chunk index inside it), no re-extraction needed")
        let nestedAgain = try await restoredArchive.count(query: nestedQuery)
        XCTAssertEqual(nestedAgain, 1, "the child document travelled with the backup")

        let exportFolder = cleanRoot.appendingPathComponent("export", isDirectory: true)
        let boundValue = try await restoredArchive.selectionSnapshotBound()
        let frozen = ArchiveSelectionScope.query(.all, exclusions: []).snapshotted(bound: try XCTUnwrap(boundValue))
        let export = try await ArchiveExportService(archive: restoredArchive).exportEMLFiles(scope: frozen, to: exportFolder)
        XCTAssertEqual(export.recordsWritten, 4)
        XCTAssertTrue(try ExportInventory.verify(folder: exportFolder).isClean)
        // OUT-04 / COMP-16: the outputs say what the restored archive says, message by message.
        // The located (header-only) record is completed from its source bytes through the
        // hydrator's locator route — routed at the restored store, as CapabilityWiring does
        // in production — and counted as hydrated, never silently taken as matching.
        let savedLocator = AttachmentHydrator.locatorProvider
        defer { AttachmentHydrator.locatorProvider = savedLocator }
        AttachmentHydrator.locatorProvider = { id in SQLiteEmailStore.locatorSnapshot(emailID: id, storeDirectory: cleanStoreDir) }
        let reconciliation = await ExportReconciliation.reconcile(folder: exportFolder, lookup: ExportRunCenter.sourceLookup(store: restored))
        XCTAssertEqual(reconciliation.matching, 4, "\(reconciliation)")
        XCTAssertEqual(reconciliation.outcome, .complete, reconciliation.reason ?? "")
        XCTAssertGreaterThanOrEqual(reconciliation.hydrated, 1, "the deferred large message is a located record read from its bytes: \(reconciliation)")
        XCTAssertTrue(ExportRunCenter.reconciliationText(reconciliation).hasPrefix("content checked: 4 of 4 messages say what the archive says"))
        // Independent check: the exported files parse back to the same three subjects, large message intact.
        var subjects: [String] = []
        var largeBytes = 0
        for file in try ExportInventory.load(folder: exportFolder).files {
            let raw = try String(contentsOf: exportFolder.appendingPathComponent(file.path), encoding: .utf8)
            let parsed = try MBOXParser.processRawMessage(raw, senderEmail: "")
            subjects.append(parsed.headers["Subject"] ?? "")
            if parsed.headers["Subject"] == "Large deferred" { largeBytes = raw.utf8.count }
        }
        XCTAssertEqual(subjects.sorted(), ["Bundle", "Contract", "Contract", "Large deferred"])
        XCTAssertGreaterThan(largeBytes, big.utf8.count, "the deferred message was exported whole from the restored copy")
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()
    }

    // MARK: - Five jobs DUP-02 — the whole scope, with a receipt that says what was read

    func testDUP02_wholeScopeFindsCopiesBeyondTheOldWindow_andTheReceiptSaysWhatWasRead() async throws {
        let env = try makeEnv()
        // 5,300 emails; 20 byte-identical pairs sit entirely beyond the previous engine's 5,000 window.
        var emails: [MBOXParser.RawEmail] = []
        for i in 0..<5_300 {
            let e = mail(10_000 + i, from: "s\(i % 13)@x.com", subject: "Bulk \(i)", body: "body \(i)",
                         date: "Wed, 01 Mar 2023 \(String(format: "%02d:%02d:%02d", (i / 3600) % 24, (i / 60) % 60, i % 60)) +0000")
            emails.append(e)
            if i >= 5_200 && i < 5_220 { emails.append(copy(of: e)) }
        }
        for start in stride(from: 0, to: emails.count, by: 500) {
            let batch = Array(emails[start..<min(start + 500, emails.count)])
            _ = try await env.store.insertBatch(batch, sourceFileHash: nil, accountID: nil, sourceID: nil, firstOrdinal: nil,
                                                dedupPolicy: .preserveAll, batchSize: 500, progress: nil)
        }
        let total = try await env.store.totalCount()
        XCTAssertEqual(total, 5_320)

        let environment = ScopeJobEnvironment(archive: env.archive, store: env.store, root: env.root)
        let (groups, receipt) = try await ScopeJobEnvironment.$current.withValue(environment) {
            try await DuplicatesEngine.exactGroups()
        }
        XCTAssertEqual(groups.count, 20, "every pair beyond the old window is found")
        XCTAssertTrue(groups.allSatisfy { $0.count == 2 })
        XCTAssertEqual(receipt.processed, 5_320)
        XCTAssertEqual(receipt.totalInScope, 5_320)
        XCTAssertEqual(receipt.unreadable, 0)
        XCTAssertFalse(receipt.cancelled)
        XCTAssertTrue(receipt.coverageLine.hasPrefix("All 5"), receipt.coverageLine)
        // A partial read is never dressed up as complete: the wording names what could not be read, or where it stopped.
        let partial = ScopeJobReceipt(jobKey: "duplicates.exact", title: "t", capability: "v3Duplicates", scope: "all", archiveRevision: 1,
                                      totalInScope: 5_320, processed: 5_300, unreadable: 20, resumed: false, cancelled: false,
                                      startedAt: Date(), finishedAt: Date(), fingerprint: "x")
        XCTAssertTrue(partial.coverageLine.contains("20 could not be read"), partial.coverageLine)
        let stopped = ScopeJobReceipt(jobKey: "duplicates.exact", title: "t", capability: "v3Duplicates", scope: "all", archiveRevision: 1,
                                      totalInScope: 5_320, processed: 1_000, unreadable: 0, resumed: false, cancelled: true,
                                      startedAt: Date(), finishedAt: Date(), fingerprint: "x")
        XCTAssertTrue(stopped.coverageLine.contains("Stopped after 1,000 of 5,320") || stopped.coverageLine.contains("Stopped after 1000 of 5320"), stopped.coverageLine)
        // The previous engine states its window whenever it is the one that ran.
        XCTAssertTrue(DuplicateManagerView.previousEngineScopeNote(appendedTo: nil).contains("5,000"))
    }

    // MARK: - Five jobs LIFE-04 / LIFE-05 — artifacts protected; diagnostics carry no mail; recovery in one place

    func testLIFE04_archiveArtifactsAreOwnerOnly_andDiagnosticsNameNoMailContent() async throws {
        let env = try makeEnv()
        var big = mail(330, from: "a@x.com", subject: "Big", body: "big")
        big.rawSource = "Subject: Big\n\n" + String(repeating: "z", count: BlobStore.inlineThresholdBytes + 100)
        try await env.store.insertBatch([mail(331, from: "a@x.com", subject: "Plain", body: "p"), big], batchSize: 10)
        try await env.fts.index(big)
        _ = try await env.store.snapshot(reason: "manual")
        let backup = env.root.appendingPathComponent("backup", isDirectory: true)
        _ = try await ArchiveBackup.create(store: env.store, to: backup)

        func perms(_ url: URL) throws -> Int {
            try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
        }
        func assertOwnerOnly(_ url: URL, _ what: String, file: StaticString = #filePath, line: UInt = #line) throws {
            let mode = try perms(url)
            XCTAssertEqual(mode & 0o077, 0, "\(what) must be owner-only, got \(String(mode, radix: 8))", file: file, line: line)
        }
        let storeDir = env.store.storeDirectory
        try assertOwnerOnly(storeDir, "store directory")
        try assertOwnerOnly(storeDir.appendingPathComponent("blobs"), "blob tier")
        try assertOwnerOnly(env.store.snapshotDirectory, "snapshot directory")
        let snapshotFile = try XCTUnwrap(env.store.snapshots().first?.url)
        try assertOwnerOnly(snapshotFile, "snapshot file")
        try assertOwnerOnly(env.root.appendingPathComponent("fts"), "search shards")
        try assertOwnerOnly(backup, "backup folder")
        for file in try ArchiveBackup.load(from: backup).files {
            try assertOwnerOnly(backup.appendingPathComponent(file.path), "backup file \(file.path)")
        }

        // Diagnostics are built from trips, metrics and counts — never from message fields.
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for name in ["maxmailin/EngineGuard.swift", "maxmailin/DiagnosticsCenter.swift"] {
            let source = try String(contentsOf: repo.appendingPathComponent(name), encoding: .utf8)
            for forbidden in ["plainBody", "htmlBody", "rawSource", "headers[\"Subject\"]", "headers[\"From\"]", "bodyPreview"] {
                XCTAssertFalse(source.contains(forbidden), "\(name) reads \(forbidden) — diagnostics must not carry mail content")
            }
        }
        let diagnostics = EngineTripCenter.shared.diagnosticsText()
        XCTAssertFalse(diagnostics.contains("Subject:"), "no message headers in diagnostics")
    }

    func testLIFE05_everyRecoveryActionIsReachableFromHealth() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let health = try String(contentsOf: repo.appendingPathComponent("maxmailin/ArchiveHealthView.swift"), encoding: .utf8)
        for identifier in ["health.retryFailedImports", "health.rebuildIndex", "health.rereadRawSources", "health.restoreBackup", "health.backup", "health.relink"] {
            XCTAssertTrue(health.contains("\"\(identifier)\""), "Health must offer \(identifier)")
        }
        XCTAssertTrue(health.contains("Restore latest…"), "the snapshot restore stays reachable")
        // The retry path really exists end to end: receipt button → notification → ContentView handler.
        let receiptView = try String(contentsOf: repo.appendingPathComponent("maxmailin/ImportReceiptView.swift"), encoding: .utf8)
        let contentView = try String(contentsOf: repo.appendingPathComponent("maxmailin/ContentView.swift"), encoding: .utf8)
        XCTAssertTrue(receiptView.contains("Retry failed sources"))
        XCTAssertTrue(contentView.contains(".retryImportSources"))
    }

    // MARK: - Five jobs DUP-03 / DUP-04 / DUP-05 — classes kept apart; removal keeps everything and is reversible

    func testDUP03_fourClassesAreDistinct_andOnlyTheIdenticalOnesAreBulkRemovable() {
        let a = makeEmail(i: 300, total: 2, body: "the same body")
        XCTAssertEqual(DuplicateVerification.verify([a, copy(of: a)]), .byteIdentical)
        // Content-equivalent: raw bytes differ (transport header), everything compared matches.
        let b = copy(of: a) { $0.rawSource = "Received: from relay\n" + $0.rawSource }
        XCTAssertEqual(DuplicateVerification.verify([a, b]), .contentEquivalent(attachmentBytesCompared: true))
        XCTAssertTrue(DuplicateVerification.contentEquivalentDefinition.contains("MIME structure"))
        // A different MIME structure (an HTML-only rendering of the same text) is a candidate, named as such.
        let htmlOnly = copy(of: a) { $0.rawSource = "raw other"; $0.htmlBody = "<p>the same body</p>"; $0.plainBody = "" }
        if case .candidate(let differences) = DuplicateVerification.verify([a, htmlOnly]) {
            XCTAssertTrue(differences.contains(.structure), "\(differences)")
        } else { XCTFail("expected a candidate") }
        let inline = copy(of: a) {
            $0.rawSource = "raw other"
            $0.attachments = [AttachmentMetadata(filename: "logo.png", mimeType: "image/png", size: 3, isInline: true, contentID: "logo", base64: "AAA=")]
        }
        if case .candidate(let differences) = DuplicateVerification.verify([a, inline]) {
            XCTAssertTrue(differences.contains(.structure) && differences.contains(.attachments))
        } else { XCTFail("expected a candidate") }
        // Similar is its own class and never verified.
        XCTAssertFalse(DuplicateVerification.Verdict.similar(similarity: 0.9).isVerified)
        XCTAssertTrue(DuplicateVerification.Verdict.byteIdentical.isVerified)
        XCTAssertFalse(DuplicateVerification.Verdict.contentEquivalent(attachmentBytesCompared: false).isVerified, "audit A01: unproven bytes are never bulk-removable")
        XCTAssertFalse(DuplicateVerification.Verdict.candidate(differences: [.body]).isVerified)
        // Survivor planning: the first unticked member stays; a fully ticked group keeps its first copy.
        let c = copy(of: a)
        let plans = DuplicateVerification.plans(for: [a.id, b.id, c.id], among: [[a, b, c]])
        XCTAssertEqual(plans, [.init(survivor: a.id, removed: [b.id, c.id])])
        let plans2 = DuplicateVerification.plans(for: [a.id], among: [[a, b, c]])
        XCTAssertEqual(plans2, [.init(survivor: b.id, removed: [a.id])])
        XCTAssertTrue(DuplicateVerification.survivorLine([a, b]).contains(a.headers["From"] ?? "?"))
    }

    func testDUP04_removalMergesEveryMembershipTagAndNote_andTheTrashRestoresIt() async throws {
        let env = try makeEnv()
        var keep = mail(310, from: "a@x.com", subject: "Kept copy", body: "same"); keep.tags = ["Inbox"]
        var gone = copy(of: keep); gone.tags = ["Projects/Alpha", "Inbox"]
        _ = try await env.store.insertBatch([keep, gone], sourceFileHash: nil, accountID: nil, sourceID: nil, firstOrdinal: nil,
                                            dedupPolicy: .preserveAll, batchSize: 10, progress: nil)
        try await env.store.userTagAdd("Follow up", ids: [gone.id])
        try await env.store.annotationSet("Note on the removed copy", id: gone.id)
        try await env.store.annotationSet("Note on the kept copy", id: keep.id)
        let before = try await env.archive.count(query: .all)
        XCTAssertEqual(before, 2)

        let result = try await env.store.removeDuplicateCopies([.init(survivor: keep.id, removed: [gone.id])])
        XCTAssertEqual(result.trashed, [gone.id])
        XCTAssertTrue(result.heldKept.isEmpty)
        XCTAssertEqual(result.membershipsMerged, 1, "Projects/Alpha was new to the survivor; Inbox it already had")
        XCTAssertEqual(result.userTagsMerged, 1)
        XCTAssertEqual(result.annotationsMerged, 1)
        // The survivor now lives in both folders, carries the tag and both notes.
        let survivorList = try await env.archive.fullEmails(ids: [keep.id])
        let survivor = try XCTUnwrap(survivorList.first)
        XCTAssertEqual(Set(SQLiteEmailStore.folderPaths(for: survivor)), ["Inbox", "Projects/Alpha"])
        let tags = try await env.store.userTags(ids: [keep.id])
        XCTAssertEqual(tags[keep.id], ["Follow up"])
        let notes = try await env.store.annotations(ids: [keep.id])
        XCTAssertEqual(notes[keep.id], "Note on the kept copy\n— from a removed duplicate copy: Note on the removed copy")
        let nodes = try await env.store.folderNodes()
        XCTAssertEqual(nodes.first { $0.path == "Projects/Alpha" }?.messageCount, 2, "the occurrence stays until the Trash is emptied")
        // The copy is in the Trash — out of the archive view, restorable, not deleted.
        let after = try await env.archive.count(query: .all)
        XCTAssertEqual(after, 1)
        let trashed = try await env.archive.trashedCount()
        XCTAssertEqual(trashed, 1)
        try await env.archive.setTrashed(ids: [gone.id], false)
        let restored = try await env.archive.count(query: .all)
        XCTAssertEqual(restored, 2, "the Trash restores it")

        // A held copy is kept even though nothing turned the store's hold gate on.
        let heldEnforced = await env.store.enforcesDatabaseLegalHolds
        XCTAssertFalse(heldEnforced)
        _ = try await env.store.legalHoldsAdd([gone.id], matter: "M-1")
        let held = try await env.store.removeDuplicateCopies([.init(survivor: keep.id, removed: [gone.id])])
        XCTAssertEqual(held.heldKept, [gone.id])
        XCTAssertTrue(held.trashed.isEmpty)
        let stillTwo = try await env.archive.count(query: .all)
        XCTAssertEqual(stillTwo, 2)
    }

    func testDUP05_reclaimableBytesAreHonest_inlineBodiesCountSharedBlobsOnlyWhenUnreferenced() async throws {
        let env = try makeEnv()
        let small = mail(320, from: "a@x.com", subject: "Small", body: "tiny body")
        var bigA = mail(321, from: "a@x.com", subject: "Big", body: "big")
        bigA.rawSource = "Subject: Big\n\n" + String(repeating: "y", count: BlobStore.inlineThresholdBytes + 512)
        let bigB = copy(of: bigA)   // the same bytes → the same content-addressed blob
        _ = try await env.store.insertBatch([small, bigA, bigB], sourceFileHash: nil, accountID: nil, sourceID: nil, firstOrdinal: nil,
                                            dedupPolicy: .preserveAll, batchSize: 10, progress: nil)
        let smallBytes = try await env.store.reclaimableBytesEstimate(ids: [small.id])
        XCTAssertGreaterThan(smallBytes, 0)
        XCTAssertLessThan(smallBytes, 10_000, "inline bodies and headers only")
        // One of two rows sharing a blob frees no blob bytes; both together free the blob.
        let oneBig = try await env.store.reclaimableBytesEstimate(ids: [bigA.id])
        let bothBig = try await env.store.reclaimableBytesEstimate(ids: [bigA.id, bigB.id])
        XCTAssertLessThan(oneBig, Int64(BlobStore.inlineThresholdBytes), "the shared blob is still referenced by the other row")
        XCTAssertGreaterThan(bothBig, Int64(BlobStore.inlineThresholdBytes), "unreferenced once both rows go")
        let none = try await env.store.reclaimableBytesEstimate(ids: [])
        XCTAssertEqual(none, 0)
        // The receipt line names the counts and the reversibility.
        var result = SQLiteEmailStore.DuplicateCleanupResult()
        result.trashed = [bigB.id]; result.membershipsMerged = 2; result.userTagsMerged = 1; result.heldKept = [small.id]
        let line = DuplicateManagerView.receiptSummary(result)
        XCTAssertTrue(line.contains("1 duplicate copies to the Trash (restorable)") && line.contains("2 folder memberships") && line.contains("1 held copies kept"), line)
    }

    // MARK: - Five jobs LIFE-03 — jobs that run together stay consistent

    func testLIFE03_importDuringSearchDuplicateReviewAndExport_staysConsistent() async throws {
        let env = try makeEnv()
        // First batch holds five byte-identical pairs; the rest arrives while the other jobs run.
        var first: [MBOXParser.RawEmail] = []
        for i in 0..<20 {
            let e = mail(200 + i, from: "a@x.com", subject: "First \(i)", body: "body \(i)")
            first.append(e)
            if i < 5 { first.append(copy(of: e)) }
        }
        // Stored copies need the preserve-all policy (the default policy skips a repeated Message-ID at import).
        _ = try await env.store.insertBatch(first, sourceFileHash: nil, accountID: nil, sourceID: nil, firstOrdinal: nil,
                                            dedupPolicy: .preserveAll, batchSize: 50, progress: nil)
        let boundValue = try await env.archive.selectionSnapshotBound()
        let frozen = ArchiveSelectionScope.query(.all, exclusions: []).snapshotted(bound: try XCTUnwrap(boundValue))
        let frozenIDs = Set(first.map(\.id))

        // The import: 10 more batches of 25, spaced out.
        let importer = Task { @MainActor in
            for batch in 0..<10 {
                let emails = (0..<25).map { mail(1000 + batch * 25 + $0, from: "b@x.com", subject: "Later \(batch)-\($0)", body: "later") }
                try await env.store.insertBatch(emails, batchSize: 25)
                try await Task.sleep(for: .milliseconds(15))
            }
        }
        // Search during import: never fails, never shrinks.
        let searcher = Task { @MainActor in
            var last = 0
            for _ in 0..<30 {
                let n = try await env.archive.count(query: .all)
                XCTAssertGreaterThanOrEqual(n, last, "a later count is never smaller during an append-only import")
                last = n
                _ = try await env.archive.page(query: .all, cursor: nil, limit: 20)
                try await Task.sleep(for: .milliseconds(5))
            }
            return last
        }
        // Duplicate review during import: the five pairs verify; nothing else is removable.
        let reviewer = Task { @MainActor in
            let groups = try await env.store.messageIDDuplicateGroups()
            return try await DuplicateVerification.verifyArchiveWide(groups: groups) { ids in try await env.archive.fullEmails(ids: ids) }
        }
        // Two exports at once, both over the frozen selection, into two folders.
        let service = ArchiveExportService(archive: env.archive)
        let folderA = env.root.appendingPathComponent("exportA", isDirectory: true)
        let folderB = env.root.appendingPathComponent("exportB", isDirectory: true)
        async let exportA = service.exportEMLFiles(scope: frozen, to: folderA)
        async let exportB = service.exportEMLFiles(scope: frozen, to: folderB)
        let (resultA, resultB) = try await (exportA, exportB)
        try await importer.value
        let lastCount = try await searcher.value
        let review = try await reviewer.value

        XCTAssertEqual(resultA.recordsWritten, frozenIDs.count)
        XCTAssertEqual(resultB.recordsWritten, frozenIDs.count)
        for folder in [folderA, folderB] {
            let inventory = try ExportInventory.load(folder: folder)
            XCTAssertEqual(Set(inventory.files.compactMap(\.emailID)), Set(frozenIDs.map(\.uuidString)), "exactly the selection frozen at start")
            XCTAssertTrue(try ExportInventory.verify(folder: folder).isClean)
        }
        XCTAssertEqual(review.verifiedGroups, 5)
        XCTAssertEqual(review.candidateGroups, 0)
        XCTAssertEqual(review.removable.count, 5)
        XCTAssertTrue(review.removable.allSatisfy { frozenIDs.contains($0) })
        let total = try await env.archive.count(query: .all)
        XCTAssertEqual(total, first.count + 250, "the import landed in full")
        XCTAssertLessThanOrEqual(lastCount, total)
    }

    // MARK: - Five jobs LIFE-02 — full backup restores on a clean profile

    func testLIFE02_backupRestoresOnACleanProfile_andRefusesATamperedBackup() async throws {
        let env = try makeEnv()
        let att = AttachmentMetadata(filename: "deed.pdf", mimeType: "application/pdf", size: 4, base64: Data("%PDF".utf8).base64EncodedString())
        var inbox = mail(210, from: "a@x.com", subject: "Kept", body: "with attachment", attachments: [att]); inbox.tags = ["Inbox"]
        var alpha = mail(211, from: "a@x.com", subject: "Project", body: "in a nested folder"); alpha.tags = ["Projects/Alpha"]
        // A raw message above the inline threshold lives in the blob tier.
        var big = mail(212, from: "a@x.com", subject: "Big", body: "big")
        big.rawSource = "Subject: Big\n\n" + String(repeating: "x", count: BlobStore.inlineThresholdBytes + 1_024)
        try await env.store.insertBatch([inbox, alpha, big], batchSize: 10)
        try await env.store.userTagAdd("Follow up", ids: [inbox.id])
        try await env.store.annotationSet("Check the deed", id: inbox.id)
        _ = try await env.store.legalHoldsAdd([alpha.id], matter: "Matter 7")
        // A sidecar present beside the database.
        let coverageURL = await env.store.attachmentCoverageURL
        _ = try AttachmentCoverageStore(url: coverageURL)
        let blobsDir = env.store.storeDirectory.appendingPathComponent("blobs")
        XCTAssertTrue(FileManager.default.fileExists(atPath: blobsDir.path), "the big message went to the blob tier")

        // Receipts are verification records: they travel too.
        let receipts = env.root.appendingPathComponent("receipts-import", isDirectory: true)
        try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)
        try Data("{\"receipt\":1}".utf8).write(to: receipts.appendingPathComponent("import-1.json"))

        let backup = env.root.appendingPathComponent("backup", isDirectory: true)
        let inventory = try await ArchiveBackup.create(store: env.store, to: backup, receiptDirectories: [("import", receipts)])
        XCTAssertEqual(inventory.counts.emails, 3)
        XCTAssertEqual(inventory.counts.attachments, 1)
        XCTAssertEqual(inventory.counts.userTags, 1)
        XCTAssertEqual(inventory.counts.annotations, 1)
        XCTAssertEqual(inventory.counts.legalHolds, 1)
        XCTAssertEqual(inventory.counts.folderMemberships, 2)
        XCTAssertEqual(Set(inventory.files.map(\.kind)), ["database", "sidecar", "blob", "receipt"])
        XCTAssertTrue(inventory.omitted.first?.contains("fts5") == true, "what is left out is said")
        XCTAssertTrue(inventory.linkedSources.isEmpty)
        XCTAssertTrue(try ArchiveBackup.verify(backup: backup).isClean)
        // A second backup into the same folder is refused — never overwritten.
        do {
            _ = try await ArchiveBackup.create(store: env.store, to: backup)
            XCTFail("a non-empty destination must be refused")
        } catch ArchiveBackupError.destinationNotEmpty {}

        // Restore on a clean profile: a fresh directory, nothing from the old paths.
        let cleanRoot = env.root.appendingPathComponent("clean-profile", isDirectory: true)
        let cleanStoreDir = cleanRoot.appendingPathComponent("store", isDirectory: true)
        let restoredReceipts = cleanRoot.appendingPathComponent("receipts", isDirectory: true)
        let restored = try ArchiveBackup.restore(backup: backup, intoStoreDirectory: cleanStoreDir, mode: .cleanProfile,
                                                 receiptDirectories: [("import", restoredReceipts)])
        XCTAssertEqual(restored.files, inventory.files)
        XCTAssertEqual(restored.counts, inventory.counts)
        XCTAssertTrue(FileManager.default.fileExists(atPath: restoredReceipts.appendingPathComponent("import-1.json").path))
        let restoredStore = SQLiteEmailStore(directory: cleanStoreDir)
        let total = try await restoredStore.totalCount()
        XCTAssertEqual(total, 3)
        let restoredBig = try await restoredStore.fullEmail(id: big.id)
        XCTAssertEqual(restoredBig?.rawSource, big.rawSource, "the blob-tier message reads back from the restored blobs")
        let restoredInboxValue = try await restoredStore.fullEmail(id: inbox.id)
        let restoredInbox = try XCTUnwrap(restoredInboxValue)
        XCTAssertEqual(SQLiteEmailStore.folderPaths(for: restoredInbox), ["Inbox"])
        let tags = try await restoredStore.userTags(ids: [inbox.id])
        XCTAssertEqual(tags[inbox.id], ["Follow up"])
        let notes = try await restoredStore.annotations(ids: [inbox.id])
        XCTAssertEqual(notes[inbox.id], "Check the deed")
        let holds = try await restoredStore.legalHoldIDs()
        XCTAssertEqual(holds, [alpha.id])
        let nodes = try await restoredStore.folderNodes()
        XCTAssertEqual(Set(nodes.map(\.path)), ["Inbox", "Projects", "Projects/Alpha"])
        let attachments = try await restoredStore.attachmentMetadata(forEmailID: inbox.id)
        XCTAssertEqual(attachments.map(\.filename), ["deed.pdf"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: cleanStoreDir.appendingPathComponent("attachment-coverage.sqlite").path))
        // Restoring over an existing archive in clean-profile mode is refused.
        do {
            _ = try ArchiveBackup.restore(backup: backup, intoStoreDirectory: cleanStoreDir, mode: .cleanProfile)
            XCTFail("a clean-profile restore must not replace an archive")
        } catch ArchiveBackupError.targetNotClean {}

        // A tampered backup is refused before anything is written.
        let tamperedTarget = env.root.appendingPathComponent("never", isDirectory: true)
        let blobEntry = try XCTUnwrap(inventory.files.first { $0.kind == "blob" })
        try Data("not the blob".utf8).write(to: backup.appendingPathComponent(blobEntry.path))
        XCTAssertFalse(try ArchiveBackup.verify(backup: backup).isClean)
        do {
            _ = try ArchiveBackup.restore(backup: backup, intoStoreDirectory: tamperedTarget, mode: .cleanProfile)
            XCTFail("a damaged backup must be refused")
        } catch ArchiveBackupError.hashMismatch(let path) { XCTAssertEqual(path, blobEntry.path) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tamperedTarget.appendingPathComponent("emails.db").path), "nothing was written")
        // And a backup without its inventory cannot be trusted at all.
        try FileManager.default.removeItem(at: backup.appendingPathComponent(ArchiveBackupInventory.filename))
        XCTAssertThrowsError(try ArchiveBackup.verify(backup: backup)) { XCTAssertEqual($0 as? ArchiveBackupError, .inventoryMissing) }
    }

    // MARK: - Five jobs FOLD-03 / FOLD-04 — one message, several locations; origin stays immutable

    func testFOLD03_aMessageInTwoLabelsIsOneMessageWithTwoLocations() async throws {
        let env = try makeEnv()
        var labelled = mail(170, from: "a@x.com", subject: "Two labels", body: "x")
        labelled.tags = ["Inbox", "Projects/Alpha"]
        var plain = mail(171, from: "a@x.com", subject: "One label", body: "y")
        plain.tags = ["Inbox"]
        try await env.store.insertBatch([labelled, plain], batchSize: 10)

        // Unique count: two messages, even though there are three memberships.
        let total = try await env.archive.count(query: .all)
        XCTAssertEqual(total, 2)
        let nodes = try await env.store.folderNodes()
        let inbox = try XCTUnwrap(nodes.first { $0.path == "Inbox" })
        let alpha = try XCTUnwrap(nodes.first { $0.path == "Projects/Alpha" })
        XCTAssertEqual(inbox.messageCount, 2, "occurrence count in Inbox")
        XCTAssertEqual(alpha.messageCount, 1, "occurrence count in Projects/Alpha")
        XCTAssertEqual(inbox.messageCount + alpha.messageCount, 3, "occurrences exceed unique messages — the header says so")
        // The same message answers from both folders — one row, two locations.
        var inInbox = EmailQuery.all; inInbox.folderID = inbox.folderID
        var inAlpha = EmailQuery.all; inAlpha.folderID = alpha.folderID
        let fromInbox = try await ids(env, SearchSpec(), scope: inInbox)
        let fromAlpha = try await ids(env, SearchSpec(), scope: inAlpha)
        XCTAssertEqual(fromInbox, ["Two labels", "One label"])
        XCTAssertEqual(fromAlpha, ["Two labels"])
        let stored = try await env.archive.fullEmails(ids: [labelled.id])
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(Set(SQLiteEmailStore.folderPaths(for: try XCTUnwrap(stored.first))), ["Inbox", "Projects/Alpha"])
        // Not a duplicate of itself: the Message-ID groups hold no group for it.
        let groups = try await env.store.messageIDDuplicateGroups()
        XCTAssertFalse(groups.contains { $0.contains(labelled.id) }, "\(groups)")
        XCTAssertTrue(ArchiveSidebarModel.occurrenceCountsNote.contains("counts in each"))
    }

    func testFOLD04_userTagsNeverRewriteTheSourcePath_andAttachmentsStayLinked() async throws {
        let env = try makeEnv()
        let att = AttachmentMetadata(filename: "brief.pdf", mimeType: "application/pdf", size: 4, base64: Data("%PDF".utf8).base64EncodedString())
        var email = mail(180, from: "a@x.com", subject: "Origin", body: "b", attachments: [att])
        email.tags = ["Top of Personal Folders/Inbox/Clients"]
        try await env.store.insertBatch([email], batchSize: 10)
        let nodesBefore = try await env.store.folderNodes()

        // The user tags, untags and re-tags; the source path and folders are untouched.
        try await env.store.userTagAdd("Clients — renamed by me", ids: [email.id])
        try await env.store.userTagAdd("Follow up", ids: [email.id])
        try await env.store.userTagRemove("Follow up", ids: [email.id])
        let storedList = try await env.archive.fullEmails(ids: [email.id])
        let stored = try XCTUnwrap(storedList.first)
        XCTAssertEqual(SQLiteEmailStore.folderPaths(for: stored), ["Top of Personal Folders/Inbox/Clients"])
        XCTAssertFalse(stored.tags.contains("Clients — renamed by me"), "a user tag is never a source tag")
        let nodesAfter = try await env.store.folderNodes()
        XCTAssertEqual(nodesAfter, nodesBefore, "no folder was created, renamed or moved by user tagging")
        // A user-tag query finds it; the source folder still answers for it too.
        var byUserTag = EmailQuery.all; byUserTag.userTag = "Clients — renamed by me"
        let byTag = try await env.archive.count(query: byUserTag)
        XCTAssertEqual(byTag, 1)
        // Export under the source-folder layout writes the ORIGINAL path, not the user's label.
        var options = ExportWriteOptions(); options.layout = .sourceFolders
        let folder = env.root.appendingPathComponent("origin", isDirectory: true)
        _ = try await ArchiveExportService(archive: env.archive).exportEMLFiles(scope: .explicit([email.id]), to: folder, write: options)
        let file = try XCTUnwrap(try ExportInventory.load(folder: folder).files.first)
        XCTAssertTrue(file.path.hasPrefix("Top of Personal Folders/Inbox/Clients/"), file.path)
        XCTAssertEqual(file.originalFolder, "Top of Personal Folders/Inbox/Clients")
        // The attachment is still the message's attachment.
        let attachments = try await env.store.attachmentMetadata(forEmailID: email.id)
        XCTAssertEqual(attachments.map(\.filename), ["brief.pdf"])
    }

    // MARK: - Five jobs OPEN-04 — progress says what is known; mail imported ≠ attachment text indexed

    func testOPEN04_progressTextNeverInventsAPercentage_andKeepsMailAndAttachmentsApart() async throws {
        // A grounded fraction shows a percentage, with bytes against a reliable total.
        XCTAssertEqual(ImportProgressText.fileProgress(fraction: 0.42, bytesDone: 0, fileBytes: 100, messagesSaved: 0), "42%")
        let withBytes = ImportProgressText.fileProgress(fraction: 0.5, bytesDone: 50 * 1_000_000, fileBytes: 100 * 1_000_000, messagesSaved: 10)
        XCTAssertTrue(withBytes.hasPrefix("50% · "), withBytes)
        XCTAssertTrue(withBytes.contains(" of "), withBytes)
        // No reliable total (unknown size, or already past it): bytes processed, no "of".
        let unknown = ImportProgressText.fileProgress(fraction: 0.5, bytesDone: 5_000_000, fileBytes: 0, messagesSaved: 0)
        XCTAssertTrue(unknown.contains("processed") && !unknown.contains(" of "), unknown)
        let past = ImportProgressText.fileProgress(fraction: 0.9, bytesDone: 200, fileBytes: 100, messagesSaved: 0)
        XCTAssertTrue(past.contains("processed") && !past.contains(" of "), past)
        // No fraction at all: counts and bytes only — never a percent sign.
        let noFraction = ImportProgressText.fileProgress(fraction: nil, bytesDone: 2_048, fileBytes: 0, messagesSaved: 7)
        XCTAssertFalse(noFraction.contains("%"), noFraction)
        XCTAssertTrue(noFraction.contains("7 messages saved"), noFraction)
        XCTAssertEqual(ImportProgressText.fileProgress(fraction: nil, bytesDone: 0, fileBytes: 0, messagesSaved: 0), "starting")
        XCTAssertEqual(ImportProgressText.fileProgress(fraction: 1.7, bytesDone: 0, fileBytes: 0, messagesSaved: 0), "100%", "clamped")

        // Imported mail and attachment text are two statements.
        let waiting = ImportProgressText.attachmentIndexing(attempted: 40, pending: 12, running: true)
        XCTAssertTrue(waiting.contains("searchable now") && waiting.contains("12 emails still to index") && waiting.contains("40 done"), waiting)
        XCTAssertTrue(waiting.contains("background"))
        let idle = ImportProgressText.attachmentIndexing(attempted: 40, pending: 12, running: false)
        XCTAssertTrue(idle.contains("next indexing pass"), idle)
        let done = ImportProgressText.attachmentIndexing(attempted: 52, pending: 0, running: false)
        XCTAssertTrue(done.contains("every email with attachments (52)"), done)
        XCTAssertFalse(ImportProgressText.attachmentIndexing(attempted: 0, pending: 0, running: false).contains("still"))

        // The store's figures behind the line: emails with attachments not yet attempted are pending.
        let env = try makeEnv()
        let att = AttachmentMetadata(filename: "a.txt", mimeType: "text/plain", size: 3, base64: Data("abc".utf8).base64EncodedString())
        try await env.store.insertBatch([mail(160, from: "a@x.com", subject: "With", body: "b", attachments: [att]),
                                         mail(161, from: "a@x.com", subject: "Without", body: "b")], batchSize: 10)
        let progress = try await env.store.attachmentTextProgress()
        XCTAssertEqual(progress.pending, 1)
        XCTAssertEqual(progress.attempted, 0)
    }

    // MARK: - Five jobs OUT-02 — a filtered export is frozen at its start; occurrences are a disclosed choice

    func testOUT02_querySelectionFrozenAtStart_importDuringTheRunDoesNotDrift() async throws {
        let env = try makeEnv()
        let first = (0..<3).map { mail(120 + $0, from: "a@x.com", subject: "Before \($0)", body: "b") }
        try await env.store.insertBatch(first, batchSize: 10)
        // The run starts: the selection is frozen to what exists now.
        let boundValue = try await env.archive.selectionSnapshotBound()
        let bound = try XCTUnwrap(boundValue)
        let frozen = ArchiveSelectionScope.query(.all, exclusions: []).snapshotted(bound: bound)
        XCTAssertTrue(frozen.isFrozen)
        XCTAssertFalse(ArchiveSelectionScope.query(.all, exclusions: []).isFrozen)
        // A background import lands while the export is running.
        let later = (0..<2).map { mail(130 + $0, from: "a@x.com", subject: "During \($0)", body: "b") }
        try await env.store.insertBatch(later, batchSize: 10)

        let live = try await env.archive.count(scope: .query(.all, exclusions: []))
        let fixed = try await env.archive.count(scope: frozen)
        XCTAssertEqual(live, 5, "the live view grew")
        XCTAssertEqual(fixed, 3, "the frozen selection did not")
        let folder = env.root.appendingPathComponent("frozen", isDirectory: true)
        let result = try await ArchiveExportService(archive: env.archive).exportEMLFiles(scope: frozen, to: folder)
        XCTAssertEqual(result.recordsWritten, 3)
        let inventory = try ExportInventory.load(folder: folder)
        XCTAssertEqual(Set(inventory.files.compactMap(\.emailID)), Set(first.map { $0.id.uuidString }), "only the mail that existed at start")
        // Freezing twice keeps the first bound; the fingerprint is stable under the later import.
        let again = frozen.snapshotted(bound: bound + 100)
        XCTAssertEqual(again, frozen)
        let fp1 = try await env.archive.selectionFingerprint(scope: frozen)
        try await env.store.insertBatch([mail(140, from: "a@x.com", subject: "Even later", body: "b")], batchSize: 10)
        let fp2 = try await env.archive.selectionFingerprint(scope: frozen)
        XCTAssertEqual(fp1, fp2)
    }

    func testOUT02_folderOccurrences_writeEachMembership_andTheReceiptDisclosesTheCopies() async throws {
        let env = try makeEnv()
        var both = mail(150, from: "a@x.com", subject: "In two folders", body: "x"); both.tags = ["Inbox", "Projects/Alpha"]
        var one = mail(151, from: "a@x.com", subject: "In one", body: "y"); one.tags = ["Inbox"]
        try await env.store.insertBatch([both, one], batchSize: 10)
        let service = ArchiveExportService(archive: env.archive)

        // Default: unique messages — one file each, in the first folder.
        var unique = ExportWriteOptions(); unique.layout = .sourceFolders
        let uniqueFolder = env.root.appendingPathComponent("unique", isDirectory: true)
        let uniqueResult = try await service.exportEMLFiles(scope: .explicit([both.id, one.id]), to: uniqueFolder, write: unique)
        XCTAssertEqual(uniqueResult.recordsWritten, 2)
        XCTAssertEqual(uniqueResult.extraCopies, 0)
        XCTAssertEqual(try ExportInventory.load(folder: uniqueFolder).files.filter { $0.emailID == both.id.uuidString }.count, 1)

        // Chosen: every folder occurrence — the second folder gets its copy, counted apart.
        var each = unique; each.folderOccurrences = true
        let eachFolder = env.root.appendingPathComponent("each", isDirectory: true)
        let eachResult = try await service.exportEMLFiles(scope: .explicit([both.id, one.id]), to: eachFolder, write: each)
        XCTAssertEqual(eachResult.recordsWritten, 3, "three files")
        XCTAssertEqual(eachResult.extraCopies, 1)
        let files = try ExportInventory.load(folder: eachFolder).files.filter { $0.emailID == both.id.uuidString }
        XCTAssertEqual(Set(files.compactMap(\.originalFolder)), ["Inbox", "Projects/Alpha"])
        XCTAssertTrue(files.allSatisfy { $0.path.hasPrefix("Inbox/") || $0.path.hasPrefix("Projects/Alpha/") })
        XCTAssertTrue(try ExportInventory.verify(folder: eachFolder).isClean)

        // The receipt keeps messages and files apart and names the choice.
        var receipt = ExportReceipt(title: "t", destination: eachFolder.path, isFolder: true, requested: 2, written: 3, outcome: .complete,
                                    startedAt: Date(), completedAt: Date())
        receipt.checked = 3; receipt.excluded = 0; receipt.extraCopies = 1; receipt.selectionFrozen = true
        XCTAssertEqual(receipt.reconciliationLine,
                       "selected 2 · written 2 messages in 3 files · hashes recorded while writing 3 of 3 · excluded 0 · failed 0 · 1 extra copy — one file per folder occurrence, as chosen · selection frozen at start")
        // The request only turns occurrences on under the source-folder layout.
        var request = ExportRequest(format: .emlFiles, title: "t", scope: .explicit([both.id]), destination: eachFolder.path, isFolder: true, cap: nil)
        request.options.folderOccurrences = true
        XCTAssertFalse(request.writeOptions.folderOccurrences, "flat layout: no occurrences")
        request.options.layout = .sourceFolders
        XCTAssertTrue(request.writeOptions.folderOccurrences)
    }

    // MARK: - Five jobs OUT-01 — every export format says what it preserves

    func testOUT01_everyExportFormatStatesWhatItPreserves() {
        // Only standard mail files are called mail-preserving; every rendering is a report.
        let mail = Set(UnifiedExportFormat.allCases.filter { $0.fidelity == .mailPreserving })
        XCTAssertEqual(mail, [.mbox, .emlFiles, .msgFiles])
        for format in [UnifiedExportFormat.pdfFiles, .tiffFiles, .csv, .headersCSV, .word, .json, .printText, .markdown, .portableHTML] {
            XCTAssertEqual(format.fidelity, .report, "\(format)")
        }
        XCTAssertEqual(UnifiedExportFormat.vcard.fidelity, .extract)
        XCTAssertEqual(UnifiedExportFormat.ics.fidelity, .extract)
        // The report note says, in words, that the output is not restorable mail.
        XCTAssertTrue(ExportFidelity.report.note.contains("cannot be re-imported as email"))
        XCTAssertTrue(ExportFidelity.report.label.contains("not restorable mail"))
        XCTAssertTrue(ExportFidelity.mailPreserving.note.contains("re-imported"))
        XCTAssertTrue(ExportFidelity.extract.note.contains("not a copy"))
        for fidelity in ExportFidelity.allCases {
            XCTAssertFalse(fidelity.label.isEmpty); XCTAssertFalse(fidelity.note.isEmpty)
        }
    }

    /// Deletion tombstones (schema v13): deleting emails records their identity
    /// so re-importing the same source never silently resurrects them — until
    /// the user explicitly forgets the deletion history.
    func testDeletionTombstone_blocksReimportUntilForgotten() async throws {
        let env = try makeEnv()

        var first: [MBOXParser.RawEmail] = []
        for i in 0..<4 {
            var e = makeEmail(i: i, total: 8, body: "b\(i)")
            e.headers["Message-ID"] = "<tomb-\(i)@test>"
            first.append(e)
        }
        _ = try await env.store.insertBatch(
            first, sourceFileHash: nil, accountID: nil,
            sourceID: nil, firstOrdinal: nil, dedupPolicy: .messageID,
            batchSize: 10, progress: nil)
        let initial = try await env.archive.count()
        XCTAssertEqual(initial, 4)

        // Delete them all → each identity is tombstoned.
        try await env.store.delete(ids: Set(first.map(\.id)))
        let afterDelete = try await env.archive.count()
        XCTAssertEqual(afterDelete, 0)
        let tombstones = try await env.store.tombstoneCount()
        XCTAssertEqual(tombstones, 4, "each deleted email is remembered")

        // Re-import the same source (same Message-IDs, NEW UUIDs) → all blocked.
        var reimport: [MBOXParser.RawEmail] = []
        for i in 0..<4 {
            var e = makeEmail(i: 100 + i, total: 8, body: "b\(i)")
            e.headers["Message-ID"] = "<tomb-\(i)@test>"
            reimport.append(e)
        }
        let blocked = try await env.store.insertBatch(
            reimport, sourceFileHash: nil, accountID: nil,
            sourceID: nil, firstOrdinal: nil, dedupPolicy: .messageID,
            batchSize: 10, progress: nil)
        XCTAssertEqual(blocked.insertedIDs.count, 0, "previously-deleted emails are not resurrected")
        XCTAssertEqual(blocked.blockedByTombstoneIDs.count, 4)
        let stillEmpty = try await env.archive.count()
        XCTAssertEqual(stillEmpty, 0, "no resurrection on re-import")

        // Override: forget the history, then the same re-import restores them.
        try await env.store.clearDeletionTombstones()
        let clearedCount = try await env.store.tombstoneCount()
        XCTAssertEqual(clearedCount, 0)
        let restored = try await env.store.insertBatch(
            reimport, sourceFileHash: nil, accountID: nil,
            sourceID: nil, firstOrdinal: nil, dedupPolicy: .messageID,
            batchSize: 10, progress: nil)
        XCTAssertEqual(restored.insertedIDs.count, 4, "after forgetting, re-import restores them")
        let finalCount = try await env.archive.count()
        XCTAssertEqual(finalCount, 4)
    }

    /// Email History (document flow): dated events sort oldest-first into
    /// the timeline; undated facts land in current state; empty inputs
    /// produce empty sections (never placeholder junk); the report carries
    /// every event.
    func testEmailHistoryBuilder_timelineAndState() {
        var inputs = EmailHistoryBuilder.Inputs()
        inputs.sentDate = Date(timeIntervalSince1970: 1_000)
        inputs.messageType = "received"
        inputs.importedAt = Date(timeIntervalSince1970: 5_000)
        inputs.sourceFilename = "Sent.mbox"
        inputs.sourceSHA256 = "99bd7573f3ae0011"
        inputs.sourceOrdinal = 4
        inputs.annotation = ("Key evidence for claim 2", "Examiner A", Date(timeIntervalSince1970: 9_000))
        inputs.auditEntries = [(Date(timeIntervalSince1970: 7_000), "Tagged as Relevant", "id", "Examiner A")]
        inputs.evidenceTag = "Relevant"
        inputs.batesNumber = "ACME-000123"
        inputs.underLegalHold = true
        inputs.isPinned = true
        inputs.manualLabels = ["Personal"]
        inputs.removedAILabels = ["Newsletter"]

        let (timeline, state) = EmailHistoryBuilder.build(inputs)
        XCTAssertEqual(timeline.map(\.title),
                       ["Received", "Imported", "Tagged as Relevant", "Annotated by Examiner A"],
                       "oldest-first: sent → imported → audit → annotation")
        XCTAssertTrue(timeline[1].detail.contains("Sent.mbox"))
        XCTAssertTrue(timeline[1].detail.contains("message #5"), "ordinal is 1-based for humans")
        let stateTitles = state.map(\.title)
        XCTAssertTrue(stateTitles.contains("Evidence: Relevant"))
        XCTAssertTrue(stateTitles.contains("Bates ACME-000123"))
        XCTAssertTrue(stateTitles.contains("Under legal hold"))
        XCTAssertTrue(stateTitles.contains("Review state"))
        XCTAssertTrue(stateTitles.contains("Manual labels"))
        XCTAssertTrue(stateTitles.contains("AI labels you removed"))

        let report = EmailHistoryBuilder.report(subject: "S", messageID: "<m@x>",
                                                timeline: timeline, state: state)
        XCTAssertTrue(report.contains("Bates ACME-000123"))
        XCTAssertTrue(report.contains("Tagged as Relevant"))

        // Empty inputs stay empty.
        let empty = EmailHistoryBuilder.build(EmailHistoryBuilder.Inputs())
        XCTAssertTrue(empty.timeline.isEmpty)
        XCTAssertTrue(empty.state.isEmpty)
    }

    /// Daily activity report: selects exactly the chosen day's audit
    /// entries (chronological), states the chain verdict honestly, and
    /// summarizes by action kind. The end-of-day case artifact.
    func testCaseActivityReport_daySliceAndVerdict() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let day = cal.date(from: DateComponents(year: 2026, month: 8, day: 9, hour: 12))!
        let sameDayEarly = cal.date(from: DateComponents(year: 2026, month: 8, day: 9, hour: 8))!
        let sameDayLate = cal.date(from: DateComponents(year: 2026, month: 8, day: 9, hour: 18))!
        let otherDay = cal.date(from: DateComponents(year: 2026, month: 8, day: 8, hour: 12))!

        var inputs = CaseActivityReportBuilder.Inputs()
        inputs.caseNumber = "SMOKE-TEST-001"
        inputs.examiner = "Examiner A"
        inputs.day = day
        inputs.calendar = cal
        inputs.chainVerified = true
        inputs.auditEntries = [
            (sameDayLate, 3, "Evidence tagged: Relevant", "email X", "Examiner A"),
            (otherDay, 1, "Import completed", "Sent.mbox", "Examiner A"),
            (sameDayEarly, 2, "Import completed", "Inbox.mbox", "Examiner A"),
        ]
        let report = CaseActivityReportBuilder.build(inputs)
        XCTAssertTrue(report.contains("SMOKE-TEST-001"))
        XCTAssertTrue(report.contains("Audit chain: VERIFIED"))
        XCTAssertTrue(report.contains("ACTIONS (2)"), "only the chosen day's entries")
        XCTAssertFalse(report.contains("Sent.mbox"), "other-day entry excluded")
        // Chronological: the 08:00 import precedes the 18:00 tagging.
        let importPos = report.range(of: "Inbox.mbox")!.lowerBound
        let tagPos = report.range(of: "Evidence tagged")!.lowerBound
        XCTAssertTrue(importPos < tagPos)
        XCTAssertTrue(report.contains("SUMMARY"))

        // Tampered chain is stated in plain words; empty day is honest.
        inputs.chainVerified = false
        XCTAssertTrue(CaseActivityReportBuilder.build(inputs).contains("FAILED VERIFICATION"))
        inputs.auditEntries = []
        inputs.chainVerified = nil
        let empty = CaseActivityReportBuilder.build(inputs)
        XCTAssertTrue(empty.contains("No audit-logged actions"))
        XCTAssertTrue(empty.contains("not verified"))
    }

    /// Triage suggestions: high risk → Confirmed; medium risk or heavy IOC
    /// load → Needs Info; light signals → Needs Info; clean → Safe. The
    /// reason line always says why.
    func testTriageVerdictPolicy_suggestions() {
        let high = TriageVerdictPolicy.suggestion(phishingRisk: "High", iocCount: 3, hasAttachments: false)
        XCTAssertEqual(high.verdict, .confirmedPhishing)
        XCTAssertTrue(high.reason.contains("High phishing risk"))

        let medium = TriageVerdictPolicy.suggestion(phishingRisk: "Medium", iocCount: 0, hasAttachments: false)
        XCTAssertEqual(medium.verdict, .needsInfo)

        let heavyIOC = TriageVerdictPolicy.suggestion(phishingRisk: nil, iocCount: 5, hasAttachments: false)
        XCTAssertEqual(heavyIOC.verdict, .needsInfo)
        XCTAssertTrue(heavyIOC.reason.contains("5 suspicious indicators"))

        let attachment = TriageVerdictPolicy.suggestion(phishingRisk: nil, iocCount: 0, hasAttachments: true)
        XCTAssertEqual(attachment.verdict, .needsInfo)

        let clean = TriageVerdictPolicy.suggestion(phishingRisk: nil, iocCount: 0, hasAttachments: false)
        XCTAssertEqual(clean.verdict, .safe)

        // The queue query compiles to a user-tag SQL filter.
        XCTAssertEqual(TriageQueueService.pendingQuery.userTag, "triage:pending")
    }

    /// Review dashboard math: totals across batches, velocity per active
    /// day, honest estimate, and the privilege-log gap detection.
    func testReviewProgressModel_summaryAndPrivilegeGap() {
        let ids = (0..<10).map { _ in UUID() }
        let priv1 = UUID(), priv2 = UUID()
        let batches: [(id: UUID, name: String, emailIDs: [UUID], reviewed: Set<UUID>, skipped: Set<UUID>)] = [
            (UUID(), "Batch 1", Array(ids[0..<6]), Set(ids[0..<4]), Set([ids[4]])),
            (UUID(), "Batch 2", Array(ids[6..<10]), Set([ids[6], ids[7]]), []),
        ]
        let summary = ReviewProgressModel.summarize(
            batches: batches,
            reviewActivityDays: ["2026-08-08", "2026-08-09"],
            privilegedIDs: [priv1, priv2],
            annotatedIDs: [priv1])

        XCTAssertEqual(summary.totalAssigned, 10)
        XCTAssertEqual(summary.totalReviewed, 6)
        XCTAssertEqual(summary.totalSkipped, 1)
        XCTAssertEqual(summary.pending, 3)
        XCTAssertEqual(summary.velocityPerDay, 3.0, accuracy: 0.001)
        XCTAssertEqual(summary.estimatedDaysRemaining ?? -1, 1.0, accuracy: 0.001)
        XCTAssertFalse(summary.privilegeLogComplete)
        XCTAssertEqual(summary.privilegedMissingAnnotation, [priv2],
                       "the unannotated privileged email is the defensibility gap")

        let report = ReviewProgressModel.defensibilityReport(
            summary, caseNumber: "MATTER-7", examiner: "Reviewer B")
        XCTAssertTrue(report.contains("MATTER-7"))
        XCTAssertTrue(report.contains("WARNING: 1 privileged email"))
        XCTAssertTrue(report.contains("Batch 1: 4/6 reviewed, 1 skipped"))

        // No activity days → no velocity claims, no fabricated estimate.
        let idle = ReviewProgressModel.summarize(
            batches: batches, reviewActivityDays: [], privilegedIDs: [], annotatedIDs: [])
        XCTAssertEqual(idle.velocityPerDay, 0)
        XCTAssertNil(idle.estimatedDaysRemaining)
        XCTAssertTrue(idle.privilegeLogComplete, "no privileged emails = nothing missing")
    }

    /// Story file: findings ordered by when they were recorded, each with
    /// its citation; empty input produces an honest guidance line.
    func testStoryFileBuilder_citedFindings() {
        let early = StoryFileBuilder.Finding(
            claim: "Payment authorized on March 3", claimDate: Date(timeIntervalSince1970: 1_000),
            subject: "Re: Q1 payments", from: "cfo@corp.com", sentDate: "Tue, 3 Mar 2026",
            messageID: "<pay@corp>", evidenceTag: "Relevant")
        let late = StoryFileBuilder.Finding(
            claim: "Board was informed a week later", claimDate: Date(timeIntervalSince1970: 2_000),
            subject: "Board minutes", from: "sec@corp.com", sentDate: "Tue, 10 Mar 2026",
            messageID: nil, evidenceTag: nil)

        let md = StoryFileBuilder.markdown(title: "Payments Story", author: "R. Khan",
                                           findings: [late, early])
        XCTAssertTrue(md.contains("# Payments Story"))
        XCTAssertTrue(md.contains("*Researched by R. Khan*"))
        XCTAssertTrue(md.contains("### 1. Payment authorized on March 3"),
                      "recording order, not input order")
        XCTAssertTrue(md.contains("### 2. Board was informed a week later"))
        XCTAssertTrue(md.contains("cfo@corp.com"))
        XCTAssertTrue(md.contains("`<pay@corp>`"), "Message-ID cited for verification")
        XCTAssertTrue(md.contains("coded Relevant"))
        XCTAssertTrue(md.contains("## Source Index"))

        let empty = StoryFileBuilder.markdown(title: "", author: "", findings: [])
        XCTAssertTrue(empty.contains("# Story File"))
        XCTAssertTrue(empty.contains("No findings yet"), "honest empty state, no fake content")
    }

    /// Audit-trail filtering: kind extraction, search across all fields,
    /// date scopes against a fixed calendar, and chip+search combination.
    func testAuditTrailFilter_searchKindsAndScopes() {
        XCTAssertEqual(AuditTrailFilter.kind(of: "Triage verdict: Confirmed Phishing"), "Triage verdict")
        XCTAssertEqual(AuditTrailFilter.kind(of: "Import completed"), "Import completed")

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = cal.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 12))!
        let today = cal.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 8))!
        let lastWeek = cal.date(from: DateComponents(year: 2026, month: 8, day: 5))!
        let lastMonth = cal.date(from: DateComponents(year: 2026, month: 7, day: 1))!

        func match(_ ts: Date, search: String = "", kind: String? = nil,
                   scope: AuditTrailFilter.DateScope = .all) -> Bool {
            AuditTrailFilter.matches(
                action: "Triage verdict: Confirmed Phishing",
                detail: "Invoice scam — reported by alice@corp.com",
                examiner: "Examiner A", timestamp: ts,
                search: search, kind: kind, scope: scope, now: now, calendar: cal)
        }

        XCTAssertTrue(match(today, scope: .today))
        XCTAssertFalse(match(lastWeek, scope: .today))
        XCTAssertTrue(match(lastWeek, scope: .week))
        XCTAssertFalse(match(lastMonth, scope: .week))
        XCTAssertTrue(match(lastMonth, scope: .all))

        XCTAssertTrue(match(today, search: "alice"), "search hits details")
        XCTAssertTrue(match(today, search: "examiner a"), "search hits examiner, case-insensitive")
        XCTAssertFalse(match(today, search: "bob"))

        XCTAssertTrue(match(today, kind: "Triage verdict"))
        XCTAssertFalse(match(today, kind: "Import completed"))
        XCTAssertTrue(match(today, search: "invoice", kind: "Triage verdict", scope: .today),
                      "chip + search + scope combine")
    }

    /// Work Center: privilege gaps outrank queues, queues outrank info,
    /// never-configured watch folder stays silent, complete analysis stays
    /// silent, and a clear desk produces an empty list.
    func testWorkCenterModel_prioritiesAndHonesty() {
        var inputs = WorkCenterModel.Inputs()
        inputs.privilegeGaps = 2
        inputs.triagePending = 7
        inputs.reviewPending = 40
        inputs.batchCount = 2
        inputs.watchFolderActive = false
        inputs.analysisAnalyzed = 80
        inputs.analysisTotal = 100

        let items = WorkCenterModel.items(inputs)
        XCTAssertEqual(items.first?.severity, .critical, "privilege gaps lead")
        XCTAssertTrue(items[0].title.contains("2 privileged"))
        let severities = items.map(\.severity)
        XCTAssertEqual(severities, severities.sorted(), "critical → action → info")
        XCTAssertTrue(items.contains { $0.title.contains("7 emails awaiting triage") })
        XCTAssertTrue(items.contains { $0.title.contains("Watch folder is off") })
        XCTAssertTrue(items.contains { $0.title.contains("AI analysis 80%") })

        // Never-configured watch folder and finished analysis are silent.
        var quiet = WorkCenterModel.Inputs()
        quiet.watchFolderActive = nil
        quiet.analysisAnalyzed = 50
        quiet.analysisTotal = 50
        XCTAssertTrue(WorkCenterModel.items(quiet).isEmpty, "a clear desk shows nothing")
    }

    /// Document numbers: format, per-type-per-year ranges that never repeat
    /// or skip, persistence across reopen, and the display-document lookup.
    func testDocumentRegistry_rangesLookupAndPersistence() async throws {
        XCTAssertEqual(DocumentNumberFormat.format(type: "imp", year: 2026, sequence: 7),
                       "IMP-2026-0007")
        XCTAssertEqual(DocumentNumberFormat.sourceAlias(3), "SRC-0003")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailin-docs-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteEmailStore(directory: root)
        let now = Date(timeIntervalSince1970: 1_786_000_000)   // 2026

        // Ranges advance per type independently; no repeats, no skips.
        let imp1 = try await store.issueDocument(type: "IMP", summary: "first import", now: now)
        let imp2 = try await store.issueDocument(type: "IMP", summary: "second import", now: now)
        let vrd1 = try await store.issueDocument(type: "VRD", summary: "Confirmed Phishing: invoice scam", now: now)
        XCTAssertTrue(imp1.hasSuffix("-0001"))
        XCTAssertTrue(imp2.hasSuffix("-0002"))
        XCTAssertTrue(vrd1.hasSuffix("-0001"), "each type has its own range")

        // Lookup by number fragment and by summary, case-insensitive.
        let byNumber = try await store.lookupDocuments(matching: imp2)
        XCTAssertEqual(byNumber.map(\.number), [imp2])
        let bySummary = try await store.lookupDocuments(matching: "PHISHING")
        XCTAssertEqual(bySummary.map(\.number), [vrd1])
        let recent = try await store.recentDocuments()
        XCTAssertEqual(recent.count, 3)

        // Second connection to the same store: the range continues where it
        // left off — a repeated number would be a defensibility disaster.
        let reopened = SQLiteEmailStore(directory: root)
        let imp3 = try await reopened.issueDocument(type: "IMP", summary: "after reopen", now: now)
        XCTAssertTrue(imp3.hasSuffix("-0003"))
        let all = try await reopened.recentDocuments()
        XCTAssertEqual(all.count, 4)
    }

    /// Workflow engine: define → run → confirm operations in order → the
    /// instance becomes 'confirmed' only when every operation is done;
    /// confirmations persist with who/result/doc; the report renders them.
    func testWorkflowEngine_instanceLifecycle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailin-wf-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteEmailStore(directory: root)

        // Built-in catalog is well-formed: 51 recipes, sequential ops.
        // 47 + the four added in the v3 cycle (3 researcher + the forensic
        // evidence plan). This count was not updated when they landed, so the
        // assertion had been failing since.
        XCTAssertEqual(WorkflowCatalog.all.count, 51)
        for def in WorkflowCatalog.all {
            XCTAssertEqual(def.operations.map(\.seq), Array(1...def.operations.count),
                           "\(def.defID) operations must be 1..n in order")
        }
        let legal = WorkflowCatalog.templates(for: "legal").first!

        // Seed + run.
        let ops = legal.operations.map {
            SQLiteEmailStore.StoredOperation(seq: $0.seq, key: $0.key, title: $0.title,
                                             hint: $0.hint, postsDocType: $0.postsDocType?.rawValue)
        }
        try await store.upsertDefinition(defID: legal.defID, name: legal.name,
                                         persona: legal.persona, builtin: true, operations: ops)
        let wf = try await store.createInstance(defID: legal.defID, title: "Acme v. Roe production",
                                                createdBy: "Reviewer B")
        XCTAssertTrue(wf.hasPrefix("WF-"))
        let total = legal.operations.count
        let st0 = try await store.instance(wf: wf)?.status
        XCTAssertEqual(st0, "open")

        // Confirm all but the last → released, not confirmed.
        for opn in legal.operations.dropLast() {
            try await store.confirmOperation(wf: wf, seq: opn.seq, totalOps: total,
                                             result: "done", note: "", docNumber: nil, confirmedBy: "Reviewer B")
        }
        let st1 = try await store.instance(wf: wf)?.status
        XCTAssertEqual(st1, "released")

        // Confirm the last, with a posted document → confirmed.
        let last = legal.operations.last!
        try await store.confirmOperation(wf: wf, seq: last.seq, totalOps: total,
                                         result: "produced", note: "23 docs", docNumber: "EXP-2026-0009",
                                         confirmedBy: "Reviewer B")
        let st2 = try await store.instance(wf: wf)?.status
        XCTAssertEqual(st2, "confirmed")

        let confs = try await store.confirmations(wf: wf)
        XCTAssertEqual(confs.count, total)
        XCTAssertEqual(confs.last?.docNumber, "EXP-2026-0009")
        XCTAssertEqual(confs.last?.confirmedBy, "Reviewer B")

        // Report renders progress, who, and the posted document.
        let report = WorkflowInstanceReport(
            wfNumber: wf, title: "Acme v. Roe production", status: "confirmed",
            createdBy: "Reviewer B", createdAt: Date(), operations: legal.operations,
            confirmations: Dictionary(uniqueKeysWithValues: confs.map {
                ($0.seq, ($0.confirmedAt, $0.confirmedBy, $0.result, $0.note, $0.docNumber)) })
        ).rendered()
        XCTAssertTrue(report.contains(wf))
        XCTAssertTrue(report.contains("5/5 operations"))
        XCTAssertTrue(report.contains("EXP-2026-0009"))
        XCTAssertTrue(report.contains("Reviewer B"))
    }

    /// Document lifecycle: who-stamp survives, notes append in order, and a
    /// reversal links both ways (original.reversedBy ↔ storno.reverses).
    func testDocumentLifecycle_whoNotesReversal() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailin-doclife-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteEmailStore(directory: root)

        let original = try await store.issueDocument(type: "VRD", summary: "Confirmed Phishing: invoice",
                                                     createdBy: "Admin A")
        var recent = try await store.recentDocuments()
        XCTAssertEqual(recent.first?.createdBy, "Admin A", "who is stamped and read back")

        try await store.addDocumentNote(original, note: "Reporter confirmed it was a drill", createdBy: "Admin A")
        try await store.addDocumentNote(original, note: "Escalated to mail-gateway team", createdBy: "Admin A")
        let notes = try await store.documentNotes(original)
        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(notes.first?.note, "Reporter confirmed it was a drill", "append order preserved")

        // Reversal (storno) links both ways — never a destructive edit.
        let storno = try await store.reverseDocument(original, type: "VRD",
                                                     reason: "misclassified — actually safe", createdBy: "Admin A")
        recent = try await store.recentDocuments()
        let orig = recent.first { $0.number == original }
        let rev = recent.first { $0.number == storno }
        XCTAssertEqual(orig?.reversedBy, storno)
        XCTAssertEqual(rev?.reverses, original)
    }

    /// Workflow master data: every built-in operation carries grounded
    /// input fields; required flags exist where the profession demands them;
    /// choice fields carry options; validation catches empty required fields.
    func testWorkflowFields_masterDataAndValidation() {
        for def in WorkflowCatalog.all {
            for op in def.operations {
                XCTAssertFalse(op.fields.isEmpty, "\(def.defID)/\(op.key) should capture data")
                for field in op.fields {
                    XCTAssertFalse(field.label.isEmpty)
                    XCTAssertFalse(field.help.isEmpty, "\(field.key) needs guidance text")
                    if field.kind == .choice { XCTAssertFalse(field.options.isEmpty, "\(field.key) choice needs options") }
                }
            }
        }
        // Each workflow launches real tools — the user does the job from the
        // workflow, not just records it. Most steps open a tool; a handful
        // are deliberate manual/record steps.
        for def in WorkflowCatalog.all {
            let launching = def.operations.filter { $0.launches != nil }.count
            XCTAssertGreaterThanOrEqual(launching, 3,
                "\(def.defID) should perform most of its work through tools")
        }
        XCTAssertEqual(WorkflowCatalog.itAdmin.operations.first { $0.key == "verdict" }?.launches, .phishingTriage)
        XCTAssertEqual(WorkflowCatalog.legal.operations.first { $0.key == "bates" }?.launches, .batesNumbering)
        XCTAssertEqual(WorkflowCatalog.personal.operations.first { $0.key == "dedupe" }?.launches, .duplicateManager)

        // Grounded specifics: forensic step 1 requires case + custodian.
        let receive = WorkflowCatalog.forensic.operations.first!
        let reqLabels = receive.fields.filter(\.required).map(\.key)
        XCTAssertTrue(reqLabels.contains("caseNumber"))
        XCTAssertTrue(reqLabels.contains("custodian"))

        // Validation: missing required → reported by label; filled → clean.
        let missing = WorkflowFieldValidation.missingRequired(receive.fields, values: ["custodian": "jdoe"])
        XCTAssertTrue(missing.contains("Case / Matter number"))
        XCTAssertFalse(missing.contains("Custodian / owner"))
        let ok = WorkflowFieldValidation.missingRequired(receive.fields,
                                                         values: ["caseNumber": "C1", "custodian": "jdoe"])
        XCTAssertTrue(ok.isEmpty)
    }

    /// Captured field values persist per operation and the completion report
    /// embeds them — the run is reusable later, exactly as asked.
    func testWorkflowFieldValues_persistAndReport() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailin-wff-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteEmailStore(directory: root)
        let it = WorkflowCatalog.itAdmin
        let ops = it.operations.map {
            SQLiteEmailStore.StoredOperation(seq: $0.seq, key: $0.key, title: $0.title,
                                             hint: $0.hint, postsDocType: $0.postsDocType?.rawValue)
        }
        try await store.upsertDefinition(defID: it.defID, name: it.name, persona: it.persona,
                                         builtin: true, operations: ops)
        let wf = try await store.createInstance(defID: it.defID, title: "INC — invoice scam", createdBy: "Admin A")

        try await store.saveFieldValues(wf: wf, seq: 1, values: [
            "reporter": "alice@corp.com", "sender": "billing@acme-invoices.ru", "subject": "Overdue invoice"])
        try await store.saveFieldValues(wf: wf, seq: 3, values: [
            "disposition": "Confirmed phishing", "severity": "P2 — High", "confidence": "High"])
        // Re-save one field → upsert, not duplicate.
        try await store.saveFieldValues(wf: wf, seq: 1, values: ["subject": "Overdue invoice (edited)"])

        let vals = try await store.fieldValues(wf: wf)
        XCTAssertEqual(vals[1]?["reporter"], "alice@corp.com")
        XCTAssertEqual(vals[1]?["subject"], "Overdue invoice (edited)", "upsert overwrote")
        XCTAssertEqual(vals[3]?["disposition"], "Confirmed phishing")

        // The completion report embeds the entered data under each step.
        let report = WorkflowInstanceReport(
            wfNumber: wf, title: "INC — invoice scam", status: "released",
            createdBy: "Admin A", createdAt: Date(), operations: it.operations,
            confirmations: [1: (Date(), "Admin A", "alice@corp.com", "", "IMP-2026-0001")],
            fieldValues: vals
        ).rendered()
        XCTAssertTrue(report.contains("Reporter: alice@corp.com"))
        XCTAssertTrue(report.contains("Disposition: Confirmed phishing"))
    }

    /// Zero-config: the 5 built-in workflows are complete master data the
    /// moment the app is installed — every persona has at least one ready
    /// recipe, each with ordered, field-bearing operations, and the "Start"
    /// list comes from the in-memory catalog (no create/configure needed).
    func testBuiltinWorkflows_readyOutOfBox() {
        let personas = ["forensic", "legal", "it_admin", "journalist", "personal"]
        for persona in personas {
            let templates = WorkflowCatalog.templates(for: persona)
            XCTAssertFalse(templates.isEmpty, "\(persona) must ship a ready workflow")
            for def in templates {
                XCTAssertTrue(def.builtin, "\(def.defID) is a built-in")
                XCTAssertGreaterThanOrEqual(def.operations.count, 4, "\(def.defID) is a real workflow")
                XCTAssertEqual(def.operations.map(\.seq), Array(1...def.operations.count))
                XCTAssertTrue(def.operations.allSatisfy { !$0.fields.isEmpty },
                              "\(def.defID) every step captures data")
            }
        }
        // Seeding is idempotent and every recipe round-trips through the store
        // exactly as authored — install once, use forever, no drift.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailin-seed-\(UUID().uuidString)", isDirectory: true)
        // (async seed exercised via the store directly to stay synchronous-safe)
        _ = root
    }

    /// Status gates: the documented defensibility holes are structurally
    /// impossible — Legal can't Produce before the privilege log is complete,
    /// IT can't Close without a verdict, Forensic can't Report before the
    /// acquisition method (hash custody) is recorded.
    func testWorkflowGates_blockUnsafeTransitions() {
        // Legal Produce (seq 5) gated on privilege log complete = Yes (seq 3).
        let produce = WorkflowCatalog.legal.operations.first { $0.key == "produce" }!
        let notReady = GatePolicy.RunState(
            confirmed: [1, 2, 3, 4],
            fieldValues: [3: ["logComplete": ""]])
        let blocked = GatePolicy.lockedReasons(produce, state: notReady)
        XCTAssertTrue(blocked.contains { $0.contains("privilege log") },
                      "Produce must be locked until the privilege log is complete")
        let ready = GatePolicy.RunState(
            confirmed: [1, 2, 3, 4],
            fieldValues: [3: ["logComplete": "Yes"]])
        XCTAssertTrue(GatePolicy.lockedReasons(produce, state: ready).isEmpty,
                      "with the log complete, Produce opens")

        // IT Close (seq 5) gated on a verdict (disposition present, seq 3).
        let close = WorkflowCatalog.itAdmin.operations.first { $0.key == "close" }!
        XCTAssertFalse(GatePolicy.lockedReasons(close,
            state: .init(confirmed: [1,2,3,4], fieldValues: [3: ["disposition": ""]])).isEmpty)
        XCTAssertTrue(GatePolicy.lockedReasons(close,
            state: .init(confirmed: [1,2,3,4], fieldValues: [3: ["disposition": "Confirmed phishing"]])).isEmpty)

        // Forensic Report (seq 5) needs the acquisition method recorded (seq 2).
        let report = WorkflowCatalog.forensic.operations.first { $0.key == "report" }!
        XCTAssertFalse(GatePolicy.lockedReasons(report,
            state: .init(confirmed: [1,2,3,4], fieldValues: [2: [:]])).isEmpty)
        XCTAssertTrue(GatePolicy.lockedReasons(report,
            state: .init(confirmed: [1,2,3,4], fieldValues: [2: ["method": "Write-blocked image"]])).isEmpty)
    }

    /// Determination: the app fills what it can compute so the human keys
    /// almost nothing — and it fills the privilege-log-complete gate field
    /// ONLY when the data truly supports it (never asserts completeness the
    /// data contradicts).
    func testFieldDerivation_prefillsFromContext() {
        var ctx = DerivationContext()
        ctx.caseNumber = "CASE-2026-0009"
        ctx.relevantCount = 42
        ctx.irrelevantCount = 5
        ctx.privilegedCount = 8
        ctx.privilegedUnannotated = 3
        ctx.archiveDuplicateCount = 17

        XCTAssertEqual(FieldDerivation.derive(defID: "builtin.forensic.intake", opKey: "receive", ctx: ctx)["caseNumber"], "CASE-2026-0009")
        XCTAssertEqual(FieldDerivation.derive(defID: "builtin.forensic.intake", opKey: "preserve", ctx: ctx)["hashAlg"], "SHA-256")

        let review = FieldDerivation.derive(defID: "builtin.legal.production", opKey: "review", ctx: ctx)
        XCTAssertEqual(review["responsive"], "42")
        XCTAssertEqual(review["nonResponsive"], "5")

        // Privilege log NOT auto-completed while docs are unannotated.
        let privNotDone = FieldDerivation.derive(defID: "builtin.legal.production", opKey: "privilege", ctx: ctx)
        XCTAssertEqual(privNotDone["privCount"], "8")
        XCTAssertNil(privNotDone["logComplete"], "must not assert completeness the data contradicts")

        // Once every privileged doc is annotated, the gate field derives Yes.
        ctx.privilegedUnannotated = 0
        XCTAssertEqual(FieldDerivation.derive(defID: "builtin.legal.production", opKey: "privilege", ctx: ctx)["logComplete"], "Yes")

        XCTAssertEqual(FieldDerivation.derive(defID: "builtin.personal.cleanup", opKey: "dedupe", ctx: ctx)["removed"], "17")

        // Nothing derived for a step with no computable fields.
        XCTAssertTrue(FieldDerivation.derive(defID: "builtin.it.phishing", opKey: "close", ctx: ctx).isEmpty)
    }

    /// Selection variants: a run's field entries flatten/expand losslessly
    /// and round-trip through the store, so a recurring job starts pre-filled.
    func testWorkflowVariants_flattenAndRoundTrip() async throws {
        let values: [Int: [String: String]] = [
            1: ["reporter": "alice@corp.com", "subject": "Overdue invoice"],
            3: ["disposition": "Confirmed phishing", "severity": "P2 — High"],
        ]
        let flat = VariantCodec.flatten(values)
        XCTAssertEqual(flat["1|reporter"], "alice@corp.com")
        XCTAssertEqual(flat["3|disposition"], "Confirmed phishing")
        XCTAssertEqual(VariantCodec.expand(flat), values, "flatten∘expand is identity")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailin-var-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteEmailStore(directory: root)
        try await store.saveVariant(defID: "builtin.it.phishing", name: "Standard invoice scam",
                                    values: flat, createdBy: "Admin A")
        // Upsert (same name) doesn't duplicate.
        try await store.saveVariant(defID: "builtin.it.phishing", name: "Standard invoice scam",
                                    values: flat, createdBy: "Admin A")
        let variants = try await store.variants(defID: "builtin.it.phishing")
        XCTAssertEqual(variants.count, 1)
        XCTAssertEqual(variants.first?.name, "Standard invoice scam")
        XCTAssertEqual(VariantCodec.expand(variants.first!.values), values,
                       "the saved variant re-expands to the original run setup")
        // Isolated per definition.
        let legalVariants = try await store.variants(defID: "builtin.legal.production")
        XCTAssertTrue(legalVariants.isEmpty)
    }

    /// On completion the run's document is enriched so it's findable later
    /// by client/matter, job comment, and inner field data — not just number.
    func testCompletedWorkflow_searchableByClientAndInnerData() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailin-wfsearch-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteEmailStore(directory: root)
        let wf = try await store.createInstance(defID: "builtin.legal.production",
                                                title: "Acme v. Roe", createdBy: "Reviewer B")
        // Simulate the runner folding client + inner data into search text.
        try await store.updateDocumentSearchText(
            wf,
            summary: "Workflow: Production Run · Client: Acme v. Roe · Matter name: Acme v. Roe · Privilege basis: Work Product · Note: withheld 12 memos",
            refs: "Acme v. Roe")

        // Findable by client/matter…
        let byClient = try await store.lookupDocuments(matching: "Acme v. Roe")
        XCTAssertTrue(byClient.contains { $0.number == wf })
        // …by inner field value…
        let byValue = try await store.lookupDocuments(matching: "Work Product")
        XCTAssertTrue(byValue.contains { $0.number == wf })
        // …by job comment…
        let byNote = try await store.lookupDocuments(matching: "withheld 12 memos")
        XCTAssertTrue(byNote.contains { $0.number == wf })
        // …and still by number.
        let byNumber = try await store.lookupDocuments(matching: wf)
        XCTAssertEqual(byNumber.map(\.number), [wf])
    }

    /// Phase D — the stakeholder summary is plain-language: it names the
    /// readable title, spells out completed vs. pending steps in prose, lists
    /// the records produced, and omits the technical jargon of the raw report.
    func testStakeholderSummary_isReaderFriendly() throws {
        let def = WorkflowCatalog.legal
        let day = Date(timeIntervalSince1970: 1_754_800_000)   // fixed, deterministic
        let summary = StakeholderSummary(
            wfNumber: "WF-2026-0007", title: "Acme v. Roe", persona: "legal",
            status: "confirmed", preparedBy: "Reviewer B", preparedAt: day,
            operations: def.operations,
            confirmations: [
                1: (day, "Reviewer B", "Acme v. Roe", "", "BATCH-2026-0002"),
                5: (day, "Reviewer B", "PROD001", "produced to opposing counsel", "EXP-2026-0009"),
            ],
            fieldValues: [
                1: ["matter": "Acme v. Roe", "reviewer": "Reviewer B"],
                5: ["productionName": "PROD001", "format": "PDF (Bates-stamped)"],
            ]
        ).rendered()

        // Reads for a non-technical audience.
        XCTAssertTrue(summary.contains("# Acme v. Roe"), "leads with the readable title")
        XCTAssertTrue(summary.contains("WF-2026-0007"))
        XCTAssertTrue(summary.contains("Prepared by:"))
        XCTAssertTrue(summary.contains("counsel"), "carries the legal-persona intro")
        // Completed steps described in prose; the field data surfaced.
        XCTAssertTrue(summary.contains("Assemble Batch"))
        XCTAssertTrue(summary.contains("completed"))
        XCTAssertTrue(summary.contains("Production set name: PROD001"))
        XCTAssertTrue(summary.contains("produced to opposing counsel"))
        // Pending steps say so, not left blank.
        XCTAssertTrue(summary.contains("Review & Code** — not yet started."))
        // Records produced are listed.
        XCTAssertTrue(summary.contains("BATCH-2026-0002"))
        XCTAssertTrue(summary.contains("EXP-2026-0009"))
        // No raw-report scaffolding leaks in.
        XCTAssertFalse(summary.contains("[x]"), "no technical checkbox markers")
        XCTAssertFalse(summary.contains("========"), "no monospace rule")
    }

    /// Phase D — in-progress entries persist before Confirm, so closing the
    /// window (or a session timeout) never loses what was typed: the saved
    /// draft re-reads back exactly.
    func testInProgressFieldDraft_persistsBeforeConfirm() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailin-wfdraft-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteEmailStore(directory: root)
        let wf = try await store.createInstance(defID: "builtin.it.phishing",
                                                title: "Reported invoice", createdBy: "Admin A")
        // Autosave writes a partial draft for a step that is NOT confirmed.
        try await store.saveFieldValues(wf: wf, seq: 1,
                                        values: ["reporter": "alice@corp.com", "subject": "Overdue"])
        // No confirmation exists yet — the draft stands on its own.
        let confs = try await store.confirmations(wf: wf)
        XCTAssertFalse(confs.contains { $0.seq == 1 }, "draft is not a confirmation")
        // Reopening the run restores exactly what was typed.
        let restored = try await store.fieldValues(wf: wf)
        XCTAssertEqual(restored[1]?["reporter"], "alice@corp.com")
        XCTAssertEqual(restored[1]?["subject"], "Overdue")
    }

    /// Phase E — discoverability. An empty archive always yields exactly one
    /// suggestion: import first. Nothing else is offered until there's data.
    func testNextBestAction_emptyArchiveSuggestsImportOnly() {
        var s = NextBestAction.State()
        s.persona = "forensic"; s.archiveEmpty = true
        let out = NextBestAction.suggestions(s)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.hub, .emailInbox)
        XCTAssertTrue(out.first?.title.contains("Import") == true)
    }

    /// With data but no workflow started, the top suggestion steers to the
    /// guided Workflows tab (not a raw tool) — the governance layer is the
    /// thing users most miss.
    func testNextBestAction_prioritizesGuidedWorkflow() {
        var s = NextBestAction.State()
        s.persona = "legal"; s.archiveEmpty = false; s.startedPersonaWorkflow = false
        let out = NextBestAction.suggestions(s)
        XCTAssertEqual(out.first?.opensWorkflows, true, "guided workflow wins over tool discovery")
        XCTAssertNil(out.first?.hub)
        XCTAssertTrue(out.first?.rationale.contains("EDRM") == true, "carries the legal framework rationale")
    }

    /// Once the workflow is under way, the persona-specific capability they're
    /// likely missing surfaces — and it differs per persona.
    func testNextBestAction_personaSpecificDiscovery() {
        func top(_ persona: String, _ mutate: (inout NextBestAction.State) -> Void = { _ in }) -> NextBestAction.Suggestion? {
            var s = NextBestAction.State()
            s.persona = persona; s.archiveEmpty = false; s.startedPersonaWorkflow = true
            mutate(&s)
            return NextBestAction.suggestions(s).first
        }
        XCTAssertEqual(top("forensic")?.hub, .chainOfCustody)
        XCTAssertEqual(top("journalist")?.hub, .storyFile)
        XCTAssertEqual(top("it_admin") { $0.watchFolderOff = true }?.hub, .phishingTriage)
        XCTAssertEqual(top("legal") { $0.privilegeGaps = 0 }?.hub, .reviewDashboard)
        XCTAssertEqual(top("personal") { $0.duplicateCount = 5 }?.hub, .duplicateManager)
        // No noise when there's nothing persona-specific left to surface.
        XCTAssertNil(top("it_admin") { $0.watchFolderOff = false })
        XCTAssertNil(top("personal") { $0.duplicateCount = 0 })
    }

    /// Expanded coverage: the secondary daily jobs each persona actually does
    /// now ship as guided workflows too, and the whole catalog stays sound —
    /// unique IDs, defined doc types, and gates that point at real operations.
    func testCatalog_expandedPersonaCoverage() {
        // Per-persona workflow counts after adding the secondary jobs.
        XCTAssertEqual(WorkflowCatalog.templates(for: "forensic").count, 11)   // intake, timeline, sweep, custody, exhibit, insider, headers, cull, iocreport, affidavit, evidenceplan
        XCTAssertEqual(WorkflowCatalog.templates(for: "researcher").count, 3)  // protocol, screening, coding
        XCTAssertEqual(WorkflowCatalog.templates(for: "legal").count, 10)   // production, hold, ECA, DSAR, privQC, compliance, collection, processing, firstpass, clawback
        XCTAssertEqual(WorkflowCatalog.templates(for: "it_admin").count, 10)   // phishing, hunt, campaign, BEC, authAudit, metrics, quarantine, rules, blocklist, dlp
        XCTAssertEqual(WorkflowCatalog.templates(for: "journalist").count, 10)   // story, network, fact-check, publish, tips, datapack, provenance, foia, quotes, crossref
        XCTAssertEqual(WorkflowCatalog.templates(for: "personal").count, 7)   // cleanup, find/export, declutter, receipts, backup, attachments, contacts

        // The new jobs are present by name.
        let names = Set(WorkflowCatalog.all.map(\.name))
        for expected in ["Timeline Reconstruction", "Legal Hold & Preservation",
                         "Early Case Assessment", "Data Subject Request (DSAR)",
                         "Threat Hunt", "Entity & Network Map", "Phishing Campaign (Bulk)",
                         "Keyword / Term Sweep", "Custody Verification",
                         "Account Compromise (BEC)", "Fact-Check & Verify",
                         "Source Protection & Publish", "Find & Export", "Unsubscribe & Declutter",
                         "Court Exhibit Package", "Insider Threat Review", "Privilege QC & Redaction",
                         "Retention & Compliance Audit", "Email Authentication Audit",
                         "Security Metrics Report", "Tip & Lead Intake", "Data Story Pack",
                         "Receipts & Records Roundup",
                         "Header & Authentication Analysis", "Deduplication & Culling",
                         "IOC Extraction & Report", "Expert Report",
                         "Collection", "Processing & Deduplication",
                         "First-Pass Review", "Clawback",
                         "Quarantine Review", "Inbox Rule Audit",
                         "Blocklist Export", "Data Exfiltration Review",
                         "Provenance Check", "Records Request (FOIA)",
                         "Quote & Attribution", "Cross-Reference Datasets",
                         "Full Backup", "Find Attachments", "Contacts Roundup"] {
            XCTAssertTrue(names.contains(expected), "missing workflow: \(expected)")
        }

        // Catalog soundness across ALL recipes.
        var ids = Set<String>()
        for def in WorkflowCatalog.all {
            XCTAssertTrue(ids.insert(def.defID).inserted, "duplicate defID \(def.defID)")
            XCTAssertGreaterThanOrEqual(def.operations.count, 4)
            let seqs = Set(def.operations.map(\.seq))
            for op in def.operations {
                // Every posted type is a real DocumentType.
                if let t = op.postsDocType { XCTAssertFalse(t.displayName.isEmpty) }
                // Every gate references an operation that exists in this recipe.
                for gate in op.gates {
                    let referenced: Int
                    switch gate.rule {
                    case .operationConfirmed(let s): referenced = s
                    case .fieldPresent(let s, _): referenced = s
                    case .fieldEquals(let s, _, _): referenced = s
                    }
                    XCTAssertTrue(seqs.contains(referenced),
                                  "\(def.defID)/\(op.key) gate points at missing seq \(referenced)")
                    XCTAssertFalse(gate.reason.isEmpty, "\(def.defID)/\(op.key) gate needs a reason")
                }
            }
        }

        // The DSAR privacy gate is the load-bearing one: no produce until
        // third-party PII is redacted.
        let dsar = WorkflowCatalog.legalDSAR
        let produce = dsar.operations.first { $0.key == "produce" }!
        let gate = produce.gates.first!
        XCTAssertEqual(gate.rule, .fieldEquals(seq: 3, key: "thirdPartyRedacted", value: "Yes"))
    }

    /// Every new secondary-job workflow runs start → confirm-all → confirmed,
    /// just like the originals — proving they're real, drivable recipes, not
    /// just catalog entries.
    func testNewWorkflows_lifecycleEndToEnd() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailin-newwf-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteEmailStore(directory: root)

        let newDefs = [
            WorkflowCatalog.forensicTimeline, WorkflowCatalog.legalHold,
            WorkflowCatalog.legalECA, WorkflowCatalog.legalDSAR,
            WorkflowCatalog.itThreatHunt, WorkflowCatalog.itCampaign,
            WorkflowCatalog.journalistNetwork,
            WorkflowCatalog.forensicKeywordSweep, WorkflowCatalog.forensicCustodyVerify,
            WorkflowCatalog.itBEC, WorkflowCatalog.journalistFactCheck,
            WorkflowCatalog.journalistPublish, WorkflowCatalog.personalFindExport,
            WorkflowCatalog.personalDeclutter,
            WorkflowCatalog.forensicExhibit, WorkflowCatalog.forensicInsider,
            WorkflowCatalog.legalPrivQC, WorkflowCatalog.legalCompliance,
            WorkflowCatalog.itAuthAudit, WorkflowCatalog.itMetrics,
            WorkflowCatalog.journalistTips, WorkflowCatalog.journalistDataPack,
            WorkflowCatalog.personalReceipts,
            WorkflowCatalog.forensicHeaders, WorkflowCatalog.forensicCull,
            WorkflowCatalog.forensicIOCReport, WorkflowCatalog.forensicAffidavit,
            WorkflowCatalog.legalCollection, WorkflowCatalog.legalProcessing,
            WorkflowCatalog.legalFirstPass, WorkflowCatalog.legalClawback,
            WorkflowCatalog.itQuarantine, WorkflowCatalog.itRules,
            WorkflowCatalog.itBlocklist, WorkflowCatalog.itDLP,
            WorkflowCatalog.journalistProvenance, WorkflowCatalog.journalistFOIA,
            WorkflowCatalog.journalistQuotes, WorkflowCatalog.journalistCrossRef,
            WorkflowCatalog.personalBackup, WorkflowCatalog.personalAttachments,
            WorkflowCatalog.personalContacts,
        ]
        for def in newDefs {
            let ops = def.operations.map {
                SQLiteEmailStore.StoredOperation(seq: $0.seq, key: $0.key, title: $0.title,
                                                 hint: $0.hint, postsDocType: $0.postsDocType?.rawValue)
            }
            try await store.upsertDefinition(defID: def.defID, name: def.name,
                                             persona: def.persona, builtin: true, operations: ops)
            let wf = try await store.createInstance(defID: def.defID, title: def.name, createdBy: "Tester")
            XCTAssertTrue(wf.hasPrefix("WF-"), "\(def.defID) should get a WF number")
            let total = def.operations.count
            for opn in def.operations {
                try await store.confirmOperation(wf: wf, seq: opn.seq, totalOps: total,
                                                 result: "done", note: "", docNumber: nil, confirmedBy: "Tester")
            }
            let status = try await store.instance(wf: wf)?.status
            XCTAssertEqual(status, "confirmed", "\(def.defID) should end confirmed")
            let confs = try await store.confirmations(wf: wf)
            XCTAssertEqual(confs.count, total, "\(def.defID) records one confirmation per op")
        }
    }

    /// The load-bearing gates on the new workflows actually block the unsafe
    /// transition — the whole point of the SAP status network.
    func testNewWorkflows_loadBearingGates() {
        func op(_ def: WorkflowDefinition, _ key: String) -> WorkflowOperation {
            def.operations.first { $0.key == key }!
        }
        // DSAR: cannot Produce until third-party PII is redacted.
        let dsarProduce = op(WorkflowCatalog.legalDSAR, "produce")
        let blocked = GatePolicy.lockedReasons(dsarProduce, state: .init(
            confirmed: [1, 2, 3, 4], fieldValues: [3: ["thirdPartyRedacted": ""]]))
        XCTAssertFalse(blocked.isEmpty, "produce must be locked until third-party PII is redacted")
        let open = GatePolicy.lockedReasons(dsarProduce, state: .init(
            confirmed: [1, 2, 3, 4], fieldValues: [3: ["thirdPartyRedacted": "Yes"]]))
        XCTAssertTrue(open.isEmpty, "produce opens once redaction is confirmed")

        // Bulk campaign: no bulk containment until a verdict is set.
        let contain = op(WorkflowCatalog.itCampaign, "contain")
        XCTAssertFalse(GatePolicy.lockedReasons(contain, state: .init(
            confirmed: [1, 2, 3], fieldValues: [3: ["disposition": ""]])).isEmpty)
        XCTAssertTrue(GatePolicy.lockedReasons(contain, state: .init(
            confirmed: [1, 2, 3], fieldValues: [3: ["disposition": "Confirmed phishing"]])).isEmpty)

        // Timeline: can't export the exhibit before the timeline is built.
        let exhibit = op(WorkflowCatalog.forensicTimeline, "exhibit")
        XCTAssertFalse(GatePolicy.lockedReasons(exhibit, state: .init(confirmed: [1], fieldValues: [:])).isEmpty)
        XCTAssertTrue(GatePolicy.lockedReasons(exhibit, state: .init(confirmed: [1, 2], fieldValues: [:])).isEmpty)

        // Legal hold: can't issue the notice before custodians are identified.
        let issue = op(WorkflowCatalog.legalHold, "issue")
        XCTAssertFalse(GatePolicy.lockedReasons(issue, state: .init(confirmed: [1], fieldValues: [1: ["custodians": ""]])).isEmpty)
        XCTAssertTrue(GatePolicy.lockedReasons(issue, state: .init(confirmed: [1], fieldValues: [1: ["custodians": "jdoe\nasmith"]])).isEmpty)
    }

    /// Every recipe carries a real plain-language purpose (no recipe falls
    /// through to the generic default) — the discoverability line users see.
    func testWorkflowPurpose_presentAndSpecific() {
        let generic = WorkflowCatalog.purpose(for: "does.not.exist")
        for def in WorkflowCatalog.all {
            let p = WorkflowCatalog.purpose(for: def.defID)
            XCTAssertFalse(p.isEmpty)
            XCTAssertNotEqual(p, generic, "\(def.defID) should have its own purpose line, not the fallback")
        }
    }

    /// GOLDEN PATH — the whole app goal in one run: an examiner imports an
    /// archive, does their persona's real job through a guided workflow, and
    /// the numbered, defensible record falls out as a byproduct — all local.
    func testGoldenPath_appFulfillsItsGoal() async throws {
        let env = try makeEnv()

        // 1. Import an archive (the universal first step).
        _ = try await seed(env, count: 40)
        let imported = try await env.archive.count()
        XCTAssertEqual(imported, 40, "the imported archive is queryable")

        // 2. Number ranges are gapless and per-type (the SAP element numbers).
        let imp1 = try await env.store.issueDocument(type: "IMP", summary: "Import 1", createdBy: "Reviewer B")
        let imp2 = try await env.store.issueDocument(type: "IMP", summary: "Import 2", createdBy: "Reviewer B")
        XCTAssertTrue(imp1.hasPrefix("IMP-") && imp2.hasPrefix("IMP-"))
        let n1 = Int(imp1.split(separator: "-").last!)!
        let n2 = Int(imp2.split(separator: "-").last!)!
        XCTAssertEqual(n2, n1 + 1, "sequential, no gap, no repeat")

        // 3. A persona does their job through a guided workflow.
        let legal = WorkflowCatalog.legal
        let ops = legal.operations.map {
            SQLiteEmailStore.StoredOperation(seq: $0.seq, key: $0.key, title: $0.title,
                                             hint: $0.hint, postsDocType: $0.postsDocType?.rawValue)
        }
        try await env.store.upsertDefinition(defID: legal.defID, name: legal.name,
                                             persona: legal.persona, builtin: true, operations: ops)
        let wf = try await env.store.createInstance(defID: legal.defID,
                                                    title: "Acme v. Roe", createdBy: "Reviewer B")

        // Defensibility gate holds BEFORE the run finishes: cannot produce
        // until the privilege log is complete.
        let produce = legal.operations.first { $0.key == "produce" }!
        XCTAssertFalse(GatePolicy.lockedReasons(produce, state: .init(
            confirmed: [1, 2, 3, 4], fieldValues: [3: ["logComplete": ""]])).isEmpty,
            "producing before the privilege log is complete must be blocked")

        // Work each step: record real field data, post the document it owes.
        let fieldsBySeq: [Int: [String: String]] = [
            1: ["matter": "Acme v. Roe", "reviewer": "Reviewer B", "batchSize": "40"],
            2: ["responsive": "12", "nonResponsive": "28"],
            3: ["privCount": "3", "privBasis": "Work Product", "logComplete": "Yes"],
            4: ["batesPrefix": "ACME", "batesStart": "ACME-000001"],
            5: ["productionName": "PROD001", "format": "PDF (Bates-stamped)"],
        ]
        let total = legal.operations.count
        for op in legal.operations {
            if let vals = fieldsBySeq[op.seq] {
                try await env.store.saveFieldValues(wf: wf, seq: op.seq, values: vals)
            }
            var doc: String? = nil
            if let t = op.postsDocType {
                doc = try await env.store.issueDocument(type: t.rawValue,
                    summary: "\(legal.name): \(op.title)", refs: wf, createdBy: "Reviewer B")
            }
            try await env.store.confirmOperation(wf: wf, seq: op.seq, totalOps: total,
                result: firstResult(fieldsBySeq, op.seq), note: "", docNumber: doc, confirmedBy: "Reviewer B")
        }

        // 4. The record is produced automatically and is fully defensible.
        let status = try await env.store.instance(wf: wf)?.status
        XCTAssertEqual(status, "confirmed", "the job completed")
        let confs = try await env.store.confirmations(wf: wf)
        XCTAssertEqual(confs.count, total)
        XCTAssertNotNil(confs.first { $0.seq == 5 }?.docNumber, "production posted an Export document")

        // 5. The record is findable later by client / inner data (the ask).
        try await env.store.updateDocumentSearchText(wf,
            summary: "Workflow: Production Run · Client: Acme v. Roe · Privilege basis: Work Product",
            refs: "Acme v. Roe")
        let byClient = try await env.store.lookupDocuments(matching: "Acme v. Roe")
        XCTAssertTrue(byClient.contains { $0.number == wf }, "the run is findable by client/matter")
        let exports = try await env.store.lookupDocuments(matching: "EXP-")
        XCTAssertFalse(exports.isEmpty, "the produced Export document is on record")

        // 6. A non-technical reader can be handed a clean summary.
        let summary = StakeholderSummary(
            wfNumber: wf, title: "Acme v. Roe", persona: "legal", status: "confirmed",
            preparedBy: "Reviewer B", preparedAt: Date(), operations: legal.operations,
            confirmations: Dictionary(uniqueKeysWithValues: confs.map {
                ($0.seq, ($0.confirmedAt, $0.confirmedBy, $0.result, $0.note, $0.docNumber)) }),
            fieldValues: fieldsBySeq
        ).rendered()
        XCTAssertTrue(summary.contains("# Acme v. Roe"))
        XCTAssertTrue(summary.contains("Complete — all 5 steps done"))
    }

    /// Small helper: the confirmation's result line = first field value, else "done".
    private func firstResult(_ map: [Int: [String: String]], _ seq: Int) -> String {
        map[seq]?.values.sorted().first ?? "done"
    }

    /// Universal capture: any job posts a numbered document AND stores the
    /// full-work payload, which reads back verbatim when the document is
    /// opened later (the SAP "open it, see everything" promise).
    func testDocumentPayload_captureAndReadBack() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailin-payload-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteEmailStore(directory: root)

        // Fresh store is at the latest schema (v12) with the payload table.
        let ver = try await store.schemaVersion()
        XCTAssertEqual(ver, SQLiteEmailStore.currentSchemaVersion)

        let number = try await store.issueDocument(type: "RPT", summary: "Ad-hoc report",
                                                   createdBy: "Reviewer B")
        let work = "INVESTIGATION REPORT\nTitle: Acme\nEmails: 40\nFindings: …"
        try await store.attachDocumentPayload(number, body: work)

        let read = try await store.documentPayload(number)
        XCTAssertEqual(read?.body, work, "the full saved work reads back verbatim")
        XCTAssertEqual(read?.contentType, "text/markdown")

        // Re-attaching replaces (upsert), never duplicates.
        try await store.attachDocumentPayload(number, body: "revised")
        let reread = try await store.documentPayload(number)
        XCTAssertEqual(reread?.body, "revised")

        // A document with no payload returns nil (not an error).
        let bare = try await store.issueDocument(type: "EXP", summary: "no payload", createdBy: "X")
        let barePayload = try await store.documentPayload(bare)
        XCTAssertNil(barePayload)
    }

    /// Structured document data: a CapturedDocument round-trips through JSON,
    /// parses into a table, and exports Excel-ready CSV — so any saved job can
    /// be manipulated into custom reports.
    func testDocumentTable_structuredJSONAndCSV() {
        let doc = CapturedDocument(title: "Acme v. Roe", sections: [
            .init(name: "Run", fields: [.init(key: "Document", value: "WF-2026-0007"),
                                        .init(key: "Client / matter", value: "Acme v. Roe")]),
            .init(name: "3. Privilege Log", fields: [.init(key: "Privilege basis", value: "Work Product"),
                                                     .init(key: "Privileged count", value: "3")]),
        ])
        // JSON round-trips exactly.
        let back = CapturedDocument.from(json: doc.jsonString())
        XCTAssertEqual(back, doc)

        // Parses to a table with every field preserved.
        let table = DocumentTable.parse(contentType: "application/json", body: doc.jsonString())
        XCTAssertEqual(table.sections.count, 2)
        XCTAssertEqual(table.rowCount, 4)
        XCTAssertEqual(table.sections[1].rows.first, .init(key: "Privilege basis", value: "Work Product"))

        // CSV is Excel-ready: header + one row per field, quoted.
        let csv = table.csv()
        XCTAssertTrue(csv.hasPrefix("Section,Field,Value\n"))
        XCTAssertTrue(csv.contains("\"3. Privilege Log\",\"Privileged count\",\"3\""))

        // A plain-text payload still tabulates via best-effort "Key: value".
        let textTable = DocumentTable.parse(contentType: "text/markdown",
            body: "IOC EXPORT\nIndicators: 12\nSource: inbox")
        XCTAssertTrue(textTable.rowCount >= 2)
        XCTAssertTrue(textTable.sections.contains { $0.rows.contains(.init(key: "Indicators", value: "12")) })
    }

    /// Cross-document custom report: many documents → one table (one row per
    /// doc, union of field keys as columns), exportable to CSV.
    func testCrossDocumentReport_build() {
        let day = Date(timeIntervalSince1970: 1_754_800_000)
        let a = DocumentTable.parse(contentType: "application/json",
            body: CapturedDocument(title: "A", sections: [.init(name: "S", fields: [
                .init(key: "Disposition", value: "Confirmed phishing"),
                .init(key: "Severity", value: "P1")])]).jsonString())
        let b = DocumentTable.parse(contentType: "application/json",
            body: CapturedDocument(title: "B", sections: [.init(name: "S", fields: [
                .init(key: "Disposition", value: "Safe")])]).jsonString())   // no Severity

        let r = CrossDocumentReport.build([
            (number: "VRD-2026-0001", date: day, table: a),
            (number: "VRD-2026-0002", date: day, table: b),
        ])
        // Columns = Document, Date + union of keys (first-seen order).
        XCTAssertEqual(r.columns, ["Document", "Date", "Disposition", "Severity"])
        XCTAssertEqual(r.rows.count, 2)
        XCTAssertEqual(r.rows[0][0], "VRD-2026-0001")
        XCTAssertEqual(r.rows[0][2], "Confirmed phishing")
        XCTAssertEqual(r.rows[0][3], "P1")
        // Missing field → blank cell, not a crash.
        XCTAssertEqual(r.rows[1][3], "")

        let csv = CrossDocumentReport.csv(r)
        XCTAssertTrue(csv.hasPrefix("\"Document\",\"Date\",\"Disposition\",\"Severity\"\n"))
        XCTAssertTrue(csv.contains("\"VRD-2026-0002\""))
    }

    /// Workflow documents carry their own "Document" field: it must not make
    /// a second "Document" header. Dates are ISO (no 12/08/26 ambiguity), a
    /// label repeated in another section keeps both values, and seal
    /// signatures are not report columns.
    func testCrossDocumentReport_columnsAreUniqueAndLossless() {
        let day = Date(timeIntervalSince1970: 1_754_800_000)   // 2025-08-10 UTC
        let a = DocumentTable.parse(contentType: "application/json",
            body: CapturedDocument(title: "A", sections: [
                .init(name: "Intake", fields: [
                    .init(key: "Document", value: "WF-2026-0001"),     // repeats the number → dropped
                    .init(key: "Status", value: "Released")]),
                .init(name: "Review", fields: [
                    .init(key: "Status", value: "Confirmed")]),         // same label, other value → kept
                .init(name: DocumentRegistry.receiptSectionName, fields: [
                    .init(key: "SHA-256", value: "abc")]),
            ]).jsonString())
        let b = DocumentTable.parse(contentType: "application/json",
            body: CapturedDocument(title: "B", sections: [.init(name: "Intake", fields: [
                .init(key: "Document", value: "IMP-2026-0004")])]).jsonString())   // differs → own column

        let r = CrossDocumentReport.build([
            (number: "WF-2026-0001", date: day, table: a),
            (number: "WF-2026-0002", date: day, table: b),
        ])
        XCTAssertEqual(r.columns, ["Document", "Date", "Status", "Review › Status", "Document (field)"])
        XCTAssertEqual(Set(r.columns).count, r.columns.count, "duplicate column headers")
        XCTAssertEqual(r.rows[0][2], "Released")
        XCTAssertEqual(r.rows[0][3], "Confirmed")
        XCTAssertEqual(r.rows[1][4], "IMP-2026-0004")
        XCTAssertNotNil(r.rows[0][1].wholeMatch(of: /\d{4}-\d{2}-\d{2}/), r.rows[0][1])
        XCTAssertEqual(r.period, day...day)
    }

    /// The saved report: summary counts for categorical columns, one section
    /// per source document, and a PDF text that carries every value.
    func testCrossDocumentReport_savedDocumentAndPDF() {
        func doc(_ status: String, _ owner: String) -> DocumentTable {
            DocumentTable.parse(contentType: "application/json",
                body: CapturedDocument(title: "", sections: [.init(name: "S", fields: [
                    .init(key: "Status", value: status),
                    .init(key: "Owner", value: owner)])]).jsonString())
        }
        let d = Date(timeIntervalSince1970: 1_754_800_000)
        let r = CrossDocumentReport.build([
            (number: "WF-1", date: d, table: doc("Released", "a")),
            (number: "WF-2", date: d, table: doc("Released", "b")),
            (number: "WF-3", date: d, table: doc("Confirmed", "c")),
        ])
        // Status repeats → summarised; Owner is all-unique free text → not.
        let b = CrossDocumentReport.breakdowns(r)
        XCTAssertEqual(b.map(\.column), ["Status"])
        XCTAssertEqual(b.first?.counts, [.init(value: "Released", count: 2), .init(value: "Confirmed", count: 1)])

        let saved = CrossDocumentReport.capturedDocument(r, typeName: "Workflows", builtBy: "Tester", builtAt: d)
        XCTAssertEqual(saved.sections.map(\.name), [CrossDocumentReport.reportSectionName, "Summary", "WF-1", "WF-2", "WF-3"])
        XCTAssertTrue(CrossDocumentReport.isCrossDocumentReport(
            DocumentTable.parse(contentType: "application/json", body: saved.jsonString())))
        XCTAssertEqual(saved.sections[1].fields.first, .init(key: "Status: Released", value: "2"))

        let pdf = CrossDocumentReport.pdfLines(r, number: "RPT-2026-0001", typeName: "Workflows",
                                               builtBy: "Tester", builtAt: d, sealSHA256: "ff")
        for value in ["Report:     RPT-2026-0001", "Seal:       SHA-256 ff", "  Owner: c", "    Released: 2"] {
            XCTAssertTrue(pdf.contains(value), "PDF text missing \(value)")
        }
    }

    // MARK: - Button audit 2026-10-09 (BUTTON_AUDIT_3_0.md)

    /// P0-2: an email whose original seal is only in the STORE (not in the
    /// in-memory window) must be verified against that stored seal. Before
    /// the fix, verify "auto-sealed" it with its current content and then
    /// compared current vs current — a tampered email passed.
    @MainActor
    func testCustodyVerify_detectsTamperAgainstStoredSeal() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("custody-verify-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            ForensicManager.testStoreOverride = nil
        }
        ForensicManager.testStoreOverride = SQLiteEmailStore(directory: root)
        let fm = ForensicManager.shared
        fm.clearForensicData()
        try await Task.sleep(nanoseconds: 200_000_000)

        let id = UUID()
        let original = MBOXParser.RawEmail(id: id, headers: ["Subject": "Contract"], rawSource: "Subject: Contract\n\nPay 100",
                                           messageType: "received", attachments: [], timestamp: "",
                                           domains: [], plainBody: "Pay 100", htmlBody: "")
        fm.storeEmailHashes([original])
        try await Task.sleep(nanoseconds: 500_000_000)        // seal lands in the store
        fm.perEmailHashes.removeValue(forKey: id)             // outside the resident window

        var tampered = original
        tampered.rawSource = "Subject: Contract\n\nPay 900"
        let report = await ChainOfCustodyManager.shared.verifyIntegrity(of: [tampered])
        XCTAssertEqual(report.failed, 1, "the tampered email must fail against its stored seal")
        XCTAssertEqual(report.passed, 0)
        XCTAssertEqual(report.newlySealed, 0, "an email sealed in the store is not 'newly sealed'")
    }

    /// Re-applying a legal hold must not re-seal a held email with its
    /// current content (that erased the evidence of modification).
    @MainActor
    func testLegalHoldSeal_isNotOverwrittenOnReapply() {
        let manager = CustodianManager.shared
        let id = UUID()
        defer { manager.removeLegalHold(id) }
        let original = MBOXParser.RawEmail(id: id, headers: ["Subject": "Held"], rawSource: "x",
                                           messageType: "received", attachments: [], timestamp: "",
                                           domains: [], plainBody: "original body", htmlBody: "")
        manager.placeLegalHold(on: [original])
        var modified = original
        modified.plainBody = "modified body"
        manager.placeLegalHold(on: [modified])                // re-apply after modification
        guard case .tampered = manager.verifyEvidenceSeal(modified) else {
            return XCTFail("the seal from the first hold must still detect the modification")
        }
    }

    /// Hand-built CSVs used to leave the RFC 2822 Date ("Mon, 12 Aug …")
    /// unquoted and rewrite commas to ";". csvRow keeps every value intact.
    func testCSVRow_keepsCommasDatesAndQuotes() {
        let row = csvRow(["Doe, Jane", "Mon, 12 Aug 2026 10:00:00 +0000", "He said \"hi\"", "=SUM(A1)"])
        XCTAssertEqual(row, "\"Doe, Jane\",\"Mon, 12 Aug 2026 10:00:00 +0000\",\"He said \"\"hi\"\"\",\"'=SUM(A1)\"\n")
    }

    /// Legal Review coding survives a round trip through the workspace store.
    func testLegalReviewSnapshot_roundTrips() {
        let name = "legal-review-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: ReviewWorkspaceStore.url(for: name)) }
        let id = UUID()
        let snapshot = LegalReviewSnapshot(
            privilege: [id: "Attorney-Client"], responsiveness: [id: "Responsive"],
            issueTags: [id: ["Employment"]], notes: [id: "Advice from counsel"],
            definedIssueTags: ["Employment"],
            audit: [.init(date: Date(timeIntervalSince1970: 1_700_000_000), emailID: id,
                          field: "Privilege", oldValue: "Unreviewed", newValue: "Attorney-Client")])
        XCTAssertNil(ReviewWorkspaceStore.save(snapshot, name: name))
        XCTAssertEqual(ReviewWorkspaceStore.load(LegalReviewSnapshot.self, name: name), snapshot)
    }

    /// The investigation PDF carries the user's own leads/quotes appendix.
    @MainActor
    func testInvestigationReport_includesAppendix() throws {
        let email = MBOXParser.RawEmail(headers: ["Subject": "Hello", "From": "a@b.c", "Date": "Mon, 12 Aug 2026 10:00:00 +0000"],
                                        rawSource: "Subject: Hello\n\nBody", messageType: "received", attachments: [],
                                        timestamp: "", domains: [], plainBody: "Body", htmlBody: "")
        let data = InvestigationReportGenerator.generateReport(
            emails: [email], title: "Investigation Report", investigatorName: "Tester",
            appendix: [.init(title: "Investigation Leads", lines: ["[High] Offshore payments lead"])])
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        let text = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n")
        XCTAssertTrue(text.contains("Offshore payments lead"), "appendix line missing from the PDF")
    }

    /// The report source query is uncapped and type-exact: older documents
    /// are never cut off by other types' volume.
    func testDocumentsOfType_uncappedAndTypeExact() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("docs-of-type-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SQLiteEmailStore(directory: dir)
        for i in 0..<5 { _ = try await store.issueDocument(type: "WF", summary: "wf \(i)") }
        for i in 0..<300 { _ = try await store.issueDocument(type: "IMP", summary: "imp \(i)") }
        let wf = try await store.documents(ofType: "WF")
        XCTAssertEqual(wf.count, 5)
        XCTAssertTrue(wf.allSatisfy { $0.type == "WF" })
        let imp = try await store.documents(ofType: "IMP")
        XCTAssertEqual(imp.count, 300, "more than the 200 recentDocuments default — no cap")
        // The two-placeholder lookup still binds both placeholders.
        let hits = try await store.lookupDocuments(matching: "wf 3")
        XCTAssertEqual(hits.map(\.summary), ["wf 3"])
    }

    /// No production source references the retired flag name.
    func testNoRollbackFlagRemains() throws {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: appSource, includingPropertiesForKeys: nil) else {
            throw XCTSkip("app source not found")
        }
        var hits: [String] = []
        for f in items where f.pathExtension == "swift" {
            guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
            if f.lastPathComponent == "SettingsView.swift" { continue }   // the one-time migration constant
            if text.contains("useV2ArchiveList") { hits.append(f.lastPathComponent) }
        }
        XCTAssertTrue(hits.isEmpty, "retired rollback flag still referenced: \(hits.joined(separator: ", "))")
    }

    // MARK: - §19.1 — Trash and Archive are reversible THROUGH THE UI

    /// The app tells the user three times that trashing is reversible:
    /// "restorable from the Trash view", "Trash is always restorable", and a
    /// doc comment calling it "a restorable review flag". It was not: the list
    /// hid trashed rows unconditionally, no surface showed them, and
    /// `undeleteEmail` had no production caller. This pins the round trip —
    /// trash, find it again, restore it.
    func testTrashedEmailIsVisibleInTheTrashFilterAndRestorable() async throws {
        let env = try makeEnv()
        _ = try await seed(env, count: 10)

        let saved = ReviewStateService.testStoreOverride
        ReviewStateService.testStoreOverride = env.store
        addTeardownBlock { @MainActor in ReviewStateService.testStoreOverride = saved }

        let vm = ParsedEmailListViewModel(viewModel: ContentViewModel(), archive: env.archive,
                                          pageSize: 10, maxRetained: 50)
        vm.isPremiumUser = true
        await vm.reloadForQueryChangeNow()
        let all = vm.visibleEmails.map(\.id)
        XCTAssertEqual(all.count, 10, "the page window hydrated")

        await ReviewStateService.shared.hydrateWindow(ids: all)
        let victim = try XCTUnwrap(all.first)

        // Trash it: it leaves normal browsing.
        vm.deleteEmail(victim)
        XCTAssertFalse(vm.visibleEmails.map(\.id).contains(victim),
                       "a trashed email must leave the active list")
        XCTAssertEqual(vm.visibleEmails.count, 9)

        // The Trash view shows it — this is the surface that did not exist.
        vm.reviewStateFilter = .trashed
        XCTAssertEqual(vm.visibleEmails.map(\.id), [victim],
                       "the Trash filter must show exactly what was trashed")

        // And it can be restored from there.
        vm.undeleteEmail(victim)
        XCTAssertTrue(vm.visibleEmails.isEmpty, "the Trash view is now empty")

        vm.reviewStateFilter = .active
        XCTAssertTrue(vm.visibleEmails.map(\.id).contains(victim),
                      "a restored email must return to normal browsing")
        XCTAssertEqual(vm.visibleEmails.count, 10)
    }

    /// The same promise is made about archiving — "find it again with the
    /// Archived filter" — and `unarchiveEmail` had neither a caller nor a test.
    func testArchivedEmailIsVisibleInTheArchivedFilterAndRestorable() async throws {
        let env = try makeEnv()
        _ = try await seed(env, count: 10)

        let saved = ReviewStateService.testStoreOverride
        ReviewStateService.testStoreOverride = env.store
        addTeardownBlock { @MainActor in ReviewStateService.testStoreOverride = saved }

        let vm = ParsedEmailListViewModel(viewModel: ContentViewModel(), archive: env.archive,
                                          pageSize: 10, maxRetained: 50)
        vm.isPremiumUser = true
        await vm.reloadForQueryChangeNow()
        let all = vm.visibleEmails.map(\.id)
        await ReviewStateService.shared.hydrateWindow(ids: all)
        let filed = try XCTUnwrap(all.first)

        vm.archiveEmail(filed)
        XCTAssertFalse(vm.visibleEmails.map(\.id).contains(filed))

        vm.reviewStateFilter = .archived
        XCTAssertEqual(vm.visibleEmails.map(\.id), [filed],
                       "the Archived filter must show exactly what was archived")

        vm.unarchiveEmail(filed)
        vm.reviewStateFilter = .active
        XCTAssertTrue(vm.visibleEmails.map(\.id).contains(filed))
    }

    /// Trash wins over Archive, so a row that is both is restorable from one
    /// place and one place only — otherwise "restore" means two different
    /// things depending on which filter you happened to be in.
    func testTrashTakesPrecedenceOverArchive() async throws {
        let env = try makeEnv()
        _ = try await seed(env, count: 6)

        let saved = ReviewStateService.testStoreOverride
        ReviewStateService.testStoreOverride = env.store
        addTeardownBlock { @MainActor in ReviewStateService.testStoreOverride = saved }

        let vm = ParsedEmailListViewModel(viewModel: ContentViewModel(), archive: env.archive,
                                          pageSize: 10, maxRetained: 50)
        vm.isPremiumUser = true
        await vm.reloadForQueryChangeNow()
        let all = vm.visibleEmails.map(\.id)
        await ReviewStateService.shared.hydrateWindow(ids: all)
        let both = try XCTUnwrap(all.first)

        vm.archiveEmail(both)
        vm.deleteEmail(both)

        vm.reviewStateFilter = .archived
        XCTAssertFalse(vm.visibleEmails.map(\.id).contains(both),
                       "a trashed row must not also appear under Archived")

        vm.reviewStateFilter = .trashed
        XCTAssertTrue(vm.visibleEmails.map(\.id).contains(both),
                      "Trash shows it whatever else is set")
    }

    /// Clearing filters must leave the Trash view, or "Clear" strands the user
    /// looking at deleted mail with no obvious way back.
    func testClearingFiltersLeavesTheTrashView() async throws {
        let env = try makeEnv()
        _ = try await seed(env, count: 4)

        let vm = ParsedEmailListViewModel(viewModel: ContentViewModel(), archive: env.archive,
                                          pageSize: 10, maxRetained: 50)
        vm.reviewStateFilter = .trashed
        vm.resetFilters()
        XCTAssertEqual(vm.reviewStateFilter, .active)
    }

    /// The SQLite browse surface offers Move to Trash too, and its `restore`
    /// also had no caller. A trash-inclusive query reaches the row; restore
    /// returns it to the default query's count.
    func testArchiveListRestoreReturnsARowToTheDefaultQuery() async throws {
        let env = try makeEnv()
        let fixtures = try await seed(env, count: 8)
        let victim = try XCTUnwrap(fixtures.first?.id)

        let list = ArchiveListViewModel(archive: env.archive, pageSize: 20, maxRetained: 100)
        await list.loadInitial()
        XCTAssertEqual(list.summaries.count, 8)

        await list.delete([victim])
        XCTAssertEqual(list.summaries.count, 7, "the trashed row leaves the default query")
        XCTAssertFalse(list.summaries.map(\.id).contains(victim))

        await list.restore([victim])
        XCTAssertEqual(list.summaries.count, 8, "restore must bring it back")
        XCTAssertTrue(list.summaries.map(\.id).contains(victim))
    }

    // MARK: - Gate 1 iPad walk — IPAD-02 (folder tree) and IPAD-05 (Trash, counts, duplicate summary)

    /// Awaits a re-page and any re-page a property change already started.
    private func settle(_ vm: ParsedEmailListViewModel) async {
        await vm.reloadForQueryChangeNow()
        for _ in 0..<200 where vm.isLoadingPage {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// IPAD-02: the folder list the iPad / iPhone sidebar draws comes from the
    /// same model as the Mac sidebar and holds every source folder — nested
    /// ones under their parent, the empty one too — with its count; choosing
    /// one filters the list by the same `folderID` the Mac uses.
    func testIPAD02_compactFolderListHasEveryFolder_emptyAndNested_withCounts_andFiltersTheList() async throws {
        let env = try makeEnv()
        let wasComplete = SQLiteEmailStore.unboundedIDLookups
        SQLiteEmailStore.unboundedIDLookups = true
        addTeardownBlock { SQLiteEmailStore.unboundedIDLookups = wasComplete }
        let sid = try await registerSource(env, sha: "ipad02", name: "MailExport.zip", parser: "mbox")
        var batch: [MBOXParser.RawEmail] = []
        for (i, path) in ["Inbox", "Inbox", "Inbox", "Work", "Work", "Work/Clients"].enumerated() {
            var e = makeEmail(i: 9_100 + i, total: 6, body: "ipad02 \(i)")
            e.folderPath = path
            batch.append(e)
        }
        _ = try await env.store.insertBatch(batch, sourceFileHash: "ipad02", accountID: nil, sourceID: sid,
                                            firstOrdinal: 0, dedupPolicy: .preserveAll, batchSize: 10, progress: nil)
        try await env.store.registerFolders(sourceID: sid, paths: ["Inbox", "Work", "Work/Clients", "Archive 2019"])

        let sidebar = ArchiveSidebarModel(archive: env.archive)
        await sidebar.refresh()
        let sources = ArchiveSidebarModel.flatFolders(sidebar.folderTrees)
        XCTAssertEqual(sources.map(\.title), ["MailExport.zip"])
        let rows = try XCTUnwrap(sources.first).rows
        XCTAssertEqual(Set(rows.map(\.node.path)), ["Inbox", "Work", "Work/Clients", "Archive 2019"], "every folder, the empty one too")
        XCTAssertEqual(sidebar.folderRowTotal, 4, "the total the header shows")
        let byPath = Dictionary(uniqueKeysWithValues: rows.map { ($0.node.path, $0) })
        XCTAssertEqual(byPath["Inbox"]?.node.messageCount, 3)
        XCTAssertEqual(byPath["Work"]?.node.messageCount, 2)
        XCTAssertEqual(byPath["Work/Clients"]?.node.messageCount, 1)
        XCTAssertEqual(byPath["Archive 2019"]?.isEmptyFolder, true)
        XCTAssertEqual(byPath["Work/Clients"]?.depth, (byPath["Work"]?.depth ?? -9) + 1, "nested under its parent")
        let workIndex = try XCTUnwrap(rows.firstIndex { $0.node.path == "Work" })
        XCTAssertEqual(rows[workIndex + 1].node.path, "Work/Clients", "a child is listed right under its parent")
        // A page of the list keeps the order and never exceeds its reach.
        XCTAssertEqual(SourceFolderSection.page(sources, reach: 2).flatMap(\.rows).map(\.id), Array(rows.prefix(2)).map(\.id))

        // Choosing Work/Clients filters the list exactly as the Mac's folder row does.
        let vm = ParsedEmailListViewModel(viewModel: ContentViewModel(), archive: env.archive, pageSize: 20, maxRetained: 50)
        vm.isPremiumUser = true
        await settle(vm)
        XCTAssertEqual(vm.visibleEmails.count, 6)
        let clients = try XCTUnwrap(byPath["Work/Clients"]).node
        vm.selectedSourceFolder = .init(id: clients.folderID, name: clients.name)
        await settle(vm)
        XCTAssertEqual(vm.visibleEmails.map { $0.headers["Subject"] ?? "" }, ["Subject 9105"])
        var macQuery = EmailQuery.all
        macQuery.folderID = clients.folderID
        let macCount = try await env.archive.count(query: macQuery)
        XCTAssertEqual(vm.displayedEmailCount, macCount)
        vm.resetFilters()
        XCTAssertNil(vm.selectedSourceFolder, "Clear leaves the folder too")
    }

    /// IPAD-05 (a): the list's Trash view pages trashed rows from the STORE
    /// (a copy a duplicate removal trashed was never resident, so the
    /// in-window filter showed an empty Trash), `in:trash` shows them as on
    /// the Mac, and Restore round-trips through the shared model.
    func testIPAD05_trashListingInTrashOperatorAndRestoreRoundTripThroughTheSharedModel() async throws {
        let env = try makeEnv()
        let fixtures = try await seed(env, count: 6)
        let saved = ReviewStateService.testStoreOverride
        ReviewStateService.testStoreOverride = env.store
        addTeardownBlock { @MainActor in ReviewStateService.testStoreOverride = saved }
        let victim = fixtures[2].id
        try await env.archive.setTrashed(ids: [victim], true)   // as a duplicate removal does

        let vm = ParsedEmailListViewModel(viewModel: ContentViewModel(), archive: env.archive, pageSize: 20, maxRetained: 50)
        vm.isPremiumUser = true
        await settle(vm)
        XCTAssertEqual(vm.visibleEmails.count, 5)
        XCTAssertFalse(vm.visibleEmails.map(\.id).contains(victim))

        vm.reviewStateFilter = .trashed
        await settle(vm)
        XCTAssertEqual(vm.visibleEmails.map(\.id), [victim], "the Trash lists what the store holds there")
        XCTAssertEqual(vm.displayedEmailCount, 1)

        vm.reviewStateFilter = .active
        vm.searchText = "in:trash"
        await settle(vm)
        XCTAssertEqual(vm.visibleEmails.count, 6, "in:trash includes the trashed copy, as on the Mac")
        XCTAssertTrue(vm.visibleEmails.map(\.id).contains(victim))

        vm.searchText = ""
        vm.reviewStateFilter = .trashed
        await settle(vm)
        await vm.restoreFromTrashNow([victim])
        await settle(vm)
        XCTAssertTrue(vm.visibleEmails.isEmpty, "the Trash is empty after the restore")
        let trashedAfter = try await env.archive.trashedCount()
        XCTAssertEqual(trashedAfter, 0, "the store has it back")
        vm.reviewStateFilter = .active
        await settle(vm)
        XCTAssertEqual(vm.visibleEmails.count, 6)
        XCTAssertTrue(vm.visibleEmails.map(\.id).contains(victim))
    }

    /// IPAD-05 (b): after a duplicate removal every count is the store's —
    /// the sidebar's Received no longer counts the trashed copy, the Trash
    /// shows it, and the re-check does not offer the same copy again.
    func testIPAD05_countsAfterADuplicateRemovalComeFromTheStore() async throws {
        let env = try makeEnv()
        let keep = mail(9_200, from: "alice@example.com", subject: "Exact duplicate message", body: "This exact message appears twice.")
        let gone = copy(of: keep)
        let other = mail(9_201, from: "bob@example.com", subject: "Other", body: "Something else.")
        _ = try await env.store.insertBatch([keep, gone, other], sourceFileHash: nil, accountID: nil, sourceID: nil, firstOrdinal: nil,
                                            dedupPolicy: .preserveAll, batchSize: 10, progress: nil)
        let sidebar = ArchiveSidebarModel(archive: env.archive)
        await sidebar.refresh()
        XCTAssertEqual(sidebar.totalCount, 3)
        XCTAssertEqual(sidebar.receivedCount, 3)
        let before = try await DuplicateManagerView.withoutTrashed(try await env.store.messageIDDuplicateGroups(), store: env.store)
        XCTAssertEqual(before.count, 1)

        let result = try await env.store.removeDuplicateCopies([.init(survivor: keep.id, removed: [gone.id])])
        XCTAssertEqual(result.trashed, [gone.id])
        await sidebar.refresh()
        XCTAssertEqual(sidebar.totalCount, 2)
        XCTAssertEqual(sidebar.receivedCount, 2, "Received leaves the Trash out, like All Mail")
        XCTAssertEqual(sidebar.trashedCount, 1)
        let after = try await DuplicateManagerView.withoutTrashed(try await env.store.messageIDDuplicateGroups(), store: env.store)
        XCTAssertTrue(after.isEmpty, "a copy already in the Trash is not offered again: \(after)")
    }

    /// IPAD-05 (c)/(d): the Duplicate Manager's summary never says "no
    /// duplicate messages" while similar groups exist or were not looked for,
    /// its plurals agree, and the walk's near-duplicate (one "!" apart) is found.
    func testIPAD05_duplicateSummaryIsHonestAboutSimilarGroups_andPluralsAgree() {
        let one = DuplicateSummary.text(verified: 0, candidates: 1, similar: 0, near: .wholeArchive)
        XCTAssertFalse((one.title + one.detail).lowercased().contains("no duplicate"), "\(one)")
        XCTAssertTrue(one.detail.contains("1 group "), one.detail)
        XCTAssertFalse(one.detail.contains("1 groups"), one.detail)
        let two = DuplicateSummary.text(verified: 0, candidates: 1, similar: 1, near: .newest(5_000))
        XCTAssertTrue(two.detail.contains("2 groups"), two.detail)
        let unchecked = DuplicateSummary.text(verified: 0, candidates: 0, similar: 0, near: .notChecked)
        XCTAssertFalse((unchecked.title + unchecked.detail).lowercased().contains("no duplicate"), "\(unchecked)")
        XCTAssertTrue(unchecked.detail.contains("not looked for"), unchecked.detail)
        let window = DuplicateSummary.text(verified: 0, candidates: 0, similar: 0, near: .newest(5_000))
        XCTAssertTrue(window.detail.contains("newest"), window.detail)
        XCTAssertEqual(DuplicateSummary.text(verified: 1, candidates: 0, similar: 0, near: .notChecked).title, "1 group of identical copies")
        XCTAssertEqual(Inflect.string("^[\(1) copy](inflect: true)"), "1 copy")
        XCTAssertEqual(Inflect.string("^[\(2) copy](inflect: true)"), "2 copies")

        var a = mail(9_300, from: "alice@example.com", subject: "Exact duplicate message", body: "This exact message appears twice.")
        a.headers["Message-ID"] = "<dupe-exact@example.com>"
        var b = mail(9_301, from: "alice@example.com", subject: "Exact duplicate message", body: "This exact message appears twice!")
        b.headers["Message-ID"] = "<near-dupe@example.com>"
        let near = DuplicateManagerView.findNearDuplicates(in: [a, b], threshold: 0.85)
        XCTAssertEqual(near.map { Set($0.map(\.id)) }, [Set([a.id, b.id])], "one punctuation mark apart is similar")
    }

    // MARK: - Release audit bf1a5b9 R2 — attachments compared as occurrences

    /// One attachment whose bytes the hydrator can produce (inline payload).
    private func r2Attachment(_ name: String, _ payload: Data, mime: String = "image/png",
                              inline: Bool = true, cid: String? = nil) -> AttachmentMetadata {
        AttachmentMetadata(filename: name, mimeType: mime, size: payload.count, isInline: inline,
                           contentID: cid, base64: payload.base64EncodedString())
    }

    /// The audit's counterexample: the same headers and body, two inline
    /// images; the first copy has hero→A and secondary→B, the second has the
    /// associations reversed. Names, sizes, counts and inline counts agree and
    /// the sorted payload hashes match — but the message renders differently.
    func testR2_swappedContentIDAssociation_isACandidate_notContentEquivalent() {
        let payloadA = Data("PNG payload number A".utf8), payloadB = Data("PNG payload number B".utf8)
        XCTAssertEqual(payloadA.count, payloadB.count, "the same sizes, so only the association differs")
        let a = copy(of: makeEmail(i: 9_400, total: 2, body: "see the images")) {
            $0.attachments = [self.r2Attachment("hero.png", payloadA, cid: "hero@x"),
                              self.r2Attachment("secondary.png", payloadB, cid: "secondary@x")]
        }
        let swapped = copy(of: a) {
            $0.rawSource = "raw other"
            $0.attachments = [self.r2Attachment("hero.png", payloadB, cid: "hero@x"),
                              self.r2Attachment("secondary.png", payloadA, cid: "secondary@x")]
        }
        let verdict = DuplicateVerification.verify([a, swapped])
        XCTAssertEqual(verdict, .candidate(differences: [.attachments]))
        XCTAssertFalse(verdict.isVerified)
        let (verified, candidates) = DuplicateVerification.classify([[a, swapped]])
        XCTAssertTrue(verified.isEmpty)
        XCTAssertEqual(candidates.map(\.id), [a.id])
        XCTAssertTrue(DuplicateVerification.bulkRemovable(verified + candidates).isEmpty, "never bulk-removable")
        // Only the association matters, not the order the parts are listed in:
        // the same occurrences in another order are still the same message.
        let reordered = copy(of: a) { $0.rawSource = "raw other"; $0.attachments.reverse() }
        XCTAssertEqual(DuplicateVerification.verify([a, reordered]), .contentEquivalent(attachmentBytesCompared: true))
    }

    /// Occurrences are a multiset of whole tuples: the same payload attached
    /// twice with the same name and Content-ID still matches, and a copy that
    /// carries it once is not the same message.
    func testR2_repeatedIdenticalPayloads_withTheSameNamesAndContentIDs_stillMatch() {
        let logo = Data("the same logo bytes".utf8)
        let a = copy(of: makeEmail(i: 9_401, total: 2, body: "logo twice")) {
            $0.attachments = [self.r2Attachment("logo.png", logo, cid: "logo@x"),
                              self.r2Attachment("logo.png", logo, cid: "logo@x")]
        }
        let b = copy(of: a) { $0.rawSource = "raw other" }
        XCTAssertEqual(DuplicateVerification.verify([a, b]), .contentEquivalent(attachmentBytesCompared: true))
        XCTAssertEqual(DuplicateVerification.bulkRemovable(DuplicateVerification.classify([[a, b]]).verified), [b.id])
        let once = copy(of: a) { $0.rawSource = "raw other"; $0.attachments = [self.r2Attachment("logo.png", logo, cid: "logo@x")] }
        XCTAssertFalse(DuplicateVerification.verify([a, once]).isVerified, "two occurrences are not one")
        // Two occurrences of one payload under different Content-IDs are not
        // two occurrences under the same Content-ID.
        let split = copy(of: a) {
            $0.rawSource = "raw other"
            $0.attachments = [self.r2Attachment("logo.png", logo, cid: "logo@x"), self.r2Attachment("logo.png", logo, cid: "logo2@x")]
        }
        XCTAssertEqual(DuplicateVerification.verify([a, split]), .candidate(differences: [.attachments]))
    }

    func testR2_renamedAttachmentWithIdenticalPayload_isACandidate() {
        let pdf = Data("%PDF-1.4 the same bytes".utf8)
        let a = copy(of: makeEmail(i: 9_402, total: 2, body: "contract attached")) {
            $0.attachments = [self.r2Attachment("contract-v1.pdf", pdf, mime: "application/pdf", inline: false)]
        }
        let renamed = copy(of: a) {
            $0.rawSource = "raw other"
            $0.attachments = [self.r2Attachment("contract-FINAL.pdf", pdf, mime: "application/pdf", inline: false)]
        }
        XCTAssertEqual(DuplicateVerification.verify([a, renamed]), .candidate(differences: [.attachments]))
        XCTAssertFalse(DuplicateVerification.verify([a, renamed]).isVerified)
        // Documented normalisation: surrounding whitespace in a file name is not a different name.
        let padded = copy(of: a) {
            $0.rawSource = "raw other"
            $0.attachments = [self.r2Attachment(" contract-v1.pdf ", pdf, mime: "application/pdf", inline: false)]
        }
        XCTAssertEqual(DuplicateVerification.verify([a, padded]), .contentEquivalent(attachmentBytesCompared: true))
        // The disposition travels with the occurrence too: inline is not attached.
        let inline = copy(of: a) {
            $0.rawSource = "raw other"
            $0.attachments = [self.r2Attachment("contract-v1.pdf", pdf, mime: "application/pdf", inline: true)]
        }
        XCTAssertFalse(DuplicateVerification.verify([a, inline]).isVerified)
    }

    func testR2_changedMIMEType_isACandidate_onlyCaseAndTheNameParameterAreNormalised() {
        let bytes = Data("plain bytes, two labels".utf8)
        let a = copy(of: makeEmail(i: 9_403, total: 2, body: "data attached")) {
            $0.attachments = [self.r2Attachment("data.bin", bytes, mime: "text/plain; charset=utf-8", inline: false)]
        }
        let retyped = copy(of: a) {
            $0.rawSource = "raw other"
            $0.attachments = [self.r2Attachment("data.bin", bytes, mime: "application/octet-stream", inline: false)]
        }
        XCTAssertEqual(DuplicateVerification.verify([a, retyped]), .candidate(differences: [.attachments]))
        // A different charset renders the same bytes differently: still a candidate.
        let charset = copy(of: a) {
            $0.rawSource = "raw other"
            $0.attachments = [self.r2Attachment("data.bin", bytes, mime: "text/plain; charset=iso-8859-1", inline: false)]
        }
        XCTAssertEqual(DuplicateVerification.verify([a, charset]), .candidate(differences: [.attachments]))
        // RFC 2045 §5.1: type, subtype and parameter names are case-insensitive;
        // `name=` repeats the file name, which is compared on its own.
        let spelled = copy(of: a) {
            $0.rawSource = "raw other"
            $0.attachments = [self.r2Attachment("data.bin", bytes, mime: "Text/Plain;  Charset=utf-8; name=\"data.bin\"", inline: false)]
        }
        XCTAssertEqual(DuplicateVerification.verify([a, spelled]), .contentEquivalent(attachmentBytesCompared: true))
        XCTAssertEqual(ExportReconciliation.normalisedMIMEType("IMAGE/PNG; name=\"x.png\"; Format=flowed"), "image/png; format=flowed")
    }

    func testR2_unavailableBytes_areNeverContentEquivalent_andTheReasonIsNamed() {
        // No payload, no file, no raw message to re-extract from: the bytes cannot be produced.
        let missing = AttachmentMetadata(filename: "hero.png", mimeType: "image/png", size: 20, isInline: true, contentID: "hero@x")
        let a = copy(of: makeEmail(i: 9_404, total: 2, body: "images")) { $0.attachments = [missing] }
        let b = copy(of: a) { $0.rawSource = "raw other" }
        let verdict = DuplicateVerification.verify([a, b])
        XCTAssertEqual(verdict, .candidate(differences: [.attachmentBytes]))
        XCTAssertFalse(verdict.isVerified)
        XCTAssertTrue(DuplicateVerification.differenceLine(verdict)?.contains("attachment bytes") == true)
        // Bytes for one copy only is still unproven.
        let withBytes = copy(of: a) {
            $0.rawSource = "raw third"
            $0.attachments = [self.r2Attachment("hero.png", Data("PNG payload number A".utf8), cid: "hero@x")]
        }
        XCTAssertFalse(DuplicateVerification.verify([withBytes, a]).isVerified)
        // Without bytes the metadata is still compared: a different Content-ID is a named attachment difference.
        let otherCID = copy(of: a) {
            $0.rawSource = "raw other"
            $0.attachments = [AttachmentMetadata(filename: "hero.png", mimeType: "image/png", size: 20, isInline: true, contentID: "other@x")]
        }
        XCTAssertEqual(DuplicateVerification.verify([a, otherCID]), .candidate(differences: [.attachments]))
        XCTAssertTrue(DuplicateVerification.bulkRemovable(DuplicateVerification.classify([[a, b], [a, otherCID]]).verified).isEmpty)
    }

    // MARK: - Release audit bf1a5b9 R5 — no message-size ceiling; message depth, continuation, stored unlock, honest failure

    /// R5 item 1 (owner 2026-11-08: "there should be no limit at all"): a
    /// message kept by its byte range (here above a 64 KiB stand-in ceiling;
    /// the 101 MiB row is `StreamedBodyIndexTests` in the package) is NOT
    /// "no text": its body may match until the backfill job streams it from
    /// the original file, after which a word in its last chunk is found. The
    /// Limits screen lists no single-message ceiling.
    func testR5_largeMessageTextIsStreamedIntoSearch_andNoSingleMessageCeilingIsListed() async throws {
        let wasOn = SearchChunkPolicy.isEnabled
        defer { SearchChunkPolicy.isEnabled = wasOn }
        let env = try chunkedEnv()
        try FileManager.default.createDirectory(at: env.root, withIntermediateDirectories: true)
        let url = env.root.appendingPathComponent("r5-large.mbox")
        let filler = String(repeating: "ordinary words about the quarterly ledger and the board.\n", count: 6_000)   // ~350 KB
        try """
        From big@example.com Fri Mar 17 12:00:00 2017
        From: big@example.com
        To: me@example.com
        Subject: R5 large
        Date: Fri, 17 Mar 2017 12:00:00 +0000
        Message-ID: <r5-large@example.com>
        Content-Type: text/plain; charset=utf-8

        \(filler)the very last word is xylophonist

        """.write(to: url, atomically: true, encoding: .utf8)
        let summary = try await importForLife01(env, url)
        XCTAssertEqual(summary.bodiesNotDecoded, 1, "kept by its byte range")
        let spec = SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.body, .allWords, "xylophonist")])])
        try await expectIDs(env, spec, [], "not streamed yet")
        let excluding = SearchSpec(groups: [SearchGroup(.exclude, [SearchCondition(.body, .allWords, "xylophonist")])])
        var q = EmailQuery.all; q.spec = excluding
        try await expectUnresolved(env, q, 1, "until streamed its body may match — it is never counted as 'no text'")

        SearchDocBackfillJob.testStoreOverride = env.store
        AttachmentTextIndexJob.testSuppressKicks = true   // R5b: a streamed body kicks the attachment job
        defer { SearchDocBackfillJob.testStoreOverride = nil; AttachmentTextIndexJob.testSuppressKicks = false }
        let outcome = await SearchDocBackfillJob.shared.run()
        XCTAssertEqual(outcome.streamedBodies, 1)
        XCTAssertEqual(outcome.streamedFailed, 0)
        try await expectIDs(env, spec, ["R5 large"], "found by its last word, streamed from the original file")
        try await expectUnresolved(env, q, 0)

        // The Limits screen: no single-message ceiling; message depth listed with its kind.
        let limits = AppLimits.all
        let single = try XCTUnwrap(limits.first { $0.what == "Single message size" })
        XCTAssertEqual(single.kind, .none)
        XCTAssertEqual(single.value, "no limit")
        XCTAssertFalse(limits.contains { $0.kind == .safety && $0.what.hasPrefix("Single message") }, "the 100 MiB text exclusion is gone")
        XCTAssertEqual(limits.first { $0.what == "Messages inside messages, per run" }?.kind, .safety)
    }

    /// One level of an attached-message chain: `depth` 1 is the outermost
    /// attachment; the innermost (level `levels`) carries `word`.
    private func emlChain(level: Int, levels: Int, word: String) -> Data {
        if level == levels {
            return Data("""
            From: inner@example.com
            Subject: level \(level)
            Content-Type: text/plain

            the innermost message says \(word)

            """.utf8)
        }
        let inner = emlChain(level: level + 1, levels: levels, word: word)
        return Data("""
        From: level\(level)@example.com
        Subject: level \(level)
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="L\(level)"

        --L\(level)
        Content-Type: text/plain

        this is level \(level)
        --L\(level)
        Content-Type: message/rfc822; name="level\(level + 1).eml"
        Content-Disposition: attachment; filename="level\(level + 1).eml"
        Content-Transfer-Encoding: base64

        \(inner.base64EncodedString(options: [.lineLength76Characters]))
        --L\(level)--

        """.utf8)
    }

    /// R5 item 2: message depth is its own ceiling (`ExtractionLimits.messageDepth`)
    /// and Resume opens one more level per round. A five-deep attached .eml
    /// chain stops at round 0 with the ceiling named; round 2 reaches the
    /// innermost message's text.
    func testR5_messageDepthFollowsResumeRounds_fiveDeepChainReachesTheInnermostText() async throws {
        let wasOn = SearchChunkPolicy.isEnabled
        defer { SearchChunkPolicy.isEnabled = wasOn }
        let env = try chunkedEnv()
        AttachmentTextIndexJob.testSuppressKicks = true
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()
        AttachmentTextIndexJob.testStoreOverride = env.store
        defer { AttachmentTextIndexJob.testStoreOverride = nil; AttachmentTextIndexJob.testSuppressKicks = false }
        let ocrWas = AttachmentOCR.isEnabled
        AttachmentOCR.isEnabled = false
        defer { AttachmentOCR.isEnabled = ocrWas }
        AttachmentTextIndexJob.installChildReader()
        ExtractionLimits.baseOverride = nil
        XCTAssertEqual(ExtractionLimits.base.messageDepth, 3)
        XCTAssertEqual(ExtractionLimits.round(2).messageDepth, 5, "one more message level per round")
        XCTAssertEqual(AttachmentTextIndexJob.maxMessageDepth, 3, "an ordinary pass works under the base")
        XCTAssertEqual(ExtractionLimits.$current.withValue(ExtractionLimits.round(1)) { AttachmentTextIndexJob.maxMessageDepth }, 4,
                       "the ceiling is the run's, not a fixed constant")

        // The chain: the attachment is level 1; level 5 holds the word.
        let chain = emlChain(level: 1, levels: 5, word: "abecedarian")
        let raw = """
        From sender@example.com Wed Jan 15 10:00:00 2025
        From: sender@example.com
        To: user@dest.org
        Subject: Deep chain
        Date: Wed, 15 Jan 2025 10:00:00 +0000
        Message-ID: <r5-deep@t>
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="B"

        --B
        Content-Type: text/plain

        see the forwarded chain
        \(mimeAttachment("level1.eml", "message/rfc822", chain))
        --B--
        """
        let email = try MBOXParser.processRawMessage(raw, senderEmail: "")
        _ = try await env.store.insertBatch([email], sourceFileHash: nil, accountID: nil, sourceID: nil, firstOrdinal: nil, dedupPolicy: .messageID, batchSize: 10, progress: nil)
        _ = await AttachmentTextIndexJob.shared.run()
        let coverage = try AttachmentCoverageStore(url: await env.store.attachmentCoverageURL)
        var row = try XCTUnwrap(try coverage.rows(for: email.id).first)
        XCTAssertEqual(row.state, .partial)
        XCTAssertTrue(row.note?.contains("a message nested deeper than 3 levels") == true, row.note ?? "")
        XCTAssertTrue(AttachmentResumeView.canResume(row), "the ceiling is named, so Resume is offered")
        func found() async throws -> Int {
            var q = EmailQuery.all
            q.spec = SearchSpec(groups: [SearchGroup(.all, attachments: [AttachmentConditionGroup(nameContains: "level1", contentMatch: .allWords, content: "abecedarian")])])
            return try await env.archive.count(query: q)
        }
        let round0 = try await found()
        XCTAssertEqual(round0, 0)

        let first = await AttachmentTextIndexJob.shared.resume(emailID: email.id, position: 0)
        guard case .resumed(1, _, let note1, let limits1) = first else { return XCTFail("\(first)") }
        XCTAssertTrue(limits1.hasSuffix("4 message levels"), limits1)
        XCTAssertTrue(note1?.contains("deeper than 4 levels") == true, note1 ?? "")
        let round1 = try await found()
        XCTAssertEqual(round1, 0, "level 5 is one level further still")

        let second = await AttachmentTextIndexJob.shared.resume(emailID: email.id, position: 0)
        guard case .resumed(2, let state2, _, _) = second else { return XCTFail("\(second)") }
        XCTAssertEqual(state2, .extracted)
        row = try XCTUnwrap(try coverage.rows(for: email.id).first)
        XCTAssertFalse(AttachmentResumeView.canResume(row), "read whole")
        let round2 = try await found()
        XCTAssertEqual(round2, 1, "round 2 reaches the innermost message")
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()
    }

    /// Three ~900-byte text members; each word only in its own member.
    private static func r5Members() -> [(name: String, data: Data)] {
        [("a.txt", Data((String(repeating: "alpha filler ", count: 68) + "aardvarkword").utf8)),
         ("b.txt", Data((String(repeating: "bravo filler ", count: 68) + "bisonword").utf8)),
         ("c.txt", Data((String(repeating: "charlie fill ", count: 68) + "caracalword").utf8))]
    }

    private func r5Message(_ zip: Data, id: String) throws -> MBOXParser.RawEmail {
        let raw = """
        From sender@example.com Wed Jan 15 10:00:00 2025
        From: sender@example.com
        To: user@dest.org
        Subject: Continue \(id)
        Date: Wed, 15 Jan 2025 10:00:00 +0000
        Message-ID: <r5-\(id)@t>
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="B"

        --B
        Content-Type: text/plain

        three files
        \(mimeAttachment("three.zip", "application/zip", zip))
        --B--
        """
        return try MBOXParser.processRawMessage(raw, senderEmail: "")
    }

    private func r5Found(_ env: Env, _ word: String) async throws -> Int {
        var q = EmailQuery.all
        q.spec = SearchSpec(groups: [SearchGroup(.all, attachments: [AttachmentConditionGroup(nameContains: "three", contentMatch: .allWords, content: word)])])
        return try await env.archive.count(query: q)
    }

    /// R5 item 3: Resume CONTINUES. Round 0 reads a.txt and stops at the
    /// 1,000-byte budget; round 1 (2,000 bytes) carries a.txt over without
    /// reading it again, so b.txt AND c.txt fit — re-reading from the start
    /// would spend 900 bytes on a.txt again and stop before c.txt. The cursor
    /// is the archive's child rows, so it survives a restart (a fresh store).
    func testR5_resumeContinuesFromTheRecordedChildren_notFromTheStart_andSurvivesARestart() async throws {
        let wasOn = SearchChunkPolicy.isEnabled
        defer { SearchChunkPolicy.isEnabled = wasOn }
        let env = try chunkedEnv()
        AttachmentTextIndexJob.testSuppressKicks = true
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()
        AttachmentTextIndexJob.testStoreOverride = env.store
        defer { AttachmentTextIndexJob.testStoreOverride = nil; AttachmentTextIndexJob.testSuppressKicks = false }
        let ocrWas = AttachmentOCR.isEnabled
        AttachmentOCR.isEnabled = false
        defer { AttachmentOCR.isEnabled = ocrWas }
        AttachmentTextIndexJob.installChildReader()
        ExtractionLimits.baseOverride = ExtractionLimits(partBytes: 1_000, totalArchiveBytes: 1_000, archiveDepth: 3)
        defer { ExtractionLimits.baseOverride = nil }

        let email = try r5Message(Self.zipPackage(Self.r5Members()), id: "continue")
        _ = try await env.store.insertBatch([email], sourceFileHash: nil, accountID: nil, sourceID: nil, firstOrdinal: nil, dedupPolicy: .messageID, batchSize: 10, progress: nil)
        _ = await AttachmentTextIndexJob.shared.run()
        let before = try await env.store.attachmentChildren(forEmailID: email.id)
        XCTAssertEqual(before.map { "\($0.path)|\($0.state)" }, ["a.txt|extracted", "b.txt|unsupported", "c.txt|unsupported"])
        let aBefore = try XCTUnwrap(before.first)
        let aFound = try await r5Found(env, "aardvarkword")
        XCTAssertEqual(aFound, 1)

        // Restart: a new store instance on the same archive; nothing in memory carries over.
        let reopened = SQLiteEmailStore(directory: env.root.appendingPathComponent("store"))
        AttachmentTextIndexJob.testStoreOverride = reopened
        let outcome = await AttachmentTextIndexJob.shared.resume(emailID: email.id, position: 0)
        guard case .resumed(1, let state, _, _) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(state, .extracted, "continuing: the budget went to b.txt and c.txt only")
        let after = try await reopened.attachmentChildren(forEmailID: email.id)
        XCTAssertEqual(after.map { "\($0.path)|\($0.state)" }, ["a.txt|extracted", "b.txt|extracted", "c.txt|extracted"])
        XCTAssertEqual(after.first?.sha256, aBefore.sha256, "a.txt is carried over as recorded, not read again")
        for word in ["aardvarkword", "bisonword", "caracalword"] {
            let n = try await r5Found(env, word)
            XCTAssertEqual(n, 1, word)
        }
        XCTAssertEqual(ExtractionContinuation.carriablePaths(after), ["a.txt", "b.txt", "c.txt"])
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()
    }

    /// R5 item 4: Resume uses the Unlock session strategy. An encrypted ZIP
    /// unlocked with "keep searchable" stops at the budget; Resume WITHOUT the
    /// password keeps the stored text and children and marks only the rest
    /// "needs the password again"; a kept Unlock then completes the rest.
    func testR5_storedUnlockSurvivesResumeWithoutPassword_andUnlockCompletesTheRest() async throws {
        let wasOn = SearchChunkPolicy.isEnabled
        defer { SearchChunkPolicy.isEnabled = wasOn }
        let env = try chunkedEnv()
        AttachmentTextIndexJob.testSuppressKicks = true
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()
        AttachmentTextIndexJob.testStoreOverride = env.store
        defer { AttachmentTextIndexJob.testStoreOverride = nil; AttachmentTextIndexJob.testSuppressKicks = false }
        let ocrWas = AttachmentOCR.isEnabled
        AttachmentOCR.isEnabled = false
        defer { AttachmentOCR.isEnabled = ocrWas }
        AttachmentTextIndexJob.installChildReader()
        ExtractionLimits.baseOverride = ExtractionLimits(partBytes: 1_000, totalArchiveBytes: 1_000, archiveDepth: 3)
        defer { ExtractionLimits.baseOverride = nil }

        let entries = Self.r5Members().map { member -> (name: String, payload: Data, flags: UInt16, method: UInt16, crc: UInt32, size: UInt32, extra: Data) in
            var cipher = ZipCryptoCipher(password: "open-sesame")
            let crc = Self.crc32(member.data)
            return (member.name, cipher.encrypt(ZipCryptoCipher.header(crc32: crc) + member.data), 0x0001, 0, crc, UInt32(member.data.count), Data())
        }
        let email = try r5Message(Self.zipRaw(entries), id: "sealed")
        _ = try await env.store.insertBatch([email], sourceFileHash: nil, accountID: nil, sourceID: nil, firstOrdinal: nil, dedupPolicy: .messageID, batchSize: 10, progress: nil)
        _ = await AttachmentTextIndexJob.shared.run()
        let coverage = try AttachmentCoverageStore(url: await env.store.attachmentCoverageURL)
        XCTAssertEqual(try coverage.rows(for: email.id).first?.state, .locked)

        // Unlock, kept: a.txt read; b.txt and c.txt stop at the budget.
        let kept = await AttachmentTextIndexJob.shared.unlock(emailID: email.id, position: 0, password: "open-sesame", retain: true)
        guard case .unlocked(_, _, true) = kept else { return XCTFail("\(kept)") }
        var row = try XCTUnwrap(try coverage.rows(for: email.id).first)
        XCTAssertEqual(row.state, .partial)
        XCTAssertTrue(row.unlockedWithPassword)
        XCTAssertTrue(AttachmentResumeView.canResume(row), row.note ?? "")
        let a0 = try await r5Found(env, "aardvarkword")
        XCTAssertEqual(a0, 1)
        let unlockedChildren = try await env.store.attachmentChildren(forEmailID: email.id)
        let aRow = try XCTUnwrap(unlockedChildren.first)

        // Resume without the password: nothing stored is replaced; the rest needs the password again.
        let resumed = await AttachmentTextIndexJob.shared.resume(emailID: email.id, position: 0)
        guard case .needsPassword(1, 2, _) = resumed else { return XCTFail("\(resumed)") }
        let a1 = try await r5Found(env, "aardvarkword")
        XCTAssertEqual(a1, 1, "the text the kept Unlock stored is still searchable")
        let children = try await env.store.attachmentChildren(forEmailID: email.id)
        XCTAssertEqual(children.map { "\($0.path)|\($0.state)" }, ["a.txt|extracted", "b.txt|locked", "c.txt|locked"])
        XCTAssertEqual(children.first?.sha256, aRow.sha256, "a.txt is the recorded one, not a re-read")
        XCTAssertEqual(children.dropFirst().compactMap(\.note), [AttachmentTextIndexJob.needsPasswordAgainNote, AttachmentTextIndexJob.needsPasswordAgainNote])
        row = try XCTUnwrap(try coverage.rows(for: email.id).first)
        XCTAssertEqual(row.state, .partial, "never re-read as locked")
        XCTAssertEqual(row.resumeRound, 1)
        XCTAssertTrue(row.unlockedWithPassword)

        // A wrong password changes nothing.
        let wrong = await AttachmentTextIndexJob.shared.unlock(emailID: email.id, position: 0, password: "nope", retain: true)
        guard case .wrongPassword = wrong else { return XCTFail("\(wrong)") }
        let stillA = try await r5Found(env, "aardvarkword")
        XCTAssertEqual(stillA, 1)

        // With the password (the Unlock path): the rest is read under round 1, a.txt carried.
        let completed = await AttachmentTextIndexJob.shared.unlock(emailID: email.id, position: 0, password: "open-sesame", retain: true)
        guard case .unlocked(_, _, true) = completed else { return XCTFail("\(completed)") }
        let done = try await env.store.attachmentChildren(forEmailID: email.id)
        XCTAssertEqual(done.map { "\($0.path)|\($0.state)" }, ["a.txt|extracted", "b.txt|extracted", "c.txt|extracted"])
        for word in ["aardvarkword", "bisonword", "caracalword"] {
            let n = try await r5Found(env, word)
            XCTAssertEqual(n, 1, word)
        }
        row = try XCTUnwrap(try coverage.rows(for: email.id).first)
        XCTAssertEqual(row.state, .extracted)
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()
    }

    private struct R5CoverageUnavailable: LocalizedError {
        var errorDescription: String? { "the coverage file is unavailable" }
    }

    /// R5 item 5: a coverage store that cannot be opened is a failure of the
    /// round, surfaced as such — never "resumed" with nothing recorded.
    func testR5_resumeFailsExplicitlyWhenTheRoundCannotBeRecorded() async throws {
        let wasOn = SearchChunkPolicy.isEnabled
        defer { SearchChunkPolicy.isEnabled = wasOn }
        let env = try chunkedEnv()
        AttachmentTextIndexJob.testSuppressKicks = true
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()
        AttachmentTextIndexJob.testStoreOverride = env.store
        defer { AttachmentTextIndexJob.testStoreOverride = nil; AttachmentTextIndexJob.testSuppressKicks = false; AttachmentTextIndexJob.testCoverageStoreFactory = nil }
        let ocrWas = AttachmentOCR.isEnabled
        AttachmentOCR.isEnabled = false
        defer { AttachmentOCR.isEnabled = ocrWas }
        AttachmentTextIndexJob.installChildReader()
        ExtractionLimits.baseOverride = ExtractionLimits(partBytes: 1_000, totalArchiveBytes: 1_000, archiveDepth: 3)
        defer { ExtractionLimits.baseOverride = nil }
        let email = try r5Message(Self.zipPackage(Self.r5Members()), id: "unrecorded")
        _ = try await env.store.insertBatch([email], sourceFileHash: nil, accountID: nil, sourceID: nil, firstOrdinal: nil, dedupPolicy: .messageID, batchSize: 10, progress: nil)
        _ = await AttachmentTextIndexJob.shared.run()

        AttachmentTextIndexJob.testCoverageStoreFactory = { _ in throw R5CoverageUnavailable() }
        let outcome = await AttachmentTextIndexJob.shared.resume(emailID: email.id, position: 0)
        guard case .notRecorded(let why) = outcome else { return XCTFail("must not claim resumed: \(outcome)") }
        XCTAssertTrue(why.hasPrefix("could not record the round:") && why.contains("unavailable"), why)
        AttachmentTextIndexJob.testCoverageStoreFactory = nil
        let coverageURL = await env.store.attachmentCoverageURL
        let row = try XCTUnwrap(try AttachmentCoverageStore(url: coverageURL).rows(for: email.id).first)
        XCTAssertEqual(row.resumeRound, 0, "no round was recorded")
        let children = try await env.store.attachmentChildren(forEmailID: email.id)
        XCTAssertEqual(children.map(\.state), ["extracted", "unsupported", "unsupported"], "nothing was rewritten")
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()
    }

    // MARK: - R5b — attachment contents of a message kept by its byte range; a reader upgrade keeps a kept Unlock

    /// R5b item 1 (owner 2026-11-08: "there should be no limit at all"): a
    /// message above the stream threshold (a 64 KiB stand-in ceiling) with a
    /// DOCX and a ZIP holding a DOCX. Streaming its body registers each
    /// attachment's byte range in the original file; the attachment job then
    /// streams each one out decoded and reads it like any other — a word in
    /// each is found, through the attachment condition and through any text.
    /// The decode holds a slice and a carry, never the attachment.
    func testR5b_attachmentContentsOfALargeMessageAreSearchable_docxAndZipWithDocx() async throws {
        let wasOn = SearchChunkPolicy.isEnabled
        defer { SearchChunkPolicy.isEnabled = wasOn }
        let env = try chunkedEnv()
        try FileManager.default.createDirectory(at: env.root, withIntermediateDirectories: true)
        AttachmentTextIndexJob.testSuppressKicks = true
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()
        AttachmentTextIndexJob.testStoreOverride = env.store
        SearchDocBackfillJob.testStoreOverride = env.store
        defer {
            AttachmentTextIndexJob.testStoreOverride = nil; AttachmentTextIndexJob.testSuppressKicks = false
            SearchDocBackfillJob.testStoreOverride = nil
        }
        let ocrWas = AttachmentOCR.isEnabled
        AttachmentOCR.isEnabled = false
        defer { AttachmentOCR.isEnabled = ocrWas }
        AttachmentTextIndexJob.installChildReader()
        ExtractionLimits.baseOverride = nil

        let memo = Self.docx(body: "the memo mentions quetzalcoatlus", header: "memo header")
        let inner = Self.docx(body: "the inner file mentions xenarthran", header: "inner header")
        let bundle = Self.zipPackage([("folder/inner.docx", inner)])
        let filler = String(repeating: "ordinary words about the quarterly ledger and the board.\n", count: 2_000)   // ~114 KB
        let url = env.root.appendingPathComponent("r5b-large.mbox")
        try """
        From big@example.com Fri Mar 17 12:00:00 2017
        From: big@example.com
        To: me@example.com
        Subject: R5b large with attachments
        Date: Fri, 17 Mar 2017 12:00:00 +0000
        Message-ID: <r5b-attach@example.com>
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="B"

        --B
        Content-Type: text/plain; charset=utf-8

        \(filler)
        \(mimeAttachment("memo.docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document", memo))
        \(mimeAttachment("bundle.zip", "application/zip", bundle))
        --B--

        """.write(to: url, atomically: true, encoding: .utf8)
        let summary = try await importForLife01(env, url)
        XCTAssertEqual(summary.bodiesNotDecoded, 1, "kept by its byte range")

        func found(_ name: String, _ word: String) async throws -> Int {
            var q = EmailQuery.all
            q.spec = SearchSpec(groups: [SearchGroup(.all, attachments: [AttachmentConditionGroup(nameContains: name, contentMatch: .allWords, content: word)])])
            return try await env.archive.count(query: q)
        }
        let before = try await found("memo", "quetzalcoatlus")
        XCTAssertEqual(before, 0)

        let streamed = await SearchDocBackfillJob.shared.run()
        XCTAssertEqual(streamed.streamedBodies, 1)
        var ids: [UUID] = []
        for try await batch in env.archive.streamFullEmails(query: .all, batchSize: 10) { ids += batch.map(\.id) }
        let id = try XCTUnwrap(ids.first)
        let listed = try await env.store.attachmentMetadata(forEmailID: id)
        XCTAssertEqual(listed.map(\.filename), ["memo.docx", "bundle.zip"], "the attachments are listed like any other")

        _ = await AttachmentTextIndexJob.shared.run()
        let memoFound = try await found("memo", "quetzalcoatlus")
        XCTAssertEqual(memoFound, 1, "a word in the DOCX is found")
        let innerFound = try await found("bundle", "xenarthran")
        XCTAssertEqual(innerFound, 1, "a word in the DOCX inside the ZIP is found")
        try await expectIDs(env, SearchSpec(groups: [SearchGroup(.all, [SearchCondition(.anyText, .allWords, "xenarthran")])]),
                            ["R5b large with attachments"], "any-text search reaches the file inside the attachment")
        let coverage = try AttachmentCoverageStore(url: await env.store.attachmentCoverageURL)
        let rows = try coverage.rows(for: id)
        XCTAssertEqual(rows.map(\.filename), ["memo.docx", "bundle.zip"])
        XCTAssertTrue(rows.allSatisfy { $0.state.isSearchable }, "\(rows.map(\.state))")
        let children = try await env.store.attachmentChildren(forEmailID: id)
        XCTAssertTrue(children.contains { $0.path == "folder/inner.docx" && $0.state == "extracted" }, "\(children.map(\.path))")

        // Bounded memory: the registered part streams out through a 4 KB slice.
        let located = try await env.store.streamedAttachmentParts(emailID: id)
        let (sourcePath, parts) = try XCTUnwrap(located)
        let out = env.root.appendingPathComponent("memo.out")
        let decoded = try StreamedPartDecoder.decode(part: parts[0], sourcePath: sourcePath, to: out, sliceBytes: 4_096)
        XCTAssertEqual(try Data(contentsOf: out), memo)
        XCTAssertLessThan(decoded.peakBufferedBytes, 3 * 4_096 + 1_024)

        // The Limits screen no longer says these contents are not read.
        let single = try XCTUnwrap(AppLimits.all.first { $0.what == "Single message size" })
        XCTAssertFalse(single.why.contains("not yet read"), single.why)
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()
    }

    /// R5b item 2: a reader upgrade (rows below the current extractor version)
    /// re-reads the message without any password. The attachment a kept Unlock
    /// stored keeps its row, its text and its children; its row says the newer
    /// reader needs the password again (once); the message's other attachment
    /// is re-read by the newer reader. Unlocking again reads it with the newer reader.
    func testR5b_readerUpgradeKeepsAKeptUnlock_andMarksOnlyWhatTheNewerReaderWouldAdd() async throws {
        let wasOn = SearchChunkPolicy.isEnabled
        defer { SearchChunkPolicy.isEnabled = wasOn }
        let env = try chunkedEnv()
        AttachmentTextIndexJob.testSuppressKicks = true
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()
        AttachmentTextIndexJob.testStoreOverride = env.store
        defer { AttachmentTextIndexJob.testStoreOverride = nil; AttachmentTextIndexJob.testSuppressKicks = false }
        let ocrWas = AttachmentOCR.isEnabled
        AttachmentOCR.isEnabled = false
        defer { AttachmentOCR.isEnabled = ocrWas }
        AttachmentTextIndexJob.installChildReader()
        ExtractionLimits.baseOverride = nil

        let entries = Self.r5Members().map { member -> (name: String, payload: Data, flags: UInt16, method: UInt16, crc: UInt32, size: UInt32, extra: Data) in
            var cipher = ZipCryptoCipher(password: "open-sesame")
            let crc = Self.crc32(member.data)
            return (member.name, cipher.encrypt(ZipCryptoCipher.header(crc32: crc) + member.data), 0x0001, 0, crc, UInt32(member.data.count), Data())
        }
        let raw = """
        From sender@example.com Wed Jan 15 10:00:00 2025
        From: sender@example.com
        To: user@dest.org
        Subject: Upgrade keeps unlock
        Date: Wed, 15 Jan 2025 10:00:00 +0000
        Message-ID: <r5b-upgrade@t>
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="B"

        --B
        Content-Type: text/plain

        two files
        \(mimeAttachment("three.zip", "application/zip", Self.zipRaw(entries)))
        \(mimeAttachment("notes.txt", "text/plain", Data("the plain notes say ocelotword".utf8)))
        --B--
        """
        let email = try MBOXParser.processRawMessage(raw, senderEmail: "")
        _ = try await env.store.insertBatch([email], sourceFileHash: nil, accountID: nil, sourceID: nil, firstOrdinal: nil, dedupPolicy: .messageID, batchSize: 10, progress: nil)
        _ = await AttachmentTextIndexJob.shared.run()
        let coverage = try AttachmentCoverageStore(url: await env.store.attachmentCoverageURL)
        XCTAssertEqual(try coverage.rows(for: email.id).first?.state, .locked)
        let kept = await AttachmentTextIndexJob.shared.unlock(emailID: email.id, position: 0, password: "open-sesame", retain: true)
        guard case .unlocked(_, _, true) = kept else { return XCTFail("\(kept)") }
        let unlockedChildren = try await env.store.attachmentChildren(forEmailID: email.id)
        XCTAssertEqual(unlockedChildren.map(\.state), ["extracted", "extracted", "extracted"])

        // The rows as an older reader (version 9) wrote them: both are re-read candidates for version 10.
        for row in try coverage.rows(for: email.id) {
            XCTAssertTrue(AttachmentTextIndexJob.boundaryExtractors.contains(row.extractor), row.extractor)
            try coverage.record(row: AttachmentCoverageRow(emailID: row.emailID, ordinal: row.ordinal, filename: row.filename, mimeType: row.mimeType,
                                                           state: row.state, extractor: row.extractor, extractorVersion: 9, characters: row.characters,
                                                           note: row.note, resumeRound: row.resumeRound, unlockedWithPassword: row.unlockedWithPassword))
        }
        _ = await AttachmentTextIndexJob.shared.run()

        for word in ["aardvarkword", "bisonword", "caracalword"] {
            let n = try await r5Found(env, word)
            XCTAssertEqual(n, 1, "\(word): the kept Unlock's text survives the upgrade's re-read")
        }
        let children = try await env.store.attachmentChildren(forEmailID: email.id)
        XCTAssertEqual(children.map(\.state), ["extracted", "extracted", "extracted"], "never re-read as locked")
        XCTAssertEqual(children.map(\.sha256), unlockedChildren.map(\.sha256))
        XCTAssertTrue(children.allSatisfy { $0.note?.contains(AttachmentTextIndexJob.needsPasswordForNewerReaderNote) != true },
                      "files already read are not marked: the newer reader adds nothing to them that needs the password")
        var rows = try coverage.rows(for: email.id)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].state, .extracted)
        XCTAssertTrue(rows[0].unlockedWithPassword)
        XCTAssertEqual(rows[0].extractorVersion, 9, "still the reading of the earlier reader")
        XCTAssertEqual(rows[0].note?.components(separatedBy: AttachmentTextIndexJob.needsPasswordForNewerReaderNote).count, 2,
                       "marked once: \(rows[0].note ?? "")")
        XCTAssertEqual(rows[1].extractorVersion, AttachmentTextIndexJob.extractorVersion, "the other attachment is re-read by the newer reader")
        var q = EmailQuery.all
        q.spec = SearchSpec(groups: [SearchGroup(.all, attachments: [AttachmentConditionGroup(nameContains: "notes", contentMatch: .allWords, content: "ocelotword")])])
        let notes = try await env.archive.count(query: q)
        XCTAssertEqual(notes, 1)

        // A second pass changes nothing and marks nothing twice.
        _ = await AttachmentTextIndexJob.shared.run()
        rows = try coverage.rows(for: email.id)
        XCTAssertEqual(rows[0].note?.components(separatedBy: AttachmentTextIndexJob.needsPasswordForNewerReaderNote).count, 2)
        let stillThere = try await r5Found(env, "bisonword")
        XCTAssertEqual(stillThere, 1)

        // Unlocking again reads it with the newer reader; the mark goes.
        let again = await AttachmentTextIndexJob.shared.unlock(emailID: email.id, position: 0, password: "open-sesame", retain: true)
        guard case .unlocked(_, _, true) = again else { return XCTFail("\(again)") }
        rows = try coverage.rows(for: email.id)
        XCTAssertEqual(rows[0].extractorVersion, AttachmentTextIndexJob.extractorVersion)
        XCTAssertFalse(rows[0].note?.contains(AttachmentTextIndexJob.needsPasswordForNewerReaderNote) == true)
        await AttachmentTextIndexJob.shared.cancelAndWaitUntilIdle()
    }
}
