//
//  AIConsent.swift
//  ArchiveCore — AIScaffold
//
//  Plan v4 SCAF-03 (§12.2 "a single session consent flag covers unrelated
//  requests", §13.4): scoped consent grants, revocation, source eligibility
//  and a consent queue whose every request resolves EXACTLY once — answered,
//  dismissed, its host closed or its task cancelled.
//
//  A grant names one provider, endpoint, model, purpose, source selection,
//  payload and spending allowance. It covers a request only when every one of
//  those matches the request's frozen snapshot, so a grant for one profile can
//  never authorise a payload or key for another. A one-run grant never covers
//  automation; automation needs a grant naming its rule (B04). Saving a key
//  never creates a grant.
//

import Foundation

// MARK: - Grants

public struct AIConsentGrant: Sendable, Hashable, Codable, Identifiable {
    public enum Scope: Sendable, Hashable, Codable {
        /// The one run the customer looked at.
        case oneRun(runID: UUID)
        /// A revocable automation grant for one rule (scheduled work).
        case automation(ruleID: UUID)
    }

    public let id: UUID
    public let scope: Scope
    public let profileID: UUID
    public let provider: AIProviderKind
    public let endpointHost: String
    public let modelID: String
    public let credential: AICredentialReference
    public let purpose: AIPurpose
    public let sourceFingerprint: String
    public let dataTypes: Set<AIDataType>
    /// One-run grants bind the exact payload; automation grants bind the
    /// source/rule scope instead (their payload is not known in advance).
    public let payloadSHA256: String?
    public let spendingAllowance: AICostEstimate
    public let grantedAt: Date

    /// A one-run grant for exactly what the customer was shown.
    public init(approving request: AIRequest, spendingAllowance: AICostEstimate? = nil, grantedAt: Date = Date()) {
        id = UUID()
        scope = .oneRun(runID: request.runID)
        profileID = request.profile.id
        provider = request.profile.provider
        endpointHost = request.profile.endpoint.host
        modelID = request.profile.modelID
        credential = request.credential
        purpose = request.purpose
        sourceFingerprint = request.sources.fingerprint
        dataTypes = request.sources.dataTypes
        payloadSHA256 = request.payloadSHA256
        self.spendingAllowance = spendingAllowance ?? request.estimate
        self.grantedAt = grantedAt
    }

    /// An automation grant for one rule, one profile, one source scope.
    public init(automationRule ruleID: UUID, profile: AIProviderProfile, purpose: AIPurpose,
                sources: AISourceSelection, spendingAllowance: AICostEstimate, grantedAt: Date = Date()) {
        id = UUID()
        scope = .automation(ruleID: ruleID)
        profileID = profile.id
        provider = profile.provider
        endpointHost = profile.endpoint.host
        modelID = profile.modelID
        credential = profile.credentialReference
        self.purpose = purpose
        sourceFingerprint = sources.fingerprint
        dataTypes = sources.dataTypes
        payloadSHA256 = nil
        self.spendingAllowance = spendingAllowance
        self.grantedAt = grantedAt
    }

    /// Every frozen field must match; nothing is inferred.
    public func covers(_ request: AIRequest) -> Bool {
        switch (scope, request.trigger) {
        case let (.oneRun(runID), .userAction):
            guard runID == request.runID, payloadSHA256 == request.payloadSHA256 else { return false }
        case let (.automation(ruleID), .automation(requestRule)):
            guard ruleID == requestRule else { return false }
        default:
            return false
        }
        return profileID == request.profile.id
            && provider == request.profile.provider
            && endpointHost == request.profile.endpoint.host
            && modelID == request.profile.modelID
            && credential == request.credential
            && purpose == request.purpose
            && sourceFingerprint == request.sources.fingerprint
            && dataTypes == request.sources.dataTypes
            && request.estimate.fits(within: spendingAllowance)
    }
}

public enum AIConsentDecision: Sendable, Equatable {
    case granted(AIConsentGrant)
    case denied
    /// No answer yet (no host to ask, or the answer is still awaited).
    case pending
    /// The sheet was dismissed, its host closed, or the task cancelled.
    case cancelled
}

/// Asks the customer about one frozen request.
public protocol AIConsentBroker: Sendable {
    func decide(_ request: AIRequest) async -> AIConsentDecision
}

/// Which grants are still in force. Revocation is checked again immediately
/// before any transport call.
public final class AIGrantRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var active: [UUID: AIConsentGrant] = [:]
    private var revoked: Set<UUID> = []

    public init() {}

    public func record(_ grant: AIConsentGrant) {
        lock.withLock {
            guard !revoked.contains(grant.id) else { return }
            active[grant.id] = grant
        }
    }

    public func revoke(_ id: UUID) {
        lock.withLock {
            active[id] = nil
            revoked.insert(id)
        }
    }

    public func revokeAll() {
        lock.withLock {
            revoked.formUnion(active.keys)
            active.removeAll()
        }
    }

    public func isActive(_ id: UUID) -> Bool { lock.withLock { active[id] != nil && !revoked.contains(id) } }
    public var activeCount: Int { lock.withLock { active.count } }
}

