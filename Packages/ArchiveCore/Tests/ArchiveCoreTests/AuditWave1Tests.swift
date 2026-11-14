//
//  AuditWave1Tests.swift
//  ArchiveCoreTests
//
//  Regression rows for the 2026-09-28 source audit, Wave 1 items that live in
//  the package: F06 (attachment identity), F07 (quoted-printable bytes),
//  F10 (malformed ZIP64 must throw, never trap).
//

import XCTest
import Foundation
@testable import ArchiveCore

final class AuditWave1Tests: XCTestCase {

    // MARK: F07 — quoted-printable is a byte transform

    func testQuotedPrintable_decodesBinaryBytesUnchanged() {
        let decoded = QuotedPrintableDecoder.decodeBytes(Data("=FF=00=80".utf8))
        XCTAssertEqual([UInt8](decoded), [0xFF, 0x00, 0x80])
    }

    func testQuotedPrintable_roundTripsEveryByteValue() {
        let all = Data((0...255).map { UInt8($0) })
        // Encode strictly: every byte as =XX (legal QP, if verbose), with soft
        // breaks every 19 triplets so line length stays under 76.
        var encoded = ""
        for (i, b) in all.enumerated() {
            encoded += String(format: "=%02X", b)
            if i % 19 == 18 { encoded += "=\r\n" }
        }
        XCTAssertEqual(QuotedPrintableDecoder.decodeBytes(Data(encoded.utf8)), all)
    }

    func testQuotedPrintable_malformedEscapeIsLiteral_softBreaksVanish() {
        XCTAssertEqual(QuotedPrintableDecoder.decodeBytes(Data("a=Zb=\nc=\r\nd=".utf8)),
                       Data("a=Zbcd".utf8))
    }

    func testAttachmentDecode_quotedPrintableIsBytesNotText() throws {
        let out = try XCTUnwrap(AttachmentHydrator.decode(Data("=FF=00=80".utf8), encoding: "Quoted-Printable"))
        XCTAssertEqual([UInt8](out), [0xFF, 0x00, 0x80])
    }

    func testAttachmentDecode_base64StillDecodesWrappedPayload() throws {
        let payload = Data((0..<300).map { UInt8($0 % 251) })
        let wrapped = payload.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        let out = try XCTUnwrap(AttachmentHydrator.decode(Data(wrapped.utf8), encoding: "base64"))
        XCTAssertEqual(out, payload)
    }

    // MARK: F06 — two attachments with one name are two attachments

    private func part(_ name: String?, ordinal: Int) -> PartLocator {
        PartLocator(messageID: UUID(), path: [ordinal], mimeType: "application/pdf", filename: name,
                    contentID: nil, contentTransferEncoding: "base64",
                    contentRange: ByteRange(offset: Int64(ordinal * 1000), length: 500),
                    headerRange: ByteRange(offset: Int64(ordinal * 1000) - 100, length: 100))
    }

    private func meta(_ name: String) -> AttachmentMetadata {
        AttachmentMetadata(filename: name, mimeType: "application/pdf", size: 500)
    }

    func testSelectPart_sameNameTwice_resolvesByOrdinal() {
        let parts = [part("invoice.pdf", ordinal: 0), part("invoice.pdf", ordinal: 1)]
        XCTAssertEqual(AttachmentHydrator.selectPart(for: meta("invoice.pdf"), index: 0, among: parts)?.contentRange.offset, 0)
        XCTAssertEqual(AttachmentHydrator.selectPart(for: meta("invoice.pdf"), index: 1, among: parts)?.contentRange.offset, 1000)
    }

    func testSelectPart_orderDisagrees_uniqueNameWins() {
        // Attachment list says index 0 is "b.pdf", parts list has it second.
        let parts = [part("a.pdf", ordinal: 0), part("b.pdf", ordinal: 1)]
        XCTAssertEqual(AttachmentHydrator.selectPart(for: meta("b.pdf"), index: 0, among: parts)?.contentRange.offset, 1000)
    }

    func testSelectPart_ambiguous_returnsNil() {
        // Two parts share the name, and the ordinal points at a differently named part.
        let parts = [part("x.pdf", ordinal: 0), part("invoice.pdf", ordinal: 1), part("invoice.pdf", ordinal: 2)]
        XCTAssertNil(AttachmentHydrator.selectPart(for: meta("invoice.pdf"), index: 0, among: parts),
                     "not sure must mean don't answer")
        XCTAssertNil(AttachmentHydrator.selectPart(for: meta("missing.pdf"), index: 9, among: parts))
    }

    func testSelectPart_noFilename_usesOrdinal() {
        let parts = [part(nil, ordinal: 0), part(nil, ordinal: 1)]
        XCTAssertEqual(AttachmentHydrator.selectPart(for: meta(""), index: 1, among: parts)?.contentRange.offset, 1000)
    }

    // MARK: F10 — malformed ZIP64 throws instead of trapping

