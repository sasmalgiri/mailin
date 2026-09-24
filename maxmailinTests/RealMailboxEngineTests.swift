//
//  RealMailboxEngineTests.swift
//  maxmailinTests
//
//  The offset engine against REAL mail, which is the gap every S4 claim has
//  carried until now: it had only ever seen synthetic fixtures I wrote, and I
//  wrote them to be easy to reason about — LF endings, 76-column lines, tidy
//  headers. The reference mailbox is none of those things.
//
//  Measured shape of `~/Downloads/Mail/Sent.mbox`:
//      90.5 MiB · 526 messages · CRLF line endings · longest line 2,632 chars
//
//  Every one of those differs from the fixtures. CRLF in particular exercises
//  the blank-line terminator (`\r\n`, whose content is a bare `\r`) and the
//  separator test on lines that end in `\r` — paths the LF fixtures could not
//  reach.
//
//  Skips, rather than fails, when the mailbox is absent: it is the owner's
//  mail and is not in the repository. A skip that names the file is honest; a
//  failure would be noise on any other machine.
//

import XCTest
@testable import maxmailin

final class RealMailboxEngineTests: XCTestCase {

    private static var fixtureURL: URL? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Downloads/Mail/Sent.mbox")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func fixture() throws -> (url: URL, size: Int64) {
        guard let url = Self.fixtureURL else {
            throw XCTSkip("~/Downloads/Mail/Sent.mbox is not present on this machine")
        }
        let size = (try FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        return (url, size)
    }

    // MARK: - Boundaries over real mail

    /// The property that decides whether the offset engine can be trusted at
    /// all: its message ranges must tile the source exactly. A gap means lost
    /// bytes, an overlap means duplicated bytes, and either one in an evidence
    /// archive is unacceptable.
    func testRealMailbox_rangesTileTheFileExactly() async throws {
        let (url, size) = try fixture()

        var locators: [MessageLocator] = []
        let scan = try await OffsetMBOXScanner().scan(fileURL: url, collect: true,
                                                      onLocator: { locator, _ in
            locators.append(locator)
        })

        print("""

        ── Real mailbox: offset scan ──────────────────────────────
        size            : \(size / 1_048_576) MiB
        messages        : \(locators.count)
        largest message : \(scan.largestMessageBytes / 1024) KiB
        bytes in ranges : \(scan.totalMessageBytes) of \(size)
        truncated heads : \(scan.truncatedHeaderOrdinals.count)
        ───────────────────────────────────────────────────────────

        """)

        XCTAssertGreaterThan(locators.count, 0, "the scanner must find messages in real mail")
        XCTAssertEqual(locators.first?.messageRange.offset, 0,
                       "the first message must start at byte 0")
        XCTAssertEqual(locators.last?.messageRange.end, size,
                       "the last message must end at end-of-file — otherwise bytes are lost")
        XCTAssertEqual(scan.totalMessageBytes, size,
                       "message ranges must account for every byte of the source")

        for (previous, next) in zip(locators, locators.dropFirst()) {
            XCTAssertEqual(previous.messageRange.end, next.messageRange.offset,
                           "gap or overlap between messages \(previous.ordinal) and \(next.ordinal)")
        }
        XCTAssertTrue(scan.truncatedHeaderOrdinals.isEmpty,
                      "real mail should not exhaust the header budget: \(scan.truncatedHeaderOrdinals)")
    }

    /// Both engines must agree on how many messages the file contains. This is
    /// the claim that lets the capability be switched on: if the engines
    /// disagree on a real mailbox, one of them is wrong about the user's mail.
    func testRealMailbox_bothEnginesAgreeOnMessageCount() async throws {
        let (url, _) = try fixture()

        var streamingCount = 0
        let streamingReport = try await MBOXParser.parseStreamingCallback(
            fileURL: url, senderEmail: "", batchSize: 200
        ) { batch in streamingCount += batch.count }

        var offsetCount = 0
        var headerOnly = 0
        let offsetReport = try await OffsetImportEngine().importMessages(
            fileURL: url, senderEmail: "", batchSize: 200
        ) { batch in
            offsetCount += batch.count
            headerOnly += batch.filter { !$0.bodyWasDecoded }.count
        }

        print("""

        ── Real mailbox: engine agreement ─────────────────────────
        streaming : \(streamingCount) imported, \(streamingReport.failed) damaged \
        \(streamingReport.errorCategories)
        offset    : \(offsetCount) imported, \(offsetReport.failed) damaged, \
        \(headerOnly) header-only
        ───────────────────────────────────────────────────────────

        """)

        XCTAssertEqual(offsetCount, streamingCount, """
            the engines disagree on this real mailbox: streaming \(streamingCount) \
            vs offset \(offsetCount). One of them is wrong about the user's mail.
            """)
        XCTAssertEqual(offsetReport.failed, 0,
                       "the offset engine must not damage real mail: \(offsetReport.errorCategories)")
    }

