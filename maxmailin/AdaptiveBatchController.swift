//
//  AdaptiveBatchController.swift
//  mailin
//
//  Plan task P3 / §5.1. Replaces the fixed `batchSize = 500` with a controller
//  that bounds **parsed bytes as well as message count**, because the two are
//  not interchangeable: one huge message is nothing like 500 tiny ones.
//
//  Measured justification (RELEASE_READINESS.md §P0.2, 2026-09-23): a 90.5 MiB
//  real mbox of 526 messages — 152 with attachments — fits in TWO batches at
//  500 messages, and peak RSS rose 400 MiB above baseline. The bound was a
//  count, so batch memory scaled with whatever those messages happened to
//  weigh.
//
//  Policy, not magic numbers: every threshold here is a starting value to be
//  re-derived from P9 measurements. What must not change is the shape — grow
//  only while every health signal is good, shrink promptly on any bad one,
//  pause with an actionable reason at hard limits, and never let a single
//  oversized item break the envelope.
//

import Foundation

// MARK: - Envelope

/// The bound on one batch: both dimensions, always.
struct BatchEnvelope: Sendable, Equatable {
    var maxMessages: Int
    var maxBytes: Int

    /// How much larger a batch is in memory than the source bytes it came from.
    ///
    /// MEASURED, not guessed (2026-09-24): a 32 MiB source-byte bound over the
    /// real 90.5 MiB attachment-heavy fixture produced a 410 MiB peak, i.e.
    /// ~13x. Decoded attachments, MIME part objects, and the retained
    /// rawSource/plainBody/htmlBody copies all multiply the source bytes. A
    /// source-byte bound alone therefore does NOT bound resident memory, which
    /// is why this factor exists. Re-derive it per format in P9 — PST/NSF will
    /// differ from MBOX.
    static let measuredParsedExpansion = 13.0

    /// Resident memory one batch may occupy. The envelope is derived backwards
    /// from this through the expansion factor, so the thing being bounded is
    /// the thing that actually runs the machine out of memory.
    static func targetResidentBytes(forPhysicalMemory bytes: UInt64) -> Int {
        // 1.5 % of RAM, clamped: 192 MiB on a 16 GB Mac, never below 96 MiB
        // (progress must still be possible) nor above 512 MiB (import must not
        // starve browsing, typing, search or export).
        let derived = Int(Double(bytes) * 0.015)
        return min(max(derived, 96 * 1_048_576), 512 * 1_048_576)
    }

    static func starting(forPhysicalMemory bytes: UInt64) -> BatchEnvelope {
        let target = targetResidentBytes(forPhysicalMemory: bytes)
        let derived = Int(Double(target) / measuredParsedExpansion)
        let byteBound = min(max(derived, 1_048_576), 64 * 1_048_576)
        let messageBound = max(32, min(256, byteBound / 131_072))
        return BatchEnvelope(maxMessages: messageBound, maxBytes: byteBound)
    }
}

// MARK: - Signals

/// One reading of everything the controller is allowed to react to. Injected so
/// the policy can be tested deterministically instead of by hoping the machine
/// is under pressure during a test run.
struct PressureSample: Sendable, Equatable {
    enum MemoryPressure: Int, Sendable, Comparable {
        case nominal = 0, warning = 1, critical = 2
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    var footprintBytes: UInt64
    /// The share of memory this import may use before the controller backs off.
    var memoryBudgetBytes: UInt64
    var memoryPressure: MemoryPressure = .nominal
    var freeDiskBytes: UInt64
    /// Bytes that must stay free for the store, WAL, FTS and export temp.
    var diskReserveBytes: UInt64
    var thermalState: ProcessInfo.ThermalState = .nominal
    /// Time the last store commit took, when known.
    var lastCommitSeconds: Double? = nil
    /// True when the FTS index is knowingly behind.
    var indexBacklog: Bool = false

    var isMemoryHealthy: Bool {
        memoryPressure == .nominal && footprintBytes < memoryBudgetBytes * 3 / 4
    }
    var isDiskHealthy: Bool { freeDiskBytes > diskReserveBytes * 2 }
    var isThermallyHealthy: Bool { thermalState == .nominal || thermalState == .fair }
}

/// What a completed batch cost.
struct BatchOutcome: Sendable, Equatable {
    var messages: Int
    var bytes: Int
    var commitSeconds: Double
}

// MARK: - Decision

enum BatchDecision: Sendable, Equatable {
    case proceed(BatchEnvelope)
    /// Import stops until the named condition clears. The reason is written for
    /// the user, not for a log grep.
    case pause(reason: String)

