//
//  ArchiveDerivedState.swift
//  maxmailin
//
//  Stage 5 Wave 2A (v2-core-cutover): the shared derived-data platform so
//  expensive per-email analysis (sentiment, classification, topic, thread,
//  predictive score, smart tags, …) is COMPUTED ONCE, persisted by email id,
//  and read back cheaply — instead of every sheet re-walking the whole corpus.
//
//    • ArchiveCorpusRevision — a durable monotonically increasing revision that
//      bumps on content-affecting mutations (import / delete / redaction). Each
//      derived record records the revision that produced it, so stale analysis
//      is detectable and never silently presented as current.
//    • ArchiveDerivedStateStore — persist/fetch/stale-scan/delete derived state.
//    • ArchiveBackgroundJobRunner — run a bounded analysis job over a query:
//      stream page → compute → persist → checkpoint → release, cancellable and
//      resumable, not tied to a screen staying open.
//

import Foundation

struct DerivedRecord: Sendable, Equatable {
    let emailID: EmailID
    var corpusRevision: Int = 0
    var analysisVersion: Int = 0
    var sentiment: String? = nil
    var classification: String? = nil
    var priority: Int? = nil
    var phishing: Bool? = nil
    var topic: String? = nil
    var threadID: String? = nil
    var predictiveScore: Double? = nil
    var smartTags: [String] = []
    var updatedAt: Int = 0
}

// MARK: - Corpus revision

@MainActor
final class ArchiveCorpusRevision {
    static let shared = ArchiveCorpusRevision(store: .shared)
    private let store: SQLiteEmailStore
    init(store: SQLiteEmailStore) { self.store = store }

    func current() async throws -> Int { try await store.corpusRevision() }

    /// Bump after a content-affecting change (import / delete / redaction).
    @discardableResult
    func bump() async throws -> Int { try await store.bumpCorpusRevision() }

    /// Current revision, after reconciling with the store's row count — so an
    /// import path that doesn't bump explicitly still moves the revision, and
    /// stale derived state is detected (two O(1) aggregates).
    @discardableResult
    func reconciled() async throws -> Int { try await store.reconcileCorpusRevisionWithCount() }
}

// MARK: - Derived state store

@MainActor
final class ArchiveDerivedStateStore {
    static let shared = ArchiveDerivedStateStore(store: .shared)
    private let store: SQLiteEmailStore
    init(store: SQLiteEmailStore) { self.store = store }

    func upsert(_ records: [DerivedRecord]) async throws { try await store.derivedUpsert(records) }
    func fetch(ids: [EmailID]) async throws -> [EmailID: DerivedRecord] { try await store.derivedFetch(ids: ids) }
    func staleIDs(below revision: Int, minAnalysisVersion: Int = 0, limit: Int) async throws -> [EmailID] {
        try await store.derivedStaleIDs(below: revision, minAnalysisVersion: minAnalysisVersion, limit: limit)
    }
    func count() async throws -> Int { try await store.derivedCount() }
    func delete(ids: Set<EmailID>) async throws { try await store.derivedDelete(ids: ids) }
    /// Partial update (Part J): persist ONLY topic assignments, preserving every
    /// other derived field another producer wrote.
    func setTopics(_ topics: [EmailID: String]) async throws { try await store.derivedSetTopics(topics) }
}

// MARK: - Background job runner

/// Runs a bounded, resumable analysis job: pull the stale work-list in bounded
/// pages, compute derived records for each page, persist, and repeat. Bounded
/// memory (one page resident), cancellable, progress-reporting.
@MainActor
final class ArchiveBackgroundJobRunner: ObservableObject {
    enum State: Equatable { case idle, running, completed, cancelled, failed(String) }

    @Published private(set) var state: State = .idle
    @Published private(set) var processed = 0
    @Published private(set) var total = 0

    private let store: SQLiteEmailStore
    private let derived: ArchiveDerivedStateStore
    private let revision: ArchiveCorpusRevision
    private var task: Task<Void, Never>?

    init(store: SQLiteEmailStore = .shared) {
        self.store = store
        self.derived = ArchiveDerivedStateStore(store: store)
        self.revision = ArchiveCorpusRevision(store: store)
    }

    /// `compute` receives one bounded batch of full emails at the current corpus
    /// revision and returns their derived records. Runs until no stale ids remain.
    @discardableResult
    func run(batchSize: Int = 300,
             compute: @escaping @Sendable ([MBOXParser.RawEmail], Int) -> [DerivedRecord]) async -> State {
        await run(batchSize: batchSize, minAnalysisVersion: 0) { emails, _, rev in
            compute(emails, rev)
        }
    }

    /// Version- and merge-aware variant (Parts I/K): records whose
    /// `analysis_version` is below `minAnalysisVersion` are treated as stale, so
    /// bumping the producer's version constant triggers an incremental
    /// recompute. `compute` also receives the EXISTING derived records for the
    /// batch so producers can merge (preserve fields another producer — topics,
    /// thread ids, predictive scores — persisted). Async so on-device model
    /// engines can be awaited per bounded batch.
    ///
    /// `staleBelowRevision: false` makes the work list purely
    /// missing-or-version-bumped — the incremental mode for per-email
    /// content-derived attributes, which don't change when OTHER emails are
    /// imported (already-computed EmailIDs are skipped).
    @discardableResult
    func run(batchSize: Int = 300,
             minAnalysisVersion: Int,
             staleBelowRevision: Bool = true,
             compute: @escaping @Sendable ([MBOXParser.RawEmail], [EmailID: DerivedRecord], Int) async -> [DerivedRecord]) async -> State {
        cancel()
        state = .running
        processed = 0
        do {
            let rev = try await revision.current()
            total = try await store.totalCount()
            while true {
                if Task.isCancelled { state = .cancelled; return state }
                let ids = try await store.derivedStaleIDs(
                    below: staleBelowRevision ? rev : 0,
                    minAnalysisVersion: minAnalysisVersion, limit: batchSize
                )
                if ids.isEmpty { break }
                let emails = try await store.emails(withIDs: ids)
                let existing = try await derived.fetch(ids: ids)
                let records = await compute(emails, existing, rev)
                // Ensure each record carries the revision it was computed at.
                let stamped = records.map { r -> DerivedRecord in
                    var r = r; if r.corpusRevision == 0 { r.corpusRevision = rev }; return r
                }
                // Guard against a compute that fails to stamp the version: an
                // unstamped record would stay "stale" forever and loop.
                let versionSafe = stamped.map { r -> DerivedRecord in
                    var r = r
                    if r.analysisVersion < minAnalysisVersion { r.analysisVersion = minAnalysisVersion }
                    return r
                }
                // If compute returned nothing for some ids, still mark them
                // processed (placeholder record) so the job can't spin forever.
                let returnedIDs = Set(versionSafe.map(\.emailID))
                let placeholders = ids.filter { !returnedIDs.contains($0) }.map { id -> DerivedRecord in
                    var r = existing[id] ?? DerivedRecord(emailID: id)
                    r.corpusRevision = rev
                    r.analysisVersion = minAnalysisVersion
                    return r
                }
                try await derived.upsert(versionSafe + placeholders)
                processed += ids.count
            }
            state = .completed
        } catch {
            state = .failed(error.localizedDescription)
        }
        return state
    }

    func cancel() { task?.cancel(); task = nil }
}
