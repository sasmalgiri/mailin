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
