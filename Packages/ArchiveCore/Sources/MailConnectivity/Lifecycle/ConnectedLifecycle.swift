//
//  ConnectedLifecycle.swift
//  MailConnectivity
//
//  Plan v4 V4-12 (§7 Subscription lapse, LIFE-06, T44): what connected mail
//  may do under the current entitlement, and the outbox decisions a lapse,
//  a restore or an account removal leaves for the user.
//
//  The entitlement is an INJECTED value (`ConnectedEntitlement`): the app
//  maps `StoreManager.entitlementState` / `AccessPolicy` onto it, including
//  which connected activities its plan treats as paid. This file never asks
//  StoreKit and never decides prices.
//
//  Rules (LIFE-06 extended to connected mail):
//   • Captured mail stays readable, searchable and exportable; drafts stay
//     editable; account removal and sign-in stay available — these are
//     never gated, whatever the plan says (`ConnectedActivity.isMaintenance`).
//   • New paid activity (capture, sending, server actions — as the app
//     declares) pauses with an explanation; nothing is deleted or dropped.
//   • An already-submitted send is still reconciled (Sent lookup / append):
//     that is maintenance of something that already happened.
//   • Queued messages are HELD while sending is paused; after a lapse
//     longer than `staleAfter` they are not sent on renewal until the user
//     decides (send now / keep as draft). The decision is persisted, so a
//     restart cannot turn it back into an automatic send.
//   • Outbox items restored from a backup, and items of a removed account,
//     are never sent automatically either.
//
//  The ledger lives in `<store>/ConnectedLifecycle/lifecycle.json`
//  (owner-only, atomically replaced, included in archive backups).
//

import Foundation

// MARK: - Entitlement (injected)

public enum ConnectedActivity: String, Sendable, Codable, CaseIterable {
    case capture, send, serverActions
    case readArchive, search, export, editDrafts, reconcileSubmittedSend, signIn, removeAccount

    /// Never gated by a plan: reading, searching and exporting captured
    /// mail, editing drafts, finishing what was already submitted, signing
    /// in and removing an account (LIFE-06).
    public var isMaintenance: Bool {
        switch self {
        case .capture, .send, .serverActions: return false
        default: return true
        }
    }
}

public struct ConnectedEntitlement: Sendable, Equatable {
    public enum Plan: String, Sendable, Codable { case free, active, lifetime, lapsed }
    public var plan: Plan
    /// When the paid period ended (lapsed); nil when unknown.
    public var lapsedAt: Date?
    /// The connected activities the app's plan treats as paid.
    public var paidActivities: Set<ConnectedActivity>

    public init(plan: Plan, lapsedAt: Date? = nil, paidActivities: Set<ConnectedActivity> = [.capture, .send, .serverActions]) {
        self.plan = plan; self.lapsedAt = lapsedAt
        self.paidActivities = paidActivities.filter { !$0.isMaintenance }
    }

    public var coversPaidActivity: Bool { plan == .active || plan == .lifetime }
}

public enum ConnectedPauseExplanation: Sendable, Equatable, Codable {
    /// The subscription ended; the activity resumes when it is renewed.
    case subscriptionLapsed(ConnectedActivity, since: Date?)
    /// The current plan does not include the activity.
    case notInPlan(ConnectedActivity)
    case accountRemoved

    /// English reference wording (the app localises from the case).
    public var defaultText: String {
        let kept = "Saved mail stays readable, searchable and exportable; drafts and the outbox stay as they are."
        switch self {
        case .subscriptionLapsed(let activity, let since):
            let when = since.map { " on \(ISO8601DateFormatter().string(from: $0).prefix(10))" } ?? ""
            return "\(Self.name(activity)) is paused because the subscription ended\(when). \(kept)"
        case .notInPlan(let activity):
            return "\(Self.name(activity)) is not included in the current plan. \(kept)"
        case .accountRemoved:
            return "This account was removed; nothing more is downloaded or sent for it. Its saved mail is kept."
        }
    }

    static func name(_ a: ConnectedActivity) -> String {
        switch a {
        case .capture: return "Saving new mail"
        case .send: return "Sending"
        case .serverActions: return "Changing mail on the server"
        default: return a.rawValue
        }
    }
}

public enum ConnectedActivityDecision: Sendable, Equatable {
    case allowed
    case paused(ConnectedPauseExplanation)
}

/// Thrown into a sync / server-action network permission: the engine
/// reports `.notPermitted(<explanation>)`, never a completion.
public struct ConnectedLifecycleRefusal: LocalizedError, Equatable {
    public let explanation: ConnectedPauseExplanation
    public var errorDescription: String? { explanation.defaultText }
}

// MARK: - Outbox holds

