//
//  ProcessFootprint.swift
//  ArchiveCore
//
//  Moved from the app's StressHarness in C-1: the adaptive batch controller
//  samples the process footprint from inside the package.
//

import Foundation

/// Current physical memory footprint (bytes) — the same accounting Xcode's
/// memory gauge and the OS Jetsam limit use (`phys_footprint`).
func currentFootprintBytes() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
    )
    let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
}
