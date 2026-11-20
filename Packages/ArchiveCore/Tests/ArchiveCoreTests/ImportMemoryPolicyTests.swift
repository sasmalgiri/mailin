import XCTest
import Foundation
@testable import ArchiveCore

final class ImportMemoryPolicyTests: XCTestCase {
    private let mib: UInt64 = 1_048_576

    func testHealthy16GiBDesktopUsesLargerUsefulCaches() {
        let limit = ImportMemoryPolicy.footprintLimit(physical: 16 * 1_024 * mib,
            footprint: 512 * mib, available: 8 * 1_024 * mib, desktop: true)
        XCTAssertEqual(limit, 4 * 1_024 * mib)
        let budget = ImportMemoryPolicy.storeBudget(limit: limit, constrained: false, desktop: true)
        XCTAssertEqual(budget.cacheKB, 512 * 1_024)
        XCTAssertEqual(budget.mmapBytes, 256 * 1_048_576)
        XCTAssertEqual(ImportMemoryPolicy.shardCacheKB(storeBudget: budget), 8_192)
    }

    func testOtherAppsUsingRAMReduceBudgetEvenOn16GiBMachine() {
        let limit = ImportMemoryPolicy.footprintLimit(physical: 16 * 1_024 * mib,
            footprint: 512 * mib, available: 2 * 1_024 * mib, desktop: true)
        XCTAssertEqual(limit, 1_024 * mib)
        let budget = ImportMemoryPolicy.storeBudget(limit: limit, constrained: false, desktop: true)
        XCTAssertEqual(budget.cacheKB, 128 * 1_024)
    }

    func testUnknownHeadroomAndHugeMachinesHaveConservativeCeilings() {
        XCTAssertEqual(ImportMemoryPolicy.footprintLimit(physical: 128 * 1_024 * mib,
            footprint: mib, available: nil, desktop: true), 1_024 * mib)
        XCTAssertEqual(ImportMemoryPolicy.footprintLimit(physical: 128 * 1_024 * mib,
            footprint: 512 * mib, available: 100 * 1_024 * mib, desktop: true), 8 * 1_024 * mib)
        XCTAssertEqual(ImportMemoryPolicy.footprintLimit(physical: 16 * 1_024 * mib,
            footprint: 512 * mib, available: 0, desktop: true), 512 * mib)
    }

    func testPressureAndMobileKeepSmallCaches() {
        for desktop in [false, true] {
            XCTAssertEqual(ImportMemoryPolicy.storeBudget(limit: 4 * 1_024 * mib,
                constrained: true, desktop: desktop), SQLiteEmailStore.importBudget)
        }
        XCTAssertEqual(ImportMemoryPolicy.storeBudget(limit: 4 * 1_024 * mib,
            constrained: false, desktop: false), SQLiteEmailStore.importBudget)
        XCTAssertLessThanOrEqual(ImportMemoryPolicy.footprintLimit(physical: 16 * 1_024 * mib,
            footprint: 256 * mib, available: 8 * 1_024 * mib, desktop: false), 1_024 * mib)
    }

    private func healthy() -> PressureSample {
        PressureSample(footprintBytes: 512 * mib, memoryBudgetBytes: 4 * 1_024 * mib,
            freeDiskBytes: 100 * 1_024 * mib, diskReserveBytes: 1_024 * mib)
    }

    func testSlowCommitsDoNotCollapseToEightMessages() async {
        let start = BatchEnvelope(maxMessages: 256, maxBytes: 32 * 1_048_576)
        let controller = AdaptiveBatchController(start: start)
        for _ in 0..<30 {
            let decision = await controller.next(after: .init(messages: 256, bytes: 1_024, commitSeconds: 3), sample: healthy())
            XCTAssertEqual(decision.envelope, start)
        }
    }

    func testModeratelySlowCommitsDoNotGrow() async {
        let start = BatchEnvelope(maxMessages: 256, maxBytes: 32 * 1_048_576)
        let controller = AdaptiveBatchController(start: start)
        for _ in 0..<10 {
            let decision = await controller.next(after: .init(messages: 256, bytes: 1_024, commitSeconds: 1), sample: healthy())
            XCTAssertEqual(decision.envelope, start)
        }
    }

    func testGrowthRespectsExpansionAndPressureStillBacksOff() async {
        let controller = AdaptiveBatchController(start: .init(maxMessages: 256, maxBytes: 32 * 1_048_576))
        for _ in 0..<20 {
            _ = await controller.next(after: .init(messages: 256, bytes: 1_024, commitSeconds: 0.1), sample: healthy())
        }
        let grown = await controller.envelope
        XCTAssertLessThanOrEqual(Double(grown.maxBytes) * BatchEnvelope.measuredParsedExpansion, Double(1_024 * mib))
        var warning = healthy()
        warning.memoryPressure = .warning
        let shrunk = await controller.next(after: nil, sample: warning)
        XCTAssertLessThan(shrunk.envelope!.maxBytes, grown.maxBytes)
        warning.memoryPressure = .critical
        let paused = await controller.next(after: nil, sample: warning)
        XCTAssertNotNil(paused.pauseReason)
    }

