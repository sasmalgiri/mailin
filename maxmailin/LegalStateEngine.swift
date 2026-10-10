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
    static let shared = LegalStateMirror()

    /// Pushed by CapabilityWiring; read on every manager change.
    nonisolated(unsafe) static var isEnabled = false

    private static let migratedKey = "legalState.v3.migrated"

    /// What the database is known to contain (the last synced copy).
    private var syncedHolds: Set<UUID> = []
    private var syncedSeals: [UUID: String] = [:]
    private var syncedCustodians: [UUID: String] = [:]
    private var syncedEventIDs: Set<UUID> = []
    private var active = false
    private var pending: Task<Void, Never>?

    private(set) var lastVerification: String?

    /// Brings the database level with the files, then verifies. Idempotent.
    ///
    /// The files are written on every change whether or not this engine is
    /// on, so they are the truth at activation: the database is loaded as
    /// the "synced" copy and the difference is written into it. (Pulling the
    /// database into the files here would resurrect a hold released while the
    /// engine was off.) The first activation takes a snapshot first.
    func activate() async {
        guard Self.isEnabled, !active else { return }
        let store = SQLiteEmailStore.shared
        let manager = CustodianManager.shared
        do {
            let first = !UserDefaults.standard.bool(forKey: Self.migratedKey)
            if first { _ = try? await store.snapshot(reason: "before-legal-state-migration") }
            syncedHolds = try await store.legalHoldIDs()
            syncedSeals = try await store.allSeals()
            syncedCustodians = try await store.allCustodianAssignments()
            syncedEventIDs = []   // INSERT OR IGNORE: re-sending is harmless
            active = true
            await syncNow()

            // Verify: the database now holds exactly what the files hold.
            let holdsOK = try await store.legalHoldIDs() == manager.legalHolds
            let sealsOK = try await store.allSeals().keys.count == manager.evidenceSeals.count
            let custodiansOK = try await store.allCustodianAssignments() == manager.custodians
            let counts = try await store.legalStateCounts()
            lastVerification = "holds \(counts.holds)/\(manager.legalHolds.count), seals \(counts.seals)/\(manager.evidenceSeals.count), custodians \(counts.custodians)/\(manager.custodians.count), custody events \(counts.custodyEvents)"
            guard holdsOK, sealsOK, custodiansOK else {
                active = false
                legalStateLog.error("legal state verification failed: \(self.lastVerification ?? "", privacy: .public)")
                ForensicManager.shared.logAction("Legal data move to database not verified",
                                                 detail: (lastVerification ?? "") + " — the files remain the source")
                return
            }
            if first {
                UserDefaults.standard.set(true, forKey: Self.migratedKey)
                ForensicManager.shared.logAction("Legal data copied into the archive database",
                                                 detail: (lastVerification ?? "") + " — verified; files kept as a second copy")
            }
        } catch {
            active = false
            legalStateLog.error("legal state activation failed: \(error.localizedDescription, privacy: .public)")
            EngineGuard.recordFallback(.v3LegalState, error: error)
        }
    }

    /// Whether the database copy is live (activated and verified).
    var isActive: Bool { active }

    /// Called from the manager's change hooks; coalesces bursts so a loop of
    /// 100k inserts becomes one batched write.
    func scheduleSync() {
        guard Self.isEnabled, active else { return }
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    /// Writes the difference between the manager and the database.
    func syncNow() async {
        guard Self.isEnabled, active else { return }
        let manager = CustodianManager.shared
        let store = SQLiteEmailStore.shared
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
            let newSeals = seals.filter { syncedSeals[$0.key] == nil }
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

            let events = ChainOfCustodyManager.shared.events.filter { !syncedEventIDs.contains($0.id) }
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
    func placeHolds(query: EmailQuery, matter: String = "") async throws -> Int {
        let store = SQLiteEmailStore.shared
        let added: Int
        if let text = query.text, !text.isEmpty {
            var ids: [UUID] = []
            for try await page in ArchiveDataService.shared.streamSummaries(query: query, batchSize: 2_000) {
                ids.append(contentsOf: page.map(\.id))
            }
            added = try await store.legalHoldsAdd(ids, matter: matter)
        } else {
            added = try await store.legalHoldsAdd(query: query, matter: matter)
        }
        syncedHolds = try await store.legalHoldIDs()
        CustodianManager.shared.absorbFromDatabase(holds: syncedHolds, seals: nil, custodians: nil)
        return added
    }

    /// Assigns a custodian to every email in `query`.
    func assignCustodian(_ name: String, query: EmailQuery) async throws -> Int {
        let store = SQLiteEmailStore.shared
        let n: Int
        if let text = query.text, !text.isEmpty {
            var map: [UUID: String] = [:]
            for try await page in ArchiveDataService.shared.streamSummaries(query: query, batchSize: 2_000) {
                for s in page { map[s.id] = name }
            }
            n = try await store.custodiansAssign(map)
        } else {
            n = try await store.custodiansAssign(name, query: query)
        }
        syncedCustodians = try await store.allCustodianAssignments()
        CustodianManager.shared.absorbFromDatabase(holds: nil, seals: nil, custodians: syncedCustodians)
        return n
    }
}
