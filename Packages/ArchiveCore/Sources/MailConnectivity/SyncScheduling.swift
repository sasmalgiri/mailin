//
//  SyncScheduling.swift
//  MailConnectivity
//
//  Plan v4 V4-04 (§5.3): the shared pieces every account's `SyncEngine`
//  uses — a fair download scheduler across accounts, the backoff policy and
//  the storage probe.
//

import Foundation

// MARK: - Fair scheduler

/// Download slots shared by every account's engine. A slot is handed out
/// round-robin over the accounts that are waiting, so one account with a
/// large backlog never starves another; each account also respects its own
/// provider limit. An account that is backing off holds NO slot while it
/// waits (the engine releases before sleeping), so a throttled, quota-paused
/// or revoked account cannot stall the others.
public actor FairDownloadScheduler {
    public let totalSlots: Int
    private var inUse = 0
    private var perAccount: [UUID: Int] = [:]
    private struct Waiter { let id: UInt64; let limit: Int; let continuation: CheckedContinuation<Void, Error> }
    private var waiting: [UUID: [Waiter]] = [:]
    /// Accounts in the order they are served; the head was served longest ago.
    private var rotation: [UUID] = []
    private var nextID: UInt64 = 0
    private(set) var peakInUse = 0

    public init(totalSlots: Int = 6) {
        self.totalSlots = max(1, totalSlots)
    }

    /// Waits for a slot for `account` (at most `accountLimit` at once).
    public func acquire(account: UUID, accountLimit: Int) async throws {
        try Task.checkCancellation()
        let limit = max(1, accountLimit)
        if waiting[account, default: []].isEmpty, canGrant(account, limit: limit), !othersWaiting(than: account) {
            grant(account)
            return
        }
        nextID += 1
        let id = nextID
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { c.resume(throwing: CancellationError()); return }
                waiting[account, default: []].append(Waiter(id: id, limit: limit, continuation: c))
                if !rotation.contains(account) { rotation.append(account) }
                dispatch()
            }
        } onCancel: {
            Task { await self.cancelWaiter(account: account, id: id) }
        }
    }

    public func release(account: UUID) {
        inUse = max(0, inUse - 1)
        perAccount[account] = max(0, (perAccount[account] ?? 1) - 1)
        dispatch()
    }

    public var slotsInUse: Int { inUse }
    public func peak() -> Int { peakInUse }

    private func canGrant(_ account: UUID, limit: Int) -> Bool {
        inUse < totalSlots && (perAccount[account] ?? 0) < limit
    }

    private func othersWaiting(than account: UUID) -> Bool {
        waiting.contains { $0.key != account && !$0.value.isEmpty }
    }

    private func grant(_ account: UUID) {
        inUse += 1
        peakInUse = max(peakInUse, inUse)
        perAccount[account, default: 0] += 1
        // The account just served goes to the back of the rotation.
        rotation.removeAll { $0 == account }
        rotation.append(account)
    }

    private func dispatch() {
        var progressed = true
        while progressed && inUse < totalSlots {
            progressed = false
            for account in rotation {
                guard var queue = waiting[account], let head = queue.first, canGrant(account, limit: head.limit) else { continue }
                queue.removeFirst()
                waiting[account] = queue.isEmpty ? nil : queue
                grant(account)
                head.continuation.resume()
                progressed = true
                break
            }
        }
    }

    private func cancelWaiter(account: UUID, id: UInt64) {
        guard var queue = waiting[account], let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let waiter = queue.remove(at: index)
        waiting[account] = queue.isEmpty ? nil : queue
        waiter.continuation.resume(throwing: CancellationError())
    }
}

// MARK: - Backoff

/// Exponential backoff with jitter, honouring Retry-After. The clock is
/// injected so tests run without real waiting and can prove there is no busy
/// loop (every retry is preceded by a recorded wait).
public struct BackoffPolicy: Sendable {
    /// First delay (seconds) for a transient failure.
    public var base: TimeInterval
    /// Longest single delay.
    public var maximum: TimeInterval
    /// Transient failures of ONE request before the item is recorded failed
    /// (with its reason, retried on the next sync) — a retry budget, not a cap
    /// on the mailbox.
    public var transientAttempts: Int
    /// Total throttling wait in one run before the account pauses and reports
    /// "rate limited" instead of waiting on.
    public var maximumThrottleWait: TimeInterval
    /// Returns a value in 0...1.
    public var jitter: @Sendable () -> Double
    /// Waits `seconds`; throws CancellationError when cancelled.
    public var sleep: @Sendable (TimeInterval) async throws -> Void

    public init(base: TimeInterval = 1, maximum: TimeInterval = 300, transientAttempts: Int = 6,
                maximumThrottleWait: TimeInterval = 1_800,
                jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
                    try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                }) {
        self.base = base; self.maximum = maximum; self.transientAttempts = max(1, transientAttempts)
        self.maximumThrottleWait = maximumThrottleWait; self.jitter = jitter; self.sleep = sleep
    }

    /// Delay before retry number `attempt` (1-based): full exponential step,
    /// "equal jitter" (half fixed, half random), never below Retry-After.
    public func delay(attempt: Int, retryAfter: TimeInterval?) -> TimeInterval {
        let exponent = min(max(0, attempt - 1), 30)
        let step = min(maximum, base * pow(2, Double(exponent)))
        let jittered = step / 2 + step / 2 * min(1, max(0, jitter()))
        if let retryAfter { return max(retryAfter, 0) + jittered / 10 }
        return jittered
    }
}

// MARK: - Storage

/// Free space where the archive lives, and whether that volume is present.
public struct StorageProbe: Sendable {
    /// Bytes available to the archive volume; nil = the volume is unreachable.
    public var availableBytes: @Sendable (URL) -> Int64?
    /// Kept free beyond the next message (database growth, other jobs).
    public var reserveBytes: Int64

    public init(reserveBytes: Int64 = 256 * 1_048_576,
                availableBytes: @escaping @Sendable (URL) -> Int64? = StorageProbe.volumeAvailableBytes) {
        self.reserveBytes = reserveBytes; self.availableBytes = availableBytes
    }

    public static let volumeAvailableBytes: @Sendable (URL) -> Int64? = { url in
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }
}
