//
//  RelocationVolumeTests.swift
//  ArchiveCoreTests
//
//  "Archive on another volume" (Capability.externalStorage) against a REAL second
//  volume: a mounted APFS disk image standing in for an external disk (owner has
//  no physical disk, 2026-10-21). The folder-based tests in the app target prove
//  the rules; this row proves them across a volume boundary, through an eject
//  ("unplug") and a re-attach, with the real location policy (no `isUsable` stub).
//
//  The move keeps a 2 GiB free-space margin, so the image must be larger than 2 GiB:
//  Prepare:  hdiutil create -size 4g -fs APFS -volname MailinExternal -type SPARSE \
//              ~/Downloads/Mail/Scale/MailinExternal.sparseimage
//            hdiutil attach ~/Downloads/Mail/Scale/MailinExternal.sparseimage -mountpoint /Volumes/MailinExternal
//  Run:      cd Packages/ArchiveCore && TEST_RUNNER_MAILIN_SCALE=1 \
//              TEST_RUNNER_MAILIN_FAULT_VOLUME=/Volumes/MailinExternal \
//              TEST_RUNNER_MAILIN_FAULT_IMAGE=~/Downloads/Mail/Scale/MailinExternal.sparseimage \
//              xcodebuild test -scheme ArchiveCore -destination 'platform=macOS' \
//              -only-testing:ArchiveCoreTests/RelocationVolumeTests
//  First run (2026-10-21) found every move outside the sandbox failing: file paths were
//  cut by string length, and `/var/…` vs `/private/var/…` put each copy in a folder that
//  does not exist. Fixed in ArchiveRelocator.relativePath; `RelocationPathTests` always runs.
//  Unsandboxed on purpose: the app-hosted test bundle cannot write to a mounted volume.
//

import XCTest
@testable import ArchiveCore

final class RelocationVolumeTests: XCTestCase {

    private static var volume: URL? {
        guard let path = ProcessInfo.processInfo.environment["MAILIN_FAULT_VOLUME"],
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static var image: URL {
        if let path = ProcessInfo.processInfo.environment["MAILIN_FAULT_IMAGE"] { return URL(fileURLWithPath: path) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/Mail/Scale/MailinFault.sparseimage")
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MAILIN_SCALE"] == "1", "volume rows are opt-in: MAILIN_SCALE=1")
        try XCTSkipUnless(Self.volume != nil, "attach the volume first: fault_volume.sh create && fault_volume.sh attach")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.image.path), "disk image not found at \(Self.image.path)")
    }

    private func email(_ i: Int) -> MBOXParser.RawEmail {
        MBOXParser.RawEmail(
            headers: ["From": "a\(i)@example.com", "To": "b@example.com", "Subject": "Volume move \(i)",
                      "Date": "Tue, 14 Mar 2017 09:41:00 +0000", "Message-ID": "<vol-\(i)-\(UUID().uuidString)@example.com>"],
            rawSource: "Subject: Volume move \(i)\r\n\r\nbody \(i)", messageType: "email", attachments: [],
            timestamp: "Tue, 14 Mar 2017 09:41:00 +0000", domains: ["example.com"],
            plainBody: "body \(i) zebrafinch", htmlBody: "")
    }

    /// Runs hdiutil; the volume must actually come and go, not just a folder rename.
    @discardableResult
    private func hdiutil(_ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        return p.terminationStatus
    }

    func testMoveToVolume_ejectFallsBack_reattachRestores() async throws {
        let volume = try XCTUnwrap(Self.volume)
        XCTAssertFalse(volume.path.contains("/Library/Application Support/"), "refusing a production-looking path")

        // "This Mac": a temp root on the boot volume.
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("volmove-home-\(UUID().uuidString)", isDirectory: true)
        let records = FileManager.default.temporaryDirectory.appendingPathComponent("volmove-rec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        var destinationToClean: URL?
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: records)
            if let d = destinationToClean { try? FileManager.default.removeItem(at: d) }
        }

        // The two roots really are on different volumes.
        let homeVolume = try home.resourceValues(forKeys: [.volumeURLKey]).volume
        let destVolume = try volume.resourceValues(forKeys: [.volumeURLKey]).volume
        XCTAssertNotEqual(homeVolume?.standardizedFileURL, destVolume?.standardizedFileURL, "the image must be a separate volume")

        let store = SQLiteEmailStore(directory: ArchiveLayout.sqliteDirectory(under: home))
        let fts = FTSSearchIndex(shardsDirectory: ArchiveLayout.ftsDirectory(under: home))
        let emails = (0..<300).map(email)
        try await store.insertBatch(emails, batchSize: 100)
        try await fts.indexBatch(emails)

        // 1. The real policy accepts the volume and the move verifies.
        let plan = ArchiveRelocator.plan(sourceRoot: home, destinationVolume: volume)
        XCTAssertTrue(plan.canProceed, plan.refusalReason ?? "")
        XCTAssertTrue(ArchiveLocationPolicy.verdict(for: volume).isUsable)
        destinationToClean = plan.destinationRoot
        let recordStore = RelocationRecordStore(url: records.appendingPathComponent("relocation.json"))
        let locationStore = ArchiveLocationStore(url: records.appendingPathComponent("location.json"))
        let receipt = try await ArchiveRelocator.perform(plan, store: store, fts: fts,
                                                         recordStore: recordStore, locationStore: locationStore)
        XCTAssertEqual(receipt.verifiedRows, 300)
        let location = try XCTUnwrap(locationStore.load())
        XCTAssertNotNil(location.bookmark, "the volume is remembered through a bookmark, which is what survives a relaunch")

