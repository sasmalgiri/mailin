@testable import ArchiveCore
//
//  LargeMessageBlobTests.swift
//  maxmailinTests
//
//  S3b / S6: the executed proof that a single message larger than SQLite's
//  1 GB row ceiling can be imported, read back and exported. Generates a
//  1.1 GB one-message mbox in the temporary directory (real RFC-822 headers,
//  a base64 body of that size), imports it through the production
//  coordinator with the 3.0 default engine (offset + blob tier), and checks
//  the row exists, the archive did not crash on the row ceiling, and an mbox
//  export returns one record of the expected size.
//
//  Opt-in with MAILIN_SCALE=1: needs about 4 GB of free disk and several
//  minutes. Recorded in SCALE_RESULTS.md when run.
//

import XCTest
@testable import maxmailin

final class LargeMessageBlobTests: XCTestCase {

    /// Above the 1 GB row ceiling, below what a laptop's temp volume minds.
    static let bodyBytes: Int64 = 1_100 * 1_048_576

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MAILIN_SCALE"] == "1",
                          "the >1 GB single-message run is opt-in: MAILIN_SCALE=1")
        try TestPreconditions.requireFreeSpace(Self.bodyBytes * 4)
    }

    /// Streams the fixture to disk in 1 MiB slices; never holds it in memory.
    private func makeFixture(at url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let headers = """
        From sender@example.com Tue Mar 14 09:41:00 2017
        From: Large Sender <sender@example.com>
        To: recipient@example.com
        Subject: one message above the SQLite row ceiling
        Date: Tue, 14 Mar 2017 09:41:00 +0000
        Message-ID: <large-\(UUID().uuidString)@example.com>
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="LARGE-BOUNDARY"

        --LARGE-BOUNDARY
        Content-Type: text/plain; charset=utf-8

        This message carries one attachment larger than a gigabyte.

        --LARGE-BOUNDARY
        Content-Type: application/octet-stream; name="payload.bin"
        Content-Transfer-Encoding: base64
        Content-Disposition: attachment; filename="payload.bin"


        """
        try handle.write(contentsOf: Data(headers.utf8))
        // 76-char base64 lines + newline = 77 bytes per line.
        let line = Data((String(repeating: "QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVphYmNkZWZnaGlqa2xtbm9wcXJzdHV2d3h5ejAxMjM0NTY3ODk=", count: 1).prefix(76) + "\n").utf8)
        var slice = Data(capacity: 1 << 20)
        while slice.count < (1 << 20) { slice.append(line) }
        var written: Int64 = 0
        while written < Self.bodyBytes {
            try handle.write(contentsOf: slice)
            written += Int64(slice.count)
        }
        try handle.write(contentsOf: Data("\n--LARGE-BOUNDARY--\n\n".utf8))
    }

    func testMessageAboveRowCeiling_importsReadsBackAndExports() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("large-message-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = root.appendingPathComponent("one-large.mbox")
        try makeFixture(at: fixture)
        let fixtureBytes = (try FileManager.default.attributesOfItem(atPath: fixture.path)[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertGreaterThan(fixtureBytes, 1_073_741_824, "the fixture must exceed the 1 GB row ceiling")

        let run = try await ProductionImportRun.run([fixture], label: "large-message", requireFreeMultiple: 3,
                                                    useOffsetEngine: true)
        defer { run.dispose() }
        try await run.assertReconciles(expected: 1, label: "1.1 GB single message (offset engine + blob tier)")
        XCTAssertEqual(run.summary.damaged, 0, "the message must not be reported as oversized")
        XCTAssertTrue(run.summary.fileErrors.isEmpty, "\(run.summary.fileErrors)")

        // Read back by id: the row exists and carries its headers.
        let archive = ArchiveDataService(repository: EmailStoreRepository(store: run.store, fts: run.fts))
        let page = try await archive.page(query: .all, cursor: nil, limit: 10)
        XCTAssertEqual(page.summaries.count, 1)
        let id = try XCTUnwrap(page.summaries.first?.id)
        let full = try await archive.fullEmail(id: id)
        XCTAssertEqual(full?.headers["Subject"], "one message above the SQLite row ceiling")

        // Export round trip: one record, and the bytes must be the message,
        // not a header-only stub.
        let exporter = await ArchiveExportService(archive: archive)
        let out = root.appendingPathComponent("roundtrip.mbox")
        let result = try await exporter.exportMBOXArchive(scope: .query(.all, exclusions: []), to: out)
        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.recordsWritten, 1)
        let outBytes = (try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? NSNumber)?.int64Value ?? 0
        print("LARGE-MESSAGE fixture=\(fixtureBytes) exported=\(outBytes) bodiesNotDecoded=\(run.summary.bodiesNotDecoded) seconds=\(String(format: "%.1f", run.seconds))")
        XCTAssertGreaterThan(outBytes, Int64(Double(fixtureBytes) * 0.9),
                             "the exported record must carry the whole message (S5 per-part reads from the locator)")
    }
}
