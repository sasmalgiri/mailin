import XCTest
@testable import maxmailin

/// Regression net for the two highest-blast-radius v2 behavioral changes:
/// R1 (v1→v2 migration) and R2 (search routed through FTS5).
///
/// NOTE: these are app-hosted and touch SwiftData/actors, so they run in an
/// interactive Xcode session (⌘U) — not headless CI-style runners. Written to
/// the red-then-green contract: each is designed to fail on its specific
/// regression (see the comments), not merely to pass against current code.
@MainActor
final class V2VerificationTests: XCTestCase {

    // MARK: - Per-test isolation (deterministic: no shared FTS/store state)

    override func setUp() async throws {
        try await super.setUp()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ftstest_\(UUID().uuidString)")
        FTSSearchIndex.testShardsDirectoryOverride = dir
        await FTSSearchIndex.shared.resetForTesting()
        FTSReconciler.resetCursorForTesting()
    }

    override func tearDown() async throws {
        try? await FTSSearchIndex.shared.clear()
        await FTSSearchIndex.shared.resetForTesting()
        FTSSearchIndex.testShardsDirectoryOverride = nil
        FTSReconciler.resetCursorForTesting()
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func makeEmail(mid: String, subject: String, body: String) -> MBOXParser.RawEmail {
        MBOXParser.RawEmail(
            headers: [
                "Message-ID": mid,
                "Subject": subject,
                "From": "a@b.com",
                "To": "c@d.com",
                "Date": "Wed, 15 Jan 2025 14:30:00 +0000"
            ],
            rawSource: "From a@b.com\n\(body)",
            messageType: "email",
            attachments: [],
            timestamp: "2025-01-15T14:30:00Z",
            domains: ["b.com"],
            plainBody: body,
            htmlBody: ""
        )
    }

    /// Fixture with a distinct calendar date so keyset paging is deterministic.
    private func makeEmailDated(mid: String, subject: String, body: String, dayOffset: Int) -> MBOXParser.RawEmail {
        var e = makeEmail(mid: mid, subject: subject, body: body)
        let day = String(format: "%02d", 1 + (dayOffset % 28))
        e.headers["Date"] = "Wed, \(day) Jan 2025 14:30:00 +0000"
        return e
    }

    // MARK: - 2b — Migration (R1)

    /// Builds a v1 store in a temp dir with a KNOWN duplicate-Message-ID
    /// fixture (100 rows, 90 distinct MIDs), migrates into an in-memory
    /// EmailStore, and asserts the deduped row count. Expected value (90) is
    /// hardcoded and independent of the production dedup helper.
    ///
    /// RED on the regression: point MigrationService.loadLegacyArchive back at
    /// the old `com.ecosanskriti.mailin/email_archive.json` path and this fails
    /// with stored < 90 (S < E) — a real shortfall the gate must catch.
    func testMigrationFromRealV1Store() async throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("mailin_migtest_\(UUID().uuidString)")

        let savedOverride = EmailPersistence.testBaseDirectoryOverride
        let savedInMemory = EmailStore.testInMemory
        EmailPersistence.testBaseDirectoryOverride = tempDir
        EmailStore.testInMemory = true
        await EmailStore.shared.resetForTesting()
        UserDefaults.standard.set(false, forKey: "maxmailin.legacyJSONMigrationCompletedV1")

        defer {
            EmailPersistence.testBaseDirectoryOverride = savedOverride
            EmailStore.testInMemory = savedInMemory
            UserDefaults.standard.set(false, forKey: "maxmailin.legacyJSONMigrationCompletedV1")
            try? fm.removeItem(at: tempDir)
        }

        // 90 unique-MID emails + 10 that REUSE the first 10 MIDs = 100 rows,
        // 90 distinct Message-IDs. Independent expected value:
        let expected = 90
        var fixtures: [MBOXParser.RawEmail] = []
        for i in 0..<90 {
            fixtures.append(makeEmail(mid: "<u-\(i)@test>", subject: "Subject \(i)", body: "body running \(i)"))
        }
        for i in 0..<10 {
            fixtures.append(makeEmail(mid: "<u-\(i)@test>", subject: "Dup \(i)", body: "dup body \(i)"))
        }
        XCTAssertEqual(fixtures.count, 100, "fixture sanity: 100 rows")

        // Write the v1 store exactly the way v1 does.
        EmailPersistence.saveSync(emails: fixtures, senderEmail: "tester@test.com")

        // Run the real migration.
        await MigrationService.shared.forceMigrate()

        let stored = try await EmailStore.shared.totalCount()
        // Directional: equal passes, higher acceptable (within-chunk dupes),
        // LOWER is data loss.
        XCTAssertGreaterThanOrEqual(stored, expected,
            "MIGRATION S < E — data loss: stored=\(stored) < expected=\(expected)")
        XCTAssertTrue(MigrationService.shared.hasMigrated,
            "migration completion flag not set")

        await EmailStore.shared.resetForTesting()
    }

    // MARK: - 2a — Search routed through FTS5 (R2)

    /// Asserts the live search path (ParsedEmailListViewModel.applyFilters)
    /// actually dispatches to FTSSearchIndex when the index is populated —
    /// observed via the engine's own call counter, not inferred from results.
    ///
    /// RED on the regression: stub the search path back to the in-RAM engine
    /// (remove the FTSSearchIndex.search call) and the counter stays 0.
    func testLiveSearchDispatchesToFTS() async throws {
        // Populate FTS with a fixture containing the probe term.
        let fixtures = (0..<5).map { makeEmail(mid: "<s-\($0)@test>", subject: "Subject \($0)", body: "running budget report \($0)") }
        try await FTSSearchIndex.shared.clear()
        try await FTSSearchIndex.shared.indexBatch(fixtures)
        let ftsRows = try await FTSSearchIndex.shared.rowCount()
        XCTAssertGreaterThan(ftsRows, 0, "precondition: FTS index populated")

        // Drive the live search path.
        let vm = ParsedEmailListViewModel(viewModel: ContentViewModel())
        vm.allEmails = fixtures
        vm.isParsing = false
        vm.searchText = "running"

        // Reset the dispatch counter immediately before the observed call, then
        // assert exactly one dispatch (catches both zero and double-dispatch).
        await FTSSearchIndex.shared.resetDebugSearchCallCount()
        vm.applyFilters()
        await vm.lastFTSSearchTask?.value   // deterministic await, no poll

        let dispatches = await FTSSearchIndex.shared.debugSearchCallCount
        XCTAssertEqual(dispatches, 1,
            "live search must dispatch to FTS exactly once (got \(dispatches))")

        try await FTSSearchIndex.shared.clear()
    }

    // MARK: - 3.4 — Delete removes from store AND search (no ghost rows)

    /// A deleted email must disappear from both the SwiftData store and the
    /// FTS index. Guards the previously-missing delete path (removeEmails used
    /// to only mutate the in-memory array, leaving searchable ghost rows).
    func testDeleteRemovesFromStoreAndSearch() async throws {
        let savedInMemory = EmailStore.testInMemory
        EmailStore.testInMemory = true
        await EmailStore.shared.resetForTesting()
        defer {
            EmailStore.testInMemory = savedInMemory
        }

        let fixtures = (0..<5).map { makeEmail(mid: "<d-\($0)@test>", subject: "Subject \($0)", body: "deletable running \($0)") }
        try await EmailStore.shared.insertBatch(fixtures, sourceFileHash: nil, batchSize: 200, progress: nil)
        try await FTSSearchIndex.shared.clear()
        try await FTSSearchIndex.shared.indexBatch(fixtures)

        let preCount = try await EmailStore.shared.totalCount()
        XCTAssertEqual(preCount, 5, "precondition: 5 inserted")

        let victim = fixtures[0].id
        try await EmailStore.shared.delete(ids: [victim])
        try await FTSSearchIndex.shared.delete(id: victim)

        let postCount = try await EmailStore.shared.totalCount()
        XCTAssertEqual(postCount, 4, "store delete must drop the row")
        let hits = try await FTSSearchIndex.shared.search("running", limit: 50)
        XCTAssertFalse(hits.contains(victim), "deleted email must not appear in FTS results (ghost row)")

        try await FTSSearchIndex.shared.clear()
        await EmailStore.shared.resetForTesting()
    }

    // MARK: - 3.4 — Store↔FTS reconcile (drift repair)

