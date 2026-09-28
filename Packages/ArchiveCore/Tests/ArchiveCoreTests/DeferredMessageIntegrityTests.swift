//
//  DeferredMessageIntegrityTests.swift
//  ArchiveCoreTests
//
//  Audit F02 / F03 / F05 (2026-09-28). A message above the full-parse ceiling
//  is imported from its headers with a byte locator and NO stored content.
//  These rows prove: the locator commits with the row (never a row without
//  one), every export that promises the message's bytes streams them from
//  the source — byte-identical to what a full parse would have stored — and
//  a message whose source is gone is an ERROR, never a stub.
//

import XCTest
import Foundation
@testable import ArchiveCore

final class DeferredMessageIntegrityTests: XCTestCase {

    // MARK: Fixture — three messages, the middle one far above a 2 KiB ceiling

    private static let ceiling: Int64 = 2048

    private struct Fixture {
        let root: URL
        let mbox: URL
        let store: SQLiteEmailStore
        let fts: FTSSearchIndex
        var archive: ArchiveDataService { ArchiveDataService(repository: EmailStoreRepository(store: store, fts: fts)) }
    }

    private func makeFixture(_ name: String) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("deferred-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let mbox = root.appendingPathComponent("source.mbox")
        // The big message carries an mboxrd-quoted body line (`>From `), so
        // the streamed export must undo the quoting exactly as a full parse
        // does — and a CRLF line so the byte path is exercised too.
        var big = ""
        for i in 0..<120 {
            big += "Line \(i) of a message that is well above the two-kibibyte ceiling used by this test.\n"
            if i == 40 { big += ">From the middle of the body, quoted by the mailbox writer.\n" }
            if i == 41 { big += ">>From twice.\r\n" }
        }
        let text = """
        From alice@example.com Thu Mar 16 11:00:00 2017
        From: alice@example.com
        To: bob@example.com
        Subject: Small one
        Date: Thu, 16 Mar 2017 11:00:00 +0000
        Message-ID: <small-\(UUID().uuidString)@example.com>

        short body

        From carol@example.com Fri Mar 17 12:00:00 2017
        From: carol@example.com
        To: bob@example.com
        Subject: Big one
        Date: Fri, 17 Mar 2017 12:00:00 +0000
        Message-ID: <big-\(UUID().uuidString)@example.com>

        \(big)
        From dave@example.com Sat Mar 18 13:00:00 2017
        From: dave@example.com
        To: bob@example.com
        Subject: Last one
        Date: Sat, 18 Mar 2017 13:00:00 +0000
        Message-ID: <last-\(UUID().uuidString)@example.com>

        the end

        """
        try Data(text.utf8).write(to: mbox)
        return Fixture(root: root, mbox: mbox,
                       store: SQLiteEmailStore(directory: root.appendingPathComponent("store", isDirectory: true)),
                       fts: FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts", isDirectory: true)))
    }

    private func importFixture(_ f: Fixture, ceiling: Int64?) async throws -> BulkImportCoordinator.RunSummary {
        let coordinator = await BulkImportCoordinator(store: f.store, fts: f.fts,
                                                      checkpoints: ImportCheckpointStore(store: f.store),
                                                      requiresStorageActivation: false)
        var options = BulkImportCoordinator.Options()
        options.enforceStoragePreflight = false
        options.useOffsetEngine = true
        options.recordLocators = true
        options.fullParseCeilingBytes = ceiling
        return try await coordinator.runImport(urls: [f.mbox], options: options)
    }

    private func email(subject: String, in f: Fixture) async throws -> MBOXParser.RawEmail {
        let page = try await f.archive.page(query: .all, cursor: nil, limit: 50)
        let id = try XCTUnwrap(page.summaries.first { $0.subject == subject }?.id, "no message titled \(subject)")
        let full = try await f.archive.fullEmail(id: id)
        return try XCTUnwrap(full)
    }

    /// Where two byte strings first differ, with context — for a failure
    /// message that says WHAT differs, not just that something does.
    static func firstDifference(_ a: Data, _ b: Data) -> String {
        let n = min(a.count, b.count)
        var i = 0
        while i < n, a[i] == b[i] { i += 1 }
        guard i < n || a.count != b.count else { return "identical" }
        let lo = max(0, i - 30), hiA = min(a.count, i + 30), hiB = min(b.count, i + 30)
        let ca = String(decoding: a[lo..<hiA], as: UTF8.self).debugDescription
        let cb = String(decoding: b[lo..<hiB], as: UTF8.self).debugDescription
        return "at byte \(i): streamed …\(ca)… vs stored …\(cb)…"
    }

    // MARK: F02 — the locator commits with the row

    func testInsertBatch_writesLocatorsInsideTheRowTransaction() async throws {
        let f = try makeFixture("store"); defer { try? FileManager.default.removeItem(at: f.root) }
        let a = MBOXParser.RawEmail(headers: ["Message-ID": "<a@x>", "Subject": "A", "Date": "Thu, 16 Mar 2017 11:00:00 +0000"],
                                    rawSource: "", messageType: "email", attachments: [], timestamp: "", domains: [],
                                    plainBody: "", htmlBody: "")
        let locator = MessageLocator(id: a.id, sourceDigest: "d", sourcePath: f.mbox.path,
                                     messageRange: ByteRange(offset: 0, length: 100), envelopeRange: ByteRange(offset: 0, length: 40),
                                     headerRange: ByteRange(offset: 40, length: 30), bodyRange: ByteRange(offset: 70, length: 30), ordinal: 0)
        let part = PartLocator(messageID: a.id, path: [1], mimeType: "application/pdf", filename: "x.pdf",
                               contentID: nil, contentTransferEncoding: "base64",
                               contentRange: ByteRange(offset: 80, length: 10), headerRange: ByteRange(offset: 70, length: 10))
        let result = try await f.store.insertBatch([a], sourceFileHash: "h", accountID: nil, sourceID: nil, firstOrdinal: nil,
                                                   dedupPolicy: .messageID, batchSize: 10, progress: nil,
                                                   locators: [a.id: .init(locator: locator, bodyDecoded: false, parts: [part])])
        XCTAssertEqual(result.insertedIDs, [a.id])
        let saved = try await f.store.locator(forEmailID: a.id)
        XCTAssertEqual(saved?.sourcePath, f.mbox.path)
        XCTAssertEqual(saved?.messageRange, locator.messageRange)
        let parts = try await f.store.partLocators(forEmailID: a.id)
        XCTAssertEqual(parts.map(\.filename), ["x.pdf"])
        let deferred = try await f.store.deferredBodyCount()
        XCTAssertEqual(deferred, 1)

        // A deduped row (same Message-ID) is NOT inserted and gains no
        // locator — it would point at bytes no row owns.
        let dup = MBOXParser.RawEmail(headers: a.headers, rawSource: "", messageType: "email", attachments: [],
                                      timestamp: "", domains: [], plainBody: "", htmlBody: "")
        let dupLocator = MessageLocator(id: dup.id, sourceDigest: "d", sourcePath: f.mbox.path,
                                        messageRange: ByteRange(offset: 500, length: 100), envelopeRange: nil,
                                        headerRange: ByteRange(offset: 500, length: 30), bodyRange: ByteRange(offset: 530, length: 70), ordinal: 9)
        let second = try await f.store.insertBatch([dup], sourceFileHash: "h2", accountID: nil, sourceID: nil, firstOrdinal: nil,
                                                   dedupPolicy: .messageID, batchSize: 10, progress: nil,
                                                   locators: [dup.id: .init(locator: dupLocator, bodyDecoded: true)])
        XCTAssertTrue(second.insertedIDs.isEmpty)
        let none = try await f.store.locator(forEmailID: dup.id)
        XCTAssertNil(none)
    }

    func testDeferredImport_everyCommittedRowHasALocator() async throws {
        let f = try makeFixture("import"); defer { try? FileManager.default.removeItem(at: f.root) }
        let summary = try await importFixture(f, ceiling: Self.ceiling)
        XCTAssertEqual(summary.persistFailed, 0)
        XCTAssertEqual(summary.bodiesNotDecoded, 1, "exactly the big message is header-only")
        let total = try await f.store.totalCount()
        XCTAssertEqual(total, 3)
        let page = try await f.archive.page(query: .all, cursor: nil, limit: 50)
        for summary in page.summaries {
            let locator = try await f.store.locator(forEmailID: summary.id)
            XCTAssertNotNil(locator, "\(summary.subject) has no locator")
        }
        let deferred = try await f.store.deferredBodyCount()
        XCTAssertEqual(deferred, 1)
        let big = try await email(subject: "Big one", in: f)
        XCTAssertTrue(big.rawSource.isEmpty, "the deferred message stores no content")
        XCTAssertTrue(big.plainBody.isEmpty)
    }

    // MARK: F05 — exports stream the located bytes, identical to a full parse

    /// What a full parse of the SAME source stores for `subject`, for byte
    /// comparison: the fixture's mbox is imported again into a fresh store
    /// with the default ceiling, so every message is decoded and stored.
    private func fullyParsedRaw(subject: String, of f: Fixture) async throws -> Data {
        let g = try makeFixture("full"); defer { try? FileManager.default.removeItem(at: g.root) }
        try FileManager.default.removeItem(at: g.mbox)
        try FileManager.default.copyItem(at: f.mbox, to: g.mbox)
        _ = try await importFixture(g, ceiling: nil)   // default ceiling: everything decoded
        let stored = try await email(subject: subject, in: g)
        XCTAssertFalse(stored.rawSource.isEmpty)
        return Data(stored.rawSource.utf8)
    }

    func testRawMessageData_ofADeferredMessage_equalsWhatAFullParseStores() async throws {
        let f = try makeFixture("raw"); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await importFixture(f, ceiling: Self.ceiling)
        let big = try await email(subject: "Big one", in: f)
        let source = await f.archive.rawMessageSource(for: big)
        guard case .located = source else { return XCTFail("expected a located message, got \(source)") }

        let streamed = try await f.archive.rawMessageData(for: big)
        let expected = try await fullyParsedRaw(subject: "Big one", of: f)
        XCTAssertEqual(streamed, expected, "located bytes must equal the stored bytes of a full parse: \(Self.firstDifference(streamed, expected))")
        let text = String(decoding: streamed, as: UTF8.self)
        XCTAssertTrue(text.contains("\nFrom the middle of the body"), "mboxrd quoting is undone")
        XCTAssertTrue(text.contains("\n>From twice.\r\n"), "exactly one `>` is removed")
        // The offset engine keeps the record's own envelope line when it
        // stores a message; the located stream does the same, so the two are
        // interchangeable everywhere `rawSource` is consumed.
        XCTAssertTrue(text.hasPrefix("From carol@example.com Fri Mar 17 12:00:00 2017\nFrom: carol@example.com"))
    }

    func testEMLExport_streamsTheDeferredMessageByteForByte() async throws {
        let f = try makeFixture("eml"); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await importFixture(f, ceiling: Self.ceiling)
        let big = try await email(subject: "Big one", in: f)
        let folder = f.root.appendingPathComponent("eml", isDirectory: true)
        let service = await ArchiveExportService(archive: f.archive)
        let result = try await service.exportEMLFiles(scope: .explicit([big.id]), to: folder,
                                                      render: { _ in "THIS RENDER MUST NOT BE USED FOR A LOCATED MESSAGE" })
        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.recordsWritten, 1)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".eml") }
        XCTAssertEqual(files.count, 1)
        let written = try Data(contentsOf: folder.appendingPathComponent(files[0]))
        let expected = try await fullyParsedRaw(subject: "Big one", of: f)
        XCTAssertEqual(written, expected)
        XCTAssertEqual(result.bytesWritten, expected.count)
    }

    func testRawMessageFile_synchronousPath_matches() async throws {
        let f = try makeFixture("sync"); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await importFixture(f, ceiling: Self.ceiling)
        let big = try await email(subject: "Big one", in: f)
        let locator = try XCTUnwrap(RawMessageFile.locator(for: big, storeDirectory: f.store.storeDirectory))
        let out = f.root.appendingPathComponent("big.eml")
        let result = try RawMessageFile.write(located: locator, to: out)
        let expected = try await fullyParsedRaw(subject: "Big one", of: f)
        XCTAssertEqual(try Data(contentsOf: out), expected)
        XCTAssertEqual(result.bytes, expected.count)
        let small = try await email(subject: "Small one", in: f)
        XCTAssertNil(RawMessageFile.locator(for: small, storeDirectory: f.store.storeDirectory),
                     "a stored message has content; the located path is not for it")
    }

    // MARK: F05 — a missing source is an error, never a stub

    func testMissingSource_isUnavailable_andEMLExportFailsWithoutAStub() async throws {
        let f = try makeFixture("gone"); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await importFixture(f, ceiling: Self.ceiling)
        let big = try await email(subject: "Big one", in: f)
        try FileManager.default.moveItem(at: f.mbox, to: f.root.appendingPathComponent("moved-away.mbox"))

        let source = await f.archive.rawMessageSource(for: big)
        guard case .unavailable(let why) = source else { return XCTFail("expected unavailable, got \(source)") }
        XCTAssertTrue(why.contains("no longer at"))
        XCTAssertFalse(source.isAvailable)

        do {
            _ = try await f.archive.rawMessageData(for: big)
            XCTFail("must throw")
        } catch let error as RawMessageError {
            guard case .contentUnavailable(let subject, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(subject, "Big one")
        }

        let folder = f.root.appendingPathComponent("eml-gone", isDirectory: true)
        let service = await ArchiveExportService(archive: f.archive)
        do {
            _ = try await service.exportEMLFiles(scope: .explicit([big.id]), to: folder)
            XCTFail("an export that cannot supply the message must fail")
        } catch {
            // expected — and nothing is left behind
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "no stub, no folder")
        XCTAssertNil(RawMessageFile.locator(for: big, storeDirectory: f.store.storeDirectory))
    }

    // MARK: Streaming unquoter

    func testStreamingUnquoter_matchesWholeTextAcrossChunkBoundaries() {
        let text = "From: a\n\n>From one\n>>From two\r\n>Fromage is not quoted\nplain >From inside\n>From "
        let whole = MBOXRecordBuilder.unquoteFromLines(bytes: Array(text.utf8))
        for chunk in [1, 2, 3, 5, 7, 11, 64] {
            var unquoter = MBOXRecordBuilder.StreamingUnquoter(enabled: true)
            var out = Data()
            let bytes = Array(text.utf8)
            var i = 0
            while i < bytes.count {
                let end = min(i + chunk, bytes.count)
                out.append(unquoter.process(Data(bytes[i..<end])))
                i = end
            }
            out.append(unquoter.finish())
            XCTAssertEqual([UInt8](out), whole, "chunk size \(chunk)")
        }
        var off = MBOXRecordBuilder.StreamingUnquoter(enabled: false)
        XCTAssertEqual(off.process(Data(text.utf8)), Data(text.utf8))
    }
}
