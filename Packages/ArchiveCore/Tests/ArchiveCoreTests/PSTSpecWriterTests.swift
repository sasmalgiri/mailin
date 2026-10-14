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
            for (a, b) in zip(m.attachments, e.attachments) where Data(base64Encoded: a.base64 ?? "", options: .ignoreUnknownCharacters) != Data(base64Encoded: b.base64 ?? "") {
                problems.append("attachment bytes of \(m.subject): read \(Data(base64Encoded: a.base64 ?? "", options: .ignoreUnknownCharacters)?.count ?? -1) of \(b.size), meta size \(a.size), file \(a.fileURL?.path ?? "-")")
            }
            if m.senderEmail != PSTSpecWriter.addresses(e.headers["From"]).first?.email { problems.append("sender of \(m.subject)") }
            // Cc/Bcc come back from the recipient table (the display lines are computed, not stored).
            if e.headers["Cc"] != nil, !m.displayCc.contains("cara@example.net") { problems.append("cc of \(m.subject): \(m.displayCc)") }
            if e.headers["Bcc"] != nil, !m.displayBcc.contains("hidden@example.net") { problems.append("bcc of \(m.subject): \(m.displayBcc)") }
        }
        XCTAssertTrue(problems.isEmpty, problems.prefix(8).joined(separator: "\n"))
        // Folders: Inbox holds every fifth message, the export folder the rest.
        let inInbox = read.filter { $0.folderPath.hasSuffix("Inbox") }.count
        XCTAssertEqual(inInbox, n / 5)
        // Like Outlook, every message carries both a recipient table (0x692) and an
        // attachment table (0x671), empty or not; libpff rejects one without the other.
        let messageNodes = spec.nodes.values.filter { $0.nid & 0x1F == 0x04 }
        XCTAssertEqual(messageNodes.count, n)
        let incomplete = messageNodes.filter { node in
            let subs = spec.subnodes(node.subBid)
            return subs[0x692] == nil || subs[0x671] == nil
        }
        XCTAssertEqual(incomplete.count, 0, "messages missing a recipient or attachment table")
        // [MS-PST] 2.7.1 "Mandatory Nodes": a PST without any of these is invalid, and
        // Outlook refuses it (2026-10-14: the spam search folder 0x2223 was missing).
        let mandatory: [UInt32] = [0x21, 0x61, 0x122, 0x12D, 0x12E, 0x12F, 0x1E1, 0x201, 0x60D, 0x60E, 0x60F, 0x610,
                                   0x692, 0x671, 0x2223, 0x8022, 0x802D, 0x802E, 0x802F, 0x8042, 0x804D, 0x804E, 0x804F,
                                   0x8062, 0x806D, 0x806E, 0x806F]
        let missing = mandatory.filter { spec.nodes[$0] == nil }
        XCTAssertEqual(missing.map { String($0, radix: 16) }, [], "mandatory nodes missing")
        XCTAssertEqual(spec.nodes[0x2223]?.parent, 0x122, "the spam search folder belongs to the root folder")
        // [MS-PST] 2.4.5.1.1: properties every Message object PC must carry.
        let requiredMessageProps: [UInt16] = [0x001A, 0x0E07, 0x0E08, 0x0E17, 0x3007, 0x3008, 0x300B]
        let lacking = messageNodes.prefix(50).filter { node in
            let props = spec.propertyContext(dataBid: node.dataBid, subBid: node.subBid)
            return requiredMessageProps.contains { props[$0] == nil }
        }
        XCTAssertEqual(lacking.count, 0, "messages missing a required property")
        // Contents rows agree with their messages the way Outlook's do (SCANPST,
        // 2026-10-14: "row doesn't match sub-object" on 990 of 1,000 rows): no cell
        // the message lacks, no stored DisplayCc, rising row versions.
        var versions = Set<Int64>()
        for folder in [0x8082, 0x80A2] as [UInt32] {
            guard let node = spec.nodes[(folder >> 5) << 5 | 0x0E] else { XCTFail("contents table of \(folder)"); continue }
            for row in spec.table(dataBid: node.dataBid, subBid: node.subBid) {
                for tag: UInt32 in [0x0057_000B, 0x0058_000B, 0x0E03_001F] where row.values[tag] != nil {
                    XCTFail("row \(String(row.rowID, radix: 16)) carries \(String(tag, radix: 16))")
                }
                if let v = row.values[0x67F3_0003]?.int { versions.insert(v) }
            }
        }
        XCTAssertEqual(versions.count, n, "every row has its own non-zero row version")
        XCTAssertFalse(versions.contains(0))
        let spamProps = spec.propertyContext(dataBid: spec.nodes[0x2223]?.dataBid ?? 0, subBid: 0)
        if case .string(let name)? = spamProps[0x3001] { XCTAssertEqual(name, "SPAM Search Folder 2") } else { XCTFail("spam folder name") }
        // Keep a copy for the external readers.
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: "/tmp/mailin-spec-1k.pst"))
        try? FileManager.default.copyItem(at: url, to: URL(fileURLWithPath: "/tmp/mailin-spec-1k.pst"))
    }
}
