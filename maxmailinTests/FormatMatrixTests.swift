@testable import ArchiveCore
//
//  FormatMatrixTests.swift
//  maxmailinTests
//
//  3.0 Phase B-6: one executed row per format, all real content.
//
//  Two tiers:
//   • Small, always-on rows (seconds): the Apache Tika PST and MSG fixtures
//     downloaded to ~/Downloads/Mail/Fixtures/tika — the first executed PST
//     and MSG imports this project has had — plus the classifier and the
//     refusal path for synthetic OST/NSF headers (no real fixture exists;
//     the docs keep saying so).
//   • 1 GB rows, opt-in with MAILIN_SCALE=1 (10–20 minutes each): the
//     fixtures `make_format_fixtures.py` derives from the owner's Sent.mbox —
//     EML folder, Maildir, Apple Mail package, EMLX folder, gzip, and a mixed
//     four-format import with disjoint Message-IDs. Every row goes through
//     the PRODUCTION coordinator into disposable storage and must reconcile
//     exactly: discovered = parsed + damaged, stored = parsed − persistFailed,
//     FTS rows = stored, and the expected message count.
//

import XCTest
@testable import maxmailin

// MARK: - Shared production-path runner

struct ProductionImportRun {
    let root: URL
    let store: SQLiteEmailStore
    let fts: FTSSearchIndex
    let summary: BulkImportCoordinator.RunSummary
    let seconds: Double
    let rssBaseline: UInt64
    let rssAfter: UInt64

    static func run(_ sources: [URL], label: String, requireFreeMultiple: Int64 = 4,
                    useOffsetEngine: Bool = true) async throws -> ProductionImportRun {
        var sourceBytes: Int64 = 0
        for url in sources { sourceBytes += directoryOrFileBytes(url) }
        try TestPreconditions.requireFreeSpace(max(sourceBytes * requireFreeMultiple, 256 * 1_048_576))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("format-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try MailinStorageEnvironment.assertNotProduction(root)
        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts", isDirectory: true))
        let checkpoints = ImportCheckpointStore(store: store)
        let coordinator = await BulkImportCoordinator(store: store, fts: fts, checkpoints: checkpoints,
                                                      requiresStorageActivation: false)
        var options = BulkImportCoordinator.Options()
        options.useOffsetEngine = useOffsetEngine
        options.recordLocators = useOffsetEngine
        options.enforceStoragePreflight = false
        let clock = ContinuousClock()
        let baseline = currentFootprintBytes()
        let start = clock.now
        let summary = try await coordinator.runImport(urls: sources, options: options)
        let elapsed = start.duration(to: clock.now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        return ProductionImportRun(root: root, store: store, fts: fts, summary: summary, seconds: seconds,
                                   rssBaseline: baseline, rssAfter: currentFootprintBytes())
    }

    static func directoryOrFileBytes(_ url: URL) -> Int64 {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        }
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey],
                                                          options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// The three identities every executed row must satisfy, plus the count.
    func assertReconciles(expected: Int?, label: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let stored = try await store.totalCount()
        let ftsRows = try await fts.rowCount()
        let mib = { (b: UInt64) in Double(b) / 1_048_576.0 }
        print("""

        ── FORMAT-ROW \(label) ────────────────────────────────────────
        discovered/parsed/damaged \(summary.discovered) / \(summary.parsed) / \(summary.damaged)   persistFailed \(summary.persistFailed)
        inserted/duplicates       \(summary.inserted.map(String.init) ?? "nil") / \(summary.duplicates.map(String.init) ?? "nil")
        stored / ftsRows          \(stored) / \(ftsRows)   indexed \(summary.indexed)
        seconds                   \(String(format: "%.1f", seconds))
        rss baseline → after      \(String(format: "%.0f", mib(rssBaseline))) → \(String(format: "%.0f", mib(rssAfter))) MiB
        fileErrors                \(summary.fileErrors.map { "\($0.filename): \($0.message)" })
        warnings                  \(summary.warnings)
        ────────────────────────────────────────────────────────────────
        """)
        XCTAssertEqual(summary.discovered, summary.parsed + summary.damaged, "discovered = parsed + damaged", file: file, line: line)
        XCTAssertEqual(stored, summary.parsed - summary.persistFailed, "stored = parsed − persistFailed", file: file, line: line)
        XCTAssertEqual(ftsRows, stored, "FTS rows = stored", file: file, line: line)
        if let expected {
            XCTAssertEqual(stored, expected, "\(label): expected message count", file: file, line: line)
        }
    }

    func dispose() { try? FileManager.default.removeItem(at: root) }
}

// MARK: - Temp hygiene

/// The test host's temporary directory lives inside the app container, which
/// nothing outside the sandbox can list or clean (TCC). A run that is killed
/// or crashes leaves its disposable stores behind — gigabytes per format row.
/// This sweeps the known prefixes older than 30 minutes and reports what it
/// found, so a full disk never silently ends a later run.
final class TestTempHygiene: XCTestCase {
    static let prefixes = ["format-", "large-message-", "handoff-", "reloc-", "enospc-", "eject-", "v1lib-", "v2lib-",
                           "mboxrd-", "throughput-", "mailin-container-", "measure-", "overflow-"]

