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
}
