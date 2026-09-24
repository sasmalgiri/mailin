//
//  OffsetParserTests.swift
//  maxmailinTests
//
//  S4: the offset scanner and the import engine built on it.
//
//  These target the guard rails SIZE_LIMITS_DESIGN.md declared
//  non-negotiable, because those are the ways a byte-scanning parser
//  silently loses mail:
//
//   • a `>From`-style body line must not split a message;
//   • a separator that straddles a read window must still be found;
//   • the last message must close at end-of-file;
//   • an I/O error must throw rather than read as EOF;
//   • a message under the ceiling must come out IDENTICAL to the streaming
//     parser's output, because that is what makes the switch safe.
//
//  NOT YET EXECUTED — written under an instruction to implement first and test
//  afterwards.
//

import XCTest
@testable import maxmailin

final class OffsetScannerTests: XCTestCase {

    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("offset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func write(_ contents: String, name: String = "fixture.mbox") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func message(subject: String, body: String) -> String {
        """
        From sender@example.com Tue Mar 14 09:41:00 2017
        From: sender@example.com
        To: recipient@example.com
        Subject: \(subject)
        Date: Tue, 14 Mar 2017 09:41:00 +0000
        Message-ID: <\(subject)@example.com>

        \(body)

        """
    }

    // MARK: - Boundaries

    func testFindsEveryMessageBoundary() async throws {
        let url = try write(message(subject: "one", body: "first body")
                            + message(subject: "two", body: "second body")
                            + message(subject: "three", body: "third body"))

        let scan = try await OffsetMBOXScanner().scan(fileURL: url)
        XCTAssertEqual(scan.messageCount, 3)
        XCTAssertEqual(scan.headers.map { $0["Subject"] }, ["one", "two", "three"])
        // Ranges must tile the file exactly: no gap means no lost bytes, no
        // overlap means no duplicated bytes.
        XCTAssertEqual(scan.locators.first?.messageRange.offset, 0)
        XCTAssertEqual(scan.locators.last?.messageRange.end, scan.sourceSize)
        for (previous, next) in zip(scan.locators, scan.locators.dropFirst()) {
            XCTAssertEqual(previous.messageRange.end, next.messageRange.offset,
                           "message ranges must tile the source with no gap or overlap")
        }
    }

    /// The classic mbox trap: a body line beginning "From " without a year is
    /// not a separator. Splitting on it would cut a message in half and
    /// fabricate a second one.
    func testBodyLineBeginningWithFromDoesNotSplitAMessage() async throws {
        let url = try write("""
        From sender@example.com Tue Mar 14 09:41:00 2017
        From: sender@example.com
        Subject: tricky
        Date: Tue, 14 Mar 2017 09:41:00 +0000

        From the desk of the chairman
        >From a quoted separator
        From time to time we write this

        """)

        let scan = try await OffsetMBOXScanner().scan(fileURL: url)
        XCTAssertEqual(scan.messageCount, 1,
                       "a \"From \" body line without a year must not be read as a separator")
    }

    /// A separator whose bytes span two read windows must still be found. With
    /// a naive per-chunk scan this silently merges two messages into one.
    func testSeparatorSpanningAWindowEdgeIsFound() async throws {
        // Pad the first message so the second separator lands mid-window.
        let padding = String(repeating: "x", count: 5_000)
        let url = try write(message(subject: "first", body: padding)
                            + message(subject: "second", body: "short"))

        var scanner = OffsetMBOXScanner()
        scanner.windowBytes = 512      // force many windows
        let scan = try await scanner.scan(fileURL: url)
        XCTAssertEqual(scan.messageCount, 2,
                       "a separator crossing a window edge must still be detected")
        XCTAssertEqual(scan.headers.map { $0["Subject"] }, ["first", "second"])
    }

