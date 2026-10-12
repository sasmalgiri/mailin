@testable import ArchiveCore
//
//  V3FoundationTests.swift
//  maxmailinTests
//
//  3.0 test pass: the foundations every whole-archive tool stands on —
//  scope jobs (resume, receipts, prove), schema v19 legal state (holds block
//  delete, seals are set once), the fingerprint tree (reproducible root,
//  pinpointed tampering), search exclusions, and Bates numbers that never
//  change. Every test runs on a disposable store bound through
//  `ScopeJobEnvironment`; production data and files are never touched.
//

import XCTest
import SQLite3
import CryptoKit
@testable import maxmailin

@MainActor
final class V3FoundationTests: XCTestCase {

    // MARK: - Fixtures

    private struct Env {
        let root: URL
        let store: SQLiteEmailStore
        let archive: ArchiveDataService
        var job: ScopeJobEnvironment { ScopeJobEnvironment(archive: archive, store: store, root: root) }
    }

    private func makeEnv() -> Env {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("v3found-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts", isDirectory: true))
        return Env(root: root, store: store,
                   archive: ArchiveDataService(repository: EmailStoreRepository(store: store, fts: fts)))
    }

    /// Email `i` is dated `i` days after 2024-01-01 (distinct, ascending).
    private func makeEmail(_ i: Int, from: String = "alice@example.com", subject: String? = nil,
                           tag: String = "fx") -> MBOXParser.RawEmail {
        let date = Date(timeIntervalSince1970: 1_704_067_200 + Double(i) * 86_400)
        let rfc = DateFormatter()
        rfc.locale = Locale(identifier: "en_US_POSIX")
        rfc.timeZone = TimeZone(identifier: "UTC")
        rfc.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let mid = "<\(tag)-\(i)@test>"
        let subj = subject ?? "Subject \(i)"
        let body = "body of message \(i)"
        return MBOXParser.RawEmail(
            headers: ["Message-ID": mid, "Subject": subj, "From": from, "To": "bob@example.com",
                      "Date": rfc.string(from: date)],
            rawSource: "Message-ID: \(mid)\nSubject: \(subj)\nFrom: \(from)\n\n\(body)",
            messageType: "email", attachments: [],
            timestamp: ISO8601DateFormatter().string(from: date),
            domains: [String(from.split(separator: "@").last ?? "")],
            plainBody: body, htmlBody: "")
    }

    /// Every id in the store, oldest first.
    private func idsOldestFirst(_ env: Env, query: EmailQuery = .all) async throws -> [UUID] {
        var q = query
        q.sort = .dateAsc
        var out: [UUID] = []
        for try await page in env.archive.streamSummaries(query: q, batchSize: 1_000) { out += page.map(\.id) }
        return out
    }

    private struct Interrupted: Error {}

    // MARK: - Scope jobs (§3-F1/F2/E1)

    /// A job stopped part-way resumes from its checkpoint: every email is
    /// processed exactly once across both runs, and the receipt is the same
    /// as an uninterrupted run's (same count, same fingerprint), marked resumed.
    func testScopeJob_resumesAfterInterruption_eachEmailOnce_sameFingerprint() async throws {
        let env = makeEnv()
        try await env.store.insertBatch((0..<23).map { makeEmail($0) }, batchSize: 100)

        try await ScopeJobEnvironment.$current.withValue(env.job) {
            // Reference: one uninterrupted run.
            let reference = try await ScopeJob.run(
                key: "test.reference", title: "Reference", capability: .v3ScopeEngine,
                query: .all, batchSize: 5, initialState: 0
            ) { count, batch in count += batch.count }
            XCTAssertEqual(reference.state, 23)
            XCTAssertEqual(reference.receipt.processed, 23)
            XCTAssertFalse(reference.receipt.resumed)

            // Interrupted on the third batch.
            var seen: [UUID] = []
            var batches = 0
            do {
                _ = try await ScopeJob.run(
                    key: "test.resume", title: "Resume", capability: .v3ScopeEngine,
                    query: .all, batchSize: 5, initialState: 0
                ) { count, batch in
                    batches += 1
                    if batches == 3 { throw Interrupted() }
                    seen += batch.map(\.id)
                    count += batch.count
                }
                XCTFail("the step threw; the run must not finish")
            } catch is Interrupted {}
            XCTAssertEqual(seen.count, 10, "two batches done before the stop")
            XCTAssertFalse(ScopeJobCheckpointStore.pendingKeys().isEmpty, "the checkpoint survives the stop")

            // Second run picks up where the first stopped.
            let resumed = try await ScopeJob.run(
                key: "test.resume", title: "Resume", capability: .v3ScopeEngine,
                query: .all, batchSize: 5, initialState: 0
            ) { count, batch in
                seen += batch.map(\.id)
                count += batch.count
            }
            XCTAssertTrue(resumed.receipt.resumed)
            XCTAssertEqual(resumed.state, 23, "the checkpointed state carries the first run's count")
            XCTAssertEqual(seen.count, 23)
            XCTAssertEqual(Set(seen).count, 23, "no email processed twice")
            XCTAssertEqual(resumed.receipt.processed, 23)
            XCTAssertEqual(resumed.receipt.fingerprint, reference.receipt.fingerprint,
                           "a resumed run proves the same email set as an uninterrupted one")
            XCTAssertFalse(ScopeJobCheckpointStore.pendingKeys().contains("test.resume"),
                           "a finished run removes its checkpoint")
        }
    }

    /// The receipt records exactly what was covered, and "Re-run and prove"
    /// matches an unchanged archive and reports a changed one.
    func testScopeJob_receiptProves_thenDetectsAChangedArchive() async throws {
        let env = makeEnv()
        try await env.store.insertBatch((0..<12).map { makeEmail($0) }, batchSize: 100)

        try await ScopeJobEnvironment.$current.withValue(env.job) {
            let (_, receipt) = try await ScopeJob.runIDs(
                key: "test.prove", title: "Prove", capability: .v3ScopeEngine,
                query: .all, batchSize: 4, initialState: 0
            ) { n, page in n += page.count }
            XCTAssertEqual(receipt.totalInScope, 12)
            XCTAssertEqual(receipt.processed, 12)
            XCTAssertFalse(receipt.cancelled)
            XCTAssertNotNil(receipt.queryJSON)

            let doc = CapturedDocument(title: receipt.title, sections: [.init(name: "Job receipt", fields: receipt.documentFields)])
            let payload = try XCTUnwrap(String(data: try JSONEncoder().encode(doc), encoding: .utf8))

            let proved = await ScopeJob.prove(documentPayload: payload)
            XCTAssertTrue(proved?.hasPrefix("Proved") ?? false, "unchanged archive proves: \(proved ?? "nil")")

            try await env.store.insertBatch([makeEmail(99, tag: "late")], batchSize: 10)
            let changed = await ScopeJob.prove(documentPayload: payload)
            XCTAssertTrue(changed?.hasPrefix("Not the same set") ?? false, "a changed archive is reported: \(changed ?? "nil")")
        }
    }

    /// The fingerprint ignores order, so batching and resume cannot change it.
    func testEmailSetFingerprint_isOrderIndependent() {
        let ids = (0..<50).map { _ in UUID() }
        var a = EmailSetFingerprint(), b = EmailSetFingerprint()
        ids.forEach { a.add($0) }
        ids.reversed().forEach { b.add($0) }
        XCTAssertEqual(a.hex, b.hex)
        var c = EmailSetFingerprint()
        ids.dropLast().forEach { c.add($0) }
        XCTAssertNotEqual(a.hex, c.hex)
    }

    // MARK: - Legal state in the database (§3-F4)

    /// An email under a legal hold cannot be deleted by any caller; the
    /// others in the same request are.
    func testLegalHold_blocksDeleteOfHeldEmailsOnly() async throws {
        let env = makeEnv()
        try await env.store.insertBatch((0..<4).map { makeEmail($0) }, batchSize: 10)
        let ids = try await idsOldestFirst(env)
        let v1 = try await env.store.legalHoldsAdd([ids[0], ids[1]], matter: "M-1")
        XCTAssertEqual(v1, 2)
        let v2 = try await env.store.legalHoldsAdd([ids[0]], matter: "M-1")
        XCTAssertEqual(v2, 0, "a hold is placed once")

        // Engine off: the files are the truth, the table does not block (M6).
        let offHeld = try await env.store.deleteReportingHeld(ids: [ids[3]])
        XCTAssertEqual(offHeld, [])
        await env.store.setEnforcesDatabaseLegalHolds(true)

        try await env.store.delete(ids: Set(ids))
        let left = try await idsOldestFirst(env)
        XCTAssertEqual(Set(left), Set([ids[0], ids[1]]), "held emails survive; unheld ones are deleted")

        let v3 = try await env.store.legalHoldsRemove([ids[0]])
        XCTAssertEqual(v3, 1)
        try await env.store.delete(ids: [ids[0]])
        let v4 = try await idsOldestFirst(env)
        XCTAssertEqual(v4, [ids[1]], "a released hold no longer protects")
    }

    /// A seal is recorded once and never replaced — a re-hold must not hide a
    /// modification made in between.
    func testEvidenceSeal_isSetOnceNeverOverwritten() async throws {
        let env = makeEnv()
        try await env.store.insertBatch([makeEmail(0)], batchSize: 10)
        let all = try await idsOldestFirst(env)
        let id = try XCTUnwrap(all.first)
        let v5 = try await env.store.sealsSetOnce([id: "first"])
        XCTAssertEqual(v5, 1)
        let v6 = try await env.store.sealsSetOnce([id: "second"])
        XCTAssertEqual(v6, 0)
        let v7 = try await env.store.seals(for: [id])[id]
        XCTAssertEqual(v7, "first")
    }

    // MARK: - Fingerprint tree (§3-F5)

    private func buildTree(_ store: SQLiteEmailStore) async throws -> SQLiteEmailStore.FingerprintTree {
        while try await store.fingerprintBuildMissing(limit: 7) > 0 {}
        try await store.fingerprintRefreshBuckets()
        return try await store.fingerprintTree()
    }

    /// The same mail gives the same root in two separate archives (leaves are
    /// content hashes in a fixed order), and every email has a leaf.
    func testFingerprintTree_rootIsReproducible() async throws {
        let a = makeEnv(), b = makeEnv()
        let mail = (0..<40).map { makeEmail($0 * 5) }   // spans several month buckets
        try await a.store.insertBatch(mail, batchSize: 100)
        try await b.store.insertBatch((0..<40).map { makeEmail($0 * 5) }, batchSize: 100)   // fresh ids, same content
        let ta = try await buildTree(a.store), tb = try await buildTree(b.store)
        XCTAssertEqual(ta.leaves, 40)
        XCTAssertGreaterThan(ta.buckets.count, 1)
        let v8 = try await a.store.fingerprintMissingCount()
        XCTAssertEqual(v8, 0)
        XCTAssertEqual(ta.root, tb.root, "same content ⇒ same archive root")
    }

    /// Changing one stored message is pinpointed to exactly that email, and a
    /// deletion changes the root.
    func testFingerprintVerify_pinpointsTheChangedEmail() async throws {
        let env = makeEnv()
        try await env.store.insertBatch((0..<10).map { makeEmail($0) }, batchSize: 100)
        let before = try await buildTree(env.store)
        let ids = try await idsOldestFirst(env)
        let v9 = try await env.store.fingerprintVerify(ids: ids)
        XCTAssertEqual(v9, [], "nothing changed yet")

        // Tamper through a second connection, as an outside edit would.
        var db: OpaquePointer?
        let path = env.store.storeDirectory.appendingPathComponent("emails.db").path
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = "UPDATE email_bodies SET raw = X'6576696C', plain = X'6576696C' WHERE id = '\(ids[3].uuidString)';"
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)

        let v10 = try await env.store.fingerprintVerify(ids: ids)
        XCTAssertEqual(v10, [.changed(ids[3])])

        try await env.store.delete(ids: [ids[0]])
        try await env.store.fingerprintRefreshBuckets()
        let after = try await env.store.fingerprintTree()
        XCTAssertEqual(after.leaves, 9)
        XCTAssertNotEqual(after.root, before.root)
    }

    // MARK: - Search exclusions (§3-Q4)

    func testExclusions_compileAndFilterTheWholeArchive() async throws {
        let env = makeEnv()
        try await env.store.insertBatch(
            (0..<6).map { makeEmail($0, from: "alice@example.com", subject: "Budget \($0)") }
            + (6..<10).map { makeEmail($0, from: "bob@other.org", subject: "Lunch \($0)") },
            batchSize: 100)

        let noAlice = ArchiveQueryCompiler.compile("-from:alice", exclusions: true)
        XCTAssertEqual(noAlice.exclusions, [EmailExclusion(field: .sender, value: "alice")])
        XCTAssertNil(noAlice.sender, "an exclusion never becomes an include")
        let v11 = try await env.archive.count(query: noAlice)
        XCTAssertEqual(v11, 4)

        let notBudget = ArchiveQueryCompiler.compile("NOT subject:budget", exclusions: true)
        let v12 = try await env.archive.count(query: notBudget)
        XCTAssertEqual(v12, 4)

        let notOther = ArchiveQueryCompiler.compile("-domain:other.org", exclusions: true)
        let v13 = try await env.archive.count(query: notOther)
        XCTAssertEqual(v13, 6)

        // Combined with an include filter.
        let combined = ArchiveQueryCompiler.compile("from:alice -subject:\"Budget 1\"", exclusions: true)
        let v14 = try await env.archive.count(query: combined)
        XCTAssertEqual(v14, 5)

        // Off: the pre-3.0 parse, no exclusions.
        XCTAssertNil(ArchiveQueryCompiler.compile("-from:alice", exclusions: false).exclusions)
    }

    /// A negated operator that has no exclusion form must not turn into the
    /// matching INCLUDE filter (it used to: "-source:x" kept only source x).
    func testExclusions_unsupportedNegationIsNeverAnInclude() {
        let q = ArchiveQueryCompiler.compile("-sort:oldest", exclusions: true)
        XCTAssertEqual(q.sort, .dateDesc)
        XCTAssertEqual(q.text, "-sort:oldest", "kept as literal text, like any unrecognised operator")
        let n = ArchiveQueryCompiler.compile("NOT before:someday", exclusions: true)
        XCTAssertNil(n.beforeDate)
        XCTAssertNil(n.exclusions, "a date that does not parse is never a bound")
    }

    /// §3-Q4 "negation for every filter": source, type, file name, evidence,
    /// pinned and both date bounds negate too — each the exact complement.
    func testExclusions_everyFilterNegates_overTheWholeArchive() async throws {
        let env = makeEnv()
        try await env.store.insertBatch((0..<10).map { makeEmail($0) }, batchSize: 100)   // 2024-01-01 … 01-10
        func count(_ s: String) async throws -> Int {
            try await env.archive.count(query: ArchiveQueryCompiler.compile(s, exclusions: true))
        }
        let v1 = try await count("-before:2024-01-04")
        XCTAssertEqual(v1, 7, "NOT before X = on or after X")
        let v2 = try await count("NOT after:2024-01-04")
        XCTAssertEqual(v2, 3, "NOT after X = before X")
        let v3 = try await count("after:2024-01-02 -after:2024-01-05")
        XCTAssertEqual(v3, 3, "an include and an excluded bound combine")
        let v4 = try await count("-type:email")
        XCTAssertEqual(v4, 0)
        let v5 = try await count("-filename:pdf")
        XCTAssertEqual(v5, 10, "no email has a pdf, so none is left out (the include would give 0)")
        let v6 = try await count("-source:nothing.mbox")
        XCTAssertEqual(v6, 10)
        let v7 = try await count("-evidence:Privileged")
        XCTAssertEqual(v7, 10)
        let v8 = try await count("-is:pinned")
        XCTAssertEqual(v8, 10)
        let q = ArchiveQueryCompiler.compile("-source:a.mbox -type:sent", exclusions: true)
        XCTAssertNil(q.sourceFileName)
        XCTAssertNil(q.messageType)
        XCTAssertEqual(q.exclusions?.map(\.field), [.source, .type])
        let described = ScopeJob.describe(ArchiveQueryCompiler.compile("-before:2024-01-04 -type:sent", exclusions: true))
        XCTAssertTrue(described.contains("not before 2024-01-04") && described.contains("not type sent"),
                      "receipts state what was left out: \(described)")
    }

    /// §3-S1 external location: snapshots go to the chosen folder when it is
    /// reachable, are listed from both places, and fall back beside the
    /// store when the folder is gone (a detached disk never costs a snapshot).
    func testSnapshots_externalFolder_usedWhenReachable_fallsBackWhenDetached() async throws {
        let env = makeEnv()
        try await env.store.insertBatch((0..<3).map { makeEmail($0) }, batchSize: 100)
        let external = env.root.appendingPathComponent("BackupDisk", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        ArchiveSnapshotPolicy.externalDirectory = external
        defer { ArchiveSnapshotPolicy.externalDirectory = nil }

        let outside = try await env.store.snapshot(reason: "manual")
        XCTAssertTrue(outside.url.path.hasPrefix(external.path), "written to the chosen folder: \(outside.url.path)")
        XCTAssertTrue(env.store.snapshots().contains { $0.url == outside.url }, "listed with the others")
        XCTAssertEqual(env.store.snapshots().first { $0.url == outside.url }?.reason, "manual",
                       "a manual snapshot is never taken for a rolling one (the schedule prunes those)")
        _ = try await env.store.snapshot(reason: "scheduled")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.url.path), "the schedule keeps manual snapshots")

        try FileManager.default.removeItem(at: external)   // the disk is detached
        let beside = try await env.store.snapshot(reason: "manual")
        XCTAssertTrue(beside.url.path.hasPrefix(env.store.snapshotDirectory.path), "falls back beside the store")
        XCTAssertTrue(ArchiveSnapshotPolicy.verdict(for: env.root).isUsable)
        XCTAssertFalse(ArchiveSnapshotPolicy.verdict(for: env.root.appendingPathComponent("missing")).isUsable)
    }

    /// §3-S1 restore: a snapshot brings the archive back, the database it
    /// replaced is kept first, and a damaged snapshot replaces nothing.
    func testSnapshots_restoreBringsBackTheArchive_keepsTheCurrentOne_refusesADamagedFile() async throws {
        let env = makeEnv()
        try await env.store.insertBatch((0..<3).map { makeEmail($0) }, batchSize: 100)
        let snap = try await env.store.snapshot(reason: "manual")
        try await env.store.insertBatch((3..<5).map { makeEmail($0) }, batchSize: 100)
        let v5 = try await env.archive.count()
        XCTAssertEqual(v5, 5)

        let damaged = env.root.appendingPathComponent("damaged.db")
        try Data(repeating: 0x41, count: 8_192).write(to: damaged)
        do {
            try await env.store.restore(from: damaged)
            XCTFail("a damaged snapshot must be refused")
        } catch {}
        let still = try await env.archive.count()
        XCTAssertEqual(still, 5, "nothing was replaced")

        try await env.store.restore(from: snap.url)
        let back = try await env.archive.count()
        XCTAssertEqual(back, 3)
        XCTAssertTrue(env.store.snapshots().contains { $0.reason == "before restore" }, "the replaced database is kept")
    }

    /// §3-S1 / rule 2: an archive opened for a schema upgrade gets a snapshot
    /// first, and the upgrade still completes.
    func testMigration_leavesASnapshotBeforeTheUpgrade() async throws {
        let env = makeEnv()
        try await env.store.insertBatch((0..<3).map { makeEmail($0) }, batchSize: 100)
        await env.store.reopenConnection()
        var db: OpaquePointer?
        let path = env.store.storeDirectory.appendingPathComponent("emails.db").path
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA user_version = 18;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        ArchiveSnapshotPolicy.isEnabled = true
        defer { ArchiveSnapshotPolicy.isEnabled = false }
        let n = try await env.archive.count()
        XCTAssertEqual(n, 3, "the upgrade completed and nothing was lost")
        XCTAssertTrue(env.store.snapshots().contains { $0.reason == "before upgrade" }, "a snapshot was taken first")
        XCTAssertNil(ArchiveSnapshotPolicy.upgradeSnapshotFailure)
    }

    /// Queries saved before 3.0 (no `exclusions` key) still decode.
    func testEmailQuery_decodesPre30JSON() throws {
        var q = EmailQuery()
        q.sender = "alice"
        var json = try XCTUnwrap(String(data: JSONEncoder().encode(q), encoding: .utf8))
        json = json.replacingOccurrences(of: ",\"exclusions\":null", with: "")
        XCTAssertFalse(json.contains("exclusions"))
        let decoded = try JSONDecoder().decode(EmailQuery.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.sender, "alice")
        XCTAssertNil(decoded.exclusions)
    }

    // MARK: - Bates numbers never change (§3-L6, rule 3)

    func testBates_numbersOldestFirst_andNeverRenumberWhenMailArrives() async throws {
        let env = makeEnv()
        try await env.store.insertBatch((10..<15).map { makeEmail($0) }, batchSize: 100)
        let format: (Int) -> String = { "T" + String(format: "%04d", $0) }

        try await ScopeJobEnvironment.$current.withValue(env.job) {
            let first = try await BatesEngine.number(query: .all, prefix: "T", start: 1, format: format)
            XCTAssertEqual(first.state.assigned, 5)
            XCTAssertEqual(first.state.first, "T0001")
            XCTAssertEqual(first.state.last, "T0005")
            let ids = try await idsOldestFirst(env)
            let numbers = try await env.store.reviewCoding(workspace: BatesEngine.workspace, field: BatesEngine.field)
            XCTAssertEqual(ids.map { numbers[$0] }, ["T0001", "T0002", "T0003", "T0004", "T0005"], "date order, oldest first")

            // Older AND newer mail arrives; existing numbers stay put.
            try await env.store.insertBatch([makeEmail(1, tag: "early"), makeEmail(20, tag: "late"), makeEmail(12, tag: "mid")], batchSize: 10)
            let second = try await BatesEngine.number(query: .all, prefix: "T", start: 1, format: format)
            XCTAssertEqual(second.state.assigned, 3)
            XCTAssertEqual(second.state.skipped, 5)
            let after = try await env.store.reviewCoding(workspace: BatesEngine.workspace, field: BatesEngine.field)
            for id in ids { XCTAssertEqual(after[id], numbers[id], "an assigned number never changes") }
            XCTAssertEqual(Set(after.values).count, 8, "no number reused")
            XCTAssertEqual(Set(after.values.filter { !numbers.values.contains($0) }), ["T0006", "T0007", "T0008"],
                           "new mail continues after the highest number")

            // A higher configured start is honoured; a lower one never rewinds.
            try await env.store.insertBatch([makeEmail(30, tag: "later")], batchSize: 10)
            let third = try await BatesEngine.number(query: .all, prefix: "T", start: 3, format: format)
            XCTAssertEqual(third.state.first, "T0009")
        }
    }

    // MARK: - Evidence records (§3-E2)

    /// Every line of the record proves its email on its own: the leaf is the
    /// SHA-256 of the stored raw MIME, it folds up to its month root, and the
    /// month root folds up to the archive root. Only emails in scope appear.
    func testEvidenceRecord_everyProofFoldsToTheArchiveRoot() async throws {
        let env = makeEnv()
        try await env.store.insertBatch((0..<30).map { makeEmail($0 * 3, from: $0 % 3 == 0 ? "carol@x.org" : "alice@example.com") },
                                        batchSize: 100)
        let url = env.root.appendingPathComponent("record.jsonl")
        var scope = ArchiveScope.wholeArchive
        scope.query.sender = "alice"

        let result = try await ScopeJobEnvironment.$current.withValue(env.job) {
            try await EvidenceRecordExporter.write(scope: scope, to: url)
        }
        XCTAssertEqual(result.written, 20)

        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { Data($0.utf8) }
        let header = try JSONDecoder().decode(EvidenceRecordExporter.Header.self, from: lines[0])
        XCTAssertEqual(header.archiveRoot, result.root)
        XCTAssertEqual(header.emailsInRecord, 20)
        let monthRoots = Dictionary(uniqueKeysWithValues: header.buckets.map { (Int($0["month"]!)!, $0["root"]!) })
        XCTAssertGreaterThan(monthRoots.count, 1, "the fixture spans several months")

        let entries = try lines.dropFirst().map { try JSONDecoder().decode(EvidenceRecordExporter.Line.self, from: $0) }
        XCTAssertEqual(entries.count, 20)
        for entry in entries {
            let id = try XCTUnwrap(UUID(uuidString: entry.id))
            let raw = try await env.store.rawBytes(id: id)
            let digest = SHA256.hash(data: try XCTUnwrap(raw)).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(entry.leaf, digest, "the leaf is the hash of the stored original")
            let month = EvidenceRecordExporter.fold(entry.leaf, entry.bucketPath)
            XCTAssertEqual(month, monthRoots[entry.month])
            XCTAssertEqual(EvidenceRecordExporter.fold(month, entry.rootPath), header.archiveRoot)
        }
    }

    /// The proof path is right for every position and every tree size,
    /// including odd nodes carried up unchanged.
    func testEvidenceRecord_pathFoldsForEveryPositionAndSize() {
        for size in 1...17 {
            let leaves = (0..<size).map { SHA256.hash(data: Data("leaf \($0)".utf8)).map { String(format: "%02x", $0) }.joined() }
            let root = SQLiteEmailStore.merkleRoot(leaves)
            for i in 0..<size {
                XCTAssertEqual(EvidenceRecordExporter.fold(leaves[i], EvidenceRecordExporter.path(for: i, in: leaves)), root,
                               "size \(size), index \(i)")
            }
        }
    }

    // MARK: - Preservation package (§3-E5)

    /// The bag holds every original byte-for-byte, validates, and the audit
    /// entry is written after the package exists. Adding an unlisted payload
    /// file or changing one makes it invalid.
    func testPreservationBag_validates_andDetectsAddedOrChangedFiles() async throws {
        let env = makeEnv()
        let mail = (0..<8).map { makeEmail($0) }
        try await env.store.insertBatch(mail, batchSize: 100)
        let bag = env.root.appendingPathComponent("bag", isDirectory: true)

        let result = try await ScopeJobEnvironment.$current.withValue(env.job) {
            try await PreservationExporter.export(scope: .wholeArchive, to: bag, organization: "Test Org")
        }
        XCTAssertEqual(result.originals, 8)
        XCTAssertEqual(result.withoutOriginal, 0)
        XCTAssertTrue(result.verified)
        XCTAssertTrue(env.job.auditLines().contains { $0.hasPrefix("Preservation package exported") })

        for id in try await idsOldestFirst(env) {
            let stored = try await env.store.rawBytes(id: id)
            let packaged = try Data(contentsOf: bag.appendingPathComponent("data/originals/\(id.uuidString).eml"))
            XCTAssertEqual(packaged, stored, "byte-identical original")
        }
        let info = try String(contentsOf: bag.appendingPathComponent("bag-info.txt"), encoding: .utf8)
        XCTAssertTrue(info.contains("Payload-Oxum: \(result.payloadBytes).9"), "8 originals + premis.xml")

        // An unlisted payload file: incomplete bag.
        let stray = bag.appendingPathComponent("data/originals/stray.eml")
        try Data("not in the manifest".utf8).write(to: stray)
        XCTAssertFalse(try PreservationExporter.verify(bag: bag), "every payload file must be listed")
        try FileManager.default.removeItem(at: stray)
        XCTAssertTrue(try PreservationExporter.verify(bag: bag))

        // A changed original: fixity fails.
        let first = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: bag.appendingPathComponent("data/originals").path).first)
        try Data("tampered".utf8).write(to: bag.appendingPathComponent("data/originals/\(first)"))
        XCTAssertFalse(try PreservationExporter.verify(bag: bag))
    }

    // MARK: - Old Bates path never renumbers (finding #4, rule 3)

    /// The pre-3.0 path used to replace every assignment with a fresh
    /// sequence over the emails given. Now: numbered emails keep their
    /// numbers, the rest continue after the highest one, in date order.
    func testOldBatesPath_neverRenumbersExistingAssignments() {
        let suite = "mailin-bates-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let env = makeEnv()

        ScopeJobEnvironment.$current.withValue(env.job) {
            let manager = BatesNumberingManager(defaults: defaults)
            manager.prefix = "B"
            manager.zeroPadding = 3
            let first = [makeEmail(10), makeEmail(11), makeEmail(12)]
            XCTAssertEqual(manager.unnumberedCount(in: first), 3)
            let assigned = manager.assignNumbers(to: first)
            XCTAssertEqual(first.map { assigned[$0.id] }, ["B001", "B002", "B003"])

            // A later run over a different working set: older and newer mail
            // plus two already-numbered emails.
            let older = makeEmail(1, tag: "older"), newer = makeEmail(20, tag: "newer")
            let second = [first[2], older, newer, first[0]]
            XCTAssertEqual(manager.unnumberedCount(in: second), 2)
            XCTAssertEqual(manager.nextFreeNumber(), 4)
            let more = manager.assignNumbers(to: second)
            XCTAssertEqual(more.count, 2, "only the unnumbered emails are numbered")
            XCTAssertEqual(more[older.id], "B004", "date order among the new ones")
            XCTAssertEqual(more[newer.id], "B005")
            for (email, number) in zip(first, ["B001", "B002", "B003"]) {
                XCTAssertEqual(manager.assignments[email.id], number, "an assigned number never changes")
            }
            XCTAssertEqual(manager.assignments.count, 5, "the first run's numbers are all kept")

            // Re-running over the same emails changes nothing.
            XCTAssertTrue(manager.assignNumbers(to: second).isEmpty)

            // Persisted to the injected store, not the app's settings.
            let reloaded = BatesNumberingManager(defaults: defaults)
            XCTAssertEqual(reloaded.assignments, manager.assignments)
        }
        XCTAssertTrue(env.job.auditLines().allSatisfy { $0.hasPrefix("Bates Numbers Assigned") })
    }

    // MARK: - S2 / S9: connection settings and two writers

    /// The 3.0 connection settings read back from a connection, and two
    /// stores writing the same archive at once never fail with "database is
    /// locked" (busy wait + write lock taken up front).
    func testSQLiteHygiene_settingsReadBack_andTwoWritersNeverBusy() async throws {
        let was = SQLiteHygiene.isEnabled
        SQLiteHygiene.isEnabled = true
        defer { SQLiteHygiene.isEnabled = was }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("v3found-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("probe.db").path, &db), SQLITE_OK)
        let handle = try XCTUnwrap(db)
        defer { sqlite3_close(handle) }
        SQLiteHygiene.apply(to: handle)
        func pragma(_ name: String) -> Int {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "PRAGMA \(name);", -1, &stmt, nil) == SQLITE_OK else { return -1 }
            defer { sqlite3_finalize(stmt) }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : -1
        }
        XCTAssertEqual(pragma("busy_timeout"), 5000)
        XCTAssertEqual(pragma("wal_autocheckpoint"), 10000)
        #if os(macOS)
        XCTAssertEqual(pragma("checkpoint_fullfsync"), 1)
        #endif
        XCTAssertEqual(SQLiteHygiene.beginWrite, "BEGIN IMMEDIATE TRANSACTION;")

        let dir = root.appendingPathComponent("store", isDirectory: true)
        let first = SQLiteEmailStore(directory: dir)
        try await first.insertBatch([makeEmail(0, tag: "warm")], batchSize: 1)   // schema created once
        let second = SQLiteEmailStore(directory: dir)
        let a = (1...400).map { makeEmail($0, tag: "a") }
        let b = (1...400).map { makeEmail($0, tag: "b") }
        async let x: Void = { for chunk in stride(from: 0, to: a.count, by: 20) { try await first.insertBatch(Array(a[chunk..<chunk + 20]), batchSize: 20) } }()
        async let y: Void = { for chunk in stride(from: 0, to: b.count, by: 20) { try await second.insertBatch(Array(b[chunk..<chunk + 20]), batchSize: 20) } }()
        try await x
        try await y
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts", isDirectory: true))
        let archive = ArchiveDataService(repository: EmailStoreRepository(store: SQLiteEmailStore(directory: dir), fts: fts))
        let stored = try await archive.count(query: .all)
        XCTAssertEqual(stored, 801, "every write from both connections landed")
    }

    // MARK: - S8: safe HTML

    /// Every auto-loading remote reference is removed (pixels, CSS, frames,
    /// scripts, refresh); inline cid: images, text and click-only links stay.
    func testSafeHTML_removesEveryRemoteFetch_keepsInlineContent() {
        let html = """
            <html><head><link rel="stylesheet" href="https://t.example/a.css">\
            <style>@import url(https://t.example/b.css); body { background: url('https://t.example/bg.png') }</style>\
            <meta http-equiv="refresh" content="0;url=https://t.example/r"></head>\
            <body onload="track()"><img src="https://t.example/pixel.gif" width="1"><img src=//t.example/p2.gif>\
            <img srcset="https://t.example/x.png 2x"><img src="cid:logo@mail"><video poster="https://t.example/p.jpg"></video>\
            <script>fetch('https://t.example/s')</script><iframe src="https://t.example/f"></iframe>\
            <a href="https://example.com/read">Read</a><p>Hello there</p></body></html>
            """
        let safe = SafeHTMLRenderer.sanitize(html)
        XCTAssertFalse(safe.html.contains("t.example"), safe.html)
        XCTAssertFalse(safe.html.lowercased().contains("onload"))
        XCTAssertTrue(safe.html.contains("cid:logo@mail"))
        XCTAssertTrue(safe.html.contains("https://example.com/read"), "a link loads nothing until it is clicked")
        XCTAssertTrue(safe.html.contains("Hello there"))
        XCTAssertGreaterThanOrEqual(safe.blockedRemoteItems, 6, "pixel ×2, srcset, poster, CSS url, @import")
    }

    /// A 5 MB message is sanitized and converted off the main thread: the
    /// main actor keeps running while it renders.
    func testSafeHTML_largeMessageDoesNotBlockTheMainThread() async throws {
        final class Ticks { var n = 0 }
        let ticks = Ticks()
        let big = "<p>" + String(repeating: "word <b>x</b> ", count: 360_000) + "</p>"
        XCTAssertGreaterThan(big.utf8.count, 5_000_000)
        let ticker = Task { @MainActor in
            while !Task.isCancelled { ticks.n += 1; try? await Task.sleep(for: .milliseconds(10)) }
        }
        let started = Date()
        _ = try? await SafeHTMLRenderer.render(big)
        let elapsed = Date().timeIntervalSince(started)
        ticker.cancel()
        // At least a third of the 10 ms ticks that fit in the render time ran.
        XCTAssertGreaterThanOrEqual(Double(ticks.n), max(1, elapsed * 100 / 3), "main actor starved: \(ticks.n) ticks in \(elapsed) s")
    }

    // MARK: - A6: a long thread is read whole

    /// Thread Story pages every member of the thread (the previous path
    /// stopped at 200): 650 replies → 650 messages, oldest first.
    func testThreadStory_completeThread_readsEveryMember() async throws {
        let env = makeEnv()
        let thread = (0..<650).map { i -> MBOXParser.RawEmail in
            var e = makeEmail(i, subject: i == 0 ? "Plan" : "Re: Plan", tag: "th")
            if i > 0 {
                e.headers["In-Reply-To"] = "<th-\(i - 1)@test>"
                e.headers["References"] = "<th-0@test> <th-\(i - 1)@test>"
            }
            return e
        }
        try await env.store.insertBatch(thread, batchSize: 200)
        try await env.store.insertBatch((0..<20).map { makeEmail(1_000 + $0, subject: "Other \($0)", tag: "ot") }, batchSize: 20)
        _ = try await ArchiveThreadService(store: env.store).backfillThreadKeys()
        try await ScopeJobEnvironment.$current.withValue(env.job) {
            var q = EmailQuery(); q.subjectContains = "Plan"; q.sort = .dateAsc
            var oldest: MBOXParser.RawEmail?
            for try await batch in env.archive.streamFullEmails(query: q, batchSize: 1) { oldest = batch.first; break }
            let first = try XCTUnwrap(oldest)
            let members = try await ThreadStoryEngine.completeThread(of: first)
            XCTAssertEqual(members.count, 650)
            XCTAssertEqual(members.first?.headers["Subject"], "Plan")
            let dates = members.compactMap { MBOXParser.parseDate($0.headers["Date"]) }
            XCTAssertEqual(dates, dates.sorted(), "oldest first")
        }
    }

    // MARK: - H9: PST export in parts

    /// A PST export larger than the destination accepts is written as
    /// numbered parts, each a complete PST that opens again, every email once.
    func testPSTExport_splitsIntoValidParts_everyEmailOnce() async throws {
        let env = makeEnv()
        try await env.store.insertBatch((0..<60).map { makeEmail($0, tag: "pst") }, batchSize: 60)
        let out = env.root.appendingPathComponent("pst", isDirectory: true)
        let exporter = ArchiveExportService(archive: env.archive)
        let parts = try await exporter.exportPSTParts(scope: .query(.all, exclusions: []), toDirectory: out,
                                                      baseName: "m", partBytes: 4_000)
        XCTAssertGreaterThan(parts.count, 1, "small part size forces several files")
        XCTAssertEqual(parts.first?.url.lastPathComponent, "m-0001.pst")
        XCTAssertEqual(parts.reduce(0) { $0 + $1.messages }, 60)
        var subjects = Set<String>()
        for part in parts {
            let parsed = try PSTParser.parse(fileURL: part.url, senderEmail: "")
            XCTAssertEqual(parsed.count, part.messages, part.url.lastPathComponent)
            for email in parsed { subjects.insert(email.headers["Subject"] ?? "") }
        }
        XCTAssertEqual(subjects.count, 60, "every email in exactly one part")
        XCTAssertLessThanOrEqual(ArchiveExportService.pstPartBytes(for: out), 45_000_000_000, "below the format's 50 GB")
    }

    // MARK: - Q3: EDRM Message Identification Hash

    /// The same message from two sources (different stored ids and header
    /// order) has one MIH; a changed body has another.
    func testMessageIdentificationHash_sameMessageAnySource_changesWithContent() {
        let a = makeEmail(7, tag: "mih")
        var b = makeEmail(7, tag: "mih")
        b.rawSource = b.headers.sorted { $0.key > $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n") + "\n\n" + b.plainBody
        XCTAssertNotEqual(a.id, b.id)
        let ha = FeatureExtractor.messageIdentificationHash(a, bodyText: a.plainBody)
        XCTAssertEqual(ha, FeatureExtractor.messageIdentificationHash(b, bodyText: b.plainBody))
        XCTAssertNotEqual(ha, FeatureExtractor.messageIdentificationHash(a, bodyText: a.plainBody + " edited"))
        XCTAssertFalse(ha.isEmpty)
    }

    // MARK: - E7: collect-to-preserve

    /// Import holds and seals each committed batch when collect-to-preserve
    /// is on — also with forensic mode off (it used to run only inside the
    /// forensic branch, so the toggle silently did nothing).
    func testCollectToPreserve_holdsEveryCommittedBatch_withOrWithoutForensicMode() throws {
        final class Calls { var hashed = 0, held = 0 }
        let batch = (0..<3).map { makeEmail($0, tag: "ctp") }
        for (forensic, preserve) in [(false, true), (true, true), (true, false)] {
            let calls = Calls()
            let work = try XCTUnwrap(ContentViewModel.committedBatchWork(
                forensic: forensic, preserve: preserve,
                hash: { calls.hashed += $0.count }, hold: { calls.held += $0.count }))
            work(batch)
            XCTAssertEqual(calls.hashed, forensic ? 3 : 0, "forensic \(forensic), preserve \(preserve)")
            XCTAssertEqual(calls.held, preserve ? 3 : 0, "forensic \(forensic), preserve \(preserve)")
        }
        XCTAssertNil(ContentViewModel.committedBatchWork(forensic: false, preserve: false, hash: { _ in }, hold: { _ in }))
    }

    // MARK: - F1: Cancel

    /// Cancel stops the job at the next batch: the receipt says "stopped
    /// after X of Y", the checkpoint is kept, and a second run resumes and
    /// finishes with each email exactly once.
    func testScopeJob_cancelStopsAtTheNextBatch_saysXofY_andResumes() async throws {
        let env = makeEnv()
        try await env.store.insertBatch((0..<120).map { makeEmail($0, tag: "cx") }, batchSize: 120)
        try await ScopeJobEnvironment.$current.withValue(env.job) {
            let (first, receipt) = try await ScopeJob.run(
                key: "test.cancel", title: "Cancel", capability: .v3ScopeEngine,
                query: .all, batchSize: 20, initialState: [UUID]()
            ) { seen, batch in
                seen += batch.map(\.id)
                if seen.count >= 40 { ScopeJobCenter.shared.cancel("test.cancel") }
            }
            XCTAssertTrue(receipt.cancelled)
            XCTAssertEqual(receipt.processed, first.count)
            XCTAssertLessThan(receipt.processed, 120, "stopped before the end")
            XCTAssertEqual(receipt.totalInScope, 120)
            XCTAssertTrue(receipt.coverageLine.contains("\(receipt.processed)") && receipt.coverageLine.contains("120"))

            let (rest, finished) = try await ScopeJob.run(
                key: "test.cancel", title: "Cancel", capability: .v3ScopeEngine,
                query: .all, batchSize: 20, initialState: [UUID]()
            ) { seen, batch in seen += batch.map(\.id) }
            XCTAssertTrue(finished.resumed)
            XCTAssertFalse(finished.cancelled)
            XCTAssertEqual(finished.processed, 120)
            // The resumed run carries the stopped run's state forward.
            XCTAssertEqual(rest.count, 120, "each email once across the two runs")
            XCTAssertEqual(Set(rest).count, 120)
            XCTAssertEqual(Array(rest.prefix(first.count)), first, "picked up where it stopped")
        }
    }
}

