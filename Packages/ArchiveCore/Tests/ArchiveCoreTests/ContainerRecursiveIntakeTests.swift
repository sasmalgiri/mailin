//
//  ContainerRecursiveIntakeTests.swift
//  ArchiveCoreTests
//
//  CLOSE-02 (v4.0 plan §8.1): a mailbox inside an archive inside an archive
//  used to be skipped and counted ("one archive level"). These tests build
//  the nested sources at test time and import them through the production
//  seam (`BulkImportCoordinator.runImport`), checking each against an oracle
//  written beside it: the exact Message-ID set, the folder of every message,
//  the counted refusals with their reasons, and — interrupted at a member
//  boundary in-process and SIGKILLed in a separate writer process — a resume
//  that imports exactly the remaining messages, none twice.
//

import XCTest
import Foundation
import SQLite3
@preconcurrency @testable import ArchiveCore

final class ContainerRecursiveIntakeTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("close02-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ImportCheckpointStore.legacyJSONURLOverride = dir.appendingPathComponent("no-legacy-checkpoints.json")
    }

    override func tearDown() {
        ContainerMailboxWalk.extractionObserver = nil
        ImportCheckpointStore.legacyJSONURLOverride = nil
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    // MARK: - Fixtures

    /// `count` messages with Message-IDs `<tag-i@close02.test>`; returns the bytes and the IDs.
    static func mbox(_ tag: String, _ count: Int, bodyBytes: Int = 0) -> (data: Data, ids: Set<String>) {
        var text = "", ids = Set<String>()
        let filler = bodyBytes > 0 ? String(repeating: "Every message once, whatever happens to the writer. ", count: bodyBytes / 52 + 1) : ""
        for i in 0..<count {
            let id = "\(tag)-\(i)@close02.test"
            ids.insert(id)
            let day = String(format: "%02d", i % 28 + 1), minute = String(format: "%02d", i % 60)
            text += "From sender@close02.test Mon Jan  6 10:00:00 2025\nFrom: Sender <sender@close02.test>\nTo: me@close02.test\n"
            text += "Subject: \(tag) \(i)\nDate: Mon, \(day) Jan 2025 10:\(minute):00 +0000\nMessage-ID: <\(id)>\n\nBody of \(tag) \(i).\n\(filler)\n\n"
        }
        return (Data(text.utf8), ids)
    }

    static func eml(_ id: String) -> Data {
        Data("From: Sender <sender@close02.test>\r\nTo: me@close02.test\r\nSubject: \(id)\r\nDate: Mon, 6 Jan 2025 10:00:00 +0000\r\nMessage-ID: <\(id)@close02.test>\r\n\r\nBody of \(id).\r\n".utf8)
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String], in cwd: URL? = nil, stdout: URL? = nil) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        var env = ProcessInfo.processInfo.environment
        env["COPYFILE_DISABLE"] = "1"   // no AppleDouble ._ members from bsdtar
        p.environment = env
        if let stdout {
            FileManager.default.createFile(atPath: stdout.path, contents: nil)
            p.standardOutput = try FileHandle(forWritingTo: stdout)
        } else {
            p.standardOutput = FileHandle.nullDevice
        }
        p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        return p.terminationStatus
    }

    // MARK: - Importing through the production seam

    struct Imported {
        var summary: BulkImportCoordinator.RunSummary
        /// normalized Message-ID → folder paths (empty when in no folder)
        var folders: [String: Set<String>]
        var rows: Int
        var ids: Set<String> { Set(folders.keys) }
    }

    @MainActor
    private func importSource(_ source: URL, root: URL? = nil, batchSize: Int = 500,
                              onCommitted: ((Int, BulkImportCoordinator) -> Void)? = nil) async throws -> Imported {
        let root = root ?? dir.appendingPathComponent("archive-\(UUID().uuidString)", isDirectory: true)
        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts", isDirectory: true))
        let coordinator = BulkImportCoordinator(store: store, fts: fts, checkpoints: ImportCheckpointStore(store: store),
                                                requiresStorageActivation: false)
        var options = BulkImportCoordinator.Options()
        options.enforceStoragePreflight = false
        options.adaptiveBatching = false
        options.batchSize = batchSize
        options.dedupPolicy = .preserveAll
        var callbacks = BulkImportCoordinator.Callbacks()
        var committed = 0
        callbacks.onCommittedBatch = { batch in
            committed += batch.count
            onCommitted?(committed, coordinator)
        }
        let summary = try await coordinator.runImport(urls: [source], options: options, callbacks: callbacks)
        let facts = try Self.storeFacts(root)
        return Imported(summary: summary, folders: facts.folders, rows: facts.rows)
    }

    static func normalized(_ id: String) -> String { id.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n")) }

    static func storeFacts(_ root: URL) throws -> (rows: Int, folders: [String: Set<String>]) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(root.appendingPathComponent("store/emails.db").path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw NSError(domain: "close02", code: 1)
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        var rows = 0
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM emails;", -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW {
            rows = Int(sqlite3_column_int64(stmt, 0))
        }
        sqlite3_finalize(stmt)
        var out: [String: Set<String>] = [:]
        let sql = "SELECT e.message_id, f.path FROM emails e LEFT JOIN email_folders ef ON ef.email_id = e.id LEFT JOIN folders f ON f.folder_id = ef.folder_id;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw NSError(domain: "close02", code: 2) }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_text(stmt, 0).map { normalized(String(cString: $0)) } ?? ""
            var set = out[id] ?? []
            if let path = sqlite3_column_text(stmt, 1) { set.insert(String(cString: path)) }
            out[id] = set
        }
        return (rows, out)
    }

    /// Asserts every oracle ID is in exactly the folder the oracle names ("" = no folder).
    private func assertFolders(_ got: Imported, _ oracle: [String: (ids: Set<String>, folder: String)],
                               file: StaticString = #filePath, line: UInt = #line) {
        let all = oracle.values.reduce(Set<String>()) { $0.union($1.ids) }
        XCTAssertEqual(got.ids, all, "exact Message-ID set", file: file, line: line)
        XCTAssertEqual(got.rows, all.count, "one row per message, none twice", file: file, line: line)
        for (label, entry) in oracle {
            for id in entry.ids {
                XCTAssertEqual(got.folders[id] ?? ["<missing>"], entry.folder.isEmpty ? [] : [entry.folder],
                               "\(label): \(id) is in \(entry.folder.isEmpty ? "no folder" : entry.folder)", file: file, line: line)
            }
        }
    }

    private func report(_ url: URL) async throws -> MBOXParser.ParseRecoveryReport {
        try await ParserFactory.parseStreamingCallback(fileURL: url, senderEmail: "", batchSize: 7, materializeAttachments: false) { _ in }
    }

    // MARK: - ZIP → ZIP → (ZIP →) MBOX, folders from every level

    func testZipInZipInZip_everyLevelImported_withFoldersFromEveryLevel() async throws {
        let top = Self.mbox("top", 2), inbox = Self.mbox("inbox", 3), flat = Self.mbox("flat", 2), deep = Self.mbox("deep", 2)
        let deepest = dir.appendingPathComponent("deepest.zip")
        try StoredZip.write([.file("Archive.mbox/mbox", deep.data)], to: deepest)
        let inner = dir.appendingPathComponent("inner.zip")
        try StoredZip.write([
            .directory("Mail/"), .directory("Mail/Inbox.mbox/"),
            .file("Mail/Inbox.mbox/mbox", inbox.data),
            .file("Mail/Inbox.mbox/Info.plist", Data("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict/></plist>\n".utf8)),
            .directory("Mail/Empty.mbox/"),
            .file("flat.mbox", flat.data),
            .file("deeper/deepest.zip", try Data(contentsOf: deepest)),
        ], to: inner)
        let outer = dir.appendingPathComponent("outer.zip")
        try StoredZip.write([
            .file("top.mbox", top.data),
            .file("Backups/2019/inner.zip", try Data(contentsOf: inner)),
        ], to: outer)

        let r = try await report(outer)
        XCTAssertEqual(r.totalMessages, 9)
        XCTAssertNil(r.errorCategories["container_nested_skipped"], "no level is skipped any more")
        XCTAssertEqual(r.errorCategories["container_member_not_mail"], 1, "Info.plist")
        XCTAssertTrue(Set(r.declaredFolders).isSuperset(of: ["Backups/2019/Mail/Inbox", "Backups/2019/Mail/Empty", "Backups/2019/deeper/Archive"]),
                      "\(r.declaredFolders)")

        let got = try await importSource(outer)
        assertFolders(got, [
            "top.mbox (level 1, stand-alone mailbox)": (top.ids, ""),
            "Mail/Inbox.mbox in inner.zip": (inbox.ids, "Backups/2019/Mail/Inbox"),
            "flat.mbox in inner.zip (stand-alone mailbox)": (flat.ids, ""),
            "Archive.mbox in deepest.zip in inner.zip": (deep.ids, "Backups/2019/deeper/Archive"),
        ])
        XCTAssertTrue(got.summary.fileErrors.isEmpty, "\(got.summary.fileErrors)")

        // The array path agrees.
        let array = try ParserFactory.parse(fileURL: outer, senderEmail: "")
        XCTAssertEqual(Set(array.compactMap { $0.headers["Message-ID"].map(Self.normalized) }), got.ids)
    }

    // MARK: - ZIP → TGZ → Maildir (real bsdtar + gzip output)

    func testZipHoldingTgzOfMaildir_foldersFromTheMaildirLayoutUnderTheZipFolder() async throws {
        let tree = dir.appendingPathComponent("tree", isDirectory: true)
        let fm = FileManager.default
        for sub in ["Maildir/cur", "Maildir/new", "Maildir/tmp", "Maildir/.Sent/cur", "Maildir/.Archive.2024/cur"] {
            try fm.createDirectory(at: tree.appendingPathComponent(sub, isDirectory: true), withIntermediateDirectories: true)
        }
        try Self.eml("md-inbox-1").write(to: tree.appendingPathComponent("Maildir/cur/1700000001.M1P1.host:2,S"))
        try Self.eml("md-inbox-2").write(to: tree.appendingPathComponent("Maildir/cur/1700000002.M2P2.host:2,S"))
        try Self.eml("md-inbox-3").write(to: tree.appendingPathComponent("Maildir/new/1700000003.M3P3.host"))
        try Self.eml("md-sent-1").write(to: tree.appendingPathComponent("Maildir/.Sent/cur/1700000004.M4P4.host:2,S"))
        try Self.eml("md-arch-1").write(to: tree.appendingPathComponent("Maildir/.Archive.2024/cur/1700000005.M5P5.host:2,S"))
        let tgz = dir.appendingPathComponent("mail.tgz")
        guard try Self.run("/usr/bin/tar", ["-czf", tgz.path, "Maildir"], in: tree) == 0 else { throw XCTSkip("tar -czf failed") }
        XCTAssertEqual(SourceFormatClassifier.classify(url: tgz).format, .gzip)

        let outer = dir.appendingPathComponent("export.zip")
        try StoredZip.write([
            .file("exports/mail.tgz", try Data(contentsOf: tgz)),
            .file("readme.txt", Data("not mail".utf8)),
        ], to: outer)

        let got = try await importSource(outer)
        let ids = { (names: [String]) in Set(names.map { "\($0)@close02.test" }) }
        assertFolders(got, [
            "Maildir root": (ids(["md-inbox-1", "md-inbox-2", "md-inbox-3"]), "exports/Maildir"),
            "Maildir++ .Sent": (ids(["md-sent-1"]), "exports/Sent"),
            "Maildir++ .Archive.2024": (ids(["md-arch-1"]), "exports/Archive/2024"),
        ])
    }

    // MARK: - Nested .eml folders; 7z → RAR → gzip → MBOX

    func testNestedEmlFolders_andSevenZipHoldingRarHoldingGzipOfMbox() async throws {
        // A ZIP of an .eml folder export, inside a ZIP; the inner export has its own wrapper.
        let emls = dir.appendingPathComponent("emls.zip")
        try StoredZip.write([
            .file("Exported/Clients/Acme/a.eml", Self.eml("eml-acme")),
            .file("Exported/Clients/Acme/b.eml", Self.eml("eml-acme-2")),
            .file("Exported/one.eml", Self.eml("eml-root")),
        ], to: emls)
        let outerZip = dir.appendingPathComponent("cases.zip")
        try StoredZip.write([
            .file("Cases/2020/emls.zip", try Data(contentsOf: emls)),
            .file("notes.txt", Data("notes".utf8)),
        ], to: outerZip)
        let got = try await importSource(outerZip)
        let ids = { (names: [String]) in Set(names.map { "\($0)@close02.test" }) }
        assertFolders(got, [
            "Exported/Clients/Acme": (ids(["eml-acme", "eml-acme-2"]), "Cases/2020/Clients/Acme"),
            "Exported (the inner wrapper names its root)": (ids(["eml-root"]), "Cases/2020/Exported"),
        ])

        // 7z → RAR → gzip → MBOX: four levels, four readers.
        let box = Self.mbox("gz", 3)
        let plain = dir.appendingPathComponent("box.mbox")
        try box.data.write(to: plain)
        let gz = dir.appendingPathComponent("box.mbox.gz")
        guard try Self.run("/usr/bin/gzip", ["-c", "-n", plain.path], stdout: gz) == 0 else { throw XCTSkip("gzip failed") }
        let rar = dir.appendingPathComponent("inner.rar")
        try RARFixtureWriter.writeRAR5([.init(name: "box.mbox.gz", data: try Data(contentsOf: gz))], to: rar)
        let sevenZip = dir.appendingPathComponent("outer.7z")
        let other = Self.mbox("seven", 2)
        try SevenZipFixtureWriter.write([
            .init(name: "Inbox.mbox/mbox", data: other.data),
            .init(name: "nested/inner.rar", data: try Data(contentsOf: rar)),
        ], to: sevenZip, solid: false)
        let chain = try await importSource(sevenZip)
        assertFolders(chain, [
            "Inbox.mbox at the 7z's top": (other.ids, "Inbox"),
            "box.mbox.gz in inner.rar in the 7z (stand-alone mailbox)": (box.ids, ""),
        ])
    }

    // MARK: - Encrypted, missing volume, unsafe paths: refused and counted with reasons

    func testEncryptedAndUnsafeMembers_atEveryLevel_refusedAndCountedWithReasons() async throws {
        let ok = Self.mbox("ok", 1), good = Self.mbox("good", 1)
        let inner = dir.appendingPathComponent("inner.zip")
        try StoredZip.write([
            .file("locked.mbox", Self.mbox("locked", 1).data, encrypted: true),
            .file("../../up.mbox", Self.mbox("up", 1).data),
            .file("ok.mbox", ok.data),
        ], to: inner)
        let outer = dir.appendingPathComponent("refusals.zip")
        try StoredZip.write([
            .file("../escape.mbox", Self.mbox("escape", 1).data),
            .file("/abs/evil.mbox", Self.mbox("evil", 1).data),
            .file("secret.mbox", Self.mbox("secret", 1).data, encrypted: true),
            .file("inner.zip", try Data(contentsOf: inner)),
            .file("good.mbox", good.data),
        ], to: outer)

        let r = try await report(outer)
        XCTAssertEqual(r.totalMessages, 2)
        XCTAssertEqual(r.errorCategories["container_member_refused"], 5)
        XCTAssertEqual(r.errorCategories["reason:unsafe path"], 3, "../escape.mbox, /abs/evil.mbox, ../../up.mbox")
        XCTAssertEqual(r.errorCategories["reason:encrypted"], 2, "secret.mbox, locked.mbox")

        let got = try await importSource(outer)
        assertFolders(got, ["ok.mbox": (ok.ids, ""), "good.mbox": (good.ids, "")])
        XCTAssertTrue(got.summary.warnings.contains("refusals.zip: 5 archive members not imported — 2 encrypted, 3 unsafe path."),
                      "\(got.summary.warnings)")
        XCTAssertFalse(got.folders.values.contains { $0.contains { $0.contains("..") } }, "no folder is ever built from an unsafe name")
    }

    func testMissingVolume_insideAnArchiveSet_refusedAndCountedWithItsReason() async throws {
        let zipTool = URL(fileURLWithPath: "/usr/bin/zip")
        guard FileManager.default.isExecutableFile(atPath: zipTool.path) else { throw XCTSkip("/usr/bin/zip is not available") }
        let filler = 60_000
        let big = Self.mbox("big", 40, bodyBytes: filler / 40 * 2), small = Self.mbox("small", 2)
        // A nested ZIP as the second member of a spanned set: the set spans, the nested ZIP is read whole.
        let inner = dir.appendingPathComponent("inner.zip")
        try StoredZip.write([.file("Mail/Kept.mbox/mbox", small.data)], to: inner)
        try big.data.write(to: dir.appendingPathComponent("big.mbox"))
        guard try Self.run(zipTool.path, ["-q", "-0", "-s", "64k", "set.zip", "big.mbox", "inner.zip"], in: dir) == 0,
              FileManager.default.fileExists(atPath: dir.appendingPathComponent("set.z01").path) else { throw XCTSkip("zip -s failed") }
        try FileManager.default.removeItem(at: dir.appendingPathComponent("big.mbox"))
        try FileManager.default.removeItem(at: dir.appendingPathComponent("set.z01"))

        let r = try await report(dir.appendingPathComponent("set.zip"))
        XCTAssertEqual(r.errorCategories["container_member_refused"], 1, "big.mbox starts on the missing first volume")
        XCTAssertEqual(r.errorCategories["reason:volume missing"], 1)
        let got = try await importSource(dir.appendingPathComponent("set.zip"))
        assertFolders(got, ["Kept.mbox in inner.zip (the single Mail folder is the wrapper, as IPAD-01)": (small.ids, "Kept")])
        XCTAssertTrue(got.summary.warnings.contains("set.zip: 1 archive member not imported — 1 volume missing."), "\(got.summary.warnings)")
    }

    // MARK: - The self-containing guard (named, counted)

    func testSelfContainingGuard_archivesDeeperThanTheGuardAreCounted_everythingAboveImports() async throws {
        let levels = ContainerMailboxWalk.selfContainingGuardDepth + 6
        var oracle = Set<String>()
        var current: Data? = nil
        for level in stride(from: levels, through: 1, by: -1) {
            let box = Self.mbox("lvl\(level)", 1)
            if level <= ContainerMailboxWalk.selfContainingGuardDepth { oracle.formUnion(box.ids) }
            var entries: [StoredZip.Entry] = [.file("m\(level).mbox", box.data)]
            if let current { entries.append(.file("next.zip", current)) }
            let url = dir.appendingPathComponent("lvl\(level).zip")
            try StoredZip.write(entries, to: url)
            current = try Data(contentsOf: url)
        }
        let source = dir.appendingPathComponent("lvl1.zip")
        let r = try await report(source)
        XCTAssertEqual(r.totalMessages, ContainerMailboxWalk.selfContainingGuardDepth, "levels 1…\(ContainerMailboxWalk.selfContainingGuardDepth) import")
        XCTAssertEqual(r.errorCategories["container_nesting_guard_skipped"], 1, "the archive below level \(ContainerMailboxWalk.selfContainingGuardDepth) is counted")
        let got = try await importSource(source)
        XCTAssertEqual(got.ids, oracle)
        XCTAssertTrue(got.summary.warnings.contains { $0.contains("1 archive more than \(ContainerMailboxWalk.selfContainingGuardDepth) archives deep") },
                      "\(got.summary.warnings)")
    }

    func testScratchSpace_isCleanedPerLevel() async throws {
        let inner = dir.appendingPathComponent("inner.zip")
        try StoredZip.write([.file("b.mbox", Self.mbox("b", 2).data)], to: inner)
        let outer = dir.appendingPathComponent("outer.zip")
        try StoredZip.write([.file("a.mbox", Self.mbox("a", 2).data), .file("inner.zip", try Data(contentsOf: inner))], to: outer)
        var scratchByPath: [[Int]: URL] = [:]
        var openAtExtraction: [[Int]: [String]] = [:]
        ContainerMailboxWalk.extractionObserver = { path, _, dest in
            let scratch = dest.deletingLastPathComponent()
            scratchByPath[path] = scratch
            // What else is in this level's scratch while the member is extracted: nothing (one member per level).
            openAtExtraction[path] = (try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? []
        }
        _ = try await report(outer)
        XCTAssertEqual(Set(scratchByPath.keys), [[0], [1], [1, 0]])
        XCTAssertEqual(scratchByPath[[0]], scratchByPath[[1]], "one scratch folder for a level")
        XCTAssertNotEqual(scratchByPath[[1]], scratchByPath[[1, 0]], "a nested archive's members go to its own level's folder")
        XCTAssertEqual(openAtExtraction[[1]], [], "a.mbox was removed before inner.zip was extracted")
        XCTAssertEqual(openAtExtraction[[1, 0]], [], "the inner level holds only the member being extracted")
        for scratch in Set(scratchByPath.values) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path), "every level's scratch is removed: \(scratch.lastPathComponent)")
        }
    }

    // MARK: - Interrupted at a member boundary, resumed after the last finished member

    @MainActor
    func testInterruptedNestedImport_resumesAfterTheLastFinishedMember_exactlyTheRest() async throws {
        let a = Self.mbox("a", 10), b = Self.mbox("b", 10), c = Self.mbox("c", 10), d = Self.mbox("d", 10)
        let inner = dir.appendingPathComponent("inner.zip")
        try StoredZip.write([.file("b.mbox", b.data), .file("c.mbox", c.data)], to: inner)
        let outer = dir.appendingPathComponent("nested.zip")
        try StoredZip.write([
            .file("a.mbox", a.data),
            .file("photo.jpg", Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4])),
            .file("inner.zip", try Data(contentsOf: inner)),
            .file("d.mbox", d.data),
        ], to: outer)
        let root = dir.appendingPathComponent("resume-archive", isDirectory: true)

        // Run 1: "Stop this source" after 25 committed — a, b, and half of c (batches of 5).
        var extracted: [[Int]] = []
        ContainerMailboxWalk.extractionObserver = { path, _, _ in extracted.append(path) }
        let first = try await importSource(outer, root: root, batchSize: 5) { committed, coordinator in
            if committed == 25 { coordinator.skipCurrentSource() }
        }
        XCTAssertEqual(first.rows, 25)
        XCTAssertEqual(first.summary.stoppedByUser.first?.messagesCommitted, 25)
        XCTAssertEqual(extracted, [[0], [1], [2], [2, 0], [2, 1]])

        // Run 2: the walk starts after b.mbox inside inner.zip; a.mbox, photo.jpg
        // and b.mbox are not extracted again; c resumes at its 6th message.
        extracted = []
        let second = try await importSource(outer, root: root, batchSize: 5)
        XCTAssertEqual(extracted, [[2], [2, 1], [3]], "finished members are not read again")
        XCTAssertEqual(second.summary.inserted, 15, "exactly the remaining messages")
        XCTAssertTrue(second.summary.resumed)
        XCTAssertTrue(second.summary.resumedDetail?.contains("after archive member inner.zip › b.mbox") == true, second.summary.resumedDetail ?? "-")
        XCTAssertTrue(second.summary.fileErrors.isEmpty, "\(second.summary.fileErrors)")
        assertFolders(second, ["a": (a.ids, ""), "b": (b.ids, ""), "c": (c.ids, ""), "d": (d.ids, "")])
        XCTAssertEqual(try Self.ordinals(root), Array(0..<40), "ordinals continue exactly from the cursor")
        let cursorDir = root.appendingPathComponent("store/import-container-cursors")
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: cursorDir.path)) ?? [], [], "the cursor goes when the source is complete")

        // Run 3: nothing left to do.
        let third = try await importSource(outer, root: root, batchSize: 5)
        XCTAssertEqual(third.summary.inserted, 0)
        XCTAssertEqual(third.summary.skippedFiles, 1)
    }

    @MainActor
    func testCursorAheadOfTheStore_isIgnored_andTheWalkStartsOver() async throws {
        let a = Self.mbox("a", 4), b = Self.mbox("b", 4)
        let outer = dir.appendingPathComponent("two.zip")
        try StoredZip.write([.file("a.mbox", a.data), .file("b.mbox", b.data)], to: outer)
        let root = dir.appendingPathComponent("ahead-archive", isDirectory: true)
        _ = try await importSource(outer, root: root, batchSize: 2) { committed, coordinator in
            if committed == 2 { coordinator.skipCurrentSource() }
        }
        // A cursor claiming more than the store vouches for (e.g. the store was restored from a backup).
        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let checkpoints = ImportCheckpointStore(store: store)
        let hash = try BulkImportCoordinator.fileDigest(outer)
        let size = (try FileManager.default.attributesOfItem(atPath: outer.path)[.size] as? NSNumber)?.intValue ?? 0
        let parser = ParserFactory.parserIdentity(for: outer, useOffsetEngine: false)
        let identity = ImportCheckpointStore.ResumeIdentity(sha256: hash, sizeBytes: size, parser: parser.name, parserVersion: parser.version)
        await checkpoints.recordContainerCursor(ContainerWalkCursor(memberPath: [0], memberNames: ["a.mbox"], messagesEmitted: 4,
                                                                    totalMessages: 4, parsed: 4, failed: 0, categories: [:],
                                                                    declaredFolders: [], sawMail: true), identity: identity)
        let ahead = await checkpoints.containerCursor(for: identity)
        XCTAssertNotNil(ahead)
        var extracted: [[Int]] = []
        ContainerMailboxWalk.extractionObserver = { path, _, _ in extracted.append(path) }
        let second = try await importSource(outer, root: root, batchSize: 2)
        XCTAssertEqual(extracted, [[0], [1]], "a cursor ahead of the committed rows is not trusted")
        XCTAssertEqual(second.summary.inserted, 6)
        assertFolders(second, ["a": (a.ids, ""), "b": (b.ids, "")])
    }

    static func ordinals(_ root: URL) throws -> [Int] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(root.appendingPathComponent("store/emails.db").path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT source_ordinal FROM emails ORDER BY source_ordinal;", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [Int] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(Int(sqlite3_column_int64(stmt, 0))) }
        return out
    }
}

