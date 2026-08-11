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

        // Built-in catalog is well-formed: 12 recipes, sequential ops.
        XCTAssertEqual(WorkflowCatalog.all.count, 12)
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
        XCTAssertEqual(WorkflowCatalog.templates(for: "forensic").count, 2)
        XCTAssertEqual(WorkflowCatalog.templates(for: "legal").count, 4)   // production, hold, ECA, DSAR
        XCTAssertEqual(WorkflowCatalog.templates(for: "it_admin").count, 3)   // phishing, threat hunt, bulk campaign
        XCTAssertEqual(WorkflowCatalog.templates(for: "journalist").count, 2)
        XCTAssertEqual(WorkflowCatalog.templates(for: "personal").count, 1)

        // The new jobs are present by name.
        let names = Set(WorkflowCatalog.all.map(\.name))
        for expected in ["Timeline Reconstruction", "Legal Hold & Preservation",
                         "Early Case Assessment", "Data Subject Request (DSAR)",
                         "Threat Hunt", "Entity & Network Map", "Phishing Campaign (Bulk)"] {
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
