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
            // Opening either store here also validates it can be opened; a
            // failure to open the destination is caught below as `.failed`.
            let sourceCount = try await source.totalCount()
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

    /// Integrity gate: the destination must hold ≥ `expected` rows AND a brand
    /// new SQLite connection over the same files must open and report the same
    /// count — proving the data is durably on disk, not just in a cache/WAL of
    /// the working handle. Only then is `.active` persisted.
    private func verifyAndActivate(expected: Int) async throws -> State {
        let destCount = try await dest.totalCount()
        guard destCount >= expected else {
            store(.failed)
            return .failed
        }
        // Reopen with a fresh instance at the same directory.
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
