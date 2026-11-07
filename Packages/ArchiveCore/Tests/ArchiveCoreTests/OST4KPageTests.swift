//
//  OST4KPageTests.swift
//  ArchiveCoreTests
//
//  Directive 2026-11-07 §6: the version-36 / 4 KiB-page OST (Outlook 2013+).
//  No real `example-2013.ost` is on this Mac, so the fixture is written by
//  the spec writer with `PSTWriterLayout.ost4K` (header wVer 36, "SO", 4096-
//  byte B-tree pages, 24-byte trailers, 512-byte block alignment) and read
//  back through the production entry points. Before the geometry seam the
//  reader walked these pages with the 512-byte layout and found no message.
//

import XCTest
import Foundation
@testable import ArchiveCore

final class OST4KPageTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ost4k-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir); super.tearDown() }

    static let attachmentBytes: [Data] = [
        Data((0..<300).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 1) }),
        Data((0..<20_000).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 2) }),   // crosses heap allocation → subnode, several blocks
        Data("third attachment, plain text".utf8),
    ]

    static func emails() -> [MBOXParser.RawEmail] {
        (0..<3).map { i in
            let body = "Body of OST message \(i).\nSecond line."
            let bytes = attachmentBytes[i]
            let att = AttachmentMetadata(filename: "file-\(i).bin", mimeType: "application/octet-stream", size: bytes.count,
                                         base64: bytes.base64EncodedString())
            let headers = ["From": "Sender \(i) <s\(i)@example.com>", "To": "Ann <ann@example.org>",
                           "Subject": "OST subject \(i) — résumé ✓", "Message-ID": "<ost\(i)@example.com>",
                           "Date": "Mon, 6 Jan 2025 10:0\(i):00 +0000"]
            return MBOXParser.RawEmail(headers: headers, rawSource: "", messageType: "email", attachments: [att],
                                       timestamp: "2025-01-06T10:0\(i):00Z", domains: ["example.com"],
                                       plainBody: body, htmlBody: i == 1 ? "<p>Body of OST message 1.</p>" : "")
        }
    }

    /// Three messages in three folders (Inbox, Inbox/Projects, Sent), each with an attachment.
    func writeFixture(layout: PSTWriterLayout, name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let w = try PSTSpecWriter(url: url, layout: layout)
        let inbox = w.appendFolder(name: "Inbox")
        let projects = w.appendFolder(name: "Projects", parent: inbox)
        let sent = w.appendFolder(name: "Sent")
        for (e, folder) in zip(Self.emails(), [inbox, projects, sent]) { try w.append(email: e, folder: folder) }
        XCTAssertEqual(try w.finalize(), 3)
        return url
    }

    static func u16(_ d: Data, _ o: Int) -> UInt16 { UInt16(d[o]) | UInt16(d[o + 1]) << 8 }
    static func u64(_ d: Data, _ o: Int) -> UInt64 { (0..<8).reduce(UInt64(0)) { $0 | UInt64(d[o + $1]) << (8 * UInt64($1)) } }

    func testOST_version36_fourKiBPages_readThroughThePSTEntryPoints() async throws {
        let url = try writeFixture(layout: .ost4K, name: "example-2013-synthetic.ost")
        let bytes = try Data(contentsOf: url)

        // The file declares itself: "!BDN", wMagicClient "SO", wVer 36, header CRCs as in the Unicode layout.
        XCTAssertEqual(Array(bytes.prefix(4)), [0x21, 0x42, 0x44, 0x4E])
        XCTAssertEqual(Array(bytes[8..<10]), [0x53, 0x4F], "SO")
        XCTAssertEqual(Self.u16(bytes, 10), 36)
        XCTAssertEqual(SourceSizePolicy.pstFormatVersion(fromHeader: bytes.prefix(16)), .unicode(36))
        XCTAssertEqual(bytes.subdata(in: 4..<8).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }, PSTSpecFormat.crc(bytes.subdata(in: 8..<479)))
        // 4 KiB pages: both B-tree roots sit on 4096-byte boundaries, the counts are at byte 4056 of the page,
        // the page trailer's ptype is at 4072 and the file ends at an AMap boundary of the 4 KiB geometry.
        let nbtIB = Self.u64(bytes, 224), bbtIB = Self.u64(bytes, 240)
        XCTAssertEqual(nbtIB % 4096, 0); XCTAssertEqual(bbtIB % 4096, 0)
        for (ib, ptype) in [(nbtIB, UInt8(0x81)), (bbtIB, UInt8(0x80))] {
            let o = Int(ib)
            XCTAssertEqual(bytes[o + 4072], ptype, "ptype"); XCTAssertEqual(bytes[o + 4073], ptype, "ptypeRepeat")
            XCTAssertGreaterThan(Self.u16(bytes, o + 4056), 0, "cEnt")
            XCTAssertEqual(bytes[o + 4061], 0, "cLevel of a one-page tree")
            XCTAssertEqual(bytes.subdata(in: (o + 4076)..<(o + 4080)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) },
                           PSTSpecFormat.crc(bytes.subdata(in: o..<(o + 4072))), "dwCRC over the 4072 bytes before the trailer")
        }
        XCTAssertEqual((UInt64(bytes.count) - PSTWriterLayout.ost4K.amapBase) % PSTWriterLayout.ost4K.amapRegion, 0)

        // The spec reader: three messages, their folders, their attachment bytes.
        let spec = try PSTSpecReader(data: bytes)
        XCTAssertEqual(spec.geometry, .fourK)
        let read = spec.messages().sorted { $0.subject < $1.subject }
        XCTAssertEqual(read.count, 3, "messages read from the 4 KiB-page file")
        guard read.count == 3 else { return }   // before the geometry seam the reader found none
        XCTAssertEqual(read.map(\.folderPath), ["Top of Personal Folders/Inbox", "Top of Personal Folders/Inbox/Projects", "Top of Personal Folders/Sent"])
        let declared = Set(spec.folderPaths())
        for folder in ["Top of Personal Folders/Inbox", "Top of Personal Folders/Inbox/Projects", "Top of Personal Folders/Sent",
                       "Top of Personal Folders/Deleted Items", "Top of Personal Folders/mailin export"] {
            XCTAssertTrue(declared.contains(folder), "folder listed by the file (empty ones included): \(folder)")
        }
        for (i, m) in read.enumerated() {
            XCTAssertEqual(m.subject, "OST subject \(i) — résumé ✓")
            XCTAssertEqual(m.bodyText, "Body of OST message \(i).\nSecond line.")
            XCTAssertEqual(m.internetMessageId, "<ost\(i)@example.com>")
            XCTAssertEqual(m.attachments.count, 1)
            XCTAssertEqual(m.attachments.first?.filename, "file-\(i).bin")
            XCTAssertEqual(m.attachments.first?.base64.flatMap { Data(base64Encoded: $0) }, Self.attachmentBytes[i], "attachment bytes of message \(i)")
        }
        XCTAssertEqual(read[1].bodyHTML, "<p>Body of OST message 1.</p>")

        // The production entry points: array path and the streaming path, same folders and ordering.
        let parsed = try PSTParser.parse(fileURL: url, senderEmail: "")
        XCTAssertEqual(parsed.count, 3)
        XCTAssertEqual(Set(parsed.compactMap(\.folderPath)), ["Top of Personal Folders/Inbox", "Top of Personal Folders/Inbox/Projects", "Top of Personal Folders/Sent"])
        XCTAssertEqual(parsed.flatMap(\.attachments).count, 3)
        var streamed: [MBOXParser.RawEmail] = []
        let result = try await PSTParser.parseStreaming(fileURL: url, senderEmail: "", batchSize: 2) { batch in streamed += batch }
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(streamed.map { $0.headers["Message-ID"] ?? "" }, parsed.map { $0.headers["Message-ID"] ?? "" })
        XCTAssertTrue(result.declaredFolders.contains("Top of Personal Folders/Inbox/Projects"))

        // Parity with the same three messages written as a Unicode 512-byte PST: the geometry
        // seam changes nothing the reader hands out.
        let pst = try writeFixture(layout: .unicodePST, name: "same-three.pst")
        let pstRead = try PSTSpecReader(data: Data(contentsOf: pst))
        XCTAssertEqual(pstRead.geometry, .unicode512)
        let viaPST = pstRead.messages().sorted { $0.subject < $1.subject }
        XCTAssertEqual(viaPST.map(\.subject), read.map(\.subject))
        XCTAssertEqual(viaPST.map(\.folderPath), read.map(\.folderPath))
        XCTAssertEqual(viaPST.map { $0.attachments.first?.base64 }, read.map { $0.attachments.first?.base64 })
    }

    /// Enough messages for the node B-tree to need more than one 4 KiB leaf page (126 NBT
    /// entries per leaf) and an index level: every message still comes back, in NID order.
    func testOST_version36_multiPageBTrees_everyMessageRead() throws {
        let url = dir.appendingPathComponent("many.ost")
        let w = try PSTSpecWriter(url: url, layout: .ost4K)
        let n = 400
        for e in PSTSpecWriterTests.emails(n) { try w.appendMessage(e) }
        XCTAssertEqual(try w.finalize(), n)
        let bytes = try Data(contentsOf: url)
        let nbtIB = Int(Self.u64(bytes, 224))
        XCTAssertGreaterThan(bytes[nbtIB + 4061], 0, "the NBT root is an index page: more than one leaf")
        let spec = try PSTSpecReader(data: bytes)
        let read = spec.messages()
        XCTAssertEqual(read.count, n)
        XCTAssertEqual(Set(read.compactMap(\.internetMessageId)).count, n)
        XCTAssertEqual(read.filter { !$0.attachments.isEmpty }.count, n / 10)
        // Every block the BBT lists lies on a 512-byte boundary (the 4 KiB geometry's block alignment).
        XCTAssertTrue(spec.blocks.values.allSatisfy { $0.ib % 512 == 0 }, "block alignment")
    }
}