// MARK: - Resolve exactly once

/// A value that can be set once. Later attempts are ignored and counted.
public final class AIOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    private var extra = 0

    public init() {}

    /// True for the first call only.
    @discardableResult
    public func resolve(_ v: Value) -> Bool {
        lock.withLock {
            guard value == nil else { extra += 1; return false }
            value = v
            return true
        }
    }

    public var resolved: Value? { lock.withLock { value } }
    public var ignoredResolutions: Int { lock.withLock { extra } }
}

/// The consent queue a future consent sheet would drive. Each request waits
/// for an answer; `answer`, `dismissAll` (host closed) and task cancellation
/// all race, and the waiting continuation is resumed exactly once.
public final class AIPendingConsentQueue: AIConsentBroker, @unchecked Sendable {
    private final class Entry: @unchecked Sendable {
        let request: AIRequest
        let once = AIOnce<AIConsentDecision>()
        var continuation: CheckedContinuation<AIConsentDecision, Never>?
        init(request: AIRequest) { self.request = request }
    }

    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]
    private var resumed = 0
    private var ignored = 0
    /// Called (on the caller's executor) when a request starts waiting.
    private let onPending: (@Sendable (AIRequest) -> Void)?

    public init(onPending: (@Sendable (AIRequest) -> Void)? = nil) {
        self.onPending = onPending
    }

    public var pendingRunIDs: [UUID] { lock.withLock { Array(entries.keys) } }
    /// Continuations resumed — must equal the number of `decide` calls.
    public var resumedCount: Int { lock.withLock { resumed } }
    /// Answers that arrived after the request had already resolved.
    public var ignoredAnswers: Int { lock.withLock { ignored } }

    public func decide(_ request: AIRequest) async -> AIConsentDecision {
        let entry = Entry(request: request)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<AIConsentDecision, Never>) in
                let early: AIConsentDecision? = lock.withLock {
                    if let decided = entry.once.resolved { return decided }
                    entry.continuation = continuation
                    entries[request.runID] = entry
                    return nil
                }
                if let early {
                    finish(entry, early, continuation: continuation)
                } else {
                    onPending?(request)
                }
            }
        } onCancel: {
            resolve(entry, .cancelled)
        }
    }

    /// The customer's answer for one run.
    public func answer(runID: UUID, _ decision: AIConsentDecision) {
        let entry: Entry? = lock.withLock { entries[runID] }
        guard let entry else {
            lock.withLock { ignored += 1 }
            return
        }
        resolve(entry, decision)
    }

    /// The sheet's host closed: every waiting request is cancelled.
    public func dismissAll() {
        let all: [Entry] = lock.withLock { Array(entries.values) }
        for entry in all { resolve(entry, .cancelled) }
    }

    private func resolve(_ entry: Entry, _ decision: AIConsentDecision) {
        let continuation: CheckedContinuation<AIConsentDecision, Never>? = lock.withLock {
            guard entry.once.resolve(decision) else {
                ignored += 1
                return nil
            }
            let c = entry.continuation
            entry.continuation = nil
            return c
        }
        // No continuation yet: `decide` will see `resolved` and finish itself.
        if let continuation { finish(entry, decision, continuation: continuation) }
    }

    private func finish(_ entry: Entry, _ decision: AIConsentDecision,
                        continuation: CheckedContinuation<AIConsentDecision, Never>) {
        lock.withLock {
            entries[entry.request.runID] = nil
            resumed += 1
        }
        continuation.resume(returning: decision)
    }
}

// MARK: - Source eligibility

public protocol AISourceEligibility: Sendable {
    /// nil = every item may go to this profile.
    func refusal(for sources: AISourceSelection, profile: AIProviderProfile) -> AIFailure?
}

/// The source rule (§13.8). File-imported mail may be eligible; Gmail-origin
/// content stays local until the Google data-use route is approved (Limited
/// Use / assessment); organisation mail (Graph, IMAP) and unknown origins
/// need an explicit decision. Provenance is the stored origin, so renaming or
/// re-exporting a Gmail message does not change it.
public struct AISourcePolicy: AISourceEligibility {
    public var allowedOrigins: Set<AISourceOrigin>
    public var gmailRouteApproved: Bool

    public init(allowedOrigins: Set<AISourceOrigin> = [.fileImport], gmailRouteApproved: Bool = false) {
        self.allowedOrigins = allowedOrigins
        self.gmailRouteApproved = gmailRouteApproved
    }

    public func refusal(for sources: AISourceSelection, profile: AIProviderProfile) -> AIFailure? {
        for item in sources.items {
            switch item.origin {
            case .gmail:
                guard gmailRouteApproved, allowedOrigins.contains(.gmail) else { return .sourceIneligible(origin: .gmail) }
            case .unknown:
                return .sourceIneligible(origin: .unknown)
            default:
                guard allowedOrigins.contains(item.origin) else { return .sourceIneligible(origin: item.origin) }
            }
        }
        return nil
    }
}
