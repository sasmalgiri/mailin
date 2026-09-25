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

// MARK: - S5: attachment readability is decided BEFORE offering the action

/// `AttachmentHydrator.canRead` documents itself as the check "used by UI that
/// must decide whether to offer Open/Save rather than offering an action that
/// then does nothing" — and had no caller. The bulk save path made the user
/// choose a destination folder first and only then reported "0 saved".
///
/// These pin the two answers that decision depends on.
@MainActor
final class AttachmentReadabilityTests: XCTestCase {

    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("readable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        AttachmentHydrator.locatorProvider = nil
    }

    private func headerOnlyEmail() -> MBOXParser.RawEmail {
        MBOXParser.RawEmail(
            headers: ["Message-ID": "<att@example.com>", "Subject": "Has an attachment",
                      "From": "a@example.com", "To": "b@example.com",
                      "Date": "Tue, 14 Mar 2017 09:41:00 +0000"],
            // Header-only import: the bytes live in the source file, not here.
            rawSource: "", messageType: "received",
            attachments: [AttachmentMetadata(filename: "report.pdf", mimeType: "application/pdf", size: 1024)],
            timestamp: "2017-03-14T09:41:00Z", domains: ["example.com"],
            plainBody: "", htmlBody: "")
    }

    /// `nonisolated static` so the `locatorProvider` closure — which is a
    /// plain `@Sendable` function, not main-actor work — can call it.
    nonisolated static func locator(sourcePath: String) -> MessageLocator {
        MessageLocator(
            sourceDigest: nil,
            sourcePath: sourcePath,
            messageRange: ByteRange(offset: 0, length: 10),
            envelopeRange: nil,
            headerRange: ByteRange(offset: 0, length: 10),
            bodyRange: ByteRange(offset: 10, length: 0),
            ordinal: 0)
    }

    /// A message with no stored bytes and no live source is NOT readable, so
    /// the UI must not offer to save it.
    func testUnmountedSourceIsNotReadable() throws {
        let email = headerOnlyEmail()
        let missing = directory.appendingPathComponent("never-written.mbox").path
        AttachmentHydrator.locatorProvider = { [missing] _ in
            Self.locator(sourcePath: missing)
        }
        let attachment = try XCTUnwrap(email.attachments.first)
        XCTAssertFalse(
            AttachmentHydrator.canRead(attachment, index: 0, email: email),
            "a locator pointing at a file that is not there must not read as readable")
    }

    /// The same message becomes readable once its source is present — so the
    /// check is answering about the source, not refusing everything.
    func testPresentSourceIsReadable() throws {
        let email = headerOnlyEmail()
        let url = directory.appendingPathComponent("present.mbox")
        try Data("From a@example.com\nSubject: x\n\nbody\n".utf8).write(to: url)
        AttachmentHydrator.locatorProvider = { [path = url.path] _ in
            Self.locator(sourcePath: path)
        }
        let attachment = try XCTUnwrap(email.attachments.first)
        XCTAssertTrue(
            AttachmentHydrator.canRead(attachment, index: 0, email: email),
            "a locator whose source exists must read as readable")
    }

    /// With no locator provider at all — capability off — a message that
    /// carries its own bytes is still readable, and one that does not is not.
    func testWithoutALocatorProviderStoredBytesStillCount() throws {
        AttachmentHydrator.locatorProvider = nil
        let attachment = AttachmentMetadata(filename: "x.pdf", mimeType: "application/pdf", size: 10)

        var stored = headerOnlyEmail()
        XCTAssertFalse(AttachmentHydrator.canRead(attachment, index: 0, email: stored),
                       "no bytes, no locator — nothing to offer")

        stored = MBOXParser.RawEmail(
            headers: stored.headers,
            rawSource: "From a@example.com\nSubject: x\n\nbody\n",
            messageType: "received", attachments: [attachment],
            timestamp: stored.timestamp, domains: ["example.com"],
            plainBody: "body", htmlBody: "")
        XCTAssertTrue(AttachmentHydrator.canRead(attachment, index: 0, email: stored),
                      "a message carrying its own raw source needs no locator")
    }
}

// MARK: - S5 per-part locators (audit defect 20)
//
// The scanner produces absolute byte ranges and decodes nothing, so the
// assertions that matter are:
//
//  • a range read back from the source is EXACTLY the part's bytes — no
//    leading newline, no trailing CRLF belonging to the next delimiter;
//  • a boundary string appearing inside body text is not a delimiter;
//  • nesting resolves to leaves in document order;
//  • malformed input still yields reachable bytes rather than dropping them.
//
// Two bytes of drift here silently corrupts every extracted attachment, which
// is why every test reads the range back and compares content rather than
// checking lengths.
//
// Lives in this file because the maxmailinTests target does not use a
// file-system synchronized group, so a new test file would not be compiled.

