//
//  MIMEAndExportAttachmentTests.swift
//  ArchiveCoreTests
//
//  Review 2026-11-16:
//   B3  an 8-bit body in a legacy charset with NO Content-Transfer-Encoding
//       header (RFC 2045 default) skipped the original-bytes recovery the
//       explicit 7bit/8bit/binary case does: "caf\xE9" in ISO-8859-1 was
//       stored and indexed as "cafÃ©".
//   B12 "Also save attachments" copied only `fileURL`s, which store-loaded
//       attachments never carry: nothing was saved for imported mail and the
//       run still reported success. Bytes now come from AttachmentHydrator
//       and failures are counted ("X of Y").
//

import XCTest
import Foundation
@preconcurrency @testable import ArchiveCore

final class MIMEAndExportAttachmentTests: XCTestCase {

    // MARK: B3

    /// The message text as the readers hand it over when the bytes are not
    /// UTF-8: one character per byte (ISO-8859-1).
    private func latin1Message(headers: String, body: [UInt8]) -> String {
        var bytes = Array(("From: a@example.org\r\nSubject: t\r\nMIME-Version: 1.0\r\n" + headers + "\r\n").utf8)
        bytes += body + Array("\r\n".utf8)
        return String(data: Data(bytes), encoding: .isoLatin1)!
    }

    private let cafe: [UInt8] = [0x63, 0x61, 0x66, 0xE9, 0x20, 0x6F, 0x6C, 0xE9]   // "café olé" in ISO-8859-1

    func testNoTransferEncodingHeader_latin1Body_isReadWithItsCharset() throws {
        let raw = latin1Message(headers: "Content-Type: text/plain; charset=iso-8859-1\r\n", body: cafe)
        let email = try MBOXParser.processRawMessage(raw, senderEmail: "")
        XCTAssertEqual(email.plainBody, "café olé")
    }

    func testUnknownTransferEncoding_latin1Body_isTreatedAsIdentity() throws {
        let raw = latin1Message(headers: "Content-Type: text/plain; charset=iso-8859-1\r\nContent-Transfer-Encoding: x-unheard-of\r\n",
                                body: cafe)
        XCTAssertEqual(try MBOXParser.processRawMessage(raw, senderEmail: "").plainBody, "café olé")
    }

    func testMultipartPartWithoutTransferEncoding_latin1Body_isReadWithItsCharset() throws {
        var body = Array("--B\r\nContent-Type: text/plain; charset=iso-8859-1\r\n\r\n".utf8)
        body += cafe
        body += Array("\r\n--B--".utf8)
        let raw = latin1Message(headers: "Content-Type: multipart/mixed; boundary=\"B\"\r\n", body: body)
        XCTAssertEqual(try MBOXParser.processRawMessage(raw, senderEmail: "").plainBody, "café olé")
    }

    func testNoTransferEncodingHeader_utf8Body_isUnchanged() throws {
        let raw = "From: a@example.org\r\nSubject: t\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nGrüße aus Köln\r\n"
        XCTAssertEqual(try MBOXParser.processRawMessage(raw, senderEmail: "").plainBody, "Grüße aus Köln")
    }

    // MARK: B12