    /// indexMissing repairs drift: emails present in the store but missing from
    /// FTS (e.g. a crash between the two commits) get indexed; idempotent.
    func testReconcileIndexesMissing() async throws {
        let fixtures = (0..<3).map { makeEmail(mid: "<r-\($0)@test>", subject: "S\($0)", body: "reconcile term \($0)") }
        try await FTSSearchIndex.shared.clear()
        try await FTSSearchIndex.shared.indexBatch([fixtures[0]])   // only 1 of 3 indexed

        let firstPass = try await FTSSearchIndex.shared.indexMissing(from: fixtures)
        XCTAssertEqual(firstPass, 2, "should index the 2 missing")

        let secondPass = try await FTSSearchIndex.shared.indexMissing(from: fixtures)
        XCTAssertEqual(secondPass, 0, "idempotent — nothing missing the second time")

        try await FTSSearchIndex.shared.clear()
    }

    // MARK: - 3.5 — Redaction actually strips content (text-level, not eyeball)

    /// The highest-liability claim: a redacted output must not *contain* the
    /// secret string (content removed, not visually boxed). Asserts on the
    /// extracted text of the redaction output, not its appearance.
    func testRedactionStripsContentFromOutput() throws {
        let secret = "SuperSecretPassword123"
        let body = "The key is \(secret) and nothing else."
        let rule = RedactionEngine.RedactionRule(
            type: .custom,
            pattern: NSRegularExpression.escapedPattern(for: secret),
            replacement: "[REDACTED]"
        )
        let (redacted, count) = RedactionEngine.redact(text: body, rules: [rule])
        XCTAssertGreaterThan(count, 0, "should redact at least once")
        XCTAssertFalse(redacted.contains(secret), "redacted output must NOT contain the secret string")
        XCTAssertTrue(redacted.contains("[REDACTED]"), "replacement token should be present")
    }

    // MARK: - P0-S1 — native FTS5 proximity (NEAR)

    /// Proximity compiles to a real FTS5 `NEAR(...)`, dispatches to the engine,
    /// matches within distance and does NOT match beyond it.
    func testProximityNearMatchesWithinDistanceOnly() async throws {
        let near = makeEmail(mid: "<p-near@test>", subject: "S", body: "the budget and the deadline are set")
        let far  = makeEmail(mid: "<p-far@test>", subject: "S", body: "budget one two three four five six seven deadline")
        try await FTSSearchIndex.shared.clear()
        try await FTSSearchIndex.shared.indexBatch([near, far])

        let q = try XCTUnwrap(FTSQueryBuilder.proximity(term1: "budget", term2: "deadline", distance: 5))
        await FTSSearchIndex.shared.resetDebugSearchCallCount()
        let ids = try await FTSSearchIndex.shared.searchRaw(q, limit: 50)
        let dispatched = await FTSSearchIndex.shared.debugSearchCallCount

        XCTAssertEqual(dispatched, 1, "proximity must dispatch to FTS5")
        XCTAssertTrue(ids.contains(near.id), "terms within distance must match")
        XCTAssertFalse(ids.contains(far.id), "terms beyond distance must not match")
        try await FTSSearchIndex.shared.clear()
    }

    /// Quoted / punctuated terms cannot break the FTS5 grammar.
    func testProximityQuotingCannotBreakFTS() throws {
        let q = try XCTUnwrap(FTSQueryBuilder.proximity(term1: "bud\"get", term2: "dead-line", distance: 3))
        XCTAssertTrue(q.hasPrefix("NEAR("))
        XCTAssertTrue(q.hasSuffix(", 3)"))
        XCTAssertTrue(q.contains("\"bud\"\"get\""), "internal double-quote must be doubled")
    }

    /// The LIVE proximity path (applyFilters) dispatches to FTS5, not in-RAM.
    func testLiveProximityDispatchesToFTS() async throws {
        let near = makeEmail(mid: "<pp@test>", subject: "S", body: "the budget and the deadline are set")
        try await FTSSearchIndex.shared.clear()
        try await FTSSearchIndex.shared.indexBatch([near])

        let vm = ParsedEmailListViewModel(viewModel: ContentViewModel())
        vm.allEmails = [near]
        vm.isParsing = false
        vm.searchText = "budget NEAR/5 deadline"

        await FTSSearchIndex.shared.resetDebugSearchCallCount()
        vm.applyFilters()
        await vm.lastFTSSearchTask?.value

        let dispatched = await FTSSearchIndex.shared.debugSearchCallCount
        XCTAssertEqual(dispatched, 1, "live proximity must dispatch to FTS5 (not in-RAM)")
        try await FTSSearchIndex.shared.clear()
    }

    // MARK: - P0-S2 — bounded, restartable reconciliation

    private func seedReconcileFixtures() async throws -> [MBOXParser.RawEmail] {
        var fixtures: [MBOXParser.RawEmail] = []
        for i in 0..<12 {
            fixtures.append(makeEmailDated(mid: "<rec-\(i)@test>", subject: "S\(i)", body: "reconcile alpha \(i)", dayOffset: i))
        }
        try await EmailStore.shared.insertBatch(fixtures, sourceFileHash: nil, batchSize: 200, progress: nil)
        try await FTSSearchIndex.shared.clear()
        // Index only the 3 newest (largest dayOffset) → the rest are missing,
        // several beyond the first reconciliation page.
        try await FTSSearchIndex.shared.indexBatch(Array(fixtures.suffix(3)))
        return fixtures
    }

    /// Reconcile reaches records beyond the first page (no fixed ceiling).
    func testBoundedReconcile_indexesMissingBeyondFirstPage() async throws {
        let savedInMemory = EmailStore.testInMemory
        EmailStore.testInMemory = true
        await EmailStore.shared.resetForTesting()
        let ftsDir = FileManager.default.temporaryDirectory.appendingPathComponent("fts_\(UUID().uuidString)")
        FTSSearchIndex.testShardsDirectoryOverride = ftsDir
        await FTSSearchIndex.shared.resetForTesting()
        FTSReconciler.resetCursorForTesting()
        defer { EmailStore.testInMemory = savedInMemory; FTSSearchIndex.testShardsDirectoryOverride = nil }

        let fixtures = try await seedReconcileFixtures()

        let n = try await FTSReconciler.reconcile(pageSize: 5).rowsIndexed   // oldest are on page 2/3
        XCTAssertEqual(n, 9, "indexes the 9 missing, including beyond the first page")

        let hits = try await FTSSearchIndex.shared.search("alpha", limit: 50)
        XCTAssertTrue(hits.contains(fixtures[0].id), "oldest (page 3) record must be reachable")
        let ftsCount = try await FTSSearchIndex.shared.rowCount()
        XCTAssertEqual(ftsCount, 12, "all store rows indexed after reconcile")

        try await FTSSearchIndex.shared.clear()
        await EmailStore.shared.resetForTesting()
        FTSReconciler.resetCursorForTesting()
    }

    /// Reconcile is restartable: interrupt after one page, resume via the saved
    /// cursor, and it completes without re-doing the whole scan.
    func testBoundedReconcile_resumesFromCursor() async throws {
        let savedInMemory = EmailStore.testInMemory
        EmailStore.testInMemory = true
        await EmailStore.shared.resetForTesting()
        let ftsDir = FileManager.default.temporaryDirectory.appendingPathComponent("fts_\(UUID().uuidString)")
        FTSSearchIndex.testShardsDirectoryOverride = ftsDir
        await FTSSearchIndex.shared.resetForTesting()
        FTSReconciler.resetCursorForTesting()
        defer { EmailStore.testInMemory = savedInMemory; FTSSearchIndex.testShardsDirectoryOverride = nil }

        _ = try await seedReconcileFixtures()

        let first = try await FTSReconciler.reconcile(pageSize: 5, maxPages: 1).rowsIndexed   // interrupt
        XCTAssertGreaterThan(first, 0, "first page made progress")
        XCTAssertLessThan(first, 9, "partial — not everything indexed yet")

        let rest = try await FTSReconciler.reconcile(pageSize: 5).rowsIndexed                 // resume
        XCTAssertEqual(first + rest, 9, "resume completes the reconcile")
        let ftsCount = try await FTSSearchIndex.shared.rowCount()
        XCTAssertEqual(ftsCount, 12, "all rows indexed after resume")

        try await FTSSearchIndex.shared.clear()
        await EmailStore.shared.resetForTesting()
        FTSReconciler.resetCursorForTesting()
    }

    // MARK: - P0-#3 — AI tools use FTS5/EmailStore, not the whole archive

