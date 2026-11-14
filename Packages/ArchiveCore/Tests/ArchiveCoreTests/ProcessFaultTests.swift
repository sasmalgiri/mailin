//
//  ProcessFaultTests.swift
//  ArchiveCoreTests
//
//  Gate 6 / OPEN-03 / OUT-06 (FIVE_JOBS_TRACKER.md): faults that only a SEPARATE
//  process can show. An in-process test cannot be SIGKILLed half-way through a
//  SQLite transaction and then look at what is left; and an unplug that lands in
//  the middle of a write terminates the writer (WAL memory-maps `-shm`, SIGBUS),
//  which an in-process test cannot survive (FaultVolumeTests had to pause first).
//
//  How: the test binary re-invokes itself (`xctest -XCTest
//  ArchiveCoreTests.FaultWriterRole/testRole <bundle>`) with MAILIN_FAULT_ROLE set.
//  That child is the writer — the production `BulkImportCoordinator` importing
//  into a fresh `SQLiteEmailStore` with store-backed checkpoints, or
//  `ArchiveExportService` exporting — and it reports progress on stdout
//  ("FAULTWRITER …" lines). The parent kills it (SIGKILL) or pulls its disk
//  (`hdiutil detach -force`) at chosen points, then reopens what is left.
//
//  Kill points are made exact with SQLite's own hooks installed on the writer's
//  connection — nothing in the shipping code changes:
//   • in-commit:   `sqlite3_commit_hook` parks the writer INSIDE a batch's
//                  transaction (all rows written, COMMIT not yet done), with
//                  `cache_size = 16` so the batch's pages have already spilled
//                  into the WAL as uncommitted frames — the parent proves that
//                  from the WAL file before it reopens the store;
//   • post-commit: `sqlite3_wal_hook` parks right after a batch committed and
//                  before its rows were indexed (store ahead of FTS).
//  plus "early" (before the first commit), "mid-batch" (part-way between two
//  commit reports) and three random points.
//
//  Run (always — no fixtures, ~1 min):
//    cd Packages/ArchiveCore && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
//      xcrun swift test --filter ProcessKillImportTests
//  Drive removal (creates, attaches and force-detaches its own 200 MB APFS image):
//    MAILIN_SCALE=1 … xcrun swift test --filter DriveRemovalProcessTests
//

import XCTest
import Foundation
import SQLite3
@preconcurrency @testable import ArchiveCore

// MARK: - Shared harness

enum FaultHarness {

    static let prefix = "FAULTWRITER "

    /// A synthetic mbox: `count` messages, unique Message-IDs `<fault-i@mailin.test>`,
    /// ~`bodyBytes` of text each, every 7th with a base64 attachment.
    static func writeMbox(count: Int, bodyBytes: Int, to url: URL) throws -> Set<String> {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let out = try FileHandle(forWritingTo: url)
        defer { try? out.close() }
        var ids = Set<String>()
        let line = "The archive keeps every message exactly once, whatever happens to the writer.\n"
        var body = ""
        while body.utf8.count < bodyBytes { body += line }
        let attachment = Data((0..<3_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }).base64EncodedString(options: .lineLength76Characters)
        var chunk = ""
        for i in 0..<count {
            let mid = "fault-\(i)@mailin.test"
            ids.insert(mid)
            let day = 1 + i % 28
            var m = "From sender\(i % 50)@mailin.test Mon Jan  1 00:00:00 2024\n"
            m += "Message-ID: <\(mid)>\n"
            m += "From: Sender \(i % 50) <sender\(i % 50)@mailin.test>\n"
            m += "To: Receiver <r\(i % 13)@mailin.test>\n"
            m += "Subject: Fault message \(i)\n"
            m += "Date: Mon, \(String(format: "%02d", day)) Jan 2024 10:\(String(format: "%02d", i % 60)):00 +0000\n"
            m += "MIME-Version: 1.0\n"
            if i % 7 == 0 {
                m += "Content-Type: multipart/mixed; boundary=\"b\(i)\"\n\n"
                m += "--b\(i)\nContent-Type: text/plain; charset=utf-8\n\nMessage \(i).\n\(body)\n"
                m += "--b\(i)\nContent-Type: application/octet-stream; name=\"data\(i).bin\"\n"
                m += "Content-Disposition: attachment; filename=\"data\(i).bin\"\nContent-Transfer-Encoding: base64\n\n"
                m += attachment + "\n--b\(i)--\n\n"
            } else {
                m += "Content-Type: text/plain; charset=utf-8\n\nMessage \(i).\n\(body)\n"
            }
            chunk += m
            if chunk.utf8.count > 1 << 20 { try out.write(contentsOf: Data(chunk.utf8)); chunk = "" }
        }
        try out.write(contentsOf: Data(chunk.utf8))
        return ids
    }

    // MARK: Child process

    final class Child: @unchecked Sendable {
        let process = Process()
        private let lock = NSCondition()
        private var lines: [(at: Date, text: String)] = []
        private var buffer = Data()
        private var consumed = 0
        let started = Date()

