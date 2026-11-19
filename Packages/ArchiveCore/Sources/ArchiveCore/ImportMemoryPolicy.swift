import Foundation
#if canImport(Darwin)
import Darwin
#endif
#if os(iOS)
import os
#endif

/// Soft budgets, not allocations or a promise that a parser cannot overshoot.
/// Reserve space for the OS/other apps, then spend headroom on useful caches
/// and bounded batches. Never load the archive merely to fill unused RAM.
enum ImportMemoryPolicy {
    static let mib: UInt64 = 1_048_576

    static var isDesktop: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    static func footprintLimit(physical: UInt64, footprint: UInt64,
                               available: UInt64?, desktop: Bool) -> UInt64 {
        let ceiling = min(physical / 4, (desktop ? 8_192 : 1_024) * mib)
        // If sampling fails, do not assume the rest of physical RAM is free.
        guard let available else { return min(ceiling, 1_024 * mib) }
        let reserve = desktop ? max(512 * mib, physical / 16) : 256 * mib
        let spare = available > reserve ? available - reserve : 0
        let increment = spare / 2
        return min(ceiling, footprint > UInt64.max - increment ? UInt64.max : footprint + increment)
    }

    /// At 16 GiB with healthy headroom: 512 MiB SQLite cache, 256 MiB mmap,
    /// and 8 MiB per FTS shard (at most 20). SQLite fills caches on demand.
    /// Quantize to avoid changing PRAGMAs at every small fluctuation.
    static func storeBudget(limit: UInt64, constrained: Bool,
                            desktop: Bool) -> SQLiteEmailStore.MemoryBudget {
        guard desktop, !constrained else { return SQLiteEmailStore.importBudget }
        let wantedMiB = min(512, limit / 8 / mib)
        var cacheMiB: UInt64 = 32
        while cacheMiB * 2 <= wantedMiB { cacheMiB *= 2 }
        return .init(cacheKB: Int(cacheMiB * 1_024),
                     mmapBytes: Int(min(256, cacheMiB) * mib))
    }

    static func shardCacheKB(storeBudget: SQLiteEmailStore.MemoryBudget) -> Int {
        min(8_192, max(2_048, storeBudget.cacheKB / 64))
    }

    /// Batches that can be resident at once: the one being committed and the
    /// one the parser prepares meanwhile (PERF-04, one batch ahead).
    static let residentBatches: UInt64 = 2

    /// A quarter of the process budget, and no more than half the remaining
    /// process headroom, may be represented by the batches in flight; each
    /// batch gets its share of that.
    static func batchSourceBytes(limit: UInt64, footprint: UInt64) -> Int {
        let headroom = limit > footprint ? limit - footprint : 0
        let resident = min(1_024 * mib, min(limit / 4, headroom / 2)) / residentBatches
        return max(1_048_576, Int(Double(resident) / BatchEnvelope.measuredParsedExpansion))
    }

    /// Fresh advisory sample. macOS has no per-app jetsam allowance API:
    /// count free + inactive pages conservatively; exclude compressed pages.
    static func availableBytes() -> UInt64? {
        #if os(macOS)
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        // `vm_kernel_page_size` is a mutable global (not concurrency-safe under
        // Swift 6); the page size from libc is the same constant.
        return (UInt64(info.free_count) + UInt64(info.inactive_count)) * UInt64(getpagesize())
        #elseif os(iOS)
        return UInt64(os_proc_available_memory())
        #else
        return nil
        #endif
    }
}