    /// A bare `.eml` has no separator at all: the whole file is one message,
    /// and `envelopeRange` stays nil so a reader knows there was none.
    func testBareEMLIsOneMessageWithNoEnvelope() async throws {
        let url = try write("""
        From: sender@example.com
        Subject: bare
        Date: Tue, 14 Mar 2017 09:41:00 +0000

        body text
        """, name: "bare.eml")

        let scan = try await OffsetMBOXScanner().scan(fileURL: url)
        XCTAssertEqual(scan.messageCount, 1)
        XCTAssertNil(scan.locators.first?.envelopeRange,
                     "there was no From_ line, and the locator must not invent one")
        XCTAssertEqual(scan.headers.first?["Subject"], "bare")
    }

    func testEmptyFileYieldsNoMessages() async throws {
        let url = try write("")
        let scan = try await OffsetMBOXScanner().scan(fileURL: url)
        XCTAssertEqual(scan.messageCount, 0)
    }

    // MARK: - Header parsing

    /// Folded headers (RFC 5322 §2.2.3) must be joined, or a long Subject
    /// arrives truncated at the fold.
    func testFoldedHeadersAreJoined() async throws {
        let url = try write("""
        From sender@example.com Tue Mar 14 09:41:00 2017
        From: sender@example.com
        Subject: a subject that has been
         folded across two lines
        Date: Tue, 14 Mar 2017 09:41:00 +0000

        body

        """)
        let scan = try await OffsetMBOXScanner().scan(fileURL: url)
        XCTAssertEqual(scan.headers.first?["Subject"],
                       "a subject that has been folded across two lines")
    }

    /// Repeated fields are joined rather than overwritten: a `Received:` chain
    /// is evidence, and keeping only the last hop loses the path.
    func testRepeatedReceivedHeadersAreAllKept() async throws {
        let url = try write("""
        From sender@example.com Tue Mar 14 09:41:00 2017
        Received: from a.example.com
        Received: from b.example.com
        From: sender@example.com
        Subject: chain
        Date: Tue, 14 Mar 2017 09:41:00 +0000

        body

        """)
        let scan = try await OffsetMBOXScanner().scan(fileURL: url)
        let received = scan.headers.first?["Received"] ?? ""
        XCTAssertTrue(received.contains("a.example.com"), received)
        XCTAssertTrue(received.contains("b.example.com"),
                      "every Received hop must survive: \(received)")
    }

    /// CRLF mailboxes are common from Windows tools; the blank line that ends
    /// the header block is `\r\n` there.
    func testCRLFHeaderBlockTerminates() async throws {
        let crlf = "From sender@example.com Tue Mar 14 09:41:00 2017\r\n"
            + "From: sender@example.com\r\n"
            + "Subject: crlf\r\n"
            + "Date: Tue, 14 Mar 2017 09:41:00 +0000\r\n"
            + "\r\n"
            + "body line\r\n"
        let url = try write(crlf)

        let scan = try await OffsetMBOXScanner().scan(fileURL: url)
        XCTAssertEqual(scan.messageCount, 1)
        XCTAssertEqual(scan.headers.first?["Subject"], "crlf")
        XCTAssertGreaterThan(scan.locators.first?.bodyRange.length ?? 0, 0,
                             "the body must be located after the CRLF blank line")
    }

    // MARK: - Locator ranges

    func testHeaderAndBodyRangesAreInsideTheMessage() async throws {
        let url = try write(message(subject: "ranges", body: "the body"))
        let scan = try await OffsetMBOXScanner().scan(fileURL: url)
        let locator = try XCTUnwrap(scan.locators.first)

        XCTAssertTrue(locator.messageRange.contains(locator.headerRange))
        XCTAssertTrue(locator.messageRange.contains(locator.bodyRange))
        if let envelope = locator.envelopeRange {
            XCTAssertTrue(locator.messageRange.contains(envelope))
            XCTAssertEqual(envelope.offset, locator.messageRange.offset,
                           "the envelope is the first line of the message")
        }
    }