        func resolved() -> URL {
            ArchiveLayout.resolveRoot(defaultRoot: home, chosen: locationStore.load(), relocation: recordStore.load())
        }
        XCTAssertEqual(resolved().standardizedFileURL, plan.destinationRoot.standardizedFileURL,
                       "with the volume attached, the moved archive is the one used")

        // 2. Unplug: force-eject the volume.
        XCTAssertEqual(try hdiutil(["detach", volume.path, "-force"]), 0, "eject failed")
        var reattached = false
        defer { if !reattached { _ = try? hdiutil(["attach", Self.image.path, "-mountpoint", volume.path]) } }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ArchiveLayout.sqliteDirectory(under: plan.destinationRoot).path))
        XCTAssertEqual(resolved().standardizedFileURL, home.standardizedFileURL,
                       "with the disk unplugged the copy on this Mac is used — mail never vanishes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: volume.path),
                       "loading the saved location must not mount the disk again (or prompt for a password)")
        let fallbackRows = try await SQLiteEmailStore(directory: ArchiveLayout.sqliteDirectory(under: home)).totalCount()
        XCTAssertEqual(fallbackRows, 300)

        // 3. Plug back in.
        XCTAssertEqual(try hdiutil(["attach", Self.image.path, "-mountpoint", volume.path]), 0, "re-attach failed")
        reattached = true
        XCTAssertNotNil(ArchiveLocationStore.restoreAccess(to: location), "the bookmark resolves after the volume returns")
        XCTAssertEqual(resolved().standardizedFileURL, plan.destinationRoot.standardizedFileURL,
                       "after re-attaching, the moved archive is used again")

        // The archive on the volume survived the forced eject intact.
        let moved = SQLiteEmailStore(directory: ArchiveLayout.sqliteDirectory(under: plan.destinationRoot))
        let movedRows = try await moved.totalCount()
        XCTAssertEqual(movedRows, 300)
        let movedFTS = FTSSearchIndex(shardsDirectory: ArchiveLayout.ftsDirectory(under: plan.destinationRoot))
        let indexed = try await movedFTS.rowCount()
        XCTAssertEqual(indexed, 300)
        let hits = try await movedFTS.search("zebrafinch", limit: 500)
        XCTAssertEqual(hits.count, 300, "search works on the moved archive")
        try await moved.insertBatch([email(1_000)], batchSize: 1)
        let afterWrite = try await moved.totalCount()
        XCTAssertEqual(afterWrite, 301, "the moved archive accepts new mail after the re-attach")
    }
}

/// Always runs (no volume needed): the move must work when the archive's path
/// goes through a symlink. Unsandboxed, `temporaryDirectory` is `/var/folders/…`,
/// which the file enumerator reports as `/private/var/folders/…` — the case that
/// made every file land in a non-existent folder before the fix.
final class RelocationPathTests: XCTestCase {
    private func email(_ i: Int) -> MBOXParser.RawEmail {
        MBOXParser.RawEmail(
            headers: ["From": "a\(i)@example.com", "To": "b@example.com", "Subject": "Path \(i)",
                      "Date": "Tue, 14 Mar 2017 09:41:00 +0000", "Message-ID": "<path-\(i)-\(UUID().uuidString)@example.com>"],
            rawSource: "Subject: Path \(i)\r\n\r\nbody \(i)", messageType: "email", attachments: [],
            timestamp: "Tue, 14 Mar 2017 09:41:00 +0000", domains: ["example.com"],
            plainBody: "body \(i)", htmlBody: "")
    }

    func testMoveThroughASymlinkedPath_copiesVerifiesAndOpens() async throws {
        // Unsandboxed this is `/var/folders/…`, a path through the /var → /private/var symlink.
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("relocpath-\(UUID().uuidString)", isDirectory: true)
        try XCTSkipUnless(base.path.hasPrefix("/var/"), "needs the /var symlink (unsandboxed macOS)")
        let home = base.appendingPathComponent("home", isDirectory: true)
        let volume = base.appendingPathComponent("volume", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let store = SQLiteEmailStore(directory: ArchiveLayout.sqliteDirectory(under: home))
        let fts = FTSSearchIndex(shardsDirectory: ArchiveLayout.ftsDirectory(under: home))
        let emails = (0..<40).map(email)
        try await store.insertBatch(emails, batchSize: 20)
        try await fts.indexBatch(emails)

        let plan = RelocationPlan(sourceRoot: home,
                                  destinationRoot: volume.appendingPathComponent(ArchiveLayout.relocatedFolderName, isDirectory: true),
                                  archiveBytes: 1, freeBytes: .max, verdict: ArchiveLocationPolicy.verdict(for: volume), fileCount: 1)
        let receipt = try await ArchiveRelocator.perform(
            plan, store: store, fts: fts,
            recordStore: RelocationRecordStore(url: base.appendingPathComponent("relocation.json")),
            locationStore: ArchiveLocationStore(url: base.appendingPathComponent("location.json")))
        XCTAssertEqual(receipt.verifiedRows, 40)
        let moved = SQLiteEmailStore(directory: ArchiveLayout.sqliteDirectory(under: plan.destinationRoot))
        let movedRows = try await moved.totalCount()
        XCTAssertEqual(movedRows, 40)
    }
}
