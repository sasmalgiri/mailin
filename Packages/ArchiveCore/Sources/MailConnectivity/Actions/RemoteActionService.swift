//
//  RemoteActionService.swift
//  MailConnectivity
//
//  Plan v4 V4-11: runs journalled server actions one item at a time.
//
//    1. permission — the account's "Change server mail" mode AND the app's
//       policy closure AND the change scope in the account's sign-in
//       (gmail.modify / Mail.ReadWrite). Any refusal: `rejected`, NOTHING is
//       sent (no token is even requested).
//    2. resolve    — provider names to ids; unsupported changes refused.
//    3. read       — the item's current state on the server.
//    4. decide     — already in the requested state (nothing sent), matches the
//       expected prior state (proceed), or neither (CONFLICT: another client
//       changed it — nothing is sent for it, and no other item is touched).
//    5. journal    — `executing` is persisted BEFORE the mutating request.
//    6. apply      — one provider request (IMAP: the targeted UID commands).
//    7. reconcile  — read back; applied (verified) / conflict / uncertain.
//
//  Replaying an operation is idempotent: a finished one returns its recorded
//  outcome without contacting the server; one a killed process left
//  `executing` is reconciled against the server first, and the change is sent
//  again only when the server still shows the exact prior state.
//

import ArchiveCore
import Foundation

/// A failure of one provider request, by what it means for the server state.
public enum RemoteRequestFailure: Error, Sendable, Equatable {
    /// Nothing reached the provider (policy refusal, no token, not connected).
    case notSent(RemoteRejection)
    /// The provider definitely refused; the message is unchanged.
    case refused(String)
    /// The provider has no such message (404 / no such UID / UIDVALIDITY changed).
    case gone
    /// The request may have reached the provider; its effect is unknown.
    case uncertain(String)
}

/// A request with provider names resolved to the ids the server reports.
public struct ResolvedChange: Sendable, Equatable {
    public var request: RemoteChangeRequest
    public var precondition: RemotePrecondition
    public init(request: RemoteChangeRequest, precondition: RemotePrecondition) {
        self.request = request; self.precondition = precondition
    }
}

public enum RemoteVerification: Sendable, Equatable {
    case reached(RemoteItemState)
    case notReached(RemoteItemState)
    /// The change took effect but its result could not be read back (e.g. IMAP
    /// MOVE without UIDPLUS: the new UID is not reported).
    case reachedUnconfirmed(String)
}

/// One provider's server actions. Every request asks the network policy first.
public protocol RemoteActionExecutor: Sendable {
    var accountID: UUID { get }
    var provider: MailProviderKind { get }
    /// Resolves names (Graph well-known folders) and refuses unsupported
    /// changes with `.notSent(.unsupported(…))` before anything is changed.
    func resolve(_ request: RemoteChangeRequest, precondition: RemotePrecondition,
                 for identity: ProviderMessageIdentity) async throws -> ResolvedChange
    /// The current state; `.gone` (thrown or returned) when the identity no longer exists.
    func state(of identity: ProviderMessageIdentity) async throws -> RemoteItemState
    /// Sends the change. Returns the message's new identity when it changed (IMAP move).
    func apply(_ change: ResolvedChange, to identity: ProviderMessageIdentity, before: RemoteItemState) async throws -> ProviderMessageIdentity?
    func verify(_ change: ResolvedChange, original: ProviderMessageIdentity,
                resulting: ProviderMessageIdentity?) async throws -> RemoteVerification
    /// After an interrupted attempt, may the change be sent again when the
    /// server still shows the prior state? False where a partial earlier
    /// attempt could leave a second copy (IMAP COPY without MOVE).
    func safeToResend(_ change: ResolvedChange) async -> Bool
}

extension RemoteActionExecutor {
    public func safeToResend(_ change: ResolvedChange) async -> Bool { true }

    public func verify(_ change: ResolvedChange, original: ProviderMessageIdentity,
                       resulting: ProviderMessageIdentity?) async throws -> RemoteVerification {
        let after: RemoteItemState
        do { after = try await state(of: resulting ?? original) } catch RemoteRequestFailure.gone { after = .gone }
        return RemoteStateRules.satisfied(change.request, after) ? .reached(after) : .notReached(after)
    }
}

/// The rules shared by every provider.
public enum RemoteStateRules {
    public static func satisfied(_ request: RemoteChangeRequest, _ s: RemoteItemState) -> Bool {
        guard s.exists else { return false }
        switch request {
        case .markRead: return s.isRead == true
        case .markUnread: return s.isRead == false
        case .flag: return s.isFlagged == true
        case .unflag: return s.isFlagged == false
        case .addLabel(let l): return s.folders.contains(l)
        case .removeLabel(let l): return !s.folders.contains(l)
        case .archiveOnServer: return !s.folders.contains("INBOX") && !s.inTrash
        case .move(let from, let to): return s.folders.contains(to) && !s.folders.contains(from) && !s.inTrash
        case .moveToTrash: return s.inTrash
        case .restoreFromTrash(let to): return !s.inTrash && (to.map { s.folders.contains($0) } ?? true)
        }
    }

