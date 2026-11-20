//
//  FastImportParityTests.swift
//  ArchiveCoreTests
//
//  FAST-06 (owner 2026-11-20: "put everything on … I want to rely on them
//  all"): the fast import must end where the normal import ends.
//
//   • mbox with exact repeats and re-encoded copies, under each Duplicates
//     choice: the messages left visible are the normal import's, the copies
//     the normal import skipped are in the Trash, the receipt adds up;
//   • a message in two folders: one visible copy that belongs to both;
//   • searchable afterwards; a new index gets month shards and a date-limited
//     search still finds its messages;
//   • the parallel readers (PST, ZIP, folder of .eml) hand on exactly the
//     messages, order and folders of the one-at-a-time readers;
//   • cancelled part-way and run again: complete, duplicate pass done.
//

import XCTest
import SQLite3
@testable import ArchiveCore

final class FastImportParityTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("fastparity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    private func message(id: String?, subject: String, body: String, date: String = "Mon, 6 Jan 2025 10:00:00 +0530") -> String {
        var text = "From a@example.com Mon Jan  6 10:00:00 2025\n"
        if let id { text += "Message-ID: <\(id)@example.com>\n" }
        text += "From: Asha <asha@example.com>\nTo: ravi@example.org\nSubject: \(subject)\nDate: \(date)\n\n\(body)\n\n"
        return text
    }

    /// 200 unique messages with an id, 20 exact repeats of them, 15 without an
    /// id and 10 re-encoded repeats of those (same headers and body, no id).
    private func duplicateMailbox() throws -> URL {
        var text = ""
        for i in 0..<200 { text += message(id: "u\(i)", subject: "Unique \(i)", body: "body uniqueword \(i) \(String(repeating: "x ", count: 30))") }
        for i in 0..<20 { text += message(id: "u\(i * 7)", subject: "Unique \(i * 7)", body: "body uniqueword \(i * 7) \(String(repeating: "x ", count: 30))") }
        for i in 0..<15 { text += message(id: nil, subject: "NoID \(i)", body: "plain body \(i)") }
        for i in 0..<10 { text += message(id: nil, subject: "NoID \(i)", body: "plain body \(i)") }
        let url = root.appendingPathComponent("dups-\(UUID().uuidString).mbox")
        try Data(text.utf8).write(to: url)
        return url
    }

    private struct Archive {
        let storeDir: URL
        let store: SQLiteEmailStore
        let fts: FTSSearchIndex
        let coordinator: BulkImportCoordinator
    }

    private func archive(_ name: String) async -> Archive {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        let storeDir = dir.appendingPathComponent("store", isDirectory: true)
        let store = SQLiteEmailStore(directory: storeDir)
        let fts = FTSSearchIndex(shardsDirectory: dir.appendingPathComponent("fts", isDirectory: true))
        let coordinator = await BulkImportCoordinator(store: store, fts: fts, checkpoints: ImportCheckpointStore(store: store),
                                                      requiresStorageActivation: false)
        return Archive(storeDir: storeDir, store: store, fts: fts, coordinator: coordinator)
    }

    private func options(fast: Bool, policy: DedupPolicy) -> BulkImportCoordinator.Options {
        var o = BulkImportCoordinator.Options()
        o.enforceStoragePreflight = false
        o.useOffsetEngine = true
        o.recordLocators = true
        o.dedupPolicy = policy
        o.fastImport = fast
        return o
    }

    private func strings(_ sql: String, in storeDir: URL) -> [String] {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(storeDir.appendingPathComponent("emails.db").path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db = handle else { return [] }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return ["(\(String(cString: sqlite3_errmsg(db))))"] }
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "NULL") }
        return out
    }

    private static let visibleSubjects = """
        SELECT e.subject FROM emails e
        WHERE NOT EXISTS (SELECT 1 FROM email_review_state r WHERE r.email_id = e.id AND r.trashed = 1)
        ORDER BY e.subject;
        """
    private static let trashedCount = "SELECT COUNT(*) FROM email_review_state WHERE trashed = 1;"

    // MARK: - Duplicates under each choice

    func testMbox_eachDuplicatesChoice_fastLeavesTheNormalImportsMessagesVisible() async throws {
        let mbox = try duplicateMailbox()
        for policy in [DedupPolicy.messageID, .messageIDOrCanonicalFingerprint, .preserveAll] {
            let normal = await archive("normal-\(policy.rawValue)")
            let n = try await normal.coordinator.runImport(urls: [mbox], options: options(fast: false, policy: policy))
            let fast = await archive("fast-\(policy.rawValue)")
            let f = try await fast.coordinator.runImport(urls: [mbox], options: options(fast: true, policy: policy))

            let normalVisible = strings(Self.visibleSubjects, in: normal.storeDir)
            let fastVisible = strings(Self.visibleSubjects, in: fast.storeDir)
            XCTAssertEqual(fastVisible, normalVisible, "\(policy): the same messages are visible")
            let expected: Int
            switch policy {
            case .messageID: expected = 200 + 25           // id repeats skipped; no-id mail kept
            case .messageIDOrCanonicalFingerprint: expected = 215  // re-encoded copies skipped too
            case .preserveAll: expected = 245
            }
            XCTAssertEqual(fastVisible.count, expected, "\(policy)")
            let skippedByNormal = 245 - normalVisible.count
            XCTAssertEqual(strings(Self.trashedCount, in: fast.storeDir).first, String(skippedByNormal),
                           "\(policy): the copies the normal import skipped are in the Trash")
            XCTAssertEqual(f.inserted, n.inserted, "\(policy): the receipt's inserted count")
            XCTAssertEqual(f.duplicates ?? 0, skippedByNormal, "\(policy): the receipt counts the duplicates")
            XCTAssertEqual(f.parsed, 245)
            XCTAssertEqual(f.persistFailed, 0)
            let pending = try await fast.store.pendingDeferredDeduplication()
            XCTAssertTrue(pending.isEmpty, "\(policy): the duplicate pass finished")
        }
    }

    // MARK: - Folders

    func testFolder_sameMessageInTwoFolders_oneVisibleCopyInBothFolders() async throws {
        let tree = root.appendingPathComponent("tree", isDirectory: true)
        for folder in ["Inbox", "Archive"] {
            let dir = tree.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for i in 0..<30 {
                // Message 0…9 is in both folders; the rest only in its own.
                let id = i < 10 ? "shared\(i)" : "\(folder)\(i)"
                let text = message(id: id, subject: "\(i < 10 ? "Shared" : folder) \(i)", body: "folder body \(i)")
                    .replacingOccurrences(of: "From a@example.com Mon Jan  6 10:00:00 2025\n", with: "")
                try Data(text.utf8).write(to: dir.appendingPathComponent("\(i).eml"))
            }
        }
        let normal = await archive("folder-normal")
        _ = try await normal.coordinator.runImport(urls: [tree], options: options(fast: false, policy: .messageID))
        let fast = await archive("folder-fast")
        _ = try await fast.coordinator.runImport(urls: [tree], options: options(fast: true, policy: .messageID))

        let normalVisible = strings(Self.visibleSubjects, in: normal.storeDir)
        let fastVisible = strings(Self.visibleSubjects, in: fast.storeDir)
        XCTAssertEqual(normalVisible.count, 50)
        XCTAssertEqual(fastVisible, normalVisible, "the same messages are visible")
        // Each shared message: one visible copy, in both folders (the normal import keeps only the first folder).
        let sharedFolders = strings("""
            SELECT COUNT(*) FROM email_folders ef JOIN emails e ON e.id = ef.email_id
            WHERE e.subject LIKE 'Shared %'
              AND NOT EXISTS (SELECT 1 FROM email_review_state r WHERE r.email_id = e.id AND r.trashed = 1);
            """, in: fast.storeDir)
        XCTAssertEqual(sharedFolders.first, "20", "10 shared messages × 2 folders")
    }

    // MARK: - Search and month shards

    func testSearch_afterFastImport_everyVisibleMessageFound_monthShardsInANewIndex() async throws {
        let mbox = try duplicateMailbox()
        let fast = await archive("search-fast")
        _ = try await fast.coordinator.runImport(urls: [mbox], options: options(fast: true, policy: .messageID))
        let hits = try await fast.fts.search("uniqueword", limit: 1_000)
        XCTAssertGreaterThanOrEqual(hits.count, 200, "every unique message is found")
        let visible = Set(strings("""
            SELECT e.id FROM emails e WHERE e.subject LIKE 'Unique %'
            AND NOT EXISTS (SELECT 1 FROM email_review_state r WHERE r.email_id = e.id AND r.trashed = 1);
            """, in: fast.storeDir).compactMap(UUID.init(uuidString:)))
        XCTAssertEqual(visible.count, 200)
        XCTAssertTrue(visible.isSubset(of: Set(hits)), "each visible message is in the index")

        let shardNames = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("search-fast/fts").path)
            .filter { $0.hasPrefix("email_search_") && $0.hasSuffix(".db") }
        XCTAssertTrue(shardNames.contains("email_search_202501.db"), "month shard for January 2025: \(shardNames)")
        XCTAssertFalse(shardNames.contains("email_search_2025.db"), "no year shard in a month-sharded index")

        // A date-limited search (year 2025) keeps the month shards.
        let after = ISO8601DateFormatter().date(from: "2025-01-01T00:00:00Z")
        let before = ISO8601DateFormatter().date(from: "2025-02-01T00:00:00Z")
        let years = FTSSearchIndex.shardYears(after: after, before: before)
        let (ranked, _) = try await fast.fts.searchRanked("uniqueword", years: years, limit: 1_000)
        XCTAssertGreaterThanOrEqual(ranked.count, 200, "the date-limited search finds them in the month shard")
    }

    // MARK: - Parallel readers hand on exactly what the serial readers do

    private struct Parsed: Equatable { let subjects: [String]; let folders: [String?]; let batches: Int }

    private func parse(_ url: URL, fastLanes: Int?) async throws -> Parsed {
        final class Box: @unchecked Sendable { var emails: [MBOXParser.RawEmail] = []; var batches = 0 }
        let box = Box()
        let lanes: (@Sendable () -> Int)? = fastLanes.map { n in { n } }
        _ = try await ImportWorkerPolicy.$fastReaders.withValue(lanes) {
            try await ParserFactory.parseStreamingCallback(fileURL: url, senderEmail: "", batchSize: 50) { batch in
                box.emails += batch
                box.batches += 1
            }
        }
        return Parsed(subjects: box.emails.map { $0.headers["Subject"] ?? "" }, folders: box.emails.map(\.folderPath), batches: box.batches)
    }

    func testPST_parallelReader_sameMessagesOrderAndFolders() async throws {
        let url = root.appendingPathComponent("many.pst")
        let writer = try PSTSpecWriter(url: url)
        let inbox = writer.appendFolder(name: "Inbox")
        let sent = writer.appendFolder(name: "Sent")
        for (i, email) in PSTSpecWriterTests.emails(300).enumerated() { try writer.append(email: email, folder: i % 3 == 0 ? sent : inbox) }
        XCTAssertEqual(try writer.finalize(), 300)
        let serial = try await parse(url, fastLanes: nil)
        let parallel = try await parse(url, fastLanes: 6)
        XCTAssertEqual(serial.subjects.count, 300)
        XCTAssertEqual(parallel.subjects, serial.subjects, "same messages, same order")
        XCTAssertEqual(parallel.folders, serial.folders, "same folders")
    }

    private func emlTree(_ name: String) throws -> URL {
        let tree = root.appendingPathComponent(name, isDirectory: true)
        for folder in ["Inbox", "Projects"] {
            let dir = tree.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for i in 0..<120 {
                let text = message(id: "\(folder)-\(i)", subject: "\(folder) \(String(format: "%03d", i))", body: "tree body \(i)")
                    .replacingOccurrences(of: "From a@example.com Mon Jan  6 10:00:00 2025\n", with: "")
                try Data(text.utf8).write(to: dir.appendingPathComponent(String(format: "%03d.eml", i)))
            }
        }
        return tree
    }

    func testFolderOfEML_parallelReader_sameMessagesOrderAndFolders_inFewerBatches() async throws {
        let tree = try emlTree("eml-tree")
        let serial = try await parse(tree, fastLanes: nil)
        let parallel = try await parse(tree, fastLanes: 6)
        XCTAssertEqual(serial.subjects.count, 240)
        XCTAssertEqual(parallel.subjects, serial.subjects, "same messages, same order")
        XCTAssertEqual(parallel.folders, serial.folders, "same folders")
        XCTAssertLessThan(parallel.batches, serial.batches, "messages go on in shared batches, not one per file")
    }

    func testZIP_parallelReader_sameMessagesOrderAndFolders_inFewerBatches() async throws {
        let tree = try emlTree("zip-tree")
        let zip = root.appendingPathComponent("tree.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = tree
        process.arguments = ["-qr", zip.path, "Inbox", "Projects"]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let serial = try await parse(zip, fastLanes: nil)
        let parallel = try await parse(zip, fastLanes: 6)
        XCTAssertEqual(serial.subjects.count, 240)
        XCTAssertEqual(parallel.subjects, serial.subjects, "same messages, same order")
        XCTAssertEqual(parallel.folders, serial.folders, "same folders")
        XCTAssertLessThan(parallel.batches, serial.batches, "messages go on in shared batches, not one per member")
    }

    // MARK: - Cancel and run again

    func testFastImport_cancelledPartWay_thenRunAgain_completeWithTheDuplicatePassDone() async throws {
        let mbox = try duplicateMailbox()
        let normal = await archive("cancel-normal")
        _ = try await normal.coordinator.runImport(urls: [mbox], options: options(fast: false, policy: .messageIDOrCanonicalFingerprint))

        let fast = await archive("cancel-fast")
        var opts = options(fast: true, policy: .messageIDOrCanonicalFingerprint)
        opts.adaptiveBatching = false
        opts.batchSize = 40
        final class TaskBox: @unchecked Sendable { var task: Task<BulkImportCoordinator.RunSummary, Error>? }
        let box = TaskBox()
        var callbacks = BulkImportCoordinator.Callbacks()
        callbacks.onCommittedBatch = { _ in box.task?.cancel() }
        box.task = Task { try await fast.coordinator.runImport(urls: [mbox], options: opts, callbacks: callbacks) }
        var cancelled = false
        if let task = box.task { do { _ = try await task.value } catch is CancellationError { cancelled = true } catch {} }
        XCTAssertTrue(cancelled)
        let partial = try await fast.store.totalCount()
        XCTAssertLessThan(partial, 245, "stopped part-way")
        let owed = try await fast.store.pendingDeferredDeduplication()
        XCTAssertFalse(owed.isEmpty, "the duplicate pass is still owed")

        let again = await BulkImportCoordinator(store: fast.store, fts: fast.fts, checkpoints: ImportCheckpointStore(store: fast.store),
                                                requiresStorageActivation: false)
        _ = try await again.runImport(urls: [mbox], options: opts)
        XCTAssertEqual(strings(Self.visibleSubjects, in: fast.storeDir), strings(Self.visibleSubjects, in: normal.storeDir),
                       "after the second run the same messages are visible as after a normal import")
        let done = try await fast.store.pendingDeferredDeduplication()
        XCTAssertTrue(done.isEmpty, "the duplicate pass finished")
    }
}
