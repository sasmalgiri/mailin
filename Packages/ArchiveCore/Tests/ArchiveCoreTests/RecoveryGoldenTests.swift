//
//  RecoveryGoldenTests.swift
//  ArchiveCoreTests
//
//  3.1 R0 golden fixtures: generated mailboxes with a manifest of how many
//  messages are live, unpurged, flagged deleted and in deleted folders. Each
//  is imported through the real import coordinator — both import engines and
//  the header-only path — and the archive, the search filters and the import
//  receipt must all equal the manifest. Generated messages only.
//

import XCTest
import Foundation
@testable import ArchiveCore

final class RecoveryGoldenTests: XCTestCase {
    struct Manifest: Equatable { var live = 0, unpurged = 0, flagged = 0, deletedFolder = 0 }

    private var was = false
    override func setUp() { super.setUp(); was = RecoveryPolicy.isEnabled; RecoveryPolicy.isEnabled = true }
    override func tearDown() { RecoveryPolicy.isEnabled = was; super.tearDown() }

    private func message(_ n: Int, _ extra: String) -> String {
        """
        From sender\(n)@example.com Mon Jan  6 10:00:00 2025
        From: Sender \(n) <sender\(n)@example.com>
        To: r@example.org
        Subject: Golden \(n)
        Date: Mon, 6 Jan 2025 10:\(String(format: "%02d", n % 60)):00 +0000
        Message-ID: <golden\(n)-\(UUID().uuidString)@example.com>
        \(extra)Content-Type: text/plain

        Body \(n).

        """
    }

    /// Thunderbird + mutt + Gmail Takeout in one mbox, with its manifest.
    private func fixture(in dir: URL) throws -> (URL, Manifest) {
        var text = ""
        var m = Manifest()
        var n = 0
        for _ in 0..<3 { n += 1; text += message(n, "X-Mozilla-Status: 0001\n"); m.live += 1 }
        for flag in ["0009", "0008", "000b", "0019"] { n += 1; text += message(n, "X-Mozilla-Status: \(flag)\n"); m.unpurged += 1 }
        n += 1; text += message(n, "Status: RO\nX-Status: D\n"); m.flagged += 1
        for _ in 0..<2 { n += 1; text += message(n, "X-Gmail-Labels: Trash,Opened\n"); m.deletedFolder += 1 }
        for _ in 0..<3 { n += 1; text += message(n, "X-Gmail-Labels: Inbox,Important\n"); m.live += 1 }
        let url = dir.appendingPathComponent("golden.mbox")
        try Data(text.utf8).write(to: url)
        return (url, m)
    }

    private func run(offset: Bool, ceiling: Int64?) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("golden-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (mbox, manifest) = try fixture(in: root)
        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts", isDirectory: true))
        let coordinator = await BulkImportCoordinator(store: store, fts: fts, checkpoints: ImportCheckpointStore(store: store),
                                                      requiresStorageActivation: false)
        var options = BulkImportCoordinator.Options()
        options.enforceStoragePreflight = false
        options.useOffsetEngine = offset
        options.recordLocators = offset
        options.fullParseCeilingBytes = ceiling
        let summary = try await coordinator.runImport(urls: [mbox], options: options)

        let c = try await store.recoveryCounts()
        let got = Manifest(live: c[.live], unpurged: c[.unpurged], flagged: c[.flaggedDeleted], deletedFolder: c[.deletedFolder])
        XCTAssertEqual(got, manifest, "offset \(offset), ceiling \(String(describing: ceiling))")

        let recovered = try await store.filteredCount(ArchiveQueryCompiler.compile("is:recovered"))
        XCTAssertEqual(recovered, manifest.unpurged + manifest.flagged + manifest.deletedFolder)
        let unpurged = try await store.filteredCount(ArchiveQueryCompiler.compile("recovery:unpurged"))
        XCTAssertEqual(unpurged, manifest.unpurged)
        let notRecovered = try await store.filteredCount(ArchiveQueryCompiler.compile("-is:recovered", exclusions: true))
        XCTAssertEqual(notRecovered, manifest.live)

        let receipt = try XCTUnwrap(summary.receipt)
        XCTAssertEqual(receipt.recovery?[.unpurged], manifest.unpurged)
        XCTAssertEqual(receipt.recovery?[.deletedFolder], manifest.deletedFolder)
        XCTAssertTrue(receipt.verify())
        if ceiling != nil {
            XCTAssertEqual(receipt.bodiesNotDecoded, manifest.live + manifest.unpurged + manifest.flagged + manifest.deletedFolder,
                           "every message took the header-only path")
        }
    }

    func testGolden_streamingEngine() async throws { try await run(offset: false, ceiling: nil) }
    func testGolden_offsetEngine() async throws { try await run(offset: true, ceiling: nil) }
    func testGolden_offsetEngine_headerOnlyMessages() async throws { try await run(offset: true, ceiling: 64) }

    func testGolden_recoveryOff_marksNothing_andImportsEverything() async throws {
        RecoveryPolicy.isEnabled = false
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("golden-off-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (mbox, m) = try fixture(in: root)
        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts", isDirectory: true))
        let coordinator = await BulkImportCoordinator(store: store, fts: fts, checkpoints: ImportCheckpointStore(store: store),
                                                      requiresStorageActivation: false)
        var options = BulkImportCoordinator.Options()
        options.enforceStoragePreflight = false
        let summary = try await coordinator.runImport(urls: [mbox], options: options)
        let rec = try await store.recoveryCounts().recovered
        XCTAssertEqual(rec, 0)
        let all = try await store.filteredCount(.all)
        XCTAssertEqual(all, m.live + m.unpurged + m.flagged + m.deletedFolder, "nothing is dropped")
        XCTAssertNil(summary.receipt?.recovery)
    }
}
