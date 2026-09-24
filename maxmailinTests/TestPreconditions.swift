//
//  TestPreconditions.swift
//  maxmailinTests
//
//  Environment preconditions, so a full disk reports as a SKIP with the
//  reason rather than as a defect in the code.
//
//  This exists because of a real afternoon lost to it. With the volume at 95%
//  (10 GiB free of 228), tests that write ~190 MB through SQLite began failing
//  with `step("disk I/O error")` and `CancellationError`. The failure MOVED
//  between runs — `testProductionPathImport` once, `testArchive_exportsMBOX`
//  the next time — which is the signature of resource exhaustion, but each
//  individual report looked exactly like a store bug. Clearing 1.3 GB made
//  them all pass again on unchanged code.
//
//  For a tool whose whole value is telling the truth about what it did, a test
//  suite that says "disk I/O error" when it means "your disk is full" is the
//  wrong failure. A skip that names the shortfall is diagnosable in seconds.
//

import XCTest
@testable import maxmailin

enum TestPreconditions {

    /// Skips the calling test when the volume holding `directory` has less
    /// than `requiredBytes` free.
    ///
    /// The margin is deliberately several times the test's own write: SQLite
    /// needs the database, its WAL, and temp space for a checkpoint, and the
    /// error it raises when any of those cannot be written does not say which.
    static func requireFreeSpace(_ requiredBytes: Int64,
                                 at directory: URL = FileManager.default.temporaryDirectory,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) throws {
        let probe = StoragePlanner.nearestExistingDirectory(of: directory)
        let values = try? probe.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = values?.volumeAvailableCapacityForImportantUsage else {
            // Unreadable free space is not a reason to skip — it is a reason
            // to proceed and let the real failure speak, because an unreadable
            // volume is itself worth seeing.
            return
        }
        let freeBytes = Int64(free)
        guard freeBytes < requiredBytes else { return }

        func gb(_ b: Int64) -> String {
            ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
        }
        throw XCTSkip("""
            Skipped: this test writes through SQLite and needs about \(gb(requiredBytes)) \
            free, but only \(gb(freeBytes)) is available on the volume holding \
            \(probe.path). This is an environment shortfall, not a defect — the test \
            passes on the same code with headroom. Free space and re-run.
            """, file: file, line: line)
    }

    /// Budget for a test that imports and re-exports the ~95 MB reference
    /// fixture: ~190 MB of payload, times a factor for WAL, index and
    /// checkpoint temp space.
    static let referenceFixtureBudget: Int64 = 2 * 1_073_741_824      // 2 GiB

    /// Budget for the 2,000-row scale test and the large synthetic mailboxes.
    static let scaleFixtureBudget: Int64 = 1_073_741_824              // 1 GiB
}
