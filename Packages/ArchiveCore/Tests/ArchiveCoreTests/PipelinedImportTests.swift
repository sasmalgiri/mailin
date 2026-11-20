//
//  PipelinedImportTests.swift
//  ArchiveCoreTests
//
//  PERF-04 (owner instruction 2026-11-19 §5): parse the next batch while the
//  database writes the current one — one prepared batch ahead, with
//  backpressure; ordering, atomic checkpoints, cancellation and restart
//  preserved.
//
//   • the sink returns from `send` before the write finishes, the next
//     `send` waits for it (one in flight), bodies run serially and in order,
//     a failed write stops the parser within one batch;
//   • cancelling the task that waits cancels the write in flight;
//   • an import through the coordinator keeps every message, the source
//     order and the Message-ID set, and a cancelled import resumes exactly.
//

import XCTest
import Foundation
import SQLite3
@testable import ArchiveCore

final class PipelinedImportTests: XCTestCase {
    private struct WriteFailed: Error {}

    private actor EventLog {
        var events: [String] = []
        func add(_ event: String) { events.append(event) }
    }

    // MARK: - The sink

    func testSink_overlapsOneBatch_keepsOrder_andSurfacesTheWriteErrorAtTheNextSend() async throws {
        let log = EventLog()
        let sink = PipelinedBatchSink<Int> { n in
            await log.add("start \(n)")
            try await Task.sleep(for: .milliseconds(80))
            if n == 3 { throw WriteFailed() }
            await log.add("end \(n)")
        }
        let clock = ContinuousClock()
        let t0 = clock.now
        try await sink.send(1)
        XCTAssertLessThan(clock.now - t0, .milliseconds(40), "send returns while the first write is still running")
        try await sink.send(2)
        XCTAssertGreaterThanOrEqual(clock.now - t0, .milliseconds(75), "the second send waited for the first write (one in flight)")
        try await sink.drain()
        var events = await log.events
        XCTAssertEqual(events, ["start 1", "end 1", "start 2", "end 2"], "serial, in order")

        try await sink.send(3)                       // this write fails
        do {
            try await sink.send(4)
            XCTFail("the failed write must surface at the next send")
        } catch is WriteFailed {}
        try await sink.drain()                       // nothing left in flight; the error is not thrown twice
        events = await log.events
        XCTAssertFalse(events.contains("start 4"), "nothing after the failure was written")
    }

    func testSink_cancellingTheWaiter_cancelsTheWriteInFlight() async throws {
        let sink = PipelinedBatchSink<Int> { _ in try await Task.sleep(for: .seconds(3)) }
        try await sink.send(1)
        let waiter = Task { try await sink.drain() }
        try await Task.sleep(for: .milliseconds(50))
        let clock = ContinuousClock()
        let t0 = clock.now
        waiter.cancel()
        do {
            try await waiter.value
            XCTFail("a cancelled wait must throw")
        } catch is CancellationError {}
        XCTAssertLessThan(clock.now - t0, .seconds(1), "the 3 s write was cancelled, not waited out")
    }

    // MARK: - Through the coordinator

    private func writeMBOX(messages: Int, at root: URL) throws -> (url: URL, ids: Set<String>) {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var text = ""
        var ids = Set<String>()
        for i in 0..<messages {
            let id = "<pipe-\(i)-\(UUID().uuidString)@example.com>"
            ids.insert(id)
            text += """
            From a@example.com Mon Jan  6 10:00:00 2025
            Message-ID: \(id)
            From: Asha <asha@example.com>
            To: ravi@example.org
            Subject: Pipeline \(i)
            Date: Mon, 6 Jan 2025 10:00:00 +0530

            body \(i) \(String(repeating: "word ", count: 30))

            """
        }
        let url = root.appendingPathComponent("pipeline.mbox")
        try Data(text.utf8).write(to: url)
        return (url, ids)
    }

    private func sideStrings(_ sql: String, in storeDir: URL) -> [String] {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(storeDir.appendingPathComponent("emails.db").path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db = handle else { return [] }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { out.append(String(cString: c)) }
        }
        return out
    }

    func testImportWithLookahead_keepsOrderAndCounts_andACancelledImportResumesExactly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pipelined-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (mbox, ids) = try writeMBOX(messages: 2_400, at: root)
        var options = BulkImportCoordinator.Options()
        options.enforceStoragePreflight = false
        options.useOffsetEngine = true
        options.recordLocators = true
        options.adaptiveBatching = false
        options.batchSize = 200

