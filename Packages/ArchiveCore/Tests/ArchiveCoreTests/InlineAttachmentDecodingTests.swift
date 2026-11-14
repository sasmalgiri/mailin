//
//  InlineAttachmentDecodingTests.swift
//  ArchiveCoreTests
//
//  CLOSE-04 found two production defects on the native OLM / Apple Mail pair
//  (NativeOLMPairFixtureTests); these self-contained cases keep them fixed
//  without the external pack:
//   1. an inline part with a filename (`Content-Disposition: inline;
//      filename="pixel.png"`, the usual CID image) was transfer-decoded
//      twice — its 68 PNG bytes came out as 13 wrong bytes;
//   2. a filename written as an RFC 2047 encoded word inside the quoted
//      parameter stayed encoded (`=?UTF-8?B?…?=` instead of `zażółć.txt`).
//

import XCTest
import Foundation
import CryptoKit
@testable import ArchiveCore

final class InlineAttachmentDecodingTests: XCTestCase {

    static let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j/1sA\nAAAASUVORK5CYII="
    static let pngSHA256 = "a31bc9e0d54f843f4a3c088c88f7542e3ca553a0d9f2ec5956bb1e3ae23621d5"

    static func message(imageDisposition: String, textFilenameParam: String) -> String {
        """
        From: a@example.test
        To: b@example.test
        Subject: inline
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="mixed"

        --mixed
        Content-Type: multipart/related; boundary="rel"

        --rel
        Content-Type: text/html; charset=utf-8

        <p>x</p><img src="cid:px"/>
        --rel
        Content-Type: image/png; name="pixel.png"
        Content-Disposition: \(imageDisposition)
        Content-ID: <px>
        Content-Transfer-Encoding: base64

        \(pngBase64)
        --rel--
        --mixed
        Content-Type: text/plain
        Content-Disposition: attachment; \(textFilenameParam)
        Content-Transfer-Encoding: base64

        U3ludGhldGljIGF0dGFjaG1lbnQ6IFphxbzDs8WCxIcg5pel5pys6Kqe
        --mixed--

        """
    }

    func bytes(_ a: AttachmentMetadata) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(a.fileURL, "\(a.filename) materialised"))
    }

    func testInlineImageWithFilename_decodedOnce_exactBytes() throws {
        for disposition in ["inline; filename=\"pixel.png\"", "inline", "attachment; filename=\"pixel.png\""] {
            let raw = Self.message(imageDisposition: disposition, textFilenameParam: "filename=\"note.txt\"")
            let atts = try EmailBodyExtractor.extractContents(from: raw).attachments
            let png = try XCTUnwrap(atts.first { $0.filename == "pixel.png" }, "\(disposition): \(atts.map(\.filename))")
            let data = try bytes(png)
            XCTAssertEqual(data.count, 68, disposition)
            XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), Self.pngSHA256, disposition)
            XCTAssertEqual(png.contentID, "px", disposition)
            XCTAssertEqual(png.size, 68, disposition)
        }
    }

    func testRFC2047FilenameInQuotedParameter_isDecoded_RFC2231StillWorks_plainNamesUnchanged() throws {
        let cases = [
            "filename=\"=?UTF-8?B?emHFvMOzxYLEhy50eHQ=?=\"": "zażółć.txt",
            "filename=\"=?utf-8?Q?za=C5=BC=C3=B3=C5=82=C4=87.txt?=\"": "zażółć.txt",
            "filename*=utf-8''za%C5%BC%C3%B3%C5%82%C4%87.txt": "zażółć.txt",
            "filename=\"plain name.txt\"": "plain name.txt",
            "filename=\"a=b.txt\"": "a=b.txt",
        ]
        for (param, expected) in cases {
            let raw = Self.message(imageDisposition: "inline", textFilenameParam: param)
            let atts = try EmailBodyExtractor.extractContents(from: raw).attachments
            XCTAssertTrue(atts.contains { $0.filename == expected }, "\(param) → \(atts.map(\.filename))")
            let txt = try XCTUnwrap(atts.first { $0.filename == expected })
            XCTAssertEqual(String(decoding: try bytes(txt), as: UTF8.self), "Synthetic attachment: Zażółć 日本語")
        }
    }
}