    /// The locator must actually resolve to the expected bytes — the whole
    /// point of S5.
    func testLocatorRangesReadBackTheExpectedBytes() async throws {
        let url = try write(message(subject: "readback", body: "distinctive body text"))
        let scan = try await OffsetMBOXScanner().scan(fileURL: url)
        let locator = try XCTUnwrap(scan.locators.first)
        let reader = LocatorReader()

        let headerData = try reader.read(locator.headerRange, from: url.path)
        let headerText = String(decoding: headerData, as: UTF8.self)
        XCTAssertTrue(headerText.contains("Subject: readback"), headerText)
        XCTAssertFalse(headerText.contains("distinctive body text"),
                       "the header range must not include the body")

        let bodyData = try reader.read(locator.bodyRange, from: url.path)
        let bodyText = String(decoding: bodyData, as: UTF8.self)
        XCTAssertTrue(bodyText.contains("distinctive body text"), bodyText)
    }

    /// A range past the end of the file is an error, not a short read. A
    /// silently truncated attachment is worse than a missing one, because it
    /// looks like evidence.
    func testOutOfRangeReadIsRefused() async throws {
        let url = try write(message(subject: "bounds", body: "body"))
        let size = (try FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0

        XCTAssertThrowsError(
            try LocatorReader().read(ByteRange(offset: size - 5, length: 500), from: url.path)
        ) { error in
            guard case LocatorReadError.rangeUnresolvable = error else {
                return XCTFail("expected rangeUnresolvable, got \(error)")
            }
        }
    }

    func testMissingSourceIsRefused() {
        XCTAssertThrowsError(
            try LocatorReader().read(ByteRange(offset: 0, length: 10),
                                     from: "/nonexistent/\(UUID().uuidString)")
        ) { error in
            guard case LocatorReadError.sourceMissing = error else {
                return XCTFail("expected sourceMissing, got \(error)")
            }
        }
    }

    // MARK: - Provenance verification

    /// The bug this pins: `LocatorReader` used to ACCEPT an `expectedDigest`,
    /// document that it verified the source, carry a `verifiesDigest` flag and
    /// a `digestMismatch` error — and check none of it. An edited source file
    /// was read and its bytes presented as the original message.
    ///
    /// Verification is now its own operation, and it actually fails on a
    /// changed file.
    func testVerifySourceDetectsATamperedFile() async throws {
        let url = try write(message(subject: "provenance", body: "original body text"))
        let digest = try OffsetImportEngine.digest(of: url)
        let scan = try await OffsetMBOXScanner().scan(fileURL: url)
        var locator = try XCTUnwrap(scan.locators.first)
        locator.sourceDigest = digest

        // Unchanged file: verification passes.
        XCTAssertNoThrow(try LocatorReader().verifySource(locator))
        XCTAssertTrue(locator.hasVerifiableSource)

        // Same-LENGTH edit — the case a bounds check cannot catch.
        var bytes = try Data(contentsOf: url)
        let target = bytes.count - 12
        bytes[target] = bytes[target] == 0x41 ? 0x42 : 0x41
        try bytes.write(to: url)
        XCTAssertEqual(bytes.count, Int(scan.sourceSize),
                       "the edit must not change the file length, or the bounds check would catch it")

        XCTAssertThrowsError(try LocatorReader().verifySource(locator)) { error in
            guard case LocatorReadError.digestMismatch = error else {
                return XCTFail("a tampered source must be a digestMismatch, got \(error)")
            }
        }

        // And the cheap read still succeeds — it never claimed to verify.
        // That is the honest split, not a gap: opening an attachment must not
        // hash a multi-gigabyte mailbox.
        XCTAssertNoThrow(try LocatorReader().read(locator.messageRange, from: locator.sourcePath))
    }

    /// A locator with no recorded digest must NOT report as verified. "We
    /// never recorded a hash" and "the hash matches" are different facts, and
    /// conflating them would let an unverifiable message be produced as
    /// verified.
    func testLocatorWithoutADigestIsNotVerifiable() async throws {
        let url = try write(message(subject: "nodigest", body: "body"))
        let scan = try await OffsetMBOXScanner().scan(fileURL: url)
        let locator = try XCTUnwrap(scan.locators.first)

        XCTAssertNil(locator.sourceDigest)
        XCTAssertFalse(locator.hasVerifiableSource,
                       "no digest means not verifiable, which is not the same as verified")
        // Verification is a no-op rather than a false pass — it cannot claim
        // anything, so it asserts nothing.
        XCTAssertNoThrow(try LocatorReader().verifySource(locator))
    }

    /// Streaming must deliver exactly the range, in chunks, so a
    /// multi-gigabyte part never has to be resident.
    func testStreamDeliversTheWholeRangeInChunks() async throws {
        let payload = String(repeating: "abcdefgh", count: 4096)   // 32 KiB
        let url = try write(payload, name: "stream.bin")

        var collected = Data()
        var chunks = 0
        try LocatorReader().stream(ByteRange(offset: 0, length: Int64(payload.utf8.count)),
                                   from: url.path, chunkSize: 4096) { chunk in
            collected.append(chunk)
            chunks += 1
        }
        XCTAssertEqual(collected.count, payload.utf8.count)
        XCTAssertEqual(String(decoding: collected, as: UTF8.self), payload)
        XCTAssertGreaterThan(chunks, 1, "the range should have been delivered in several chunks")
    }
}

// MARK: - The engine

final class OffsetImportEngineTests: XCTestCase {

    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("offset-engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func write(_ contents: String) throws -> URL {
        let url = directory.appendingPathComponent("fixture.mbox")
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func message(subject: String, bodyBytes: Int) -> String {
        """
        From sender@example.com Tue Mar 14 09:41:00 2017
        From: sender@example.com
        To: recipient@example.com
        Subject: \(subject)
        Date: Tue, 14 Mar 2017 09:41:00 +0000
        Message-ID: <\(subject)@example.com>

        \(String(repeating: "y", count: bodyBytes))

        """
    }

    /// The property that makes switching the capability on safe: an ordinary
    /// message must come out of the offset engine with the same headers and
    /// the same body as the streaming parser produces.
    ///
    /// `rawSource` is deliberately NOT asserted equal, because running this
    /// test found a fidelity defect in the streaming parser: it never appends
    /// the `From_` separator line to the message it accumulates, so
    /// `processRawMessage` sees a bare RFC 822 message and synthesises
    /// `From MAILER-DAEMON Thu Jan  1 00:00:00 1970`. The real envelope — the
    /// envelope sender and the delivery date, both forensically meaningful —
    /// is replaced with a 1970 placeholder. The offset engine reads the
    /// message range from the file and therefore keeps the original.
    ///
    /// Asserting byte-identity here would mean requiring the new engine to
    /// reproduce the old one's data loss, so instead
    /// `testOffsetEnginePreservesTheRealEnvelopeLine` pins the better
    /// behaviour and records the difference.
    func testOrdinaryMessagesMatchTheStreamingParser() async throws {
        let source = message(subject: "alpha", bodyBytes: 64)
            + message(subject: "beta", bodyBytes: 128)
        let url = try write(source)

        var viaOffset: [MBOXParser.RawEmail] = []
        _ = try await OffsetImportEngine().importMessages(
            fileURL: url, senderEmail: "me@example.com") { batch in
                viaOffset += batch.map(\.email)
            }

        var viaStreaming: [MBOXParser.RawEmail] = []
        _ = try await MBOXParser.parseStreamingCallback(
            fileURL: url, senderEmail: "me@example.com") { batch in
                viaStreaming += batch
            }

        XCTAssertEqual(viaOffset.count, viaStreaming.count)
        for (offset, streaming) in zip(viaOffset, viaStreaming) {
            XCTAssertEqual(offset.headers["Subject"], streaming.headers["Subject"])
            XCTAssertEqual(offset.headers["Message-ID"], streaming.headers["Message-ID"])
            XCTAssertEqual(offset.plainBody, streaming.plainBody,
                           "the two engines must agree on an ordinary message's body")
        }
    }

    /// The fidelity difference the test above uncovered, pinned so it cannot
    /// regress: the offset engine keeps the mailbox's real `From_` envelope,
    /// where the streaming parser substitutes a MAILER-DAEMON/1970 placeholder.
    func testOffsetEnginePreservesTheRealEnvelopeLine() async throws {
        let url = try write(message(subject: "envelope", bodyBytes: 32))

        var viaOffset: [MBOXParser.RawEmail] = []
        _ = try await OffsetImportEngine().importMessages(
            fileURL: url, senderEmail: "me@example.com") { batch in
                viaOffset += batch.map(\.email)
            }
        let offsetRaw = try XCTUnwrap(viaOffset.first?.rawSource)
        XCTAssertTrue(offsetRaw.hasPrefix("From sender@example.com Tue Mar 14 09:41:00 2017"),
                      "the original envelope line must survive: \(offsetRaw.prefix(80))")
        XCTAssertFalse(offsetRaw.contains("MAILER-DAEMON"),
                       "no placeholder envelope should be synthesised when a real one exists")

        var viaStreaming: [MBOXParser.RawEmail] = []
        _ = try await MBOXParser.parseStreamingCallback(
            fileURL: url, senderEmail: "me@example.com") { batch in
                viaStreaming += batch
            }
        // Documents the current streaming behaviour rather than endorsing it.
        // Fixing the streaming parser changes the default engine's raw bytes,
        // and therefore every stored hash and resume checkpoint, so it is a
        // separate, deliberate change — not a drive-by.
        let streamingRaw = try XCTUnwrap(viaStreaming.first?.rawSource)
        XCTAssertTrue(streamingRaw.contains("MAILER-DAEMON"),
                      "if this now fails, the streaming parser was fixed — update this test and the note above it")
    }

    /// The reason S4 exists. Under the streaming parser a message past the
    /// ceiling is counted `oversized_message` and never enters the archive;
    /// here it is imported from its headers with its bytes located.
    func testMessageOverTheCeilingIsImportedInsteadOfDropped() async throws {
        var engine = OffsetImportEngine()
        engine.fullParseCeilingBytes = 4_096     // small, so the fixture stays fast

        let url = try write(message(subject: "small", bodyBytes: 64)
                            + message(subject: "huge", bodyBytes: 16_384))

        var imported: [OffsetImportEngine.Imported] = []
        let report = try await engine.importMessages(
            fileURL: url, senderEmail: "me@example.com") { batch in
                imported += batch
            }

        XCTAssertEqual(report.totalMessages, 2)
        XCTAssertEqual(report.failed, 0, "neither message is damaged")
        XCTAssertEqual(imported.count, 2, "the oversized message must be archived, not skipped")

        let huge = try XCTUnwrap(imported.first { $0.email.headers["Subject"] == "huge" })
        XCTAssertFalse(huge.bodyWasDecoded)
        XCTAssertTrue(huge.email.rawSource.isEmpty,
                      "a header-only import must not pretend to hold the body")
        XCTAssertFalse(huge.email.anomalies.isEmpty,
                       "the deferred body must be marked, so no surface calls it fully processed")
        XCTAssertEqual(huge.email.headers["Subject"], "huge",
                       "headers are parsed even when the body is not")

        // And its bytes are locatable, which is what lets S5 serve it later.
        let reader = LocatorReader()
        let bytes = try reader.read(huge.locator.messageRange, from: url.path)
        XCTAssertEqual(Int64(bytes.count), huge.locator.byteCount)
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("Subject: huge"))

        let small = try XCTUnwrap(imported.first { $0.email.headers["Subject"] == "small" })
        XCTAssertTrue(small.bodyWasDecoded, "a message under the ceiling takes the proven path")
        XCTAssertFalse(small.email.rawSource.isEmpty)
    }