    private func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
    private func le32(_ v: UInt32) -> Data { Data((0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) }) }
    private func le64(_ v: UInt64) -> Data { Data((0..<8).map { UInt8((v >> (8 * $0)) & 0xFF) }) }

    private func scratch(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("audit-zip-\(UUID().uuidString)-\(name)")
    }

    /// EOCD whose counts/sizes are saturated, so the reader consults the
    /// 20-byte ZIP64 locator that precedes it.
    private func saturatedEOCD() -> Data {
        le32(0x0605_4B50) + le16(0) + le16(0) + le16(0xFFFF) + le16(0xFFFF) + le32(0xFFFF_FFFF) + le32(0xFFFF_FFFF) + le16(0)
    }

    private func zip64Record(entries: UInt64, cdSize: UInt64, cdOffset: UInt64) -> Data {
        le32(0x0606_4B50) + le64(44) + le16(45) + le16(45) + le32(0) + le32(0)
            + le64(entries) + le64(entries) + le64(cdSize) + le64(cdOffset)
    }

    private func assertThrowsReadError(_ url: URL, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try ZIPArchiveReader.members(of: url), file: file, line: line) { error in
            XCTAssertTrue(error is ZIPArchiveReader.ReadError, "\(error)", file: file, line: line)
        }
    }

    func testZip64_locatorOffsetAboveInt64Max_throws() throws {
        let url = scratch("locator.zip"); defer { try? FileManager.default.removeItem(at: url) }
        var file = zip64Record(entries: 0, cdSize: 0, cdOffset: 0)
        file += le32(0x0706_4B50) + le32(0) + le64(UInt64.max) + le32(1)   // locator → UInt64.max
        file += saturatedEOCD()
        try file.write(to: url)
        assertThrowsReadError(url)
    }

    func testZip64_centralDirectoryOffsetAboveInt64Max_throws() throws {
        let url = scratch("cdoffset.zip"); defer { try? FileManager.default.removeItem(at: url) }
        var file = zip64Record(entries: 1, cdSize: 46, cdOffset: UInt64.max)
        file += le32(0x0706_4B50) + le32(0) + le64(0) + le32(1)             // locator → record at 0
        file += saturatedEOCD()
        try file.write(to: url)
        assertThrowsReadError(url)
    }

    func testZip64_offsetPlusSizeOverflow_throws() throws {
        let url = scratch("overflow.zip"); defer { try? FileManager.default.removeItem(at: url) }
        var file = zip64Record(entries: 1, cdSize: 1000, cdOffset: UInt64(Int64.max) - 10)
        file += le32(0x0706_4B50) + le32(0) + le64(0) + le32(1)
        file += saturatedEOCD()
        try file.write(to: url)
        assertThrowsReadError(url)
    }

    func testZip64_extraFieldDeclaresMoreThanPresent_throws() throws {
        let url = scratch("extra.zip"); defer { try? FileManager.default.removeItem(at: url) }
        // One central entry with saturated sizes and a ZIP64 extra field whose
        // header claims 24 bytes while only the 4-byte header exists.
        let name = Data("m.mbox".utf8)
        var central = le32(0x0201_4B50) + le16(45) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0)
        central += le32(0)                                   // crc
        central += le32(0xFFFF_FFFF) + le32(0xFFFF_FFFF)     // csize, usize saturated
        central += le16(UInt16(name.count)) + le16(4) + le16(0)   // extra length 4 = header only
        central += le16(0) + le16(0) + le32(0)
        central += le32(0xFFFF_FFFF)                          // offset saturated
        central += name + le16(0x0001) + le16(24)             // the lying extra header
        var file = central
        file += le32(0x0605_4B50) + le16(0) + le16(0) + le16(1) + le16(1)
        file += le32(UInt32(central.count)) + le32(0) + le16(0)
        try file.write(to: url)
        assertThrowsReadError(url)
    }

    func testZip64_wellFormedStillParses() throws {
        // Sanity: the checked arithmetic must not reject a legal ZIP64 shape.
        let url = scratch("ok.zip"); defer { try? FileManager.default.removeItem(at: url) }
        let name = Data("m.mbox".utf8)
        let payload = Data("From a@b Thu Mar 16 11:00:00 2017\nSubject: x\n\nhi\n".utf8)
        var file = le32(0x0403_4B50) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0)
        let crc = ZIPArchiveReader.CRC32.checksum(payload)
        file += le32(crc) + le32(UInt32(payload.count)) + le32(UInt32(payload.count)) + le16(UInt16(name.count)) + le16(0)
        file += name + payload
        let cdOffset = UInt64(file.count)
        var central = le32(0x0201_4B50) + le16(45) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0)
        central += le32(crc) + le32(0xFFFF_FFFF) + le32(0xFFFF_FFFF)
        let extra = le16(0x0001) + le16(24) + le64(UInt64(payload.count)) + le64(UInt64(payload.count)) + le64(0)
        central += le16(UInt16(name.count)) + le16(UInt16(extra.count)) + le16(0) + le16(0) + le16(0) + le32(0) + le32(0xFFFF_FFFF)
        central += name + extra
        file += central
        let recordOffset = UInt64(file.count)
        file += zip64Record(entries: 1, cdSize: UInt64(central.count), cdOffset: cdOffset)
        file += le32(0x0706_4B50) + le32(0) + le64(recordOffset) + le32(1)
        file += saturatedEOCD()
        try file.write(to: url)
        let members = try ZIPArchiveReader.members(of: url)
        XCTAssertEqual(members.count, 1)
        XCTAssertEqual(members[0].uncompressedSize, Int64(payload.count))
        XCTAssertEqual(members[0].localHeaderOffset, 0)
    }
}