        init(role: String, env extra: [String: String]) throws {
            let bundle = Bundle(for: FaultWriterRole.self).bundleURL
            process.executableURL = try Self.xctestBinary()
            process.arguments = ["-XCTest", "ArchiveCoreTests.FaultWriterRole/testRole", bundle.path]
            var env = ProcessInfo.processInfo.environment
            env["MAILIN_FAULT_ROLE"] = role
            for (k, v) in extra { env[k] = v }
            process.environment = env
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard let self else { return }
                self.lock.lock()
                if data.isEmpty { self.lines.append((Date(), "\(FaultHarness.prefix)EOF")) }
                self.buffer.append(data)
                while let nl = self.buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let text = String(decoding: self.buffer[self.buffer.startIndex..<nl], as: UTF8.self)
                    self.buffer.removeSubrange(self.buffer.startIndex...nl)
                    if text.hasPrefix(FaultHarness.prefix) { self.lines.append((Date(), text)) }
                }
                self.lock.broadcast()
                self.lock.unlock()
                if data.isEmpty { handle.readabilityHandler = nil }
            }
            try process.run()
        }

        static func xctestBinary() throws -> URL {
            let argv0 = CommandLine.arguments.first ?? ""
            if argv0.hasSuffix("/xctest"), FileManager.default.isExecutableFile(atPath: argv0) {
                return URL(fileURLWithPath: argv0)
            }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            p.arguments = ["--find", "xctest"]
            let pipe = Pipe(); p.standardOutput = pipe
            try p.run(); p.waitUntilExit()
            let path = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return URL(fileURLWithPath: path)
        }

        /// Next writer line (after the ones already consumed) starting with
        /// `FAULTWRITER <kind>`; nil on timeout or when the child exited first.
        func next(_ kind: String, timeout: TimeInterval) -> String? {
            let deadline = Date().addingTimeInterval(timeout)
            lock.lock(); defer { lock.unlock() }
            while true {
                while consumed < lines.count {
                    let text = lines[consumed].text
                    consumed += 1
                    let body = String(text.dropFirst(FaultHarness.prefix.count))
                    if body.hasPrefix(kind) { return body }
                    if body == "EOF" { return nil }
                }
                if !lock.wait(until: deadline) { return nil }
            }
        }

        var allLines: [String] {
            lock.lock(); defer { lock.unlock() }
            return lines.map { String($0.text.dropFirst(FaultHarness.prefix.count)) }
        }

        func sigkill() {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }

        func wait(timeout: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline { usleep(50_000) }
            return !process.isRunning
        }
    }

    // MARK: Store inspection (what a relaunch sees)

    struct StoreState: CustomStringConvertible {
        var integrity = ""
        var rows = 0
        var bodies = 0
        var orphanBodies = 0
        var attachmentsDeclared = 0
        var attachmentRows = 0
        var missingFromParticipant = 0
        var duplicatesRecorded = 0
        var distinctOrdinals = 0
        var minOrdinal = -1
        var maxOrdinal = -1
        var progressCheckpoint: Int?
        var sessionCount: Int?
        var messageIDs: [String] = []
        var indexed = 0

        var description: String {
            "rows=\(rows) checkpoint=\(progressCheckpoint.map(String.init) ?? "-") session=\(sessionCount.map(String.init) ?? "-") indexed=\(indexed) bodies=\(bodies) attachments=\(attachmentRows)/\(attachmentsDeclared) duplicates=\(duplicatesRecorded) ordinals=\(minOrdinal)…\(maxOrdinal) integrity=\(integrity)"
        }

        /// The number of messages the store's own checkpoint vouches for.
        var vouched: Int { sessionCount ?? progressCheckpoint ?? 0 }
    }

    /// Reopens the store the way a relaunch does (`SQLiteEmailStore` → WAL
    /// recovery → integrity check), then reads the tables with a plain handle.
    static func inspect(root: URL) async throws -> StoreState {
        let dir = root.appendingPathComponent("store", isDirectory: true)
        var s = StoreState()
        let store = SQLiteEmailStore(directory: dir)
        s.integrity = try await store.integrityCheck()
        await store.reopenConnection()

        var db: OpaquePointer?
        guard sqlite3_open_v2(dir.appendingPathComponent("emails.db").path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw NSError(domain: "FaultHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: "open failed"])
        }
        defer { sqlite3_close(db) }
        func int(_ sql: String) -> Int? {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
            return Int(sqlite3_column_int64(stmt, 0))
        }
        s.rows = int("SELECT COUNT(*) FROM emails;") ?? -1
        s.bodies = int("SELECT COUNT(*) FROM email_bodies;") ?? -1
        s.orphanBodies = int("SELECT COUNT(*) FROM email_bodies WHERE id NOT IN (SELECT id FROM emails);") ?? -1
        s.attachmentsDeclared = int("SELECT COALESCE(SUM(attachment_count),0) FROM emails;") ?? -1
        s.attachmentRows = int("SELECT COUNT(*) FROM attachments;") ?? -1
        s.missingFromParticipant = int("SELECT COUNT(*) FROM emails e WHERE NOT EXISTS (SELECT 1 FROM email_participants p WHERE p.email_id = e.id AND p.role = 'FROM');") ?? -1
        s.duplicatesRecorded = int("SELECT COUNT(*) FROM duplicates;") ?? -1
        s.distinctOrdinals = int("SELECT COUNT(DISTINCT source_ordinal) FROM emails;") ?? -1
        s.minOrdinal = int("SELECT MIN(source_ordinal) FROM emails;") ?? -1
        s.maxOrdinal = int("SELECT MAX(source_ordinal) FROM emails;") ?? -1
        s.progressCheckpoint = int("SELECT messages_ingested FROM import_progress;")
        s.sessionCount = int("SELECT email_count FROM import_sessions;")
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT message_id FROM emails;", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 0) { s.messageIDs.append(String(cString: c)) }
            }
            sqlite3_finalize(stmt)
        }
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts", isDirectory: true))
        s.indexed = (try? await fts.rowCount()) ?? -1
        return s
    }

    /// The invariants every kill must leave: a healthy database, no half-written
    /// batch (every table agrees, ordinals are exactly 0..<rows), and a
    /// checkpoint that vouches for exactly the rows that are there.
    static func assertConsistent(_ s: StoreState, label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(s.integrity, "ok", "\(label): integrity", file: file, line: line)
        XCTAssertEqual(s.bodies, s.rows, "\(label): every email row has its body row (no half-written batch)", file: file, line: line)
        XCTAssertEqual(s.orphanBodies, 0, "\(label): no body without its email", file: file, line: line)
        XCTAssertEqual(s.attachmentRows, s.attachmentsDeclared, "\(label): attachment rows match the emails' counts", file: file, line: line)
        XCTAssertEqual(s.missingFromParticipant, 0, "\(label): every email has its sender row", file: file, line: line)
        XCTAssertEqual(s.duplicatesRecorded, 0, "\(label): nothing was recorded as a duplicate", file: file, line: line)
        XCTAssertEqual(Set(s.messageIDs).count, s.messageIDs.count, "\(label): no Message-ID stored twice", file: file, line: line)
        if s.rows > 0 {
            XCTAssertEqual(s.minOrdinal, 0, "\(label): ordinals start at 0", file: file, line: line)
            XCTAssertEqual(s.maxOrdinal, s.rows - 1, "\(label): ordinals are contiguous", file: file, line: line)
            XCTAssertEqual(s.distinctOrdinals, s.rows, "\(label): one row per ordinal", file: file, line: line)
        }
        XCTAssertEqual(s.vouched, s.rows, "\(label): the checkpoint vouches for exactly the committed rows", file: file, line: line)
        XCTAssertLessThanOrEqual(s.indexed, s.rows, "\(label): the index can lag the store, never lead it", file: file, line: line)
    }

    static func normalized(_ ids: [String]) -> Set<String> {
        Set(ids.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n")) })
    }

    /// WAL frames written after the last commit frame of the current WAL
    /// generation — i.e. pages of a transaction that never committed. Read
    /// BEFORE anything reopens the database (recovery may reset the WAL).
    static func uncommittedWALFrames(root: URL) -> (frames: Int, committedFrames: Int) {
        let url = root.appendingPathComponent("store/emails.db-wal")
        guard let data = try? Data(contentsOf: url), data.count >= 32 else { return (0, 0) }
        func be32(_ o: Int) -> UInt32 { data[o..<o + 4].reduce(0) { ($0 << 8) | UInt32($1) } }
        let pageSize = Int(be32(8))
        let salt1 = be32(16), salt2 = be32(20)
        guard pageSize > 0 else { return (0, 0) }
        var offset = 32, frame = 0, lastCommit = 0
        while offset + 24 + pageSize <= data.count {
            guard be32(offset + 8) == salt1, be32(offset + 12) == salt2 else { break }
            frame += 1
            if be32(offset + 4) != 0 { lastCommit = frame }
            offset += 24 + pageSize
        }
        return (frame - lastCommit, lastCommit)
    }

    // MARK: hdiutil

    @discardableResult
    static func hdiutil(_ args: [String]) -> (status: Int32, output: String) {
        run("/usr/bin/hdiutil", args)
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: out, as: UTF8.self))
    }
}

