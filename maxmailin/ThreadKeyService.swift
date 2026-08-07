//
//  ThreadKeyService.swift
//  maxmailin
//
//  Part L (v2-core-cutover): persisted thread relationships. A stable thread
//  key is derived per email from Message-ID / In-Reply-To / References
//  (normalized-subject fallback at lower confidence), computed as a bounded
//  background backfill over header columns only (no bodies hydrated), and
//  persisted to the indexed `thread_keys` table in SQLiteEmailStore.
//
//  Query path: threadKey → paginated summaries via ArchiveDataService. The
//  legacy list's visible-page grouping (ThreadGrouper over the resident page)
//  stays as-is — it is bounded; archive-wide thread views read this persisted
//  mapping instead of runtime-grouping the archive.
//

import Foundation

// MARK: - Derivation

struct ThreadKeyDeriver {

    enum Confidence: Int, Sendable {
        /// Derived from RFC-5322 reference headers (References / In-Reply-To /
        /// Message-ID) — authoritative.
        case high = 2
        /// Normalized-subject fallback — heuristic, lower confidence.
        case subjectFallback = 1
        /// No usable signal — the email is its own singleton thread.
        case singleton = 0
    }

    /// Stable thread key for one email. Semantics intentionally match
    /// `MBOXParser.detectThreadID` (References root → In-Reply-To → own
    /// Message-ID) so persisted keys agree with the legacy grouper's
    /// `threadID`-first behavior; the subject fallback matches
    /// `ThreadGrouper.normalizedThreadKey`.
    static func derive(
        messageID: String?,
        inReplyTo: String?,
        references: String?,
        subject: String?,
        emailID: EmailID
    ) -> (key: String, confidence: Confidence) {
        if let root = firstReference(in: references) {
            return (root, .high)
        }
        if let reply = normalizedToken(inReplyTo) {
            return (reply, .high)
        }
        if let mid = normalizedToken(messageID) {
            return (mid, .high)
        }
        let normalizedSubject = ThreadGrouper.normalizeSubject(subject ?? "")
        if !normalizedSubject.isEmpty {
            return ("subj:" + normalizedSubject.lowercased(), .subjectFallback)
        }
        return ("single:" + emailID.uuidString, .singleton)
    }

    /// The FIRST id in the References chain is the thread root.
    private static func firstReference(in references: String?) -> String? {
        guard let references, !references.isEmpty else { return nil }
        let tokens = references
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return tokens.first
    }

    private static func normalizedToken(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Backfill + query service

/// Bounded backfill of persisted thread keys and the indexed thread → members
/// query path. Backfill reads header columns only (no body blobs) and keeps
/// one page resident at a time.
@MainActor
final class ArchiveThreadService {
    static let shared = ArchiveThreadService(store: .shared)

    private let store: SQLiteEmailStore
    private var backfillTask: Task<Void, Never>?

    init(store: SQLiteEmailStore) { self.store = store }

    /// Derive + persist thread keys for every email that doesn't have one yet.
    /// Bounded batches (100–500), resumable (the work list is a LEFT JOIN on
    /// missing rows, so interruption loses nothing). Returns rows written.
    @discardableResult
    func backfillThreadKeys(batchSize: Int = 500) async throws -> Int {
        let size = max(100, min(500, batchSize))
        var written = 0
        while !Task.isCancelled {
            let page = try await store.threadKeyMissingPage(limit: size)
            if page.isEmpty { break }
            let rows = page.map { source -> SQLiteEmailStore.ThreadKeyRow in
                let (key, confidence) = ThreadKeyDeriver.derive(
                    messageID: source.messageID,
                    inReplyTo: source.inReplyTo,
                    references: source.references,
                    subject: source.subject,
                    emailID: source.id
                )
                return SQLiteEmailStore.ThreadKeyRow(emailID: source.id, threadKey: key, confidence: confidence.rawValue)
            }
            try await store.threadKeysUpsert(rows)
            written += rows.count
        }
        return written
    }

    /// Fire-and-forget incremental kick (no-op when fully backfilled).
    func kickBackfill() {
        guard backfillTask == nil else { return }
        backfillTask = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = try? await self.backfillThreadKeys()
            self.backfillTask = nil
        }
    }

    func threadKey(for id: EmailID) async throws -> String? {
        try await store.threadKey(for: id)?.threadKey
    }

    /// Member ids of a thread, newest first, paginated (indexed seek).
    func emailIDs(inThread threadKey: String, limit: Int = 200, offset: Int = 0) async throws -> [EmailID] {
        try await store.threadEmailIDs(threadKey: threadKey, limit: limit, offset: offset)
    }
}

// MARK: - ArchiveDataService query path (Part L)

extension ArchiveDataService {
    /// Paginated lightweight summaries for a persisted thread key — the
    /// bounded read path archive-wide thread views use instead of grouping the
    /// whole archive at runtime.
    func threadSummaries(
        threadKey: String,
        limit: Int = 200,
        offset: Int = 0,
        threads: ArchiveThreadService = .shared
    ) async throws -> [EmailSummary] {
        let ids = try await threads.emailIDs(inThread: threadKey, limit: limit, offset: offset)
        return try await summaries(ids: ids)
    }
}
