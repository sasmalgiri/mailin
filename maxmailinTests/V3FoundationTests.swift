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
        let q = ArchiveQueryCompiler.compile("-source:inbox.mbox", exclusions: true)
        XCTAssertNil(q.sourceFileName)
        XCTAssertEqual(q.text, "-source:inbox.mbox", "kept as literal text, like any unrecognised operator")
        let n = ArchiveQueryCompiler.compile("NOT before:2020-01-01", exclusions: true)
        XCTAssertNil(n.beforeDate)
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
}
