//
//  PSTProtectionTests.swift
//  ArchiveCoreTests
//
//  Directive 2026-11-07 §6 "Protected mail/documents", PST protection:
//  bCryptMethod 0 / 1 / 2 written by the spec writer and decoded on read by
//  the production entry points; 0x10 (Windows Information Protection)
//  refused by name; the Outlook password (PidTagPstPassword, a CRC) read in
//  full with the receipt saying so. One test each.
//

import XCTest
import Foundation
@testable import ArchiveCore

final class PSTProtectionTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("pstprot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir); super.tearDown() }

    static let marker = "PSTPROTECTION-BODY-MARKER-20261107"

    static func emails() -> [MBOXParser.RawEmail] {
        (0..<5).map { i in
            let body = "Body \(i): \(marker) " + String(repeating: "filler text to cross one heap allocation ", count: i * 40)
            let att = AttachmentMetadata(filename: "f\(i).bin", mimeType: "application/octet-stream", size: 3_000,
                                         base64: Data((0..<3_000).map { UInt8(truncatingIfNeeded: $0 &+ i) }).base64EncodedString())
            return MBOXParser.RawEmail(headers: ["From": "s\(i)@example.com", "To": "ann@example.org", "Subject": "Crypt subject \(i)",
                                                 "Message-ID": "<crypt\(i)@example.com>", "Date": "Mon, 6 Jan 2025 10:0\(i):00 +0000"],
                                       rawSource: "", messageType: "email", attachments: [att],
                                       timestamp: "2025-01-06T10:0\(i):00Z", domains: ["example.com"], plainBody: body, htmlBody: "")
        }
    }

    func write(_ name: String, cryptMethod: UInt8, passwordCRC: UInt32 = 0) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let w = try PSTSpecWriter(url: url, cryptMethod: cryptMethod, storePasswordCRC: passwordCRC)
        let inbox = w.appendFolder(name: "Inbox")
        for e in Self.emails() { try w.append(email: e, folder: inbox) }
        XCTAssertEqual(try w.finalize(), 5)
        return url
    }

    /// bCryptMethod 0, 1 and 2: the same five messages come back through PSTParser.parse and the
    /// streaming path; the bytes on disk are plain only for 0.
    func testCryptMethods_none_permute_cyclic_areDecodedOnRead() async throws {
        let markerUTF16 = Self.marker.data(using: .utf16LittleEndian)!
        for method: UInt8 in [0, 1, 2] {
            let url = try write("m\(method).pst", cryptMethod: method)
            let bytes = try Data(contentsOf: url)
            XCTAssertEqual(bytes[513], method)
            XCTAssertEqual(PSTProtection.cryptMethod(header: bytes), PSTProtection.CryptMethod(raw: method))
            let plainVisible = bytes.range(of: markerUTF16) != nil
            XCTAssertEqual(plainVisible, method == 0, "method \(method): body text \(plainVisible ? "is" : "is not") readable in the raw bytes")

            let spec = try PSTSpecReader(data: bytes)
            XCTAssertEqual(spec.crypt, method)
            let parsed = try PSTParser.parse(fileURL: url, senderEmail: "")
            XCTAssertEqual(parsed.count, 5, "method \(method)")
            XCTAssertEqual(Set(parsed.map { $0.headers["Subject"] ?? "" }), Set((0..<5).map { "Crypt subject \($0)" }), "method \(method)")
            XCTAssertTrue(parsed.allSatisfy { $0.plainBody.contains(Self.marker) }, "method \(method): bodies decoded")
            XCTAssertEqual(parsed.flatMap(\.attachments).count, 5, "method \(method): attachments decoded")
            var streamed: [MBOXParser.RawEmail] = []
            let result = try await PSTParser.parseStreaming(fileURL: url, senderEmail: "", batchSize: 2) { streamed += $0 }
            XCTAssertEqual(result.count, 5, "method \(method)")
            XCTAssertEqual(streamed.map { $0.headers["Message-ID"] ?? "" }, parsed.map { $0.headers["Message-ID"] ?? "" })

            let report = try XCTUnwrap(PSTProtection.inspect(data: bytes))
            XCTAssertEqual(report.cryptMethod.raw, method)
            XCTAssertFalse(report.isPasswordProtected)
            XCTAssertEqual(report.receiptNote == nil, method == 0)
            if method != 0 { XCTAssertTrue(report.receiptNote!.contains("decoded on read"), report.receiptNote!) }
        }
    }

    /// bCryptMethod 0x10: Windows Information Protection — refused by name by both readers.
    func testWindowsInformationProtection_0x10_isLockedByName() throws {
        let url = try write("wip.pst", cryptMethod: 0)
        var bytes = try Data(contentsOf: url)
        bytes[513] = 0x10
        let locked = dir.appendingPathComponent("wip-locked.pst")
        try bytes.write(to: locked)

        XCTAssertEqual(PSTProtection.cryptMethod(header: bytes), .windowsProtected)
        let report = try XCTUnwrap(PSTProtection.inspect(data: bytes))
        XCTAssertTrue(report.receiptNote?.contains("Windows Information Protection (bCryptMethod 0x10)") == true, report.receiptNote ?? "nil")

        XCTAssertThrowsError(try PSTSpecReader(data: bytes)) { error in
            let text = String(describing: error)
            XCTAssertTrue(text.contains("locked") && text.contains("Windows Information Protection") && text.contains("0x10"), text)
        }
        XCTAssertThrowsError(try PSTParser.parse(fileURL: locked, senderEmail: "")) { error in
            let text = String(describing: error)
            XCTAssertTrue(text.contains("locked") && text.contains("Windows Information Protection") && text.contains("0x10"), text)
            XCTAssertFalse(text.contains("Unsupported PST encryption type"), "the old generic wording is gone")
        }
        // An ANSI header keeps bCryptMethod at offset 461.
        var ansi = Data(count: 564)
        ansi[0] = 0x21; ansi[1] = 0x42; ansi[2] = 0x44; ansi[3] = 0x4E; ansi[10] = 14; ansi[461] = 0x10
        XCTAssertEqual(PSTProtection.cryptMethod(header: ansi), .windowsProtected)
    }

    /// PidTagPstPassword: a CRC Outlook checks, not encryption — the file is read in full and the
    /// import receipt says so.
    func testOutlookPasswordCRC_isNotEncryption_readInFull_receiptSaysSo() async throws {
        let url = try write("pwd.pst", cryptMethod: 1, passwordCRC: 0x1234_ABCD)
        let report = try XCTUnwrap(PSTProtection.inspect(fileURL: url))
        XCTAssertEqual(report.passwordCRC, 0x1234_ABCD)
        XCTAssertTrue(report.isPasswordProtected)
        let note = try XCTUnwrap(report.receiptNote)
        XCTAssertTrue(note.contains("PidTagPstPassword CRC 0x1234ABCD"), note)
        XCTAssertTrue(note.contains("read in full"), note)
        XCTAssertTrue(note.contains("no secret was bypassed"), note)
        XCTAssertTrue(note.contains("compressible encryption"), note)

        // Every message is read without any password.
        let parsed = try PSTParser.parse(fileURL: url, senderEmail: "")
        XCTAssertEqual(parsed.count, 5)
        XCTAssertTrue(parsed.allSatisfy { $0.plainBody.contains(Self.marker) })

        // Through the production importer: the receipt's warnings carry the note.
        let root = dir.appendingPathComponent("archive", isDirectory: true)
        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts", isDirectory: true))
        let coordinator = await BulkImportCoordinator(store: store, fts: fts, checkpoints: ImportCheckpointStore(store: store),
                                                      requiresStorageActivation: false)
        var options = BulkImportCoordinator.Options()
        options.enforceStoragePreflight = false
        let summary = try await coordinator.runImport(urls: [url], options: options)
        XCTAssertEqual(summary.parsed, 5, summary.warnings.description)
        XCTAssertTrue(summary.warnings.contains { $0.hasPrefix("pwd.pst: ") && $0.contains("PidTagPstPassword CRC 0x1234ABCD") && $0.contains("read in full") },
                      summary.warnings.description)
    }
}
