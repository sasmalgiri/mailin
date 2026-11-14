//
//  MailClientHandoffFixtureTests.swift
//  ArchiveCoreTests
//
//  OUT-05 / gate 5: the export a mail client is asked to open is produced by
//  mailin's own export code, from a store mailin imported. Fifteen synthetic
//  messages (no personal data) in two source folders — Unicode subjects
//  (German, Hindi, Japanese), one HTML body, a PDF and an image attachment,
//  a three-message reply thread, distinct Message-IDs — are imported, then
//  exported three ways:
//    mailin-handoff/  exportMBOXPartitions over the whole archive — exactly
//                     what "Export to Apple Mail or Thunderbird…" writes
//    folders/         one exportMBOXArchive per imported folder (FOLD-02 ids)
//    eml/             exportEMLFiles, one .eml per message
//  and an inventory.json (subject, Message-ID, folder, attachment names +
//  SHA-256) is written beside them for the independent parser check and the
//  client import (MAIL_CLIENT_HANDOFF_TESTS.md).
//
//  Set MAILIN_GATE5_OUT to keep the output in a fixed folder for the client
//  run; otherwise it goes to a temporary folder that is removed afterwards.
//

import XCTest
import Foundation
import CryptoKit
@preconcurrency @testable import ArchiveCore

final class MailClientHandoffFixtureTests: XCTestCase {

    struct Attachment: Codable { let name: String; let mime: String; let sha256: String; let bytes: Int }
    struct Entry: Codable {
        let subject: String; let messageID: String; let folder: String
        let html: Bool; let inReplyTo: String?; let attachments: [Attachment]
    }

    private static func hex(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    /// RFC 2047 encoded word for a non-ASCII subject; plain ASCII is left as is.
    private static func encodedSubject(_ s: String) -> String {
        if s.allSatisfy({ $0.isASCII }) { return s }
        return "=?UTF-8?B?\(Data(s.utf8).base64EncodedString())?="
    }

    /// A minimal one-page PDF (valid xref offsets computed, not guessed).
    static func samplePDF() -> Data {
        var objs: [String] = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
        ]
        let stream = "BT /F1 18 Tf 20 50 Td (mailin gate 5) Tj ET"
        objs.append("<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream")
        objs.append("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        var out = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (i, o) in objs.enumerated() {
            offsets.append(out.utf8.count)
            out += "\(i + 1) 0 obj\n\(o)\nendobj\n"
        }
        let xref = out.utf8.count
        out += "xref\n0 \(objs.count + 1)\n0000000000 65535 f \n"
        for o in offsets { out += String(format: "%010d 00000 n \n", o) }
        out += "trailer\n<< /Size \(objs.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(out.utf8)
    }

    /// A 1×1 PNG (red pixel).
    static func samplePNG() -> Data {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!
    }

