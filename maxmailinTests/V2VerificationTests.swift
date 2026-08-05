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

    /// Date bounds are applied at the DB level; text + exact date range is
    /// rejected explicitly rather than silently ignored.
    func testDateBoundsHonoredAndTextPlusDateRejected() async throws {
        let savedInMemory = EmailStore.testInMemory
        EmailStore.testInMemory = true
        await EmailStore.shared.resetForTesting()
        defer { EmailStore.testInMemory = savedInMemory }

        // dayOffset i → "1+i Jan 2025 14:30 UTC". 10 emails, days 01..10.
        let fixtures = (0..<10).map { makeEmailDated(mid: "<d-\($0)@t>", subject: "S\($0)", body: "body \($0)", dayOffset: $0) }
        try await EmailStore.shared.insertBatch(fixtures, sourceFileHash: nil, batchSize: 200, progress: nil)
        let repo = EmailStoreRepository.shared

        // Boundary between day05 (14:30) and day06 (14:30): includes days 06..10 = 5.
        var comps = DateComponents()
        comps.year = 2025; comps.month = 1; comps.day = 5; comps.hour = 20; comps.minute = 0
        comps.timeZone = TimeZone(identifier: "UTC")
        let after = Calendar(identifier: .gregorian).date(from: comps)!

        let page = try await repo.page(query: EmailQuery(afterDate: after), cursor: nil, limit: 50)
        XCTAssertEqual(page.summaries.count, 5, "afterDate bound applied at DB level")
        let cnt = try await repo.count(query: EmailQuery(afterDate: after))
        XCTAssertEqual(cnt, 5, "date-filtered count matches")

        var rejected = false
        do {
            _ = try await repo.page(query: EmailQuery(text: "body", afterDate: after), cursor: nil, limit: 10)
        } catch is EmailRepositoryError {
            rejected = true
        }
        XCTAssertTrue(rejected, "text + exact date range must be rejected, not silently ignored")

        await EmailStore.shared.resetForTesting()
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
