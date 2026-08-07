//
//  EmailArchiveStore.swift
//  maxmailin
//
//  Stage 4B (v2-core-cutover): the bounded canonical-store contract, extracted
//  so the storage engine can be swapped behind `EmailRepository` WITHOUT
//  touching the UI. `EmailStore` (SwiftData) and `SQLiteEmailStore` (direct
//  SQLite/blob) both satisfy it; the stress harness proved SwiftData's import
//  is O(N²) and its keyset paging O(N) on the shipping deployment target
//  (no expressible secondary indexes), so the SQLite engine — which can
//  `CREATE INDEX` freely — becomes the production store (see
//  V2_STORAGE_DECISION.md).
//
//  Every method is a page / batch / single-record boundary — never the whole
//  corpus — so resident memory stays bounded regardless of archive size.
//

import Foundation

/// §4: the user-facing duplicate policy, decided at the import entry point —
/// never inferred deep inside SQLite.
///   preserveAll                      → dedup_key = NULL (every occurrence kept)
///   messageID                        → normalized Message-ID, NULL if missing
///   messageIDOrCanonicalFingerprint  → Message-ID, else a deterministic
///                                      fingerprint of From|To|Date|Subject|body hash
enum DedupPolicy: String, Sendable, Codable {
    case preserveAll
    case messageID
    case messageIDOrCanonicalFingerprint
}

/// §5.3: structured outcome of a store insert — the coordinator indexes ONLY
/// `insertedIDs` into FTS, so a deduped/reinserted row can never become a
/// ghost search hit.
struct BatchInsertResult: Sendable {
    var attempted = 0
    /// Rows actually written this call (new canonical emails).
    var insertedIDs: [UUID] = []
    /// Rows skipped because the same (source_id, source_ordinal) occurrence is
    /// already stored — crash-resume / repeated parse of the same source.
    var existingSourceOccurrenceIDs: [UUID] = []
    /// Rows skipped by the dedup policy (recorded as duplicate findings).
    var duplicateIDs: [UUID] = []
}

protocol EmailArchiveStore: Sendable {
    /// Persist a batch. Idempotent on non-empty Message-ID (duplicates skipped),
    /// committed in chunks of `batchSize`.
    func insertBatch(
        _ emails: [MBOXParser.RawEmail],
        sourceFileHash: String?,
        accountID: String?,
        batchSize: Int,
        progress: ((Int, Int) -> Void)?
    ) async throws

    func totalCount() async throws -> Int
    func count(after: Date?, before: Date?) async throws -> Int

    /// Keyset page (`date DESC, id DESC`) of lightweight summaries — no bodies —
    /// with optional `after ≤ date < before` bounds applied in the DB.
    func summaryPage(
        after: Date?, before: Date?, cursorDate: Date?, cursorID: UUID?, limit: Int
    ) async throws -> [EmailSummary]

    func summaries(ids: [UUID]) async throws -> [EmailSummary]
    func existingIDs(among ids: [UUID]) async throws -> Set<UUID>
    func emails(withIDs ids: [UUID]) async throws -> [MBOXParser.RawEmail]
    func fullEmail(id: UUID) async throws -> MBOXParser.RawEmail?
    func delete(ids: Set<UUID>) async throws

    /// Keyset page of (id, date) only — the bounded reconcile walk.
    func reconcilePage(beforeDate: Date?, beforeID: UUID?, limit: Int) async throws -> [(id: UUID, date: Date)]

    func clearAll() async throws
}

extension EmailArchiveStore {
    /// Convenience used by the harness / callers that don't need custody or
    /// progress plumbing.
    func insertBatch(_ emails: [MBOXParser.RawEmail], batchSize: Int = 500) async throws {
        try await insertBatch(emails, sourceFileHash: nil, accountID: nil, batchSize: batchSize, progress: nil)
    }
}

// EmailStore already exposes exactly this surface (its actor-isolated
// synchronous methods witness the async requirements).
extension EmailStore: EmailArchiveStore {}