// MARK: - 3.1 test pass: Scripts (S6–S11)

@MainActor
final class V31ScriptTests: XCTestCase {
    private func makeEmail(_ subject: String = "Contract terminate notice", body: String = "We will terminate the contract today.",
                       extra: String = "") throws -> MBOXParser.RawEmail {
        try MBOXParser.processRawMessage("""
            From: A <a@example.com>
            To: b@example.org
            Subject: \(subject)
            Date: Mon, 6 Jan 2025 10:00:00 +0000
            Message-ID: <s1@example.com>
            \(extra)Content-Type: text/plain

            \(body)
            """, senderEmail: "")
    }

    func testInstrument_guardsWhileAndFor_leavesStringsAndForOf() {
        let src = #"var s = "while (true)"; while (x < 3) { x++; } for (var i = 0; i < 9; i++) {} for (;;) {} for (const k of a) {}"#
        let out = ScriptSandbox.instrument(src)
        XCTAssertTrue(out.contains(#""while (true)""#), "strings are untouched")
        XCTAssertTrue(out.contains("while (__mailinTick() && (x < 3))"))
        XCTAssertTrue(out.contains("for (var i = 0; __mailinTick() && (i < 9);  i++)"))
        XCTAssertTrue(out.contains("for (; __mailinTick() && (true); )"))
        XCTAssertTrue(out.contains("for (const k of a)"))
    }

    func testRuntime_proposesChanges_andReports() throws {
        let s = MailinScript(name: "t", source: """
            function process(email) {
              if (email.subject.indexOf("Contract") >= 0) mailin.tag("contract");
              mailin.column("len", String(email.body.length));
              mailin.report(email.subject);
            }
            """)
        let rt = try ScriptRuntime(s)
        let r = try rt.run(try makeEmail(), userTags: [])
        XCTAssertEqual(r.changes.map(\.kind), [.tag, .column])
        XCTAssertEqual(r.changes.first?.key, "contract")
        XCTAssertEqual(r.report, ["Contract terminate notice"])
    }

    func testRuntime_noNetwork_noEval_noFunctionConstructor() throws {
        let s = MailinScript(name: "probe", source: """
            function process(email) {
              mailin.report(typeof fetch + "," + typeof XMLHttpRequest + "," + typeof WebSocket + "," + typeof setTimeout + "," + typeof eval);
              try { (function(){}).constructor("return 1")(); mailin.report("ctor-ok"); } catch (e) { mailin.report("ctor-blocked"); }
            }
            """)
        let r = try ScriptRuntime(s).run(try makeEmail(), userTags: [])
        XCTAssertEqual(r.report.first, "undefined,undefined,undefined,undefined,undefined")
        XCTAssertEqual(r.report.last, "ctor-blocked")
    }

    func testRuntime_infiniteLoop_isStoppedByTheWatchdog() throws {
        let rt = try ScriptRuntime(MailinScript(name: "loop", source: "function process(email) { while (true) {} }"))
        let start = Date()
        XCTAssertThrowsError(try rt.run(try makeEmail(), userTags: [])) { error in
            guard case ScriptError.watchdog = error else { return XCTFail("expected the watchdog, got \(error)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), ScriptPolicy.perEmailSeconds + 3)
    }

    func testRuntime_compileErrors_areReported() {
        XCTAssertThrowsError(try ScriptRuntime(MailinScript(name: "bad", source: "function process(email) {"))) {
            guard case ScriptError.compile = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try ScriptRuntime(MailinScript(name: "none", source: "var x = 1;"))) {
            XCTAssertEqual($0 as? ScriptError, .noProcessFunction)
        }
    }

    func testEveryBundledScript_compiles_andRunsWithoutErrors() throws {
        let sample = try makeEmail(extra: "Received: from a (a [10.0.0.1]) by b; Mon, 6 Jan 2025 10:00:00 +0000\n")
        for s in BundledScripts.all {
            let rt = try ScriptRuntime(s)
            XCTAssertNoThrow(try rt.run(sample, userTags: []), s.name)
        }
        XCTAssertEqual(Set(BundledScripts.all.map(\.id)).count, BundledScripts.all.count, "stable unique ids")
    }

    func testKeywordProximityScript_tagsOnlyNearWords() throws {
        let s = try XCTUnwrap(BundledScripts.all.first { $0.name == "Keyword proximity" })
        let rt = try ScriptRuntime(s)
        XCTAssertEqual(try rt.run(try makeEmail(), userTags: []).changes.first?.key, "near:contract+terminate")
        XCTAssertTrue(try rt.run(try makeEmail(body: "contract " + String(repeating: "word ", count: 30) + "terminate"), userTags: []).changes.isEmpty)
    }

    func testRecipe_generatesCodeThatCompiles_andMatches() throws {
        var r = ScriptRecipe()
        r.conditions = [.init(field: .subject, op: .contains, value: "contract"),
                        .init(field: .body, op: .matches, value: "termin\\w+")]
        r.actions = [.init(kind: .tag, value: "recipe-hit"), .init(kind: .column, value: "why", value2: "it's \"quoted\"")]
        let rt = try ScriptRuntime(MailinScript(name: r.name, source: r.source))
        let hit = try rt.run(try makeEmail(), userTags: [])
        XCTAssertEqual(hit.changes.map(\.key), ["recipe-hit", "why"])
        XCTAssertEqual(hit.changes.last?.value, "it's \"quoted\"", "values are escaped, not spliced")
        let lunch = try makeEmail("Lunch")
        XCTAssertTrue(try rt.run(lunch, userTags: []).changes.isEmpty)
    }

    func testScriptFile_roundTrip_andTamperRefused() throws {
        let s = MailinScript(name: "share me", version: "3", source: "function process(email) { mailin.tag('x'); }", runsAtImport: true)
        let data = try ScriptFile.export(s)
        let back = try ScriptFile.importScript(data)
        XCTAssertEqual(back.source, s.source)
        XCTAssertEqual(back.version, "3")
        XCTAssertFalse(back.runsAtImport, "an imported script never runs at import until the user says so")
        XCTAssertNotEqual(back.id, s.id)
        let tampered = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "mailin.tag('x')", with: "mailin.tag('y')")
        XCTAssertThrowsError(try ScriptFile.importScript(Data(tampered.utf8)))
    }
}

// MARK: - 3.1 test pass: Review Pack files (T0) and team case fold (T2–T7)

final class V31ReviewTests: XCTestCase {
    private var dir: URL!
    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("V31ReviewTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir); super.tearDown() }

    private func writePack(key: Curve25519.Signing.PrivateKey, emails n: Int) throws -> URL {
        let url = dir.appendingPathComponent("p.mailinpack")
        let w = try SignedLineWriter(url: url)
        try w.write(ReviewPackHeader(packID: UUID(), title: "T", createdAt: Date(), createdBy: "E",
                                     examinerKey: key.publicKey.rawRepresentation.base64EncodedString(),
                                     emailCount: n, codes: ReviewPackBuilder.defaultCodes, instructions: "", scope: "all"))
        for i in 0..<n {
            try w.write(ReviewPackEmail(id: UUID(), date: "d", from: "f\(i)", to: "t", cc: "", subject: "S\(i)",
                                        body: "body \(i)", attachments: [], sourceSHA256: "x"))
        }
        try w.finish(signingWith: key)
        return url
    }

    func testPack_opens_readsBodiesLazily_andResponseIsSigned() throws {
        let key = Curve25519.Signing.PrivateKey()
        let url = try writePack(key: key, emails: 25)
        let pack = try OpenedReviewPack.open(url)
        XCTAssertEqual(pack.index.count, 25)
        XCTAssertEqual(try pack.email(at: 17).subject, "S17")

        let id = pack.index[3].id
        let out = dir.appendingPathComponent("r.mailinresponse")
        // writeResponse signs with the device key; verify the file with its own header key.
        do {
            try pack.writeResponse([id: ReviewDecision(emailID: id, code: "Privileged", tags: ["a"], note: "n", decidedAt: Date())],
                                   reviewer: "R", to: out)
        } catch ReviewPackError.keyUnavailable {
            throw XCTSkip("no Keychain in this test host")
        }
        var header: ReviewResponseHeader?
        let sha = try SignedLineReader.verify(url: out) { first in
            header = try SignedLineReader.decoder().decode(ReviewResponseHeader.self, from: first)
            return header!.reviewerKey
        }
        XCTAssertFalse(sha.isEmpty)
        XCTAssertEqual(header?.packSHA256, pack.sha256)
    }

    func testPack_anyChangedByte_isRefused() throws {
        let url = try writePack(key: Curve25519.Signing.PrivateKey(), emails: 3)
        var text = try String(contentsOf: url, encoding: .utf8)
        text = text.replacingOccurrences(of: "body 1", with: "body X")
        try Data(text.utf8).write(to: url)
        XCTAssertThrowsError(try OpenedReviewPack.open(url)) { XCTAssertEqual($0 as? ReviewPackError, .badSignature) }
    }

    // Team fold

    private struct Author { let key = Curve25519.Signing.PrivateKey(); let name: String
        var pub: String { key.publicKey.rawRepresentation.base64EncodedString() } }

    private func entries(_ a: Author, _ ops: [(TeamLogEntry.Op, UUID?, String, Int)]) throws -> [TeamLogEntry] {
        var out: [TeamLogEntry] = []
        for (i, op) in ops.enumerated() {
            var e = TeamLogEntry(seq: i, lamport: op.3, author: a.pub, authorName: a.name, role: "reviewer", at: Date(),
                                 op: op.0, emailID: op.1, batch: nil, value: op.2, prevHash: out.last?.hash ?? "")
            e.signature = try a.key.signature(for: try e.signedBytes()).base64EncodedString()
            out.append(e)
        }
        return out
    }

    private func manifest(lead: Author) -> TeamCaseManifest {
        TeamCaseManifest(caseID: UUID(), title: "c", createdAt: Date(), createdBy: "L", leadKey: lead.pub,
                         codes: ReviewPackBuilder.defaultCodes, batches: [], qcPercent: 10)
    }

    func testFold_isTheSameForAnyInterleaving_andConflictsKeepBothDecisions() throws {
        let lead = Author(name: "Lead"), r1 = Author(name: "Ann"), r2 = Author(name: "Bo")
        let e1 = UUID(), e2 = UUID()
        var all = try entries(r1, [(.code, e1, "Relevant", 1), (.tagAdd, e1, "hot", 2), (.code, e2, "Privileged", 3)])
        all += try entries(r2, [(.code, e1, "Not relevant", 2), (.tagAdd, e1, "hot", 3), (.tagRemove, e1, "hot", 4)])
        let m = manifest(lead: lead)
        let reference = TeamCase.fold(all, manifest: m)
        for _ in 0..<20 { XCTAssertEqual(TeamCase.fold(all.shuffled(), manifest: m), reference) }

        XCTAssertEqual(reference.conflicts.count, 1)
        XCTAssertEqual(Set(reference.conflicts[0].decisions.values), ["Relevant", "Not relevant"])
        XCTAssertEqual(reference.emails[e1]?.tags["hot"]?.count, 1, "the tag stays while Ann still holds it")
        XCTAssertEqual(reference.code(e2), "Privileged")

        // Only the lead's resolution counts.
        let fake = try entries(r1, [(.resolve, e1, "Relevant", 9)])
        XCTAssertEqual(TeamCase.fold(all + fake, manifest: m).conflicts.count, 1)
        let real = try entries(lead, [(.resolve, e1, "Not relevant", 9)])
        let resolved = TeamCase.fold(all + real, manifest: m)
        XCTAssertTrue(resolved.conflicts.isEmpty)
        XCTAssertEqual(resolved.code(e1), "Not relevant")
    }

    func testLog_tamperedEntryStopsTheLog_tornLastLineIsIgnored() throws {
        let a = Author(name: "Ann")
        let es = try entries(a, [(.code, UUID(), "Relevant", 1), (.code, UUID(), "Privileged", 2), (.code, UUID(), "Relevant", 3)])
        func file(_ list: [TeamLogEntry], tail: String = "") throws -> URL {
            var d = Data()
            for e in list { d.append(try TeamCaseIO.encoder.encode(e)); d.append(0x0A) }
            d.append(Data(tail.utf8))
            let url = dir.appendingPathComponent(UUID().uuidString + ".jsonl")
            try d.write(to: url)
            return url
        }
        XCTAssertEqual(TeamCase.readLog(try file(es)).0.count, 3)

        let torn = TeamCase.readLog(try file(es, tail: "{\"seq\":3,\"lam"))
        XCTAssertEqual(torn.0.count, 3)
        XCTAssertTrue(torn.1.first?.contains("interrupted") ?? false)

        var changed = es
        changed[1].value = "Not relevant"     // signature no longer matches
        let tampered = TeamCase.readLog(try file(changed))
        XCTAssertEqual(tampered.0.count, 1, "entries after a tampered one are not used")
        XCTAssertTrue(tampered.1.first?.contains("tampered") ?? false)
    }

    func testQCStats_overturnRate_andWilsonInterval() throws {
        let lead = Author(name: "Lead"), r1 = Author(name: "Ann"), qc = Author(name: "Q")
        var all: [TeamLogEntry] = []
        var ann: [(TeamLogEntry.Op, UUID?, String, Int)] = []
        var q: [(TeamLogEntry.Op, UUID?, String, Int)] = []
        for i in 0..<10 {
            let id = UUID()
            ann.append((.code, id, "Relevant", i + 1))
            q.append((.qcCode, id, i < 2 ? "Not relevant" : "Relevant", i + 20))
        }
        all += try entries(r1, ann)
        all += try entries(qc, q)
        let s = TeamCase.fold(all, manifest: manifest(lead: lead))
        let stat = try XCTUnwrap(s.qcStats().first)
        XCTAssertEqual(stat.checked, 10)
        XCTAssertEqual(stat.overturned, 2)
        XCTAssertEqual(stat.rate, 0.2, accuracy: 1e-9)
        // Wilson 95 % for 2/10: 0.0567 – 0.5098.
        XCTAssertEqual(stat.low, 0.0567, accuracy: 0.001)
        XCTAssertEqual(stat.high, 0.5098, accuracy: 0.001)
    }
}

// MARK: - 3.1 test pass: Shortcuts (S0–S1)

final class V31ShortcutsTests: XCTestCase {
    func testSearchSummary_saysTheExactTotal() {
        XCTAssertEqual(SearchEmailsIntent.summary(total: 25, shown: 10, query: "x"), "Found 25 emails matching “x”; showing the first 10.")
        XCTAssertEqual(SearchEmailsIntent.summary(total: 3, shown: 3, query: "x"), "Found 3 emails matching “x”.")
    }

    func testFindClauses_mapOntoTheArchiveQuery() {
        var q = EmailQuery()
        for c: EmailEntityClause in [.sender("anna"), .subject("budget"), .hasAttachments(true), .recovered(false)] { c.apply(to: &q) }
        XCTAssertEqual(q.sender, "anna")
        XCTAssertEqual(q.subjectContains, "budget")
        XCTAssertEqual(q.hasAttachments, true)
        XCTAssertEqual(q.exclusions?.first?.field, .recovered)
        var r = EmailQuery(); EmailEntityClause.recovered(true).apply(to: &r)
        XCTAssertEqual(r.recovery, "any")
    }

    func testActionsRefuseWhileTheSwitchIsOff() {
        let was = ShortcutsPolicy.actionsEnabled
        ShortcutsPolicy.actionsEnabled = false
        defer { ShortcutsPolicy.actionsEnabled = was }
        XCTAssertThrowsError(try ShortcutsPolicy.requireEnabled())
    }
}
