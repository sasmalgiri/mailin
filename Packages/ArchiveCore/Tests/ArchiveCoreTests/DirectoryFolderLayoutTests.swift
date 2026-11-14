//
//  DirectoryFolderLayoutTests.swift
//  ArchiveCoreTests
//
//  Directive 2026-11-07 §6: Maildir++ and nested .eml directory folders are
//  preserved, not flattened. A Maildir++ tree (`.Sent`, `.Archive.2024`, each
//  with cur/new/tmp) maps to the folders `Sent` and `Archive/2024`; a nested
//  directory of .eml files maps each file to its directory path below the
//  root; `cur`, `new` and `tmp` are never folder names; files in `tmp/` are
//  skipped and counted. Before this, every Maildir member landed in the root
//  folder's name and sub-mailboxes were not even found; a nested .eml folder
//  imported only the files at its top level.
//

import XCTest
import Foundation
@testable import ArchiveCore

final class DirectoryFolderLayoutTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("dirlayout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir); super.tearDown() }

    private func write(_ relative: String, subject: String) throws {
        let url = dir.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = "From: a@example.com\r\nTo: b@example.org\r\nSubject: \(subject)\r\nMessage-ID: <\(subject.replacingOccurrences(of: " ", with: "-"))@example.com>\r\nDate: Mon, 6 Jan 2025 10:00:00 +0000\r\n\r\nBody of \(subject).\r\n"
        try Data(text.utf8).write(to: url)
    }
    private func mkdir(_ relative: String) throws {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(relative, isDirectory: true), withIntermediateDirectories: true)
    }

    /// Collects every message a streaming import of `root` hands out, with the report.
    private func importStreaming(_ root: URL) async throws -> (emails: [MBOXParser.RawEmail], report: MBOXParser.ParseRecoveryReport) {
        var emails: [MBOXParser.RawEmail] = []
        let report = try await ParserFactory.parseStreamingCallback(fileURL: root, senderEmail: "", batchSize: 3, materializeAttachments: false) { batch in
            emails += batch
        }
        return (emails, report)
    }

    func testMaildirPlusPlus_subMailboxesKeepTheirFolders_tmpSkippedAndCounted() async throws {
        let root = dir.appendingPathComponent("Maildir", isDirectory: true)
        // Inbox (the root), two Maildir++ sub-mailboxes, one empty sub-mailbox, one Dovecot fs-layout nest.
        try write("Maildir/cur/1.eml:2,S", subject: "inbox one")
        try write("Maildir/new/2.eml", subject: "inbox two")
        try write("Maildir/tmp/3.eml", subject: "inbox delivery in progress")
        try write("Maildir/.Sent/cur/4.eml:2,S", subject: "sent one")
        try mkdir("Maildir/.Sent/new"); try mkdir("Maildir/.Sent/tmp")
        try write("Maildir/.Archive.2024/cur/5.eml:2,S", subject: "archive one")
        try write("Maildir/.Archive.2024/new/6.eml", subject: "archive two")
        try write("Maildir/.Archive.2024/tmp/7.eml", subject: "archive delivery in progress")
        try mkdir("Maildir/.Drafts/cur"); try mkdir("Maildir/.Drafts/new"); try mkdir("Maildir/.Drafts/tmp")
        try write("Maildir/Lists/Swift/cur/8.eml:2,S", subject: "list one")
        try Data("1 V1 N9\n".utf8).write(to: root.appendingPathComponent("dovecot-uidlist"))   // server bookkeeping, not a message

        XCTAssertEqual(SourceFormatClassifier.classify(url: root).format, .maildir)

        // Expansion: every cur/new file of every mailbox, no tmp file, stable order.
        let members = SourceFormatClassifier.expand(root, format: .maildir)
        XCTAssertEqual(members.count, 6, members.map(\.lastPathComponent).description)
        XCTAssertFalse(members.contains { $0.pathComponents.contains("tmp") })

        // Folder paths from the layout: root = the folder's own name; Maildir++ names decoded; nested plain directories kept.
        func folder(_ relative: String) -> String? {
            SourceFormatClassifier.folderPath(member: root.appendingPathComponent(relative), root: root, format: .maildir)
        }
        XCTAssertEqual(folder("cur/1.eml:2,S"), "Maildir")
        XCTAssertEqual(folder("new/2.eml"), "Maildir")
        XCTAssertEqual(folder(".Sent/cur/4.eml:2,S"), "Sent")
        XCTAssertEqual(folder(".Archive.2024/cur/5.eml:2,S"), "Archive/2024")
        XCTAssertEqual(folder(".Archive.2024/new/6.eml"), "Archive/2024")
        XCTAssertEqual(folder("Lists/Swift/cur/8.eml:2,S"), "Lists/Swift")

        // The production streaming path: each message in its folder, per-folder counts, tmp counted as skipped,
        // the empty Drafts mailbox declared (FOLD-02).
        let (emails, report) = try await importStreaming(root)
        XCTAssertEqual(report.totalMessages, 6)
        XCTAssertEqual(emails.count, 6)
        var perFolder: [String: Int] = [:]
        for e in emails { perFolder[e.folderPath ?? "<none>", default: 0] += 1 }
        XCTAssertEqual(perFolder, ["Maildir": 2, "Sent": 1, "Archive/2024": 2, "Lists/Swift": 1])
        XCTAssertEqual(emails.first { $0.headers["Subject"] == "sent one" }?.folderPath, "Sent")
        XCTAssertEqual(emails.first { $0.headers["Subject"] == "archive two" }?.folderPath, "Archive/2024")
        for e in emails {
            for part in (e.folderPath ?? "").split(separator: "/") {
                XCTAssertFalse(["cur", "new", "tmp"].contains(String(part)), "cur/new/tmp leaked into a folder name: \(e.folderPath ?? "")")
            }
        }
        XCTAssertNil(emails.first { $0.headers["Subject"]?.contains("delivery in progress") == true }, "tmp/ files are not messages")
        XCTAssertEqual(report.errorCategories["maildir_tmp_skipped"], 2, "\(report.errorCategories)")
        XCTAssertEqual(Set(report.declaredFolders), ["Maildir", "Sent", "Archive/2024", "Drafts", "Lists/Swift"])

        // The array path stamps the same folders.
        let parsed = try ParserFactory.parse(fileURL: root, senderEmail: "")
        XCTAssertEqual(parsed.count, 6)
        XCTAssertEqual(Set(parsed.compactMap(\.folderPath)), ["Maildir", "Sent", "Archive/2024", "Lists/Swift"])
    }

    func testNestedEMLDirectory_eachFileKeepsItsDirectoryAsFolder() async throws {
        let root = dir.appendingPathComponent("Exported mail", isDirectory: true)
        try write("Exported mail/one.eml", subject: "top one")
        try write("Exported mail/Clients/three.eml", subject: "clients three")
        try write("Exported mail/Clients/Acme/two.eml", subject: "acme two")
        try write("Exported mail/Clients/Acme/four.eml", subject: "acme four")
        try write("Exported mail/.hidden/skip.eml", subject: "hidden")        // hidden entries are not evidence
        try Data("x".utf8).write(to: root.appendingPathComponent("Clients/notes.txt"))

        let classification = SourceFormatClassifier.classify(url: root)
        XCTAssertEqual(classification.format, .emlFolder, classification.summary)

        let members = SourceFormatClassifier.expand(root, format: .emlFolder)
        XCTAssertEqual(members.map(\.lastPathComponent), ["four.eml", "two.eml", "three.eml", "one.eml"], "every .eml below the root, sorted by path")

        func folder(_ relative: String) -> String? {
            SourceFormatClassifier.folderPath(member: root.appendingPathComponent(relative), root: root, format: .emlFolder)
        }
        XCTAssertEqual(folder("one.eml"), "Exported mail")
        XCTAssertEqual(folder("Clients/three.eml"), "Clients")
        XCTAssertEqual(folder("Clients/Acme/two.eml"), "Clients/Acme")

        let (emails, report) = try await importStreaming(root)
        XCTAssertEqual(report.totalMessages, 4)
        var perFolder: [String: Int] = [:]
        for e in emails { perFolder[e.folderPath ?? "<none>", default: 0] += 1 }
        XCTAssertEqual(perFolder, ["Exported mail": 1, "Clients": 1, "Clients/Acme": 2])
        XCTAssertEqual(Set(report.declaredFolders), ["Exported mail", "Clients", "Clients/Acme"])
        XCTAssertNil(report.errorCategories["maildir_tmp_skipped"])

        // A folder whose .eml files are ALL in sub-folders is still an .eml folder.
        let nestedOnly = dir.appendingPathComponent("Nested only", isDirectory: true)
        try write("Nested only/2023/a.eml", subject: "a")
        XCTAssertEqual(SourceFormatClassifier.classify(url: nestedOnly).format, .emlFolder)
        XCTAssertEqual(try ParserFactory.parse(fileURL: nestedOnly, senderEmail: "").compactMap(\.folderPath), ["2023"])
    }
}
