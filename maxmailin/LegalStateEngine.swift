@testable import ArchiveCore
//
//  LegalStateEngine.swift
//  maxmailin
//
//  §3-F4 (switch: `v3LegalState`). Legal holds, evidence seals, custodian
//  assignments and custody events move into the archive database — fast bulk
//  updates, store-level hold enforcement on delete, whole-archive totals in
//  one query — while the previous files stay up to date as a second copy for
//  the whole of 3.0 (dual-write). Switching the engine off loses nothing:
//  the files were never stopped.
//
//  Turning on: a snapshot is taken (the switch requires `v3Snapshots`), the
//  existing files are copied into the database once, and the counts are
//  verified; a mismatch is logged and the engine keeps the files as the
//  source of truth.
//

import Foundation
import os

private let legalStateLog = Logger(subsystem: "com.ecosanskriti.maxmailin", category: "LegalState")

@MainActor
final class LegalStateMirror {
    /// The app's mirror over the app's legal files.
    static let shared = LegalStateMirror(manager: nil, events: { ChainOfCustodyManager.shared.events })

    /// Pushed by CapabilityWiring (the `v3LegalState` switch, app mirror).
    nonisolated(unsafe) static var isEnabled = false

    /// The manager whose files this mirror keeps level with the database.
    private weak var ownManager: CustodianManager?
    private var manager: CustodianManager { ownManager ?? .shared }
    private let events: @MainActor () -> [CustodyEvent]
    /// A disposable mirror's own switch (tests); the app mirror reads `isEnabled`.
    var enabledOverride: Bool?

    /// Whether this mirror's engine switch is on.
    var isOn: Bool { enabledOverride ?? Self.isEnabled }

    /// What the database is known to contain (the last synced copy).
    private var syncedHolds: Set<UUID> = []
    private var syncedSeals: [UUID: String] = [:]
    private var syncedCustodians: [UUID: String] = [:]
    private var syncedEventIDs: Set<UUID> = []
    private var active = false
    private var pending: Task<Void, Never>?

    private(set) var lastVerification: String?

    /// - Parameters:
    ///   - manager: the files' manager (nil = `CustodianManager.shared`).
    ///   - events: custody events to mirror.
    init(manager: CustodianManager?, events: @escaping @MainActor () -> [CustodyEvent] = { [] }) {
        ownManager = manager
        self.events = events
        manager?.mirrorTarget = self
    }

    // MARK: Markers (beside the manager's files, not in app settings)

    private var migratedMarker: URL { manager.directory.appendingPathComponent("legal_state_v3.migrated") }
    /// Present while a job is writing legal rows straight into the database
    /// and the files have not received them yet (rule 16).
    private var pendingMarker: URL { manager.directory.appendingPathComponent("legal_state_v3.pending_db_write") }

    /// Call before writing legal rows directly into the database.
    func beginDatabaseWrite() {
        try? Data().write(to: pendingMarker, options: .atomic)
    }

    /// Call once the files hold the result of the direct database write.
    func endDatabaseWrite() {
        try? FileManager.default.removeItem(at: pendingMarker)
    }

    var hasPendingDatabaseWrite: Bool { FileManager.default.fileExists(atPath: pendingMarker.path) }

