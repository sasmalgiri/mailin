//
//  ImportWorkerPolicy.swift
//  ArchiveCore
//
//  FAST-02 (owner decision 2026-11-20): how many workers the fast import uses,
//  decided again before every batch from what the Mac can give right now.
//
//  • Readers (parse workers): every core but one while the Mac is cool and
//    the import is inside its memory share; half under heat, Low Power Mode or
//    memory over the share; one when the Mac is critically hot. The old fixed
//    count was min(cores − 1, 8).
//  • Writers: one per search-index year file, up to half the cores. The
//    archive file itself has one writer — SQLite allows one per file.
//  • Duplicate-pass workers: the same as readers (hashing is CPU work).
//

import Foundation

enum ImportWorkerPolicy {
    /// Share of physical memory the import may occupy before the policy halves
    /// its workers — the same share the batch controller uses.
    static var memoryShareBytes: UInt64 {
        UInt64(Double(ProcessInfo.processInfo.physicalMemory) * LivePressureSampler.memoryBudgetFraction)
    }

    static func readers(cores: Int = ProcessInfo.processInfo.activeProcessorCount,
                        thermal: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState,
                        lowPower: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled,
                        footprint: UInt64 = currentFootprintBytes(),
                        memoryShare: UInt64 = memoryShareBytes) -> Int {
        let full = max(1, cores - 1)
        switch thermal {
        case .critical: return 1
        case .serious: return max(1, full / 2)
        default: break
        }
        if lowPower || footprint > memoryShare { return max(1, full / 2) }
        return full
    }

    static func searchWriters(cores: Int = ProcessInfo.processInfo.activeProcessorCount,
                              thermal: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState) -> Int {
        if thermal == .critical || thermal == .serious { return 1 }
        return max(1, cores / 2)
    }

    static func duplicatePassWorkers() -> Int { readers() }

    /// `readers()` as a value, for the task-local and the parser hooks.
    static let readersNow: @Sendable () -> Int = { readers() }

    /// FAST-02: set by the fast import around the parse of one source, read by
    /// the PST/OST reader and the ZIP walk (which have no options parameter for
    /// it). Nil — every other import — keeps their one-at-a-time reading.
    @TaskLocal static var fastReaders: (@Sendable () -> Int)?
}