    // MARK: - Stage 3 — EmailRepository bounded data contract

    /// The repository returns bounded pages/summaries (no full bodies), keyset
    /// pagination doesn't overlap, count works, text query goes through FTS, and
    /// full content hydrates only on demand.
    func testRepositoryPagesBoundedSummariesAndCount() async throws {
        let savedInMemory = EmailStore.testInMemory
        EmailStore.testInMemory = true
        await EmailStore.shared.resetForTesting()
        let ftsDir = FileManager.default.temporaryDirectory.appendingPathComponent("fts_\(UUID().uuidString)")
        FTSSearchIndex.testShardsDirectoryOverride = ftsDir
        await FTSSearchIndex.shared.resetForTesting()
        defer { EmailStore.testInMemory = savedInMemory; FTSSearchIndex.testShardsDirectoryOverride = nil }

        let fixtures = (0..<7).map { makeEmailDated(mid: "<repo-\($0)@test>", subject: "Repo \($0)", body: "alpha body \($0)", dayOffset: $0) }
        try await EmailStore.shared.insertBatch(fixtures, sourceFileHash: nil, batchSize: 200, progress: nil)
        try await FTSSearchIndex.shared.clear()
        try await FTSSearchIndex.shared.indexBatch(fixtures)

        let repo = EmailStoreRepository.shared

        let total = try await repo.count(query: .all)
        XCTAssertEqual(total, 7, "count(all) == store total")

        let p1 = try await repo.page(query: .all, cursor: nil, limit: 3)
        XCTAssertEqual(p1.summaries.count, 3, "bounded page")
        XCTAssertNotNil(p1.nextCursor, "more pages available")
        XCTAssertTrue(p1.summaries.allSatisfy { $0.bodyPreview.count <= 400 }, "summary preview, not full body")

        let p2 = try await repo.page(query: .all, cursor: p1.nextCursor, limit: 3)
        XCTAssertTrue(Set(p1.summaries.map(\.id)).isDisjoint(with: Set(p2.summaries.map(\.id))), "keyset pages don't overlap")

        let hits = try await repo.page(query: EmailQuery(text: "alpha"), cursor: nil, limit: 5)
        XCTAssertGreaterThan(hits.summaries.count, 0, "text query returns hits")
        XCTAssertLessThanOrEqual(hits.summaries.count, 5, "bounded")

        let full = try await repo.fullEmail(id: p1.summaries[0].id)
        XCTAssertNotNil(full, "full content hydrates on demand")

        await EmailStore.shared.resetForTesting()
        try await FTSSearchIndex.shared.clear()
    }

    // MARK: - Stage 3.1 — repository hardening

    /// count() is an exact aggregate, independent of the page/search limit
    /// (does not materialize result IDs).
    func testCountIsAggregateNotMaterialized() async throws {
        let savedInMemory = EmailStore.testInMemory
        EmailStore.testInMemory = true
        await EmailStore.shared.resetForTesting()
        defer { EmailStore.testInMemory = savedInMemory }

        let fixtures = (0..<30).map { makeEmail(mid: "<c-\($0)@t>", subject: "S\($0)", body: "common token \($0)") }
        try await EmailStore.shared.insertBatch(fixtures, sourceFileHash: nil, batchSize: 200, progress: nil)
        try await FTSSearchIndex.shared.clear()
        try await FTSSearchIndex.shared.indexBatch(fixtures)

        let repo = EmailStoreRepository.shared
        let c = try await repo.count(query: EmailQuery(text: "common"))
        XCTAssertEqual(c, 30, "exact count, independent of any page/search limit")
        let p = try await repo.page(query: EmailQuery(text: "common"), cursor: nil, limit: 5)
        XCTAssertLessThanOrEqual(p.summaries.count, 5, "page stays bounded while count is full")

        await EmailStore.shared.resetForTesting()
    }

    /// Date bounds are applied in the DB; text + exact date range is now
    /// SUPPORTED (FTS candidates filtered by exact date, bm25 order).
    func testDateBoundsHonoredAndTextPlusDateSupported() async throws {
        // dayOffset i → "1+i Jan 2025 14:30 UTC". 10 emails, days 01..10.
        let fixtures = (0..<10).map { makeEmailDated(mid: "<d-\($0)@t>", subject: "S\($0)", body: "body \($0)", dayOffset: $0) }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mailin-td-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store"))
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts"))
        try await store.insertBatch(fixtures, batchSize: 100)
        try await fts.indexBatch(fixtures)
        let repo = EmailStoreRepository(store: store, fts: fts)

        // Boundary between day05 (14:30) and day06 (14:30): includes days 06..10 = 5.
        var comps = DateComponents()
        comps.year = 2025; comps.month = 1; comps.day = 5; comps.hour = 20; comps.minute = 0
        comps.timeZone = TimeZone(identifier: "UTC")
        let after = Calendar(identifier: .gregorian).date(from: comps)!

        // Date-only (native DB path).
        let page = try await repo.page(query: EmailQuery(afterDate: after), cursor: nil, limit: 50)
        XCTAssertEqual(page.summaries.count, 5, "afterDate bound applied at DB level")
        let cnt = try await repo.count(query: EmailQuery(afterDate: after))
        XCTAssertEqual(cnt, 5, "date-filtered count matches")

        // Text + date (FTS candidates + exact date filter). "body" matches all 10.
        let td = try await repo.page(query: EmailQuery(text: "body", afterDate: after), cursor: nil, limit: 50)
        XCTAssertEqual(td.summaries.count, 5, "text + date returns date-filtered text matches")
        XCTAssertTrue(td.summaries.allSatisfy { $0.date >= after }, "all results within the date bound")
        let tdCount = try await repo.count(query: EmailQuery(text: "body", afterDate: after))
        XCTAssertEqual(tdCount, 5, "text + date count matches")
    }

    // MARK: - Stage 3.1.7 — injectable, Release-safe storage environment

    /// Hard safety gate: a disposable environment must refuse to root itself on
    /// (or overlapping) the real user's production storage directory, so a
    /// stress harness can never touch production data. A temp root is allowed.
    func testDisposableEnvironmentRefusesProductionPath() throws {
        let prod = MailinStorageEnvironment.productionStorageDirectory

        // Exactly the production directory → refused.
        XCTAssertThrowsError(try MailinStorageEnvironment.disposable(at: prod)) {
            XCTAssertTrue($0 is StorageEnvironmentError)
        }
        // A directory INSIDE production → refused.
        XCTAssertThrowsError(
            try MailinStorageEnvironment.disposable(at: prod.appendingPathComponent("fts5"))
        )
        // An ANCESTOR that contains production (Application Support) → refused.
        XCTAssertThrowsError(
            try MailinStorageEnvironment.disposable(at: prod.deletingLastPathComponent())
        )
        // A disjoint temp root → allowed.
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailin-gate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        XCTAssertNoThrow(try MailinStorageEnvironment.disposable(at: temp))
    }

    /// Two disposable environments at different roots are fully isolated: data
    /// written into one is invisible to the other (and neither touches the
    /// shared production singletons).
    func testDisposableEnvironmentsAreIsolatedByRoot() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailin-iso-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let envA = try MailinStorageEnvironment.disposable(at: base.appendingPathComponent("A"))
        let envB = try MailinStorageEnvironment.disposable(at: base.appendingPathComponent("B"))

        let fixtures = (0..<5).map { makeEmail(mid: "<iso-\($0)@t>", subject: "S\($0)", body: "body \($0)") }
        try await envA.store.insertBatch(fixtures, batchSize: 200)

