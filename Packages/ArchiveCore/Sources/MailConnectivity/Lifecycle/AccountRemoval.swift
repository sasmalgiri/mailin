//
//  AccountRemoval.swift
//  MailConnectivity
//
//  Plan v4 V4-12 (§7 Account removal, T21, T44): removing a connected
//  account, in this order —
//
//   1. the lifecycle marks it removed: every later network request of the
//      account is refused, even from a task that is still unwinding;
//   2. its running tasks are cancelled (the app owns the Task handles and
//      passes them through `AccountTaskControl`);
//   3. its outbox is handled VISIBLY: items not yet handed to the provider
//      are cancelled before submission and kept (the draft stays in the
//      draft store; the frozen message stays in the outbox); items already
//      submitted (accepted / uncertain) stay listed for reconciliation —
//      nothing is silently dropped and nothing is sent;
//   4. its secrets are removed (or, on request, kept with the account
//      disconnected) and its live cache (sync cursors, listed-not-captured
//      queue) dropped on request;
//   5. its archived messages are KEPT. Deleting them is a separate,
//      explicit call with the affected count shown first
//      (`planArchiveDeletion` → `deleteArchivedMail(confirmedCount:)`);
//      records under a legal hold and blobs any other account or import
//      references are never removed. No other account is touched.
//

import ArchiveCore
import Foundation

/// The app's running work per account (sync tasks, sends, server actions).
public protocol AccountTaskControl: Sendable {
    /// Cancels every task of the account and waits until they stopped; returns how many there were.
    func cancelTasks(account: UUID) async -> Int
}

public struct AccountRemovalOptions: Sendable, Equatable {
    /// Delete the account's Keychain items (default). False: keep them, account disconnected.
    public var removeSecrets: Bool
    /// Drop sync cursors and the listed-not-captured queue (default).
    public var removeLiveCache: Bool
    public init(removeSecrets: Bool = true, removeLiveCache: Bool = true) {
        self.removeSecrets = removeSecrets; self.removeLiveCache = removeLiveCache
    }
}

/// Shown before removing: what happens to each kind of thing.
public struct AccountRemovalPlan: Sendable, Equatable {
    public var account: MailAccount
    public var drafts: Int
    /// Not yet submitted: cancelled before submission and kept.
    public var outboxToKeep: Int
    /// Already submitted (accepted / uncertain): kept listed for reconciliation.
    public var outboxAwaitingOutcome: Int
    /// Archived mail, kept unless deleted separately.
    public var archive: ConnectedAccountArchiveSummary
}

public struct AccountRemovalReport: Sendable, Equatable {
    public var accountID: UUID
    public var tasksCancelled: Int
    /// Cancelled before submission; their draft is still in the draft store.
    public var keptAsDrafts: [UUID]
    /// Cancelled before submission; the draft had been discarded, the frozen
    /// message stays readable in the outbox (`Outbox.frozenMessage`).
    public var keptInOutbox: [UUID]
    /// Already handed to the provider: listed until reconciled.
    public var awaitingOutcome: [UUID]
    public var secretsRemoved: Bool
    public var liveCacheRowsRemoved: Int
    public var archivedRecordsKept: Int
}

public actor AccountRemovalCoordinator {
    let registry: MailAccountRegistry
    let sink: ConnectedArchiveSink
    let outbox: Outbox
    let drafts: DraftStore
    let lifecycle: ConnectedLifecycle
    let tasks: any AccountTaskControl

    public init(registry: MailAccountRegistry, sink: ConnectedArchiveSink, outbox: Outbox, drafts: DraftStore,
                lifecycle: ConnectedLifecycle, tasks: any AccountTaskControl) {
        self.registry = registry; self.sink = sink; self.outbox = outbox; self.drafts = drafts
        self.lifecycle = lifecycle; self.tasks = tasks
    }

    static func awaitsOutcome(_ state: OutboxState) -> Bool {
        switch state {
        case .submitting, .accepted, .outcomeUncertain: return true
        default: return false
        }
    }

    public func plan(_ id: UUID) async throws -> AccountRemovalPlan {
        let account = try await registry.account(id)
        let ops = try await outbox.operations().filter { $0.accountID == id }
        let draftCount = await drafts.drafts().drafts.filter { $0.accountID == id }.count
        return AccountRemovalPlan(account: account, drafts: draftCount,
                                  outboxToKeep: ops.filter { ConnectedLifecycle.isWaitingToSend($0.state) }.count,
                                  outboxAwaitingOutcome: ops.filter { Self.awaitsOutcome($0.state) }.count,
                                  archive: try await sink.accountArchiveSummary(accountID: id))
    }

    public func remove(_ id: UUID, options: AccountRemovalOptions = AccountRemovalOptions()) async throws -> AccountRemovalReport {
        _ = try await registry.account(id)
        try lifecycle.markAccountRemoved(id)
        let cancelled = await tasks.cancelTasks(account: id)

        var keptAsDrafts: [UUID] = [], keptInOutbox: [UUID] = [], awaiting: [UUID] = []
        for op in try await outbox.operations() where op.accountID == id {
            if ConnectedLifecycle.isWaitingToSend(op.state) {
                do {
                    try await outbox.cancel(op.id, note: "account removed; kept, not sent")
                } catch OutboxError.cannotCancelAfterSubmission {
                    awaiting.append(op.id)
                    continue
                }
                if (try? await drafts.draft(op.draftID)) != nil { keptAsDrafts.append(op.id) } else { keptInOutbox.append(op.id) }
            } else if Self.awaitsOutcome(op.state) {
                awaiting.append(op.id)
            }
        }

        if options.removeSecrets {
            try await registry.remove(id)
        } else {
            var account = try await registry.account(id)
            account.connectionState = .disconnected
            account.enabledModes = []
            try await registry.save(account)
        }
        let cacheRows = options.removeLiveCache ? try await sink.removeLiveCache(accountID: id) : 0
        let kept = try await sink.accountArchiveSummary(accountID: id).records
        return AccountRemovalReport(accountID: id, tasksCancelled: cancelled, keptAsDrafts: keptAsDrafts, keptInOutbox: keptInOutbox,
                                    awaitingOutcome: awaiting, secretsRemoved: options.removeSecrets,
                                    liveCacheRowsRemoved: cacheRows, archivedRecordsKept: kept)
    }

    /// The count to show before "Delete this account's archived mail".
    public func planArchiveDeletion(_ id: UUID) async throws -> ConnectedAccountArchiveSummary {
        try await sink.accountArchiveSummary(accountID: id)
    }

    /// Deletes the account's archived mail — only when `confirmedCount`
    /// equals the deletable count now (else `countChanged`, nothing deleted).
    /// The caller removes `deletedEmailIDs` from the search index.
    public func deleteArchivedMail(_ id: UUID, confirmedCount: Int) async throws -> ConnectedAccountArchiveDeletion {
        try await sink.deleteAccountArchive(accountID: id, confirmedCount: confirmedCount)
    }
}
