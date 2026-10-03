//
//  UndatedMessageTests.swift
//  ArchiveCoreTests
//
//  Found on a real Gmail Sent.mbox (2026-10-03): a chat transcript with no
//  Date header and a message with an unreadable one were stored as year 1
//  and sorted to the bottom of every list. The message still carries its
//  delivery time, in Received and on the mbox envelope; the archive now uses
//  it, and never rewrites the Date header itself.
//

import XCTest
import Foundation
@testable import ArchiveCore

final class UndatedMessageTests: XCTestCase {

    private func gregorian(_ date: Date?) -> DateComponents? {
        guard let date else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.dateComponents([.year, .month, .day], from: date)
    }

    func testChatTranscriptWithoutDateHeader_isDatedFromReceived() throws {
        let raw = """
        From 1376223687785267735@xxx Thu Aug 04 14:46:24 +0000 2011
        X-GM-THRID: 1376223687785267735
        Received: by 10.216.93.194 with SMTP id l44cs14895wef;
                Thu, 4 Aug 2011 07:46:25 -0700 (PDT)
        From: ankan@example.com
        Subject: Chat with ankan@example.com
        Content-Type: text/plain

        hi
        """
        let email = try MBOXParser.processRawMessage(raw, senderEmail: "")
        XCTAssertNil(email.headers["Date"], "no Date header is invented")
        let parts = gregorian(MBOXParser.effectiveDate(for: email))
        XCTAssertEqual(parts?.year, 2011)
        XCTAssertEqual(parts?.month, 8)
        XCTAssertEqual(parts?.day, 4)
    }

    func testUnreadableDateHeader_fallsBackToEnvelope_andIsKeptVerbatim() throws {
        let raw = """
        From 1471395034029534947@xxx Fri Jun 20 02:34:13 +0000 2014
        Date: Fri, Jun 20, 2014 at 4:30 AM
        From: noreply@example.com
        Subject: Your registration
        Content-Type: text/plain

        welcome
        """
        let email = try MBOXParser.processRawMessage(raw, senderEmail: "")
        XCTAssertEqual(email.headers["Date"], "Fri, Jun 20, 2014 at 4:30 AM", "the Date header stays as found")
        let parts = gregorian(MBOXParser.effectiveDate(for: email))
        XCTAssertEqual(parts?.year, 2014)
        XCTAssertEqual(parts?.month, 6)
        XCTAssertEqual(parts?.day, 20)
    }

    func testReadableDateHeader_stillWins() throws {
        let raw = """
        From someone@xxx Fri Jun 20 02:34:13 +0000 2014
        Received: by host; Thu, 19 Jun 2014 19:34:12 -0700 (PDT)
        Date: Mon, 3 Mar 2014 10:00:00 +0000
        From: a@example.com
        Subject: s

        b
        """
        let email = try MBOXParser.processRawMessage(raw, senderEmail: "")
        XCTAssertEqual(gregorian(MBOXParser.effectiveDate(for: email))?.month, 3)
    }

    func testBareMessageWithNoDateAnywhere_staysUndated() throws {
        // A bare .eml gets a synthetic 1970 envelope; that is not a date.
        let raw = """
        From: a@example.com
        Subject: s

        b
        """
        let email = try MBOXParser.processRawMessage(raw, senderEmail: "")
        XCTAssertNil(MBOXParser.effectiveDate(for: email))
        XCTAssertEqual(email.timestamp, MBOXParser.undatedTimestamp)
    }
}