    /// Run at launch whatever the switch: if a direct database write was
    /// interrupted (quit, crash), the rows it wrote are added to the files —
    /// never removing anything — so switching the engine off or on loses no
    /// hold, seal or custodian. Returns how many rows were recovered.
    @discardableResult
    func recoverInterruptedDatabaseWrite() async -> Int {
        guard hasPendingDatabaseWrite else { return 0 }
        let store = ScopeJobEnvironment.store
        do {
            let added = manager.absorbDatabaseAdditions(
                holds: try await store.legalHoldIDs(),
                seals: try await store.allSeals(),
                custodians: try await store.allCustodianAssignments())
            endDatabaseWrite()
            if added > 0 {
                ScopeJobEnvironment.logAction("Legal data recovered after an interrupted job",
                                                 detail: "\(added) holds, seals or custodian assignments written to the database before the interruption were added to the legal files")
            }
            return added
        } catch {
            legalStateLog.error("legal state recovery failed: \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }

    /// Brings the database level with the files, then verifies. Idempotent;
    /// after `deactivate()` it re-reads the database and re-verifies.
    ///
    /// The files are written on every change whether or not this engine is
    /// on, so they are the truth at activation: the database is loaded as
    /// the "synced" copy and the difference is written into it. (Pulling the
    /// database into the files here would resurrect a hold released while the
    /// engine was off.) An interrupted direct write is recovered first. The
    /// first activation takes a snapshot first.
    func activate() async {
        guard isOn, !active else { return }
        await recoverInterruptedDatabaseWrite()
        let store = ScopeJobEnvironment.store
        let manager = self.manager
        do {
            let first = !FileManager.default.fileExists(atPath: migratedMarker.path)
            if first { _ = try? await store.snapshot(reason: "before-legal-state-migration") }
            syncedHolds = try await store.legalHoldIDs()
            syncedSeals = try await store.allSeals()
            syncedCustodians = try await store.allCustodianAssignments()
            syncedEventIDs = []   // INSERT OR IGNORE: re-sending is harmless
            active = true
            await syncNow()

            // Verify: the database now holds exactly what the files hold.
            let holdsOK = try await store.legalHoldIDs() == manager.legalHolds
            let sealsOK = try await store.allSeals() == manager.evidenceSeals
            let custodiansOK = try await store.allCustodianAssignments() == manager.custodians
            let counts = try await store.legalStateCounts()
            lastVerification = "holds \(counts.holds)/\(manager.legalHolds.count), seals \(counts.seals)/\(manager.evidenceSeals.count), custodians \(counts.custodians)/\(manager.custodians.count), custody events \(counts.custodyEvents)"
            guard holdsOK, sealsOK, custodiansOK else {
                active = false
                await store.setEnforcesDatabaseLegalHolds(false)
                legalStateLog.error("legal state verification failed: \(self.lastVerification ?? "", privacy: .public)")
                ScopeJobEnvironment.logAction("Legal data move to database not verified",
                                                 detail: (lastVerification ?? "") + " — the files remain the source")
                return
            }
            await store.setEnforcesDatabaseLegalHolds(true)
            // §3-F4: the review workspaces (Legal Review, Journalist) join the
            // database too; their files stay the first copy.
            ReviewWorkspaceStore.mirrorExistingFiles()
            if first {
                try? Data().write(to: migratedMarker, options: .atomic)
                ScopeJobEnvironment.logAction("Legal data copied into the archive database",
                                                 detail: (lastVerification ?? "") + " — verified; files kept as a second copy")
            }
        } catch {
            active = false
            await store.setEnforcesDatabaseLegalHolds(false)
            legalStateLog.error("legal state activation failed: \(error.localizedDescription, privacy: .public)")
            EngineGuard.recordFallback(.v3LegalState, error: error)
        }
    }

    /// The switch went off: the files are the only truth again, and the
    /// database stops refusing deletes on its own. Nothing is removed.
    func deactivate() async {
        pending?.cancel()
        pending = nil
        active = false
        await ScopeJobEnvironment.store.setEnforcesDatabaseLegalHolds(false)
    }

    /// Whether the database copy is live (activated and verified).
    var isActive: Bool { active }

    /// Called from the manager's change hooks; coalesces bursts so a loop of
    /// 100k inserts becomes one batched write.
    func scheduleSync() {
        guard isOn, active else { return }
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    /// Writes the difference between the manager and the database.
    func syncNow() async {
        guard isOn, active else { return }
        let manager = self.manager
        let store = ScopeJobEnvironment.store
        let token = EngineGuard.begin(.v3LegalState)
        defer { EngineGuard.end(token) }
        do {
            let holds = manager.legalHolds
            let addHolds = holds.subtracting(syncedHolds)
            let removeHolds = syncedHolds.subtracting(holds)
            if !addHolds.isEmpty { try await store.legalHoldsAdd(Array(addHolds)) }
            if !removeHolds.isEmpty { try await store.legalHoldsRemove(Array(removeHolds)) }
            syncedHolds = holds

            let seals = manager.evidenceSeals
            // A seal whose value differs was released and re-sealed through
            // the files (the old path removes the seal on release): the
            // files are the truth, so the database row is replaced.
            let resealed = seals.filter { syncedSeals[$0.key] != nil && syncedSeals[$0.key] != $0.value }
            if !resealed.isEmpty { try await store.sealsRemove(Array(resealed.keys)) }
            let newSeals = seals.filter { syncedSeals[$0.key] == nil || resealed[$0.key] != nil }
            let removedSeals = syncedSeals.keys.filter { seals[$0] == nil }
            if !newSeals.isEmpty { try await store.sealsSetOnce(newSeals) }
            if !removedSeals.isEmpty { try await store.sealsRemove(removedSeals) }
            syncedSeals = seals

            let custodians = manager.custodians
            let changed = custodians.filter { syncedCustodians[$0.key] != $0.value }
            let removed = syncedCustodians.keys.filter { custodians[$0] == nil }
            if !changed.isEmpty { try await store.custodiansAssign(changed) }
            if !removed.isEmpty { try await store.custodiansRemove(removed) }
            syncedCustodians = custodians

            let events = self.events().filter { !syncedEventIDs.contains($0.id) }
            if !events.isEmpty {
                try await store.custodyEventsAppend(events.map(Self.eventRow))
                syncedEventIDs.formUnion(events.map(\.id))
            }
        } catch {
            // The files are already written; the database catches up on the
            // next change (the synced copy was not advanced past the failure).
            legalStateLog.error("legal state sync failed: \(error.localizedDescription, privacy: .public)")
            EngineGuard.recordFallback(.v3LegalState, error: error)
        }
    }

    private static func eventRow(_ e: CustodyEvent) -> (id: String, emailID: UUID?, at: Date, payload: Data) {
        (id: e.id.uuidString,
         emailID: e.emailIDs.count == 1 ? e.emailIDs.first : nil,
         at: e.date,
         payload: (try? JSONEncoder().encode(e)) ?? Data())
    }

    // MARK: Whole-scope actions (used by the L engines)

    /// Places a hold on every email in `query` in the database, then mirrors
    /// the result into the manager (and so the files). Returns how many new.
    func placeHolds(query requested: EmailQuery, matter: String = "") async throws -> Int {
        let store = ScopeJobEnvironment.store
        let query = ScopeJobEnvironment.archive.scoped(requested)   // free-tier rule applies here too
        let added: Int
        beginDatabaseWrite()
        if let text = query.text, !text.isEmpty {
            var ids: [UUID] = []
            for try await page in ScopeJobEnvironment.archive.streamSummaries(query: query, batchSize: 2_000) {
                ids.append(contentsOf: page.map(\.id))
            }
            added = try await store.legalHoldsAdd(ids, matter: matter)
        } else {
            added = try await store.legalHoldsAdd(query: query, matter: matter)
        }
        syncedHolds = try await store.legalHoldIDs()
        manager.absorbFromDatabase(holds: syncedHolds, seals: nil, custodians: nil)
        endDatabaseWrite()
        return added
    }

    /// Assigns a custodian to every email in `query`.
    func assignCustodian(_ name: String, query requested: EmailQuery) async throws -> Int {
        let store = ScopeJobEnvironment.store
        let query = ScopeJobEnvironment.archive.scoped(requested)
        let n: Int
        beginDatabaseWrite()
        if let text = query.text, !text.isEmpty {
            var map: [UUID: String] = [:]
            for try await page in ScopeJobEnvironment.archive.streamSummaries(query: query, batchSize: 2_000) {
                for s in page { map[s.id] = name }
            }
            n = try await store.custodiansAssign(map)
        } else {
            n = try await store.custodiansAssign(name, query: query)
        }
        syncedCustodians = try await store.allCustodianAssignments()
        manager.absorbFromDatabase(holds: nil, seals: nil, custodians: syncedCustodians)
        endDatabaseWrite()
        return n
    }
}