// MARK: - SIGKILL a separate writer mid-walk (ProcessFaultTests' pattern)

final class ContainerKillResumeTests: XCTestCase {

    func testSIGKILLDuringANestedContainerImport_resumesToExactlyTheSourcesMessageIDs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("close02-kill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        ImportCheckpointStore.legacyJSONURLOverride = root.appendingPathComponent("no-legacy-checkpoints.json")
        defer { ImportCheckpointStore.legacyJSONURLOverride = nil }

        // outer.zip { a.mbox, level1/inner.zip { b.mbox, Mail/C.mbox/mbox, innermost.zip { d.mbox, e.mbox } }, f.mbox }
        let per = 1_000
        var oracle = Set<String>()
        func box(_ tag: String) -> Data { let m = ContainerRecursiveIntakeTests.mbox(tag, per, bodyBytes: 600); oracle.formUnion(m.ids); return m.data }
        let innermost = root.appendingPathComponent("innermost.zip")
        try StoredZip.write([.file("d.mbox", box("d")), .file("e.mbox", box("e"))], to: innermost)
        let inner = root.appendingPathComponent("inner.zip")
        try StoredZip.write([.file("b.mbox", box("b")), .file("Mail/C.mbox/mbox", box("c")),
                             .file("innermost.zip", try Data(contentsOf: innermost))], to: inner)
        let source = root.appendingPathComponent("outer.zip")
        try StoredZip.write([.file("a.mbox", box("a")), .file("level1/inner.zip", try Data(contentsOf: inner)),
                             .file("f.mbox", box("f"))], to: source)
        try FileManager.default.removeItem(at: inner)
        try FileManager.default.removeItem(at: innermost)
        let total = oracle.count
        XCTAssertEqual(total, 6 * per)

        let env = ["MAILIN_FAULT_ROOT": root.path, "MAILIN_FAULT_SOURCE": source.path, "MAILIN_FAULT_BATCH": "50"]
        var previous = 0
        var rng = SystemRandomNumberGenerator()
        var deepestCursor: [Int] = []
        // Commit reports of 50 messages: the kills land in a.mbox, in inner.zip and inside innermost.zip.
        for (n, commits) in [2, 10, 25, 25].enumerated() {
            let child = try FaultHarness.Child(role: "import", env: env)
            guard child.next("START", timeout: 120) != nil else { child.sigkill(); XCTFail("writer never started"); return }
            var reached = true
            for _ in 0..<commits where child.next("COMMITTED", timeout: 120) == nil { reached = false }
            usleep(UInt32.random(in: 20_000...400_000, using: &rng))
            child.sigkill()
            XCTAssertTrue(reached, "kill \(n): \(child.allLines.suffix(3))")
            let state = try await FaultHarness.inspect(root: root)
            print("CLOSE02 kill \(n): \(state)")
            FaultHarness.assertConsistent(state, label: "kill \(n)")
            XCTAssertGreaterThanOrEqual(state.rows, previous, "kill \(n): a kill never loses committed rows")
            previous = state.rows
            let cursorDir = root.appendingPathComponent("store/import-container-cursors")
            for name in (try? FileManager.default.contentsOfDirectory(atPath: cursorDir.path)) ?? [] {
                let data = try Data(contentsOf: cursorDir.appendingPathComponent(name))
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let path = ((json?["cursor"] as? [String: Any])?["memberPath"] as? [Int]) ?? []
                print("CLOSE02 kill \(n): cursor \(path) after \((json?["cursor"] as? [String: Any])?["messagesEmitted"] ?? "-") messages")
                if path.count > deepestCursor.count { deepestCursor = path }
            }
        }
        XCTAssertLessThan(previous, total, "the kills landed before the end")
        XCTAssertGreaterThanOrEqual(deepestCursor.count, 2, "a kill landed with the walk inside a nested archive: \(deepestCursor)")

        let final = try FaultHarness.Child(role: "import", env: env)
        let done = try XCTUnwrap(final.next("DONE", timeout: 600), "\(final.allLines.suffix(3))")
        _ = final.wait(timeout: 60)
        print("CLOSE02 resume: \(done)")
        XCTAssertTrue(done.contains("inserted=\(total - previous) "), "the resume inserts exactly the rest: \(done)")
        XCTAssertTrue(done.contains("persistFailed=0 fileErrors=0"), done)

        let state = try await FaultHarness.inspect(root: root)
        FaultHarness.assertConsistent(state, label: "final")
        XCTAssertEqual(state.rows, total, "no omission, no duplicate")
        XCTAssertEqual(FaultHarness.normalized(state.messageIDs), oracle, "Message-ID set equals the source's")
        XCTAssertEqual(state.sessionCount, total)
        XCTAssertNil(state.progressCheckpoint)
    }
}

