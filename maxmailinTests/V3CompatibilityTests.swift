@testable import ArchiveCore
//
//  V3CompatibilityTests.swift
//  maxmailinTests
//
//  §3-M6 / rule 16: both engines see the same data for the whole of 3.0.
//  Each test flips a 3.0 switch on → off → on (and simulates a crash in the
//  middle of a direct database write) and checks that nothing is lost and
//  nothing released comes back. Everything runs on disposable stores, files
//  and settings bound through `ScopeJobEnvironment`.
//

import XCTest
@testable import maxmailin

@MainActor
final class V3CompatibilityTests: XCTestCase {

    // MARK: - Fixtures

    private struct Env {
        let root: URL
        let store: SQLiteEmailStore
        let archive: ArchiveDataService
        let legalDir: URL
        var manager: CustodianManager
        var mirror: LegalStateMirror
        var job: ScopeJobEnvironment {
            ScopeJobEnvironment(archive: archive, store: store, root: root, custodian: manager, legal: mirror)
        }
        /// A fresh manager + mirror over the same files and database — what a
        /// relaunch sees.
        @MainActor mutating func relaunch(engineOn: Bool) {
            manager = CustodianManager(directory: legalDir)
            mirror = LegalStateMirror(manager: manager)
            mirror.enabledOverride = engineOn
        }
    }

