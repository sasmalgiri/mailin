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
        // …and the copy on this Mac is offered for deletion ONLY once the
        // running store has opened at the destination (F01 rule 3). Before
        // the relaunch the live root is still `home`: nothing is offered and
        // the delete is a no-op.
        XCTAssertNil(ArchiveRelocator.retiredCopyOnThisMac(defaultRoot: home, record: recordStore.load(), liveRoot: home),
                     "before relaunch the copy here is the live one")
        XCTAssertTrue(ArchiveRelocator.moveAwaitsRelaunch(defaultRoot: home, record: recordStore.load(), liveRoot: home))
        try ArchiveRelocator.deleteRetiredCopy(defaultRoot: home, record: recordStore.load(), liveRoot: home)
        XCTAssertTrue(ArchiveLayout.hasArchive(at: home), "a delete before relaunch must remove nothing")
        let stillRows = try await store.totalCount()
        XCTAssertEqual(stillRows, 50)

        XCTAssertEqual(ArchiveRelocator.retiredCopyOnThisMac(defaultRoot: home, record: recordStore.load(),
                                                             liveRoot: plan.destinationRoot), home)
        XCTAssertFalse(ArchiveRelocator.moveAwaitsRelaunch(defaultRoot: home, record: recordStore.load(),
                                                           liveRoot: plan.destinationRoot))
        try ArchiveRelocator.deleteRetiredCopy(defaultRoot: home, record: recordStore.load(), liveRoot: plan.destinationRoot)
        XCTAssertFalse(ArchiveLayout.hasArchive(at: home))
        let movedStill = try await moved.totalCount()
        XCTAssertEqual(movedStill, 50, "deleting the retired copy leaves the moved archive intact")
    }

    // MARK: F01 — the relocator can never remove what it is moving

    private struct Fixture {
        let base: URL, home: URL, volume: URL
        let store: SQLiteEmailStore, fts: FTSSearchIndex
        let recordStore: RelocationRecordStore, locationStore: ArchiveLocationStore
        func sourceHash() throws -> String {
            try ArchiveExportService.sha256(ofFile: ArchiveLayout.sqliteDirectory(under: home).appendingPathComponent("emails.db"))
                .map { String(format: "%02x", $0) }.joined()
        }
    }

    private func makeFixture(_ name: String, rows: Int = 20) async throws -> Fixture {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("reloc-\(name)-\(UUID().uuidString)", isDirectory: true)
        let home = base.appendingPathComponent("home", isDirectory: true)
        let volume = base.appendingPathComponent("volume", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        try MailinStorageEnvironment.assertNotProduction(base)
        let store = SQLiteEmailStore(directory: ArchiveLayout.sqliteDirectory(under: home))
        let fts = FTSSearchIndex(shardsDirectory: ArchiveLayout.ftsDirectory(under: home))
        let emails = (0..<rows).map(email)
        try await store.insertBatch(emails, batchSize: 10)
        try await fts.indexBatch(emails)
        return Fixture(base: base, home: home, volume: volume, store: store, fts: fts,
                       recordStore: RelocationRecordStore(url: base.appendingPathComponent("relocation.json")),
                       locationStore: ArchiveLocationStore(url: base.appendingPathComponent("location.json")))
    }

    /// Runs `perform` expecting a refusal; asserts the source is untouched.
    private func assertRefused(_ plan: RelocationPlan, _ f: Fixture, file: StaticString = #filePath, line: UInt = #line) async throws {
        let before = try f.sourceHash()
        XCTAssertNotNil(plan.refusalReason, "plan must refuse", file: file, line: line)
        XCTAssertFalse(plan.canProceed, file: file, line: line)
        do {
            _ = try await ArchiveRelocator.perform(plan, store: f.store, fts: f.fts,
                                                   recordStore: f.recordStore, locationStore: f.locationStore)
            XCTFail("perform must refuse: \(plan.destinationRoot.path)", file: file, line: line)
        } catch RelocationError.refused {
            // expected
        }
        XCTAssertTrue(ArchiveLayout.hasArchive(at: plan.sourceRoot), "source archive must still exist", file: file, line: line)
        XCTAssertEqual(try f.sourceHash(), before, "source bytes must be unchanged after a refusal", file: file, line: line)
        let rows = try await f.store.totalCount()
        XCTAssertEqual(rows, 20, file: file, line: line)
        XCTAssertNil(f.recordStore.load(), "a refused move leaves no record", file: file, line: line)
    }

    /// An archive that already lives at `<volume>/mailin-archive`, with the
    /// same volume chosen again: destination == source.
    func testRelocate_refusesTheFolderTheArchiveIsAlreadyIn() async throws {
        let f = try await makeFixture("same"); defer { try? FileManager.default.removeItem(at: f.base) }
        // Move once, legitimately.
        let first = ArchiveRelocator.plan(sourceRoot: f.home, destinationVolume: f.volume)
        _ = try await ArchiveRelocator.perform(first, store: f.store, fts: f.fts,
                                               recordStore: f.recordStore, locationStore: f.locationStore)
        // Now the archive IS at volume/mailin-archive. Choosing `volume` again
        // must refuse — this is the case that deleted the live archive.
        let relocatedStore = SQLiteEmailStore(directory: ArchiveLayout.sqliteDirectory(under: first.destinationRoot))
        let again = ArchiveRelocator.plan(sourceRoot: first.destinationRoot, destinationVolume: f.volume)
        XCTAssertEqual(again.destinationRoot.standardizedFileURL, first.destinationRoot.standardizedFileURL)
        XCTAssertNotNil(again.pathConflict)
        let hashBefore = try ArchiveExportService.sha256(ofFile: ArchiveLayout.sqliteDirectory(under: first.destinationRoot).appendingPathComponent("emails.db"))
        do {
            _ = try await ArchiveRelocator.perform(again, store: relocatedStore,
                                                   fts: FTSSearchIndex(shardsDirectory: ArchiveLayout.ftsDirectory(under: first.destinationRoot)),
                                                   recordStore: f.recordStore, locationStore: f.locationStore)
            XCTFail("must refuse moving an archive onto itself")
        } catch RelocationError.refused {}
        XCTAssertTrue(ArchiveLayout.hasArchive(at: first.destinationRoot), "the live archive must survive")
        let hashAfter = try ArchiveExportService.sha256(ofFile: ArchiveLayout.sqliteDirectory(under: first.destinationRoot).appendingPathComponent("emails.db"))
        XCTAssertEqual(hashBefore, hashAfter)
        let rows = try await relocatedStore.totalCount()
        XCTAssertEqual(rows, 20)
    }

    /// The same folder reached through a symlink must be recognised as the same place.
    func testRelocate_refusesTheSameFolderThroughASymlink() async throws {
        let f = try await makeFixture("symlink"); defer { try? FileManager.default.removeItem(at: f.base) }
        let first = ArchiveRelocator.plan(sourceRoot: f.home, destinationVolume: f.volume)
        _ = try await ArchiveRelocator.perform(first, store: f.store, fts: f.fts,
                                               recordStore: f.recordStore, locationStore: f.locationStore)
        let alias = f.base.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.volume)
        let relocatedStore = SQLiteEmailStore(directory: ArchiveLayout.sqliteDirectory(under: first.destinationRoot))
        let viaAlias = ArchiveRelocator.plan(sourceRoot: first.destinationRoot, destinationVolume: alias)
        XCTAssertNotEqual(viaAlias.destinationRoot.path, first.destinationRoot.path, "the paths differ textually…")
        XCTAssertNotNil(viaAlias.pathConflict, "…but they are the same place")
        do {
            _ = try await ArchiveRelocator.perform(viaAlias, store: relocatedStore,
                                                   fts: FTSSearchIndex(shardsDirectory: ArchiveLayout.ftsDirectory(under: first.destinationRoot)),
                                                   recordStore: f.recordStore, locationStore: f.locationStore)
            XCTFail("must refuse")
        } catch RelocationError.refused {}
        XCTAssertTrue(ArchiveLayout.hasArchive(at: first.destinationRoot))
    }

    /// Destination inside the source (choosing the archive's own root as the volume).
    func testRelocate_refusesADestinationInsideTheArchive() async throws {
        let f = try await makeFixture("nested-inside"); defer { try? FileManager.default.removeItem(at: f.base) }
        let plan = ArchiveRelocator.plan(sourceRoot: f.home, destinationVolume: f.home)
        XCTAssertTrue(plan.destinationRoot.path.hasPrefix(f.home.path))
        try await assertRefused(plan, f)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.destinationRoot.path), "nothing may be created inside the archive")
    }

    /// Source inside the destination (the archive lives in a subfolder of the chosen volume's target).
    func testRelocate_refusesADestinationThatContainsTheArchive() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("reloc-contains-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let volume = base.appendingPathComponent("volume", isDirectory: true)
        // The archive sits INSIDE what would become the destination root.
        let home = volume.appendingPathComponent(ArchiveLayout.relocatedFolderName, isDirectory: true)
            .appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try MailinStorageEnvironment.assertNotProduction(base)
        let store = SQLiteEmailStore(directory: ArchiveLayout.sqliteDirectory(under: home))
        let fts = FTSSearchIndex(shardsDirectory: ArchiveLayout.ftsDirectory(under: home))
        try await store.insertBatch((0..<20).map(email), batchSize: 10)
        let f = Fixture(base: base, home: home, volume: volume, store: store, fts: fts,
                        recordStore: RelocationRecordStore(url: base.appendingPathComponent("r.json")),
                        locationStore: ArchiveLocationStore(url: base.appendingPathComponent("l.json")))
        let plan = ArchiveRelocator.plan(sourceRoot: home, destinationVolume: volume)
        try await assertRefused(plan, f)
    }

    /// Someone else's archive at the destination is never replaced.
    func testRelocate_refusesADestinationThatAlreadyHoldsAnArchive() async throws {
        let f = try await makeFixture("occupied"); defer { try? FileManager.default.removeItem(at: f.base) }
        let occupied = f.volume.appendingPathComponent(ArchiveLayout.relocatedFolderName, isDirectory: true)
        let other = SQLiteEmailStore(directory: ArchiveLayout.sqliteDirectory(under: occupied))
        try await other.insertBatch((100..<105).map(email), batchSize: 5)
        let otherHash = try ArchiveExportService.sha256(ofFile: ArchiveLayout.sqliteDirectory(under: occupied).appendingPathComponent("emails.db"))

        let plan = ArchiveRelocator.plan(sourceRoot: f.home, destinationVolume: f.volume)
        XCTAssertTrue(plan.destinationHoldsArchive)
        try await assertRefused(plan, f)

        let otherRows = try await other.totalCount()
        XCTAssertEqual(otherRows, 5, "the existing archive at the destination is untouched")
        XCTAssertEqual(try ArchiveExportService.sha256(ofFile: ArchiveLayout.sqliteDirectory(under: occupied).appendingPathComponent("emails.db")),
                       otherHash)
    }

    /// Recheck R8: a pre-existing destination folder with ANY content is not
    /// ours to remove, whether or not it looks like an archive. Only an empty
    /// folder may be replaced.
    func testRelocate_refusesAnOccupiedDestinationFolder_andReplacesOnlyAnEmptyOne() async throws {
        let f = try await makeFixture("occupied-folder"); defer { try? FileManager.default.removeItem(at: f.base) }
        let destination = f.volume.appendingPathComponent(ArchiveLayout.relocatedFolderName, isDirectory: true)
        let sentinel = destination.appendingPathComponent("notes.txt")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("someone else's file".utf8).write(to: sentinel)

        let plan = ArchiveRelocator.plan(sourceRoot: f.home, destinationVolume: f.volume)
        XCTAssertFalse(plan.destinationHoldsArchive)
        XCTAssertTrue(plan.destinationIsOccupied)
        try await assertRefused(plan, f)
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "someone else's file", "not a byte of the foreign folder is touched")

        // An EMPTY pre-existing folder is fine.
        try FileManager.default.removeItem(at: sentinel)
        let again = ArchiveRelocator.plan(sourceRoot: f.home, destinationVolume: f.volume)
        XCTAssertFalse(again.destinationIsOccupied)
        XCTAssertNil(again.refusalReason, again.refusalReason ?? "")
        let receipt = try await ArchiveRelocator.perform(again, store: f.store, fts: f.fts,
                                                         recordStore: f.recordStore, locationStore: f.locationStore)
        XCTAssertEqual(receipt.verifiedRows, 20)
        XCTAssertTrue(ArchiveLayout.hasArchive(at: destination))
        let siblings = try FileManager.default.contentsOfDirectory(atPath: f.volume.path)
        XCTAssertEqual(siblings, [ArchiveLayout.relocatedFolderName], "staging folder must not remain: \(siblings)")
    }

    /// Third review T6: a destination folder whose contents cannot be listed
    /// is refused — emptiness must be proven, never assumed.
    func testRelocate_refusesAnUnreadableDestinationFolder() async throws {
        let f = try await makeFixture("unreadable"); defer { try? FileManager.default.removeItem(at: f.base) }
        let destination = f.volume.appendingPathComponent(ArchiveLayout.relocatedFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let secret = destination.appendingPathComponent("inside.txt")
        try Data("hidden from the lister".utf8).write(to: secret)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: destination.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path) }
        guard case .unreadable = ArchiveRelocator.directoryState(destination) else {
            // Running as root (or on a filesystem that ignores mode bits) the
            // listing succeeds; the rule cannot be exercised here.
            return
        }
        let plan = ArchiveRelocator.plan(sourceRoot: f.home, destinationVolume: f.volume)
        XCTAssertTrue(plan.destinationIsOccupied, "unreadable counts as occupied")
        XCTAssertTrue(plan.refusalReason?.contains("could not be read") == true, plan.refusalReason ?? "")
        try await assertRefused(plan, f)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        XCTAssertEqual(try String(contentsOf: secret, encoding: .utf8), "hidden from the lister", "nothing inside was touched")
    }

    /// The store handed to `perform` must be the one over the plan's source.
    func testRelocate_refusesAStoreThatIsNotTheSource() async throws {
        let f = try await makeFixture("wrong-store"); defer { try? FileManager.default.removeItem(at: f.base) }
        let elsewhere = f.base.appendingPathComponent("elsewhere", isDirectory: true)
        let otherStore = SQLiteEmailStore(directory: ArchiveLayout.sqliteDirectory(under: elsewhere))
        let plan = ArchiveRelocator.plan(sourceRoot: f.home, destinationVolume: f.volume)
        XCTAssertNil(plan.refusalReason)
        do {
            _ = try await ArchiveRelocator.perform(plan, store: otherStore, fts: f.fts,
                                                   recordStore: f.recordStore, locationStore: f.locationStore)
            XCTFail("must refuse")
        } catch RelocationError.refused {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.destinationRoot.path))
    }

    func testCanonicalPath_resolvesAliasesAndMissingTails() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("canon-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let real = base.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let alias = base.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        XCTAssertEqual(ArchiveRelocator.canonicalPath(alias), ArchiveRelocator.canonicalPath(real))
        XCTAssertEqual(ArchiveRelocator.canonicalPath(alias.appendingPathComponent("not/yet/there")),
                       ArchiveRelocator.canonicalPath(real) + "/not/yet/there")
        XCTAssertFalse(ArchiveRelocator.canonicalPath(URL(fileURLWithPath: "/tmp/x/")).hasSuffix("/"))
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