// MARK: - A stored-method ZIP writer (names written verbatim, unsafe ones included)

enum StoredZip {
    struct Entry {
        var name: String
        var data: Data
        var encrypted = false
        var isDirectory = false
        static func file(_ name: String, _ data: Data, encrypted: Bool = false) -> Entry { Entry(name: name, data: data, encrypted: encrypted) }
        static func directory(_ name: String) -> Entry { Entry(name: name, data: Data(), isDirectory: true) }
    }

    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { raw in for b in raw { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) } }
        return c ^ 0xFFFF_FFFF
    }

    static func write(_ entries: [Entry], to url: URL) throws {
        var out = Data(), central = Data()
        func u16(_ v: Int, _ d: inout Data) { d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF)) }
        func u32(_ v: UInt32, _ d: inout Data) { for i in 0..<4 { d.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
        for e in entries {
            let name = Data(e.name.utf8)
            let crc = crc32(e.data)
            let offset = UInt32(out.count)
            let flags = (e.encrypted ? 1 : 0) | 0x800
            u32(0x0403_4B50, &out); u16(20, &out); u16(flags, &out); u16(0, &out); u16(0, &out); u16(0x21, &out)
            u32(crc, &out); u32(UInt32(e.data.count), &out); u32(UInt32(e.data.count), &out)
            u16(name.count, &out); u16(0, &out); out.append(name); out.append(e.data)
            u32(0x0201_4B50, &central); u16(20, &central); u16(20, &central); u16(flags, &central); u16(0, &central)
            u16(0, &central); u16(0x21, &central); u32(crc, &central)
            u32(UInt32(e.data.count), &central); u32(UInt32(e.data.count), &central)
            u16(name.count, &central); u16(0, &central); u16(0, &central); u16(0, &central); u16(0, &central)
            u32(e.isDirectory ? 0x10 : 0, &central); u32(offset, &central); central.append(name)
        }
        let cdOffset = UInt32(out.count)
        out.append(central)
        u32(0x0605_4B50, &out); u16(0, &out); u16(0, &out); u16(entries.count, &out); u16(entries.count, &out)
        u32(UInt32(central.count), &out); u32(cdOffset, &out); u16(0, &out)
        try out.write(to: url)
    }
}
