//
//  ConnectedRestore.swift
//  MailConnectivity
//
//  Plan v4 V4-12 (§7 Secrets, T45): after `ArchiveBackup.restore`.
//
//  A backup carries account METADATA (provider, issuer/tenant or server,
//  display identity, modes) and the drafts / outbox folders, never a
//  credential. A clean-profile restore already marked every connected
//  account `needsReauthorisation` in the restored database; this step makes
//  the outbox safe: every item that was not yet handed to a provider may
//  already have been sent from the other copy after the backup was taken,
//  so it waits for the user's decision instead of being sent on sign-in.
//  Items already submitted stay listed for Sent reconciliation.
//

import Foundation

public struct ConnectedRestoreReport: Sendable, Equatable {
    /// Accounts that must sign in again on this device.
    public var accountsNeedingSignIn: [UUID]
    /// Outbox items that wait for Send now / Keep as draft.
    public var outboxHeldForDecision: [UUID]
    public var outboxAwaitingReconciliation: [UUID]
    public var drafts: Int
    /// Draft / outbox folders that could not be read (listed, never hidden).
    public var unreadable: [String]
}

public enum ConnectedRestore {
    /// Call once, right after the restore placed its files and before any
    /// outbox runs. Idempotent: holding an item twice changes nothing.
    public static func prepare(storeDirectory: URL, registry: MailAccountRegistry, lifecycle: ConnectedLifecycle) async throws -> ConnectedRestoreReport {
        let outboxStore = try OutboxStore(storeDirectory: storeDirectory)
        let listing = await outboxStore.all()
        let held = try lifecycle.holdRestored(listing.operations)
        let drafts = try DraftStore(storeDirectory: storeDirectory)
        let draftListing = await drafts.drafts()
        let accounts = try await registry.accounts()
        return ConnectedRestoreReport(
            accountsNeedingSignIn: accounts.filter { $0.connectionState == .needsReauthorisation }.map(\.id),
            outboxHeldForDecision: held,
            outboxAwaitingReconciliation: listing.operations.filter { AccountRemovalCoordinator.awaitsOutcome($0.state) }.map(\.id),
            drafts: draftListing.drafts.count,
            unreadable: listing.unreadable.map(\.id) + draftListing.unreadable.map(\.id))
    }
}
