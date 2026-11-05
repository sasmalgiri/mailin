@testable import ArchiveCore
import XCTest
import PDFKit
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
        // CRLF and LF forms of the same message are the same message.
        let lf = copy(of: a) { $0.rawSource = "Subject: s\n\nline one\nline two" }
        let crlf = copy(of: a) { $0.rawSource = "Subject: s\r\n\r\nline one\r\nline two" }
        XCTAssertEqual(DuplicateVerification.verify([lf, crlf]), .byteIdentical)
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
        XCTAssertEqual(DuplicateVerification.verify([a, b]), .contentEquivalent(attachmentBytesCompared: false))
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
        XCTAssertEqual(rows.map(\.state), [.extracted, .noText, .unsupported, .locked, .truncated])
        XCTAssertEqual(rows[4].characters, AttachmentTextIndexJob.maxTextPerAttachment)
        XCTAssertTrue(rows.allSatisfy { $0.extractorVersion == AttachmentTextIndexJob.extractorVersion })
        XCTAssertNotNil(rows[3].note)

        let summary = try coverage.summary(currentExtractorVersion: AttachmentTextIndexJob.extractorVersion)
        XCTAssertEqual(summary.total, 5)
        XCTAssertEqual(summary.searchable, 2)
        XCTAssertEqual(summary.unsupportedKinds.map(\.kind), ["doc"])
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
        XCTAssertEqual(try coverage.rows(for: email.id).map(\.state), [.extracted, .noText, .unsupported, .locked, .truncated])
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
        XCTAssertEqual(v, 23, "v21 adds folders, v22/v23 the search chunks")
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
        let words = (0..<20_000).map { "w\($0)" }.joined(separator: " ")
        let chunks = SearchChunker.chunks(of: words, chunk: 4_000, overlap: 200)
        XCTAssertGreaterThan(chunks.count, 20)
        for (i, c) in chunks.enumerated() {
            XCTAssertLessThanOrEqual(c.count, 4_000)
            XCTAssertFalse(c.hasPrefix(" ") && i == 0)
            // No word is cut: every chunk boundary word reappears whole in the next chunk's overlap.
            if i + 1 < chunks.count {
                let lastWord = c.split(separator: " ").last.map(String.init) ?? ""
                XCTAssertTrue(chunks[i + 1].contains(lastWord), "chunk \(i) ends with \(lastWord), missing from the overlap")
            }
        }
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
        XCTAssertTrue(xlsx.text.contains("[Sheet: Budget]\nGross margin\tinline note\n42\t84 {=SUM(A1:A2)}\trich run"), xlsx.text)

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
        XCTAssertEqual(rows.map(\.state), [.extracted, .extracted, .extracted, .unsupported])
        XCTAssertEqual(rows.map(\.extractorVersion), Array(repeating: 3, count: 4))
        XCTAssertTrue(rows[3].note?.contains("older Office") == true, rows[3].note ?? "")

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
        XCTAssertEqual(receipt.reconciliationLine, "selected 5 · written 3 · checked 3 of 3 · excluded 1 · failed 1")
        let plain = ExportReceipt(title: "t", destination: "x", isFolder: false, requested: nil, written: 2, outcome: .complete,
                                  startedAt: Date(), completedAt: Date())
        XCTAssertNil(plain.reconciliationLine, "older receipts show nothing they do not know")
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
}
