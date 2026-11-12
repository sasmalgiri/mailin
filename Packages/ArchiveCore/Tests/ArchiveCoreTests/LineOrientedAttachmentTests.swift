import XCTest
@testable import ArchiveCore

/// T26 finding (v4.0, 2026-11-12): the same mail from an mbox file (LF) and from a
/// server (CRLF) carried an attached .eml of 242 vs 250 bytes — its line endings
/// follow the transport — so the duplicate engine called the copies different.
final class LineOrientedAttachmentTests: XCTestCase {
    private func message(_ eol: String) -> String {
        let lines = [
            "From: a@example.org", "To: b@example.org", "Subject: Board minutes",
            "Message-ID: <lo@example.org>", "MIME-Version: 1.0",
            "Content-Type: multipart/mixed; boundary=\"B\"", "",
            "--B", "Content-Type: text/plain", "", "Body.",
            "--B", "Content-Type: message/rfc822; name=\"forwarded.eml\"",
            "Content-Disposition: attachment; filename=\"forwarded.eml\"", "",
            "From: c@example.org", "Subject: Inner", "", "Inner line one.", "Inner line two.",
            "--B", "Content-Type: application/octet-stream; name=\"blob.bin\"",
            "Content-Disposition: attachment; filename=\"blob.bin\"", "Content-Transfer-Encoding: base64", "",
            Data([0x01, 0x0D, 0x0A, 0x02]).base64EncodedString(),
            "--B--", ""]
        return lines.joined(separator: eol)
    }

    func testAttachedMessage_lfAndCrlfCopies_areTheSameOccurrence_binaryKeepsExactBytes() throws {
        let lf = try MBOXParser.processRawMessage(message("\n"), senderEmail: "")
        let crlf = try MBOXParser.processRawMessage(message("\r\n"), senderEmail: "")
        let a = ExportReconciliation.occurrences(of: lf, includeMIMEType: true)
        let b = ExportReconciliation.occurrences(of: crlf, includeMIMEType: true)
        XCTAssertEqual(a.missingBytes, 0); XCTAssertEqual(b.missingBytes, 0)
        XCTAssertEqual(ExportReconciliation.occurrenceMultiset(a.list), ExportReconciliation.occurrenceMultiset(b.list),
                       "\(a.list) vs \(b.list)")
        // A binary part is never normalised: its CR LF bytes stay as they are.
        XCTAssertFalse(ExportReconciliation.lineOrientedPart("application/octet-stream"))
        XCTAssertTrue(ExportReconciliation.lineOrientedPart("message/rfc822; name=x.eml"))
        XCTAssertTrue(ExportReconciliation.lineOrientedPart("Text/Plain"))
        XCTAssertEqual(ExportReconciliation.normalisedLineEndings(Data([0x61, 0x0D, 0x0A, 0x62, 0x0D, 0x63])), Data([0x61, 0x0A, 0x62, 0x0A, 0x63]))
    }
}