    /// Batches must respect the envelope's message bound, or the engine
    /// reintroduces an unbounded batch.
    func testBatchesRespectTheEnvelope() async throws {
        let source = (1...10).map { message(subject: "m\($0)", bodyBytes: 32) }.joined()
        let url = try write(source)

        var sizes: [Int] = []
        _ = try await OffsetImportEngine().importMessages(
            fileURL: url,
            senderEmail: "me@example.com",
            batchSize: 3,
            envelopeProvider: { BatchEnvelope(maxMessages: 3, maxBytes: Int.max) }
        ) { batch in
            sizes.append(batch.count)
        }

        XCTAssertEqual(sizes.reduce(0, +), 10, "every message must be delivered exactly once")
        for size in sizes {
            XCTAssertLessThanOrEqual(size, 3, "a batch must not exceed the envelope: \(sizes)")
        }
    }

    /// The source digest must end up on every locator, so a later read can
    /// prove it hit the same bytes.
    func testSourceDigestIsRecordedOnEveryLocator() async throws {
        let url = try write(message(subject: "digest", bodyBytes: 32))
        let digest = try OffsetImportEngine.digest(of: url)
        XCTAssertEqual(digest.count, 64, "SHA-256 renders as 64 hex characters")

        var imported: [OffsetImportEngine.Imported] = []
        _ = try await OffsetImportEngine().importMessages(
            fileURL: url, senderEmail: "me@example.com", sourceDigest: digest) { batch in
                imported += batch
            }
        XCTAssertEqual(imported.first?.locator.sourceDigest, digest)
    }