public enum OutboxHoldReason: Sendable, Equatable, Codable {
    /// Sending is paused by the plan; the item waits, visible.
    case sendingPaused(ConnectedPauseExplanation)
    /// Queued before a lapse of `lapsedFor` seconds: sent only after the user decides.
    case decisionNeededAfterLapse(queuedAt: Date, lapsedFor: TimeInterval)
    /// Came back with a restored backup: it may already have been sent from the other copy.
    case restoredFromBackup(restoredAt: Date)
    case accountRemoved
    /// The archive's drive (holding the outbox) is not connected.
    case archiveDriveMissing(volumeName: String)

    /// The user must choose Send now or Keep as draft; time alone never releases it.
    public var needsUserDecision: Bool {
        switch self {
        case .decisionNeededAfterLapse, .restoredFromBackup: return true
        default: return false
        }
    }

    public var defaultText: String {
        switch self {
        case .sendingPaused(let why): return "Not sent yet: \(why.defaultText)"
        case .decisionNeededAfterLapse(_, let lapsed):
            let days = max(1, Int((lapsed / 86_400).rounded()))
            return "Waiting for you: this message was queued before sending was paused for \(days) day\(days == 1 ? "" : "s"). Send it now, or keep it as a draft."
        case .restoredFromBackup:
            return "Waiting for you: this message came back with a restored backup and may already have been sent. Check Sent, then send it or keep it as a draft."
        case .accountRemoved: return "Not sent: its account was removed. The message is kept."
        case .archiveDriveMissing(let name): return "Not sent yet: the drive “\(name)” that holds the archive is not connected."
        }
    }
}

public enum OutboxAdmissionDecision: Sendable, Equatable {
    case submit
    case hold(OutboxHoldReason)
}

public typealias OutboxAdmission = @Sendable (OutboxOperation, Date) async -> OutboxAdmissionDecision

// MARK: - Ledger

struct LifecycleLedger: Codable, Equatable {
    struct Lapse: Codable, Equatable { var start: Date; var end: Date? }
    struct Decision: Codable, Equatable { var reason: OutboxHoldReason; var since: Date }
    var version = 1
    /// Periods during which sending was paused by the plan.
    var lapses: [Lapse] = []
    var decisionsNeeded: [UUID: Decision] = [:]
    /// Operations the user explicitly chose to send after a hold.
    var released: [UUID: Date] = [:]
    var removedAccounts: [UUID: Date] = [:]
    var restores: [Date] = []
    var recaptureDecisions: [UUID: RecaptureDecision] = [:]
}

public struct RecaptureDecision: Codable, Sendable, Equatable {
    public enum Choice: String, Codable, Sendable {
        /// Both records stay; nothing is marked.
        case keepBoth
        /// Both records stay; the recaptured one is the preferred copy (the old one is never deleted or changed).
        case preferRecaptured
    }
    public var oldEmailID: UUID
    public var recapturedEmailID: UUID
    public var choice: Choice
    public var decidedAt: Date
    public init(oldEmailID: UUID, recapturedEmailID: UUID, choice: Choice, decidedAt: Date) {
        self.oldEmailID = oldEmailID; self.recapturedEmailID = recapturedEmailID; self.choice = choice; self.decidedAt = decidedAt
    }
}

public enum ConnectedLifecycleStoreError: LocalizedError, Equatable {
    case unreadable(String)
    case saveFailed(String)
    public var errorDescription: String? {
        switch self {
        case .unreadable(let why): return "The connected-mail lifecycle record could not be read: \(why). Nothing will be sent automatically until it is."
        case .saveFailed(let why): return "The connected-mail lifecycle record could not be saved: \(why)"
        }
    }
}

// MARK: - Lifecycle

/// Thread-safe (a lock, not an actor) so network-permission closures can ask synchronously.
public final class ConnectedLifecycle: @unchecked Sendable {
    public static let folderName = "ConnectedLifecycle"
    public let fileURL: URL
    private let entitlement: @Sendable () -> ConnectedEntitlement
    private let clock: @Sendable () -> Date
    /// A lapse at least this long makes queued messages wait for a decision.
    public let staleAfter: TimeInterval
    /// When set, the outbox holds while the archive's drive is missing.
    public let drive: ArchiveDriveIdentity?
    private let lock = NSLock()
    private var ledger: LifecycleLedger

