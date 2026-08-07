//
//  StorageActivationCoordinator.swift
//  maxmailin
//
//  Stage 5A (v2-core-cutover): the single source of truth for *which* store is
//  the production authority, and the gate that makes SQLite that authority
//  deterministically at startup — before any archive read or write begins.
//
//  Rules enforced (see the Stage 5 plan):
//    • Migration (SwiftData → SQLite) runs before normal reads/writes.
//    • SwiftData is a READ-ONLY migration source; it is never mutated or
//      deleted here (retained as rollback evidence).
//    • The `active` marker is set ONLY after the count/integrity gate passes and
//      a FRESH SQLite connection reopens and agrees — so a failed or partial
//      migration can never expose a half-populated archive as authoritative.
//    • No dual-write, no "read SQLite else silently fall back to SwiftData":
//      callers gate on `isActive`; until it is true, import is blocked and the
//      cutover read paths (Stage 5D) do not switch.
//
//  Durable states: notRequired · required · copying · verifying · active · failed.
//

import Foundation
import os.log

private let activationLog = Logger(subsystem: "com.ecosanskriti.mailin", category: "StorageActivation")

actor StorageActivationCoordinator {

    enum State: String, Sendable, Equatable {
        case notRequired   // fresh install / empty source — SQLite is authority
        case required      // migration needed, not yet started
        case copying       // migration in progress
        case verifying     // count + reopen integrity gate running
        case active        // SQLite is the confirmed authority
        case failed        // gate/migration failed — authority NOT switched
    }

    private let source: EmailStore
    private let dest: SQLiteEmailStore
    private let defaults: UserDefaults
    private let stateKey: String

    init(
        source: EmailStore,
        dest: SQLiteEmailStore,
        defaults: UserDefaults = .standard,
        stateKey: String = "mailin.storage.activation.state"
    ) {
        self.source = source
        self.dest = dest
        self.defaults = defaults
        self.stateKey = stateKey
    }

    /// The production coordinator: SwiftData `EmailStore.shared` → SQLite
    /// `SQLiteEmailStore.shared`.
    static let shared = StorageActivationCoordinator(source: .shared, dest: .shared)

    // MARK: - Persisted state

    private func loadState() -> State? {
        defaults.string(forKey: stateKey).flatMap(State.init(rawValue:))
    }
    private func store(_ s: State) {
        defaults.set(s.rawValue, forKey: stateKey)
        activationLog.info("storage activation → \(s.rawValue, privacy: .public)")
    }

    /// The last persisted state (nil if never run). Cheap; no store access.
    var persistedState: State? { loadState() }

    /// True only when SQLite is the confirmed production authority. Import and
    /// the Stage 5D read cutover gate on this.
    var isActive: Bool { loadState() == .active }

    // MARK: - Activation

    /// Idempotent. Drives the state machine to `.active` (or `.failed`) and
    /// returns the resulting state. Safe to call on every launch — once
    /// `.active` and still consistent, it is a fast no-op.
    @discardableResult
    func activate() async -> State {
        do {
            // §11.3 tombstone: after a user-initiated archive clear, legacy
            // SwiftData rows must NEVER re-migrate — old data may not
            // resurrect into a deliberately emptied archive.
            let tombstoned = defaults.bool(forKey: ArchiveLifecycleService.migrationTombstoneKey)

            // Opening either store here also validates it can be opened; a
            // failure to open the destination is caught below as `.failed`.
            let sourceCount = tombstoned ? 0 : (try await source.totalCount())
            let destCount = try await dest.totalCount()

            // Fast path: already active AND still consistent (dest holds at
            // least the source's rows). If the marker is active but the dest is
            // short (rollback / corruption), fall through and re-migrate.
            if loadState() == .active, destCount >= sourceCount {
                return .active
            }

            // Fresh install / empty (or cleared) source — nothing to migrate;
            // SQLite is authority as soon as it opens.
            if sourceCount == 0 {
                store(.notRequired)
                store(.active)
                return .active
            }

            // Destination already holds everything (marker was absent/stale) —
            // just re-verify and activate.
            if destCount >= sourceCount {
                store(.verifying)
                return try await verifyAndActivate(expected: sourceCount)
            }

            // Migration needed: copy (bounded, resumable, non-destructive).
            store(.required)
            store(.copying)
            let result = try await MailinStoreMigration.migrate(
                from: source, to: dest, markCompleteFlag: false
            )
            guard result.completed else {
                store(.failed)
                activationLog.error("migration incomplete: copied \(result.copied), dest \(result.destCount)/\(result.sourceCount)")
                return .failed
            }
            store(.verifying)
            return try await verifyAndActivate(expected: sourceCount)
        } catch {
            store(.failed)
            activationLog.error("activation failed: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
    }

    /// §10 content-identity gate — count alone is NOT enough. Activation
    /// requires, in order:
    ///   1. destCount ≥ expected;
    ///   2. EXACT ID coverage: every source id exists in the destination
    ///      (bounded (id,date) keyset walk — ids only, never bodies);
    ///   3. sampled content fidelity: first/last source pages' subjects,
    ///      bodies and attachment counts match after hydration;
    ///   4. `PRAGMA integrity_check` == "ok";
    ///   5. a brand-new SQLite connection over the same files reopens and
    ///      reports the same count (durability, not cache/WAL illusion).
    /// Only then is `.active` persisted.
    private func verifyAndActivate(expected: Int) async throws -> State {
        let destCount = try await dest.totalCount()
        guard destCount >= expected else {
            store(.failed)
            return .failed
        }

        // 2. Exact source-ID coverage (skip when the source is empty/tombstoned).
        if expected > 0 {
            var beforeDate: Date? = nil
            var beforeID: UUID? = nil
            var missing = 0
            var firstPageIDs: [UUID] = []
            var lastPageIDs: [UUID] = []
            while true {
                let page = try await source.reconcilePage(beforeDate: beforeDate, beforeID: beforeID, limit: 1_000)
                if page.isEmpty { break }
                let ids = page.map(\.id)
                if firstPageIDs.isEmpty { firstPageIDs = Array(ids.prefix(3)) }
                lastPageIDs = Array(ids.suffix(3))
                let present = try await dest.existingIDs(among: ids)
                missing += ids.count - present.count
                beforeDate = page.last!.date
                beforeID = page.last!.id
                if page.count < 1_000 { break }
            }
            guard missing == 0 else {
                store(.failed)
                activationLog.error("identity gate: \(missing) source ids absent from destination")
                return .failed
            }

            // 3. Sampled content fidelity (bounded: ≤6 emails hydrated).
            for id in Set(firstPageIDs + lastPageIDs) {
                guard let src = try await source.fullEmail(id: id),
                      let dst = try await dest.fullEmail(id: id) else {
                    store(.failed)
                    activationLog.error("identity gate: sample \(id, privacy: .public) unreadable")
                    return .failed
                }
                guard dst.plainBody == src.plainBody,
                      dst.headers["Subject"] == src.headers["Subject"],
                      dst.attachments.count >= src.attachments.count else {
                    store(.failed)
                    activationLog.error("identity gate: content mismatch for \(id, privacy: .public)")
                    return .failed
                }
            }
        }

        // 4. Database health.
        let health = try await dest.integrityCheck()
        guard health == "ok" else {
            store(.failed)
            activationLog.error("integrity_check failed: \(health, privacy: .public)")
            return .failed
        }

        // 5. Fresh-connection durability gate.
        let reopened = SQLiteEmailStore(directory: dest.storeDirectory)
        let reopenedCount = try await reopened.totalCount()
        guard reopenedCount == destCount else {
            store(.failed)
            activationLog.error("reopen gate mismatch: \(reopenedCount) != \(destCount)")
            return .failed
        }
        store(.active)
        return .active
    }

    #if DEBUG
    func resetForTesting() { defaults.removeObject(forKey: stateKey) }
    #endif
}
