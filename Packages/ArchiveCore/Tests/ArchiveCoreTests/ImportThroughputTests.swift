//
//  ImportThroughputTests.swift
//  ArchiveCoreTests
//
//  The one number the Debug rows in SCALE_RESULTS.md cannot give: import
//  throughput of the OPTIMISED build. The package is built with
//  `-enable-testing` in every configuration, so this runs under
//  `swift test -c release` as well as `swift test` — same code, same file,
//  same Mac, only the optimiser differs.
//
//  Run:   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
//         MAILIN_SCALE=1 xcrun swift test -c release --package-path Packages/ArchiveCore \
//         --filter ImportThroughputTests
//

import XCTest
@testable import ArchiveCore

final class ImportThroughputTests: XCTestCase {

    private static var fixture: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/Mail/Sent.mbox")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MAILIN_SCALE"] == "1", "opt-in: MAILIN_SCALE=1")
        try XCTSkipUnless(Self.fixture != nil, "~/Downloads/Mail/Sent.mbox not present")
    }

    func testRealMailbox_productionPath_throughput() async throws {
        let fixture = try XCTUnwrap(Self.fixture)
        let bytes = (try FileManager.default.attributesOfItem(atPath: fixture.path)[.size] as? NSNumber)?.int64Value ?? 0
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("throughput-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #if DEBUG
        let configuration = "debug"
        #else
        let configuration = "release"
        #endif

        for (label, offset) in [("offset engine", true), ("streaming parser", false)] {
            let runRoot = root.appendingPathComponent(offset ? "offset" : "streaming", isDirectory: true)
            let store = SQLiteEmailStore(directory: runRoot.appendingPathComponent("store", isDirectory: true))
            let fts = FTSSearchIndex(shardsDirectory: runRoot.appendingPathComponent("fts", isDirectory: true))
            let coordinator = await BulkImportCoordinator(store: store, fts: fts,
                                                          checkpoints: ImportCheckpointStore(store: store),
                                                          requiresStorageActivation: false)
            var options = BulkImportCoordinator.Options()
            options.enforceStoragePreflight = false
            options.useOffsetEngine = offset
            options.recordLocators = offset
            let clock = ContinuousClock()
            let start = clock.now
            let summary = try await coordinator.runImport(urls: [fixture], options: options)
            let elapsed = start.duration(to: clock.now).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            let stored = try await store.totalCount()
            let indexed = try await fts.rowCount()
            let mibPerSecond = Double(bytes) / 1_048_576 / seconds
            print("THROUGHPUT configuration=\(configuration) engine=\(label) bytes=\(bytes) messages=\(stored) indexed=\(indexed) seconds=\(String(format: "%.1f", seconds)) MiB/s=\(String(format: "%.2f", mibPerSecond)) msg/s=\(String(format: "%.1f", Double(stored) / seconds)) damaged=\(summary.damaged) persistFailed=\(summary.persistFailed)")
            XCTAssertEqual(summary.parsed, stored)
            XCTAssertEqual(indexed, stored)
        }
    }
}