final class MIMEPartScannerTests: XCTestCase {

    private let messageID = UUID()

    /// Builds a message, returns its body bytes and the offset they sit at in
    /// a notional source file — a non-zero offset on purpose, because an
    /// off-by-`bodyOffset` bug would be invisible at zero.
    private func body(_ text: String, at offset: Int64 = 4_096) -> (Data, Int64) {
        (Data(text.utf8), offset)
    }

    /// Reads a part's range out of the same buffer, undoing `bodyOffset`.
    private func slice(_ part: PartLocator, from data: Data, bodyOffset: Int64) -> Data {
        let start = Int(part.contentRange.offset - bodyOffset)
        let end = start + Int(part.contentRange.length)
        guard start >= 0, end <= data.count, start <= end else { return Data() }
        return data.subdata(in: start..<end)
    }

    private func text(_ part: PartLocator, from data: Data, bodyOffset: Int64) -> String {
        String(data: slice(part, from: data, bodyOffset: bodyOffset), encoding: .utf8) ?? "<undecodable>"
    }

    // MARK: - Single part

    func testNonMultipartMessageIsOneLeafCoveringTheWholeBody() {
        let (data, offset) = body("just a plain body\nwith two lines\n")
        let parts = MIMEPartScanner.parts(
            bodyData: data, bodyOffset: offset,
            topHeaders: ["Content-Type": "text/plain; charset=utf-8"],
            messageID: messageID)

        XCTAssertEqual(parts.count, 1)
        let part = try! XCTUnwrap(parts.first)
        XCTAssertEqual(part.mimeType, "text/plain")
        XCTAssertEqual(part.contentRange.offset, offset, "the leaf starts where the body starts")
        XCTAssertEqual(part.contentRange.length, Int64(data.count), "and covers all of it")
        XCTAssertEqual(text(part, from: data, bodyOffset: offset),
                       "just a plain body\nwith two lines\n")
    }

    // MARK: - Flat multipart

    func testTwoPartMixedYieldsExactContentForEach() {
        let raw = [
            "--BOUND",
            "Content-Type: text/plain",
            "",
            "the readable body",
            "--BOUND",
            "Content-Type: application/pdf",
            "Content-Disposition: attachment; filename=\"report.pdf\"",
            "Content-Transfer-Encoding: base64",
            "",
            "QUJDREVG",
            "--BOUND--",
            ""
        ].joined(separator: "\r\n")
        let (data, offset) = body(raw)

        let parts = MIMEPartScanner.parts(
            bodyData: data, bodyOffset: offset,
            topHeaders: ["Content-Type": "multipart/mixed; boundary=\"BOUND\""],
            messageID: messageID)

        XCTAssertEqual(parts.count, 2, "two parts, and the closing delimiter is not a third")

        let first = try! XCTUnwrap(parts.first)
        XCTAssertEqual(first.mimeType, "text/plain")
        XCTAssertEqual(text(first, from: data, bodyOffset: offset), "the readable body",
                       "no leading newline and no trailing CRLF from the next delimiter")

        let second = try! XCTUnwrap(parts.last)
        XCTAssertEqual(second.mimeType, "application/pdf")
        XCTAssertEqual(second.filename, "report.pdf")
        XCTAssertEqual(second.contentTransferEncoding, "base64")
        XCTAssertTrue(second.isAttachment)
        XCTAssertEqual(text(second, from: data, bodyOffset: offset), "QUJDREVG",
                       "the encoded payload, exactly — this is what gets base64-decoded")
    }

    /// The whole point: the attachment's range must be a small fraction of a
    /// large message, so reading it does not read the message.
    func testAttachmentRangeIsIndependentOfTheSiblingSize() {
        let filler = String(repeating: "x", count: 200_000)
        let raw = [
            "--B", "Content-Type: text/plain", "", filler,
            "--B", "Content-Type: application/octet-stream",
            "Content-Disposition: attachment; filename=\"small.bin\"", "", "TINY",
            "--B--", ""
        ].joined(separator: "\r\n")
        let (data, offset) = body(raw)

        let parts = MIMEPartScanner.parts(
            bodyData: data, bodyOffset: offset,
            topHeaders: ["Content-Type": "multipart/mixed; boundary=B"],
            messageID: messageID)

        let attachment = try! XCTUnwrap(parts.first { $0.filename == "small.bin" })
        XCTAssertEqual(attachment.contentRange.length, 4,
                       "reading this attachment must cost 4 bytes, not \(data.count)")
        XCTAssertEqual(text(attachment, from: data, bodyOffset: offset), "TINY")
        XCTAssertLessThan(attachment.encodedByteCount, Int64(data.count) / 1000)
    }

    // MARK: - The trap: boundary text inside a body