        // 1. A complete import: every message, in source order, once.
        let storeDir = root.appendingPathComponent("store", isDirectory: true)
        let store = SQLiteEmailStore(directory: storeDir)
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts", isDirectory: true))
        let coordinator = await BulkImportCoordinator(store: store, fts: fts, checkpoints: ImportCheckpointStore(store: store),
                                                      requiresStorageActivation: false)
        let summary = try await coordinator.runImport(urls: [mbox], options: options)
        XCTAssertEqual(summary.parsed, 2_400)
        XCTAssertEqual(summary.persistFailed, 0)
        let total = try await store.totalCount()
        XCTAssertEqual(total, 2_400)
        let ordinals = sideStrings("SELECT source_ordinal FROM emails ORDER BY source_ordinal;", in: storeDir).compactMap(Int.init)
        XCTAssertEqual(ordinals, Array(0..<2_400), "source ordinals are contiguous and in order")
        let stored = Set(sideStrings("SELECT message_id FROM emails;", in: storeDir))
        XCTAssertEqual(stored, ids, "the Message-ID set is exactly the source's")

        // 2. Cancelled after the first committed batch, then resumed: exact.
        final class TaskBox: @unchecked Sendable { var task: Task<BulkImportCoordinator.RunSummary, Error>? }
        let storeDir2 = root.appendingPathComponent("store2", isDirectory: true)
        let store2 = SQLiteEmailStore(directory: storeDir2)
        let fts2 = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts2", isDirectory: true))
        let first = await BulkImportCoordinator(store: store2, fts: fts2, checkpoints: ImportCheckpointStore(store: store2),
                                                requiresStorageActivation: false)
        let box = TaskBox()
        var callbacks = BulkImportCoordinator.Callbacks()
        callbacks.onCommittedBatch = { _ in box.task?.cancel() }
        box.task = Task { try await first.runImport(urls: [mbox], options: options, callbacks: callbacks) }
        var cancelled = false
        if let task = box.task {
            do { _ = try await task.value } catch is CancellationError { cancelled = true } catch {}
        }
        XCTAssertTrue(cancelled)
        let partial = try await store2.totalCount()
        XCTAssertGreaterThan(partial, 0)
        XCTAssertLessThan(partial, 2_400, "the cancelled run stopped part-way")
        XCTAssertEqual(partial % 200, 0, "whole batches only: the write in flight was finished or rolled back, never half-committed")

        let second = await BulkImportCoordinator(store: store2, fts: fts2, checkpoints: ImportCheckpointStore(store: store2),
                                                 requiresStorageActivation: false)
        _ = try await second.runImport(urls: [mbox], options: options)
        let resumed = try await store2.totalCount()
        XCTAssertEqual(resumed, 2_400, "resume completes the file")
        let ordinals2 = sideStrings("SELECT source_ordinal FROM emails ORDER BY source_ordinal;", in: storeDir2).compactMap(Int.init)
        XCTAssertEqual(ordinals2, Array(0..<2_400), "no gap and no repeat across the cancel / resume boundary")
        XCTAssertEqual(Set(sideStrings("SELECT message_id FROM emails;", in: storeDir2)), ids)
    }

    /// The rollback switch: `overlapBatches = false` is the sequential schedule
    /// of before, and both schedules store exactly the same rows, ordinals and
    /// byte locators from the same file.
    func testOverlapOnAndOff_storeTheSameRowsOrdinalsAndLocators() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (mbox, ids) = try writeMBOX(messages: 1_100, at: root)
        var rows: [Bool: Set<String>] = [:]
        for overlap in [true, false] {
            let dir = root.appendingPathComponent(overlap ? "on" : "off", isDirectory: true)
            let store = SQLiteEmailStore(directory: dir.appendingPathComponent("store", isDirectory: true))
            let fts = FTSSearchIndex(shardsDirectory: dir.appendingPathComponent("fts", isDirectory: true))
            let coordinator = await BulkImportCoordinator(store: store, fts: fts, checkpoints: ImportCheckpointStore(store: store),
                                                          requiresStorageActivation: false)
            var options = BulkImportCoordinator.Options()
            options.enforceStoragePreflight = false
            options.useOffsetEngine = true
            options.recordLocators = true
            options.adaptiveBatching = false
            options.batchSize = 150
            options.overlapBatches = overlap
            let summary = try await coordinator.runImport(urls: [mbox], options: options)
            XCTAssertEqual(summary.parsed, 1_100, "overlap \(overlap)")
            let joined = sideStrings("""
                SELECT e.message_id || '|' || e.source_ordinal || '|' || l.msg_offset || '|' || l.msg_length || '|' || l.body_offset || '|' || l.body_length
                FROM emails e JOIN message_locators l ON l.email_id = e.id;
                """, in: dir.appendingPathComponent("store", isDirectory: true))
            XCTAssertEqual(joined.count, 1_100, "every row has its locator (overlap \(overlap))")
            rows[overlap] = Set(joined)
        }
        XCTAssertEqual(rows[true], rows[false], "both schedules produce the same rows, ordinals and locators")
        XCTAssertEqual(Set(rows[true]!.map { String($0.split(separator: "|")[0]) }), ids)
    }
}