        let a = try await envA.repository.count(query: .all)
        let b = try await envB.repository.count(query: .all)
        XCTAssertEqual(a, 5, "environment A sees its own data")
        XCTAssertEqual(b, 0, "environment B is isolated — sees nothing from A")
        XCTAssertFalse(envA.isProduction, "disposable environment is never marked production")
    }

    // MARK: - Stage 4B.3 — SwiftData → SQLite migration

    /// Non-destructive, count-gated migration copies every distinct email into
    /// SQLite, leaves the SwiftData source intact, and is idempotent.
    func testMigration_swiftDataToSQLite_nonDestructiveAndCountGated() async throws {
        let saved = EmailStore.testInMemory
        EmailStore.testInMemory = true
        await EmailStore.shared.resetForTesting()
        defer { EmailStore.testInMemory = saved }

        // 40 distinct + 10 duplicate Message-IDs → source dedups to 40.
        var fixtures = (0..<40).map { makeEmail(mid: "<m-\($0)@t>", subject: "S\($0)", body: "token body \($0)") }
        fixtures += (0..<10).map { makeEmail(mid: "<m-\($0)@t>", subject: "dup", body: "dup") }
        try await EmailStore.shared.insertBatch(fixtures, batchSize: 100)
        let srcCount = try await EmailStore.shared.totalCount()
        XCTAssertEqual(srcCount, 40, "source deduped to 40")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailin-mig-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dest = SQLiteEmailStore(directory: root)

        let r = try await MailinStoreMigration.migrate(from: EmailStore.shared, to: dest, markCompleteFlag: false)
        XCTAssertTrue(r.completed, "count-gated completion")
        XCTAssertEqual(r.destCount, 40, "all distinct rows copied")
        XCTAssertEqual(r.copied, 40)
        let destCount = try await dest.totalCount()
        XCTAssertEqual(destCount, 40)
        // Non-destructive: source untouched.
        let srcAfter = try await EmailStore.shared.totalCount()
        XCTAssertEqual(srcAfter, 40, "SwiftData source not modified")
        // Content actually landed (not just counts).
        let dpage = try await dest.summaryPage(after: nil, before: nil, cursorDate: nil, cursorID: nil, limit: 100)
        XCTAssertEqual(dpage.count, 40)
        let one = dpage.first!
        let full = try await dest.fullEmail(id: one.id)
        XCTAssertNotNil(full, "bodies migrated, fetchable by id")

        // Idempotent: a second run copies nothing.
        let r2 = try await MailinStoreMigration.migrate(from: EmailStore.shared, to: dest, markCompleteFlag: false)
        XCTAssertEqual(r2.copied, 0)
        XCTAssertTrue(r2.completed)

        await EmailStore.shared.resetForTesting()
    }

    /// An interrupted migration resumes and completes without re-copying.
    func testMigration_resumesAfterInterruption() async throws {
        let saved = EmailStore.testInMemory
        EmailStore.testInMemory = true
        await EmailStore.shared.resetForTesting()
        defer { EmailStore.testInMemory = saved }

        let fixtures = (0..<30).map { makeEmailDated(mid: "<r-\($0)@t>", subject: "S\($0)", body: "body \($0)", dayOffset: $0) }
        try await EmailStore.shared.insertBatch(fixtures, batchSize: 100)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailin-mig-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dest = SQLiteEmailStore(directory: root)

        let first = try await MailinStoreMigration.migrate(from: EmailStore.shared, to: dest, pageSize: 5, maxPages: 2, markCompleteFlag: false)
        XCTAssertFalse(first.completed, "interrupted partway")
        XCTAssertLessThan(first.destCount, 30)
        XCTAssertGreaterThan(first.copied, 0)

        let rest = try await MailinStoreMigration.migrate(from: EmailStore.shared, to: dest, pageSize: 5, markCompleteFlag: false)
        XCTAssertTrue(rest.completed, "resume completes")
        XCTAssertEqual(rest.destCount, 30)
        XCTAssertEqual(first.copied + rest.copied, 30, "no row copied twice")

        await EmailStore.shared.resetForTesting()
    }

    // MARK: - Stage 5C.0 — migration firewall ratchet guard

    /// The number of legacy whole-corpus references (parsedEmails / .allEmails /
    /// filteredEmails) may only DECREASE as consumers migrate behind
    /// ArchiveDataService. Fails if a new reference is introduced; lower
    /// `baseline` whenever you retire references. (No hosted CI, so this runs as
    /// a unit test on the dev machine / ⌘U.)
    func testLegacyCorpusConsumerCountOnlyDecreases() throws {
        let baseline = 256   // W2-B: metadata + widget migrated (was 260)
        let src = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // maxmailinTests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("maxmailin")
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil) else {
            throw XCTSkip("app source not found at \(src.path)")
        }
        let patterns = ["parsedEmails", ".allEmails", "filteredEmails"]
        var count = 0
        for f in items where f.pathExtension == "swift" && f.lastPathComponent != "ArchiveDataService.swift" {
            guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
            for p in patterns { count += text.components(separatedBy: p).count - 1 }
        }
        print("LEGACY_CORPUS_CONSUMERS=\(count) (baseline \(baseline))")
        XCTAssertLessThanOrEqual(count, baseline,
            "Introduced a new legacy whole-corpus reference (\(count) > \(baseline)). Route new code through ArchiveDataService, not parsedEmails/allEmails/filteredEmails.")
    }

    /// Differential test: the firewall's paged/streamed reads over SQLite must
    /// return the same ids/order/count as a direct-array oracle — the guarantee
    /// that lets consumers migrate onto ArchiveDataService with confidence.
    func testArchiveDataService_matchesArrayOracle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailin-fw-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store"))
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts"))
        let svc = ArchiveDataService(repository: EmailStoreRepository(store: store, fts: fts))

        // Distinct dates → deterministic keyset order.
        let fixtures = (0..<20).map { makeEmailDated(mid: "<f-\($0)@t>", subject: "S\($0)", body: "b \($0)", dayOffset: $0) }
        try await store.insertBatch(fixtures, batchSize: 100)

        // Oracle: (date DESC, id DESC) with id compared as its uuid string,
        // mirroring the SQLite keyset.
        let oracleIDs = fixtures.sorted { lhs, rhs in
            let ld = MBOXParser.parseDate(lhs.headers["Date"]) ?? .distantPast
            let rd = MBOXParser.parseDate(rhs.headers["Date"]) ?? .distantPast
            if ld != rd { return ld > rd }
            return lhs.id.uuidString > rhs.id.uuidString
        }.map(\.id)

        let page = try await svc.page(query: .all, cursor: nil, limit: 100)
        XCTAssertEqual(page.summaries.map(\.id), oracleIDs, "firewall page order == array oracle")
        let count = try await svc.count(query: .all)
        XCTAssertEqual(count, 20, "firewall count == oracle count")

        // Streaming walks the whole set (bounded pages) with the same members.
        var streamed: [EmailID] = []
        for try await batch in svc.streamSummaries(query: .all, batchSize: 7) {
            streamed.append(contentsOf: batch.map(\.id))
        }
        XCTAssertEqual(Set(streamed), Set(oracleIDs), "stream covers the whole archive")
        XCTAssertEqual(streamed.count, 20, "stream has no skips or duplicates")

        // Detail hydration by id returns bodies.
        let full = try await svc.fullEmail(id: oracleIDs[0])
        XCTAssertNotNil(full)
    }

    // MARK: - Stage 5D.1A — bounded paged list model

    /// (date DESC, id-string DESC) oracle mirroring the SQLite keyset.
    private func oracleOrder(_ fixtures: [MBOXParser.RawEmail]) -> [EmailID] {
        fixtures.sorted { a, b in
            let ad = MBOXParser.parseDate(a.headers["Date"]) ?? .distantPast
            let bd = MBOXParser.parseDate(b.headers["Date"]) ?? .distantPast
            if ad != bd { return ad > bd }
            return a.id.uuidString > b.id.uuidString
        }.map(\.id)
    }

    private func makeListVM(_ fixtures: [MBOXParser.RawEmail], pageSize: Int, maxRetained: Int) async throws -> ArchiveListViewModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailin-lvm-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store"))
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts"))
        try await store.insertBatch(fixtures, batchSize: 200)
        let svc = ArchiveDataService(repository: EmailStoreRepository(store: store, fts: fts))
        return ArchiveListViewModel(archive: svc, pageSize: pageSize, maxRetained: maxRetained)
    }

    /// Paged list ids/order/count/traversal match the array oracle; pages are
    /// disjoint, page size is never exceeded, detail hydrates, missing → nil.
    func testArchiveListVM_differentialAgainstOracle() async throws {
        // dayOffset wraps at 28 → repeated timestamps, so this also exercises
        // keyset tie-breaking with no skips/duplicates.
        let fixtures = (0..<55).map { makeEmailDated(mid: "<l-\($0)@t>", subject: "Subj \($0)", body: "body \($0)", dayOffset: $0) }
        let oracle = oracleOrder(fixtures)
        let vm = try await makeListVM(fixtures, pageSize: 10, maxRetained: 10_000)

        var appended: [EmailID] = []
        var maxBatch = 0
        vm._debugOnAppend = { batch in appended.append(contentsOf: batch.map(\.id)); maxBatch = max(maxBatch, batch.count) }

        await vm.loadInitial()
        XCTAssertEqual(vm.totalCount, 55, "count matches oracle")
        XCTAssertEqual(vm.summaries.map(\.id), Array(oracle.prefix(10)), "first page ids/order match oracle")
        XCTAssertTrue(vm.hasMore)
        let page1 = Set(vm.summaries.map(\.id))

        await vm.loadNextPage()
        XCTAssertEqual(vm.summaries.map(\.id), Array(oracle.prefix(20)), "second page appends in oracle order")
        let page2 = Set(vm.summaries.map(\.id)).subtracting(page1)
        XCTAssertTrue(page1.isDisjoint(with: page2), "page 1 ∩ page 2 = ∅")

        var guardCount = 0
        while vm.hasMore && guardCount < 100 { await vm.loadNextPage(); guardCount += 1 }
        XCTAssertEqual(vm.summaries.map(\.id), oracle, "full traversal (no cap) == oracle exactly")
        XCTAssertEqual(appended, oracle, "every id yielded exactly once, in order")
        XCTAssertLessThanOrEqual(maxBatch, 10, "page size never exceeded")

        // Detail hydration by id, and missing id → nil.
        let full = try await vm.fullEmail(id: oracle[0])
        XCTAssertEqual(full?.id, oracle[0], "fullEmail returns the same logical email")
        let missing = try await vm.fullEmail(id: UUID())
        XCTAssertNil(missing, "nonexistent id returns nil")
    }

    /// Resident summaries stay bounded across a large traversal, yet no id is
    /// skipped or duplicated (verified via the per-page hook).
    func testArchiveListVM_boundedRetention() async throws {
        let fixtures = (0..<500).map { makeEmail(mid: "<bm-\($0)@t>", subject: "S\($0)", body: "b \($0)") }
        let oracle = oracleOrder(fixtures)
        let vm = try await makeListVM(fixtures, pageSize: 50, maxRetained: 120)

        var appended: [EmailID] = []
        vm._debugOnAppend = { appended.append(contentsOf: $0.map(\.id)) }

        await vm.loadInitial()
        var guardCount = 0
        while vm.hasMore && guardCount < 100 { await vm.loadNextPage(); guardCount += 1 }

        XCTAssertLessThanOrEqual(vm.maxRetainedObserved, 120, "resident window never exceeds maxRetained")
        XCTAssertGreaterThanOrEqual(vm.maxRetainedObserved, 100, "window actually filled")
        XCTAssertLessThanOrEqual(vm.summaries.count, 120)
        XCTAssertEqual(Set(appended), Set(oracle), "no ids skipped despite capping")
        XCTAssertEqual(appended.count, 500, "no duplicates")
    }

    /// Bounded bidirectional page window: forward scroll drops the head page,
    /// backward scroll re-fetches it EXACTLY via its remembered start cursor,
    /// and the resident window never exceeds `windowPages * pageSize`.
    func testArchiveListVM_bidirectionalPageWindow() async throws {
        let fixtures = (0..<300).map { makeEmailDated(mid: "<bd-\($0)@t>", subject: "S\($0)", body: "b \($0)", dayOffset: $0) }
        let oracle = oracleOrder(fixtures)
        let vm = try await makeListVM(fixtures, pageSize: 50, maxRetained: 100)   // windowPages = 2

        await vm.loadInitial()
        XCTAssertEqual(vm.summaries.map(\.id), Array(oracle[0..<50]))
        XCTAssertFalse(vm.hasPrevious)
        await vm.loadNextPage()                                   // [0,1]
        XCTAssertEqual(vm.summaries.map(\.id), Array(oracle[0..<100]))
        await vm.loadNextPage()                                   // drop 0 → [1,2]
        XCTAssertEqual(vm.summaries.map(\.id), Array(oracle[50..<150]))
        XCTAssertTrue(vm.hasPrevious, "pages exist before the window head")
        await vm.loadNextPage()                                   // [2,3]
        XCTAssertEqual(vm.summaries.map(\.id), Array(oracle[100..<200]))

        await vm.loadPreviousPage()                               // [1,2]
        XCTAssertEqual(vm.summaries.map(\.id), Array(oracle[50..<150]), "backward refetch reproduces the earlier page exactly")
        await vm.loadPreviousPage()                               // [0,1]
        XCTAssertEqual(vm.summaries.map(\.id), Array(oracle[0..<100]))
        XCTAssertFalse(vm.hasPrevious, "back at the top")
        XCTAssertLessThanOrEqual(vm.maxRetainedObserved, 100, "window stays bounded through bidirectional browsing")
    }

    /// Delete from the list removes the row from the store, FTS and the paged
    /// results, with no skip/duplicate corruption across page boundaries.
    func testArchiveListVM_deleteReflectsInPagesAndSearch() async throws {
        let fixtures = (0..<40).map { makeEmailDated(mid: "<del-\($0)@t>", subject: "S\($0)", body: "token \($0)", dayOffset: $0) }
        // Build a VM whose archive also has FTS, so search reflects deletion.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mailin-del-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store"))
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts"))
        try await store.insertBatch(fixtures, batchSize: 100)
        try await fts.indexBatch(fixtures)
        let svc = ArchiveDataService(repository: EmailStoreRepository(store: store, fts: fts))
        let vm = ArchiveListViewModel(archive: svc, pageSize: 10, maxRetained: 10_000)

        await vm.loadInitial()
        var guardN = 0
        while vm.hasMore && guardN < 50 { await vm.loadNextPage(); guardN += 1 }
        XCTAssertEqual(vm.summaries.count, 40)
        let victim = vm.summaries[15].id   // a row on a later page

        await vm.delete([victim])
        // Reloaded pages must not contain the victim, count drops, no dupes.
        var seen = Set<EmailID>(); var dup = false
        guardN = 0
        while vm.hasMore && guardN < 50 { await vm.loadNextPage(); guardN += 1 }
        for s in vm.summaries { if !seen.insert(s.id).inserted { dup = true } }
        XCTAssertFalse(seen.contains(victim), "deleted row gone from paged results")
        XCTAssertFalse(dup, "no duplicates after delete")
        let count = try await svc.count(query: .all)
        XCTAssertEqual(count, 39, "store count reflects deletion")
        // FTS also no longer returns it.
        let hits = try await fts.searchRaw("token", limit: 100)
        XCTAssertFalse(hits.contains(victim), "deleted row gone from FTS")
    }

    /// Query-revision guard: a slow superseded load must NOT overwrite the newer
    /// query's results, even if it completes last (deterministic via a gated mock).
    func testArchiveListVM_revisionGuardDropsStale() async throws {
        let mock = GatedRepository()
        let a = EmailSummary(id: UUID(), messageID: "A", subject: "A", from: "a", date: Date(timeIntervalSince1970: 100), bodyPreview: "", hasAttachments: false, sizeBytes: 0)
        let c = EmailSummary(id: UUID(), messageID: "C", subject: "C", from: "c", date: Date(timeIntervalSince1970: 200), bodyPreview: "", hasAttachments: false, sizeBytes: 0)
        await mock.setDatasets(["__all__": [a], "C": [c]])
        let vm = ArchiveListViewModel(archive: ArchiveDataService(repository: mock), pageSize: 10, maxRetained: 100)

        let tA = Task { await vm.loadInitial() }                       // query .all (stale-to-be)
        await waitUntil { await mock.pending == 1 }
        let tC = Task { await vm.setQuery(EmailQuery(text: "C")) }     // supersedes A
        await waitUntil { await mock.pending == 2 }

        await mock.release()   // A's page returns first → revision stale → discarded
        await mock.release()   // C's page returns → published
        _ = await tA.value; _ = await tC.value

        XCTAssertEqual(vm.summaries.map(\.id), [c.id], "only the latest query's results are visible")
        XCTAssertEqual(vm.totalCount, 1)
        XCTAssertFalse(vm.isLoading, "loading state settled")
    }

    // MARK: - Stage 5 Wave 2A — DB-side aggregates

    /// ArchiveAggregateService matches a Swift-computed oracle (total, with-
    /// attachments, date range, top senders/subjects) — DB aggregates, no corpus.
    func testArchiveAggregateService_matchesOracle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mailin-agg-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store"))

        // Deterministic fixtures: sender cycles 0..4 (so sender k appears with a
        // known frequency); every 3rd has an attachment; subjects repeat mod 7.
        var fixtures: [MBOXParser.RawEmail] = []
        for i in 0..<50 {
            var e = makeEmailDated(mid: "<agg-\(i)@t>", subject: "Subject \(i % 7)", body: "b \(i)", dayOffset: i)
            e.headers["From"] = "sender\(i % 5)@example.com"
            if i % 3 == 0 { e.attachments = [AttachmentMetadata(filename: "a.pdf", mimeType: "application/pdf", size: 10)] }
            fixtures.append(e)
        }
        try await store.insertBatch(fixtures, batchSize: 100)
        let svc = ArchiveAggregateService(store: store)
        let snap = try await svc.snapshot(topLimit: 5)

        // Oracle.
        XCTAssertEqual(snap.total, 50)
        XCTAssertEqual(snap.withAttachments, fixtures.filter { !$0.attachments.isEmpty }.count)
        let dates = fixtures.compactMap { MBOXParser.parseDate($0.headers["Date"]) }
        XCTAssertEqual(snap.minDate, dates.min())
        XCTAssertEqual(snap.maxDate, dates.max())

        let senderCounts = Dictionary(grouping: fixtures, by: { $0.headers["From"] ?? "" }).mapValues { $0.count }
        let topSenderOracle = senderCounts.max { $0.value < $1.value }!
        XCTAssertEqual(snap.topSenders.first?.count, topSenderOracle.value, "top sender frequency matches oracle")
        XCTAssertTrue(snap.topSenders.count <= 5, "bounded to topLimit")

        let subjectCounts = Dictionary(grouping: fixtures, by: { $0.headers["Subject"] ?? "" }).mapValues { $0.count }
        XCTAssertEqual(snap.topSubjects.first?.count, subjectCounts.values.max(), "top subject frequency matches oracle")
    }

    // MARK: - Stage 5 Wave 2A — derived-state platform

    /// Corpus revision bumps monotonically; derived state persists/fetches by id,
    /// stale-scans below a revision, cascades on delete, and a background job
    /// processes every stale id in bounded batches until none remain.
    func testDerivedStatePlatform() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mailin-dv-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store"))
        let fixtures = (0..<25).map { makeEmail(mid: "<dv-\($0)@t>", subject: "S\($0)", body: "b \($0)") }
        try await store.insertBatch(fixtures, batchSize: 100)

        // Corpus revision monotonic.
        let rev0 = try await store.corpusRevision()
        let rev1 = try await store.bumpCorpusRevision()
        XCTAssertEqual(rev1, rev0 + 1)

        // All ids are stale (no derived rows yet).
        let stale = try await store.derivedStaleIDs(below: rev1, limit: 1000)
        XCTAssertEqual(stale.count, 25, "every email is stale before analysis")

        // Background job computes derived state for all, in bounded batches.
        let runner = ArchiveBackgroundJobRunner(store: store)
        var batchSizesSeen: [Int] = []
        let finalState = await runner.run(batchSize: 10) { emails, rev in
            batchSizesSeen.append(emails.count)
            return emails.map { DerivedRecord(emailID: $0.id, corpusRevision: rev, sentiment: "neutral", topic: "t\(abs($0.id.hashValue) % 3)") }
        }
        XCTAssertEqual(finalState, .completed)
        let derivedCount1 = try await store.derivedCount()
        XCTAssertEqual(derivedCount1, 25, "all derived rows persisted")
        XCTAssertTrue(batchSizesSeen.allSatisfy { $0 <= 10 }, "bounded batches")
        let noneStale = try await store.derivedStaleIDs(below: rev1, limit: 1000)
        XCTAssertTrue(noneStale.isEmpty, "nothing stale after the job")

        // Fetch by id round-trips.
        let fetched = try await store.derivedFetch(ids: [fixtures[0].id, fixtures[1].id])
        XCTAssertEqual(fetched[fixtures[0].id]?.sentiment, "neutral")
        XCTAssertEqual(fetched[fixtures[0].id]?.corpusRevision, rev1)

        // Bumping the revision makes everything stale again (invalidation).
        let rev2 = try await store.bumpCorpusRevision()
        let staleAfterBump = try await store.derivedStaleIDs(below: rev2, limit: 1000)
        XCTAssertEqual(staleAfterBump.count, 25, "revision bump invalidates derived state")

        // Deleting an email cascades its derived row.
        try await store.delete(ids: [fixtures[0].id])
        let afterDelete = try await store.derivedFetch(ids: [fixtures[0].id])
        XCTAssertNil(afterDelete[fixtures[0].id], "derived state removed with the email")
        let derivedCount2 = try await store.derivedCount()
        XCTAssertEqual(derivedCount2, 24)
    }

    // MARK: - Stage 5 Wave 2A — evidence + export services

    /// Evidence service returns bounded, ordered references with excerpts drawn
    /// from the real bodies; text queries retrieve matching evidence only.
    func testArchiveEvidenceService_boundedAndGrounded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mailin-ev-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store"))
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts"))
        var fixtures = (0..<20).map { makeEmailDated(mid: "<ev-\($0)@t>", subject: "S\($0)", body: "common body content number \($0)", dayOffset: $0) }
        fixtures[3].plainBody = "zebraxyz secret marker three"
        try await store.insertBatch(fixtures, batchSize: 100)
        try await fts.indexBatch(fixtures)
        let svc = ArchiveEvidenceService(archive: ArchiveDataService(repository: EmailStoreRepository(store: store, fts: fts)), excerptChars: 40)

        let all = try await svc.evidence(for: .all, limit: 5)
        XCTAssertEqual(all.count, 5, "bounded to limit")
        XCTAssertTrue(all.allSatisfy { $0.excerpt.count <= 40 }, "excerpts bounded")
        XCTAssertTrue(all.allSatisfy { !$0.evidenceID.isEmpty })

        let hits = try await svc.evidence(for: EmailQuery(text: "zebraxyz"), limit: 10)
        XCTAssertEqual(hits.count, 1, "text query retrieves only matching evidence")
        XCTAssertEqual(hits.first?.id, fixtures[3].id)
        XCTAssertTrue(hits.first?.excerpt.contains("zebraxyz") ?? false, "excerpt grounded in real body")
    }

    /// Export streams a whole-query selection to disk incrementally and the
    /// output record count matches the selection (minus exclusions).
    func testArchiveExportService_streamsSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mailin-exp-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store"))
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts"))
        let fixtures = (0..<30).map { makeEmailDated(mid: "<exp-\($0)@t>", subject: "Subject, \($0)", body: "b \($0)", dayOffset: $0) }
        try await store.insertBatch(fixtures, batchSize: 100)
        let svc = ArchiveExportService(archive: ArchiveDataService(repository: EmailStoreRepository(store: store, fts: fts)))

        // CSV, whole-query Select All minus 5 exclusions → 25 rows + header.
        let excluded = Set(fixtures.prefix(5).map(\.id))
        let csvURL = root.appendingPathComponent("out.csv")
        var progressTicks = 0
        let result = try await svc.export(scope: .query(.all, exclusions: excluded), format: .csvSummaries, to: csvURL, batchSize: 7) { _ in progressTicks += 1 }
        XCTAssertEqual(result.recordsWritten, 25, "streamed exactly the selection minus exclusions")
        XCTAssertTrue(result.completed)
        XCTAssertGreaterThan(progressTicks, 1, "progress reported per batch (streamed, not one shot)")
        let lines = try String(contentsOf: csvURL, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 26, "header + 25 rows")
        XCTAssertTrue(lines[0].hasPrefix("id,date,from,to,subject"))
        // CSV quoting: subjects contain commas.
        XCTAssertTrue(lines[1].contains("\"Subject,"), "comma-bearing field quoted")

        // JSON export parses and has the right count.
        let jsonURL = root.appendingPathComponent("out.json")
        _ = try await svc.export(scope: .explicit(Set(fixtures.map(\.id))), format: .jsonSummaries, to: jsonURL)
        let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [[String: Any]]
        XCTAssertEqual(parsed?.count, 30, "valid JSON array of all 30")
    }

    // MARK: - Stage 5 Wave 1C/1E — detail hydration + selection scope

    /// ID→fullEmail detail: hydrates the right email, reports missing, and a
    /// stale selection load cannot replace a newer selection.
    func testArchiveDetailVM_hydrationMissingAndRace() async throws {
        // Hydration + missing over a real store.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mailin-dvm-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store"))
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts"))
        let fixtures = (0..<5).map { makeEmail(mid: "<d-\($0)@t>", subject: "S\($0)", body: "body \($0)") }
        try await store.insertBatch(fixtures, batchSize: 100)
        let svc = ArchiveDataService(repository: EmailStoreRepository(store: store, fts: fts))
        let dvm = ArchiveDetailViewModel(archive: svc, cacheLimit: 4)

        await dvm.select(fixtures[0].id)
        XCTAssertEqual(dvm.loadedID, fixtures[0].id, "hydrates the selected email")
        await dvm.select(UUID())
        if case .failed = dvm.state {} else { XCTFail("missing id should fail") }

        // Race: stale selection (via gated mock) completing last must not win.
        let mock = GatedRepository()
        let dvm2 = ArchiveDetailViewModel(archive: ArchiveDataService(repository: mock), cacheLimit: 4)
        let idA = UUID(), idB = UUID()
        let tA = Task { await dvm2.select(idA) }
        await waitUntil { await mock.pending == 1 }
        let tB = Task { await dvm2.select(idB) }
        await waitUntil { await mock.pending == 2 }
        await mock.release()   // A resumes first → stale → discarded
        await mock.release()   // B resumes → wins
        _ = await tA.value; _ = await tB.value
        XCTAssertEqual(dvm2.loadedID, idB, "only the latest selection is shown")
    }

    /// Selection scope resolves counts symbolically — Select All is never a
    /// materialized id set — and streams the selected emails in bounded batches.
    func testArchiveSelectionScope_countAndStream() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mailin-sel-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store"))
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts"))
        let fixtures = (0..<30).map { makeEmail(mid: "<s-\($0)@t>", subject: "S\($0)", body: "body \($0)") }
        try await store.insertBatch(fixtures, batchSize: 100)
        let svc = ArchiveDataService(repository: EmailStoreRepository(store: store, fts: fts))

        let all = ArchiveSelectionScope.query(.all, exclusions: [])
        let allCount = try await svc.count(scope: all)
        XCTAssertEqual(allCount, 30, "whole-query Select All resolves count without a materialized set")

        let excluded = Set(fixtures.prefix(3).map(\.id))
        let minus = ArchiveSelectionScope.query(.all, exclusions: excluded)
        let minusCount = try await svc.count(scope: minus)
        XCTAssertEqual(minusCount, 27)

        var streamed = 0, maxBatch = 0
        for try await batch in svc.streamSelected(scope: minus, batchSize: 7) {
            streamed += batch.count; maxBatch = max(maxBatch, batch.count)
            XCTAssertTrue(batch.allSatisfy { !excluded.contains($0.id) }, "exclusions honored in stream")
        }
        XCTAssertEqual(streamed, 27, "stream yields exactly the selected emails")
        XCTAssertLessThanOrEqual(maxBatch, 7, "bounded batches")

        let explicit = ArchiveSelectionScope.explicit(Set(fixtures.prefix(5).map(\.id)))
        let exCount = try await svc.count(scope: explicit)
        XCTAssertEqual(exCount, 5)
    }

    private func waitUntil(_ condition: @escaping () async -> Bool, timeout: TimeInterval = 3) async {
        let start = Date()
        while !(await condition()) {
            if Date().timeIntervalSince(start) > timeout { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    // MARK: - Stage 5A — storage activation coordinator

    /// Build a coordinator over the in-memory SwiftData source + a disposable
    /// SQLite dest, with an isolated UserDefaults state key.
    private func makeActivation() -> (StorageActivationCoordinator, SQLiteEmailStore, String, URL) {
        let key = "test.activation.\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailin-act-\(UUID().uuidString)", isDirectory: true)
        let dest = SQLiteEmailStore(directory: root)
        let coord = StorageActivationCoordinator(source: .shared, dest: dest, defaults: .standard, stateKey: key)
        return (coord, dest, key, root)
    }

    /// Fresh install (empty source) activates immediately; existing SwiftData
    /// migrates non-destructively and only then activates.
    func testActivation_freshAndExisting() async throws {
        let saved = EmailStore.testInMemory
        EmailStore.testInMemory = true
        await EmailStore.shared.resetForTesting()
        defer { EmailStore.testInMemory = saved }

        // Fresh: nothing in source → active immediately.
        let (fresh, _, freshKey, freshRoot) = makeActivation()
        defer { UserDefaults.standard.removeObject(forKey: freshKey); try? FileManager.default.removeItem(at: freshRoot) }
        let freshBefore = await fresh.isActive
        XCTAssertFalse(freshBefore, "not active until run")
        let s0 = await fresh.activate()
        XCTAssertEqual(s0, .active)
        let s0Active = await fresh.isActive
        XCTAssertTrue(s0Active, "import gate opens only after activation")

        // Existing SwiftData: 25 rows migrate into SQLite, source untouched.
        let fixtures = (0..<25).map { makeEmail(mid: "<a-\($0)@t>", subject: "S\($0)", body: "body \($0)") }
        try await EmailStore.shared.insertBatch(fixtures, batchSize: 100)
        let (coord, dest, key, root) = makeActivation()
        defer { UserDefaults.standard.removeObject(forKey: key); try? FileManager.default.removeItem(at: root) }
        let s1 = await coord.activate()
        XCTAssertEqual(s1, .active)
        let destCount = try await dest.totalCount()
        XCTAssertEqual(destCount, 25, "all rows migrated before activation")
        let srcCount = try await EmailStore.shared.totalCount()
        XCTAssertEqual(srcCount, 25, "SwiftData source not modified (rollback intact)")

        await EmailStore.shared.resetForTesting()
    }

    /// An interrupted migration (state left `copying`, dest partially filled)
    /// resumes and reaches `active`; a stale `active` marker over a short dest
    /// is re-migrated rather than trusted.
    func testActivation_resumesAndRejectsStaleMarker() async throws {
        let saved = EmailStore.testInMemory
        EmailStore.testInMemory = true
        await EmailStore.shared.resetForTesting()
        defer { EmailStore.testInMemory = saved }

        let fixtures = (0..<30).map { makeEmailDated(mid: "<b-\($0)@t>", subject: "S\($0)", body: "body \($0)", dayOffset: $0) }
        try await EmailStore.shared.insertBatch(fixtures, batchSize: 100)

        // Interrupted: copy one page, leave marker at `copying`.
        let (coord, dest, key, root) = makeActivation()
        defer { UserDefaults.standard.removeObject(forKey: key); try? FileManager.default.removeItem(at: root) }
        _ = try await MailinStoreMigration.migrate(from: EmailStore.shared, to: dest, pageSize: 5, maxPages: 1, markCompleteFlag: false)
        let partial = try await dest.totalCount()
        XCTAssertLessThan(partial, 30, "left partially migrated")
        UserDefaults.standard.set("copying", forKey: key)

        let resumed = await coord.activate()
        XCTAssertEqual(resumed, .active, "resumes from copying to active")
        let full = try await dest.totalCount()
        XCTAssertEqual(full, 30, "resume completed the copy")

        // Stale marker: pretend active but wipe the dest — must NOT stay active
        // on a half-populated/empty archive; re-migrates.
        try await dest.clearAll()
        UserDefaults.standard.set("active", forKey: key)
        let recovered = await coord.activate()
        XCTAssertEqual(recovered, .active)
        let refilled = try await dest.totalCount()
        XCTAssertEqual(refilled, 30, "stale active marker over short dest was re-migrated")

        await EmailStore.shared.resetForTesting()
    }

    /// A destination already holding every row activates even when the marker is
    /// absent; a second activate() is an idempotent no-op.
    func testActivation_markerAbsentButComplete_andIdempotent() async throws {
        let saved = EmailStore.testInMemory
        EmailStore.testInMemory = true
        await EmailStore.shared.resetForTesting()
        defer { EmailStore.testInMemory = saved }

        let fixtures = (0..<12).map { makeEmail(mid: "<c-\($0)@t>", subject: "S\($0)", body: "body \($0)") }
        try await EmailStore.shared.insertBatch(fixtures, batchSize: 100)

        let (coord, dest, key, root) = makeActivation()
        defer { UserDefaults.standard.removeObject(forKey: key); try? FileManager.default.removeItem(at: root) }
        // Pre-populate dest fully, but leave the state marker absent.
        _ = try await MailinStoreMigration.migrate(from: EmailStore.shared, to: dest, markCompleteFlag: false)
        XCTAssertNil(UserDefaults.standard.string(forKey: key), "no marker yet")

        let s = await coord.activate()
        XCTAssertEqual(s, .active, "complete dest verifies + activates without re-copy")
        let again = await coord.activate()
        XCTAssertEqual(again, .active, "idempotent")

        await EmailStore.shared.resetForTesting()
    }

    // MARK: - Stage 4 — mailin-v2-stress harness

    /// Drives the REAL engine (EmailStore + FTS5 + repository + reconcile) over
    /// a disposable environment at one or more scales, writing a JSON artifact
    /// and asserting correctness. Skipped in the normal suite (it is heavy);
    /// invoke via `MAILIN_STRESS_SCALES=10000,20000` in the test environment.
    ///   MAILIN_STRESS_SCALES   comma-separated scales (falls back to _SCALE)
    ///   MAILIN_STRESS_CONFIG   label recorded in the JSON (e.g. "Release")
    ///   MAILIN_STRESS_NODESTRUCT=1  skip the delete + FTS-rebuild checks
    ///   MAILIN_STRESS_BODY     body bytes per email (default 600)
    func testStressHarnessSweep() async throws {
        // Trigger channel. A sandboxed test host does NOT inherit the shell
        // environment, so the primary channel is a KEY=VALUE config file the
        // shell drops into the app container's tmp; env vars override if present.
        //   SCALES=10000,20000   CONFIG=Release   NODESTRUCT=1   BODY=600
        let procEnv = ProcessInfo.processInfo.environment
        let tmp = FileManager.default.temporaryDirectory
        let configURL = tmp.appendingPathComponent("mailin_stress_config.txt")
        print("STRESS_CONFIG_PATH=\(configURL.path)")

        var fileCfg: [String: String] = [:]
        if let text = try? String(contentsOf: configURL, encoding: .utf8) {
            for line in text.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    fileCfg[parts[0].trimmingCharacters(in: .whitespaces).uppercased()] =
                        parts[1].trimmingCharacters(in: .whitespaces)
                }
            }
        }
        func opt(_ key: String) -> String? {
            procEnv["MAILIN_STRESS_\(key)"] ?? fileCfg[key]
        }

        guard let scalesRaw = opt("SCALES") ?? opt("SCALE") else {
            throw XCTSkip("No stress config. Drop SCALES=10000 into \(configURL.path) (or set MAILIN_STRESS_SCALES).")
        }
        let scales = scalesRaw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        XCTAssertFalse(scales.isEmpty, "SCALES parsed to no integers")

        let label = opt("CONFIG") ?? "Debug"
        let noDestruct = opt("NODESTRUCT") == "1"
        let bodyBytes = opt("BODY").flatMap { Int($0) } ?? 600

        let outURL = tmp.appendingPathComponent("mailin_stress_results.json")
        print("STRESS_OUTPUT_PATH=\(outURL.path)")

        var results: [StressResult] = []
        for scale in scales {
            var cfg = StressConfig(scale: scale)
            cfg.configurationLabel = label
            cfg.runDestructiveChecks = !noDestruct
            cfg.bodyBytes = bodyBytes

            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("mailin-stress-\(scale)-\(UUID().uuidString)", isDirectory: true)
            let result = try await StressHarness.run(config: cfg, root: root)
            try? FileManager.default.removeItem(at: root)
            results.append(result)

            // Incremental write so a mid-sweep failure still leaves evidence.
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(results).write(to: outURL)

            print(String(format: "STRESS scale=%d passed=%@ import=%.0f/s index=%.0f/s peakImportRSS=%.0fMB postRSS=%.0fMB firstPage=%.1fms deepPage=%.1fms searchP95=%.2fms coldReopen=%.1fms disk=%.1fMB",
                         scale, result.passed ? "YES" : "NO",
                         result.importMsgPerSec, result.indexMsgPerSec,
                         result.rssPeakImportMB, result.rssPostImportMB,
                         result.firstPageMs, result.deepPageMs, result.searchP95Ms,
                         result.coldReopenMs, Double(result.totalDiskBytes) / 1_048_576.0))
            if !result.notes.isEmpty { print("STRESS scale=\(scale) notes: \(result.notes)") }

            XCTAssertTrue(result.passed, "scale \(scale) correctness failed: \(result.notes)")
        }
        print("STRESS_DONE wrote \(results.count) result(s) to \(outURL.path)")
    }

    #if canImport(FoundationModels)
    /// The AI search tool retrieves via FTS5 → EmailStore (bounded evidence),
    /// not by scanning an in-memory `[RawEmail]` corpus.
    func testAISearchToolRetrievesBoundedEvidenceViaFTS() async throws {
        guard #available(macOS 26, iOS 26, *) else {
            throw XCTSkip("Foundation Models tools require macOS/iOS 26")
        }
        let savedInMemory = EmailStore.testInMemory
        EmailStore.testInMemory = true
        await EmailStore.shared.resetForTesting()
        let ftsDir = FileManager.default.temporaryDirectory.appendingPathComponent("fts_\(UUID().uuidString)")
        FTSSearchIndex.testShardsDirectoryOverride = ftsDir
        await FTSSearchIndex.shared.resetForTesting()
        defer { EmailStore.testInMemory = savedInMemory; FTSSearchIndex.testShardsDirectoryOverride = nil }

        let fixtures = (0..<8).map { makeEmail(mid: "<ai-\($0)@test>", subject: "Apollo \($0)", body: "project apollo status update \($0)") }
        try await EmailStore.shared.insertBatch(fixtures, sourceFileHash: nil, batchSize: 200, progress: nil)
        try await FTSSearchIndex.shared.clear()
        try await FTSSearchIndex.shared.indexBatch(fixtures)

        await FTSSearchIndex.shared.resetDebugSearchCallCount()
        let tool = SearchEmailsTool()
        let output = try await tool.call(arguments: .init(query: "apollo"))
        let dispatched = await FTSSearchIndex.shared.debugSearchCallCount

        XCTAssertGreaterThanOrEqual(dispatched, 1, "AI search tool must reach FTS5")
        XCTAssertTrue(output.contains("Apollo"), "returns matching evidence")
        let evidenceCount = output.components(separatedBy: "Subject:").count - 1
        XCTAssertGreaterThan(evidenceCount, 0, "found some evidence")
        XCTAssertLessThanOrEqual(evidenceCount, 5, "bounded evidence set (<=5), not the whole archive")

        try await FTSSearchIndex.shared.clear()
        await EmailStore.shared.resetForTesting()
    }
    #endif
}

