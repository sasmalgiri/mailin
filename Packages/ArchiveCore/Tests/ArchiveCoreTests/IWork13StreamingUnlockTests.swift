//
//  IWork13StreamingUnlockTests.swift
//  ArchiveCoreTests
//
//  CLOSE-03 (plan §1.3 CUR-05, CUR-06).
//
//  CUR-05 — `IWork13Encryption.unlock` used to keep every decrypted IWA member
//  in memory and build one in-memory ZIP: a per-member guard does not bound
//  their sum. These tests build a synthetic protected document with MANY
//  members from the published scheme (test-only writer below, a known
//  password) and check that the unlock's peak memory stays bounded, that a
//  cancellation and a full disk stop it with a named error, and that nothing
//  half-written is left in scratch. The real Pages / Numbers / Keynote files
//  (`IWorkPasswordFixtureTests`) stay the correctness oracle.
//
//  CUR-06 — password check, parse and integrity are three facts. A flipped
//  cipher-text byte where it is detectable gives a named damaged/unreadable
//  result, never silently wrong text; a flipped trailer byte still opens
//  (the trailer is not checked) and the reading's note says so.
//

import XCTest
import Foundation
import CryptoKit
import Darwin
@testable import ArchiveCore

final class IWork13StreamingUnlockTests: XCTestCase {

    static let password = "Harbour-Ledger-77"

    // MARK: - A test-only writer of the scheme (IWork13Encryption.swift header)

    struct Synthetic {
        let url: URL
        let key: [UInt8]
        let memberCount: Int
        let memberPlainBytes: Int
        func plain(_ index: Int) -> Data { Self.plain(index, bytes: memberPlainBytes) }
        static func plain(_ index: Int, bytes: Int) -> Data {
            var d = Data(count: bytes)
            d.withUnsafeMutableBytes { raw in
                let p = raw.bindMemory(to: UInt8.self)
                for i in 0..<bytes { p[i] = UInt8(truncatingIfNeeded: (i &* 31) ^ (index &* 131) ^ (i >> 8)) }
            }
            return d
        }
    }

    static func verifierBytes(password: String, iterations: UInt32 = 1_000) throws -> (bytes: Data, key: [UInt8]) {
        let salt = (0..<16).map { _ in UInt8.random(in: 0...255) }
        let iv = (0..<16).map { _ in UInt8.random(in: 0...255) }
        let key = CryptoPrimitives.pbkdf2SHA1(password: password, salt: salt, rounds: iterations, length: 16)
        let check = (0..<32).map { _ in UInt8.random(in: 0...255) }
        let blob = try CryptoPrimitives.aesCBC(check + Array(SHA256.hash(data: check)), key: key, iv: iv, encrypt: true)
        var out = Data([2, 0, 1, 0])
        withUnsafeBytes(of: iterations.littleEndian) { out.append(contentsOf: $0) }
        out.append(contentsOf: salt); out.append(contentsOf: iv); out.append(contentsOf: blob)
        XCTAssertEqual(out.count, 104)
        return (out, key)
    }

    /// 16 bytes, IV, AES-128-CBC(PKCS#7) cipher text, 20 trailing bytes.
    static func protectedMember(_ plain: Data, key: [UInt8]) throws -> Data {
        let pad = 16 - plain.count % 16
        let padded = [UInt8](plain) + [UInt8](repeating: UInt8(pad), count: pad)
        let iv = (0..<16).map { _ in UInt8.random(in: 0...255) }
        var out = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        out.append(contentsOf: iv)
        out.append(contentsOf: try CryptoPrimitives.aesCBC(padded, key: key, iv: iv, encrypt: true))
        out.append(contentsOf: Insecure.SHA1.hash(data: plain))   // 20 bytes; not what Apple writes, and not checked
        return out
    }

    /// The document, written member by member through the file-backed writer
    /// (so building it does not itself hold the members in memory).
    func makeSynthetic(members: Int, plainBytes: Int, in dir: URL) throws -> Synthetic {
        let url = dir.appendingPathComponent("synthetic-protected.pages")
        let writer = try StreamingZIPWriter(destination: url)
        let (verifier, key) = try Self.verifierBytes(password: Self.password)
        let spool = dir.appendingPathComponent("spool.bin")
        func add(_ name: String, _ data: Data) throws {
            try data.write(to: spool)
            try writer.addStored(name: name, contentsOf: spool, size: UInt64(data.count), crc: ZIPArchiveReader.CRC32.checksum(data))
        }
        try add(IWork13Encryption.verifierName, verifier)
        for i in 0..<members {
            try autoreleasepool {
                try add(String(format: "Index/Member-%05d.iwa", i), try Self.protectedMember(Synthetic.plain(i, bytes: plainBytes), key: key))
            }
        }
        try add("Metadata/Properties.plist", Data("plain metadata".utf8))
        try writer.finish()
        try? FileManager.default.removeItem(at: spool)
        return Synthetic(url: url, key: key, memberCount: members, memberPlainBytes: plainBytes)
    }