// MARK: - Commit-point hooks (writer process only)

/// Set by the writer's batch callback; read by the SQLite hooks on the
/// actor's thread. Plain globals: the hooks are C function pointers.
private var faultParkInCommit = false
private var faultParkAfterCommit = false
private var faultDB: OpaquePointer?

private let faultCommitHook: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { _ in
    if faultParkInCommit {
        var pending: Int32 = 0, hi: Int32 = 0
        sqlite3_db_status(faultDB, SQLITE_DBSTATUS_CACHE_SPILL, &pending, &hi, 0)
        FaultWriterRole.emit("PARKED in-commit autocommit=\(sqlite3_get_autocommit(faultDB)) spilled=\(pending) changes=\(sqlite3_total_changes(faultDB))")
        sleep(600)   // the parent SIGKILLs us here, transaction open
    }
    return 0
}

private let faultWALHook: @convention(c) (UnsafeMutableRawPointer?, OpaquePointer?, UnsafePointer<CChar>?, Int32) -> Int32 = { _, _, _, _ in
    if faultParkAfterCommit {
        FaultWriterRole.emit("PARKED post-commit")
        sleep(600)   // committed, not yet indexed
    }
    return SQLITE_OK
}

// MARK: - The writer (child process role)

/// Not a test of its own: it does nothing unless MAILIN_FAULT_ROLE is set by
/// the parent that spawned this process.
final class FaultWriterRole: XCTestCase {

    static func emit(_ line: String) {
        FileHandle.standardOutput.write(Data((FaultHarness.prefix + line + "\n").utf8))
    }