/// A repository whose `page()` calls suspend until explicitly `release()`d, so a
/// test can force a deterministic (reordered) completion order and prove the
/// list model's query-revision guard drops stale results. Distinguishes queries
/// by `text` so the "wrong" and "right" results are observably different.
actor GatedRepository: EmailRepository {
    private var gates: [CheckedContinuation<Void, Never>] = []
    private var _pending = 0
    private var datasets: [String: [EmailSummary]] = [:]

    func setDatasets(_ d: [String: [EmailSummary]]) { datasets = d }
    var pending: Int { _pending }

    /// Resume the oldest suspended `page()` call.
    func release() {
        guard !gates.isEmpty else { return }
        let g = gates.removeFirst()
        _pending -= 1
        g.resume()
    }

    private func key(_ q: EmailQuery) -> String { (q.text?.isEmpty ?? true) ? "__all__" : q.text! }

    func page(query: EmailQuery, cursor: EmailPageCursor?, limit: Int) async throws -> EmailPage {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            gates.append(c); _pending += 1
        }
        let data = datasets[key(query)] ?? []
        return EmailPage(summaries: Array(data.prefix(limit)), nextCursor: nil)
    }
    func summaries(ids: [EmailID]) async throws -> [EmailSummary] { [] }
    /// Gated like `page()`: suspends until `release()`, then returns a minimal
    /// email carrying the requested id (so a stale detail load is observable).
    func fullEmail(id: EmailID) async throws -> MBOXParser.RawEmail? {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            gates.append(c); _pending += 1
        }
        return MBOXParser.RawEmail(
            id: id, headers: ["Subject": id.uuidString], rawSource: "", messageType: "stored",
            attachments: [], timestamp: "", domains: [], plainBody: "body", htmlBody: ""
        )
    }
    func fullEmails(ids: [EmailID]) async throws -> [MBOXParser.RawEmail] { [] }
    func exists(ids: [EmailID]) async throws -> Set<EmailID> { [] }
    func count(query: EmailQuery) async throws -> Int { (datasets[key(query)] ?? []).count }
    func delete(ids: [EmailID]) async throws {}
}