    /// Headers must survive real-world folding, CRLF and repeated fields. The
    /// synthetic fixtures tested each of these in isolation with hand-written
    /// examples; this checks them against mail nobody wrote for a test.
    func testRealMailbox_headersAreParsedForEveryMessage() async throws {
        let (url, _) = try fixture()

        var headerSets: [[String: String]] = []
        _ = try await OffsetMBOXScanner().scan(fileURL: url, collect: false,
                                               onLocator: { _, headers in
            headerSets.append(headers)
        })

        let withFrom = headerSets.filter { !($0["From"] ?? "").isEmpty }.count
        let withSubject = headerSets.filter { !($0["Subject"] ?? "").isEmpty }.count
        let withDate = headerSets.filter { !($0["Date"] ?? "").isEmpty }.count
        let withMessageID = headerSets.filter {
            !($0["Message-ID"] ?? $0["Message-Id"] ?? "").isEmpty
        }.count

        print("""

        ── Real mailbox: header coverage (\(headerSets.count) messages) ──
        From       : \(withFrom)
        Subject    : \(withSubject)
        Date       : \(withDate)
        Message-ID : \(withMessageID)
        ───────────────────────────────────────────────────────────

        """)

        // `From` is mandatory in RFC 5322 and present in any real sent-mail
        // archive; a parser that misses it on real mail is broken regardless
        // of what the synthetic fixtures said.
        XCTAssertEqual(withFrom, headerSets.count,
                       "every real message must yield a From header")
        XCTAssertGreaterThan(withDate, headerSets.count * 9 / 10,
                             "Date should be present on essentially all real mail")
    }

    /// Locator ranges must resolve to the bytes they claim, on real mail with
    /// real MIME. A header range that bled into the body, or a body range off
    /// by a CRLF, would show up here and not in an LF fixture.
    func testRealMailbox_locatorRangesResolveToTheirContent() async throws {
        let (url, _) = try fixture()

        var locators: [MessageLocator] = []
        var headerSets: [[String: String]] = []
        _ = try await OffsetMBOXScanner().scan(fileURL: url, collect: false,
                                               onLocator: { locator, headers in
            locators.append(locator); headerSets.append(headers)
        })
        guard !locators.isEmpty else { throw XCTSkip("no messages found") }

        let reader = LocatorReader()
        // Sample across the file rather than reading 90 MiB back: first, last,
        // and evenly spaced middles.
        let sampleIndices = Set([0, locators.count - 1]
            + stride(from: 0, to: locators.count, by: max(1, locators.count / 12)))

        for index in sampleIndices.sorted() {
            let locator = locators[index]
            let headers = headerSets[index]

            let headerBytes = try reader.read(locator.headerRange, from: locator.sourcePath)
            let headerText = String(decoding: headerBytes, as: UTF8.self)

            // The header range must contain the From line it reported.
            if let from = headers["From"], !from.isEmpty {
                let firstToken = from.split(separator: " ").first.map(String.init) ?? from
                XCTAssertTrue(headerText.contains(firstToken), """
                    message \(index): header range does not contain its own From value \
                    (\(firstToken)) — the range is wrong
                    """)
            }
            // And must NOT contain the envelope line, which is a separate range.
            XCTAssertFalse(headerText.hasPrefix("From "), """
                message \(index): the header range must start after the From_ envelope, \
                got \(headerText.prefix(40).debugDescription)
                """)

            // Envelope + header + body must not exceed the message.
            XCTAssertTrue(locator.messageRange.contains(locator.headerRange))
            XCTAssertTrue(locator.messageRange.contains(locator.bodyRange))
            if let envelope = locator.envelopeRange {
                XCTAssertTrue(locator.messageRange.contains(envelope))
            }
        }
    }

