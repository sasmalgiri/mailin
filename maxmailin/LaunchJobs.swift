@testable import ArchiveCore
//
//  LaunchJobs.swift
//  maxmailin
//
//  Phase C-2: the inventory of everything that runs at launch, each entry
//  owned by a page. A job runs only when its owner is enabled, registers
//  itself in `ModuleRegistry.jobs` while it runs (so Settings ▸ Modules shows
//  it and disabling the page cancels it), and unregisters when done. Before
//  this, the same kicks were scattered through `mailinApp` with ad-hoc
//  `isEnabled` checks and the `JobRegistry` had no callers at all.
//
//  This list is also the "launch-time job inventory" the module activation
//  matrix reports per capability.
//

import Foundation

@MainActor
enum LaunchJobs {

    struct Job: Identifiable, Sendable {
        let id: String
        let owner: AppModule
        let label: String
        /// Why it runs at launch, for the matrix.
        let purpose: String
    }

    /// The inventory. Order is the order they are kicked.
    static let inventory: [Job] = [
        Job(id: "fidelity.backfill", owner: .archive, label: String(localized: "Repair pre-full-fidelity rows"),
            purpose: String(localized: "Re-extracts type / attachments / labels / domains from stored MIME for rows imported by older builds; no-op once clean.")),
        Job(id: "attachment.textIndex", owner: .archive, label: String(localized: "Index attachment contents"),
            purpose: String(localized: "Bounded background text extraction so in:attachments searches file contents; honours the import sheet's choice.")),
        Job(id: "fts.reconcile", owner: .archive, label: String(localized: "Reconcile store ↔ search index"),
            purpose: String(localized: "Repairs store/FTS drift after a crash between commits and collapses duplicate FTS rows; bounded, restartable.")),
        Job(id: "digest.weekly", owner: .aiInsights, label: String(localized: "Weekly saved-search digest"),
            purpose: String(localized: "At most one digest per week for opted-in saved searches.")),
        Job(id: "semantic.index", owner: .aiInsights, label: String(localized: "Semantic index"),
            purpose: String(localized: "Opt-in, resumable on-device sentence vectors for Ask; runs only with the switch on and Page 2 enabled.")),
        Job(id: "workflow.seed", owner: .professional, label: String(localized: "Seed built-in workflows"),
            purpose: String(localized: "Idempotent upsert of the shipped workflow recipes; runs only when Page 3 is on.")),
        Job(id: "audit.launch", owner: .professional, label: String(localized: "Audit-chain launch entry"),
            purpose: String(localized: "Appends the launch event to the tamper-evident HMAC chain; Professional-owned (§3.3 R6)."))
    ]

    static func jobs(for module: AppModule) -> [Job] { inventory.filter { $0.owner == module } }

    /// Kick every launch job whose owner is enabled. `storageActive` gates the
    /// jobs that need the SQLite store to be the authority.
    static func run(modules: ModuleRegistry, storageActive: Bool, storageStateLabel: String) {
        // Page-owned hooks into Archive-owned surfaces.
        ArchiveExportService.installProfessionalHooks(enabled: modules.isEnabled(.professional))

        if modules.isEnabled(.professional) {
            _ = try? HMACChainAuditLog.shared.append(
                action: "v2.storage.activation",
                detail: "SQLite activation state: \(storageStateLabel)")
        }

        guard storageActive else { return }

        if modules.isEnabled(.archive) {
            let sender = UserDefaults.standard.string(forKey: "defaultSenderEmail") ?? ""
            // Owner's review 2026-09-29: these two jobs own their "Running
            // now" rows — registered when a run starts (including later
            // re-kicks after an import) and cleared on every exit path. The
            // hook only hands them the registry.
            FidelityBackfillJob.shared.kickIfNeeded(senderEmail: sender, registry: modules.jobs)

            if ImportChoices.indexAttachmentTextDefault() {
                AttachmentTextIndexJob.shared.kickIfNeeded(registry: modules.jobs)
            }

            let reconcile = Task.detached(priority: .utility) {
                let active = await StorageActivationCoordinator.shared.isActive
                let store: any EmailArchiveStore = active ? SQLiteEmailStore.shared : EmailStore.shared
                let storeCount = (try? await store.totalCount()) ?? 0
                let ftsCount = (try? await FTSSearchIndex.shared.rowCount()) ?? 0
                if storeCount > ftsCount {
                    _ = try? await FTSReconciler.reconcile(store: store, fts: .shared)
                }
                _ = try? await FTSSearchIndex.shared.dedupeShards()
                await MainActor.run { modules.jobs.finish(id: "fts.reconcile") }
            }
            modules.jobs.register(id: "fts.reconcile", module: .archive, label: String(localized: "Reconcile store ↔ search index"),
                                  cancel: { reconcile.cancel() })
        }

        if modules.isEnabled(.aiInsights) {
            DigestScheduler.shared.checkAndDeliver()
            // I4: resumes the opt-in semantic index where it stopped; a no-op
            // when the switch is off. Registers itself as a Page-2 job.
            SemanticIndexController.shared.resume(modules: modules)
        }

        if modules.isEnabled(.professional) {
            let seed = Task { await WorkflowService.seedBuiltins() }
            modules.jobs.register(id: "workflow.seed", module: .professional, label: String(localized: "Seed built-in workflows"),
                                  cancel: { seed.cancel() })
            Task { @MainActor in
                _ = await seed.result
                modules.jobs.finish(id: "workflow.seed")
            }
        }
    }
}