    func testBudgetSelectedBeforeFirstOpenSurvivesOpeningAndRestore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("memory-policy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteEmailStore(directory: root)
        let large = ImportMemoryPolicy.storeBudget(limit: 4 * 1_024 * mib, constrained: false, desktop: true)
        await store.setMemoryBudget(large)
        _ = try await store.totalCount()
        let opened = await store.activeBudget
        XCTAssertEqual(opened, large)
        await store.setMemoryBudget(SQLiteEmailStore.importBudget)
        let small = await store.activeBudget
        XCTAssertEqual(small, SQLiteEmailStore.importBudget)
        await store.setMemoryBudget(SQLiteEmailStore.interactiveBudget)
        let restored = await store.activeBudget
        XCTAssertEqual(restored, SQLiteEmailStore.interactiveBudget)
    }

    // MARK: - PERF-03 (owner instruction 2026-11-19 §4): browsing budgets come back

    private func writeMBOX(messages: Int, at root: URL) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var text = ""
        for i in 0..<messages {
            text += """
            From a@example.com Mon Jan  6 10:00:00 2025
            Message-ID: <budget-\(i)-\(UUID().uuidString)@example.com>
            From: Asha <asha@example.com>
            To: ravi@example.org
            Subject: Budget \(i)
            Date: Mon, 6 Jan 2025 10:00:00 +0530

            body \(i) \(String(repeating: "word ", count: 40))

            """
        }
        let url = root.appendingPathComponent("budget.mbox")
        try Data(text.utf8).write(to: url)
        return url
    }

    /// Whether the run completes, is cancelled or fails, the store is back on
    /// the interactive budget when `runImport` returns or throws — not later
    /// on a detached task, so the next browse never sees import-mode caches.
    func testBrowsingBudgetIsRestored_afterCompletion_cancellation_andFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("budget-restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteEmailStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let fts = FTSSearchIndex(shardsDirectory: root.appendingPathComponent("fts", isDirectory: true))
        func coordinator() async -> BulkImportCoordinator {
            await BulkImportCoordinator(store: store, fts: fts, checkpoints: ImportCheckpointStore(store: store),
                                        requiresStorageActivation: false)
        }
        var options = BulkImportCoordinator.Options()
        options.enforceStoragePreflight = false
        options.adaptiveBatching = true

        // 1. Completed.
        let small = try writeMBOX(messages: 12, at: root.appendingPathComponent("a"))
        let summary = try await coordinator().runImport(urls: [small], options: options)
        XCTAssertEqual(summary.parsed, 12)
        let afterRun = await store.activeBudget
        XCTAssertEqual(afterRun, SQLiteEmailStore.interactiveBudget, "completed: interactive budget back before runImport returned")

        // 2. Cancelled part-way: the first committed batch cancels the task.
        final class TaskBox: @unchecked Sendable { var task: Task<BulkImportCoordinator.RunSummary, Error>? }
        let big = try writeMBOX(messages: 3_000, at: root.appendingPathComponent("b"))
        let cancelling = await coordinator()
        let box = TaskBox()
        var callbacks = BulkImportCoordinator.Callbacks()
        callbacks.onCommittedBatch = { _ in box.task?.cancel() }
        box.task = Task { try await cancelling.runImport(urls: [big], options: options, callbacks: callbacks) }
        var cancelled = false
        if let task = box.task {
            do { _ = try await task.value } catch is CancellationError { cancelled = true } catch {}
        }
        XCTAssertTrue(cancelled, "the run was cancelled after its first committed batch")
        let afterCancel = await store.activeBudget
        XCTAssertEqual(afterCancel, SQLiteEmailStore.interactiveBudget, "cancelled: interactive budget back when runImport threw")

        // 3. Failed: a source that does not exist.
        let missing = root.appendingPathComponent("c/none.mbox")
        do { _ = try await coordinator().runImport(urls: [missing], options: options) } catch {}
        let afterFailure = await store.activeBudget
        XCTAssertEqual(afterFailure, SQLiteEmailStore.interactiveBudget, "failed: interactive budget back")
    }

    // MARK: - PERF-04: a repeated outcome is not new evidence

    /// With one batch parsed ahead the controller can be asked again before
    /// a new commit finished. The same outcome (same sequence) seen again
    /// must not count towards growth; fresh sequences still do.
    func testRepeatedOutcome_doesNotGrowTheBatch_freshOutcomesDo() async {
        let controller = AdaptiveBatchController(physicalMemory: 16 * 1_024 * mib)
        let start = await controller.envelope
        let repeated = BatchOutcome(messages: 256, bytes: 1_024, commitSeconds: 0.1, sequence: 7)
        for _ in 0..<20 {
            let decision = await controller.next(after: repeated, sample: healthy())
            XCTAssertEqual(decision.envelope, start, "the same committed batch reported again is not a healthy trend")
        }
        for n in 1...20 {
            _ = await controller.next(after: BatchOutcome(messages: 256, bytes: 1_024, commitSeconds: 0.1, sequence: 100 + n),
                                      sample: healthy())
        }
        let grown = await controller.envelope
        XCTAssertGreaterThan(grown.maxMessages, start.maxMessages, "twenty distinct healthy commits grow the batch")
    }
}
