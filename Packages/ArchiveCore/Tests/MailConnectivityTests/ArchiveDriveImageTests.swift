//
//  ArchiveDriveImageTests.swift
//  MailConnectivityTests
//
//  V4-12 rehearsals on a REAL volume (T22, T23): an APFS disk image holds
//  the archive; it is force-detached in the middle of a capture, and in a
//  second run filled until the disk is really full. Opt-in, like
//  DriveRemovalProcessTests:
//
//    MAILIN_SCALE=1 DEVELOPER_DIR=… xcrun swift test --filter ArchiveDriveImageTests
//
//  Each image is 64 MB (sparse) and deleted in tearDown.
//

import XCTest
import Foundation
import CryptoKit
@testable import MailConnectivity
@testable import ArchiveCore

final class ArchiveDriveImageTests: XCTestCase {
    private var work: URL!
    private var image: URL!
    private var mountPoint: URL!
    static let volumeName = "MailinV412"

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

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MAILIN_SCALE"] == "1",
                          "drive rehearsals are opt-in: MAILIN_SCALE=1 (creates, fills and force-detaches a 64 MB disk image)")
        work = FileManager.default.temporaryDirectory.appendingPathComponent("v412-drive-\(UUID().uuidString)", isDirectory: true)
        mountPoint = work.appendingPathComponent("mnt", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        image = work.appendingPathComponent("drive.sparseimage")
        var created = Self.run("/usr/bin/hdiutil", ["create", "-size", "64m", "-fs", "APFS", "-volname", Self.volumeName, "-type", "SPARSE", image.path])
        if created.status != 0 {
            image = work.appendingPathComponent("drive.dmg")
            created = Self.run("/usr/sbin/diskutil", ["image", "create", "blank", "--fs", "APFS", "--size", "64m", "--volumeName", Self.volumeName, image.path])
        }
        try XCTSkipUnless(created.status == 0, "could not create the disk image: \(created.output)")
        try attach()
    }

    override func tearDownWithError() throws {
        if let mountPoint { Self.run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"]) }
        if let work { try? FileManager.default.removeItem(at: work) }
    }

    private func attach() throws {
        let r = Self.run("/usr/bin/hdiutil", ["attach", image.path, "-mountpoint", mountPoint.path, "-nobrowse"])
        guard r.status == 0 else { throw NSError(domain: "hdiutil", code: Int(r.status), userInfo: [NSLocalizedDescriptionKey: r.output]) }
    }

    func record(_ id: UUID) -> ConnectedAccountRecord {
        ConnectedAccountRecord(accountID: id, provider: .gmail, issuer: "https://accounts.google.com", displayIdentity: "asha@gmail.com",
                               enabledModes: ["capture"], connectionState: "connected", createdAt: Date(), updatedAt: Date())
    }

    func engine(_ fake: FakeMailProvider, _ sink: ConnectedArchiveSink, _ storage: StorageProbe) -> SyncEngine {
        SyncEngine(adapter: fake, sink: sink, scheduler: FairDownloadScheduler(totalSlots: 4), tokens: nil, permission: { _ in },
                   backoff: LifecycleTests.noWait, storage: storage)
    }

    func capturedIDs(_ sink: ConnectedArchiveSink, account: UUID) async throws -> [String] {
        try await sink.store.remoteMessageDigests().filter { $0.account == account }.map { row in
            guard case .gmail(let id) = try ProviderMessageIdentity(key: row.key) else { return "?" }
            return id
        }
    }

    func staged(_ sink: ConnectedArchiveSink) -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: sink.stagingDirectory.path)) ?? []).filter { $0.hasPrefix("stage-") }.count
    }

    // MARK: T22 — the drive is pulled mid-capture

    func testV412_T22_realImageForceDetachedMidCapture_pausesNamingTheVolume_noSecondArchive_resumesAfterReattach() async throws {
        let storeDir = mountPoint.appendingPathComponent("archive", isDirectory: true)
        let sink = ConnectedArchiveSink(storeDirectory: storeDir)
        let fake = FakeMailProvider(pageSize: 6)
        await fake.setMaxConcurrent(1)
        await fake.addFolder("INBOX", path: "Inbox")
        for i in 0..<30 { await fake.seed("d\(i)", folders: ["INBOX"]) }
        try await sink.saveAccount(record(fake.accountID))
        let drive = try ArchiveDriveIdentity.of(storeDirectory: storeDir)
        XCTAssertEqual(drive.volumeName, Self.volumeName)
        XCTAssertNotNil(drive.volumeUUID)
        let mount = mountPoint!
        let detached = LBox<(Int32, String)?>(nil)
        await fake.on(.beforeFetchNumber(9), [.run {
            detached.set(Self.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]))
        }])
        let engine = engine(fake, sink, .guarded(by: drive, reserveBytes: 64 * 1_024))
        let first = await engine.sync()
        print("V412 drive: detach \(detached.value.map { "\($0.0) \($0.1.trimmingCharacters(in: .whitespacesAndNewlines))" } ?? "not run")")
        XCTAssertEqual(detached.value?.0, 0, "the image was force-detached mid-capture")
        XCTAssertEqual(first.outcome, .paused(.driveUnavailable), "\(first.outcome)")
        XCTAssertEqual(first.missingDrive?.volumeName, Self.volumeName, "the pause names the volume")
        XCTAssertFalse(ArchiveDriveGuard.check(drive).isPresent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeDir.appendingPathComponent("emails.db").path),
                       "no archive was created where the volume used to be mounted")
        let requests = await fake.requests
        let again = await engine.sync()
        XCTAssertEqual(again.outcome, .paused(.driveUnavailable))
        let requestsAfter = await fake.requests
        XCTAssertEqual(requestsAfter, requests)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeDir.path), "still nothing at the old path")

        // The drive comes back at the same place.
        let monitor = ArchiveDriveMonitor(drive: drive)
        try attach()
        let event = await monitor.poll()
        XCTAssertEqual(event, .returned)
        let reconcile = try await monitor.reopen(sink)
        print("V412 drive: reconcile after return \(reconcile)")
        XCTAssertEqual(reconcile.recordsMissingBytes, 0, "no committed record lost its bytes")
        let resumed = await engine.sync()
        XCTAssertTrue(resumed.outcome.isCompletion, "\(resumed.outcome)")
        let ids = try await capturedIDs(sink, account: fake.accountID)
        XCTAssertEqual(ids.count, 30); XCTAssertEqual(Set(ids).count, 30)
        for row in try await sink.store.remoteMessageDigests() {
            let bytes = try sink.store.blobStore.read(BlobReference(digest: row.digest, length: 0))
            XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), row.digest)
        }
        XCTAssertEqual(staged(sink), 0)
    }

    // MARK: T23 — the drive really fills up

    func testV412_T23_realDiskFull_pausesBeforeCheckpoint_storeIntact_resumesAfterSpaceIsFreed() async throws {
        let storeDir = mountPoint.appendingPathComponent("archive", isDirectory: true)
        let sink = ConnectedArchiveSink(storeDirectory: storeDir)
        let fake = FakeMailProvider(pageSize: 10)
        await fake.setMaxConcurrent(2)
        await fake.setPadding(256 * 1_024)
        await fake.setOmitSizeHints(true)          // like IMAP without RFC822.SIZE: the write itself finds the limit
        await fake.addFolder("INBOX", path: "Inbox")
        for i in 0..<30 { await fake.seed("f\(i)", folders: ["INBOX"]) }
        try await sink.saveAccount(record(fake.accountID))
        let drive = try ArchiveDriveIdentity.of(storeDirectory: storeDir)

        // Fill the volume, leaving about 2.5 MB.
        let filler = mountPoint.appendingPathComponent("filler.bin")
        let free = try XCTUnwrap(StorageProbe.volumeAvailableBytes(storeDir))
        let target = max(0, free - 2_621_440)
        FileManager.default.createFile(atPath: filler.path, contents: nil)
        let handle = try FileHandle(forWritingTo: filler)
        let chunk = Data(repeating: 0xA5, count: 1_048_576)
        var written: Int64 = 0
        while written + Int64(chunk.count) <= target {
            do { try handle.write(contentsOf: chunk) } catch { break }
            written += Int64(chunk.count)
        }
        try handle.synchronize(); try handle.close()
        let left = StorageProbe.volumeAvailableBytes(storeDir) ?? -1
        print("V412 disk full: volume had \(free) bytes free, filler \(written), left \(left)")

        let engine = engine(fake, sink, .guarded(by: drive, reserveBytes: 128 * 1_024))
        let paused = await engine.sync()
        print("V412 disk full: first run \(paused.outcome), receipt \(String(describing: paused.receipt))")
        guard case .paused(.diskFull) = paused.outcome else { return XCTFail("\(paused.outcome)") }
        XCTAssertFalse(paused.outcome.isCompletion)
        XCTAssertEqual(staged(sink), 0, "the spool is empty while paused")
        let capturedWhileFull = try await capturedIDs(sink, account: fake.accountID)
        XCTAssertLessThan(capturedWhileFull.count, 30)
        XCTAssertGreaterThan(capturedWhileFull.count, 0, "some mail fit before the disk filled")
        let cp = try await sink.checkpoint(accountID: fake.accountID, scope: "enum:INBOX")
        XCTAssertNotEqual(cp?.bootstrapState.hasPrefix("enumerated@"), true, "the folder was not marked done")
        for row in try await sink.store.remoteMessageDigests() {
            XCTAssertTrue(sink.store.blobStore.exists(BlobReference(digest: row.digest, length: 0)), "\(row.key): no record without bytes")
        }

        try FileManager.default.removeItem(at: filler)
        let resumed = await engine.sync()
        XCTAssertTrue(resumed.outcome.isCompletion, "\(resumed.outcome)")
        let ids = try await capturedIDs(sink, account: fake.accountID)
        XCTAssertEqual(ids.count, 30); XCTAssertEqual(Set(ids).count, 30, "each message exactly once")
        XCTAssertEqual(staged(sink), 0)
    }
}