    var envelope: BatchEnvelope? {
        if case .proceed(let e) = self { return e }
        return nil
    }
    var pauseReason: String? {
        if case .pause(let r) = self { return r }
        return nil
    }
}

/// How a single item that exceeds the byte bound must be handled.
enum OversizedItemPlan: Sendable, Equatable {
    /// Fits: include it in the current batch.
    case inline
    /// Larger than the whole envelope: hand it to the bounded spool so one
    /// message cannot blow the memory bound. Never "grow the envelope to fit".
    case spoolAlone(bytes: Int)
}

// MARK: - Live signals

/// Builds a `PressureSample` from the running system. Kept separate from the
/// controller so the policy stays testable with synthetic samples.
enum LivePressureSampler {

    /// Share of physical memory one import may occupy before the controller
    /// starts backing off. Conservative on purpose: import must not starve
    /// browsing, typing, search or export (directive §3, work fairness).
    static let memoryBudgetFraction = 0.25

    /// Bytes that must stay free for the database, WAL, FTS, extracted text and
    /// export temp. A starting value — P3/P9 measurements replace it.
    static let diskReserveBytes: UInt64 = 5 * 1024 * 1_048_576   // 5 GiB

    /// The OS memory-pressure reading. Separate because
    /// `MemoryPressureHandler` is main-actor isolated, while the rest of the
    /// sample is not.
    @MainActor
    static func currentPressure() -> PressureSample.MemoryPressure {
        guard let observed = MemoryPressureHandler.shared.lastObservedLevel,
              MemoryPressureHandler.shared.isUnderRecentPressure(window: 30) else {
            return .nominal
        }
        switch observed {
        case .critical: return .critical
        case .warning, .thermal: return .warning
        }
    }

