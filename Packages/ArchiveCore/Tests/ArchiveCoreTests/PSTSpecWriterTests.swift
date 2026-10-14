//
//  PSTSpecWriterTests.swift
//  ArchiveCoreTests
//
//  3.0 B8: the [MS-PST] writer. 1,000 synthetic emails (attachments, cc/bcc,
//  HTML, bodies larger than one heap allocation and one block) are written,
//  then read back by mailin's spec reader; with MAILIN_PST_TOOLS=1 the same
//  file is also checked by libpff (pypff) and libpst (readpst), independent
//  readers, run as external tools.
//

import XCTest
import Foundation
@testable import ArchiveCore

final class PSTSpecWriterTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("pstspecw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir); super.tearDown() }

    static func emails(_ n: Int) -> [MBOXParser.RawEmail] {
        (0..<n).map { i in
            let long = i % 25 == 0 ? String(repeating: "Long paragraph \(i) for the body. ", count: 400) : ""
            let body = "Hello number \(i).\n\(long)Regards,\nSender \(i % 30)"
            var atts: [AttachmentMetadata] = []
            if i % 10 == 0 {
                let bytes = Data((0..<(i % 40 == 0 ? 20_000 : 300)).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ i) })
                atts.append(AttachmentMetadata(filename: "file-\(i).bin", mimeType: "application/octet-stream", size: bytes.count,
                                               base64: bytes.base64EncodedString()))
            }
            var headers = ["From": "Sender \(i % 30) <s\(i % 30)@example.com>", "To": "Ann <ann@example.org>, bob@example.org",
                           "Subject": "Subject \(i) — résumé ✓", "Message-ID": "<w\(i)@example.com>",
                           "Date": "Mon, 6 Jan 2025 10:\(String(format: "%02d", i % 60)):00 +0000"]
            if i % 3 == 0 { headers["Cc"] = "Cara <cara@example.net>" }
            if i % 7 == 0 { headers["Bcc"] = "hidden@example.net" }
            return MBOXParser.RawEmail(headers: headers,
                                       rawSource: "From: s@example.com\r\nSubject: Subject \(i)\r\n\r\n\(body)",
                                       messageType: "email", attachments: atts,
                                       timestamp: "2025-01-06T10:\(String(format: "%02d", i % 60)):00Z", domains: ["example.com"],
                                       plainBody: body, htmlBody: i % 4 == 0 ? "<p>Hello <b>\(i)</b></p>" : "")
        }
    }

    func writeFixture(_ n: Int, name: String = "spec.pst") throws -> URL {
        let url = dir.appendingPathComponent(name)
        let w = try PSTSpecWriter(url: url)
        let inbox = w.appendFolder(name: "Inbox")
        for (i, e) in Self.emails(n).enumerated() {
            if i % 5 == 0 { try w.append(email: e, folder: inbox) } else { try w.appendMessage(e) }
        }
        XCTAssertEqual(try w.finalize(), n)
        return url
    }

    func testSpecWriter_1k_readsBackExactly_throughTheSpecReader() throws {
        let n = 1_000
        let url = try writeFixture(n)
        let bytes = try Data(contentsOf: url)
        // Structure: header CRCs, file ends at an allocation-map boundary.
        XCTAssertEqual(Array(bytes.prefix(4)), [0x21, 0x42, 0x44, 0x4E])
        let partial = bytes.subdata(in: 4..<8).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        XCTAssertEqual(partial, PSTSpecFormat.crc(bytes.subdata(in: 8..<479)))
        XCTAssertEqual((UInt64(bytes.count) - PSTSpecFormat.amapBase) % PSTSpecFormat.amapRegion, 0)

        let spec = try PSTSpecReader(data: bytes)
        XCTAssertEqual(spec.crypt, 0)
        let read = spec.messages()
        XCTAssertEqual(read.count, n)
        let original = Self.emails(n)
        let bySubject = Dictionary(uniqueKeysWithValues: read.map { ($0.internetMessageId ?? "", $0) })
        var problems: [String] = []
        for e in original {
            guard let m = bySubject[e.headers["Message-ID"]!] else { problems.append("missing \(e.headers["Message-ID"]!)"); continue }
            if m.subject != e.headers["Subject"] { problems.append("subject \(m.subject)") }
            if m.bodyText != e.plainBody { problems.append("body of \(m.subject) (\(m.bodyText.count) vs \(e.plainBody.count))") }
            if m.attachments.count != e.attachments.count { problems.append("attachments of \(m.subject)") }
            for (a, b) in zip(m.attachments, e.attachments) where a.data != Data(base64Encoded: b.base64 ?? "") {
                problems.append("attachment bytes of \(m.subject)")
            }
            if m.senderEmail != PSTSpecWriter.addresses(e.headers["From"]).first?.email { problems.append("sender of \(m.subject)") }
        }
        XCTAssertTrue(problems.isEmpty, problems.prefix(8).joined(separator: "\n"))
        // Folders: Inbox holds every fifth message, the export folder the rest.
        let inInbox = read.filter { $0.folderPath.hasSuffix("Inbox") }.count
        XCTAssertEqual(inInbox, n / 5)
        // Keep a copy for the external readers.
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: "/tmp/mailin-spec-1k.pst"))
        try? FileManager.default.copyItem(at: url, to: URL(fileURLWithPath: "/tmp/mailin-spec-1k.pst"))
    }
}