    /// A line that merely CONTAINS the boundary, or is `--BOUND` mid-line, is
    /// not a delimiter. Splitting on it would truncate the part.
    func testBoundaryTextInsideBodyDoesNotSplitAPart() {
        let raw = [
            "--BOUND",
            "Content-Type: text/plain",
            "",
            "discussing --BOUND inline is allowed",
            "and a line mentioning --BOUND at the end --BOUND too",
            "--BOUND--",
            ""
        ].joined(separator: "\r\n")
        let (data, offset) = body(raw)

        let parts = MIMEPartScanner.parts(
            bodyData: data, bodyOffset: offset,
            topHeaders: ["Content-Type": "multipart/mixed; boundary=BOUND"],
            messageID: messageID)

        XCTAssertEqual(parts.count, 1, "mid-line boundary text must not create parts")
        let content = text(try! XCTUnwrap(parts.first), from: data, bodyOffset: offset)
        XCTAssertTrue(content.contains("discussing --BOUND inline"), content)
        XCTAssertTrue(content.contains("--BOUND at the end"),
                      "the part must not be cut at the mention: \(content)")
    }

    /// A line that starts with the boundary text but continues with other
    /// characters is a DIFFERENT boundary, not this one.
    func testLongerBoundaryPrefixIsNotThisDelimiter() {
        let raw = [
            "--B",
            "Content-Type: text/plain",
            "",
            "--BEXTRA is not our delimiter",
            "--B--",
            ""
        ].joined(separator: "\r\n")
        let (data, offset) = body(raw)

        let parts = MIMEPartScanner.parts(
            bodyData: data, bodyOffset: offset,
            topHeaders: ["Content-Type": "multipart/mixed; boundary=B"],
            messageID: messageID)

        XCTAssertEqual(parts.count, 1)
        XCTAssertTrue(text(try! XCTUnwrap(parts.first), from: data, bodyOffset: offset)
                        .contains("--BEXTRA is not our delimiter"))
    }

    // MARK: - Line endings

    func testBareLFMultipartIsHandled() {
        let raw = [
            "--B", "Content-Type: text/plain", "", "lf body",
            "--B", "Content-Type: text/html", "", "<p>lf html</p>",
            "--B--", ""
        ].joined(separator: "\n")
        let (data, offset) = body(raw)

        let parts = MIMEPartScanner.parts(
            bodyData: data, bodyOffset: offset,
            topHeaders: ["Content-Type": "multipart/alternative; boundary=B"],
            messageID: messageID)

        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(text(parts[0], from: data, bodyOffset: offset), "lf body")
        XCTAssertEqual(text(parts[1], from: data, bodyOffset: offset), "<p>lf html</p>")
    }

    // MARK: - Nesting

    func testNestedMultipartResolvesToLeavesInDocumentOrder() {
        let raw = [
            "--OUT",
            "Content-Type: multipart/alternative; boundary=\"IN\"",
            "",
            "--IN",
            "Content-Type: text/plain",
            "",
            "plain alternative",
            "--IN",
            "Content-Type: text/html",
            "",
            "<p>html alternative</p>",
            "--IN--",
            "--OUT",
            "Content-Type: application/pdf",
            "Content-Disposition: attachment; filename=\"a.pdf\"",
            "",
            "PDFBYTES",
            "--OUT--",
            ""
        ].joined(separator: "\r\n")
        let (data, offset) = body(raw)

        let parts = MIMEPartScanner.parts(
            bodyData: data, bodyOffset: offset,
            topHeaders: ["Content-Type": "multipart/mixed; boundary=OUT"],
            messageID: messageID)

        XCTAssertEqual(parts.map(\.mimeType),
                       ["text/plain", "text/html", "application/pdf"],
                       "leaves must come out flattened, in document order")
        XCTAssertEqual(text(parts[0], from: data, bodyOffset: offset), "plain alternative")
        XCTAssertEqual(text(parts[1], from: data, bodyOffset: offset), "<p>html alternative</p>")
        XCTAssertEqual(text(parts[2], from: data, bodyOffset: offset), "PDFBYTES")

        // Paths distinguish nesting, so two leaves are never confused.
        XCTAssertEqual(Set(parts.map(\.path)).count, parts.count,
                       "every leaf needs a distinct MIME path: \(parts.map(\.path))")
        XCTAssertGreaterThan(parts[0].path.count, parts[2].path.count,
                             "a nested leaf is deeper than a top-level one")
    }

    // MARK: - Malformed input stays reachable

