//
//  HeaderCaseTests.swift
//  ArchiveCoreTests
//
//  Found on a real Gmail Sent.mbox (2026-10-07): an Outlook 12 message wrote
//  its MIME headers in lowercase ("content-type:") and was stored as raw
//  MIME text, boundaries and all, three multipart levels deep.
//

import XCTest
import Foundation
@testable import ArchiveCore

final class HeaderCaseTests: XCTestCase {

    func testLowercaseMIMEHeadersAreParsed() throws {
        let raw = """
        From jyotsana@example.com Thu Jun 12 10:26:46 2014
        From: Jyotsana <jyotsana@example.com>
        To: <owner@example.com>
        Subject: Abbott India - Executive Planning - Goa
        Date: Thu, 12 Jun 2014 10:26:46 +0530
        MIME-Version: 1.0
        content-type: multipart/mixed;
         boundary="----=_NextPart_000"

        ------=_NextPart_000
        content-type: multipart/related;
         boundary="----=_NextPart_001"

        ------=_NextPart_001
        content-type: multipart/alternative;
         boundary="----=_NextPart_002"

        ------=_NextPart_002
        content-type: text/plain;
         charset="us-ascii"
        content-transfer-encoding: 7bit

        Dear Candidate, please find the job description attached.

        ------=_NextPart_002
        content-type: text/html;
         charset="us-ascii"
        content-transfer-encoding: 7bit

        <html><body><p>Dear Candidate, please find the job description attached.</p></body></html>

        ------=_NextPart_002--

        ------=_NextPart_001--

        ------=_NextPart_000
        content-type: application/msword;
         name="JD.doc"
        content-transfer-encoding: base64
        content-disposition: attachment;
         filename="JD.doc"

        SGVsbG8=

        ------=_NextPart_000--

        """
        let email = try MBOXParser.processRawMessage(raw, senderEmail: "")
        XCTAssertTrue(email.plainBody.contains("Dear Candidate, please find the job description attached."))
        XCTAssertFalse(email.plainBody.contains("NextPart"), "raw MIME boundaries leaked into the text: \(email.plainBody.prefix(200))")
        XCTAssertEqual(email.attachments.map(\.filename), ["JD.doc"])
    }

    func testOtherHeaderNamesKeepTheirSpelling() {
        let headers = MIMEParser.parseHeaders(from: "Message-Id: <a@b>\ncontent-type: text/plain\nX-GM-THRID: 1")
        XCTAssertEqual(headers["Message-Id"], "<a@b>")
        XCTAssertEqual(headers["Content-Type"], "text/plain")
        XCTAssertEqual(headers["X-GM-THRID"], "1")
    }
}
