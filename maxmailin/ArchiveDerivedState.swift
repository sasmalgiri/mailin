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
}

// MARK: - Derived state store

@MainActor
final class ArchiveDerivedStateStore {
    static let shared = ArchiveDerivedStateStore(store: .shared)
    private let store: SQLiteEmailStore
    init(store: SQLiteEmailStore) { self.store = store }

    func upsert(_ records: [DerivedRecord]) async throws { try await store.derivedUpsert(records) }
    func fetch(ids: [EmailID]) async throws -> [EmailID: DerivedRecord] { try await store.derivedFetch(ids: ids) }
    func staleIDs(below revision: Int, limit: Int) async throws -> [EmailID] { try await store.derivedStaleIDs(below: revision, limit: limit) }
    func count() async throws -> Int { try await store.derivedCount() }
    func delete(ids: Set<EmailID>) async throws { try await store.derivedDelete(ids: ids) }
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
        cancel()
        state = .running
        processed = 0
        do {
            let rev = try await revision.current()
            total = try await store.totalCount()
            while true {
                if Task.isCancelled { state = .cancelled; return state }
                let ids = try await store.derivedStaleIDs(below: rev, limit: batchSize)
                if ids.isEmpty { break }
                let emails = try await store.emails(withIDs: ids)
                let records = compute(emails, rev)
                // Ensure each record carries the revision it was computed at.
                let stamped = records.map { r -> DerivedRecord in
                    var r = r; if r.corpusRevision == 0 { r.corpusRevision = rev }; return r
                }
                try await derived.upsert(stamped)
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
