@testable import ArchiveCore
//
//  ArchiveRelocationTests.swift
//  maxmailinTests
//
//  B5: the relocation rules and the relocator itself, on temp roots that
//  stand in for "this Mac" and "the external volume". The disk-image run
//  (`fault_volume.sh`) exercises the same code against a real second volume
//  in Phase J.
//

import XCTest
@testable import maxmailin

final class ArchiveLayoutResolutionTests: XCTestCase {

    private func tempRoot(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("layout-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func plantArchive(at root: URL) throws {
        let sqlite = ArchiveLayout.sqliteDirectory(under: root)
        try FileManager.default.createDirectory(at: sqlite, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: sqlite.appendingPathComponent("emails.db"))
    }

    func testDefaultRootWinsWithoutARecord() throws {
        let home = try tempRoot("home"); defer { try? FileManager.default.removeItem(at: home) }
        try plantArchive(at: home)
        let chosen = ArchiveLocation(path: "/Volumes/Nowhere", bookmark: nil, recordedAt: Date())
        let resolved = ArchiveLayout.resolveRoot(defaultRoot: home, chosen: chosen, relocation: nil, isUsable: { _ in true })
        XCTAssertEqual(resolved, home, "an existing archive on this Mac is never abandoned for a mere chosen location")
    }

    func testVerifiedReachableRelocationWins() throws {
        let home = try tempRoot("home"); defer { try? FileManager.default.removeItem(at: home) }
        let volume = try tempRoot("volume"); defer { try? FileManager.default.removeItem(at: volume) }
        try plantArchive(at: home)
        let destination = volume.appendingPathComponent(ArchiveLayout.relocatedFolderName, isDirectory: true)
        try plantArchive(at: destination)
        let record = RelocationRecord(sourceRoot: home.path, destinationRoot: destination.path, verifiedAt: Date(),
                                      rows: 1, bytes: 1, emailsDBSHA256: "00")
        let resolved = ArchiveLayout.resolveRoot(defaultRoot: home, chosen: nil, relocation: record, isUsable: { _ in true })
        XCTAssertEqual(resolved.standardizedFileURL, destination.standardizedFileURL)
    }

    func testDetachedRelocationFallsBackToTheCopyOnThisMac() throws {
        let home = try tempRoot("home"); defer { try? FileManager.default.removeItem(at: home) }
        try plantArchive(at: home)
        let record = RelocationRecord(sourceRoot: home.path, destinationRoot: "/Volumes/Gone/mailin-archive", verifiedAt: Date(),
                                      rows: 1, bytes: 1, emailsDBSHA256: "00")
        let resolved = ArchiveLayout.resolveRoot(defaultRoot: home, chosen: nil, relocation: record, isUsable: { _ in false })
        XCTAssertEqual(resolved, home, "a detached destination must never make the mail vanish")
    }

    func testChosenLocationUsedOnlyForANewArchive() throws {
        let home = try tempRoot("home"); defer { try? FileManager.default.removeItem(at: home) }
        let volume = try tempRoot("volume"); defer { try? FileManager.default.removeItem(at: volume) }
        let chosen = ArchiveLocation(path: volume.path, bookmark: nil, recordedAt: Date())
        let resolved = ArchiveLayout.resolveRoot(defaultRoot: home, chosen: chosen, relocation: nil, isUsable: { _ in true })
        XCTAssertEqual(resolved.standardizedFileURL,
                       volume.appendingPathComponent(ArchiveLayout.relocatedFolderName, isDirectory: true).standardizedFileURL)
    }

    /// The recorded location must come back through its BOOKMARK, not its
    /// plain path: that is what keeps an external volume reachable after a
    /// relaunch under the sandbox.
    func testChosenLocationIsRestoredThroughItsBookmark() throws {
        let chosen = try tempRoot("chosen-volume"); defer { try? FileManager.default.removeItem(at: chosen) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("location-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = ArchiveLocationStore(url: file)
        let bookmark = try XCTUnwrap(ArchiveLocationStore.bookmark(for: chosen), "a bookmark must be made for a reachable folder")
        store.save(ArchiveLocation(path: chosen.path, bookmark: bookmark, recordedAt: Date()))

        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.url.standardizedFileURL.resolvingSymlinksInPath(),
                       chosen.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertNotNil(loaded.bookmark)
        // Resolution is what proves access, not the path string.
        let access = try XCTUnwrap(ArchiveLocationStore.restoreAccess(to: loaded))
        XCTAssertEqual(URL(fileURLWithPath: access.path).standardizedFileURL.resolvingSymlinksInPath(),
                       chosen.standardizedFileURL.resolvingSymlinksInPath())
    }

    func testSQLiteAndFTSShareOneRoot() {
        let root = URL(fileURLWithPath: "/tmp/anywhere", isDirectory: true)
        XCTAssertEqual(ArchiveLayout.sqliteDirectory(under: root).deletingLastPathComponent(),
                       ArchiveLayout.ftsDirectory(under: root).deletingLastPathComponent())
    }
}

final class ArchiveRelocatorTests: XCTestCase {

    private func email(_ i: Int) -> MBOXParser.RawEmail {
        MBOXParser.RawEmail(
            headers: ["From": "a\(i)@example.com", "To": "b@example.com", "Subject": "Relocate \(i)",
                      "Date": "Tue, 14 Mar 2017 09:41:00 +0000", "Message-ID": "<reloc-\(i)-\(UUID().uuidString)@example.com>"],
            rawSource: "Subject: Relocate \(i)\r\n\r\nbody \(i)", messageType: "email", attachments: [],
            timestamp: "Tue, 14 Mar 2017 09:41:00 +0000", domains: ["example.com"],
            plainBody: "body \(i) relocation", htmlBody: "")
    }

    func testRelocate_copiesVerifiesRecordsAndOpensAtDestination() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("reloc-\(UUID().uuidString)", isDirectory: true)
        let home = base.appendingPathComponent("home", isDirectory: true)
        let volume = base.appendingPathComponent("volume", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try MailinStorageEnvironment.assertNotProduction(base)

        let store = SQLiteEmailStore(directory: ArchiveLayout.sqliteDirectory(under: home))
        let fts = FTSSearchIndex(shardsDirectory: ArchiveLayout.ftsDirectory(under: home))
        let emails = (0..<50).map(email)
        try await store.insertBatch(emails, batchSize: 25)
        try await fts.indexBatch(emails)

        let plan = ArchiveRelocator.plan(sourceRoot: home, destinationVolume: volume)
        XCTAssertGreaterThan(plan.archiveBytes, 0)
        XCTAssertTrue(plan.canProceed, plan.refusalReason ?? "")

        let recordStore = RelocationRecordStore(url: base.appendingPathComponent("relocation.json"))
        let locationStore = ArchiveLocationStore(url: base.appendingPathComponent("location.json"))
        var lastProgress: (Int64, Int64) = (0, 0)
        let receipt = try await ArchiveRelocator.perform(plan, store: store, fts: fts,
                                                         recordStore: recordStore, locationStore: locationStore,
                                                         progress: { lastProgress = ($0, $1) })
        XCTAssertEqual(receipt.verifiedRows, 50)
        XCTAssertEqual(lastProgress.0, lastProgress.1, "progress must end at the total")
        XCTAssertEqual(recordStore.load()?.destinationRoot, plan.destinationRoot.path)
        XCTAssertEqual(locationStore.load()?.path, volume.path)

        // The copy is a working archive.
        let moved = SQLiteEmailStore(directory: ArchiveLayout.sqliteDirectory(under: plan.destinationRoot))
        let movedRows = try await moved.totalCount()
        XCTAssertEqual(movedRows, 50)
        let movedFTS = FTSSearchIndex(shardsDirectory: ArchiveLayout.ftsDirectory(under: plan.destinationRoot))
        let movedIndexed = try await movedFTS.rowCount()
        XCTAssertEqual(movedIndexed, 50)

        // The original is untouched.
        let originalRows = try await store.totalCount()
        XCTAssertEqual(originalRows, 50)
        XCTAssertTrue(ArchiveLayout.hasArchive(at: home))

        // Resolution now prefers the relocated copy…
        let resolved = ArchiveLayout.resolveRoot(defaultRoot: home, chosen: locationStore.load(),
                                                 relocation: recordStore.load(), isUsable: { _ in true })
        XCTAssertEqual(resolved.standardizedFileURL, plan.destinationRoot.standardizedFileURL)
        // …and the copy on this Mac is offered for deletion only while both exist.
        XCTAssertEqual(ArchiveRelocator.retiredCopyOnThisMac(defaultRoot: home, record: recordStore.load()), home)
        try ArchiveRelocator.deleteRetiredCopy(defaultRoot: home)
        // deleteRetiredCopy reads the PRODUCTION record by default, so the
        // temp copy above is only removed when its record matches; assert via
        // the explicit helper instead of the filesystem.
    }

    func testRelocate_refusesWhenDestinationTooSmall() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("reloc-small-\(UUID().uuidString)", isDirectory: true)
        let home = base.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: ArchiveLayout.sqliteDirectory(under: home), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try Data(repeating: 1, count: 4096).write(to: ArchiveLayout.sqliteDirectory(under: home).appendingPathComponent("emails.db"))
        var plan = ArchiveRelocator.plan(sourceRoot: home, destinationVolume: base)
        plan.freeBytes = 10
        XCTAssertFalse(plan.canProceed)
        XCTAssertNotNil(plan.refusalReason)
        let store = SQLiteEmailStore(directory: ArchiveLayout.sqliteDirectory(under: home))
        let fts = FTSSearchIndex(shardsDirectory: ArchiveLayout.ftsDirectory(under: home))
        do {
            _ = try await ArchiveRelocator.perform(plan, store: store, fts: fts,
                                                   recordStore: RelocationRecordStore(url: base.appendingPathComponent("r.json")),
                                                   locationStore: ArchiveLocationStore(url: base.appendingPathComponent("l.json")))
            XCTFail("must refuse")
        } catch RelocationError.refused {
            // expected
        }
    }
}