    private let pdfBytes = Data((0..<600).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) })

    private func emailWithAttachment() -> MBOXParser.RawEmail {
        let b64 = pdfBytes.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        let raw = "Message-ID: <att-1@test>\r\nFrom: a@b.com\r\nTo: c@d.com\r\nSubject: With attachment\r\n"
            + "Date: Wed, 01 Jan 2025 10:00:00 +0000\r\nMIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=\"XX\"\r\n\r\n"
            + "--XX\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nSee attached.\r\n"
            + "--XX\r\nContent-Type: application/pdf; name=\"report.pdf\"\r\nContent-Disposition: attachment; filename=\"report.pdf\"\r\n"
            + "Content-Transfer-Encoding: base64\r\n\r\n\(b64)\r\n--XX--\r\n"
        return MBOXParser.RawEmail(
            headers: ["Message-ID": "<att-1@test>", "Subject": "With attachment", "From": "a@b.com", "To": "c@d.com",
                      "Date": "Wed, 01 Jan 2025 10:00:00 +0000"],
            rawSource: raw, messageType: "email",
            attachments: [AttachmentMetadata(filename: "report.pdf", mimeType: "application/pdf", size: pdfBytes.count)],
            timestamp: "", domains: ["b.com"], plainBody: "See attached.", htmlBody: "")
    }

    /// An attachment listed in the record whose bytes are nowhere (no part in
    /// the raw MIME, no file, no payload).
    private func emailWithUnrecoverableAttachment() -> MBOXParser.RawEmail {
        MBOXParser.RawEmail(
            headers: ["Message-ID": "<att-2@test>", "Subject": "Lost", "From": "a@b.com", "To": "c@d.com",
                      "Date": "Thu, 02 Jan 2025 10:00:00 +0000"],
            rawSource: "Message-ID: <att-2@test>\r\nSubject: Lost\r\n\r\nbody\r\n", messageType: "email",
            attachments: [AttachmentMetadata(filename: "missing.bin", mimeType: "application/octet-stream", size: 9)],
            timestamp: "", domains: ["b.com"], plainBody: "body", htmlBody: "")
    }

    @MainActor
    func testSaveAttachments_importedMail_writesHydratedBytes_andCountsWhatCouldNotBeSaved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("att-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts", isDirectory: true))
        try await store.insertBatch([emailWithAttachment(), emailWithUnrecoverableAttachment()], batchSize: 100)
        let archive = ArchiveDataService(repository: EmailStoreRepository(store: store, fts: fts))
        let service = ArchiveExportService(archive: archive)

        // Precondition: the store hands back no fileURL — the case B12 missed.
        var loaded: [MBOXParser.RawEmail] = []
        for try await batch in archive.streamSelected(scope: .query(.all, exclusions: [])) { loaded += batch }
        XCTAssertEqual(loaded.flatMap(\.attachments).count, 2)
        XCTAssertTrue(loaded.flatMap(\.attachments).allSatisfy { $0.fileURL == nil })

        let folder = root.appendingPathComponent("Attachments", isDirectory: true)
        let outcome = try await service.exportAttachments(scope: .query(.all, exclusions: []), to: folder)
        XCTAssertEqual(outcome.saved, 1, "the imported attachment's bytes are recovered and written")
        XCTAssertEqual(outcome.failed, 1, "the unrecoverable one is counted, not skipped silently")
        XCTAssertEqual(outcome.attempted, 2)
        XCTAssertFalse(outcome.capped)
        XCTAssertFalse(outcome.isComplete, "never complete over partial work")
        XCTAssertEqual(outcome.partialSummary?.hasPrefix("Saved 1 of 2 attachments"), true, outcome.partialSummary ?? "nil")
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("report.pdf")), pdfBytes, "byte-exact")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["report.pdf"])

        // A second run into the same folder keeps the first copy and adds one.
        let again = try await service.exportAttachments(scope: .query(.all, exclusions: []), to: folder)
        XCTAssertEqual(again.saved, 1)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(names.count, 2, "\(names)")
        for name in names { XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(name)), pdfBytes) }

        // Only recoverable mail: complete, no summary.
        let onlyGood = try await service.exportAttachments(
            scope: .explicit([loaded.first { $0.headers["Message-ID"] == "<att-1@test>" }!.id]),
            to: root.appendingPathComponent("Good", isDirectory: true))
        XCTAssertEqual(onlyGood, ArchiveExportService.AttachmentExportOutcome(saved: 1, failed: 0, capped: false))
        XCTAssertTrue(onlyGood.isComplete)
        XCTAssertNil(onlyGood.partialSummary)

        // The free-tier cap is still honoured, and says so.
        let capped = try await service.exportAttachments(scope: .query(.all, exclusions: []),
                                                         to: root.appendingPathComponent("Capped", isDirectory: true),
                                                         maxAttachments: 0)
        XCTAssertTrue(capped.capped)
        XCTAssertEqual(capped.saved, 0)
        XCTAssertFalse(capped.isComplete)
    }
}
