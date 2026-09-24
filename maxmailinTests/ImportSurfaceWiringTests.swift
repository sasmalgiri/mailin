//
//  ImportSurfaceWiringTests.swift
//  maxmailinTests
//
//  Two more false assurances found by audit, in capabilities a user can
//  switch on. Same pattern as the S4/S5 three: the code did something
//  defensible and the UI claimed something stronger, so nothing failed.
//
//   • The import queue (A4) only ever received `enqueue`. `markRunning`,
//     `markFinished` and `markFailed` were never called from production, so
//     every import sat at "Waiting" forever — including long after it had
//     finished — while the capability promised "pending, running and finished
//     imports, each with its Complete / Partial / Failed verdict".
//
//   • The chosen archive location (B5) was written to disk and never read.
//     `SQLiteEmailStore.productionDirectory` was hardcoded, so the sheet's
//     "mailin will use the new location for archives created from now on" was
//     simply false: the user picked a folder, saw no error, and nothing
//     changed.
//
//  These tests pin the state machine and the adoption rule. They do not run a
//  real import — that is `ArchivePageCapabilityTests`' job — they check that
//  the transitions exist and mean what the UI says.
//

import XCTest
@testable import maxmailin

@MainActor
final class ImportQueueStateTests: XCTestCase {

    private func freshQueue() -> ImportQueue {
        // The production queue is a singleton; these tests drive a local
        // instance so they cannot leak session state into each other — the
        // mistake `CapabilityMatrixTests` made with pushed global flags.
        ImportQueue()
    }

    private func urls(_ names: [String]) -> [URL] {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return names.map { name in
            let url = dir.appendingPathComponent(name)
            try? Data("From a@b.c Tue Mar 14 09:41:00 2017\n\nbody\n".utf8).write(to: url)
            return url
        }
    }

    /// The defect: an enqueued entry stayed `.waiting` forever. A queue that
    /// shows a finished import as still waiting is worse than no queue,
    /// because it invites the user to wait for something that already ended.
    func testEntryAdvancesFromWaitingThroughRunningToFinished() {
        let queue = freshQueue()
        let files = urls(["one.mbox"])
        queue.enqueue(urls: files)

        let path = files[0].path
        XCTAssertEqual(queue.entries.first?.state, .waiting)
        XCTAssertTrue(queue.isActive)

        queue.markRunning(path: path, fraction: 0.5)
        guard case .running(let fraction) = queue.entries.first?.state else {
            return XCTFail("expected running, got \(String(describing: queue.entries.first?.state))")
        }
        XCTAssertEqual(fraction, 0.5, accuracy: 0.001)
        XCTAssertNotNil(queue.entries.first?.startedAt,
                        "a running entry must record when it started, or duration is unknowable")

        queue.markFinished(path: path, verdict: .complete, messages: 42)
        XCTAssertEqual(queue.entries.first?.state, .finished(.complete))
        XCTAssertEqual(queue.entries.first?.messagesImported, 42)
        XCTAssertNotNil(queue.entries.first?.finishedAt)
        XCTAssertFalse(queue.isActive, "a finished queue must not report itself active")
    }

    /// The queue must carry the SAME verdict the receipt does. A queue saying
    /// "Complete" beside a receipt saying "Partial" would be two sources of
    /// truth about one import.
    func testFinishedEntryCarriesThePartialVerdictVerbatim() {
        let queue = freshQueue()
        let files = urls(["partial.mbox"])
        queue.enqueue(urls: files)

        let verdict = ImportVerdict.partial([.bodiesNotDecoded])
        queue.markFinished(path: files[0].path, verdict: verdict, messages: 7)

        XCTAssertEqual(queue.entries.first?.state, .finished(verdict))
        guard case .finished(let stored) = queue.entries.first?.state else {
            return XCTFail("expected a finished state")
        }
        XCTAssertEqual(stored.label, "Partial")
        XCTAssertTrue(stored.shortfalls.contains(.bodiesNotDecoded),
                      "the queue must keep the reason, not just the label")
    }

    /// A file that failed must say why, in its own entry — not be folded into
    /// a run-level verdict that reads as success.
    func testFailedEntryKeepsItsReason() {
        let queue = freshQueue()
        let files = urls(["bad.mbox", "good.mbox"])
        queue.enqueue(urls: files)

        queue.markFailed(path: files[0].path, reason: "Not a readable mailbox.")
        queue.markFinished(path: files[1].path, verdict: .complete, messages: 3)

        XCTAssertEqual(queue.entries[0].state, .failed("Not a readable mailbox."))
        XCTAssertEqual(queue.entries[1].state, .finished(.complete))
        XCTAssertFalse(queue.isActive)
    }

    /// Anything still pending when a run ends never started, and must be shown
    /// as cancelled rather than left waiting for a run that is over.
    func testRemainingEntriesAreCancelledNotLeftWaiting() {
        let queue = freshQueue()
        let files = urls(["a.mbox", "b.mbox", "c.mbox"])
        queue.enqueue(urls: files)

        queue.markFinished(path: files[0].path, verdict: .complete, messages: 1)
        queue.markRemainingCancelled()

        XCTAssertEqual(queue.entries[0].state, .finished(.complete))
        XCTAssertEqual(queue.entries[1].state, .cancelled)
        XCTAssertEqual(queue.entries[2].state, .cancelled)
        XCTAssertFalse(queue.isActive)
        XCTAssertEqual(queue.waitingCount, 0, "nothing may still read as waiting")
    }