    /// nil = the expected prior state holds; otherwise what differs.
    public static func violation(_ p: RemotePrecondition, _ s: RemoteItemState) -> String? {
        guard s.exists else { return "it is no longer on the server (another client moved or deleted it)" }
        if p.notInTrash && s.inTrash { return "another client moved it to Trash" }
        if p.inTrash && !s.inTrash { return "it is no longer in Trash (another client restored or moved it)" }
        if let f = p.inFolder, !s.folders.contains(f) { return "it is no longer in \(f) (another client moved it)" }
        return nil
    }

    public enum Decision: Equatable { case alreadyInState, proceed, conflict(String) }

    public static func decide(_ change: ResolvedChange, _ before: RemoteItemState) -> Decision {
        guard before.exists else { return .conflict(violation(change.precondition, before)!) }
        if satisfied(change.request, before) { return .alreadyInState }
        if let why = violation(change.precondition, before) { return .conflict(why) }
        return .proceed
    }
}

/// The scopes a provider's sign-in must include before mailin changes mail.
public enum ServerActionScopes {
    public static let gmailModify = "https://www.googleapis.com/auth/gmail.modify"
    /// Gmail's full-access scope also allows modify / trash.
    public static let gmailFullAccess = "https://mail.google.com/"
    public static let graphReadWrite = "Mail.ReadWrite"
    public static let graphReadWriteShared = "Mail.ReadWrite.Shared"

    /// The scope to request, or nil when the granted scopes already cover it.
    public static func missing(for identity: ProviderMessageIdentity, granted: [String]) -> String? {
        let lower = Set(granted.map { $0.lowercased() })
        switch identity {
        case .gmail:
            if lower.contains(gmailModify.lowercased()) || lower.contains(gmailFullAccess) { return nil }
            return gmailModify
        case .graph(let mailbox, _):
            let needed = mailbox == "me" ? graphReadWrite : graphReadWriteShared
            let ok = lower.contains { $0 == needed.lowercased() || $0.hasSuffix("/" + needed.lowercased()) }
            return ok ? nil : needed
        case .imap:
            return nil          // IMAP sign-in is not scoped; the account mode still applies
        }
    }
}

/// The app's "Change server mail" policy for an account: throw to refuse.
public typealias ServerChangePermission = @Sendable (UUID) throws -> Void