    private func makeEnv(engineOn: Bool = true) -> Env {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("v3compat-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts", isDirectory: true))
        let legalDir = root.appendingPathComponent("legal", isDirectory: true)
        let manager = CustodianManager(directory: legalDir)
        let mirror = LegalStateMirror(manager: manager)
        mirror.enabledOverride = engineOn
        return Env(root: root, store: store,
                   archive: ArchiveDataService(repository: EmailStoreRepository(store: store, fts: fts)),
                   legalDir: legalDir, manager: manager, mirror: mirror)
    }

    private func makeEmail(_ i: Int, from: String, tag: String = "c") -> MBOXParser.RawEmail {
        let date = Date(timeIntervalSince1970: 1_704_067_200 + Double(i) * 86_400)
        let rfc = DateFormatter()
        rfc.locale = Locale(identifier: "en_US_POSIX")
        rfc.timeZone = TimeZone(identifier: "UTC")
        rfc.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let mid = "<\(tag)-\(i)@test>"
        return MBOXParser.RawEmail(
            headers: ["Message-ID": mid, "Subject": "S \(i)", "From": from, "To": "x@example.com",
                      "Date": rfc.string(from: date)],
            rawSource: "Message-ID: \(mid)\nFrom: \(from)\n\nbody \(i)",
            messageType: "email", attachments: [],
            timestamp: ISO8601DateFormatter().string(from: date),
            domains: [String(from.split(separator: "@").last ?? "")],
            plainBody: "body \(i)", htmlBody: "")
    }

    private func ids(_ env: Env, sender: String? = nil) async throws -> [UUID] {
        var q = EmailQuery()
        q.sender = sender
        q.sort = .dateAsc
        var out: [UUID] = []
        for try await page in env.archive.streamSummaries(query: q, batchSize: 1_000) { out += page.map(\.id) }
        return out
    }

    private func dbHolds(_ env: Env) async throws -> Set<UUID> { try await env.store.legalHoldIDs() }

    // MARK: - Legal data: on → off → on

    func testLegalState_flipFlop_losesNothing_andResurrectsNothing() async throws {
        var env = makeEnv()
        try await env.store.insertBatch((0..<3).map { makeEmail($0, from: "alice@a.com") }
                                        + (3..<6).map { makeEmail($0, from: "bob@b.com") }, batchSize: 10)
        let alice = try await ids(env, sender: "alice")
        let bob = try await ids(env, sender: "bob")

        try await ScopeJobEnvironment.$current.withValue(env.job) {
            // ON: whole-scope actions write the database AND the files.
            await env.mirror.activate()
            XCTAssertTrue(env.mirror.isActive)
            var aliceQuery = EmailQuery(); aliceQuery.sender = "alice"
            var bobQuery = EmailQuery(); bobQuery.sender = "bob"
            let placed = try await env.mirror.placeHolds(query: aliceQuery)
            XCTAssertEqual(placed, 3)
            XCTAssertEqual(env.manager.legalHolds, Set(alice), "the files received the database holds")
            _ = try await env.mirror.assignCustodian("Pat", query: bobQuery)
            XCTAssertEqual(Set(env.manager.custodians.keys), Set(bob))
            XCTAssertFalse(env.mirror.hasPendingDatabaseWrite)

            // The database refuses to delete a held email while the copy is live.
            let refused = try await env.store.deleteReportingHeld(ids: [alice[0]])
            XCTAssertEqual(refused, [alice[0]])
        }

        // OFF: the old path changes the files only.
        env.mirror.enabledOverride = false
        try await ScopeJobEnvironment.$current.withValue(env.job) {
            await env.mirror.deactivate()
            env.manager.removeLegalHold(alice[0])
            env.manager.placeLegalHold(on: [bob[0]])
            env.manager.assignCustodian("Lee", to: alice[1])
            // A hold released in the files no longer blocks a delete.
            let refused = try await env.store.deleteReportingHeld(ids: [alice[0]])
            XCTAssertTrue(refused.isEmpty, "released while the engine was off: deletable")
        }

        // ON again, after a relaunch: the database matches the files exactly.
        env.relaunch(engineOn: true)
        try await ScopeJobEnvironment.$current.withValue(env.job) {
            await env.mirror.activate()
            XCTAssertTrue(env.mirror.isActive, "verified: \(env.mirror.lastVerification ?? "")")
            let expectedHolds: Set<UUID> = [alice[1], alice[2], bob[0]]
            XCTAssertEqual(env.manager.legalHolds, expectedHolds)
            let holds = try await dbHolds(env)
            XCTAssertEqual(holds, expectedHolds, "the released hold is gone, the old-path hold arrived")
            let custodians = try await env.store.allCustodianAssignments()
            XCTAssertEqual(custodians, env.manager.custodians)
            XCTAssertEqual(custodians[alice[1]], "Lee")
            XCTAssertEqual(custodians.values.filter { $0 == "Pat" }.count, 3)
        }
    }

    // MARK: - Legal data: crash in the middle of a direct database write

    func testLegalState_interruptedDatabaseWrite_isRecoveredAtLaunch_withTheEngineOff() async throws {
        var env = makeEnv()
        try await env.store.insertBatch((0..<4).map { makeEmail($0, from: "alice@a.com") }, batchSize: 10)
        let all = try await ids(env)

        try await ScopeJobEnvironment.$current.withValue(env.job) {
            await env.mirror.activate()
            // A job starts writing straight into the database …
            env.mirror.beginDatabaseWrite()
            try await env.store.legalHoldsAdd([all[0], all[1]])
            try await env.store.sealsSetOnce([all[0]: "seal-0"])
            // … and the app is killed before the files receive the rows.
        }
        XCTAssertTrue(env.manager.legalHolds.isEmpty, "the files never received them")

        // Relaunch with the engine switched OFF: recovery still runs.
        env.relaunch(engineOn: false)
        await ScopeJobEnvironment.$current.withValue(env.job) {
            XCTAssertTrue(env.mirror.hasPendingDatabaseWrite)
            let recovered = await env.mirror.recoverInterruptedDatabaseWrite()
            XCTAssertEqual(recovered, 3, "two holds and one seal")
            XCTAssertEqual(env.manager.legalHolds, [all[0], all[1]], "the old path now sees the holds")
            XCTAssertEqual(env.manager.evidenceSeals[all[0]], "seal-0")
            XCTAssertFalse(env.mirror.hasPendingDatabaseWrite)
        }

        // And ON again: activation keeps them (the files are the truth, and
        // the files now have them).
        env.relaunch(engineOn: true)
        try await ScopeJobEnvironment.$current.withValue(env.job) {
            await env.mirror.activate()
            XCTAssertTrue(env.mirror.isActive)
            let holds = try await dbHolds(env)
            XCTAssertEqual(holds, [all[0], all[1]])
        }
    }

    /// A hold released and re-sealed through the files while the engine was
    /// off: activation replaces the database seal instead of failing
    /// verification forever.
    func testLegalState_resealedWhileOff_verifiesOnReactivation() async throws {
        var env = makeEnv()
        try await env.store.insertBatch([makeEmail(0, from: "alice@a.com")], batchSize: 10)
        let found = try await ids(env)
        let id = try XCTUnwrap(found.first)

        try await ScopeJobEnvironment.$current.withValue(env.job) {
            await env.mirror.activate()
            env.manager.legalHolds.insert(id)
            env.manager.evidenceSeals[id] = "first-seal"
            await env.mirror.syncNow()
            let seals = try await env.store.allSeals()
            XCTAssertEqual(seals[id], "first-seal")
        }

        env.mirror.enabledOverride = false
        await ScopeJobEnvironment.$current.withValue(env.job) {
            await env.mirror.deactivate()
            env.manager.removeLegalHold(id)                 // old path drops the seal too
            env.manager.legalHolds.insert(id)
            env.manager.evidenceSeals[id] = "second-seal"   // re-held, re-sealed
        }

        env.relaunch(engineOn: true)
        try await ScopeJobEnvironment.$current.withValue(env.job) {
            await env.mirror.activate()
            XCTAssertTrue(env.mirror.isActive, "verification passes: \(env.mirror.lastVerification ?? "")")
            let seals = try await env.store.allSeals()
            XCTAssertEqual(seals[id], "second-seal")
        }
    }

    // MARK: - Bates: on → off → on

    func testBates_flipFlop_bothEnginesSeeAndKeepEachOthersNumbers() async throws {
        let env = makeEnv()
        let suite = "mailin-bates-compat-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        try await env.store.insertBatch((0..<3).map { makeEmail($0, from: "a@a.com") }, batchSize: 10)

        try await ScopeJobEnvironment.$current.withValue(env.job) {
            let manager = BatesNumberingManager(defaults: defaults)
            manager.prefix = "C"
            manager.zeroPadding = 2

            // ON: the 3.0 engine numbers the archive; the old manager sees it.
            let first = try await BatesEngine.assign(scope: .wholeArchive, manager: manager)
            XCTAssertEqual(first.state.assigned, 3)
            XCTAssertEqual(Set(manager.assignments.values), ["C01", "C02", "C03"])

            // OFF: new mail arrives; the old path numbers it after the 3.0 numbers.
            try await env.store.insertBatch((3..<5).map { makeEmail($0, from: "a@a.com", tag: "late") }, batchSize: 10)
            let all = try await ids(env)
            let emails = try await env.archive.fullEmails(ids: all)
            let old = manager.assignNumbers(to: emails)
            XCTAssertEqual(Set(old.values), ["C04", "C05"], "the old path continues after the 3.0 numbers")

            // ON again: the old numbers join the database; nothing renumbered.
            try await env.store.insertBatch([makeEmail(9, from: "a@a.com", tag: "later")], batchSize: 10)
            let before = manager.assignments
            let second = try await BatesEngine.assign(scope: .wholeArchive, manager: manager)
            XCTAssertEqual(second.state.assigned, 1)
            XCTAssertEqual(second.state.first, "C06")
            let stored = try await env.store.reviewCoding(workspace: BatesEngine.workspace, field: BatesEngine.field)
            for (id, number) in before { XCTAssertEqual(stored[id], number, "every earlier number kept, in both stores") }
            XCTAssertEqual(stored.count, 6)
            XCTAssertEqual(manager.assignments, stored, "both engines see the same numbers")
        }
    }

    // MARK: - Privilege flags outside the scanned scope are kept

    func testPrivilegeScan_keepsFlagsOutsideTheScope() async throws {
        let env = makeEnv()
        try await env.store.insertBatch((0..<3).map { makeEmail($0, from: "alice@a.com") }, batchSize: 10)
        let forensic = ForensicManager.shared
        let saved = forensic.privilegeFlags
        addTeardownBlock { @MainActor in forensic.privilegeFlags = saved }
        let elsewhere = UUID()
        forensic.privilegeFlags = [elsewhere: ["attorney-client"]]

        try await ScopeJobEnvironment.$current.withValue(env.job) {
            var q = EmailQuery(); q.sender = "alice"
            _ = try await PrivilegeScanEngine.scan(query: q)
        }
        XCTAssertEqual(forensic.privilegeFlags[elsewhere], ["attorney-client"],
                       "a scan of one scope must not erase flags set on other emails")
    }

    // MARK: - Shadow comparison (§3-M4)

    func testShadowComparison_differencesListsEveryChangedKey() {
        XCTAssertEqual(ShadowComparison.differences(previous: ["a": 1, "b": 2], current: ["a": 1, "b": 3, "c": 1]),
                       ["b: 2 → 3", "c: 0 → 1"])
        XCTAssertTrue(ShadowComparison.differences(previous: ["a": 1], current: ["a": 1]).isEmpty)
    }

    /// The harness runs every pair on the same newest-N emails of a disposable
    /// archive and records a report per tool next to it, not in the app.
    func testShadowComparison_runsEveryPairOnTheSameEmails() async throws {
        let env = makeEnv(engineOn: false)
        try await env.store.insertBatch((0..<12).map { makeEmail($0, from: "pat@corp.com", tag: "sh") }, batchSize: 20)
        let reports = try await ScopeJobEnvironment.$current.withValue(env.job) {
            try await ShadowComparison.run(subset: 10)
        }
        XCTAssertEqual(reports.count, ShadowComparison.pairs.count)
        XCTAssertTrue(reports.allSatisfy { $0.subset == 10 }, "the previous engines got exactly the newest 10")
        let recorded = ScopeJobEnvironment.$current.withValue(env.job) { ShadowComparison.recorded() }
        XCTAssertEqual(recorded.count, reports.count, "reports are written beside the disposable archive")
        // Same detector on the same emails: these two must agree exactly.
        for tool in [String(localized: "PII report"), String(localized: "NLP classification"), String(localized: "Keyword sweep")] {
            let r = try XCTUnwrap(reports.first { $0.tool == tool })
            XCTAssertTrue(r.matches, "\(tool): \(r.differences)")
        }
    }
}