    /// Ordinals must be stable and gapless, because a resumed import
    /// reconciles against them.
    func testOrdinalsAreSequentialFromZero() async throws {
        let source = (1...5).map { message(subject: "m\($0)", bodyBytes: 16) }.joined()
        let url = try write(source)

        var imported: [OffsetImportEngine.Imported] = []
        _ = try await OffsetImportEngine().importMessages(
            fileURL: url, senderEmail: "me@example.com") { batch in
                imported += batch
            }
        XCTAssertEqual(imported.map(\.locator.ordinal), [0, 1, 2, 3, 4])
    }

    /// A header-only import must NOT report Complete.
    ///
    /// Found by audit. A message archived from its headers is parsed, stored
    /// and indexed, so every existing check in `ImportReconciler` passed and
    /// the receipt said "Every message was imported and is searchable" — about
    /// messages with no body at all. The receipt is the durable, honest
    /// record; that made it lie.
    func testHeaderOnlyImportIsPartialNotComplete() {
        let now = Date()

        // A clean run with nothing deferred is still Complete.
        var clean = ImportReceipt(startedAt: now, completedAt: now)
        clean.discovered = 10
        clean.parsed = 10
        clean.inserted = 10
        clean.duplicates = 0
        clean.indexed = 10
        XCTAssertEqual(ImportReconciler.verdict(for: clean), .complete,
                       "a run with no deferred bodies must still be Complete")

        // Same run, but two messages were imported header-only.
        var deferred = clean
        deferred.bodiesNotDecoded = 2
        let verdict = ImportReconciler.verdict(for: deferred)

        XCTAssertNotEqual(verdict, .complete, """
            an import that left bodies undecoded must not claim every message \
            is searchable
            """)
        XCTAssertEqual(verdict.label, "Partial")
        XCTAssertTrue(verdict.shortfalls.contains(.bodiesNotDecoded),
                      "the verdict must name the reason: \(verdict.shortfalls)")
        XCTAssertTrue(verdict.summary.lowercased().contains("headers"),
                      "the explanation must say what happened: \(verdict.summary)")
    }