    func testSweepStaleDisposableStores() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        let entries = (try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var freed: Int64 = 0, kept: Int64 = 0, removed = 0
        for entry in entries where Self.prefixes.contains(where: { entry.lastPathComponent.hasPrefix($0) }) {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let bytes = ProductionImportRun.directoryOrFileBytes(entry)
            if Date().timeIntervalSince(modified) > 30 * 60 {
                try? fm.removeItem(at: entry)
                freed += bytes; removed += 1
            } else {
                kept += bytes
            }
        }
        print("TEMP-HYGIENE tmp=\(tmp.path) removed=\(removed) freedBytes=\(freed) keptRecentBytes=\(kept)")
    }
}

// MARK: - Small rows (always on when the fixture is present)

final class RealBinaryFixtureTests: XCTestCase {

    private static let fixtures = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Downloads/Mail/Fixtures/tika")

    private func fixture(_ name: String) throws -> URL {
        let url = Self.fixtures.appendingPathComponent(name)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path),
                          "\(name) not present — Apache Tika test fixture, see MAILIN_3_0_TODO.md B-6")
        return url
    }

    /// The first executed PST import: Apache Tika's testPST.pst (2.3 MB,
    /// Apache-2.0). The count is whatever the parser finds; what is asserted
    /// is that it finds messages and that the run reconciles.
    func testTikaPST_importsAndReconciles() async throws {
        let pst = try fixture("testPST.pst")
        XCTAssertEqual(SourceFormatClassifier.classify(url: pst).format, .pst)
        let run = try await ProductionImportRun.run([pst], label: "tika-pst", useOffsetEngine: false)
        defer { run.dispose() }
        try await run.assertReconciles(expected: nil, label: "Tika testPST.pst")
        XCTAssertGreaterThan(run.summary.parsed, 0, "a real PST must yield messages")
        XCTAssertTrue(run.summary.fileErrors.isEmpty, "\(run.summary.fileErrors)")
    }

    /// The first executed MSG imports: three Tika .msg files (OLE2).
    func testTikaMSG_importsAndReconciles() async throws {
        let names = ["testMSG.msg", "testMSG_forwarded.msg", "test-outlook.msg"]
        var urls: [URL] = []
        for name in names {
            let url = Self.fixtures.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { urls.append(url) }
        }
        try XCTSkipUnless(!urls.isEmpty, "no Tika .msg fixtures present")
        for url in urls { XCTAssertEqual(SourceFormatClassifier.classify(url: url).format, .msg, url.lastPathComponent) }
        let run = try await ProductionImportRun.run(urls, label: "tika-msg", useOffsetEngine: false)
        defer { run.dispose() }
        try await run.assertReconciles(expected: urls.count, label: "Tika .msg ×\(urls.count)")
        XCTAssertTrue(run.summary.fileErrors.isEmpty, "\(run.summary.fileErrors)")
    }
}

/// No real OST or NSF exists on this machine or in public. These rows prove
/// only what can be proven without one: the classifier names the format from
/// its signature, and an import of a file that carries the signature but no
/// valid structure ends in a named failure — zero rows, no crash — instead
/// of a silent success. The format table keeps saying "no executed fixture".
final class SyntheticBinaryFormatTests: XCTestCase {

