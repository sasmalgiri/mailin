//
//  EMLExportEnvelopeTests.swift
//  ArchiveCoreTests
//
//  Gate 2 (2026-11-18), found on the real Enron corpus: every .eml that "Export as .eml files"
//  wrote began with an mbox envelope line — `From MAILER-DAEMON Thu Jan  1 00:00:00 1970` for a
//  message imported from an .eml / maildir file (the parser's synthetic envelope, kept in the
//  stored raw source), or the source's own `From sender date` line for a message imported from an
//  mbox. That line is mbox container framing, not part of an RFC 5322 message, so the .eml was
//  not the message: 0 of 56,699 exported Enron files equalled their source file. Python's
//  `email` parser hides it (it takes the line as a Unix-from), which is why the gate-5 parser
//  check passed. The .eml now starts with the message's first header line; the mbox export keeps
//  one envelope per record as before.
//

import XCTest
import Foundation
@preconcurrency @testable import ArchiveCore

final class EMLExportEnvelopeTests: XCTestCase {

    private func importAndExportEML(_ files: [(name: String, bytes: Data)]) async throws -> [Data] {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("eml-envelope-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        let source = work.appendingPathComponent("source/inbox", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        for f in files { try f.bytes.write(to: source.appendingPathComponent(f.name)) }
        let store = SQLiteEmailStore(directory: work.appendingPathComponent("store", isDirectory: true))
        let fts = FTSSearchIndex(shardsDirectory: work.appendingPathComponent("fts", isDirectory: true))
        let coordinator = await BulkImportCoordinator(store: store, fts: fts, checkpoints: ImportCheckpointStore(store: store),
                                                      requiresStorageActivation: false)
        var options = BulkImportCoordinator.Options()
        options.enforceStoragePreflight = false
        // An mbox is imported as the file the person picks; message files as their folder.
        let picked = files.count == 1 && files[0].name.hasSuffix(".mbox")
            ? source.appendingPathComponent(files[0].name) : work.appendingPathComponent("source", isDirectory: true)
        _ = try await coordinator.runImport(urls: [picked], options: options)
        let archive = ArchiveDataService(repository: EmailStoreRepository(store: store, fts: fts))
        let service = await ArchiveExportService(archive: archive)
        let out = work.appendingPathComponent("out", isDirectory: true)
        _ = try await service.exportEMLFiles(scope: .query(.all, exclusions: []), to: out)
        return try fm.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "eml" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try Data(contentsOf: $0) }
    }

    func testEMLExport_ofABareMessageFile_startsWithItsFirstHeader_notAnMboxEnvelope() async throws {
        // An Enron-shaped file: CRLF headers, LF body, no envelope (maildir / MH numbered file).
        let text = "Message-ID: <env-1@example.org>\r\nDate: Thu, 21 Jun 2001 09:49:00 -0700 (PDT)\r\n"
            + "From: a@example.org\r\nTo: b@example.org\r\nSubject: Re: CERA\r\nMime-Version: 1.0\r\n"
            + "Content-Type: text/plain; charset=us-ascii\r\nContent-Transfer-Encoding: 7bit\r\n\r\n"
            + "Should we meet?\n\nJennifer\n"
        let out = try await importAndExportEML([("1.", Data(text.utf8))])
        let eml = try XCTUnwrap(out.first)
        let string = String(decoding: eml, as: UTF8.self)
        XCTAssertTrue(string.hasPrefix("Message-ID: <env-1@example.org>\r\n"), "an .eml begins with the message: \(string.prefix(60))")
        XCTAssertFalse(string.contains("MAILER-DAEMON"))
        XCTAssertTrue(string.contains("Should we meet?\n\nJennifer"), "the body is the source's")
    }

    func testEMLExport_ofAnMboxRecord_dropsTheContainersEnvelopeLine() async throws {
        let mbox = "From alice@example.org Thu Jun 21 09:49:00 2001\n"
            + "Message-ID: <env-2@example.org>\nDate: Thu, 21 Jun 2001 09:49:00 -0700\nFrom: alice@example.org\n"
            + "To: b@example.org\nSubject: framed\n\nBody line.\n>From the archive, quoted.\n\n"
        let out = try await importAndExportEML([("box.mbox", Data(mbox.utf8))])
        let string = String(decoding: try XCTUnwrap(out.first), as: UTF8.self)
        XCTAssertTrue(string.hasPrefix("Message-ID: <env-2@example.org>\n"), "no `From alice@…` envelope in an .eml: \(string.prefix(60))")
        XCTAssertTrue(string.contains("\nFrom the archive, quoted."), "the mboxrd quoting was the container's and stays undone")
    }
}

/// Gate 2 (2026-11-18), found on the real Enron corpus: dasovich-j holds messages dated
/// "Wed, 21 Dec 0001 22:30:50 -0800". The previous PST writer (`PSTStreamWriter`, used while
/// `v3PSTSpecWriter` is off) converted that date to a FILETIME with `UInt64(negative)` and the
/// export CRASHED. A date before 1601 (FILETIME's epoch) is now written as FILETIME 0, as the
/// spec writer already does; the message's own Date header travels unchanged in the transport
/// headers.
final class PSTWriterPre1601DateTests: XCTestCase {
    func testStreamWriter_messageDatedYear0001_isWritten_notACrash() throws {
        let raw = "Message-ID: <y1@example.org>\r\nDate: Wed, 21 Dec 0001 22:30:50 -0800 (PST)\r\n"
            + "From: a@example.org\r\nTo: b@example.org\r\nSubject: year one\r\n\r\nBody.\r\n"
        let email = try MBOXParser.processRawMessage(raw, senderEmail: "", materializeAttachments: false)
        XCTAssertFalse(email.timestamp.isEmpty, "the parser keeps the year-0001 date: \(email.timestamp)")
        for spec in [false, true] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("y1-\(UUID().uuidString).pst")
            defer { try? FileManager.default.removeItem(at: url) }
            let was = PSTWriterPolicy.useSpecWriter
            PSTWriterPolicy.useSpecWriter = spec
            defer { PSTWriterPolicy.useSpecWriter = was }
            let writer = try PSTWriterFactory.make(url: url)
            try writer.appendMessage(email)
            XCTAssertEqual(try writer.finalize(), 1, spec ? "spec writer" : "stream writer")
            let back = try PSTParser.parse(fileURL: url, senderEmail: "")
            XCTAssertEqual(back.map { $0.headers["Subject"] ?? "" }, ["year one"], spec ? "spec writer" : "stream writer")
        }
    }
}