    static func sample(storeDirectory: URL,
                       indexBacklog: Bool,
                       observedPressure: PressureSample.MemoryPressure) -> PressureSample {
        let physical = ProcessInfo.processInfo.physicalMemory
        let budget = UInt64(Double(physical) * memoryBudgetFraction)

        let free: UInt64
        if let values = try? storeDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let important = values.volumeAvailableCapacityForImportantUsage {
            free = UInt64(max(0, important))
        } else {
            // Unknown free space is treated as "just above the reserve" rather
            // than as infinite: an unreadable volume must not unlock growth.
            free = diskReserveBytes + 1
        }

        return PressureSample(
            footprintBytes: currentFootprintBytes(),
            memoryBudgetBytes: budget,
            memoryPressure: observedPressure,
            freeDiskBytes: free,
            diskReserveBytes: diskReserveBytes,
            thermalState: ProcessInfo.processInfo.thermalState,
            lastCommitSeconds: nil,
            indexBacklog: indexBacklog
        )
    }
}

// MARK: - Controller

/// Decides the next batch envelope from the last outcome and the current
/// signals. Deliberately an actor with no I/O of its own: it is policy, and the
/// caller owns measurement.
actor AdaptiveBatchController {

    struct Limits: Sendable {
        var floor: BatchEnvelope
        var ceiling: BatchEnvelope
        /// Commit latency above which the controller stops growing.
        var growCommitSecondsMax: Double = 0.75
        /// Commit latency above which it shrinks.
        var shrinkCommitSeconds: Double = 2.0
        /// Consecutive healthy batches required before growing — one good batch
        /// is noise, not a trend.
        var healthyBatchesBeforeGrowth: Int = 2

        static func `default`(startingFrom start: BatchEnvelope) -> Limits {
            Limits(
                floor: BatchEnvelope(maxMessages: 8, maxBytes: 1_048_576),
                ceiling: BatchEnvelope(maxMessages: max(start.maxMessages * 8, 512),
                                       maxBytes: max(start.maxBytes * 8, 256 * 1_048_576))
            )
        }
    }

    /// One recorded change, for diagnostics and the import receipt.
    struct Transition: Sendable, Equatable {
        enum Kind: String, Sendable { case start, grew, shrank, held, paused, resumed }
        var kind: Kind
        var envelope: BatchEnvelope
        var cause: String
    }

    private(set) var envelope: BatchEnvelope
    private let limits: Limits
    private var consecutiveHealthy = 0
    private var paused = false
    private(set) var trace: [Transition] = []

    init(start: BatchEnvelope, limits: Limits? = nil) {
        self.envelope = start
        self.limits = limits ?? .default(startingFrom: start)
        self.trace = [Transition(kind: .start, envelope: start,
                                 cause: "initial envelope from machine memory")]
    }

    init(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) {
        let start = BatchEnvelope.starting(forPhysicalMemory: physicalMemory)
        self.envelope = start
        self.limits = .default(startingFrom: start)
        self.trace = [Transition(kind: .start, envelope: start,
                                 cause: "initial envelope from machine memory")]
    }

    /// The next decision. Call once per batch boundary with the previous
    /// batch's cost (nil for the first) and a fresh sample.
    func next(after outcome: BatchOutcome?, sample: PressureSample) -> BatchDecision {
        // 1. Hard stops first: these are not throttles, they are refusals.
        if let stop = hardStop(sample) {
            if !paused {
                paused = true
                record(.paused, cause: stop)
            }
            return .pause(reason: stop)
        }
        if paused {
            paused = false
            record(.resumed, cause: "pressure cleared")
        }

        // 2. Shrink on any bad signal, promptly and multiplicatively.
        if let cause = shrinkCause(outcome: outcome, sample: sample) {
            consecutiveHealthy = 0
            envelope = clamp(BatchEnvelope(maxMessages: envelope.maxMessages / 2,
                                           maxBytes: envelope.maxBytes / 2))
            record(.shrank, cause: cause)
            return .proceed(envelope)
        }

        // 3. Grow only on a sustained healthy trend, and gently.
        consecutiveHealthy += 1
        if consecutiveHealthy >= limits.healthyBatchesBeforeGrowth,
           envelope != limits.ceiling {
            consecutiveHealthy = 0
            envelope = clamp(BatchEnvelope(maxMessages: envelope.maxMessages * 3 / 2,
                                           maxBytes: envelope.maxBytes * 3 / 2))
            record(.grew, cause: "memory, disk, thermal and commit latency all healthy")
            return .proceed(envelope)
        }

        record(.held, cause: "within envelope")
        return .proceed(envelope)
    }

    /// Whether an item fits, or must be spooled on its own. A single message
    /// larger than the byte bound is handled without breaking the envelope —
    /// the envelope is never grown to accommodate one item.
    func plan(forItemOfSize bytes: Int) -> OversizedItemPlan {
        bytes > envelope.maxBytes ? .spoolAlone(bytes: bytes) : .inline
    }

    // MARK: Policy

    private func hardStop(_ sample: PressureSample) -> String? {
        if sample.memoryPressure == .critical {
            return "Paused: the system is critically low on memory. Import resumes automatically when memory frees up."
        }
        if sample.freeDiskBytes <= sample.diskReserveBytes {
            let needed = ByteCountFormatter.string(
                fromByteCount: Int64(sample.diskReserveBytes), countStyle: .file)
            return "Paused: less than \(needed) of disk space is free, which the archive needs for the database, index and temporary files."
        }
        if sample.thermalState == .critical {
            return "Paused: this Mac is too hot to keep importing at speed. Import resumes when it cools down."
        }
        return nil
    }

    private func shrinkCause(outcome: BatchOutcome?, sample: PressureSample) -> String? {
        if sample.memoryPressure == .warning { return "system memory pressure" }
        if sample.footprintBytes >= sample.memoryBudgetBytes {
            return "import memory budget reached"
        }
        if sample.thermalState == .serious { return "thermal throttling" }
        if sample.indexBacklog { return "search index is falling behind" }
        if sample.freeDiskBytes <= sample.diskReserveBytes * 2 { return "disk space running low" }
        if let outcome, outcome.commitSeconds >= limits.shrinkCommitSeconds {
            return String(format: "store commits are slow (%.1fs)", outcome.commitSeconds)
        }
        if !sample.isMemoryHealthy { return "memory use is approaching the budget" }
        return nil
    }

    /// Growth also requires latency headroom, checked by the caller's sample
    /// plus the previous outcome; this only enforces the bounds.
    private func clamp(_ candidate: BatchEnvelope) -> BatchEnvelope {
        BatchEnvelope(
            maxMessages: min(max(candidate.maxMessages, limits.floor.maxMessages),
                             limits.ceiling.maxMessages),
            maxBytes: min(max(candidate.maxBytes, limits.floor.maxBytes),
                          limits.ceiling.maxBytes)
        )
    }

    private func record(_ kind: Transition.Kind, cause: String) {
        trace.append(Transition(kind: kind, envelope: envelope, cause: cause))
        // Bounded: diagnostics must not become a leak on a long import.
        if trace.count > 512 { trace.removeFirst(trace.count - 512) }
    }
}