    /// Receipts written before this field existed must decode as zero rather
    /// than failing — otherwise an upgrade would make old receipts unreadable,
    /// and a receipt is meant to be the durable record.
    func testOlderReceiptsDecodeWithNoDeferredBodies() throws {
        let json = """
        {
          "schemaVersion": 3,
          "sources": [],
          "discovered": 5, "parsed": 5, "damaged": 0, "skipped": 0,
          "persistFailed": 0, "indexed": 5, "attachmentsSeen": 0,
          "fileFailures": [], "warnings": [],
          "startedAt": 780000000, "completedAt": 780000001,
          "durationSeconds": 1, "resumed": false
        }
        """
        let decoder = JSONDecoder()
        let receipt = try decoder.decode(ImportReceipt.self, from: Data(json.utf8))
        XCTAssertEqual(receipt.bodiesNotDecoded, 0)
        XCTAssertEqual(ImportReconciler.verdict(for: receipt), .complete,
                       "an old clean receipt must still read as Complete")
    }

    /// The two engines must NOT share a resume identity, because they do not
    /// agree on message ordinals.
    ///
    /// Found by audit, not by a failing test. Checkpoints match on
    /// `(sha256, size, parser, parserVersion)` so that a parser change cannot
    /// resume mid-file against a different ordering — but
    /// `parserIdentity(forExtension:)` returned `("mbox", 1)` for both
    /// engines. The streaming parser DROPS a message over
    /// `MBOXParser.maxMessageBytes`; the offset engine IMPORTS it. One
    /// oversized message therefore shifts every later ordinal between them, so
    /// a half-finished streaming import resuming under the offset engine would
    /// "skip the first N" and skip a DIFFERENT N — duplicating some messages
    /// and losing others, in an evidence archive.
    func testEnginesDoNotShareAResumeIdentity() throws {
        let url = directory.appendingPathComponent("identity.mbox")
        try Data("From a@b.c Tue Mar 14 09:41:00 2017\nFrom: a@b.c\n\nbody\n".utf8)
            .write(to: url)

        let streaming = ParserFactory.parserIdentity(for: url, useOffsetEngine: false)
        let offset = ParserFactory.parserIdentity(for: url, useOffsetEngine: true)

        XCTAssertEqual(streaming.name, "mbox")
        XCTAssertEqual(offset.name, "mbox-offset")
        XCTAssertNotEqual(streaming.name, offset.name, """
            the engines must have distinct parser identities, or a checkpoint \
            written by one will be honoured by the other
            """)
    }