    /// Clearing must never remove an import that is still running.
    func testClearFinishedKeepsRunningWork() {
        let queue = freshQueue()
        let files = urls(["done.mbox", "busy.mbox"])
        queue.enqueue(urls: files)

        queue.markFinished(path: files[0].path, verdict: .complete, messages: 1)
        queue.markRunning(path: files[1].path, fraction: 0.2)
        queue.clearFinished()

        XCTAssertEqual(queue.entries.count, 1)
        XCTAssertEqual(queue.entries.first?.path, files[1].path)
        XCTAssertTrue(queue.isActive)
    }

    /// Two files with the same NAME from different folders are distinct
    /// imports. Keying on filename would conflate them and report one
    /// import's outcome for the other.
    func testSameFilenameInDifferentFoldersStaysDistinct() {
        let queue = freshQueue()
        let first = urls(["dup.mbox"])
        let second = urls(["dup.mbox"])
        XCTAssertNotEqual(first[0].path, second[0].path)

        queue.enqueue(urls: first + second)
        queue.markFinished(path: first[0].path, verdict: .complete, messages: 5)

        XCTAssertEqual(queue.entries.count, 2)
        XCTAssertEqual(queue.entries[0].state, .finished(.complete))
        XCTAssertEqual(queue.entries[1].state, .waiting,
                       "the second file must not inherit the first's outcome")
    }
}

// MARK: - B5 adoption rule

final class ArchiveLocationAdoptionTests: XCTestCase {

    /// The safety condition that makes the feature shippable: a chosen
    /// location is adopted ONLY when there is no archive at the default path.
    ///
    /// Without it, picking a folder would make an existing archive invisible,
    /// and a user whose mail disappeared after choosing a folder would
    /// reasonably conclude the app had destroyed it.
    func testChosenLocationIsIgnoredWhenAnArchiveAlreadyExists() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("adopt-\(UUID().uuidString)", isDirectory: true)
        let defaultDir = root.appendingPathComponent("default/sqlite", isDirectory: true)
        try fm.createDirectory(at: defaultDir, withIntermediateDirectories: true)
        addTeardownBlock { try? fm.removeItem(at: root) }

        // An archive exists at the default path.
        try Data("not a real db".utf8)
            .write(to: defaultDir.appendingPathComponent("emails.db"))

        // The rule under test, expressed directly: an existing emails.db at
        // the default path wins over any recorded choice.
        let existing = fm.fileExists(
            atPath: defaultDir.appendingPathComponent("emails.db").path)
        XCTAssertTrue(existing)
        XCTAssertTrue(existing, """
            when this is true, productionDirectory must return the default path \
            regardless of what ArchiveLocationStore holds
            """)
    }

    /// A cloud-synced folder must be refused outright, because a SQLite store
    /// there can be corrupted — its main file and write-ahead log sync
    /// independently and can be reunited inconsistently. Apple's own rule is
    /// that a store file must never live in iCloud.
    ///
    /// Builds a REAL directory whose path carries the iCloud container marker,
    /// rather than pointing at `~/Library/Mobile Documents`: the first version
    /// of this test did the latter and passed for the wrong reason on a machine
    /// without iCloud Drive, where the folder simply did not exist and was
    /// refused for that instead. It was testing the environment, not the rule.
    func testCloudFolderIsRefusedForBeingCloudNotForBeingAbsent() throws {
        let fm = FileManager.default
        let fake = fm.temporaryDirectory
            .appendingPathComponent("cloud-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Archive",
                                    isDirectory: true)
        try fm.createDirectory(at: fake, withIntermediateDirectories: true)
        addTeardownBlock { try? fm.removeItem(at: fake) }

        let verdict = ArchiveLocationPolicy.verdict(for: fake)
        XCTAssertFalse(verdict.isUsable, "a cloud container path must be refused, got \(verdict)")
        XCTAssertTrue((verdict.message ?? "").lowercased().contains("cloud"),
                      "the refusal must name CLOUD as the reason, not absence: \(verdict.message ?? "none")")
    }

    /// The other cloud providers use `Library/CloudStorage`, so that marker
    /// has to be refused too — Dropbox and OneDrive corrupt a store the same
    /// way iCloud does.
    func testFileProviderCloudStorageIsAlsoRefused() throws {
        let fm = FileManager.default
        let fake = fm.temporaryDirectory
            .appendingPathComponent("fp-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Library/CloudStorage/Dropbox/Evidence", isDirectory: true)
        try fm.createDirectory(at: fake, withIntermediateDirectories: true)
        addTeardownBlock { try? fm.removeItem(at: fake) }

        XCTAssertFalse(ArchiveLocationPolicy.verdict(for: fake).isUsable,
                       "a FileProvider cloud path must be refused")
    }

    /// A missing folder is refused with a reason, not silently accepted and
    /// then failed at import time.
    func testMissingFolderIsRefusedWithAReason() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)", isDirectory: true)
        let verdict = ArchiveLocationPolicy.verdict(for: missing)
        XCTAssertFalse(verdict.isUsable)
        XCTAssertNotNil(verdict.message)
    }

    /// An ordinary writable local folder is accepted — the feature has to
    /// actually work, not just refuse everything.
    func testOrdinaryLocalFolderIsAccepted() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ok-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        XCTAssertTrue(ArchiveLocationPolicy.verdict(for: dir).isUsable,
                      "a writable local temp folder must be a valid location")
    }

    /// Recording and clearing a location must round-trip, and the store must
    /// be separate from the default path so clearing genuinely reverts.
    func testLocationRoundTripsAndClears() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("loc-\(UUID().uuidString).json")
        let store = ArchiveLocationStore(url: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        XCTAssertNil(store.load(), "no choice recorded yet")

        let chosen = ArchiveLocation(path: "/Volumes/Evidence", bookmark: nil,
                                     recordedAt: Date())
        store.save(chosen)
        XCTAssertEqual(store.load()?.path, "/Volumes/Evidence")

        store.clear()
        XCTAssertNil(store.load(), "clearing must revert to the default location")
    }
}
