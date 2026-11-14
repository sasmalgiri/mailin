//
//  AIRequestCoordinator.swift
//  ArchiveCore — AIScaffold
//
//  Plan v4 SCAF-01/03/04 (§12.2 "one coordinator enforces entitlements and
//  policy", §13.3): the one door every future AI request goes through. In this
//  release it is constructed with `UnavailableAITransport`, so the answer is
//  always a refusal; the order of checks is what a future runtime inherits.
//
//  Order, exactly:
//    1. Pro entitlement          (a saved key is not an entitlement, SCAF-04)
//    2. AI policy                (runtime shipped? AI on? endpoint; never a mail host)
//    3. source eligibility       (e.g. Gmail-origin stays local)
//    4. transport available      (no consent prompt for a request that cannot run)
//    5. budget pre-check         (unknown price is refused, not treated as free)
//    6. consent — awaited on the FROZEN request; denied / pending / cancelled
//       → zero transport calls; the grant must cover every frozen field
//    7. re-check after the await: cancellation, policy, entitlement, revocation
//    8. reserve budget
//    9. read the key by the frozen credential reference (never "the selected
//       provider's key")
//   10. transport — the request's own endpoint is the only destination
//   11. settle budget, write the ledger line (reported / uncertain)
//

import Foundation

/// The app's Pro entitlement, as the coordinator sees it. The app adapts its
/// existing `AccessPolicy`; no new purchase product exists for AI.
public protocol AIEntitlementGate: Sendable {
    var allowsAIWork: Bool { get }
}

public final class AIRequestCoordinator: @unchecked Sendable {
    public struct Counts: Sendable, Equatable {
        public var submitted = 0
        public var consentPrompts = 0
        public var transportInvocations = 0
        public var keyReads = 0
    }

    private let policy: AIPolicy
    private let entitlement: any AIEntitlementGate
    private let eligibility: any AISourceEligibility
    private let keys: AIKeyProfileStore
    private let consent: any AIConsentBroker
    private let grants: AIGrantRegistry
    private let budget: any AIBudget
    private let ledger: any AIUsageLedger
    private let transport: any AITransport
    private let provider: any AIProvider
    private let counters: AIScaffoldCounters

    private let lock = NSLock()
    private var counts = Counts()

    public init(policy: AIPolicy = .shared,
                entitlement: any AIEntitlementGate,
                eligibility: any AISourceEligibility = AISourcePolicy(),
                keys: AIKeyProfileStore = AIKeyProfileStore(),
                consent: any AIConsentBroker,
                grants: AIGrantRegistry = AIGrantRegistry(),
                budget: any AIBudget,
                ledger: any AIUsageLedger = InMemoryAIUsageLedger(),
                transport: any AITransport = AIProductionTransport.current,
                provider: any AIProvider = AIProviderAdapter(),
                counters: AIScaffoldCounters = .shared) {
        self.policy = policy
        self.entitlement = entitlement
        self.eligibility = eligibility
        self.keys = keys
        self.consent = consent
        self.grants = grants
        self.budget = budget
        self.ledger = ledger
        self.transport = transport
        self.provider = provider
        self.counters = counters
    }

    public var snapshot: Counts { lock.withLock { counts } }

    private func bump(_ change: (inout Counts) -> Void) { lock.withLock { change(&counts) } }

    private func refuse(_ request: AIRequest, _ failure: AIFailure) -> AIResult {
        counters.refused(failure)
        return .refused(request.runID, failure)
    }

    /// Every pre-consent check, in order. nil = may ask for consent.
    private func preflight(_ request: AIRequest) -> AIFailure? {
        if Task.isCancelled { return .cancelled }
        guard entitlement.allowsAIWork else { return .notEntitled }
        if let refusal = policy.refusal(for: request) { return refusal }
        if let refusal = eligibility.refusal(for: request.sources, profile: request.profile) { return refusal }
        guard transport.isAvailable else { return .transportUnavailable }
        return budget.wouldRefuse(request)
    }

    public func submit(_ request: AIRequest) async -> AIResult {
        bump { $0.submitted += 1 }
        counters.submitted()

        if let failure = preflight(request) { return refuse(request, failure) }

        // 6. Consent on the frozen value. Whatever the app's "selected
        // profile" becomes during the await, `request` cannot change.
        bump { $0.consentPrompts += 1 }
        counters.prompted()
        let grant: AIConsentGrant
        switch await consent.decide(request) {
        case .granted(let g): grant = g
        case .denied: return refuse(request, .consentDenied)
        case .pending: return refuse(request, .consentPending)
        case .cancelled: return refuse(request, .consentCancelled)
        }
        guard grant.covers(request) else { return refuse(request, .consentDoesNotCover) }
        grants.record(grant)

        // 7. Anything may have changed while the sheet was up.
        if Task.isCancelled { return refuse(request, .cancelled) }
        guard entitlement.allowsAIWork else { return refuse(request, .notEntitled) }
        if let refusal = policy.refusal(for: request) { return refuse(request, refusal) }
        guard grants.isActive(grant.id) else { return refuse(request, .consentRevoked) }

        // 8.
        let reservation: AIReservation
        switch budget.reserve(request) {
        case .reserved(let r): reservation = r
        case .refused(let failure): return refuse(request, failure)
        }

        // 9. The frozen reference — the profile in the request, nothing else.
        let secret: AISecret
        do {
            bump { $0.keyReads += 1 }
            guard let s = try keys.read(request.credential) else {
                budget.release(reservation)
                return refuse(request, .noCredential)
            }
            secret = s
        } catch let error as AIKeyStoreError {
            budget.release(reservation)
            return refuse(request, .keychain(status: error.osStatus ?? 0))
        } catch {
            budget.release(reservation)
            return refuse(request, .keychain(status: 0))
        }
        guard grants.isActive(grant.id), !Task.isCancelled else {
            budget.release(reservation)
            return refuse(request, Task.isCancelled ? .cancelled : .consentRevoked)
        }

        // 10.
        bump { $0.transportInvocations += 1 }
        counters.transported()
        let result = await provider.run(request, secret: secret, transport: transport)

        // 11. A call that reached the transport may be billable even if it failed.
        budget.settle(reservation, usage: result.usage)
        ledger.append(AIUsageEntry(request: request.record, consentGrantID: grant.id,
                                   billing: result.usage == nil ? .uncertain : .reported,
                                   usage: result.usage, outcome: Self.outcomeName(result.status)))
        if case .oneRun = grant.scope { grants.revoke(grant.id) }  // one run, one use
        return result
    }

    static func outcomeName(_ status: AIResultStatus) -> String {
        switch status {
        case .success: return "success"
        case .partial: return "partial"
        case .error: return "error"
        case .cancelled: return "cancelled"
        }
    }
}