    private var work: URL!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent("iwork13-stream-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: work)
        super.tearDown()
    }

    func freshScratch() throws -> URL {
        let s = work.appendingPathComponent("scratch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: s, withIntermediateDirectories: true)
        return s
    }

    func leftovers(_ dir: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    }

    // MARK: - Peak memory (phys_footprint sampled while the unlock runs)

    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }

    final class PeakSampler {
        private let lock = NSLock()
        private var running = true
        private var peak: UInt64 = 0
        private var thread: Thread?
        func start() {
            peak = IWork13StreamingUnlockTests.footprint()
            let t = Thread { [unowned self] in
                while true {
                    let now = IWork13StreamingUnlockTests.footprint()
                    self.lock.lock()
                    if now > self.peak { self.peak = now }
                    let go = self.running
                    self.lock.unlock()
                    if !go { break }
                    usleep(1_000)
                }
            }
            thread = t; t.start()
        }
        func stop() -> UInt64 {
            let now = IWork13StreamingUnlockTests.footprint()
            lock.lock(); running = false; if now > peak { peak = now }; let p = peak; lock.unlock()
            usleep(5_000)
            return p
        }
    }

    /// 400 members × 128 KiB = 50 MiB of plain text: held in memory, the old
    /// unlock grew by about three times that (305 MiB for 800 members, measured
    /// 2026-11-09). Streamed, the growth is a few MiB whatever the member count.
    func testUnlock_manyMembers_peakMemoryBounded_andEveryMemberRoundTrips() throws {
        let synthetic = try makeSynthetic(members: 400, plainBytes: 128 * 1024, in: work)
        let members = try ZIPArchiveReader.members(of: synthetic.url)
        let scratch = try freshScratch()
        let sampler = PeakSampler()
        let before = Self.footprint()
        sampler.start()
        let unlocked = try autoreleasepool {
            try IWork13Encryption.unlock(fileURL: synthetic.url, members: members, password: Self.password, scratch: scratch,
                                         limit: ExtractionLimits.effective.partBytes)
        }
        let peak = sampler.stop()
        let growth = peak > before ? peak - before : 0
        let total = UInt64(synthetic.memberCount * synthetic.memberPlainBytes)
        XCTAssertLessThan(growth, 32 << 20, "peak growth \(growth >> 20) MiB while unlocking \(total >> 20) MiB in \(synthetic.memberCount) members")
        XCTAssertTrue(unlocked.skipped.isEmpty, "\(unlocked.skipped)")

        let plainMembers = try ZIPArchiveReader.members(of: unlocked.url)
        XCTAssertEqual(plainMembers.count, synthetic.memberCount, "every IWA member, nothing else")
        for i in [0, 1, 199, synthetic.memberCount - 1] {
            let name = String(format: "Index/Member-%05d.iwa", i)
            let member = try XCTUnwrap(plainMembers.first { $0.name == name })
            XCTAssertEqual(try DocumentTextExtractor.memberData(member, from: unlocked.url, scratch: scratch), synthetic.plain(i), name)
        }
        XCTAssertEqual(Set(leftovers(scratch)), [unlocked.url.lastPathComponent], "only the unlocked ZIP remains in scratch")
    }

    // MARK: - Cancellation

    func testUnlock_cancelledPartWay_throwsCancellation_leavesNothingInScratch() throws {
        let synthetic = try makeSynthetic(members: 40, plainBytes: 4096, in: work)
        let members = try ZIPArchiveReader.members(of: synthetic.url)
        let scratch = try freshScratch()
        var asked = 0
        XCTAssertThrowsError(try IWork13Encryption.unlock(fileURL: synthetic.url, members: members, password: Self.password, scratch: scratch,
                                                          limit: ExtractionLimits.effective.partBytes,
                                                          isCancelled: { asked += 1; return asked > 25 })) { error in
            XCTAssertTrue(error is CancellationError, "cancellation, not a failure: \(error)")
        }
        XCTAssertGreaterThan(asked, 25, "asked per member / block, so the stop came part-way")
        XCTAssertEqual(leftovers(scratch), [], "no partial ZIP, no member files left behind")
    }