    private static func raw(subject: String, messageID: String, day: Int, from: String,
                            inReplyTo: String? = nil, references: String? = nil,
                            plain: String, html: String? = nil,
                            parts: [(name: String, mime: String, data: Data)] = []) -> String {
        let date = String(format: "Mon, %02d Sep 2025 10:%02d:00 +0000", day, day)
        var t = "From: \(from)\r\nTo: Test Recipient <recipient@example.invalid>\r\n"
        t += "Subject: \(encodedSubject(subject))\r\nDate: \(date)\r\nMessage-ID: \(messageID)\r\n"
        if let inReplyTo { t += "In-Reply-To: \(inReplyTo)\r\n" }
        if let references { t += "References: \(references)\r\n" }
        t += "MIME-Version: 1.0\r\n"
        func textPart() -> String {
            let plainPart = "Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n\(plain)\r\n"
            guard let html else { return plainPart }
            return "Content-Type: multipart/alternative; boundary=\"ALT-gate5\"\r\n\r\n--ALT-gate5\r\n\(plainPart)"
                + "--ALT-gate5\r\nContent-Type: text/html; charset=utf-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n\(html)\r\n--ALT-gate5--\r\n"
        }
        if parts.isEmpty { return t + textPart() }
        t += "Content-Type: multipart/mixed; boundary=\"MIX-gate5\"\r\n\r\n--MIX-gate5\r\n" + textPart()
        for p in parts {
            t += "--MIX-gate5\r\nContent-Type: \(p.mime); name=\"\(p.name)\"\r\nContent-Transfer-Encoding: base64\r\n"
            t += "Content-Disposition: attachment; filename=\"\(p.name)\"\r\n\r\n"
            t += p.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn]) + "\r\n"
        }
        return t + "--MIX-gate5--\r\n"
    }

    /// The fifteen synthetic messages: (folder, raw, inventory entry).
    static func corpus() -> [(folder: String, raw: String, entry: Entry)] {
        var out: [(String, String, Entry)] = []
        func add(_ folder: String, _ subject: String, _ n: Int, from: String = "Sample Sender <sender@example.invalid>",
                 inReplyTo: String? = nil, references: String? = nil, html: String? = nil,
                 parts: [(name: String, mime: String, data: Data)] = []) {
            let id = "<gate5-\(String(format: "%02d", n))@mailin.example.invalid>"
            let r = raw(subject: subject, messageID: id, day: n, from: from, inReplyTo: inReplyTo, references: references,
                        plain: "Synthetic message \(n) for the mail-client handoff test. Ünïcödé body: äöü – हिन्दी – 日本語.",
                        html: html, parts: parts)
            out.append((folder, r, Entry(subject: subject, messageID: id, folder: folder, html: html != nil, inReplyTo: inReplyTo,
                                         attachments: parts.map { Attachment(name: $0.name, mime: $0.mime, sha256: hex($0.data), bytes: $0.data.count) })))
        }
        let t1 = "<gate5-06@mailin.example.invalid>", t2 = "<gate5-07@mailin.example.invalid>"
        add("Inbox", "Grüße aus München – Übersicht", 1)
        add("Inbox", "नमस्ते: परियोजना की स्थिति", 2)
        add("Inbox", "会議の議事録（第3四半期）", 3)
        add("Inbox", "HTML newsletter sample", 4,
            html: "<html><body><h1>Gate 5</h1><p>This is the <b>HTML</b> body. 日本語 – हिन्दी.</p></body></html>")
        add("Inbox", "Quarterly report (PDF attached)", 5, parts: [("report-q3.pdf", "application/pdf", samplePDF())])
        add("Inbox", "Project kickoff", 6)
        add("Inbox", "Re: Project kickoff", 7, from: "Other Person <other@example.invalid>", inReplyTo: t1, references: t1)
        add("Inbox", "Re: Project kickoff", 8, inReplyTo: t2, references: "\(t1) \(t2)")
        add("Projects", "Photo from the site visit", 9, parts: [("site-photo.png", "image/png", samplePNG())])
        add("Projects", "Straße und Brücke – Planung", 10)
        add("Projects", "बजट अनुमोदन", 11)
        add("Projects", "見積書の確認をお願いします", 12)
        add("Projects", "Plain ASCII status update", 13)
        add("Projects", "Ölpreis-Änderung: Rückmeldung", 14)
        add("Projects", "Final checklist", 15)
        return out.map { (folder: $0.0, raw: $0.1, entry: $0.2) }
    }

    func testGate5_buildsTheClientHandoffExport() async throws {
        let fm = FileManager.default
        let fixed = ProcessInfo.processInfo.environment["MAILIN_GATE5_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let root = fixed ?? fm.temporaryDirectory.appendingPathComponent("gate5-\(UUID().uuidString)", isDirectory: true)
        if fixed != nil { try? fm.removeItem(at: root) }
        defer { if fixed == nil { try? fm.removeItem(at: root) } }
        let work = fm.temporaryDirectory.appendingPathComponent("gate5-work-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)

        // Two source folders = a nested .eml directory (source/Inbox, source/Projects),
        // imported by mailin, which keeps each file's directory as its folder.
        let corpus = Self.corpus()
        XCTAssertEqual(corpus.count, 15)
        XCTAssertEqual(Set(corpus.map(\.entry.messageID)).count, 15, "Message-IDs must be distinct")
        let source = work.appendingPathComponent("source", isDirectory: true)
        for (i, item) in corpus.enumerated() {
            let dir = source.appendingPathComponent(item.folder, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(item.raw.utf8).write(to: dir.appendingPathComponent(String(format: "%02d.eml", i + 1)))
        }
        let sources = [source]
        let store = SQLiteEmailStore(directory: work.appendingPathComponent("store", isDirectory: true))
        let fts = FTSSearchIndex(shardsDirectory: work.appendingPathComponent("fts", isDirectory: true))
        let coordinator = await BulkImportCoordinator(store: store, fts: fts, checkpoints: ImportCheckpointStore(store: store),
                                                      requiresStorageActivation: false)
        var options = BulkImportCoordinator.Options()
        options.enforceStoragePreflight = false
        _ = try await coordinator.runImport(urls: sources, options: options)
        let archive = ArchiveDataService(repository: EmailStoreRepository(store: store, fts: fts))
        let imported = try await archive.count(query: .all)
        XCTAssertEqual(imported, 15, "import")

        let service = await ArchiveExportService(archive: archive)

        // 1. The app's Apple Mail / Thunderbird handoff (MailClientHandoffViews.run).
        let handoff = root.appendingPathComponent("mailin-handoff", isDirectory: true)
        let parts = try await service.exportMBOXPartitions(scope: .query(.all, exclusions: []), toDirectory: handoff, baseName: "mailin-handoff")
        XCTAssertEqual(parts.last?.recordsWritten, 15)

        // 2. One mbox per imported folder (FOLD-02 folder ids).
        let nodes = try await store.folderNodes().filter { $0.messageCount > 0 }
        let byFolder = root.appendingPathComponent("folders", isDirectory: true)
        try fm.createDirectory(at: byFolder, withIntermediateDirectories: true)
        var folderCounts: [String: Int] = [:]
        for node in nodes {
            var q = EmailQuery.all; q.folderID = node.folderID
            let r = try await service.exportMBOXArchive(scope: .query(q, exclusions: []), to: byFolder.appendingPathComponent("\(node.name).mbox"))
            folderCounts[node.name, default: 0] += r.recordsWritten
        }
        XCTAssertEqual(folderCounts.values.reduce(0, +), 15, "folders: \(nodes.map { "\($0.path)=\($0.messageCount)" })")

        // 3. One .eml per message.
        let eml = root.appendingPathComponent("eml", isDirectory: true)
        let e = try await service.exportEMLFiles(scope: .query(.all, exclusions: []), to: eml)
        XCTAssertEqual(e.recordsWritten, 15)

        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(corpus.map(\.entry)).write(to: root.appendingPathComponent("inventory.json"))
        try encoder.encode(folderCounts).write(to: root.appendingPathComponent("folder-counts.json"))
    }
}
