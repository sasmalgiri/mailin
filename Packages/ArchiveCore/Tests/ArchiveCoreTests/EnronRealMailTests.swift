//
//  EnronRealMailTests.swift
//  ArchiveCoreTests
//
//  Gate 2 (owner 2026-11-15: "no 4.0.1 — do them in 4.0"): real mail at the five-jobs size.
//  One Enron custodian (CMU release enron_mail_20150507, kaminski-v: 28,465 real messages,
//  129 MB, 46 folders) imported through the app's streaming import path, reconciled against an
//  independent walk of the files: every message once, every folder with its own count, no
//  failures, memory bounded. Opt-in: MAILIN_ENRON_DIR=<.../maildir/kaminski-v>.
//

import XCTest
import Foundation
@testable import ArchiveCore

final class EnronRealMailTests: XCTestCase {
    private func enronDir() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["MAILIN_ENRON_DIR"], !path.isEmpty else {
            throw XCTSkip("set MAILIN_ENRON_DIR to an Enron custodian maildir (e.g. kaminski-v)")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The independent inventory: every regular, non-hidden file below the root, by its folder.
    private func inventory(_ root: URL) -> [String: Int] {
        var perFolder: [String: Int] = [:]
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [:] }
        for case let url as URL in e where (try? url.resourceValues(forKeys: Set(keys)).isRegularFile) == true {
            let relative = url.deletingLastPathComponent().path.replacingOccurrences(of: root.path, with: "")
            perFolder[relative.trimmingCharacters(in: CharacterSet(charactersIn: "/")), default: 0] += 1
        }
        return perFolder
    }

    func testEnronCustodian_asTheFilesAre_classifiedAndImportedOnce_everyFolderReconciled() async throws {
        let root = try enronDir()
        let expected = inventory(root)
        let expectedTotal = expected.values.reduce(0, +)
        print("ENRON: \(expectedTotal) files in \(expected.count) folders")
        XCTAssertGreaterThan(expectedTotal, 20_000)

        let classification = SourceFormatClassifier.classify(url: root)
        print("ENRON: classified as \(classification.format) — \(classification.summary)")

        let baseline = CarverScaleTests.footprint()
        var peak = baseline
        var perFolder: [String: Int] = [:]
        var messageIDs = Set<String>(), duplicateIDs = 0, emptyBodies = 0, imported = 0
        let started = Date()
        let report = try await ParserFactory.parseStreamingCallback(fileURL: root, senderEmail: "", batchSize: 500,
                                                                    materializeAttachments: false) { batch in
            for email in batch {
                imported += 1
                perFolder[email.folderPath ?? "<none>", default: 0] += 1
                let id = email.headers["Message-ID"] ?? ""
                if !id.isEmpty, !messageIDs.insert(id).inserted { duplicateIDs += 1 }
                if email.plainBody.isEmpty && email.htmlBody.isEmpty { emptyBodies += 1 }
            }
            peak = max(peak, CarverScaleTests.footprint())
        }
        let seconds = Date().timeIntervalSince(started)
        print("ENRON: imported \(imported) (report \(report.successfullyParsed) ok, \(report.failed) failed, categories \(report.errorCategories)) in "
              + String(format: "%.1f s", seconds) + "; \(messageIDs.count) distinct Message-IDs, \(duplicateIDs) repeated; "
              + "\(emptyBodies) with no body; \(perFolder.count) folders; peak footprint growth \((peak - min(peak, baseline)) / 1_048_576) MB")

        XCTAssertEqual(imported, expectedTotal, "every file is one message, none lost, none doubled")
        XCTAssertEqual(report.failed, 0)
        // Folders: the same names and the same counts as the files on disk (the import names a
        // folder by its path below the chosen root; the root's own files by the root's name).
        let rootName = root.lastPathComponent
        let normalised = Dictionary(expected.map { ($0.key.isEmpty ? rootName : $0.key, $0.value) }, uniquingKeysWith: +)
        XCTAssertEqual(perFolder, normalised, "every folder with exactly its own messages")
        XCTAssertLessThan(peak - min(peak, baseline), 400 * 1_048_576, "memory follows the batch, not the 129 MB mailbox")
    }
}

/// Always runs: the defect gate 2 found. A bare message whose body quotes an mbox-style
/// "From addr date" line (a forwarded message) is one message, not two.
final class BareMessageEnvelopeLineTests: XCTestCase {
    func testBareMessage_bodyLineShapedLikeAnEnvelope_staysOneMessage() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = "Message-ID: <bare-1@example.org>\r\nDate: Thu, 7 Dec 2000 22:25:37 -0800\r\nFrom: a@example.org\r\n"
            + "To: b@example.org\r\nSubject: Fwd: notes\r\n\r\nSee below.\r\n\r\n"
            + "From tduggan@ieee.org Thu Dec 7 22:25:37 2000\r\nReturn-Path: <tduggan@ieee.org>\r\nSubject: inner\r\n\r\nInner text.\r\n"
        let file = dir.appendingPathComponent("1.eml")
        try text.write(to: file, atomically: true, encoding: .utf8)

        var emails: [MBOXParser.RawEmail] = []
        _ = try await ParserFactory.parseStreamingCallback(fileURL: file, senderEmail: "", batchSize: 50,
                                                           materializeAttachments: false) { emails.append(contentsOf: $0) }
        XCTAssertEqual(emails.count, 1, "the quoted envelope line is body text")
        XCTAssertTrue(emails.first?.plainBody.contains("Inner text.") == true)
    }

    /// MH / Enron-style folders: files named "1", "2." … that start with mail headers are messages;
    /// a numbered file that is not mail is left out. CRLF files are recognised as well.
    func testNumberedMessageFiles_mhFolderIsRead_strayNumberedFileIgnored() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mh-\(UUID().uuidString)", isDirectory: true)
        let inbox = dir.appendingPathComponent("inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (name, eol) in [("1", "\n"), ("2.", "\r\n")] {
            let text = ["Message-ID: <mh-\(name)@example.org>", "Date: Thu, 7 Dec 2000 22:25:37 -0800", "From: a@example.org",
                        "Subject: message \(name)", "", "Body \(name)", ""].joined(separator: eol)
            try text.write(to: inbox.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try "3 apples\n4 pears\n".write(to: inbox.appendingPathComponent("3"), atomically: true, encoding: .utf8)

        XCTAssertEqual(SourceFormatClassifier.classify(url: dir).format, .emlFolder)
        var emails: [MBOXParser.RawEmail] = []
        _ = try await ParserFactory.parseStreamingCallback(fileURL: dir, senderEmail: "", batchSize: 50,
                                                           materializeAttachments: false) { emails.append(contentsOf: $0) }
        XCTAssertEqual(emails.compactMap { $0.headers["Subject"] }.sorted(), ["message 1", "message 2."])
    }
}
