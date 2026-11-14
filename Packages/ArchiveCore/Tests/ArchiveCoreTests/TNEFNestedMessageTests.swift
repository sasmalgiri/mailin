//
//  TNEFNestedMessageTests.swift
//  ArchiveCoreTests
//
//  Directive 2026-11-07 §6: a message embedded in a winmail.dat (attAttachment
//  with PR_ATTACH_METHOD = ATTACH_EMBEDDED_MSG and a PtypObject holding
//  IID_IMessage + the embedded message's own TNEF stream, or a winmail.dat
//  attached by value) is expanded into an attached .eml whose own files are
//  reachable, bounded by ExtractionLimits.effective.archiveDepth. Before this
//  the reader listed such an attachment as "not expanded" with no bytes.
//
//  The TNEF byte layout follows the helper in maxmailinTests/V2CutoverTests
//  (`tnef(subject:body:files:)`), extended with embedded messages.
//

import XCTest
import Foundation
@testable import ArchiveCore

final class TNEFNestedMessageTests: XCTestCase {

    /// A TNEF stream: subject, body, an optional sender/date, files by value and
    /// embedded messages (method 5, PtypObject = IID_IMessage + inner TNEF).
    static func tnef(subject: String, body: String, from: (name: String, address: String)? = nil,
                     files: [(name: String, mime: String, data: Data)], embedded: [Data] = [],
                     embeddedWithoutObject: Bool = false) -> Data {
        var out = Data()
        func le16(_ v: UInt16) { out.append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8)]) }
        func le32(_ v: UInt32) { out.append(contentsOf: (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) }) }
        func le16(into d: inout Data, _ v: UInt16) { d.append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8)]) }
        func le32(into d: inout Data, _ v: UInt32) { d.append(contentsOf: (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) }) }
        func attribute(_ level: UInt8, _ id: UInt32, _ payload: Data) {
            out.append(level); le32(id); le32(UInt32(payload.count)); out.append(payload)
            le16(UInt16(payload.reduce(UInt32(0)) { ($0 + UInt32($1)) & 0xFFFF }))
        }
        func cString(_ s: String) -> Data { Data(s.utf8) + Data([0]) }
        func padded(_ d: Data) -> Data { d + Data(repeating: 0, count: (4 - d.count % 4) % 4) }
        le32(TNEFReader.signature); le16(0x1234)
        attribute(1, 0x0001_8004, cString(subject))
        if let from {
            // TRP: trpidOneOff(1), cbgrtrp, cch, cbRgb, name, "SMTP:address".
            var trp = Data(); let name = cString(from.name), addr = cString("SMTP:" + from.address)
            le16(into: &trp, 1); le16(into: &trp, UInt16(8 + name.count + addr.count)); le16(into: &trp, UInt16(name.count)); le16(into: &trp, UInt16(addr.count))
            trp.append(name); trp.append(addr)
            attribute(1, 0x0004_8000, trp)
            // DTR: 2025-03-04 05:06:07, Tuesday.
            var dtr = Data(); for v in [2025, 3, 4, 5, 6, 7, 2] as [UInt16] { le16(into: &dtr, v) }
            attribute(1, 0x0003_8005, dtr)
        }
        attribute(1, 0x0002_800C, cString(body))
        for file in files {
            attribute(2, 0x0006_9002, Data(count: 14))
            attribute(2, 0x0001_8010, cString(file.name))
            attribute(2, 0x0006_800F, file.data)
            var props = Data(); le32(into: &props, 2)
            let unicode = file.name.data(using: .utf16LittleEndian)! + Data([0, 0])
            le32(into: &props, 0x3707_001F); le32(into: &props, 1); le32(into: &props, UInt32(unicode.count)); props.append(padded(unicode))
            let mime = cString(file.mime)
            le32(into: &props, 0x370E_001E); le32(into: &props, 1); le32(into: &props, UInt32(mime.count)); props.append(padded(mime))
            attribute(2, 0x0006_9005, props)
        }
        for inner in embedded {
            attribute(2, 0x0006_9002, Data(count: 14))
            var props = Data(); le32(into: &props, embeddedWithoutObject ? 1 : 2)
            le32(into: &props, 0x3705_0003); le32(into: &props, 5)                        // PR_ATTACH_METHOD = ATTACH_EMBEDDED_MSG
            if !embeddedWithoutObject {
                let object = TNEFReader.iidIMessage + inner                               // PR_ATTACH_DATA_OBJ, PtypObject
                le32(into: &props, 0x3701_000D); le32(into: &props, 1); le32(into: &props, UInt32(object.count)); props.append(padded(object))
            }
            attribute(2, 0x0006_9005, props)
        }
        return out
    }

    static let innerBytes = Data("inner attachment bytes — नमस्ते".utf8)

    static func inner(subject: String = "Inner subject", files: [(name: String, mime: String, data: Data)] = [("inner.txt", "text/plain", innerBytes)],
                      embedded: [Data] = []) -> Data {
        tnef(subject: subject, body: "Inner body text.", from: ("Inner Sender", "inner@example.com"), files: files, embedded: embedded)
    }

    func parse(_ eml: Data) throws -> MBOXParser.RawEmail {
        try MBOXParser.processRawMessage(String(decoding: eml, as: UTF8.self), senderEmail: "", materializeAttachments: false)
    }

    func testEmbeddedMessage_expandedAsAttachedEML_withItsOwnAttachmentReachable() throws {
        let outer = Self.tnef(subject: "Outer", body: "Outer body.", files: [("a.txt", "text/plain", Data("A".utf8))], embedded: [Self.inner()])
        let content = try TNEFReader.read(outer)
        XCTAssertEqual(content.attachments.count, 2)
        XCTAssertEqual(content.attachments[0].filename, "a.txt")
        let nested = content.attachments[1]
        XCTAssertEqual(nested.filename, "Inner subject.eml", "named like MSGParser's embedded messages")
        XCTAssertEqual(nested.mimeType, "message/rfc822")
        XCTAssertTrue(nested.isAttachedMessage)
        XCTAssertFalse(nested.isEmbeddedMessage, "expanded, so no longer 'listed, not expanded'")
        XCTAssertFalse(content.notes.contains { $0.contains("not expanded") }, "\(content.notes)")
        // The rendering parses back as a message: envelope, body, and the inner file with its bytes.
        let email = try parse(nested.data)
        XCTAssertEqual(email.headers["Subject"], "Inner subject")
        XCTAssertEqual(email.headers["From"], "\"Inner Sender\" <inner@example.com>")
        XCTAssertEqual(email.headers["Date"], "Tue, 04 Mar 2025 05:06:07 +0000")
        XCTAssertEqual(email.headers[RFC822Renderer.provenanceHeader], "TNEF embedded message")
        XCTAssertTrue(email.plainBody.contains("Inner body text."), email.plainBody)
        XCTAssertEqual(email.attachments.map(\.filename), ["inner.txt"])
        XCTAssertEqual(AttachmentHydrator.data(for: email.attachments[0], index: 0, email: email), Self.innerBytes)
    }

    func testTwoLevels_expandedWithinTheBaseCeiling_thirdListedNotExpanded() throws {
        // base archiveDepth 3: winmail.dat (0) → embedded (1) → embedded in that (2) expanded; (3) is listed.
        let level3 = Self.inner(subject: "Level 3")
        let level2 = Self.inner(subject: "Level 2", embedded: [level3])
        let level1 = Self.inner(subject: "Level 1", embedded: [level2])
        let outer = Self.tnef(subject: "Outer", body: "Outer body.", files: [], embedded: [level1])
        let content = try TNEFReader.read(outer)
        XCTAssertEqual(content.attachments.map(\.filename), ["Level 1.eml"])
        let one = try parse(content.attachments[0].data)
        // (The MIME pipeline names a message/rfc822 part "attached.eml", as it does for .msg-embedded messages.)
        XCTAssertEqual(one.attachments.count, 2)
        XCTAssertEqual(one.attachments[0].filename, "inner.txt")
        XCTAssertTrue(one.attachments[1].mimeType.hasPrefix("message/rfc822"), one.attachments[1].mimeType)
        let twoData = try XCTUnwrap(AttachmentHydrator.data(for: one.attachments[1], index: 1, email: one))
        let two = try parse(twoData)
        XCTAssertEqual(two.headers["Subject"], "Level 2")
        // Level 3 sits deeper than the ceiling: listed, not expanded — its TNEF stream travels as a
        // winmail.dat (nothing dropped; the next round opens it), and the note says why.
        XCTAssertEqual(two.attachments.map(\.filename), ["inner.txt", "winmail.dat"])
        XCTAssertTrue(two.attachments[1].mimeType.hasPrefix("application/ms-tnef"), two.attachments[1].mimeType)
        let level3Bytes = try XCTUnwrap(AttachmentHydrator.data(for: two.attachments[1], index: 1, email: two))
        XCTAssertTrue(TNEFReader.isTNEF(level3Bytes))
        XCTAssertEqual(try TNEFReader.read(level3Bytes).subject, "Level 3")
        XCTAssertTrue(content.notes.contains { $0.contains("not expanded") && $0.contains("deeper than 3 levels") }, "\(content.notes)")
    }

    func testDepthCeiling_fromExtractionLimits_oneLevelListsNotExpanded_resumeRoundExpands() throws {
        let outer = Self.tnef(subject: "Outer", body: "Outer body.", files: [], embedded: [Self.inner()])
        let tight = ExtractionLimits(partBytes: 1_048_576, totalArchiveBytes: 1_048_576, archiveDepth: 1)
        let listed = try ExtractionLimits.$current.withValue(tight) { try TNEFReader.read(outer) }
        XCTAssertEqual(listed.attachments.count, 1)
        XCTAssertTrue(listed.attachments[0].isEmbeddedMessage)
        XCTAssertFalse(listed.attachments[0].isAttachedMessage)
        XCTAssertTrue(listed.notes.contains { $0.contains("not expanded") && $0.contains("deeper than 1 level") }, "\(listed.notes)")
        // The next Resume round (one more level) opens it.
        let round1 = ExtractionLimits(partBytes: tight.partBytes, totalArchiveBytes: tight.totalArchiveBytes, archiveDepth: tight.archiveDepth + 1)
        let expanded = try ExtractionLimits.$current.withValue(round1) { try TNEFReader.read(outer) }
        XCTAssertEqual(expanded.attachments.map(\.filename), ["Inner subject.eml"])
        XCTAssertTrue(expanded.attachments[0].isAttachedMessage)
    }

    func testNestedWinmailDatByValue_expandedToo_andEmbeddedWithoutObjectStaysListed() throws {
        let byValue = Self.tnef(subject: "Outer", body: "Outer body.",
                                files: [("winmail.dat", "application/ms-tnef", Self.inner(subject: "Forwarded"))])
        let content = try TNEFReader.read(byValue)
        XCTAssertEqual(content.attachments.map(\.filename), ["Forwarded.eml"])
        XCTAssertEqual(content.attachments[0].mimeType, "message/rfc822")
        XCTAssertEqual(try parse(content.attachments[0].data).attachments.map(\.filename), ["inner.txt"])

        let noObject = Self.tnef(subject: "Outer", body: "Outer body.", files: [], embedded: [Data()], embeddedWithoutObject: true)
        let listed = try TNEFReader.read(noObject)
        XCTAssertEqual(listed.attachments.count, 1)
        XCTAssertTrue(listed.attachments[0].isEmbeddedMessage)
        XCTAssertTrue(listed.notes.contains { $0.contains("not expanded") && $0.contains("not a TNEF stream") }, "\(listed.notes)")
    }
}
