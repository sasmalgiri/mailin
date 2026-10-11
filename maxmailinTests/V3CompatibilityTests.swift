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
import SQLite3
import CryptoKit
import FoundationModels
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

    // MARK: - M2: a tripped engine comes back once with a new version

    func testTrippedEngine_restoredOnceInANewVersion_unlessTheUserChose() {
        let env = makeEnv(engineOn: false)
        ScopeJobEnvironment.$current.withValue(env.job) {
            EngineGuard.saveTrips([
                EngineTrip(capability: Capability.v3PIIReport.rawValue, date: Date(), appVersion: "3.0 (600)"),
                EngineTrip(capability: Capability.v3IOC.rawValue, date: Date(), appVersion: "3.0 (600)"),
                EngineTrip(capability: Capability.v3Bates.rawValue, date: Date(), appVersion: "3.0 (601)"),
            ])
            EngineGuard.noteUserChoice(.v3IOC)   // the user decided after the trip
            let restored = EngineGuard.takeRestorableTrips(currentVersion: "3.0 (601)")
            XCTAssertEqual(restored, [.v3PIIReport], "older-version trip comes back; the user's choice and a same-version trip stay")
            XCTAssertTrue(EngineGuard.takeRestorableTrips(currentVersion: "3.0 (601)").isEmpty, "only once")
            XCTAssertTrue(EngineGuard.takeRestorableTrips(currentVersion: "3.0 (602)").contains(.v3Bates),
                          "the 601 trip gets its chance in 602")
        }
    }

    // MARK: - M3: a fallback is recorded, audited and stated in the receipt

    private struct Boom: LocalizedError { var errorDescription: String? { "boom" } }

    func testFallback_isAuditedAndStatedInTheJobReceipt() async throws {
        let env = makeEnv(engineOn: false)
        try await env.store.insertBatch((0..<3).map { makeEmail($0, from: "a@a.com", tag: "fb") }, batchSize: 10)
        try await ScopeJobEnvironment.$current.withValue(env.job) {
            let (_, receipt) = try await ScopeJob.runIDs(
                key: "test.fallback", title: "Fallback", capability: .v3PIIReport,
                query: .all, batchSize: 10, initialState: 0
            ) { n, page in
                n += page.count
                _ = EngineGuard.fellBack(.v3PIIReport, error: Boom())   // a seam inside the job fell back
            }
            XCTAssertEqual(receipt.fallbacks, 1)
            XCTAssertTrue(receipt.coverageLine.contains("fell back"), receipt.coverageLine)
            XCTAssertTrue(receipt.documentFields.contains { $0.key == "Calls that fell back to the previous engine" && $0.value == "1" })
            XCTAssertTrue(env.job.auditLines().contains { $0.hasPrefix("Fell back to the previous engine") })
        }
        let message = ScopeJobEnvironment.$current.withValue(env.job) { EngineGuard.fellBack(.v3IOC, error: Boom()) }
        XCTAssertTrue(message.contains("boom") && message.contains("previous engine"), message)
    }

    // MARK: - Old-path bug fixes (§8 #1, #7)

    private final class StuckPlugin: MailinPlugin {
        let pluginID = "test.stuck", pluginName = "Stuck", pluginVersion = "1", pluginDescription = "never returns"
        func analyze(emails: [MailinPluginEmail]) async -> [MailinPluginFinding] {
            try? await Task.sleep(for: .seconds(600))   // far past the deadline; ends when cancelled
            return []
        }
        func export(emails: [MailinPluginEmail], format: String) async -> Data? { nil }
    }

    private final class ManyFindingsPlugin: MailinPlugin {
        let pluginID = "test.many", pluginName = "Many", pluginVersion = "1", pluginDescription = "150 findings"
        func analyze(emails: [MailinPluginEmail]) async -> [MailinPluginFinding] {
            (0..<150).map { MailinPluginFinding(title: "f\($0)", detail: "", severity: .info, relatedEmailIDs: []) }
        }
        func export(emails: [MailinPluginEmail], format: String) async -> Data? { nil }
    }

    /// #7: the deadline really ends the call (it used to wait for the plugin).
    func testPluginDeadline_endsTheCall_andFindingsAreNotCut() async {
        let manager = PluginManager()
        manager.sandboxTimeout = .milliseconds(300)
        manager.register(plugin: StuckPlugin())
        manager.register(plugin: ManyFindingsPlugin())
        let started = Date()
        let stuck = await manager.runPlugin(id: "test.stuck", emails: [])
        XCTAssertTrue(stuck.isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the deadline ended the call")
        let many = await manager.runPlugin(id: "test.many", emails: [])
        XCTAssertEqual(many.count, 150, "no silent cut at 100")
    }

    /// #1: the privilege log's columns are real text (`%s` with a Swift
    /// String printed garbage or crashed).
    func testPrivilegeLog_columnsCarryTheRealText() {
        let forensic = ForensicManager.shared
        let saved = forensic.evidenceTags
        defer { forensic.evidenceTags = saved }
        let email = makeEmail(1, from: "Ann Example <ann@a.com>", tag: "pl")
        forensic.evidenceTags = [email.id: .privileged]
        let log = forensic.exportPrivilegeLog(emails: [email])
        XCTAssertTrue(log.contains("Ann Example <ann@a.com>"), log)
        XCTAssertTrue(log.contains("S 1"), "subject column")
        XCTAssertTrue(log.contains("No.      Date"), "header padded to the same widths")
    }

    // MARK: - E4: collection fields on import receipts

    func testImportReceipt_collectionFieldsRoundTrip_andOldReceiptsStillDecode() throws {
        var receipt = ImportReceipt(startedAt: Date(), completedAt: Date())
        receipt.custodian = "Pat Examiner"
        receipt.collectingTool = "mailin 3.0 (603)"
        receipt.collectionSettings = ["Duplicates": "Message-ID", "Copies originals": "yes"]
        let data = try JSONEncoder().encode(receipt)
        let back = try JSONDecoder().decode(ImportReceipt.self, from: data)
        XCTAssertEqual(back.custodian, "Pat Examiner")
        XCTAssertEqual(back.collectingTool, "mailin 3.0 (603)")
        XCTAssertEqual(back.collectionSettings?["Duplicates"], "Message-ID")

        // A receipt written before 3.0 has none of these keys.
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "custodian"); json.removeValue(forKey: "collectingTool"); json.removeValue(forKey: "collectionSettings")
        let old = try JSONDecoder().decode(ImportReceipt.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.custodian)
        XCTAssertNil(old.collectionSettings)
    }

    // MARK: - E6: a redacted export carries no unredacted part

    func testRedactedExport_everyPartIsRedacted_noHTMLNoAttachmentBytes() {
        let ssn = "078-05-1120"
        let secretBytes = Data("attachment holds \(ssn)".utf8).base64EncodedString()
        let email = MBOXParser.RawEmail(
            headers: ["Subject": "Re: \(ssn)", "From": "a@a.com", "To": "b@b.com", "Cc": "c@c.com \(ssn)",
                      "Date": "Mon, 01 Jan 2024 00:00:00 +0000", "Message-ID": "<e6@test>"],
            rawSource: "raw \(ssn)", messageType: "email",
            attachments: [AttachmentMetadata(filename: "scan-\(ssn).pdf", mimeType: "application/pdf", size: 20, base64: secretBytes)],
            timestamp: "2024-01-01T00:00:00Z", domains: ["a.com"],
            plainBody: "Plain part \(ssn).",
            htmlBody: "<html><body><p title=\"\(ssn)\">HTML part \(ssn)</p><img src=\"cid:x\"></body></html>")
        let redacted = RedactionEngine.redactEmail(email, rules: RedactionEngine.defaultRules)
        let entry = RedactionEngine.exportEntry(redacted)
        XCTAssertFalse(entry.contains(ssn), "no part carries the unredacted value:\n\(entry)")
        XCTAssertFalse(entry.contains("<p") || entry.contains("<html") || entry.contains("title="), "no HTML part")
        XCTAssertFalse(entry.contains(secretBytes), "no attachment bytes")
        XCTAssertTrue(entry.contains("not included in this export"), "attachments are named, not carried")
        XCTAssertGreaterThanOrEqual(redacted.redactionCount, 5, "subject, Cc, plain, HTML attribute, file name")
    }

    // MARK: - S6: Safe Mode makes the archive read-only

    func testSafeModeReadOnly_blocksWrites_allowsReads_andLifts() async throws {
        let env = makeEnv(engineOn: false)
        try await env.store.insertBatch([makeEmail(0, from: "a@a.com", tag: "ro")], batchSize: 10)
        try await env.store.setReadOnly(true)
        do {
            try await env.store.insertBatch([makeEmail(1, from: "a@a.com", tag: "ro")], batchSize: 10)
            XCTFail("a write must fail while read-only")
        } catch {}
        let whileReadOnly = try await env.archive.count(query: .all)
        XCTAssertEqual(whileReadOnly, 1, "reads still work; nothing was written")
        try await env.store.setReadOnly(false)
        try await env.store.insertBatch([makeEmail(2, from: "a@a.com", tag: "ro")], batchSize: 10)
        let after = try await env.archive.count(query: .all)
        XCTAssertEqual(after, 2)
    }

    // MARK: - I4: a user's scope is never swapped for an archive sample

    func testAIContext_keepsTheUsersScope_replacesOnlyAWindow() async throws {
        let env = makeEnv(engineOn: false)
        try await env.store.insertBatch((0..<30).map { makeEmail($0, from: "a@a.com", tag: "ai") }, batchSize: 50)
        let all = try await env.archive.fullEmails(ids: try await ids(env))
        let one = [all[3]]
        await ScopeJobEnvironment.$current.withValue(env.job) {
            let kept = await AIContextSelector.context(for: one, isWindow: false, scopeName: "other", enabled: true)
            XCTAssertEqual(kept.emails.map(\.id), [all[3].id], "one email asked about stays one email")
            XCTAssertNil(kept.basedOn)

            let window = Array(all.prefix(5))
            let replaced = await AIContextSelector.context(for: window, isWindow: true, scopeName: "other", enabled: true)
            XCTAssertEqual(replaced.emails.count, 30, "a window is replaced by an even spread of the archive (all 30 here)")
            XCTAssertTrue(replaced.basedOn?.contains("30") ?? false, replaced.basedOn ?? "nil")

            let off = await AIContextSelector.context(for: window, isWindow: true, scopeName: "other", enabled: false)
            XCTAssertEqual(off.emails.count, 5, "engine off: the window as given")
        }
    }

    // MARK: - F1: batch size follows free memory

    func testAdaptiveBatch_followsFreeMemory_neverZero_neverAboveTheRequest() {
        let perBatchEmail = UInt64(AdaptiveBatch.bytesPerEmail) * 8
        XCTAssertEqual(AdaptiveBatch.size(requested: 200, available: 0), AdaptiveBatch.minimum, "under pressure: slower, not stopped")
        XCTAssertEqual(AdaptiveBatch.size(requested: 200, available: 64 * 1_073_741_824), 200, "plenty: the tool's own size")
        XCTAssertEqual(AdaptiveBatch.size(requested: 200, available: perBatchEmail * 80), 80, "in between: what fits")
        XCTAssertEqual(AdaptiveBatch.size(requested: 5, available: 0), 5, "never larger than the tool asked for")
        XCTAssertEqual(AdaptiveBatch.size(requested: 5, available: 64 * 1_073_741_824), 5)
        XCTAssertGreaterThan(AdaptiveBatch.availableBytes(), 0, "this machine reports free memory")
    }

    // MARK: - F4: review workspaces in the database

    func testWorkspaces_dualWrite_codingRows_andRecoveryFromTheDatabase() async throws {
        let env = makeEnv(engineOn: true)
        let a = UUID(), b = UUID()
        try await ScopeJobEnvironment.$current.withValue(env.job) {
            var snapshot = LegalReviewSnapshot()
            snapshot.privilege = [a: "attorneyClient", b: "notPrivileged"]
            snapshot.responsiveness = [a: "responsive"]
            XCTAssertNil(ReviewWorkspaceStore.save(snapshot, name: LegalReviewSnapshot.fileName))
            await ReviewWorkspaceStore.flushDatabaseMirror()

            let privilege = try await env.store.reviewCoding(workspace: "legal-review", field: "privilege")
            XCTAssertEqual(privilege, snapshot.privilege, "per-email coding is queryable in the database")

            // A changed call replaces the row; a removed one is gone.
            snapshot.privilege = [a: "workProduct"]
            ReviewWorkspaceStore.save(snapshot, name: LegalReviewSnapshot.fileName)
            await ReviewWorkspaceStore.flushDatabaseMirror()
            let after = try await env.store.reviewCoding(workspace: "legal-review", field: "privilege")
            XCTAssertEqual(after, [a: "workProduct"])

            // The file is lost: the database copy brings the workspace back.
            try FileManager.default.removeItem(at: ReviewWorkspaceStore.url(for: LegalReviewSnapshot.fileName))
            XCTAssertNil(ReviewWorkspaceStore.load(LegalReviewSnapshot.self, name: LegalReviewSnapshot.fileName))
            let recovered = await ReviewWorkspaceStore.loadFromDatabase(LegalReviewSnapshot.self, name: LegalReviewSnapshot.fileName)
            XCTAssertEqual(recovered, snapshot)
        }
    }

    // MARK: - F5: the fingerprint tree is the verification path

    /// A held email whose stored bytes change behind its back fails Verify,
    /// even though its evidence seal (computed from the parsed fields the app
    /// keeps) still matches — the tree checks the stored original.
    func testVerifySeals_withTheTree_catchesAChangedOriginal() async throws {
        let env = makeEnv(engineOn: false)
        try await env.store.insertBatch((0..<3).map { makeEmail($0, from: "a@a.com", tag: "f5") }, batchSize: 10)
        let all = try await env.archive.fullEmails(ids: try await ids(env))
        try await ScopeJobEnvironment.$current.withValue(env.job) {
            env.manager.placeLegalHoldBatched(all)
            let before = try await CustodianEngine.verifySeals(group: nil, useFingerprints: true)
            XCTAssertEqual(before.intact, 3)
            XCTAssertEqual(before.broken, 0)

            // Change one stored original through a second connection.
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(env.store.storeDirectory.appendingPathComponent("emails.db").path, &db), SQLITE_OK)
            defer { sqlite3_close(db) }
            XCTAssertEqual(sqlite3_exec(db, "UPDATE email_bodies SET raw = X'00' WHERE id = '\(all[1].id.uuidString)';", nil, nil, nil), SQLITE_OK)

            let after = try await CustodianEngine.verifySeals(group: nil, useFingerprints: true)
            XCTAssertEqual(after.treeBroken, 1, "the tree pinpoints the changed original")
            XCTAssertEqual(after.broken, 1)
            XCTAssertEqual(after.intact, 2)
            let withoutTree = try await CustodianEngine.verifySeals(group: nil, useFingerprints: false)
            XCTAssertEqual(withoutTree.broken, 0, "the old seal alone cannot see a change to the stored original")
        }
    }

    // MARK: - F6: named entities in the analysis index

    func testEntities_extractedStoredCountedAndDeletedWithTheEmail() async throws {
        let found = FeatureExtractor.entities(in: "Yesterday Tim Cook met Satya Nadella at Microsoft in Seattle to discuss the plan.")
        XCTAssertTrue(found.contains { $0.kind == "person" }, "people are found: \(found)")
        XCTAssertTrue(found.contains { $0.kind == "place" || $0.kind == "organization" }, "places/organisations are found: \(found)")

        let env = makeEnv(engineOn: false)
        try await env.store.insertBatch((0..<3).map { makeEmail($0, from: "a@a.com", tag: "ent") }, batchSize: 10)
        let all = try await ids(env)
        var records: [SQLiteEmailStore.FeatureRecord] = []
        for (i, id) in all.enumerated() {
            var r = SQLiteEmailStore.FeatureRecord(emailID: id, version: FeatureExtractor.version)
            r.entities = [(kind: "person", value: "Pat Lee")] + (i == 0 ? [(kind: "person", value: "Sam Roe")] : [])
            records.append(r)
        }
        try await env.store.featuresUpsert(records)
        let top = try await env.store.entityTop(kind: "person", limit: 10)
        XCTAssertEqual(top.distinct, 2)
        XCTAssertEqual(top.rows.first?.value, "Pat Lee")
        XCTAssertEqual(top.rows.first?.emails, 3, "counted across the whole archive")

        try await env.store.delete(ids: [all[0]])
        let after = try await env.store.entityTop(kind: "person", limit: 10)
        XCTAssertEqual(after.distinct, 1, "a deleted email's entities go with it")
        XCTAssertEqual(after.rows.first?.emails, 2)
    }

    // MARK: - E2: evidence records travel with case bundles

    func testEvidenceRecordForIDs_provesExactlyThoseEmails_andBundlesStillDecodeWithout() async throws {
        let env = makeEnv(engineOn: false)
        try await env.store.insertBatch((0..<6).map { makeEmail($0 * 20, from: "a@a.com", tag: "e2") }, batchSize: 10)
        let all = try await ids(env)
        let chosen = Set(all.prefix(2))
        try await ScopeJobEnvironment.$current.withValue(env.job) {
            let record = try await EvidenceRecordExporter.record(for: chosen)
            XCTAssertEqual(record.written, 2)
            let lines = record.text.split(separator: "\n").map { Data($0.utf8) }
            let header = try JSONDecoder().decode(EvidenceRecordExporter.Header.self, from: lines[0])
            let roots = Dictionary(uniqueKeysWithValues: header.buckets.map { (Int($0["month"]!)!, $0["root"]!) })
            let entries = try lines.dropFirst().map { try JSONDecoder().decode(EvidenceRecordExporter.Line.self, from: $0) }
            XCTAssertEqual(Set(entries.compactMap { UUID(uuidString: $0.id) }), chosen)
            for e in entries {
                let month = EvidenceRecordExporter.fold(e.leaf, e.bucketPath)
                XCTAssertEqual(month, roots[e.month])
                XCTAssertEqual(EvidenceRecordExporter.fold(month, e.rootPath), header.archiveRoot)
            }
        }
        // A bundle written before 3.0 has no `evidenceRecord` key.
        let old = #"{"formatVersion":2,"caseTitle":"t","exportedBy":"x","exportedAt":"2026-01-01T00:00:00Z","note":"","emails":[],"achMatrices":[],"factMatrices":[],"actionRegisters":[],"evidenceDesks":[],"reasoningCases":[]}"#
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        XCTAssertNil(try dec.decode(CaseBundle.self, from: Data(old.utf8)).evidenceRecord)
    }

    // MARK: - I1: the timeline tool counts the whole archive

    func testEmailTimeline_countsEveryMonthExactly_andFoldsLongSpansIntoYears() async throws {
        guard #available(macOS 26, iOS 26, *) else { throw XCTSkip("FoundationModels needs OS 26") }
        let env = makeEnv(engineOn: false)
        try await env.store.insertBatch((0..<7).map { makeEmail($0, from: "a@a.com", tag: "i1") }, batchSize: 10)
        try await ScopeJobEnvironment.$current.withValue(env.job) {
            let months = try await EmailTimelineTool.monthlyCounts(.all)
            XCTAssertEqual(months.reduce(0) { $0 + $1.count }, 7, "every email is counted once")
            var bySender = EmailQuery.all
            bySender.sender = "nobody@x.com"
            let none = try await EmailTimelineTool.monthlyCounts(bySender)
            XCTAssertTrue(none.isEmpty)
        }
        let long = (0..<40).map { (month: String(format: "%04d-%02d", 2020 + $0 / 12, $0 % 12 + 1), count: 1) }
        let text = EmailTimelineTool.render(long, scope: "all")
        XCTAssertTrue(text.hasPrefix("40 emails"), "the total stays exact: \(text)")
        XCTAssertTrue(text.contains("2020: 12") && text.contains("2023: 4"), "long spans are listed per year: \(text)")
    }

    // MARK: - I2: a full context window is recognised

    func testContextOverflow_isRecognised_otherErrorsAreNot() throws {
        guard #available(macOS 26, iOS 26, *) else { throw XCTSkip("FoundationModels needs OS 26") }
        let overflow = LanguageModelSession.GenerationError.exceededContextWindowSize(.init(debugDescription: "full"))
        XCTAssertTrue(LanguageModelSession.isContextOverflow(overflow))
        XCTAssertFalse(LanguageModelSession.isContextOverflow(CancellationError()))
        let fresh = LanguageModelSession()
        XCTAssertFalse(fresh.condenseTranscriptForRetry(), "an empty transcript has nothing to condense")
    }

    // MARK: - A17: the AI Digest covers the whole period

    /// The previous digest read the newest 1,000 emails and filtered them to
    /// the period in memory; the whole-period digest counts every email in
    /// it, says how much of each list it shows, and checks new contacts
    /// against the archive before the period.
    func testDigest_wholePeriod_exactTotals_listsSayNofM_newContactsCheckedBeforeThePeriod() async throws {
        let env = makeEnv(engineOn: false)
        try await env.store.insertBatch([makeEmail(0, from: "old@x.com", tag: "before")], batchSize: 10)
        try await env.store.insertBatch((10..<1_210).map { makeEmail($0, from: $0 % 2 == 0 ? "new@y.com" : "old@x.com", tag: "a17") },
                                        batchSize: 500)
        let start = Date(timeIntervalSince1970: 1_704_067_200 + 10 * 86_400)
        let end = Date(timeIntervalSince1970: 1_704_067_200 + 2_000 * 86_400)
        try await ScopeJobEnvironment.$current.withValue(env.job) {
            let q = DigestEngine.periodQuery(.all, period: .custom, customStart: start, customEnd: end)
            let sections = try await DigestEngine.digest(query: q, narrate: false)
            let lines = sections.flatMap { $0.items.map(\.headline) }
            XCTAssertTrue(lines.contains("Total: 1200 emails"), "every email of the period is counted: \(lines.prefix(3))")
            XCTAssertTrue(lines.contains(String(localized: "\(5) of \(1_200) conversations shown")), "lists say N of M: \(lines)")
            let contacts = sections.first { $0.title == String(localized: "New Contacts") }
            XCTAssertEqual(contacts?.items.first?.headline, "new@y.com", "only the address with no earlier email is new")
            XCTAssertEqual(contacts?.items.first?.emailIDs.count, 600)
            XCTAssertFalse(contacts?.items.contains { $0.headline == "old@x.com" } ?? true)
        }
    }

    // MARK: - A15: graph paths are found however far apart

    func testKnowledgeGraph_findsAPathPastFiveHundredNodes() {
        let graph = KnowledgeGraph()
        for i in 0...700 { _ = graph.addNode(KGNode(id: "p\(i)", type: .person, label: "P\(i)")) }
        for i in 0..<700 { _ = graph.addEdge(KGEdge(sourceID: "p\(i)", targetID: "p\(i + 1)", type: .communicatesWith)) }
        let path = graph.shortestPath(from: "p0", to: "p700")
        XCTAssertEqual(path?.count, 701, "the search used to stop after 500 nodes and report no path")
        XCTAssertEqual(path?.first, "p0")
        XCTAssertEqual(path?.last, "p700")
        XCTAssertEqual(graph.shortestPath(from: "p3", to: "p5"), ["p3", "p4", "p5"])
    }

    // MARK: - Triage: a re-query after verdicts sees them

    /// The triage queue reloads its next part once the shown part is done;
    /// it waits for the verdict writes first so decided emails never return.
    func testReviewState_waitForWrites_thenAQuerySeesEveryWrite() async throws {
        let env = makeEnv(engineOn: false)
        try await env.store.insertBatch((0..<6).map { makeEmail($0, from: "a@a.com", tag: "tq") }, batchSize: 10)
        let all = try await ids(env)
        ReviewStateService.testStoreOverride = env.store
        defer { ReviewStateService.testStoreOverride = nil }
        let review = ReviewStateService()
        review.addTag("pending", to: all)
        review.removeTag("pending", from: Array(all.prefix(4)))
        await review.waitForWrites()
        var q = EmailQuery.all
        q.userTag = "pending"
        let left = try await env.archive.count(query: q)
        XCTAssertEqual(left, 2, "every write landed before the re-query")
    }

    // MARK: - Enterprise licensing

    private func licenseKey(_ payload: [String: Any], signer: Curve25519.Signing.PrivateKey) throws -> String {
        func b64(_ d: Data) -> String {
            d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let json = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return "MAILIN1.\(b64(json)).\(b64(try signer.signature(for: json)))"
    }

    /// Valid → Professional; 30 days of grace after expiry; then Personal —
    /// never less (the archive stays readable). Tampered or foreign keys fail.
    func testEnterpriseLicense_validGraceExpiredInvalid() throws {
        let signer = Curve25519.Signing.PrivateKey()
        let pub = signer.publicKey.rawRepresentation.base64EncodedString()
        let base: [String: Any] = ["v": 1, "org": "Acme LLP", "seats": 25, "issued": "2026-01-01", "id": "T1"]
        var dated = base; dated["expires"] = "2026-12-31"
        let key = try licenseKey(dated, signer: signer)
        let f = ISO8601DateFormatter()
        func at(_ s: String) -> EnterpriseLicense { EnterpriseLicense.evaluate(key: key, now: f.date(from: s)!, publicKey: pub) }

        XCTAssertEqual(at("2026-12-31T23:00:00Z").tier, .professional, "valid through the expiry day")
        guard case .grace(_, let left) = at("2027-01-10T00:00:00Z").status else { return XCTFail("grace after expiry") }
        XCTAssertEqual(left, 21)
        XCTAssertEqual(at("2027-01-10T00:00:00Z").tier, .professional)
        guard case .expired = at("2027-02-15T00:00:00Z").status else { return XCTFail("expired after grace") }
        XCTAssertEqual(at("2027-02-15T00:00:00Z").tier, .personal, "never below Personal: the archive stays usable")

        let perpetual = try licenseKey(base, signer: signer)
        XCTAssertEqual(EnterpriseLicense.evaluate(key: perpetual, now: f.date(from: "2040-01-01T00:00:00Z")!, publicKey: pub).tier, .professional)

        var parts = key.split(separator: ".").map(String.init)
        parts[1] = parts[1].replacingOccurrences(of: "A", with: "B")
        guard case .invalid = EnterpriseLicense.evaluate(key: parts.joined(separator: "."), now: Date(), publicKey: pub).status else { return XCTFail("tampered key") }
        let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        guard case .invalid = EnterpriseLicense.evaluate(key: key, now: Date(), publicKey: other).status else { return XCTFail("foreign key") }
        guard case .missing = EnterpriseLicense.evaluate(key: "  ", now: Date()).status else { return XCTFail("empty") }
        guard case .invalid = EnterpriseLicense.evaluate(key: "hello", now: Date()).status else { return XCTFail("garbage") }
    }

    /// Setting the clock back does not revive an expired key: the latest
    /// date seen is kept and used whenever the clock reads earlier.
    func testEnterpriseLicense_clockCannotRunBackwards() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "license-\(UUID().uuidString)"))
        let future = Date().addingTimeInterval(400 * 86_400).timeIntervalSince1970
        defaults.set(future, forKey: "enterprise.licenseClockHighWater")
        _ = EnterpriseLicense.current(defaults: defaults, managedKey: nil)
        XCTAssertEqual(defaults.double(forKey: "enterprise.licenseClockHighWater"), future, "the high-water mark never moves back")
    }

    /// The embedded public key is a real Ed25519 key.
    func testEnterpriseLicense_embeddedPublicKeyIsUsable() throws {
        let data = try XCTUnwrap(Data(base64Encoded: EnterpriseLicense.publicKeyBase64))
        XCTAssertNoThrow(try Curve25519.Signing.PublicKey(rawRepresentation: data))
    }

    // MARK: - X1: one scope rule for every host

    /// Every host opens a tool on the current filter; the whole archive is
    /// the user's explicit choice; no filter means the whole archive.
    func testToolScope_filterByDefault_wholeArchiveOnRequest() {
        var filter = EmailQuery.all
        filter.sender = "alice"
        XCTAssertEqual(ToolScope.query(filter: filter, wholeArchive: false), filter)
        XCTAssertEqual(ToolScope.query(filter: filter, wholeArchive: true), .all)
        XCTAssertEqual(ToolScope.query(filter: .all, wholeArchive: false), .all)
    }

    /// The Professional page and the Archive sidebar build each Professional
    /// tool through the same view, so they cannot drift apart again.
    func testProfessionalTools_haveOneConstruction() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let content = try String(contentsOf: root.appendingPathComponent("maxmailin/ContentView.swift"), encoding: .utf8)
        for tool in ["BatesConfigView(", "ChainOfCustodyView(", "EDiscoveryWorkflowView(", "RedactionConfigView(",
                     "ReviewBatchPanelView(", "InvestigationReportConfigSheet(", "EvidenceDesksStudioView("] {
            let start = try XCTUnwrap(content.range(of: "private func hubDestinationContent"))
            let end = try XCTUnwrap(content.range(of: "case .settings:", range: start.upperBound..<content.endIndex))
            XCTAssertFalse(content[start.lowerBound..<end.lowerBound].contains(tool),
                           "\(tool) is built in the sidebar switch again; build it in ProfessionalDestinationView")
        }
    }

    // MARK: - M5: TestFlight builds run the 3.0 engines

    func testBetaBuilds_turnPreviewEnginesOn_appStoreBuildsDoNot() {
        XCTAssertTrue(Capability.defaultOn(maturity: .preview, isEngine: true, beta: true), "TestFlight runs the 3.0 engines")
        XCTAssertFalse(Capability.defaultOn(maturity: .preview, isEngine: true, beta: false), "the App Store keeps them off until promoted")
        XCTAssertFalse(Capability.defaultOn(maturity: .preview, isEngine: false, beta: true), "only 3.0 engines, not other previews")
        XCTAssertFalse(Capability.defaultOn(maturity: .experimental, isEngine: true, beta: true))
        XCTAssertTrue(Capability.defaultOn(maturity: .stable, isEngine: false, beta: false))
        XCTAssertFalse(BetaEnvironment.isBeta, "tests always see the shipping defaults")
    }

    // MARK: - List window memory budget

    /// A window of large messages keeps bodies and headers but not every raw
    /// source: the total stays within the budget and anything over the
    /// blob-tier size is dropped, with its true size kept.
    func testListWindow_rawSourcesStayWithinTheBudget() {
        let big = String(repeating: "A", count: 3_000)
        let emails = (0..<10).map { i -> MBOXParser.RawEmail in
            var e = makeEmail(i, from: "a@a.com", tag: "wb")
            e.rawSource = i == 0 ? String(repeating: "B", count: 20_000) : big
            return e
        }
        let r = ParsedEmailListViewModel.applyMemoryBudget(emails, budget: 10_000, large: 10_000)
        let kept = r.emails.reduce(0) { $0 + $1.rawSource.utf8.count }
        XCTAssertLessThanOrEqual(kept, 10_000, "raw sources in memory stay within the budget")
        XCTAssertTrue(r.emails[0].rawSource.isEmpty, "a message over the size threshold is never held")
        XCTAssertEqual(r.deferred[emails[0].id], 20_000, "its true size is kept for the Large filter")
        XCTAssertEqual(r.emails.count, 10, "no email leaves the window")
        XCTAssertEqual(r.emails.map(\.plainBody), emails.map(\.plainBody), "bodies stay")
        XCTAssertEqual(r.deferred.count, 10 - 3, "three 3,000-byte sources fit in 10,000")
    }
}