    // MARK: - Disk full (injected write failure)

    /// Stands in for a volume that fills up after `capacity` bytes in total.
    final class FillingDisk {
        var capacity: Int
        init(capacity: Int) { self.capacity = capacity }
        final class Sink: ZIPByteSink {
            let disk: FillingDisk; let inner: FileZIPSink
            init(_ disk: FillingDisk, _ url: URL) throws { self.disk = disk; inner = try FileZIPSink(url: url) }
            func write(_ data: Data) throws {
                guard disk.capacity >= data.count else { throw POSIXError(.ENOSPC) }
                disk.capacity -= data.count
                try inner.write(data)
            }
            func close() throws { try inner.close() }
        }
        func factory() -> StreamingZIPWriter.SinkFactory { { [unowned self] url in try Sink(self, url) } }
    }

    func testUnlock_diskFillsPartWay_namedDiskFull_nothingHalfWrittenLeft() throws {
        let synthetic = try makeSynthetic(members: 30, plainBytes: 8192, in: work)
        let members = try ZIPArchiveReader.members(of: synthetic.url)
        // Fails in the middle: while decrypting a member, while copying one into the ZIP, and at the very end.
        for capacity in [10 * 8192 + 100, 2 * 8192 + 4000, 30 * 8192 * 2 + 30 * 60] {
            let scratch = try freshScratch()
            let disk = FillingDisk(capacity: capacity)
            XCTAssertThrowsError(try IWork13Encryption.unlock(fileURL: synthetic.url, members: members, password: Self.password, scratch: scratch,
                                                              limit: ExtractionLimits.effective.partBytes, makeSink: disk.factory())) { error in
                guard case IWork13Encryption.UnlockError.diskFull(let member)? = error as? IWork13Encryption.UnlockError else {
                    return XCTFail("capacity \(capacity): expected diskFull, got \(error)")
                }
                XCTAssertFalse(member.isEmpty)
                XCTAssertTrue((error as? LocalizedError)?.errorDescription?.contains("the disk is full (nothing was kept)") == true,
                              "\((error as? LocalizedError)?.errorDescription ?? "")")
            }
            XCTAssertEqual(leftovers(scratch), [], "capacity \(capacity): nothing half-written left: \(leftovers(scratch))")
        }
        // A non-space write failure is named as such, not as a full disk.
        XCTAssertEqual(IWork13Encryption.UnlockError.from(POSIXError(.EIO), member: "m") as? IWork13Encryption.UnlockError,
                       .writeFailed(member: "m", detail: (POSIXError(.EIO) as NSError).localizedDescription))
        XCTAssertEqual(IWork13Encryption.UnlockError.from(CocoaError(.fileWriteOutOfSpace), member: "m") as? IWork13Encryption.UnlockError,
                       .diskFull(member: "m"))
    }

    // MARK: - The writer itself: member count past the 16-bit field (ZIP64)

    func testStreamingWriter_moreThan65535Members_readBackThroughZIP64() throws {
        let url = work.appendingPathComponent("many.zip")
        let source = work.appendingPathComponent("one.bin")
        let bytes = Data("x".utf8)
        try bytes.write(to: source)
        let writer = try StreamingZIPWriter(destination: url)
        let count = 70_000
        for i in 0..<count {
            try writer.addStored(name: "m/\(i)", contentsOf: source, size: 1, crc: ZIPArchiveReader.CRC32.checksum(bytes))
        }
        try writer.finish()
        let members = try ZIPArchiveReader.members(of: url)
        XCTAssertEqual(members.count, count)
        XCTAssertEqual(members.last?.name, "m/\(count - 1)")
        XCTAssertEqual(Set(leftovers(work)), ["many.zip", "one.bin"], "spooled directory and .partial gone")
    }

    // MARK: - CUR-06: corruption against the real Pages fixture

    static let pagesFixture = IWorkPasswordFixtureTests.fixtures.appendingPathComponent("pages-protected.pages")