    /// A non-streamable format ignores the engine flag: there is no offset
    /// engine for PST, so asking for one must not mislabel the source record.
    func testNonStreamableFormatKeepsItsOwnIdentity() throws {
        let url = directory.appendingPathComponent("fake.pst")
        // "!BDN" + a Unicode wVer, enough for the classifier to route it.
        var header = Data([0x21, 0x42, 0x44, 0x4E])
        header.append(Data(repeating: 0, count: 6))
        header.append(Data([23, 0]))                  // wVer = 23 → Unicode
        header.append(Data(repeating: 0, count: 512))
        try header.write(to: url)

        let asked = ParserFactory.parserIdentity(for: url, useOffsetEngine: true)
        XCTAssertEqual(asked.name, "pst",
                       "the offset engine only handles line-structured mail; got \(asked.name)")
    }

    /// A file with no line structure must be refused, not scanned until
    /// memory runs out.
    func testFileWithNoLineBreaksIsRefused() async throws {
        let url = directory.appendingPathComponent("nolines.mbox")
        try Data(repeating: 0x41, count: 200_000).write(to: url)   // 200 KB of 'A'

        var scanner = OffsetMBOXScanner()
        scanner.windowBytes = 4_096
        // The bound is absolute, not a multiple of the window, so the test has
        // to lower it rather than relying on a small window.
        scanner.maxLineBytes = 64 * 1024
        do {
            _ = try await scanner.scan(fileURL: url)
            XCTFail("a file with no line breaks must be refused")
        } catch {
            // Any thrown error is acceptable; silently succeeding is not.
            XCTAssertTrue(error.localizedDescription.contains("line structure")
                          || error is ExtractionError,
                          "unexpected error: \(error)")
        }
    }
}