    public init(storeDirectory: URL, entitlement: @escaping @Sendable () -> ConnectedEntitlement,
                now: @escaping @Sendable () -> Date = { Date() }, staleAfter: TimeInterval = 24 * 3_600,
                drive: ArchiveDriveIdentity? = nil) throws {
        let folder = storeDirectory.appendingPathComponent(Self.folderName, isDirectory: true)
        do { try DraftStore.makeProtectedDirectory(folder) } catch { throw ConnectedLifecycleStoreError.saveFailed(error.localizedDescription) }
        DraftStore.sweepTemporaryFiles(under: folder)
        fileURL = folder.appendingPathComponent("lifecycle.json")
        self.entitlement = entitlement; self.clock = now; self.staleAfter = staleAfter; self.drive = drive
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .secondsSince1970
                ledger = try decoder.decode(LifecycleLedger.self, from: Data(contentsOf: fileURL))
            } catch { throw ConnectedLifecycleStoreError.unreadable(error.localizedDescription) }
        } else {
            ledger = LifecycleLedger()
            try persistLocked()      // present from the start: a later read failure is never mistaken for "nothing recorded"
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }

    /// Writes the ledger durably (temporary file, full flush, rename). Called with the lock held.
    private func persistLocked() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .secondsSince1970
        let tmp = fileURL.deletingLastPathComponent().appendingPathComponent(".lifecycle.json.\(UUID().uuidString).tmp")
        do {
            let data = try encoder.encode(ledger)
            let handle = try DraftStore.createProtectedFile(tmp)
            do {
                defer { try? handle.close() }
                try handle.write(contentsOf: data)
                try DraftStore.flush(handle)
            }
            try DraftStore.publish(tmp, as: fileURL)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw ConnectedLifecycleStoreError.saveFailed(error.localizedDescription)
        }
    }

    // MARK: Decisions

    /// Whether `activity` may run now (for `account`, when given).
    public func decide(_ activity: ConnectedActivity, account: UUID? = nil) -> ConnectedActivityDecision {
        locked { decideLocked(activity, account: account, at: clock()) }
    }

    private func decideLocked(_ activity: ConnectedActivity, account: UUID?, at now: Date) -> ConnectedActivityDecision {
        if activity.isMaintenance { return .allowed }
        if let account, ledger.removedAccounts[account] != nil { return .paused(.accountRemoved) }
        let e = entitlement()
        observeLocked(e, at: now)
        guard e.paidActivities.contains(activity), !e.coversPaidActivity else { return .allowed }
        return .paused(e.plan == .lapsed ? .subscriptionLapsed(activity, since: e.lapsedAt) : .notInPlan(activity))
    }

    /// Records when sending became paused / resumed (a lapse period).
    private func observeLocked(_ e: ConnectedEntitlement, at now: Date) {
        let sendingPaused = e.paidActivities.contains(.send) && !e.coversPaidActivity
        let open = ledger.lapses.last.map { $0.end == nil } ?? false
        if sendingPaused && !open {
            ledger.lapses.append(.init(start: min(e.lapsedAt ?? now, now), end: nil))
            try? persistLocked()
        } else if !sendingPaused && open {
            ledger.lapses[ledger.lapses.count - 1].end = now
            try? persistLocked()
        }
    }

    /// Wrap the account's sync network permission: capture is refused (with
    /// the explanation) while the plan pauses it or the account was removed.
    public func capturePermission(_ base: @escaping NetworkPermission) -> NetworkPermission {
        permission(.capture, base)
    }

    /// The same for separately authorised server actions (V4-11).
    public func serverActionPermission(_ base: @escaping NetworkPermission) -> NetworkPermission {
        permission(.serverActions, base)
    }

    private func permission(_ activity: ConnectedActivity, _ base: @escaping NetworkPermission) -> NetworkPermission {
        { [self] ask in
            if case .paused(let why) = decide(activity, account: ask.accountID) { throw ConnectedLifecycleRefusal(explanation: why) }
            try base(ask)
        }
    }

    // MARK: Outbox

    /// Install with `Outbox.setAdmission(lifecycle.outboxAdmission)`.
    public var outboxAdmission: OutboxAdmission {
        { [self] op, now in admit(op, at: now) }
    }

    public func admit(_ op: OutboxOperation, at now: Date) -> OutboxAdmissionDecision {
        if let drive, !ArchiveDriveGuard.check(drive).isPresent { return .hold(.archiveDriveMissing(volumeName: drive.volumeName)) }
        return locked {
            if ledger.removedAccounts[op.accountID] != nil { return .hold(.accountRemoved) }
            if case .paused(let why) = decideLocked(.send, account: op.accountID, at: now) { return .hold(.sendingPaused(why)) }
            if let pending = ledger.decisionsNeeded[op.id] { return .hold(pending.reason) }
            if ledger.released[op.id] != nil { return .submit }
            // A lapse long enough to make this message stale: the user decides.
            let queuedAt = op.createdAt
            for lapse in ledger.lapses {
                guard let end = lapse.end, end <= now, queuedAt < end else { continue }
                let lapsedFor = end.timeIntervalSince(max(lapse.start, queuedAt))
                if lapsedFor >= staleAfter {
                    let reason = OutboxHoldReason.decisionNeededAfterLapse(queuedAt: queuedAt, lapsedFor: end.timeIntervalSince(lapse.start))
                    ledger.decisionsNeeded[op.id] = .init(reason: reason, since: now)
                    try? persistLocked()
                    return .hold(reason)
                }
            }
            return .submit
        }
    }

    /// Items waiting for the user's decision (persisted).
    public func pendingDecisions() -> [UUID: OutboxHoldReason] {
        locked { ledger.decisionsNeeded.mapValues(\.reason) }
    }

    /// The user's explicit "send it now" for a held item.
    public func release(_ operationID: UUID) throws {
        try locked {
            ledger.decisionsNeeded[operationID] = nil
            ledger.released[operationID] = clock()
            try persistLocked()
        }
    }

    /// The user's "keep it as a draft": cancelled before submission (the
    /// draft and the frozen message stay); the decision is cleared.
    @discardableResult
    public func keepAsDraft(_ operationID: UUID, outbox: Outbox) async throws -> OutboxOperation {
        let op = try await outbox.cancel(operationID, note: "kept as a draft by the user; not sent")
        try locked {
            ledger.decisionsNeeded[operationID] = nil
            try persistLocked()
        }
        return op
    }

    // MARK: Accounts and restores

    public func markAccountRemoved(_ account: UUID) throws {
        try locked {
            ledger.removedAccounts[account] = clock()
            try persistLocked()
        }
    }

    public func isRemoved(_ account: UUID) -> Bool { locked { ledger.removedAccounts[account] != nil } }

    /// The person added a removed account again (reconnected under its old
    /// id): its new work may run. Items held because it was removed stay
    /// cancelled (they were cancelled at removal); nothing is sent by this.
    public func clearAccountRemoved(_ account: UUID) throws {
        try locked {
            guard ledger.removedAccounts.removeValue(forKey: account) != nil else { return }
            try persistLocked()
        }
    }

    /// After a restore: every outbox item that was not yet handed to a
    /// provider waits for the user's decision.
    @discardableResult
    public func holdRestored(_ operations: [OutboxOperation]) throws -> [UUID] {
        try locked {
            let now = clock()
            ledger.restores.append(now)
            var held: [UUID] = []
            for op in operations where Self.isWaitingToSend(op.state) {
                ledger.decisionsNeeded[op.id] = .init(reason: .restoredFromBackup(restoredAt: now), since: now)
                ledger.released[op.id] = nil
                held.append(op.id)
            }
            try persistLocked()
            return held
        }
    }

    /// Not yet handed to a provider and not finished: it could still be sent.
    static func isWaitingToSend(_ state: OutboxState) -> Bool {
        switch state {
        case .draft, .queued, .retryWaiting, .needsSignIn: return true
        default: return false
        }
    }

    // MARK: Recapture decisions (T46)

    public func recordRecaptureDecision(_ decision: RecaptureDecision) throws {
        try locked {
            ledger.recaptureDecisions[decision.oldEmailID] = decision
            try persistLocked()
        }
    }

    public func recaptureDecision(old: UUID) -> RecaptureDecision? { locked { ledger.recaptureDecisions[old] } }

    // MARK: Visibility (T44)

    /// Lapse periods recorded (start, end; end nil = still paused).
    public var lapses: [(start: Date, end: Date?)] { locked { ledger.lapses.map { ($0.start, $0.end) } } }
}