    /// Declared multipart with no delimiter anywhere: the bytes must still be
    /// reachable as one part rather than vanishing.
    func testDeclaredMultipartWithNoDelimiterYieldsTheBodyAnyway() {
        let (data, offset) = body("no delimiters in here at all\n")
        let parts = MIMEPartScanner.parts(
            bodyData: data, bodyOffset: offset,
            topHeaders: ["Content-Type": "multipart/mixed; boundary=MISSING"],
            messageID: messageID)

        XCTAssertEqual(parts.count, 1, "the bytes must not be dropped")
        XCTAssertEqual(text(try! XCTUnwrap(parts.first), from: data, bodyOffset: offset),
                       "no delimiters in here at all\n")
    }

    /// Multipart declared with no boundary parameter — same rule.
    func testMultipartWithoutABoundaryParameterYieldsTheBodyAnyway() {
        let (data, offset) = body("orphaned content\n")
        let parts = MIMEPartScanner.parts(
            bodyData: data, bodyOffset: offset,
            topHeaders: ["Content-Type": "multipart/mixed"],
            messageID: messageID)
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(text(try! XCTUnwrap(parts.first), from: data, bodyOffset: offset),
                       "orphaned content\n")
    }

    func testEmptyBodyYieldsOneEmptyPartNotACrash() {
        let (data, offset) = body("")
        let parts = MIMEPartScanner.parts(
            bodyData: data, bodyOffset: offset,
            topHeaders: ["Content-Type": "text/plain"],
            messageID: messageID)
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts.first?.contentRange.length, 0)
    }

    /// Unbounded nesting must terminate. The inner content stays reachable as
    /// a leaf at the depth limit rather than being lost to recursion.
    func testDeeplyNestedMultipartTerminates() {
        // Each level declares the next; far deeper than maxDepth.
        var raw = ""
        let levels = MIMEPartScanner.maxDepth + 10
        for level in 0..<levels {
            raw += "--B\(level)\r\nContent-Type: multipart/mixed; boundary=\"B\(level + 1)\"\r\n\r\n"
        }
        raw += "--B\(levels)\r\nContent-Type: text/plain\r\n\r\ndeep\r\n--B\(levels)--\r\n"
        for level in stride(from: levels - 1, through: 0, by: -1) {
            raw += "--B\(level)--\r\n"
        }
        let (data, offset) = body(raw)

        let parts = MIMEPartScanner.parts(
            bodyData: data, bodyOffset: offset,
            topHeaders: ["Content-Type": "multipart/mixed; boundary=B0"],
            messageID: messageID)

        XCTAssertFalse(parts.isEmpty, "recursion must stop with the bytes still reachable")
        XCTAssertLessThanOrEqual(parts.map(\.path.count).max() ?? 0,
                                 MIMEPartScanner.maxDepth + 1,
                                 "depth must be bounded")
    }

    // MARK: - Headers

    func testPartHeadersAreParsedIncludingFoldedValues() {
        let raw = [
            "--B",
            "Content-Type: application/pdf",
            "Content-Disposition: attachment;",
            " filename=\"a very long name.pdf\"",
            "Content-ID: <cid-42@example.com>",
            "",
            "BYTES",
            "--B--",
            ""
        ].joined(separator: "\r\n")
        let (data, offset) = body(raw)

        let parts = MIMEPartScanner.parts(
            bodyData: data, bodyOffset: offset,
            topHeaders: ["Content-Type": "multipart/mixed; boundary=B"],
            messageID: messageID)

        let part = try! XCTUnwrap(parts.first)
        XCTAssertEqual(part.filename, "a very long name.pdf",
                       "a folded Content-Disposition must still yield the filename")
        XCTAssertEqual(part.contentID, "cid-42@example.com",
                       "the angle brackets are not part of the id")
        XCTAssertEqual(text(part, from: data, bodyOffset: offset), "BYTES")
    }

    /// The header range must cover the part's own headers and nothing else —
    /// it is what lets a reader show a part's metadata without its content.
    func testHeaderRangeCoversOnlyThePartHeaders() {
        let raw = [
            "--B",
            "Content-Type: text/plain",
            "",
            "content here",
            "--B--",
            ""
        ].joined(separator: "\r\n")
        let (data, offset) = body(raw)

        let part = try! XCTUnwrap(MIMEPartScanner.parts(
            bodyData: data, bodyOffset: offset,
            topHeaders: ["Content-Type": "multipart/mixed; boundary=B"],
            messageID: messageID).first)

        let start = Int(part.headerRange.offset - offset)
        let end = start + Int(part.headerRange.length)
        let headerText = String(data: data.subdata(in: start..<end), encoding: .utf8) ?? ""
        XCTAssertTrue(headerText.contains("Content-Type: text/plain"), headerText)
        XCTAssertFalse(headerText.contains("content here"),
                       "the header range must stop before the content: \(headerText)")
        XCTAssertFalse(headerText.contains("--B"),
                       "and must not include the delimiter: \(headerText)")
    }
}
