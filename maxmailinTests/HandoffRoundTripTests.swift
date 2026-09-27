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
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/Mail/Sent.mbox")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The claim behind "Export to Apple Mail": the mbox mailin writes gives
    /// back every message with the same attachments and, where the raw MIME
    /// was stored, byte-identical.
    func testRealMailbox_roundTripsThroughMBOX() async throws {
        let fixture = try XCTUnwrap(Self.fixture, "~/Downloads/Mail/Sent.mbox not present")
        try TestPreconditions.requireFreeSpace(TestPreconditions.referenceFixtureBudget)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("handoff-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let report = try await HandoffRoundTripHarness.run(sources: [fixture], root: root)
        print("HANDOFF-ROUNDTRIP \(report.verdictLine) seconds=\(String(format: "%.1f", report.seconds)) notes=\(report.notes)")
        XCTAssertGreaterThan(report.imported, 0)
        XCTAssertEqual(report.reparsed, report.imported, "every message must come back")
        XCTAssertTrue(report.missingAfterRoundTrip.isEmpty, "\(report.missingAfterRoundTrip)")
        XCTAssertTrue(report.attachmentMismatches.isEmpty, "\(report.attachmentMismatches)")
        XCTAssertEqual(report.rawHashesMatched, report.rawHashesCompared, "stored raw MIME must export byte-identical")
        XCTAssertTrue(report.passed, report.verdictLine)
    }

    /// Small partitions force several files, which is how a >4 GB export
    /// reaches an exFAT drive; identity must survive the split.
    func testRealMailbox_partitionedRoundTrip() async throws {
        let fixture = try XCTUnwrap(Self.fixture, "~/Downloads/Mail/Sent.mbox not present")
        try TestPreconditions.requireFreeSpace(TestPreconditions.referenceFixtureBudget)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("handoff-parts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let report = try await HandoffRoundTripHarness.run(sources: [fixture], root: root, partitionBytes: 16 * 1_048_576)
        print("HANDOFF-PARTITIONED partitions=\(report.partitions) \(report.verdictLine)")
        XCTAssertGreaterThan(report.partitions, 1, "a 95 MB mailbox at 16 MB per partition must split")
        XCTAssertTrue(report.passed, report.verdictLine)
    }
}