    /// The header-only path, on REAL mail.
    ///
    /// The previous commit recorded this as a gap: nothing in the reference
    /// mailbox exceeds the 100 MB full-parse ceiling, so the one behaviour S4
    /// exists for was still exercised by synthetic fixtures only. Lowering the
    /// ceiling closes it — the same real messages, with real CRLF and real
    /// MIME, now take the header-only route.
    ///
    /// A 1 MiB ceiling is not a realistic setting; it is a way to route real
    /// mail down the path a 1.5 GB message would take in production.
    func testRealMailbox_headerOnlyPathOnRealMessages() async throws {
        let (url, _) = try fixture()

        var engine = OffsetImportEngine()
        engine.fullParseCeilingBytes = 1_048_576

        var imported: [OffsetImportEngine.Imported] = []
        let report = try await engine.importMessages(
            fileURL: url, senderEmail: "", batchSize: 200,
            sourceDigest: try OffsetImportEngine.digest(of: url)
        ) { batch in imported += batch }

        let headerOnly = imported.filter { !$0.bodyWasDecoded }
        let fullyParsed = imported.filter(\.bodyWasDecoded)

        print("""

        ── Real mailbox: header-only path (1 MiB ceiling) ─────────
        imported     : \(imported.count)
        header-only  : \(headerOnly.count)
        fully parsed : \(fullyParsed.count)
        damaged      : \(report.failed)
        ───────────────────────────────────────────────────────────

        """)

        XCTAssertEqual(report.failed, 0, "lowering the ceiling must not damage anything")
        XCTAssertGreaterThan(headerOnly.count, 0,
                             "a 1 MiB ceiling must route some real messages header-only")
        XCTAssertEqual(imported.count, headerOnly.count + fullyParsed.count)

        let reader = LocatorReader()
        for item in headerOnly.prefix(10) {
            // A header-only message must be honest about what it is.
            XCTAssertTrue(item.email.rawSource.isEmpty,
                          "a header-only message must not pretend to hold its body")
            XCTAssertTrue(item.email.plainBody.isEmpty)
            XCTAssertTrue(item.email.attachments.isEmpty,
                          "attachments cannot be enumerated without decoding")
            XCTAssertFalse(item.email.anomalies.isEmpty,
                           "the deferred body must be marked so no surface calls it processed")

            // But its headers must be real, from real mail.
            XCTAssertFalse((item.email.headers["From"] ?? "").isEmpty,
                           "headers are parsed even when the body is not")

            // And its bytes must be locatable and correct — this is what makes
            // the trade acceptable rather than data loss.
            let bytes = try reader.read(item.locator.messageRange,
                                        from: item.locator.sourcePath)
            XCTAssertEqual(Int64(bytes.count), item.locator.byteCount)
            XCTAssertTrue(item.locator.hasVerifiableSource)
            XCTAssertNoThrow(try reader.verifySource(item.locator))

            // The located bytes must actually be this message: its own
            // Message-ID has to appear in them.
            if let messageID = item.email.headers["Message-ID"],
               !messageID.isEmpty {
                let text = String(decoding: bytes.prefix(8192), as: UTF8.self)
                XCTAssertTrue(text.contains(messageID), """
                    located bytes do not contain the message's own Message-ID \
                    (\(messageID)) — the locator points at the wrong message
                    """)
            }
        }
    }

    /// The receipt must call such a run Partial, not Complete — on real
    /// numbers rather than a hand-built receipt.
    func testRealMailbox_headerOnlyRunWouldReportPartial() async throws {
        let (url, _) = try fixture()

        var engine = OffsetImportEngine()
        engine.fullParseCeilingBytes = 1_048_576
        var deferred = 0
        var total = 0
        _ = try await engine.importMessages(
            fileURL: url, senderEmail: "", batchSize: 200
        ) { batch in
            total += batch.count
            deferred += batch.filter { !$0.bodyWasDecoded }.count
        }
        XCTAssertGreaterThan(deferred, 0)

        // A receipt shaped like that run.
        let now = Date()
        var receipt = ImportReceipt(startedAt: now, completedAt: now)
        receipt.discovered = total
        receipt.parsed = total
        receipt.inserted = total
        receipt.duplicates = 0
        receipt.indexed = total
        receipt.bodiesNotDecoded = deferred

        let verdict = ImportReconciler.verdict(for: receipt)
        XCTAssertNotEqual(verdict, .complete, """
            \(deferred) of \(total) real messages had no body decoded; the receipt \
            must not claim every message is searchable
            """)
        XCTAssertTrue(verdict.shortfalls.contains(.bodiesNotDecoded))
        print("── Real mailbox: \(deferred)/\(total) deferred → verdict \(verdict.label)")
    }

    /// Provenance, end to end on real bytes: the digest recorded at import must
    /// verify against the untouched file. This is the operation that replaced
    /// the parameter that claimed to verify and did not.
    func testRealMailbox_sourceDigestVerifies() async throws {
        let (url, _) = try fixture()

        let digest = try OffsetImportEngine.digest(of: url)
        XCTAssertEqual(digest.count, 64, "SHA-256 renders as 64 hex characters")

        var first: MessageLocator?
        _ = try await OffsetMBOXScanner().scan(fileURL: url, collect: false,
                                               onLocator: { locator, _ in
            if first == nil { first = locator }
        })
        var locator = try XCTUnwrap(first)
        locator.sourceDigest = digest

        XCTAssertTrue(locator.hasVerifiableSource)
        XCTAssertNoThrow(try LocatorReader().verifySource(locator),
                         "the untouched reference mailbox must verify against its own digest")

        // A wrong digest must fail — otherwise the check proves nothing.
        var tampered = locator
        tampered.sourceDigest = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try LocatorReader().verifySource(tampered)) { error in
            guard case LocatorReadError.digestMismatch = error else {
                return XCTFail("expected digestMismatch, got \(error)")
            }
        }
    }
}
