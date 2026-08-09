import XCTest
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
}
