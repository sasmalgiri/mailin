//
//  Base64BodyTwiceTests.swift
//  ArchiveCoreTests
//
//  2026-11-15 (found by the 100 MB Notes test): a base64 text part was
//  decoded twice — MIMEParser decoded it, EmailBodyExtractor decoded the
//  decoded text again — so a body whose text was itself "valid base64"
//  (alphabet characters a multiple of 4: about one in four) became garbage.
//  Any format that reaches MBOXParser was affected (mbox, eml, rendered PST /
//  MSG / NSF). Quoted-printable had the same second pass ("=41" in a decoded
//  text turned into "A").
//

import XCTest
@testable import ArchiveCore

final class Base64BodyTwiceTests: XCTestCase {
    private func raw(_ contentType: String, _ encoding: String, _ body: String) -> String {
        "From: a@example.org\r\nSubject: t\r\nMIME-Version: 1.0\r\nContent-Type: \(contentType)\r\n"
            + "Content-Transfer-Encoding: \(encoding)\r\n\r\n\(body)\r\n"
    }

    private func b64(_ s: String) -> String {
        Data(s.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
    }

    func testSinglePartBase64_textThatIsValidBase64_isDecodedOnce() throws {
        // 32 alphabet characters: the decoded text is itself decodable base64.
        let text = "Memo 96. Quarterly figures and the plan."
        let email = try MBOXParser.processRawMessage(raw("text/plain; charset=utf-8", "base64", b64(text)), senderEmail: "")
        XCTAssertEqual(email.plainBody, text)
        // And one that is not (the case that always worked) stays right.
        let other = "Memo 5. Quarterly figures and the plan!"
        XCTAssertEqual(try MBOXParser.processRawMessage(raw("text/plain; charset=utf-8", "base64", b64(other)), senderEmail: "").plainBody, other)
    }

    func testMultipartBase64PlainAndHTML_decodedOnce() throws {
        let plain = "abcd efgh ijkl mnop", html = "<p>abcdefgh</p>"
        let body = "--B\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n\(b64(plain))\r\n"
            + "--B\r\nContent-Type: text/html; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n\(b64(html))\r\n--B--"
        let email = try MBOXParser.processRawMessage(
            "From: a@example.org\r\nSubject: t\r\nMIME-Version: 1.0\r\nContent-Type: multipart/alternative; boundary=\"B\"\r\n\r\n\(body)\r\n",
            senderEmail: "")
        XCTAssertEqual(email.plainBody, plain)
        XCTAssertEqual(email.htmlBody, html)
    }

    func testQuotedPrintable_decodedTextWithAnEqualsSignIsNotDecodedAgain() throws {
        // "=3D41" decodes to "=41"; a second pass turned that into "A".
        let email = try MBOXParser.processRawMessage(raw("text/plain; charset=utf-8", "quoted-printable", "price =3D41 euro"), senderEmail: "")
        XCTAssertEqual(email.plainBody, "price =41 euro")
    }

    func testLatin1EightBit_keepsTheParsersCharsetDecoding() throws {
        let email = try MBOXParser.processRawMessage(raw("text/plain; charset=utf-8", "8bit", "Grüße aus Köln"), senderEmail: "")
        XCTAssertEqual(email.plainBody, "Grüße aus Köln")
    }
}
