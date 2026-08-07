import XCTest
@testable import maxmailin

/// Parts I–M regression net: persisted derived state (AI filter attributes,
/// topics, thread keys, predictive-coding records, near-duplicate findings)
/// over isolated temp-dir SQLite fixtures.
///
/// Written red-then-green: each test fails on its specific regression —
/// derived-state loss/clobbering, version bumps not triggering recompute,
/// wrong thread-key derivation, score upserts clobbering human labels, or
/// findings pagination skipping/duplicating groups.
@MainActor
final class V2DerivedStateTests: XCTestCase {

    // MARK: - Fixtures (temp-dir SQLite store, per-test isolation)

    private func makeTempStore() -> SQLiteEmailStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailin-derived-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return SQLiteEmailStore(directory: root)
    }

    private func makeEmail(
        mid: String?,
        subject: String,
        body: String,
        inReplyTo: String? = nil,
        references: String? = nil,
        dayOffset: Int = 0
    ) -> MBOXParser.RawEmail {
        var headers: [String: String] = [
            "Subject": subject,
            "From": "a@b.com",
            "To": "c@d.com",
            "Date": "Wed, \(String(format: "%02d", 1 + (dayOffset % 28))) Jan 2025 14:30:00 +0000"
        ]
        if let mid { headers["Message-ID"] = mid }
        if let inReplyTo { headers["In-Reply-To"] = inReplyTo }
        if let references { headers["References"] = references }
        return MBOXParser.RawEmail(
            headers: headers,
            rawSource: "From a@b.com\n\(body)",
            messageType: "email",
            attachments: [],
            timestamp: "2025-01-15T14:30:00Z",
            domains: ["b.com"],
            plainBody: body,
            htmlBody: ""
        )
    }

    // MARK: - Part I — derived-state persistence roundtrip

    /// A fully-populated derived record survives a persist → fetch roundtrip
    /// field-for-field, and a topic-only partial upsert (Part J's write path)
    /// must NOT clobber the fields other producers persisted.
    func testDerivedRecordRoundtripAndTopicMergePreservesFields() async throws {
        let store = makeTempStore()
        let id = UUID()

        var record = DerivedRecord(emailID: id)
        record.corpusRevision = 3
        record.analysisVersion = 1
        record.sentiment = "0.7500"
        record.classification = "Newsletter"
        record.priority = 4
        record.phishing = true
        record.threadID = "<root@test>"
        record.predictiveScore = 0.42
        record.smartTags = ["Newsletter", "Flagged"]
        record.updatedAt = 1_700_000_000

        try await store.derivedUpsert([record])
        let fetched = try await store.derivedFetch(ids: [id])
        XCTAssertEqual(fetched[id], record, "persist → fetch must be lossless")

        // Part J partial write: only the topic column may change.
        try await store.derivedSetTopics([id: "Budget Planning"])
        let merged = try await store.derivedFetch(ids: [id])[id]
        XCTAssertEqual(merged?.topic, "Budget Planning", "topic persisted")
        XCTAssertEqual(merged?.sentiment, "0.7500", "sentiment must survive a topic write")
        XCTAssertEqual(merged?.priority, 4, "priority must survive a topic write")
        XCTAssertEqual(merged?.phishing, true, "phishing flag must survive a topic write")
        XCTAssertEqual(merged?.predictiveScore, 0.42, "predictive score must survive a topic write")
        XCTAssertEqual(merged?.smartTags, ["Newsletter", "Flagged"], "smart tags must survive a topic write")

        // Topic write for an email with NO prior derived row creates one.
        let fresh = UUID()
        try await store.derivedSetTopics([fresh: "Legal"])
        let created = try await store.derivedFetch(ids: [fresh])[fresh]
        XCTAssertEqual(created?.topic, "Legal", "topic-only insert works for new rows")
    }

    /// Version-bump recompute contract: records computed at analysis version 1
    /// become stale when the producer requires version 2, and recomputing at
    /// version 2 clears the work list. Already-computed ids at the current
    /// version are SKIPPED (incremental).
    func testVersionBumpMarksRecordsStaleUntilRecomputed() async throws {
        let store = makeTempStore()
        let fixtures = (0..<6).map { makeEmail(mid: "<v-\($0)@t>", subject: "S\($0)", body: "body \($0)", dayOffset: $0) }
        try await store.insertBatch(fixtures, batchSize: 100)

        // Nothing computed yet → all stale.
        let allStale = try await store.derivedStaleIDs(below: 0, minAnalysisVersion: 1, limit: 100)
        XCTAssertEqual(Set(allStale), Set(fixtures.map(\.id)), "missing records are stale")

        // Compute at version 1 → nothing stale at version 1.
        let v1 = fixtures.map { email -> DerivedRecord in
            var r = DerivedRecord(emailID: email.id)
            r.analysisVersion = 1
            r.sentiment = "0.0000"
            return r
        }
        try await store.derivedUpsert(v1)
        let noneStale = try await store.derivedStaleIDs(below: 0, minAnalysisVersion: 1, limit: 100)
        XCTAssertTrue(noneStale.isEmpty, "computed ids are skipped at the same version")

        // Version bump → everything stale again until recomputed at 2.
        let bumped = try await store.derivedStaleIDs(below: 0, minAnalysisVersion: 2, limit: 100)
        XCTAssertEqual(Set(bumped), Set(fixtures.map(\.id)), "version bump must trigger recompute")

        let v2 = v1.map { r -> DerivedRecord in var r = r; r.analysisVersion = 2; return r }
        try await store.derivedUpsert(v2)
        let cleared = try await store.derivedStaleIDs(below: 0, minAnalysisVersion: 2, limit: 100)
        XCTAssertTrue(cleared.isEmpty, "recompute at the new version clears the work list")
    }

    /// End-to-end through the background job runner: the first run computes
    /// every email in bounded batches; a re-run at the same version processes
    /// NOTHING (incremental); bumping the version reprocesses everything and
    /// preserves fields other producers wrote (merge contract).
    func testBackgroundJobRunnerIsIncrementalAndMerges() async throws {
        let store = makeTempStore()
        let fixtures = (0..<25).map { makeEmail(mid: "<j-\($0)@t>", subject: "S\($0)", body: "job body \($0)", dayOffset: $0) }
        try await store.insertBatch(fixtures, batchSize: 100)

        // Another producer persisted a topic first.
        let topicID = fixtures[0].id
        try await store.derivedSetTopics([topicID: "Preexisting Topic"])

        let runner = ArchiveBackgroundJobRunner(store: store)
        let first = await runner.run(batchSize: 10, minAnalysisVersion: 1, staleBelowRevision: false) { emails, existing, _ in
            emails.map { email in
                var r = existing[email.id] ?? DerivedRecord(emailID: email.id)
                r.analysisVersion = 1
                r.sentiment = "0.5000"
                return r
            }
        }
        XCTAssertEqual(first, .completed)
        XCTAssertEqual(runner.processed, 25, "first run computes every email")

        let second = await runner.run(batchSize: 10, minAnalysisVersion: 1, staleBelowRevision: false) { emails, existing, _ in
            emails.map { email in
                var r = existing[email.id] ?? DerivedRecord(emailID: email.id)
                r.analysisVersion = 1
                return r
            }
        }
        XCTAssertEqual(second, .completed)
        XCTAssertEqual(runner.processed, 0, "re-run at the same version is a no-op (incremental)")

        let third = await runner.run(batchSize: 10, minAnalysisVersion: 2, staleBelowRevision: false) { emails, existing, _ in
            emails.map { email in
                var r = existing[email.id] ?? DerivedRecord(emailID: email.id)
                r.analysisVersion = 2
                r.sentiment = "0.9000"
                return r
            }
        }
        XCTAssertEqual(third, .completed)
        XCTAssertEqual(runner.processed, 25, "version bump reprocesses everything")

        let merged = try await store.derivedFetch(ids: [topicID])[topicID]
        XCTAssertEqual(merged?.topic, "Preexisting Topic", "job must merge, not clobber, other producers' fields")
        XCTAssertEqual(merged?.sentiment, "0.9000")
        XCTAssertEqual(merged?.analysisVersion, 2)
    }

    // MARK: - Part L — thread-key derivation

    /// References chain wins (root = FIRST id), then In-Reply-To, then own
    /// Message-ID — all high confidence. Subject fallback is LOWER confidence;
    /// no signal at all yields a singleton key.
    func testThreadKeyDerivationCorrectness() {
        let id = UUID()

        // References chain: the root (first) id keys the thread.
        let refs = ThreadKeyDeriver.derive(
            messageID: "<c@t>", inReplyTo: "<b@t>",
            references: "<a@t>\n <b@t>", subject: "Re: Budget", emailID: id
        )
        XCTAssertEqual(refs.key, "<a@t>", "References root must win over In-Reply-To / Message-ID")
        XCTAssertEqual(refs.confidence, .high)

        // In-Reply-To when no References.
        let reply = ThreadKeyDeriver.derive(
            messageID: "<b@t>", inReplyTo: "<a@t>", references: nil, subject: "Re: Budget", emailID: id
        )
        XCTAssertEqual(reply.key, "<a@t>")
        XCTAssertEqual(reply.confidence, .high)

        // Own Message-ID for a thread root.
        let root = ThreadKeyDeriver.derive(
            messageID: "<a@t>", inReplyTo: nil, references: nil, subject: "Budget", emailID: id
        )
        XCTAssertEqual(root.key, "<a@t>")
        XCTAssertEqual(root.confidence, .high)

        // Subject fallback: Re:/Fwd: prefixes stripped, lowercased, LOWER confidence.
        let subj = ThreadKeyDeriver.derive(
            messageID: nil, inReplyTo: nil, references: nil, subject: "Re: Fwd: Budget Plan", emailID: id
        )
        XCTAssertEqual(subj.key, "subj:budget plan", "normalized-subject fallback")
        XCTAssertEqual(subj.confidence, .subjectFallback)
        XCTAssertLessThan(subj.confidence.rawValue, ThreadKeyDeriver.Confidence.high.rawValue,
                          "subject fallback must carry lower confidence than header derivation")

        // No signal at all → singleton key unique to the email.
        let single = ThreadKeyDeriver.derive(
            messageID: nil, inReplyTo: nil, references: nil, subject: "", emailID: id
        )
        XCTAssertEqual(single.key, "single:\(id.uuidString)")
        XCTAssertEqual(single.confidence, .singleton)
    }

    /// Backfill persists a key per email (bounded pages, resumable no-op when
    /// done) and the indexed threadKey → paginated-summaries query path
    /// returns exactly the chain members, newest first.
    func testThreadKeyBackfillAndPagedThreadQuery() async throws {
        let store = makeTempStore()
        // Reply chain of 3 (root A; B replies to A; C carries the References
        // chain "<a@t> <b@t>") + a subject-fallback pair + one unrelated email.
        let a = makeEmail(mid: "<a@t>", subject: "Budget", body: "root", dayOffset: 0)
        let b = makeEmail(mid: "<b@t>", subject: "Re: Budget", body: "reply", inReplyTo: "<a@t>", dayOffset: 1)
        let c = makeEmail(mid: "<c@t>", subject: "Re: Budget", body: "reply 2", references: "<a@t> <b@t>", dayOffset: 2)
        let s1 = makeEmail(mid: nil, subject: "Lunch", body: "eat", dayOffset: 3)
        let s2 = makeEmail(mid: nil, subject: "Re: Lunch", body: "yes", dayOffset: 4)
        let other = makeEmail(mid: "<z@t>", subject: "Zebra", body: "unrelated", dayOffset: 5)
        let fixtures = [a, b, c, s1, s2, other]
        try await store.insertBatch(fixtures, batchSize: 100)

        let threads = ArchiveThreadService(store: store)
        let written = try await threads.backfillThreadKeys(batchSize: 100)
        XCTAssertEqual(written, 6, "every stored email gets a key")
        let rerun = try await threads.backfillThreadKeys(batchSize: 100)
        XCTAssertEqual(rerun, 0, "backfill is incremental — a second pass writes nothing")

        // The whole chain shares the root key, at high confidence.
        for email in [a, b, c] {
            let row = try await store.threadKey(for: email.id)
            XCTAssertEqual(row?.threadKey, "<a@t>", "chain member keyed to the References/In-Reply-To root")
            XCTAssertEqual(row?.confidence, ThreadKeyDeriver.Confidence.high.rawValue)
        }
        // Subject-fallback pair groups together at lower confidence.
        let s1Row = try await store.threadKey(for: s1.id)
        let s2Row = try await store.threadKey(for: s2.id)
        XCTAssertEqual(s1Row?.threadKey, "subj:lunch")
        XCTAssertEqual(s1Row?.threadKey, s2Row?.threadKey, "Re:-prefixed subject joins the same thread")
        XCTAssertEqual(s1Row?.confidence, ThreadKeyDeriver.Confidence.subjectFallback.rawValue)

        // Paginated query path: newest first, disjoint pages, only members.
        let page1 = try await threads.emailIDs(inThread: "<a@t>", limit: 2, offset: 0)
        let page2 = try await threads.emailIDs(inThread: "<a@t>", limit: 2, offset: 2)
        XCTAssertEqual(page1, [c.id, b.id], "newest first")
        XCTAssertEqual(page2, [a.id], "second page completes the thread")
        XCTAssertTrue(Set(page1).isDisjoint(with: Set(page2)))

        // ArchiveDataService thread read path returns summaries for the page.
        let ftsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailin-fts-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: ftsDir) }
        let svc = ArchiveDataService(
            repository: EmailStoreRepository(store: store, fts: FTSSearchIndex(shardsDirectory: ftsDir))
        )
        let summaries = try await svc.threadSummaries(threadKey: "<a@t>", limit: 10, offset: 0, threads: threads)
        XCTAssertEqual(Set(summaries.map(\.id)), Set([a.id, b.id, c.id]), "thread summaries = exactly the members")
        XCTAssertTrue(summaries.allSatisfy { $0.bodyPreview.count <= 400 }, "summaries, not full bodies")
    }

    // MARK: - Part K — predictive record persistence

    /// Labels (+ compact features) and model scores persist independently:
    /// a scoring pass must never clobber a human label, and the paged read
    /// returns scored records highest-first with version stamps intact.
    func testPredictiveRecordPersistenceAndPagedRead() async throws {
        let store = makeTempStore()
        let labeled = UUID()
        let scoredOnly = UUID()
        let low = UUID()

        try await store.predictiveUpsertLabels([
            SQLiteEmailStore.PredictiveRecordRow(
                emailID: labeled, label: 1,
                features: #"{"budget":0.91,"deadline":0.44}"#,
                modelVersion: 1, featureVersion: 1, corpusRevision: 7
            )
        ])

        // Scoring pass covers all three — must preserve the human label/features.
        try await store.predictiveUpsertScores(
            [labeled: 0.95, scoredOnly: 0.6, low: 0.1],
            modelVersion: 1, featureVersion: 1, corpusRevision: 7
        )

        let rows = try await store.predictiveFetch(ids: [labeled, scoredOnly, low])
        XCTAssertEqual(rows[labeled]?.label, 1, "score upsert must not clobber the human label")
        XCTAssertEqual(rows[labeled]?.features, #"{"budget":0.91,"deadline":0.44}"#, "compact features preserved")
        XCTAssertEqual(rows[labeled]?.score, 0.95)
        XCTAssertNil(rows[scoredOnly]?.label, "unlabeled row stays unlabeled")
        XCTAssertEqual(rows[scoredOnly]?.score, 0.6)
        XCTAssertEqual(rows[labeled]?.modelVersion, 1)
        XCTAssertEqual(rows[labeled]?.featureVersion, 1)
        XCTAssertEqual(rows[labeled]?.corpusRevision, 7)

        // Re-labeling flips the label without losing the score.
        try await store.predictiveUpsertLabels([
            SQLiteEmailStore.PredictiveRecordRow(
                emailID: labeled, label: 0, features: nil,
                modelVersion: 1, featureVersion: 1, corpusRevision: 7
            )
        ])
        let relabeled = try await store.predictiveFetch(ids: [labeled])[labeled]
        XCTAssertEqual(relabeled?.label, 0)
        XCTAssertEqual(relabeled?.score, 0.95, "label upsert must not clobber the model score")

        // Paged read: highest score first, bounded pages, no overlap.
        let page1 = try await store.predictivePage(limit: 2, offset: 0)
        let page2 = try await store.predictivePage(limit: 2, offset: 2)
        XCTAssertEqual(page1.map(\.score), [0.95, 0.6], "ordered by score desc")
        XCTAssertEqual(page2.map(\.score), [0.1])
        XCTAssertTrue(Set(page1.map(\.emailID)).isDisjoint(with: Set(page2.map(\.emailID))))

        let labeledRows = try await store.predictiveLabeled()
        XCTAssertEqual(labeledRows.map(\.emailID), [labeled], "labeled() returns exactly the human-labeled rows")
        let total = try await store.predictiveCount()
        XCTAssertEqual(total, 3)
    }

    // MARK: - Part M — near-duplicate finding persistence + paged read

    /// Findings replace wholesale with algorithm-version + corpus-revision
    /// stamps; group pages are ordered largest-first, disjoint, and members
    /// hydrate per group with representative flag + similarity intact.
    func testNearDuplicateFindingsPersistAndPage() async throws {
        let store = makeTempStore()

        func group(_ key: String, members: Int, similarity: Double) -> [SQLiteEmailStore.NearDupMemberRow] {
            (0..<members).map { i in
                SQLiteEmailStore.NearDupMemberRow(
                    groupKey: key, emailID: UUID(),
                    isRepresentative: i == 0, similarity: similarity
                )
            }
        }
        let g1 = group("g1", members: 4, similarity: 0.97)   // largest
        let g2 = group("g2", members: 3, similarity: 0.88)
        let g3 = group("g3", members: 2, similarity: 0.81)

        try await store.nearDuplicatesReplace(g1 + g2 + g3, algoVersion: 1, corpusRevision: 5)

        let count = try await store.nearDuplicateGroupCount()
        XCTAssertEqual(count, 3)
        let meta = try await store.nearDuplicateMeta()
        XCTAssertEqual(meta.algoVersion, 1)
        XCTAssertEqual(meta.corpusRevision, 5)

        // Pages: largest group first, disjoint, complete.
        let page1 = try await store.nearDuplicateGroupKeysPage(limit: 2, offset: 0)
        let page2 = try await store.nearDuplicateGroupKeysPage(limit: 2, offset: 2)
        XCTAssertEqual(page1, ["g1", "g2"], "largest groups first")
        XCTAssertEqual(page2, ["g3"])
        XCTAssertTrue(Set(page1).isDisjoint(with: Set(page2)))

        // Members hydrate exactly, with representative + similarity intact.
        let members = try await store.nearDuplicateMembers(groupKeys: ["g1"])
        XCTAssertEqual(members.count, 4)
        XCTAssertEqual(members.filter(\.isRepresentative).count, 1, "exactly one representative per group")
        XCTAssertTrue(members.allSatisfy { $0.similarity == 0.97 })
        XCTAssertEqual(Set(members.map(\.emailID)), Set(g1.map(\.emailID)))

        // Replace semantics: a re-analysis supersedes the old findings set.
        try await store.nearDuplicatesReplace(group("h1", members: 2, similarity: 0.9), algoVersion: 2, corpusRevision: 6)
        let newCount = try await store.nearDuplicateGroupCount()
        XCTAssertEqual(newCount, 1, "replace supersedes previous findings")
        let newMeta = try await store.nearDuplicateMeta()
        XCTAssertEqual(newMeta.algoVersion, 2)
        XCTAssertEqual(newMeta.corpusRevision, 6)
        let gone = try await store.nearDuplicateMembers(groupKeys: ["g1"])
        XCTAssertTrue(gone.isEmpty, "old groups removed")
    }

    // MARK: - Corpus-revision reconcile (cache invalidation for bulk import)

    /// The count-based reconcile bumps the revision exactly when the row count
    /// changed (bulk import writes to the store without bumping), and is a
    /// no-op otherwise — so persisted findings invalidate on import but not on
    /// every read.
    func testCorpusRevisionReconcileBumpsOnlyOnCountChange() async throws {
        let store = makeTempStore()
        let fixtures = (0..<3).map { makeEmail(mid: "<rc-\($0)@t>", subject: "S\($0)", body: "b \($0)", dayOffset: $0) }
        try await store.insertBatch(fixtures, batchSize: 100)

        let r1 = try await store.reconcileCorpusRevisionWithCount()
        let r2 = try await store.reconcileCorpusRevisionWithCount()
        XCTAssertEqual(r1, r2, "no content change → no bump")

        // Simulate a bulk import (store insert without an explicit bump).
        try await store.insertBatch([makeEmail(mid: "<rc-new@t>", subject: "New", body: "new", dayOffset: 9)], batchSize: 100)
        let r3 = try await store.reconcileCorpusRevisionWithCount()
        XCTAssertGreaterThan(r3, r2, "count change → revision bump (stale caches detectable)")
        let r4 = try await store.reconcileCorpusRevisionWithCount()
        XCTAssertEqual(r4, r3, "idempotent once observed")
    }
}