/// Everything the user can still see and act on while connected activity is paused.
public struct ConnectedLifecycleOverview: Sendable {
    public var drafts: Int
    public var unreadableDrafts: Int
    /// Not yet submitted (queued, waiting to retry, needs sign-in).
    public var waitingToSend: [UUID]
    /// Accepted or uncertain: reconciled as maintenance.
    public var awaitingReconciliation: [UUID]
    public var held: [UUID: OutboxHoldReason]
    public var capture: ConnectedActivityDecision
    public var send: ConnectedActivityDecision

    public static func make(lifecycle: ConnectedLifecycle, drafts: DraftStore, outbox: Outbox) async throws -> ConnectedLifecycleOverview {
        let listing = await drafts.drafts()
        let ops = try await outbox.operations()
        var held = await outbox.heldOperations()
        for (id, why) in lifecycle.pendingDecisions() { held[id] = why }
        return ConnectedLifecycleOverview(
            drafts: listing.drafts.count, unreadableDrafts: listing.unreadable.count,
            waitingToSend: ops.filter { ConnectedLifecycle.isWaitingToSend($0.state) }.map(\.id),
            awaitingReconciliation: ops.filter {
                switch $0.state { case .accepted, .outcomeUncertain, .submitting: return true; default: return false }
            }.map(\.id),
            held: held, capture: lifecycle.decide(.capture), send: lifecycle.decide(.send))
    }
}