    func testRole() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let role = env["MAILIN_FAULT_ROLE"] else {
            throw XCTSkip("writer role for ProcessKillImportTests / DriveRemovalProcessTests; runs only when spawned by them")
        }
        // Never read or migrate the production checkpoint file.
        ImportCheckpointStore.legacyJSONURLOverride = URL(fileURLWithPath: env["MAILIN_FAULT_ROOT"]!).appendingPathComponent("no-legacy-checkpoints.json")
        switch role {
        case "import": try await runImport(env)
        case "export": try await runExport(env)
        default: XCTFail("unknown role \(role)")
        }
    }

    @MainActor
    private func runImport(_ env: [String: String]) async throws {
        let root = URL(fileURLWithPath: env["MAILIN_FAULT_ROOT"]!, isDirectory: true)
        let source = URL(fileURLWithPath: env["MAILIN_FAULT_SOURCE"]!)
        let mode = env["MAILIN_FAULT_PARK"] ?? "none"           // none | in-commit | post-commit
        let parkAt = Int(env["MAILIN_FAULT_PARK_AT"] ?? "") ?? Int.max
        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts", isDirectory: true))
        let checkpoints = ImportCheckpointStore(store: store)
        if mode != "none" {
            let db = try await store.ensureDB()
            switch mode {
            case "in-commit":
                // Small page cache: the batch's pages spill into the WAL before
                // COMMIT, so the kill leaves uncommitted frames for recovery.
                let rc = sqlite3_exec(db, "PRAGMA cache_size = 16; PRAGMA cache_spill = 16;", nil, nil, nil)
                faultDB = db
                var st: OpaquePointer?
                sqlite3_prepare_v2(db, "PRAGMA cache_size;", -1, &st, nil); sqlite3_step(st)
                let cs = sqlite3_column_int(st, 0); sqlite3_finalize(st)
                sqlite3_prepare_v2(db, "PRAGMA cache_spill;", -1, &st, nil); sqlite3_step(st)
                let sp = sqlite3_column_int(st, 0); sqlite3_finalize(st)
                Self.emit("DIAG rc=\(rc) cache_size=\(cs) cache_spill=\(sp)")
                sqlite3_commit_hook(db, faultCommitHook, nil)
            case "post-commit":
                sqlite3_wal_hook(db, faultWALHook, nil)
            default: break
            }
        }
        let coordinator = BulkImportCoordinator(store: store, fts: fts, checkpoints: checkpoints,
                                                requiresStorageActivation: false)
        var options = BulkImportCoordinator.Options()
        options.enforceStoragePreflight = false
        options.adaptiveBatching = false
        options.batchSize = Int(env["MAILIN_FAULT_BATCH"] ?? "") ?? 100
        var committed = 0
        var callbacks = BulkImportCoordinator.Callbacks()
        callbacks.onCommittedBatch = { batch in
            committed += batch.count
            Self.emit("COMMITTED \(committed)\(faultDB.map { " changes=\(sqlite3_total_changes($0))" } ?? "")")
            if committed >= parkAt {
                if mode == "in-commit" { faultParkInCommit = true }
                if mode == "post-commit" { faultParkAfterCommit = true }
            }
        }
        // Report a pause (e.g. "Archive volume detached") as soon as it is set.
        let watcher = Task { @MainActor in
            var last: String?
            while !Task.isCancelled {
                let reason = coordinator.batchPauseReason
                if reason != last, let reason { Self.emit("PAUSED \(reason)") }
                last = reason
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { watcher.cancel() }
        Self.emit("START")
        do {
            let s = try await coordinator.runImport(urls: [source], options: options, callbacks: callbacks)
            Self.emit("DONE inserted=\(s.inserted.map(String.init) ?? "nil") duplicates=\(s.duplicates.map(String.init) ?? "nil") skippedFiles=\(s.skippedFiles) resumed=\(s.resumed) persistFailed=\(s.persistFailed) fileErrors=\(s.fileErrors.count) detail=\(s.resumedDetail ?? "-") errors=\(s.fileErrors.map(\.message))")
        } catch {
            Self.emit("THREW \(error.localizedDescription)")
        }
    }

    @MainActor
    private func runExport(_ env: [String: String]) async throws {
        let root = URL(fileURLWithPath: env["MAILIN_FAULT_ROOT"]!, isDirectory: true)
        let output = URL(fileURLWithPath: env["MAILIN_FAULT_OUTPUT"]!)
        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts", isDirectory: true))
        let archive = ArchiveDataService(repository: EmailStoreRepository(store: store, fts: fts))
        let service = ArchiveExportService(archive: archive)
        var write = ExportWriteOptions()
        write.keepPartialOnCancel = true
        var last = (0, 0)
        Self.emit("START")
        do {
            let r = try await service.exportMBOXArchive(scope: .query(.all, exclusions: []), to: output, write: write,
                                                        onProgress: { done, total in
                                                            last = (done, total)
                                                            Self.emit("PROGRESS \(done) \(total)")
                                                        })
            Self.emit("DONE completed=\(r.completed) records=\(r.recordsWritten) bytes=\(r.bytesWritten) sha=\(r.sha256Hex ?? "-")")
        } catch {
            // What the app's receipt would say: X of Y, failed.
            Self.emit("THREW written=\(last.0) of=\(last.1) error=\(error.localizedDescription)")
        }
    }
}

// MARK: - OPEN-03: SIGKILL the importing process at chosen points

final class ProcessKillImportTests: XCTestCase {

    func testSIGKILLMidImport_atSevenPoints_leavesAConsistentStore_andResumesToExactlyTheSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("procfault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        ImportCheckpointStore.legacyJSONURLOverride = root.appendingPathComponent("no-legacy-checkpoints.json")
        defer { ImportCheckpointStore.legacyJSONURLOverride = nil }

        let total = 8_000, batch = 100
        let source = root.appendingPathComponent("source.mbox")
        let sourceIDs = try FaultHarness.writeMbox(count: total, bodyBytes: 1_500, to: source)
        let sourceBytes = (try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.intValue ?? 0
        print("PROCFAULT source: \(total) messages, \(sourceBytes) bytes, batch \(batch)")

        let baseEnv = ["MAILIN_FAULT_ROOT": root.path, "MAILIN_FAULT_SOURCE": source.path, "MAILIN_FAULT_BATCH": "\(batch)"]
        var rng = SystemRandomNumberGenerator()
        var previous = 0
        var killsAfterProgress = 0

        /// One writer run killed at a point; returns what a relaunch finds.
        func killRun(_ label: String, park: String = "none", parkAt: Int = 0,
                     at point: (FaultHarness.Child) -> Bool) async throws -> FaultHarness.StoreState {
            var env = baseEnv
            env["MAILIN_FAULT_PARK"] = park
            env["MAILIN_FAULT_PARK_AT"] = "\(parkAt)"
            let child = try FaultHarness.Child(role: "import", env: env)
            guard child.next("START", timeout: 120) != nil else {
                child.sigkill()
                XCTFail("\(label): writer never started: \(child.allLines)"); throw XCTSkip("no writer")
            }
            let reached = point(child)
            let killedAt = Date().timeIntervalSince(child.started)
            child.sigkill()
            XCTAssertEqual(child.process.terminationReason, .uncaughtSignal, "\(label): the writer died by the signal")
            XCTAssertTrue(reached, "\(label): the kill point was reached: \(child.allLines.suffix(3))")
            let wal = FaultHarness.uncommittedWALFrames(root: root)
            let state = try await FaultHarness.inspect(root: root)
            let lastReport = child.allLines.last(where: { $0.hasPrefix("COMMITTED") }) ?? "COMMITTED (none this run)"
            print("PROCFAULT kill \(label): t=\(String(format: "%.2f", killedAt)) s, last report '\(lastReport)', WAL uncommitted frames=\(wal.frames) (committed frames \(wal.committedFrames)); after reopen \(state)")
            FaultHarness.assertConsistent(state, label: label)
            XCTAssertGreaterThanOrEqual(state.rows, previous, "\(label): a kill never loses committed rows")
            if state.rows > previous { killsAfterProgress += 1 }
            previous = state.rows
            return state
        }

        // 1. Early: as soon as the writer starts (hashing / source registration).
        _ = try await killRun("early") { _ in usleep(20_000); return true }

        // 2. Mid-batch: part-way between two commit reports.
        _ = try await killRun("mid-batch") { child in
            guard child.next("COMMITTED", timeout: 120) != nil, child.next("COMMITTED", timeout: 60) != nil else { return false }
            usleep(30_000)
            return true
        }

        // 3. In-commit: parked inside a batch's transaction, pages already in the WAL.
        // (The writer counts what IT committed; the park point is relative to the resume.)
        let inCommitAt = 1_000
        var inCommitFrames = 0
        do {
            var env = baseEnv
            env["MAILIN_FAULT_PARK"] = "in-commit"; env["MAILIN_FAULT_PARK_AT"] = "\(inCommitAt)"
            let child = try FaultHarness.Child(role: "import", env: env)
            let parked = child.next("PARKED in-commit", timeout: 180)
            child.sigkill()
            XCTAssertNotNil(parked, "in-commit: the writer parked inside a commit: \(child.allLines.suffix(3))")
            inCommitFrames = FaultHarness.uncommittedWALFrames(root: root).frames
            let state = try await FaultHarness.inspect(root: root)
            print("PROCFAULT kill in-commit:'\(parked ?? "-")' after \(previous) + \(inCommitAt) committed, WAL uncommitted frames=\(inCommitFrames); after reopen \(state)")
            XCTAssertGreaterThan(inCommitFrames, 0, "in-commit: the killed transaction had written pages into the WAL")
            FaultHarness.assertConsistent(state, label: "in-commit")
            XCTAssertEqual(state.rows, previous + inCommitAt, "in-commit: the open batch is gone entirely; the committed ones are all there")
            previous = state.rows
        }

        // 4. Post-commit: batch committed, its rows not yet indexed.
        let postCommitAt = 1_000
        do {
            var env = baseEnv
            env["MAILIN_FAULT_PARK"] = "post-commit"; env["MAILIN_FAULT_PARK_AT"] = "\(postCommitAt)"
            let child = try FaultHarness.Child(role: "import", env: env)
            let parked = child.next("PARKED post-commit", timeout: 180)
            child.sigkill()
            XCTAssertNotNil(parked, "post-commit: the writer parked after a commit: \(child.allLines.suffix(3))")
            let state = try await FaultHarness.inspect(root: root)
            print("PROCFAULT kill post-commit: parked after \(previous) + \(postCommitAt) reported; after reopen \(state)")
            FaultHarness.assertConsistent(state, label: "post-commit")
            XCTAssertEqual(state.rows, previous + postCommitAt + batch, "post-commit: the batch that committed before the kill is kept")
            XCTAssertLessThan(state.indexed, state.rows, "post-commit: the store is ahead of the index (repaired below)")
            previous = state.rows
        }

        // 5–7. Random points after the run has made progress.
        for n in 1...3 {
            let delay = UInt32.random(in: 50_000...600_000, using: &rng)
            _ = try await killRun("random-\(n) (+\(delay / 1000) ms)") { child in
                guard child.next("COMMITTED", timeout: 120) != nil else { return false }
                usleep(delay)
                return true
            }
        }

        // Resume to the end: one clean run, then a second that must find nothing to do.
        let finalChild = try FaultHarness.Child(role: "import", env: baseEnv)
        let started = Date()
        let done = finalChild.next("DONE", timeout: 600)
        _ = finalChild.wait(timeout: 60)
        print("PROCFAULT resume run: \(done ?? "no DONE: \(finalChild.allLines.suffix(3))") in \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
        let finalLine = try XCTUnwrap(done)
        XCTAssertTrue(finalLine.contains("resumed=true"), finalLine)
        XCTAssertTrue(finalLine.contains("inserted=\(total - previous) "), "the resume inserts exactly the rest: \(finalLine)")
        XCTAssertTrue(finalLine.contains("persistFailed=0 fileErrors=0"), finalLine)

        let again = try FaultHarness.Child(role: "import", env: baseEnv)
        let againLine = try XCTUnwrap(again.next("DONE", timeout: 300))
        _ = again.wait(timeout: 60)
        XCTAssertTrue(againLine.contains("inserted=0 ") && againLine.contains("skippedFiles=1"), "a finished source is not read again: \(againLine)")

        var state = try await FaultHarness.inspect(root: root)
        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts", isDirectory: true))
        let repaired = try await FTSReconciler.reconcile(store: store, fts: fts)
        await store.reopenConnection()
        let indexedBeforeRepair = state.indexed
        state.indexed = try await fts.rowCount()
        print("PROCFAULT final: \(state); index repaired by launch reconciler: \(repaired.rowsIndexed) rows (\(indexedBeforeRepair) → \(state.indexed)); kills that landed after progress: \(killsAfterProgress)")
        FaultHarness.assertConsistent(state, label: "final")
        XCTAssertEqual(state.rows, total, "no losses, no duplicates")
        XCTAssertEqual(state.sessionCount, total, "the source is recorded as fully imported")
        XCTAssertNil(state.progressCheckpoint, "no in-progress checkpoint is left behind")
        XCTAssertEqual(FaultHarness.normalized(state.messageIDs), sourceIDs, "Message-ID set equals the source's")
        XCTAssertEqual(state.indexed, total, "after the launch reconciler, every row is searchable")
    }
}

// MARK: - OUT-06 / drive removal: a separate writer loses its disk mid-write

final class DriveRemovalProcessTests: XCTestCase {

    private var image: URL!
    private var mountPoint: URL!
    private var work: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MAILIN_SCALE"] == "1", "drive-removal rows are opt-in: MAILIN_SCALE=1 (creates and force-detaches a disk image)")
        work = FileManager.default.temporaryDirectory.appendingPathComponent("driveremoval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        mountPoint = work.appendingPathComponent("mnt", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        image = work.appendingPathComponent("fault.sparseimage")
        var created = FaultHarness.hdiutil(["create", "-size", "200m", "-fs", "APFS", "-volname", "MailinFault", "-type", "SPARSE", image.path])
        if created.status != 0 {
            // macOS 27: `hdiutil create` fails ("Directory not empty"); its
            // replacement is `diskutil image create blank` (a sparse RAW file).
            image = work.appendingPathComponent("fault.dmg")
            created = FaultHarness.run("/usr/sbin/diskutil", ["image", "create", "blank", "--fs", "APFS", "--size", "200m", "--volumeName", "MailinFault", image.path])
        }
        try XCTSkipUnless(created.status == 0, "could not create the disk image: \(created.output)")
        try attach()
        ImportCheckpointStore.legacyJSONURLOverride = work.appendingPathComponent("no-legacy-checkpoints.json")
    }

    override func tearDownWithError() throws {
        ImportCheckpointStore.legacyJSONURLOverride = nil
        if let mountPoint { FaultHarness.hdiutil(["detach", mountPoint.path, "-force"]) }
        if let work { try? FileManager.default.removeItem(at: work) }
    }

    private func attach() throws {
        let r = FaultHarness.hdiutil(["attach", image.path, "-mountpoint", mountPoint.path, "-nobrowse"])
        guard r.status == 0 else { throw NSError(domain: "hdiutil", code: Int(r.status), userInfo: [NSLocalizedDescriptionKey: r.output]) }
    }

    private func detach() -> (Int32, String) {
        let r = FaultHarness.hdiutil(["detach", mountPoint.path, "-force"])
        return (r.status, r.output)
    }

    /// The pull lands while the writer is mid-export: the writer is frozen
    /// (SIGSTOP), the disk detached, the writer thawed into a missing disk.
    /// Without the freeze, `detach -force` can wait out the writer's own
    /// durable flushes (F_FULLFSYNC per batch) and take effect only after the
    /// export finished — a race a physically pulled drive does not have.
    private func detachMidWrite(_ child: FaultHarness.Child) -> (Int32, String) {
        // A random moment inside the next batch, so the pull usually finds
        // written-but-unvouched records (and sometimes a cut one) on the disk.
        usleep(UInt32.random(in: 10_000...120_000))
        kill(child.process.processIdentifier, SIGSTOP)
        let result = detach()
        kill(child.process.processIdentifier, SIGCONT)
        return result
    }

    /// The archive lives on the removable disk; the importing process loses it
    /// mid-batch. Whatever the writer does (dies, pauses, fails the file), the
    /// re-attached store must be healthy, its checkpoint must vouch for exactly
    /// its rows, and a fresh run must finish the source exactly.
    func testDetachDuringImport_fromASeparateProcess_storeIsConsistent_andResumesExactly() async throws {
        let total = 6_000
        let source = work.appendingPathComponent("source.mbox")   // on the boot volume
        let sourceIDs = try FaultHarness.writeMbox(count: total, bodyBytes: 4_000, to: source)
        let root = mountPoint.appendingPathComponent("archive", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let env = ["MAILIN_FAULT_ROOT": root.path, "MAILIN_FAULT_SOURCE": source.path, "MAILIN_FAULT_BATCH": "100"]

        let child = try FaultHarness.Child(role: "import", env: env)
        XCTAssertNotNil(child.next("START", timeout: 120))
        // Let ~a fifth of the source commit, then pull the disk mid-batch.
        var reported = 0
        while reported < total / 5, let line = child.next("COMMITTED", timeout: 120) {
            reported = Int(line.split(separator: " ")[1]) ?? reported
        }
        usleep(40_000)
        let detachStart = Date()
        let (status, output) = detach()
        print("DRIVE import: detached at \(reported) reported committed (hdiutil \(status), \(String(format: "%.2f", Date().timeIntervalSince(detachStart))) s): \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        XCTAssertEqual(status, 0, "force detach failed")

        // What does the writer do with its disk gone? Watch for 10 s.
        let watchUntil = Date().addingTimeInterval(10)
        while child.process.isRunning && Date() < watchUntil { usleep(100_000) }
        let paused = child.allLines.first(where: { $0.hasPrefix("PAUSED") })
        let ended = child.allLines.first(where: { $0.hasPrefix("DONE") || $0.hasPrefix("THREW") })
        print("DRIVE import: writer running=\(child.process.isRunning) exit=\(child.process.isRunning ? "-" : "\(child.process.terminationReason == .uncaughtSignal ? "signal" : "exit") \(child.process.terminationStatus)") paused=\(paused ?? "nil") ended=\(ended ?? "nil")")
        if let ended {
            XCTAssertFalse(ended.contains("persistFailed=0 fileErrors=0") && ended.contains("inserted=\(total)"),
                           "a run that lost its disk must not report a clean, complete import: \(ended)")
        }

        // Plug it back in. A writer still waiting may continue; give it a minute.
        try attach()
        if child.process.isRunning {
            let finished = child.next("DONE", timeout: 90) ?? child.next("THREW", timeout: 1)
            print("DRIVE import: after re-attach the same writer said: \(finished ?? "nothing in 90 s")")
            child.sigkill()
        }

        let after = try await FaultHarness.inspect(root: root)
        print("DRIVE import: after re-attach and reopen \(after)")
        FaultHarness.assertConsistent(after, label: "after detach")

        let resume = try FaultHarness.Child(role: "import", env: env)
        let done = resume.next("DONE", timeout: 600)
        _ = resume.wait(timeout: 60)
        print("DRIVE import: resume run: \(done ?? "none: \(resume.allLines.suffix(3))")")
        var final = try await FaultHarness.inspect(root: root)
        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts", isDirectory: true))
        let repaired = try await FTSReconciler.reconcile(store: store, fts: fts)
        await store.reopenConnection()
        final.indexed = try await fts.rowCount()
        print("DRIVE import: final \(final); reconciler indexed \(repaired.rowsIndexed)")
        FaultHarness.assertConsistent(final, label: "final")
        XCTAssertEqual(final.rows, total)
        XCTAssertEqual(FaultHarness.normalized(final.messageIDs), sourceIDs)
        XCTAssertEqual(final.indexed, total)
    }

    /// The archive is on this Mac; an export is being written to the removable
    /// disk by a separate process when the disk is pulled. The writer must not
    /// claim a complete export, the archive must be untouched, and whatever
    /// the writer said it wrote must be what is on the disk when it returns.
    func testDetachDuringExport_fromASeparateProcess_outcomeIsHonest_andArchiveIntact() async throws {
        let total = 6_000
        let root = work.appendingPathComponent("archive", isDirectory: true)   // boot volume
        let source = work.appendingPathComponent("source.mbox")
        _ = try FaultHarness.writeMbox(count: total, bodyBytes: 4_000, to: source)
        let importer = try FaultHarness.Child(role: "import", env: ["MAILIN_FAULT_ROOT": root.path, "MAILIN_FAULT_SOURCE": source.path, "MAILIN_FAULT_BATCH": "500"])
        XCTAssertNotNil(importer.next("DONE", timeout: 600))
        _ = importer.wait(timeout: 60)
        let before = try await FaultHarness.inspect(root: root)
        XCTAssertEqual(before.rows, total)

        let output = mountPoint.appendingPathComponent("export.mbox")
        let child = try FaultHarness.Child(role: "export", env: ["MAILIN_FAULT_ROOT": root.path, "MAILIN_FAULT_OUTPUT": output.path])
        XCTAssertNotNil(child.next("START", timeout: 120))
        var progress = 0
        while progress < total / 4, let line = child.next("PROGRESS", timeout: 120) {
            progress = Int(line.split(separator: " ")[1]) ?? progress
        }
        let (status, text) = detachMidWrite(child)
        print("DRIVE export: detached after PROGRESS \(progress) of \(total) (hdiutil \(status)): \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        XCTAssertEqual(status, 0)
        let deadline = Date().addingTimeInterval(60)
        var verdict: String?
        repeat {
            let exited = !child.process.isRunning
            verdict = child.allLines.first(where: { $0.hasPrefix("DONE") || $0.hasPrefix("THREW") })
            if verdict != nil || exited { break }
            usleep(100_000)
        } while Date() < deadline
        child.sigkill()
        print("DRIVE export: writer said: \(verdict ?? "nothing (exit reason \(child.process.terminationReason.rawValue), status \(child.process.terminationStatus))")")
        if let verdict {
            XCTAssertFalse(verdict.hasPrefix("DONE completed=true"), "an export whose disk was pulled must not report completion: \(verdict)")
        }

        try attach()
        let onDisk = FileManager.default.fileExists(atPath: output.path)
        let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.intValue ?? 0
        var records = 0
        if onDisk, let data = FileManager.default.contents(atPath: output.path) {
            records = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
                .filter { $0.starts(with: Data("Message-ID: <fault-".utf8)) }.count
        }
        print("DRIVE export: after re-attach the file exists=\(onDisk) bytes=\(size) records=\(records)")

        // The archive on this Mac is untouched.
        let after = try await FaultHarness.inspect(root: root)
        FaultHarness.assertConsistent(after, label: "archive after export fault")
        XCTAssertEqual(after.rows, total)

        // Nothing reported as written that is not on the disk: the "X of Y" the
        // writer reported is a prefix of what the re-attached file holds. (The
        // tail past X could not be cut back on a vanished disk; it is never
        // vouched for. R8: `ContainerManifest.recover` cuts it back to the last
        // verified checkpoint on reconnect — see the recover-and-resume test below.)
        if let verdict, verdict.hasPrefix("THREW"),
           let written = verdict.split(separator: " ").first(where: { $0.hasPrefix("written=") }).flatMap({ Int($0.dropFirst(8)) }) {
            XCTAssertTrue(onDisk, "the partial file is kept")
            XCTAssertGreaterThanOrEqual(records, written, "every record the writer reported is on the disk")
            XCTAssertLessThan(written, total, "a failed export says X of Y with X < Y")
        }
    }

    /// R8 / OUT-06a: the disk is pulled mid-export, plugged back in, and the
    /// partial export is recovered and resumed. The file it leaves holds
    /// records past the receipt's "X of Y" (the last may be cut); recovery
    /// verifies the last durable checkpoint's prefix hash, inventories that
    /// tail and cuts it away; the resume appends from exactly there. The
    /// finished file parses to exactly the selection — no record twice, none
    /// missing — the receipt's count equals the parsed count, its SHA-256 is
    /// the file's, and the content check pairs every record one-to-one.
    func testDetachDuringExport_reattach_recoverAndResume_outputIsExactlyTheSelection() async throws {
        let total = 6_000
        let root = work.appendingPathComponent("archive", isDirectory: true)   // boot volume
        let source = work.appendingPathComponent("source.mbox")
        let sourceIDs = try FaultHarness.writeMbox(count: total, bodyBytes: 4_000, to: source)
        let importer = try FaultHarness.Child(role: "import", env: ["MAILIN_FAULT_ROOT": root.path, "MAILIN_FAULT_SOURCE": source.path, "MAILIN_FAULT_BATCH": "500"])
        XCTAssertNotNil(importer.next("DONE", timeout: 600))
        _ = importer.wait(timeout: 60)

        let output = mountPoint.appendingPathComponent("export.mbox")
        let child = try FaultHarness.Child(role: "export", env: ["MAILIN_FAULT_ROOT": root.path, "MAILIN_FAULT_OUTPUT": output.path])
        XCTAssertNotNil(child.next("START", timeout: 120))
        var progress = 0
        while progress < total / 4, let line = child.next("PROGRESS", timeout: 120) {
            progress = Int(line.split(separator: " ")[1]) ?? progress
        }
        let (status, _) = detachMidWrite(child)
        XCTAssertEqual(status, 0)
        let deadline = Date().addingTimeInterval(60)
        var verdict: String?
        repeat {
            verdict = child.allLines.first(where: { $0.hasPrefix("DONE") || $0.hasPrefix("THREW") })
            if verdict != nil || !child.process.isRunning { break }
            usleep(100_000)
        } while Date() < deadline
        child.sigkill()
        // What the receipt would say: the last PROGRESS the writer reported.
        let reported = child.allLines.filter { $0.hasPrefix("PROGRESS") }.compactMap { Int($0.split(separator: " ")[1]) }.max() ?? 0
        print("DRIVE resume: detached after PROGRESS \(progress); writer said \(verdict ?? "nothing"); receipt X = \(reported) of \(total)")
        if let verdict { XCTAssertFalse(verdict.hasPrefix("DONE completed=true"), verdict) }

        try attach()
        let foundBytes = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.uint64Value ?? 0
        let foundRecords = (FileManager.default.contents(atPath: output.path) ?? Data())
            .split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            .filter { $0.starts(with: Data("Message-ID: <fault-".utf8)) }.count
        let recovery = try ContainerManifest.recover(output: output)
        print("DRIVE resume: found \(foundBytes) bytes holding \(foundRecords) record(s) (\(foundRecords - reported) past the receipt); \(recovery.summary); vouched positions \(recovery.positions)")
        XCTAssertGreaterThanOrEqual(recovery.positions, reported, "the durable checkpoint is never behind what the receipt reported")
        XCTAssertEqual(recovery.records, recovery.positions, "one mbox record per selected message")
        XCTAssertLessThan(recovery.positions, total)
        // Every record found past the boundary is in the tail inventory (a cut
        // one may have lost its Message-ID line, so it can be one fewer).
        let inventoried = recovery.records + recovery.tailCompleteRecords
        XCTAssertTrue(foundRecords == inventoried || (recovery.tailLastRecordCut && foundRecords == inventoried + 1),
                      "found \(foundRecords), inventoried \(inventoried) + \(recovery.tailLastRecordCut ? "1 cut" : "none cut")")
        let cutBack = try await Self.parse(output)
        XCTAssertEqual(cutBack.count, recovery.records, "after recovery the file parses to exactly the vouched records")
        XCTAssertEqual(Set(cutBack).count, cutBack.count)

        let resumed = try await Self.resume(root: root, output: output, recovery: recovery)
        print("DRIVE resume: resumed run completed=\(resumed.completed) records=\(resumed.recordsWritten) sha=\(resumed.sha256Hex ?? "-")")
        XCTAssertTrue(resumed.completed)
        XCTAssertEqual(resumed.recordsWritten, total, "the receipt: \(total) of \(total)")
        let final = try await Self.parse(output)
        XCTAssertEqual(final.count, total, "parsed count equals the receipt's")
        XCTAssertEqual(Set(final).count, final.count, "no record twice")
        XCTAssertEqual(FaultHarness.normalized(final), sourceIDs, "exactly the selection")
        let sha = ContainerManifest.hex(try ArchiveExportService.sha256(ofFile: output))
        XCTAssertEqual(sha, resumed.sha256Hex, "the hash the receipt carries is the file's")
        let manifest = try ContainerManifest.scan(url: ContainerManifest.url(for: output))
        XCTAssertEqual(manifest.recordLines, total); XCTAssertEqual(manifest.end?.records, total); XCTAssertEqual(manifest.end?.sha256, sha)
        XCTAssertNil(manifest.inconsistent)

        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let lookup = ExportReconciliation.SourceLookup(records: { ids in
            var out: [UUID: MBOXParser.RawEmail] = [:]
            for id in ids { if let e = try await store.fullEmail(id: id) { out[id] = e } }
            return out
        })
        let report = await ExportReconciliation.reconcile(file: output, promised: resumed.recordsWritten, lookup: lookup)
        print("DRIVE resume: content check \(report.summary)")
        XCTAssertEqual(report.outcome, .complete, "\(report.summary)\n\(report.findings.prefix(3))")
        XCTAssertEqual(report.selection?.paired, total)
        XCTAssertEqual(report.selection?.missing, 0); XCTAssertEqual(report.selection?.extra, 0)
    }

    /// Message-IDs of every record an mbox parses to, in file order.
    static func parse(_ url: URL) async throws -> [String] {
        var ids: [String] = []
        try await ExportReconciliation.readContainer(url, kind: .mbox, batchSize: 500) { batch in
            ids.append(contentsOf: batch.map { ExportReconciliation.identifier($0.headers["Message-ID"] ?? "") })
        }
        return ids
    }

    @MainActor
    static func resume(root: URL, output: URL, recovery: ContainerManifest.Recovery) async throws -> ArchiveExportResult {
        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts", isDirectory: true))
        let service = ArchiveExportService(archive: ArchiveDataService(repository: EmailStoreRepository(store: store, fts: fts)))
        return try await service.exportMBOXArchive(scope: .query(.all, exclusions: []), to: output, write: .resuming(from: recovery))
    }

    /// The export finishes; the disk is pulled immediately after the writer
    /// reported success. What it reported (records, SHA-256) must be on the disk.
    func testDetachRightAfterACompletedExport_reportedBytesAreOnTheDisk() async throws {
        let total = 3_000
        let root = work.appendingPathComponent("archive", isDirectory: true)
        let source = work.appendingPathComponent("source.mbox")
        _ = try FaultHarness.writeMbox(count: total, bodyBytes: 2_000, to: source)
        let importer = try FaultHarness.Child(role: "import", env: ["MAILIN_FAULT_ROOT": root.path, "MAILIN_FAULT_SOURCE": source.path, "MAILIN_FAULT_BATCH": "500"])
        XCTAssertNotNil(importer.next("DONE", timeout: 600))
        _ = importer.wait(timeout: 60)

        let output = mountPoint.appendingPathComponent("export.mbox")
        let child = try FaultHarness.Child(role: "export", env: ["MAILIN_FAULT_ROOT": root.path, "MAILIN_FAULT_OUTPUT": output.path])
        let done = try XCTUnwrap(child.next("DONE", timeout: 600), "\(child.allLines.suffix(3))")
        let (status, _) = detach()   // the instant the receipt would be shown
        XCTAssertEqual(status, 0)
        child.sigkill()
        try attach()
        let reportedSHA = done.components(separatedBy: "sha=").last ?? ""
        let actual = try ArchiveExportService.sha256(ofFile: output).map { String(format: "%02x", $0) }.joined()
        print("DRIVE export-then-pull: writer said '\(done)'; on disk sha=\(actual)")
        XCTAssertTrue(done.contains("completed=true records=\(total)"), done)
        XCTAssertEqual(actual, reportedSHA, "the bytes the receipt vouches for are on the disk after an immediate unplug")
    }
}

// MARK: - T22 restore leg: the backup's drive is pulled mid-restore

/// Plan v4 T22 (restore leg). Deterministic: the "drive" holding the backup is
/// a folder that is moved away (as an unmount makes it vanish) right after the
/// restore has read its first file. The restore must stop naming how far it got,
/// change nothing in the archive, leave no staging behind, and succeed when the
/// drive returns. A real force-detached disk image is `DriveRemovalProcessTests`
/// (MAILIN_SCALE=1); this row needs none.
final class BackupRestoreDriveRemovalTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("restore-pull-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func mail(_ i: Int) -> MBOXParser.RawEmail {
        MBOXParser.RawEmail(
            headers: ["Message-ID": "<restore-\(i)-\(UUID().uuidString)@test>", "Subject": "Restore \(i)", "From": "a@test",
                      "To": "me@test", "Date": "Mon, 2 Nov 2026 10:0\(i % 10):00 +0000"],
            rawSource: "", messageType: "email", attachments: [], timestamp: "", domains: [],
            plainBody: "body \(i)", htmlBody: "")
    }

    /// A backup on the "drive" of 3 messages (one in the blob tier) plus two
    /// self-contained source copies, so the restore has several files to place.
    private func makeBackup() async throws -> (drive: URL, backup: URL, big: MBOXParser.RawEmail, inventory: ArchiveBackupInventory) {
        let source = SQLiteEmailStore(directory: root.appendingPathComponent("source-store", isDirectory: true))
        var big = mail(2)
        big.rawSource = "Subject: Big\n\n" + String(repeating: "x", count: BlobStore.inlineThresholdBytes + 1_024)
        try await source.insertBatch([mail(0), mail(1), big], batchSize: 10)
        let sources = source.storeDirectory.appendingPathComponent(ArchiveBackup.sourcesFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: 4_096).write(to: sources.appendingPathComponent("a.mbox"))
        try Data(repeating: 0x62, count: 4_096).write(to: sources.appendingPathComponent("b.mbox"))
        let drive = root.appendingPathComponent("BackupDrive", isDirectory: true)
        let backup = drive.appendingPathComponent("mailin-backup", isDirectory: true)
        let inventory = try await ArchiveBackup.create(store: source, to: backup)
        XCTAssertTrue(inventory.files.contains { $0.kind == "blob" }, "the big message went to the blob tier")
        XCTAssertEqual(inventory.files.filter { $0.kind == "source" }.count, 2)
        return (drive, backup, big, inventory)
    }

    private func pullAfterFirstFile(_ drive: URL, to unplugged: URL) -> (String, Int, Int) -> Void {
        { _, copied, _ in
            if copied == 1 { try? FileManager.default.moveItem(at: drive, to: unplugged) }
        }
    }

    private func assertInterrupted(_ error: Error, total: Int, file: StaticString = #filePath, line: UInt = #line) {
        guard case .restoreInterrupted(let copied, let planned, _)? = error as? ArchiveBackupError else {
            return XCTFail("expected restoreInterrupted, got \(error)", file: file, line: line)
        }
        XCTAssertEqual(copied, 1, file: file, line: line)
        XCTAssertEqual(planned, total, file: file, line: line)
        let text = error.localizedDescription
        XCTAssertTrue(text.contains("1 of \(total) files"), "says how far it got: \(text)", file: file, line: line)
        XCTAssertTrue(text.contains("Nothing in the archive was changed"), text, file: file, line: line)
    }

    /// Clean profile: before, the database was placed first and the pull then
    /// failed a blob copy — a restored database without its message files, and
    /// the retry was refused as "an archive already exists".
    func testT22_drivePulledDuringCleanProfileRestore_changesNothing_retrySucceeds() async throws {
        let (drive, backup, big, inventory) = try await makeBackup()
        let unplugged = root.appendingPathComponent("unplugged", isDirectory: true)
        let target = root.appendingPathComponent("new-profile/store", isDirectory: true)

        XCTAssertThrowsError(try ArchiveBackup.restore(backup: backup, intoStoreDirectory: target, mode: .cleanProfile,
                                                       afterEachCopy: pullAfterFirstFile(drive, to: unplugged))) {
            assertInterrupted($0, total: inventory.files.count)
        }
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: target.appendingPathComponent(ArchiveBackup.databaseName).path), "no database without its files")
        XCTAssertFalse(fm.fileExists(atPath: target.appendingPathComponent(ArchiveBackup.blobsFolder).path))
        XCTAssertFalse(fm.fileExists(atPath: target.appendingPathComponent(ArchiveBackup.sourcesFolder).path))
        XCTAssertFalse(fm.fileExists(atPath: target.appendingPathComponent(ArchiveBackup.restoreStagingFolder).path), "no staging left behind")

        // The drive returns: the same restore runs to the end.
        try fm.moveItem(at: unplugged, to: drive)
        let restored = try ArchiveBackup.restore(backup: backup, intoStoreDirectory: target, mode: .cleanProfile)
        XCTAssertEqual(restored.counts.emails, 3)
        let store = SQLiteEmailStore(directory: target)
        let total = try await store.totalCount()
        XCTAssertEqual(total, 3)
        let readBack = try await store.fullEmail(id: big.id)
        XCTAssertEqual(readBack?.rawSource, big.rawSource, "the blob-tier message reads back")
        XCTAssertFalse(fm.fileExists(atPath: target.appendingPathComponent(ArchiveBackup.restoreStagingFolder).path))
    }

    /// In place (the app's restore): the running archive keeps its database
    /// byte for byte and gains no files when the backup vanishes part-way.
    func testT22_drivePulledDuringInPlaceRestore_keepsTheCurrentArchive() async throws {
        let (drive, backup, _, inventory) = try await makeBackup()
        let unplugged = root.appendingPathComponent("unplugged", isDirectory: true)
        let targetDir = root.appendingPathComponent("current-store", isDirectory: true)
        let current = SQLiteEmailStore(directory: targetDir)
        try await current.insertBatch([mail(7)], batchSize: 1)
        try await current.checkpoint()
        await current.reopenConnection()   // as the app does before it restores
        let db = targetDir.appendingPathComponent(ArchiveBackup.databaseName)
        let before = try ExportInventory.sha256(of: db)

        XCTAssertThrowsError(try ArchiveBackup.restore(backup: backup, intoStoreDirectory: targetDir, mode: .replaceDatabaseKeepFiles,
                                                       afterEachCopy: pullAfterFirstFile(drive, to: unplugged))) {
            assertInterrupted($0, total: inventory.files.count)
        }
        let fm = FileManager.default
        XCTAssertEqual(try ExportInventory.sha256(of: db), before, "the current database is untouched")
        XCTAssertFalse(fm.fileExists(atPath: targetDir.appendingPathComponent(ArchiveBackup.sourcesFolder).path), "no files were added")
        XCTAssertFalse(fm.fileExists(atPath: targetDir.appendingPathComponent(ArchiveBackup.restoreStagingFolder).path))
        let still = SQLiteEmailStore(directory: targetDir)
        let stillCount = try await still.totalCount()
        XCTAssertEqual(stillCount, 1, "the archive opens with what it had")
        await still.reopenConnection()

        try fm.moveItem(at: unplugged, to: drive)
        try ArchiveBackup.restore(backup: backup, intoStoreDirectory: targetDir, mode: .replaceDatabaseKeepFiles)
        let after = SQLiteEmailStore(directory: targetDir)
        let afterCount = try await after.totalCount()
        XCTAssertEqual(afterCount, 3)
        XCTAssertTrue(fm.fileExists(atPath: targetDir.appendingPathComponent("sources/a.mbox").path))
    }
}