    private func synthetic(name: String, header: [UInt8], size: Int = 64 * 1024) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        var data = Data(header)
        data.append(Data(repeating: 0, count: max(0, size - header.count)))
        try data.write(to: url)
        return url
    }

    func testSyntheticOST_isClassifiedAndRefusedHonestly() async throws {
        // "!BDN" is the PST/OST file signature; the name says OST.
        let url = try synthetic(name: "synthetic.ost", header: Array("!BDN".utf8) + [0, 0, 0, 0])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let format = SourceFormatClassifier.classify(url: url).format
        XCTAssertTrue(format == .ost || format == .pst, "signature must be recognised as the Outlook family, got \(format)")
        let run = try await ProductionImportRun.run([url], label: "synthetic-ost", useOffsetEngine: false)
        defer { run.dispose() }
        let stored = try await run.store.totalCount()
        XCTAssertEqual(stored, 0, "a structurally empty OST must store nothing")
        XCTAssertTrue(!run.summary.fileErrors.isEmpty || run.summary.damaged > 0 || run.summary.discovered == 0,
                      "the outcome must be visible: an error, a damaged count, or an explicit zero")
    }

    func testSyntheticNSF_isClassifiedAndRefusedHonestly() async throws {
        let url = try synthetic(name: "synthetic.nsf", header: [0x1A, 0x00, 0x00, 0x00])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertEqual(SourceFormatClassifier.classify(url: url).format, .nsf)
        let run = try await ProductionImportRun.run([url], label: "synthetic-nsf", useOffsetEngine: false)
        defer { run.dispose() }
        let stored = try await run.store.totalCount()
        XCTAssertEqual(stored, 0)
        XCTAssertTrue(!run.summary.fileErrors.isEmpty || run.summary.damaged > 0 || run.summary.discovered == 0)
    }
}

// MARK: - 1 GB rows (opt-in)

final class FormatMatrixScaleTests: XCTestCase {

    private static let formats = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Downloads/Mail/Scale/formats")
    /// `make_format_fixtures.py` default: 11 copies × 526 messages.
    private static let copies = 11
    private static let messagesPerCopy = 526
    private static var expected: Int { copies * messagesPerCopy }

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MAILIN_SCALE"] == "1",
                          "1 GB format rows are opt-in: MAILIN_SCALE=1 (10–20 minutes each)")
    }

    private func fixture(_ name: String) throws -> URL {
        let url = Self.formats.appendingPathComponent(name)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path),
                          "\(name) not present — run make_format_fixtures.py Sent.mbox ~/Downloads/Mail/Scale")
        return url
    }

    func testEMLFolder_1GB() async throws {
        let url = try fixture("eml-1gb")
        XCTAssertEqual(SourceFormatClassifier.classify(url: url).format, .emlFolder)
        let run = try await ProductionImportRun.run([url], label: "eml")
        defer { run.dispose() }
        try await run.assertReconciles(expected: Self.expected, label: "EML folder 1 GB")
    }

    func testMaildir_1GB() async throws {
        let url = try fixture("maildir-1gb")
        XCTAssertEqual(SourceFormatClassifier.classify(url: url).format, .maildir)
        let run = try await ProductionImportRun.run([url], label: "maildir")
        defer { run.dispose() }
        try await run.assertReconciles(expected: Self.expected, label: "Maildir 1 GB")
    }

    func testAppleMailPackage_1GB() async throws {
        let url = try fixture("applemail-1gb.mbox")
        XCTAssertEqual(SourceFormatClassifier.classify(url: url).format, .appleMailMailbox)
        let run = try await ProductionImportRun.run([url], label: "applemail")
        defer { run.dispose() }
        try await run.assertReconciles(expected: Self.expected, label: "Apple Mail package 1 GB")
    }

    func testEMLXFolder_1GB() async throws {
        let url = try fixture("emlx-1gb")
        let run = try await ProductionImportRun.run([url], label: "emlx")
        defer { run.dispose() }
        try await run.assertReconciles(expected: Self.expected, label: "EMLX folder 1 GB")
    }

    func testGzip_1GB() async throws {
        let url = try fixture("mbox-1gb.mbox.gz")
        XCTAssertEqual(SourceFormatClassifier.classify(url: url).format, .gzip)
        let run = try await ProductionImportRun.run([url], label: "gzip", requireFreeMultiple: 6)
        defer { run.dispose() }
        try await run.assertReconciles(expected: Self.expected, label: "gzip 1 GB")
    }

    /// Four formats in one run, disjoint Message-IDs: the total must be the
    /// sum of the parts with zero duplicates.
    func testMixedFourFormats_1GB() async throws {
        let dir = try fixture("mixed-1gb")
        let expectedText = try String(contentsOf: dir.appendingPathComponent("EXPECTED_COUNT.txt"), encoding: .utf8)
        let expected = Int(expectedText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let parts = ["part-a.mbox", "part-b-eml", "part-c.zip", "part-d-maildir"].map { dir.appendingPathComponent($0) }
        let run = try await ProductionImportRun.run(parts, label: "mixed", requireFreeMultiple: 5)
        defer { run.dispose() }
        try await run.assertReconciles(expected: expected, label: "mixed mbox+eml+zip+Maildir 1 GB")
        XCTAssertEqual(run.summary.duplicates ?? 0, 0, "disjoint ID ranges → no duplicates")
    }
}
