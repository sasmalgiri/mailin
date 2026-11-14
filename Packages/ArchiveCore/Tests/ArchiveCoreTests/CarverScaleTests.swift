//
//  CarverScaleTests.swift
//  ArchiveCoreTests
//
//  3.1 R9 done-means: 1 GB of random data with messages planted at known
//  places — every planted message found, nothing else, memory flat.
//  Opt-in (writes 1 GB to the temporary folder):
//    MAILIN_SCALE=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
//      xcrun swift test -c release --package-path Packages/ArchiveCore --filter CarverScaleTests
//

import XCTest
import Foundation
@testable import ArchiveCore

final class CarverScaleTests: XCTestCase {
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }

    func testOneGigabyte_randomWithPlantedMessages() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MAILIN_SCALE"] == "1", "opt-in: MAILIN_SCALE=1")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("carve-1g-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let h = try FileHandle(forWritingTo: url)
        let planted = Int(ProcessInfo.processInfo.environment["MAILIN_CARVE_PLANTED"] ?? "100") ?? 100
        let chunk = 10 * 1_048_576
        var rng = SystemRandomNumberGenerator()
        for i in 0..<planted {
            var block = [UInt8](repeating: 0, count: chunk)
            for j in stride(from: 0, to: chunk, by: 8) {
                let v = rng.next() as UInt64
                withUnsafeBytes(of: v) { b in for k in 0..<8 where j + k < chunk { block[j + k] = b[k] } }
            }
            try h.write(contentsOf: Data(block))
            let msg = "\nFrom: s\(i)@example.com\nTo: r@example.org\nSubject: planted \(i)\nDate: Mon, 6 Jan 2025 10:00:00 +0000\nMessage-ID: <planted\(i)@example.com>\n\nplanted body \(i)\n"
            try h.write(contentsOf: Data(msg.utf8))
        }
        try h.close()

        let before = Self.footprint()
        var peak = before
        var found = Set<String>()
        let start = Date()
        let r = try await MIMECarver.carve(url: url, batchSize: 50, emit: { batch in
            for e in batch { if let s = e.headers["Subject"] { found.insert(s) } }
            peak = max(peak, Self.footprint())
        }, progress: { done, _ in
            let f = Self.footprint(); peak = max(peak, f)
            if done % (100 * 1_048_576) < 1_048_576 { print("CARVE-MEM \(done / 1_048_576) MB read: +\((Int64(f) - Int64(before)) / 1_048_576) MB") }
        })
        let seconds = Date().timeIntervalSince(start)
        print("CARVE-1G: \(r.bytesScanned) bytes, \(r.kept) kept, \(r.rejected) rejected, \(Int(seconds)) s, peak +\((peak - before) / 1_048_576) MB")
        XCTAssertEqual(r.kept, planted)
        XCTAssertEqual(found, Set((0..<planted).map { "planted \($0)" }))
        XCTAssertLessThan(peak - before, 256 * 1_048_576, "memory stays flat")
    }
}
