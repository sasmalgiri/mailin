//
//  AIBudget.swift
//  ArchiveCore — AIScaffold
//
//  Plan v4 SCAF-03 (§13.5): token / cost budget interfaces and the usage-
//  ledger contract. Counts in code (rule 8): estimates are computed locally,
//  never by asking a provider (a token-counting endpoint also transmits
//  content, §13.4).
//
//  Unknown price is NOT free: an unknown estimate never equals zero, never
//  fits inside a numeric allowance and is refused by a budget unless the
//  customer explicitly accepted unknown pricing for that budget.
//

import Foundation

// MARK: - Prices and estimates

/// A provider's published price for one model, with the date it was checked.
/// A nil rate means the rate is unknown, not zero.
public struct AIPriceTable: Sendable, Equatable, Codable {
    public let modelID: String
    public let inputPerMillionTokens: Decimal?
    public let outputPerMillionTokens: Decimal?
    public let currency: String
    public let checkedOn: Date

    public init(modelID: String, inputPerMillionTokens: Decimal?, outputPerMillionTokens: Decimal?,
                currency: String = "USD", checkedOn: Date) {
        self.modelID = modelID
        self.inputPerMillionTokens = inputPerMillionTokens
        self.outputPerMillionTokens = outputPerMillionTokens
        self.currency = currency
        self.checkedOn = checkedOn
    }
}

public enum AICostEstimate: Sendable, Hashable, Codable {
    case known(amount: Decimal, currency: String, priceTableDate: Date)
    case unknown

    /// Only a known zero is free. Unknown is never free.
    public var isFree: Bool {
        if case .known(let amount, _, _) = self { return amount == 0 }
        return false
    }

    public var isKnown: Bool { if case .known = self { return true } else { return false } }

    /// Whether this estimate fits inside `allowance`. Unknown fits only an
    /// allowance that is itself "unknown accepted"; a known amount never fits
    /// an unknown allowance (that would be a blank cheque), and currencies must match.
    public func fits(within allowance: AICostEstimate) -> Bool {
        switch (self, allowance) {
        case let (.known(a, ca, _), .known(b, cb, _)): return ca == cb && a <= b
        case (.unknown, .unknown): return true
        default: return false
        }
    }
}

/// Local, conservative token estimate: one token per three UTF-8 bytes,
/// rounded up. Errs high so a reservation covers the real count.
public enum AITokenEstimator {
    public static func inputTokens(_ payload: Data) -> Int { (payload.count + 2) / 3 }
}

public enum AICostEstimator {
    public static func estimate(inputTokens: Int, maxOutputTokens: Int, price: AIPriceTable?) -> AICostEstimate {
        guard let price, let input = price.inputPerMillionTokens, let output = price.outputPerMillionTokens else {
            return .unknown
        }
        let million = Decimal(1_000_000)
        let amount = Decimal(inputTokens) * input / million + Decimal(max(0, maxOutputTokens)) * output / million
        return .known(amount: amount, currency: price.currency, priceTableDate: price.checkedOn)
    }
}

// MARK: - Budget

public struct AIReservation: Sendable, Hashable {
    public let id: UUID
    public let runID: UUID
    public let estimate: AICostEstimate
}

public enum AIReservationOutcome: Sendable, Equatable {
    case reserved(AIReservation)
    case refused(AIFailure)
}

/// Reserve the worst permitted cost before a step starts; settle or release after.
public protocol AIBudget: Sendable {
    /// No reservation is made when the answer is a refusal.
    func reserve(_ request: AIRequest) -> AIReservationOutcome
    /// Pre-check without reserving (used before consent is asked).
    func wouldRefuse(_ request: AIRequest) -> AIFailure?
    func settle(_ reservation: AIReservation, usage: AIUsage?)
    func release(_ reservation: AIReservation)
}

/// Per-run and period limits in one currency. Concurrent reservations count
/// against the period limit together, so two parallel runs cannot both fit
/// into the space for one.
public final class AIRunBudget: AIBudget, @unchecked Sendable {
    public let currency: String
    public let perRunLimit: Decimal
    public let periodLimit: Decimal
    /// Explicit customer choice. Off by default: unknown prices are refused.
    public let acceptsUnknownPrice: Bool

