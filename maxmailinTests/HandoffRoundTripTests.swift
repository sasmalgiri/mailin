@testable import ArchiveCore
//
//  HandoffRoundTripTests.swift
//  maxmailinTests
//
//  H1 + H2: the mbox writer's quoting rules, and the executed round trip
//  source → archive → mbox → re-parse over the owner's real mailbox.
//

import XCTest
@testable import maxmailin

final class MBOXQuotingTests: XCTestCase {

    func testQuotesLeadingFromOnEveryLineEnding() {
        XCTAssertEqual(MBOXRecordBuilder.quoteFromLines("From a\nFrom b\r\nFrom c\rlast"),
                       ">From a\n>From b\r\n>From c\rlast")
    }

    func testQuotesAlreadyQuotedLinesSoUnquotingIsReversible() {
        XCTAssertEqual(MBOXRecordBuilder.quoteFromLines(">From x\n>>From y\n"),
                       ">>From x\n>>>From y\n")
    }

    func testLeavesOtherLinesAndFromHeadersAlone() {
        let raw = "From: alice@example.com\nSubject: Fromage\n\nbody From here\n"
        XCTAssertEqual(MBOXRecordBuilder.quoteFromLines(raw), raw)
    }

    /// mboxrd is lossless only because reading undoes exactly what writing did.
    func testUnquoteIsTheInverseOfQuote() {
        let originals = ["From a\n>From b\r\n>>From c\rFrom: header\nplain\n", "From ", ">From ", "", "x\n\nFrom y"]
        for original in originals {
            XCTAssertEqual(MBOXRecordBuilder.unquoteFromLines(MBOXRecordBuilder.quoteFromLines(original)), original,
                           "round trip of \(original.debugDescription)")
        }
        XCTAssertEqual(MBOXRecordBuilder.unquoteFromLines(">From x\n>>From y\nFrom z\n"), "From x\n>From y\nFrom z\n")
    }

    /// A mailbox written by another client (Takeout, Apple Mail, Thunderbird)
    /// carries `>From ` escaping; both engines must read it back as `From `.
    func testBothEnginesUnescapeMboxrdBodyLines() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mboxrd-\(UUID().uuidString).mbox")
        defer { try? FileManager.default.removeItem(at: url) }
        let record = """
        From alice@example.com Tue Mar 14 09:41:00 2017
        From: Alice <alice@example.com>
        To: bob@example.com
        Subject: moving
        Date: Tue, 14 Mar 2017 09:41:00 +0000
        Message-ID: <mboxrd-\(UUID().uuidString)@example.com>

        I want to move again.
        >From Bara jaguli to Kalyani
        >>From a quoted reply
        Regards

        """
        try Data(record.utf8).write(to: url)

        var streaming: [MBOXParser.RawEmail] = []
        _ = try await MBOXParser.parseStreamingCallback(fileURL: url, senderEmail: "") { streaming += $0 }
        let viaStreaming = try XCTUnwrap(streaming.first)
        XCTAssertTrue(viaStreaming.rawSource.contains("\nFrom Bara jaguli to Kalyani\n"), viaStreaming.rawSource)
        XCTAssertTrue(viaStreaming.rawSource.contains("\n>From a quoted reply\n"))
        XCTAssertTrue(viaStreaming.plainBody.contains("From Bara jaguli"))
        XCTAssertFalse(viaStreaming.plainBody.contains(">From Bara"))

        var offset: [MBOXParser.RawEmail] = []
        _ = try await OffsetImportEngine().importMessages(fileURL: url, senderEmail: "") { offset += $0.map(\.email) }
        let viaOffset = try XCTUnwrap(offset.first)
        XCTAssertTrue(viaOffset.rawSource.hasPrefix("From alice@example.com Tue Mar 14 09:41:00 2017\n"), "real envelope kept")
        XCTAssertTrue(viaOffset.rawSource.contains("\nFrom Bara jaguli to Kalyani\n"), viaOffset.rawSource)
        XCTAssertTrue(viaOffset.rawSource.contains("\n>From a quoted reply\n"))

