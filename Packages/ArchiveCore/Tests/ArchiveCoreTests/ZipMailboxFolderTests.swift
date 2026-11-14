//
//  ZipMailboxFolderTests.swift
//  ArchiveCoreTests
//
//  IPAD-01 (gate 1 walk 2026-11-08, F-2): a ZIP of an Apple Mail export
//  imported with no folders — 51 of 51 messages, but 0 folders and 0
//  memberships. Container members were extracted one at a time to a flat
//  scratch file, so the mailbox path inside the ZIP ("Work.mbox/Clients.mbox/
//  mbox") was lost; Info.plist / an empty `mbox` were dropped as "not mail",
//  so the empty mailbox was never declared either. The unzipped export folder
//  (a folder of .mbox packages) was not even recognised as a source, and a
//  package holding a nested mailbox read only its own `mbox`.
//
//  These tests build the export at test time and import it through the
//  production seam (`BulkImportCoordinator.runImport`, "Keep every copy"), as
//  a ZIP of the contents, as a Finder-style ZIP of the folder, with the
//  plain-directory variant (Work/Clients.mbox), and as the unzipped folder —
//  all four must give the same folders and memberships.
//

import XCTest
import Foundation
@preconcurrency @testable import ArchiveCore

final class ZipMailboxFolderTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("zipfolders-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir); super.tearDown() }

    private static func mbox(_ subjects: [String], tag: String) -> Data {
        var out = ""
        for (i, s) in subjects.enumerated() {
            out += "From sender@example.com Mon Jan  6 10:00:00 2025\n"
            out += "From: sender@example.com\nTo: me@example.org\nSubject: \(s)\n"
            out += "Message-ID: <\(tag)-\(i)@example.com>\nDate: Mon, 6 Jan 2025 10:0\(i % 10):00 +0000\n\nBody of \(s).\n\n"
        }
        return Data(out.utf8)
    }

    /// An Apple Mail "Export Mailbox…" folder: each mailbox a package with
    /// `mbox`, `Info.plist`, `table_of_contents`; Clients nested in Work
    /// (inside the Work package, or — `plainParent` — in a plain Work folder);
    /// "Archive 2019" exported empty. Inbox 4, Work 3, Work/Clients 2.
    private func makeExport(named name: String, plainParent: Bool) throws -> URL {
        let fm = FileManager.default
        let root = dir.appendingPathComponent(name, isDirectory: true)
        func package(_ relative: String, _ subjects: [String], tag: String) throws {
            let p = root.appendingPathComponent(relative, isDirectory: true)
            try fm.createDirectory(at: p, withIntermediateDirectories: true)
            try Self.mbox(subjects, tag: tag).write(to: p.appendingPathComponent("mbox"))
            try Data("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict/></plist>\n".utf8).write(to: p.appendingPathComponent("Info.plist"))
            try Data([0, 1, 2, 3]).write(to: p.appendingPathComponent("table_of_contents"))
        }
        try package("Inbox.mbox", ["Inbox 1", "Inbox 2", "Inbox 3", "Inbox 4"], tag: "inbox")
        if plainParent {
            try fm.createDirectory(at: root.appendingPathComponent("Work", isDirectory: true), withIntermediateDirectories: true)
            try package("Work.mbox", ["Work 1", "Work 2", "Work 3"], tag: "work")
            try package("Work/Clients.mbox", ["Clients 1", "Clients 2"], tag: "clients")
        } else {
            try package("Work.mbox", ["Work 1", "Work 2", "Work 3"], tag: "work")
            try package("Work.mbox/Clients.mbox", ["Clients 1", "Clients 2"], tag: "clients")
        }
        try package("Archive 2019.mbox", [], tag: "empty")
        return root
    }

    private func zip(_ items: [String], in cwd: URL, to name: String) throws -> URL {
        let tool = URL(fileURLWithPath: "/usr/bin/zip")
        guard FileManager.default.isExecutableFile(atPath: tool.path) else { throw XCTSkip("/usr/bin/zip is not available") }
        let out = dir.appendingPathComponent(name)
        let process = Process()
        process.executableURL = tool
        process.currentDirectoryURL = cwd
        process.arguments = ["-q", "-r", out.path] + items
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return out
    }

    private struct Imported {
        var total = 0
        var folders: [String: Int] = [:]      // path → messages directly in it
        var declared: Set<String> = []
        var memberships = 0
    }

    /// The production seam the app uses for any picked source (ZIP or folder), "Keep every copy".
    private func importThroughCoordinator(_ source: URL, offsetEngine: Bool = false) async throws -> Imported {
        let work = dir.appendingPathComponent("store-\(UUID().uuidString)", isDirectory: true)
        let store = SQLiteEmailStore(directory: work.appendingPathComponent("store", isDirectory: true))
        let fts = FTSSearchIndex(shardsDirectory: work.appendingPathComponent("fts", isDirectory: true))
        let coordinator = await BulkImportCoordinator(store: store, fts: fts, checkpoints: ImportCheckpointStore(store: store),
                                                      requiresStorageActivation: false)
        var options = BulkImportCoordinator.Options()
        options.enforceStoragePreflight = false
        options.dedupPolicy = .preserveAll
        options.useOffsetEngine = offsetEngine   // the app's offset-parser capability; ZIPs and folders bypass it
        _ = try await coordinator.runImport(urls: [source], options: options)
        let archive = ArchiveDataService(repository: EmailStoreRepository(store: store, fts: fts))
        var out = Imported()
        out.total = try await archive.count(query: .all)
        for node in try await store.folderNodes() {
            out.folders[node.path] = node.messageCount
            if node.declared { out.declared.insert(node.path) }
            out.memberships += node.messageCount
        }
        return out
    }

    private let expectedFolders: [String: Int] = ["Inbox": 4, "Work": 3, "Work/Clients": 2, "Archive 2019": 0]

    private func assertExportFolders(_ got: Imported, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(got.total, 9, "\(label): every message", file: file, line: line)
        XCTAssertEqual(got.folders, expectedFolders, "\(label): folders and their counts", file: file, line: line)
        XCTAssertEqual(got.memberships, 9, "\(label): one membership per message", file: file, line: line)
        XCTAssertTrue(got.declared.isSuperset(of: ["Inbox", "Work/Clients", "Archive 2019"]),
                      "\(label): the empty mailbox is declared: \(got.declared)", file: file, line: line)
    }

    func testIPAD01_zipOfAppleMailExport_keepsMailboxFolders_nestedAndEmpty() async throws {
        let root = try makeExport(named: "MailExport", plainParent: false)
        // A ZIP of the export's contents (Inbox.mbox/…, Work.mbox/Clients.mbox/…, Archive 2019.mbox/…).
        let contents = try zip(["Inbox.mbox", "Work.mbox", "Archive 2019.mbox"], in: root, to: "contents.zip")
        assertExportFolders(try await importThroughCoordinator(contents), "ZIP of the contents")

        // Finder's Compress: one wrapper folder around everything; the wrapper is not a mailbox.
        let finder = try zip(["MailExport"], in: dir, to: "MailExport.zip")
        assertExportFolders(try await importThroughCoordinator(finder), "Finder-style ZIP")

        // The unzipped folder, picked directly, gives the same folders.
        XCTAssertEqual(SourceFormatClassifier.classify(url: root).format, .appleMailMailbox,
                       "a folder of exported .mbox packages is an Apple Mail export")
        assertExportFolders(try await importThroughCoordinator(root), "unzipped folder")

        // The same with the offset engine on (the app's default in 3.0).
        assertExportFolders(try await importThroughCoordinator(finder, offsetEngine: true), "Finder-style ZIP, offset engine on")
        assertExportFolders(try await importThroughCoordinator(root, offsetEngine: true), "unzipped folder, offset engine on")
    }

    func testIPAD01_plainParentDirectory_variant_zipAndFolderAgree() async throws {
        let root = try makeExport(named: "PlainExport", plainParent: true)
        let finder = try zip(["PlainExport"], in: dir, to: "PlainExport.zip")
        assertExportFolders(try await importThroughCoordinator(finder), "plain Work/Clients.mbox in a ZIP")
        assertExportFolders(try await importThroughCoordinator(root), "plain Work/Clients.mbox as a folder")
    }

    func testIPAD01_singlePackageWithNestedMailbox_importsBoth() async throws {
        // A Work.mbox package picked on its own: its own mbox AND the nested Clients.mbox.
        _ = try makeExport(named: "One", plainParent: false)
        let work = dir.appendingPathComponent("One/Work.mbox", isDirectory: true)
        let got = try await importThroughCoordinator(work)
        XCTAssertEqual(got.total, 5)
        XCTAssertEqual(got.folders, ["Work": 3, "Work/Clients": 2])
        let zipped = try zip(["Work.mbox"], in: dir.appendingPathComponent("One", isDirectory: true), to: "work.zip")
        let viaZip = try await importThroughCoordinator(zipped)
        XCTAssertEqual(viaZip.total, 5)
        XCTAssertEqual(viaZip.folders, ["Work": 3, "Work/Clients": 2])
    }

    func testIPAD01_containerFolderPath_rules() {
        func f(_ name: String, wrapper: String? = nil) -> String? {
            SourceFormatClassifier.containerFolderPath(memberName: name, wrapper: wrapper)
        }
        XCTAssertEqual(f("Inbox.mbox/mbox"), "Inbox")
        XCTAssertEqual(f("Work.mbox/Clients.mbox/mbox"), "Work/Clients")
        XCTAssertEqual(f("Work/Clients.mbox/mbox"), "Work/Clients")
        XCTAssertEqual(f("MailExport/Work.mbox/Clients.mbox/mbox", wrapper: "MailExport"), "Work/Clients")
        XCTAssertEqual(f("Work.mbox/0A1B/Data/1/Messages/7.emlx"), "Work", "inside a package only .mbox names are folders")
        XCTAssertEqual(f("Exported/Clients/Acme/two.eml", wrapper: "Exported"), "Clients/Acme")
        XCTAssertEqual(f("Exported/one.eml", wrapper: "Exported"), "Exported", "as the unzipped .eml folder names its root")
        XCTAssertEqual(f("Maildir/.Archive.2024/cur/5.eml:2,S", wrapper: "Maildir"), "Archive/2024")
        XCTAssertEqual(f("Maildir/cur/1.eml:2,S", wrapper: "Maildir"), "Maildir")
        // Unchanged: flat members and stand-alone mailbox files carry no folder (Takeout keeps its labels).
        XCTAssertNil(f("one.eml"))
        XCTAssertNil(f("Takeout/Mail/All mail Including Spam and Trash.mbox", wrapper: "Takeout"))
        XCTAssertNil(f("backup/archive.pst"))
    }
}
