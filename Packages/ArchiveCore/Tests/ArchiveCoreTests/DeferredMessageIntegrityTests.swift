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
        let result = try RawMessageFile.write(located: locator, to: out, verifying: SourceVerificationLedger())
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

    // MARK: F04 — a changed source is refused, not exported with a fresh hash

    func testEditedSource_sameLength_isRefusedByEveryStreamingExport() async throws {
        let f = try makeFixture("edited"); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await importFixture(f, ceiling: Self.ceiling)
        let big = try await email(subject: "Big one", in: f)
        let storedLocator = try await f.store.locator(forEmailID: big.id)
        let locator = try XCTUnwrap(storedLocator)
        XCTAssertTrue(locator.hasVerifiableSource, "the offset engine records the source digest")

        // Same-length edit inside the big message's body.
        var bytes = try Data(contentsOf: f.mbox)
        let marker = Data("Line 60 of a message".utf8)
        let at = try XCTUnwrap(bytes.range(of: marker)?.lowerBound)
        bytes[at + 5] = UInt8(ascii: "7")   // "Line 60" → "Line 70"
        try bytes.write(to: f.mbox)

        let service = await ArchiveExportService(archive: f.archive)
        // EML (per-file) export.
        let folder = f.root.appendingPathComponent("eml", isDirectory: true)
        do {
            _ = try await service.exportEMLFiles(scope: .explicit([big.id]), to: folder)
            XCTFail("an edited source must be refused")
        } catch let error as LocatorReadError {
            guard case .digestMismatch(_, let path) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(path, f.mbox.path)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "nothing is left behind")

        // MBOX (single document) export goes through the same ledger.
        let mbox = f.root.appendingPathComponent("out.mbox")
        do {
            _ = try await service.exportMBOXArchive(scope: .explicit([big.id]), to: mbox)
            XCTFail("an edited source must be refused")
        } catch let error as LocatorReadError {
            guard case .digestMismatch = error else { return XCTFail("\(error)") }
        }

        // The shared reader with a ledger refuses too; without one it reads
        // (the ledger is the caller's choice, and every export passes one).
        do {
            _ = try await f.archive.rawMessageData(for: big, ledger: SourceVerificationLedger())
            XCTFail()
        } catch let error as LocatorReadError {
            guard case .digestMismatch = error else { return XCTFail("\(error)") }
        }
        _ = try await f.archive.rawMessageData(for: big, ledger: nil)

        // The small (stored) message is unaffected: its bytes are in the archive.
        let small = try await email(subject: "Small one", in: f)
        let smallFolder = f.root.appendingPathComponent("eml-small", isDirectory: true)
        let ok = try await service.exportEMLFiles(scope: .explicit([small.id]), to: smallFolder)
        XCTAssertEqual(ok.recordsWritten, 1)
    }

    func testLedger_verifiesEachSourceOncePerRun_andReverifiesAfterAnEdit() async throws {
        let f = try makeFixture("once"); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await importFixture(f, ceiling: Self.ceiling)
        let big = try await email(subject: "Big one", in: f)
        let storedLocator = try await f.store.locator(forEmailID: big.id)
        let locator = try XCTUnwrap(storedLocator)
        let ledger = SourceVerificationLedger()
        try await ledger.verify(locator)
        try await ledger.verify(locator)   // same file identity → cached, no second hash
        XCTAssertEqual(ledger.verifiedPaths, [f.mbox.path])

        // Recheck R4: the cache key carries the file's size and modification
        // date, so an edit AFTER the first verification is re-verified by the
        // SAME ledger and refused — not served from the cache.
        var bytes = try Data(contentsOf: f.mbox)
        bytes[bytes.count / 2] = bytes[bytes.count / 2] == 0x20 ? 0x2E : 0x20
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: f.mbox.path)
        try bytes.write(to: f.mbox)
        do {
            try await ledger.verify(locator)
            XCTFail("an edited source must not ride the earlier verification")
        } catch let error as LocatorReadError {
            // Within one operation the change detector (size/mtime) fires.
            guard case .sourceChangedDuringExport = error else { return XCTFail("\(error)") }
        }
        // And a fresh operation re-hashes and sees it by digest.
        do {
            try await SourceVerificationLedger().verify(locator)
            XCTFail()
        } catch let error as LocatorReadError {
            guard case .digestMismatch = error else { return XCTFail("\(error)") }
        }
    }

    // MARK: Recheck R4 — the ledger key is path + expected digest + file identity

    func testLedgerKey_distinguishesDigestsAtTheSamePath_andSeesEdits() async throws {
        let f = try makeFixture("key"); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await importFixture(f, ceiling: Self.ceiling)
        let big = try await email(subject: "Big one", in: f)
        let storedLocator = try await f.store.locator(forEmailID: big.id)
        let locator = try XCTUnwrap(storedLocator)
        let ledger = SourceVerificationLedger()
        try await ledger.verify(locator)

        // A second locator recording a DIFFERENT digest for the same path is
        // its own verification — and fails, because the file is not that.
        var other = locator
        other.sourceDigest = String(repeating: "0", count: 64)
        do {
            try await ledger.verify(other)
            XCTFail("a different expected digest must not ride the first verification")
        } catch let error as LocatorReadError {
            guard case .digestMismatch = error else { return XCTFail("\(error)") }
        }

        // Editing the file changes its size/mtime, so the SAME locator's next
        // use within the run is refused by the change detector (T4).
        var bytes = try Data(contentsOf: f.mbox)
        bytes[bytes.count / 2] = bytes[bytes.count / 2] == 0x20 ? 0x2E : 0x20
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: f.mbox.path)
        try bytes.write(to: f.mbox)
        do {
            try await ledger.verify(locator)
            XCTFail("an edited file must not be served from the cache")
        } catch let error as LocatorReadError {
            guard case .sourceChangedDuringExport = error else { return XCTFail("\(error)") }
        }

        // A locator without a digest is reported as unverified, not passed off as verified.
        var undigested = locator
        undigested.sourceDigest = nil
        let fresh = SourceVerificationLedger()
        try await fresh.verify(undigested)
        XCTAssertEqual(fresh.unverifiedPaths, [f.mbox.path])
        XCTAssertTrue(fresh.verifiedPaths.isEmpty)
    }

    /// The synchronous legacy writer verifies too (R4).
    func testRawMessageFile_refusesAnEditedSource() async throws {
        let f = try makeFixture("sync-verify"); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await importFixture(f, ceiling: Self.ceiling)
        let big = try await email(subject: "Big one", in: f)
        let locator = try XCTUnwrap(RawMessageFile.locator(for: big, storeDirectory: f.store.storeDirectory))
        var bytes = try Data(contentsOf: f.mbox)
        bytes[bytes.count / 2] = bytes[bytes.count / 2] == 0x20 ? 0x2E : 0x20
        try bytes.write(to: f.mbox)
        let out = f.root.appendingPathComponent("edited.eml")
        XCTAssertThrowsError(try RawMessageFile.write(located: locator, to: out, verifying: SourceVerificationLedger())) { error in
            guard case LocatorReadError.digestMismatch = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }

    // MARK: Recheck R5 — every per-file format withholds undecoded content

    func testMessageFilesExport_withoutRawStreaming_withholdsDeferredMessages() async throws {
        let f = try makeFixture("withheld"); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await importFixture(f, ceiling: Self.ceiling)
        let service = await ArchiveExportService(archive: f.archive)
        let folder = f.root.appendingPathComponent("pdf-like", isDirectory: true)
        var rendered: [String] = []
        // A renderer like PDF/TIFF/MSG: it reads the decoded body and would
        // happily produce a header-only document for a deferred message.
        let result = try await service.exportMessageFiles(scope: .query(.all, exclusions: []), to: folder) { email, index in
            rendered.append(email.headers["Subject"] ?? "")
            return ("\(index).txt", Data((email.headers["Subject"] ?? "").utf8))
        }
        XCTAssertEqual(result.withheld, 1, "the deferred message is withheld, not rendered as a stub")
        XCTAssertEqual(result.recordsWritten, 2)
        XCTAssertFalse(rendered.contains("Big one"), "the renderer never sees the undecoded message")
        XCTAssertEqual(Set(rendered), ["Small one", "Last one"])
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

    // MARK: Recheck R7 — a `From ` inside a line longer than a chunk is not a line start

    private func chunked(_ bytes: [UInt8], sizes: [Int]) -> [Data] {
        var out: [Data] = []
        var i = 0, k = 0
        while i < bytes.count {
            let size = sizes[k % sizes.count]
            out.append(Data(bytes[i..<min(i + size, bytes.count)]))
            i += size; k += 1
        }
        return out
    }

    func testStreamingFilters_longLines_matchWholeTextForAnyChunking() {
        // Two 1.1 MiB runs, then `>From ` exactly at what used to be an
        // emergency-flush boundary, then real line starts of every shape.
        var bytes = [UInt8](repeating: UInt8(ascii: "A"), count: 1_100_000)
        bytes += Array(">From inside-long-line\n".utf8)
        bytes += [UInt8](repeating: UInt8(ascii: "B"), count: 1_100_000)
        bytes += Array("From inside-too\r\n>From real start\n>>From twice\nFrom real start 2\n".utf8)
        bytes += [UInt8](repeating: UInt8(ascii: ">"), count: 3_000) + Array("From long quote run\n".utf8)
        bytes += Array("tail without newline >From x".utf8)

        let wholeUnquoted = MBOXRecordBuilder.unquoteFromLines(bytes: bytes)
        let wholeQuoted = MBOXRecordBuilder.quoteFromLines(bytes: bytes)
        XCTAssertEqual(wholeUnquoted.count, bytes.count - 3, "three real `>From` line starts lose one byte each")
        XCTAssertEqual(wholeQuoted.count, bytes.count + 4, "four real From/`>From` line starts gain one byte each")

        for sizes in [[1_048_576], [1_100_000], [7], [1], [4096, 1], [1_100_022, 3]] {
            var unquoter = MBOXRecordBuilder.StreamingUnquoter(enabled: true)
            var quoter = MBOXRecordBuilder.StreamingQuoter(enabled: true)
            var u = Data(), q = Data()
            for chunk in chunked(bytes, sizes: sizes) {
                u.append(unquoter.process(chunk))
                q.append(quoter.process(chunk))
            }
            u.append(unquoter.finish())
            q.append(quoter.finish())
            XCTAssertEqual([UInt8](u), wholeUnquoted, "unquote, chunk sizes \(sizes)")
            XCTAssertEqual([UInt8](q), wholeQuoted, "quote, chunk sizes \(sizes)")
        }
    }

    // MARK: Third review T5 — no cutoff on the `>` run

    func testStreamingFilters_veryLongQuoteRuns_matchWholeText() {
        for quotes in [65_535, 65_536, 65_537, 200_000] {
            var bytes = [UInt8](repeating: UInt8(ascii: ">"), count: quotes) + Array("From boundary\n".utf8)
            bytes += Array("plain\n".utf8)
            let wholeU = MBOXRecordBuilder.unquoteFromLines(bytes: bytes)
            let wholeQ = MBOXRecordBuilder.quoteFromLines(bytes: bytes)
            XCTAssertEqual(wholeU.count, bytes.count - 1)
            XCTAssertEqual(wholeQ.count, bytes.count + 1)
            for sizes in [[8192], [1], [quotes], [quotes + 3, 2]] {
                var unquoter = MBOXRecordBuilder.StreamingUnquoter(enabled: true)
                var quoter = MBOXRecordBuilder.StreamingQuoter(enabled: true)
                var u = Data(), q = Data()
                for chunk in chunked(bytes, sizes: sizes) {
                    u.append(unquoter.process(chunk)); q.append(quoter.process(chunk))
                }
                u.append(unquoter.finish()); q.append(quoter.finish())
                XCTAssertEqual([UInt8](u), wholeU, "unquote \(quotes) quotes, chunks \(sizes)")
                XCTAssertEqual([UInt8](q), wholeQ, "quote \(quotes) quotes, chunks \(sizes)")
            }
        }
    }

    // MARK: Third review T4 — the ledger is a change detector across the read

    func testLedger_detectsASourceChangedBetweenVerificationAndRead() async throws {
        let f = try makeFixture("during"); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await importFixture(f, ceiling: Self.ceiling)
        let big = try await email(subject: "Big one", in: f)
        let storedLocator = try await f.store.locator(forEmailID: big.id)
        let locator = try XCTUnwrap(storedLocator)
        let ledger = SourceVerificationLedger()
        try await ledger.verify(locator)
        try ledger.assertUnchanged(locator)
        // The file grows by one byte after verification: every read that
        // relies on the verification now refuses.
        let handle = try FileHandle(forWritingTo: f.mbox)
        try handle.seekToEnd(); try handle.write(contentsOf: Data([0x0A])); try handle.close()
        XCTAssertThrowsError(try ledger.assertUnchanged(locator)) { error in
            guard case LocatorReadError.sourceChangedDuringExport = error else { return XCTFail("\(error)") }
        }
        let out = f.root.appendingPathComponent("changed.eml")
        XCTAssertThrowsError(try RawMessageFile.write(located: locator, to: out, verifying: ledger))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
        do {
            _ = try await f.archive.rawMessageData(for: big, ledger: ledger)
            XCTFail()
        } catch let error as LocatorReadError {
            guard case .sourceChangedDuringExport = error else { return XCTFail("\(error)") }
        }
        // A NEW operation re-verifies from scratch and catches it by digest.
        do {
            _ = try await f.archive.rawMessageData(for: big, ledger: SourceVerificationLedger())
            XCTFail()
        } catch let error as LocatorReadError {
            guard case .digestMismatch = error else { return XCTFail("\(error)") }
        }
    }

    // MARK: Recheck R1 — the whole-message fallback resolves by ordinal too

    func testAttachmentFallback_sameNameTwice_returnsTheRequestedOne() throws {
        let first = Data("FIRST-PAYLOAD-bytes".utf8).base64EncodedString()
        let second = Data("SECOND-PAYLOAD-other".utf8).base64EncodedString()
        let raw = """
        From: a@example.com
        To: b@example.com
        Subject: Two invoices
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="bnd"

        --bnd
        Content-Type: text/plain

        see attached
        --bnd
        Content-Type: application/pdf; name="invoice.pdf"
        Content-Disposition: attachment; filename="invoice.pdf"
        Content-Transfer-Encoding: base64

        \(first)
        --bnd
        Content-Type: application/pdf; name="invoice.pdf"
        Content-Disposition: attachment; filename="invoice.pdf"
        Content-Transfer-Encoding: base64

        \(second)
        --bnd--
        """
        let email = MBOXParser.RawEmail(
            headers: ["Subject": "Two invoices", "Message-ID": "<two@x>"], rawSource: raw, messageType: "email",
            attachments: [AttachmentMetadata(filename: "invoice.pdf", mimeType: "application/pdf", size: 19),
                          AttachmentMetadata(filename: "invoice.pdf", mimeType: "application/pdf", size: 20)],
            timestamp: "", domains: [], plainBody: "see attached", htmlBody: "")
        // No part locators (legacy row): the whole-message fallback is the path.
        let a = try XCTUnwrap(AttachmentHydrator.data(for: email.attachments[0], index: 0, email: email))
        let b = try XCTUnwrap(AttachmentHydrator.data(for: email.attachments[1], index: 1, email: email))
        XCTAssertEqual(a, Data("FIRST-PAYLOAD-bytes".utf8))
        XCTAssertEqual(b, Data("SECOND-PAYLOAD-other".utf8), "the second same-named attachment is the second payload")
        XCTAssertNotEqual(a, b)
    }
}