        // A bare .eml has no container escaping: its `>From` is content.
        let eml = url.deletingPathExtension().appendingPathExtension("eml")
        defer { try? FileManager.default.removeItem(at: eml) }
        try Data(record.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)[1].utf8).write(to: eml)
        var bare: [MBOXParser.RawEmail] = []
        _ = try await MBOXParser.parseStreamingCallback(fileURL: eml, senderEmail: "") { bare += $0 }
        XCTAssertTrue(try XCTUnwrap(bare.first).rawSource.contains("\n>From Bara jaguli to Kalyani\n"))
    }

    @MainActor
    func testRecordStartsWithEnvelopeAndEndsWithBlankLine() {
        let email = MBOXParser.RawEmail(
            headers: ["From": "Alice <alice@example.com>", "To": "bob@example.com", "Subject": "Hi",
                      "Date": "Tue, 14 Mar 2017 09:41:00 +0000", "Message-ID": "<q-\(UUID().uuidString)@example.com>"],
            rawSource: "From: Alice <alice@example.com>\nSubject: Hi\n\nFrom the top\n",
            messageType: "email", attachments: [], timestamp: "Tue, 14 Mar 2017 09:41:00 +0000",
            domains: ["example.com"], plainBody: "From the top", htmlBody: "")
        let record = ArchiveExportService.mboxRecord(for: email)
        XCTAssertTrue(record.hasPrefix("From alice@example.com "), record.prefix(60).description)
        XCTAssertTrue(record.contains("\n>From the top\n"))
        XCTAssertTrue(record.hasSuffix("\n\n"))
    }
}

final class HandoffRoundTripTests: XCTestCase {

    private static var fixture: URL? {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads/Mail/Sent.mbox")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The claim behind "Export to Apple Mail": the mbox mailin writes gives
    /// back every message with the same attachments and, where the raw MIME
    /// was stored, byte-identical from the first header byte to the last body
    /// byte. The mbox container's own framing (envelope line, `>From `
    /// quoting, record separator) is legitimately rewritten and is excluded.
    func testRealMailbox_roundTripsThroughMBOX() async throws {
        guard let fixture = Self.fixture else { throw XCTSkip("~/Downloads/Mail/Sent.mbox not present") }
        try TestPreconditions.requireFreeSpace(TestPreconditions.referenceFixtureBudget)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("handoff-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let report = try await HandoffRoundTripHarness.run(sources: [fixture], root: root)
        print("HANDOFF-ROUNDTRIP \(report.verdictLine) seconds=\(String(format: "%.1f", report.seconds)) notes=\(report.notes)")
        XCTAssertGreaterThan(report.imported, 0)
        XCTAssertEqual(report.reparsed, report.imported, "every message must come back")
        XCTAssertTrue(report.missingAfterRoundTrip.isEmpty, "\(report.missingAfterRoundTrip)")
        XCTAssertTrue(report.attachmentMismatches.isEmpty, "\(report.attachmentMismatches)")
        XCTAssertEqual(report.rawHashesMatched, report.rawHashesCompared,
                       "stored raw MIME must come back byte-identical from the first header byte to the last body byte (mbox framing — envelope line and record separator — excluded)")
        XCTAssertTrue(report.passed, report.verdictLine)
    }

    /// Small partitions force several files, which is how a >4 GB export
    /// reaches an exFAT drive; identity must survive the split.
    func testRealMailbox_partitionedRoundTrip() async throws {
        guard let fixture = Self.fixture else { throw XCTSkip("~/Downloads/Mail/Sent.mbox not present") }
        try TestPreconditions.requireFreeSpace(TestPreconditions.referenceFixtureBudget)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("handoff-parts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let report = try await HandoffRoundTripHarness.run(sources: [fixture], root: root, partitionBytes: 16 * 1_048_576)
        print("HANDOFF-PARTITIONED partitions=\(report.partitions) \(report.verdictLine) notes=\(report.notes)")
        XCTAssertGreaterThan(report.partitions, 1, "a 95 MB mailbox at 16 MB per partition must split")
        XCTAssertTrue(report.passed, report.verdictLine)
    }
}