public actor RemoteActionService {
    public nonisolated let account: MailAccount
    let executor: any RemoteActionExecutor
    public nonisolated let journal: RemoteOperationJournal
    let changePermission: ServerChangePermission
    let now: @Sendable () -> Date
    /// Tests only: called after the mutating request returned, before the outcome is saved (a kill there).
    var afterApplyHook: (@Sendable () throws -> Void)?

    public init(account: MailAccount, executor: any RemoteActionExecutor, journal: RemoteOperationJournal,
                changePermission: @escaping ServerChangePermission, now: @escaping @Sendable () -> Date = { Date() }) {
        self.account = account; self.executor = executor; self.journal = journal
        self.changePermission = changePermission; self.now = now
    }

    func setAfterApplyHook(_ hook: (@Sendable () throws -> Void)?) { afterApplyHook = hook }

    /// Journals one operation (nothing is sent).
    public func enqueue(_ identity: ProviderMessageIdentity, _ request: RemoteChangeRequest, emailID: UUID? = nil,
                        expected: RemotePrecondition? = nil, planID: UUID? = nil) async throws -> RemoteOperation {
        let op = RemoteOperation(accountID: account.id, identity: identity, emailID: emailID, request: request,
                                 expected: expected, planID: planID, now: now())
        try await journal.save(op)
        return op
    }

    /// Journals and executes one operation.
    public func perform(_ identity: ProviderMessageIdentity, _ request: RemoteChangeRequest, emailID: UUID? = nil,
                        expected: RemotePrecondition? = nil) async throws -> RemoteOperation {
        let op = try await enqueue(identity, request, emailID: emailID, expected: expected)
        return try await execute(op.id)
    }

    /// The permission refusal for this account, or nil. Never touches the network.
    public func permissionRefusal(for identity: ProviderMessageIdentity) -> RemoteRejection? {
        if executor.accountID != account.id { return .accountMismatch }
        if identity.provider != account.provider || executor.provider != account.provider { return .accountMismatch }
        guard account.enabledModes.contains(.serverActions) else { return .changeServerMailOff }
        do { try changePermission(account.id) } catch { return .changeServerMailOff }
        guard account.connectionState == .connected else { return .needsSignIn }
        if let scope = ServerActionScopes.missing(for: identity, granted: account.grantedScopes) {
            return .needsExtraPermission(scope: scope)
        }
        return nil
    }

    /// Executes (or reconciles) a journalled operation. Throws only when the
    /// journal cannot be written — then nothing (more) was sent.
    public func execute(_ id: UUID) async throws -> RemoteOperation {
        var op = try await journal.load(id)
        if op.isFinished { return op }                  // idempotent replay: no request at all
        guard op.accountID == account.id else { return try await finish(&op, .rejected(.accountMismatch)) }
        let replay: Bool
        if case .executing = op.attempt { replay = true } else { replay = false }

        if let refusal = permissionRefusal(for: op.identity) { return try await finish(&op, .rejected(refusal)) }

        let change: ResolvedChange
        do { change = try await executor.resolve(op.request, precondition: op.expected, for: op.identity) } catch {
            return try await finish(&op, replay ? .uncertain(Self.text(error)) : Self.rejection(error))
        }

        let before: RemoteItemState
        do { before = try await executor.state(of: op.identity) } catch RemoteRequestFailure.gone {
            before = .gone
        } catch {
            return try await finish(&op, replay ? .uncertain("an earlier attempt was interrupted and the server could not be checked: \(Self.text(error))")
                                                : Self.rejection(error, reading: true))
        }
        op.observedBefore = before
        switch RemoteStateRules.decide(change, before) {
        case .alreadyInState:
            op.observedAfter = before
            return try await finish(&op, .applied(verified: true, alreadyInState: !replay))
        case .conflict(let why):
            if replay {
                return try await finish(&op, .uncertain("an earlier attempt was interrupted; now \(why) — it may have been this request"))
            }
            return try await finish(&op, .conflict(why))
        case .proceed:
            if replay, !(await executor.safeToResend(change)) {
                return try await finish(&op, .uncertain("an earlier attempt was interrupted and may have left a copy in the destination; it was not repeated"))
            }
        }

        // Persisted BEFORE the request: a kill from here on is reconciled, never resent blindly.
        op.attempt = .executing(since: now())
        op.updatedAt = now()
        try await journal.save(op)

        var resulting: ProviderMessageIdentity?
        var uncertainWhy: String?
        do {
            resulting = try await executor.apply(change, to: op.identity, before: before)
        } catch RemoteRequestFailure.notSent(let r) {
            return try await finish(&op, .rejected(r))
        } catch RemoteRequestFailure.refused(let why) {
            return try await finish(&op, .rejected(.providerRefused(why)))
        } catch RemoteRequestFailure.gone {
            return try await finish(&op, .conflict("it was removed from the server before the change"))
        } catch RemoteRequestFailure.uncertain(let why) {
            uncertainWhy = why
        } catch {
            uncertainWhy = Self.text(error)
        }
        op.resultingIdentity = resulting
        try afterApplyHook?()

        let verification: RemoteVerification
        do { verification = try await executor.verify(change, original: op.identity, resulting: resulting) } catch {
            if let uncertainWhy { return try await finish(&op, .uncertain(uncertainWhy)) }
            op.note = "the change was accepted; reading it back failed (\(Self.text(error)))"
            return try await finish(&op, .applied(verified: false, alreadyInState: false))
        }
        switch verification {
        case .reached(let after):
            op.observedAfter = after
            return try await finish(&op, .applied(verified: true, alreadyInState: false))
        case .reachedUnconfirmed(let why):
            op.note = why
            return try await finish(&op, uncertainWhy.map { .uncertain($0) } ?? .applied(verified: false, alreadyInState: false))
        case .notReached(let after):
            op.observedAfter = after
            if let uncertainWhy { return try await finish(&op, .uncertain(uncertainWhy)) }
            if let why = RemoteStateRules.violation(change.precondition, after), after != before {
                return try await finish(&op, .conflict("changed by another client while the change was made: \(why)"))
            }
            return try await finish(&op, .uncertain("the server accepted the change but still shows the earlier state"))
        }
    }

    private func finish(_ op: inout RemoteOperation, _ outcome: RemoteOperationOutcome) async throws -> RemoteOperation {
        op.outcome = outcome
        op.attempt = .finished(at: now())
        op.updatedAt = now()
        try await journal.save(op)
        return op
    }

    static func rejection(_ error: Error, reading: Bool = false) -> RemoteOperationOutcome {
        switch error {
        case RemoteRequestFailure.notSent(let r): return .rejected(r)
        case RemoteRequestFailure.refused(let why): return .rejected(reading ? .stateUnavailable(why) : .providerRefused(why))
        default: return .rejected(.stateUnavailable(text(error)))
        }
    }

    static func text(_ error: Error) -> String {
        switch error {
        case RemoteRequestFailure.notSent(let r): return r.defaultText
        case RemoteRequestFailure.refused(let s), RemoteRequestFailure.uncertain(let s): return s
        case RemoteRequestFailure.gone: return "the message is no longer on the server"
        default: return error.localizedDescription
        }
    }
}