    /// The real document with one byte of Index/Document.iwa changed at
    /// `offset(storedCount)` — rebuilt with fresh ZIP CRCs, so only the
    /// encryption layer can notice.
    func damaged(_ offset: (Int) -> Int) throws -> URL {
        let members = try ZIPArchiveReader.members(of: Self.pagesFixture)
        let scratch = try freshScratch()
        var entries: [MiniZIPWriter.Entry] = []
        var hit = false
        for m in members where !m.isDirectory {
            var data = try DocumentTextExtractor.memberData(m, from: Self.pagesFixture, scratch: scratch)
            if m.name == "Index/Document.iwa" {
                let at = offset(data.count)
                data[data.startIndex + at] ^= 0x01
                hit = true
            }
            entries.append(.init(name: m.name, data: data, deflate: false))
        }
        XCTAssertTrue(hit)
        let url = work.appendingPathComponent("damaged-\(UUID().uuidString).pages")
        try MiniZIPWriter.archive(entries).write(to: url)
        return url
    }

    func read(_ url: URL) throws -> OfficeTextExtractor.Result {
        try DocumentTextExtractor.extract(fileURL: url, kind: .pages, logicalName: "damaged.pages", password: IWorkPasswordFixtureTests.password)
    }

    func testIntact_opensWithTheIntegrityNote_passwordAndParseAreNotAuthenticity() throws {
        let opened = try DocumentTextExtractor.extract(fileURL: Self.pagesFixture, kind: .pages, logicalName: "p.pages",
                                                       password: IWorkPasswordFixtureTests.password)
        XCTAssertTrue(opened.text.contains("The quorum clause lighthouse stands at the harbour."))
        XCTAssertEqual(opened.notes, [IWork13Encryption.integrityNote])
        XCTAssertTrue(opened.notes[0].contains("not cryptographically verified"))
        XCTAssertFalse(opened.notes.joined().contains("authenticated"), "never labelled authenticated")
        XCTAssertTrue(opened.skipped.isEmpty, "a note is not a skipped part: \(opened.skipped)")
        XCTAssertEqual(opened.childNote, IWork13Encryption.integrityNote, "the child row carries the note")
        // An unprotected document makes no such statement.
        let plain = try DocumentTextExtractor.extract(fileURL: IWorkPasswordFixtureTests.fixtures.appendingPathComponent("pages-plain.pages"),
                                                      kind: .pages, logicalName: "p.pages")
        XCTAssertEqual(plain.notes, [])
    }

    func testTrailerByteFlipped_stillOpens_sameText_noteSaysIntegrityUnverified() throws {
        let twin = try DocumentTextExtractor.extract(fileURL: Self.pagesFixture, kind: .pages, logicalName: "p.pages",
                                                     password: IWorkPasswordFixtureTests.password)
        let opened = try read(try damaged { $0 - 7 })     // inside the 20-byte trailer
        XCTAssertEqual(opened.text, twin.text, "the trailer is not checked, so the text is unchanged")
        XCTAssertTrue(opened.notes.contains(IWork13Encryption.integrityNote), "\(opened.notes)")
    }

    func testCipherTextByteFlipped_inTheLastBlock_namedDamaged_neverSilentlyWrongText() throws {
        // The last byte of the second-to-last cipher block: CBC flips the last
        // plain byte, i.e. the padding — detectable, named with the member.
        let url = try damaged { $0 - IWork13Encryption.trailerBytes - 16 - 1 }
        XCTAssertThrowsError(try read(url)) { error in
            let text = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            XCTAssertTrue(text.contains("Index/Document.iwa"), text)
            XCTAssertTrue(text.contains("bad padding") && text.contains("damaged"), text)
        }
    }

    func testCipherTextByteFlipped_inTheFirstBlock_garbledMemberNamedNotRead() throws {
        // The first cipher block: its plain block is garbled — the IWA framing
        // the reader parses next must notice; either the reading fails with
        // the member named, or the member is listed as not read. It never
        // returns different text as if it were whole.
        let twin = try DocumentTextExtractor.extract(fileURL: Self.pagesFixture, kind: .pages, logicalName: "p.pages",
                                                     password: IWorkPasswordFixtureTests.password)
        let url = try damaged { _ in IWork13Encryption.headerBytes }
        do {
            let opened = try read(url)
            // Observed 2026-11-09: "Index/Document.iwa (IWA chunk header at 0 is not snappy)".
            XCTAssertTrue(opened.skipped.contains { $0.contains("Index/Document.iwa") },
                          "garbled member must be named as not read, not passed off as text; skipped=\(opened.skipped)")
            XCTAssertTrue(opened.partial)
            XCTAssertNotEqual(opened.text, twin.text)
            XCTAssertTrue(opened.notes.contains(IWork13Encryption.integrityNote))
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            XCTAssertNotEqual(error as? OfficeTextExtractor.ExtractError, .wrongPassword, "damage is not a wrong password: \(text)")
        }
    }
}