    private let lock = NSLock()
    private var reserved: [UUID: Decimal] = [:]
    private var unknownReservations: Set<UUID> = []
    private var spent: Decimal = 0

    public init(currency: String = "USD", perRunLimit: Decimal, periodLimit: Decimal, acceptsUnknownPrice: Bool = false) {
        self.currency = currency
        self.perRunLimit = perRunLimit
        self.periodLimit = periodLimit
        self.acceptsUnknownPrice = acceptsUnknownPrice
    }

    public var reservedTotal: Decimal { lock.withLock { reserved.values.reduce(0, +) } }
    public var activeReservations: Int { lock.withLock { reserved.count + unknownReservations.count } }
    public var spentTotal: Decimal { lock.withLock { spent } }

    public func wouldRefuse(_ request: AIRequest) -> AIFailure? {
        lock.withLock { refusal(for: request.estimate) }
    }

    private func refusal(for estimate: AICostEstimate) -> AIFailure? {
        switch estimate {
        case .unknown:
            return acceptsUnknownPrice ? nil : .priceUnknown
        case .known(let amount, let cur, _):
            guard cur == currency else { return .priceUnknown }
            if amount > perRunLimit { return .budgetExceeded }
            if spent + reserved.values.reduce(0, +) + amount > periodLimit { return .budgetExceeded }
            return nil
        }
    }

    public func reserve(_ request: AIRequest) -> AIReservationOutcome {
        lock.withLock {
            if let failure = refusal(for: request.estimate) { return .refused(failure) }
            let reservation = AIReservation(id: UUID(), runID: request.runID, estimate: request.estimate)
            if case .known(let amount, _, _) = request.estimate {
                reserved[reservation.id] = amount
            } else {
                unknownReservations.insert(reservation.id)
            }
            return .reserved(reservation)
        }
    }

    /// Settles at the reserved amount: the provider's invoice is authoritative,
    /// and without a price table this budget cannot price returned usage more
    /// precisely than the reservation did.
    public func settle(_ reservation: AIReservation, usage: AIUsage?) {
        lock.withLock {
            if let amount = reserved.removeValue(forKey: reservation.id) { spent += amount }
            unknownReservations.remove(reservation.id)
        }
    }

    public func release(_ reservation: AIReservation) {
        lock.withLock {
            reserved[reservation.id] = nil
            unknownReservations.remove(reservation.id)
        }
    }
}

// MARK: - Usage ledger

/// What the provider reported for one call. Nil fields are unknown, not zero.
public struct AIUsage: Sendable, Hashable, Codable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cachedInputTokens: Int?
    public var reasoningTokens: Int?

    public init(inputTokens: Int?, outputTokens: Int?, cachedInputTokens: Int? = nil, reasoningTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.reasoningTokens = reasoningTokens
    }
}

/// How sure the ledger is about a charge.
public enum AIBillingCertainty: String, Sendable, Codable {
    /// The provider returned usage for this call.
    case reported
    /// The call reached the transport but no usage came back (timeout,
    /// disconnect, cancellation): it may still be billable (§13.5).
    case uncertain
}

/// One ledger line. Contract: never the secret, never the payload — only the
/// request record (hashes and references) and the outcome.
public struct AIUsageEntry: Sendable, Equatable, Codable {
    public let request: AIRequestRecord
    public let consentGrantID: UUID
    public let billing: AIBillingCertainty
    public let usage: AIUsage?
    public let outcome: String
    public let recordedAt: Date

    public init(request: AIRequestRecord, consentGrantID: UUID, billing: AIBillingCertainty, usage: AIUsage?,
                outcome: String, recordedAt: Date = Date()) {
        self.request = request
        self.consentGrantID = consentGrantID
        self.billing = billing
        self.usage = usage
        self.outcome = outcome
        self.recordedAt = recordedAt
    }
}

/// The ledger contract: one entry for every call that reached a transport —
/// and none for a request refused before it.
public protocol AIUsageLedger: Sendable {
    func append(_ entry: AIUsageEntry)
    func entries() -> [AIUsageEntry]
}

public final class InMemoryAIUsageLedger: AIUsageLedger, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [AIUsageEntry] = []
    public init() {}
    public func append(_ entry: AIUsageEntry) { lock.withLock { items.append(entry) } }
    public func entries() -> [AIUsageEntry] { lock.withLock { items } }
}
