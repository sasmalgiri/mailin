//
//  SevenZipReaderTests.swift
//  ArchiveCoreTests
//
//  Completion directive 2026-11-07 §6 "Containers": the 7z reader on real
//  files — archives written by bsdtar/libarchive 3.7.4 (Copy, LZMA, LZMA2,
//  Deflate; BZip2 and PPMd as the named-not-opened cases; every one with an
//  LZMA2-compressed header) under Fixtures/sevenzip, and the owner's public
//  pack (7-Zip 26.05 with AES-256 and encrypted headers; libarchive's
//  encrypted regression corpus) with every member's SHA-256 compared to
//  `expected_results.json`. BCJ x86 and Delta have no local encoder, so
//  they are exercised on spec-built archives whose filter output is
//  produced by the encoder side of the same transform.
//

import XCTest
import CryptoKit
@testable import ArchiveCore

final class SevenZipReaderTests: XCTestCase {

    // MARK: - Fixture locations and oracle

    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/sevenzip")
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let publicPack = repoRoot.appendingPathComponent("maxmailinTests/Fixtures/opensource/public-pack")

    /// SHA-256 of the files bsdtar was given (recorded when the fixtures were made).
    static let inputHashes: [String: String] = [
        "README.txt": "b0496e51b4b1c7bfe88079516b82d699df0ff8c45a199a8a055462007333ee28",
        "nested/large.txt": "c828085aebc8918154e834078b2873c57b94f96485d0071727ab76e8aefff810",
        "nested/notes.txt": "2733eff9e77a475758e3c2973e40e961361592dfc271b6cbd245c49e966c9833",
    ]

    struct OracleMember: Decodable { let path: String; let bytes: Int; let sha256: String }
    struct OracleArchive: Decodable { let path: String; let password: String?; let members: [OracleMember] }
    struct Oracle: Decodable { let archives: [OracleArchive] }

    static func oracle(for relativePath: String) throws -> OracleArchive {
        let data = try Data(contentsOf: publicPack.appendingPathComponent("expected_results.json"))
        let oracle = try JSONDecoder().decode(Oracle.self, from: data)
        return try XCTUnwrap(oracle.archives.first { $0.path == relativePath }, "no oracle entry for \(relativePath)")
    }

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("sevenzip-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: scratch); super.tearDown() }

    private func extractToData(_ reader: SevenZipReader, _ member: SevenZipReader.Member, maxOutputBytes: Int64? = nil) throws -> Data {
        let url = scratch.appendingPathComponent(UUID().uuidString)
        try reader.extract(member, to: url, maxOutputBytes: maxOutputBytes)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Data(contentsOf: url)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - bsdtar fixtures: every method, members byte-exact

    private func checkBsdtarArchive(_ name: String, expectedMethod: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let reader = try SevenZipReader(url: Self.fixtures.appendingPathComponent(name))
        XCTAssertTrue(reader.isHeaderEncrypted == false, file: file, line: line)
        let files = reader.members.filter { !$0.isDirectory }
        XCTAssertEqual(Set(files.map(\.name)), Set(Self.inputHashes.keys), "\(name) lists every file", file: file, line: line)
        for member in files {
            XCTAssertEqual(member.method, expectedMethod, "\(name): \(member.name)", file: file, line: line)
            XCTAssertNil(member.unsupportedMethod, file: file, line: line)
            XCTAssertFalse(member.isEncrypted, file: file, line: line)
            let data = try extractToData(reader, member)
            XCTAssertEqual(Int64(data.count), member.size, "\(name): \(member.name) size", file: file, line: line)
            XCTAssertEqual(Self.sha256(data), Self.inputHashes[member.name], "\(name): \(member.name) bytes", file: file, line: line)
        }
    }

    func testCopyArchive_everyMemberByteExact() throws { try checkBsdtarArchive("copy.7z", expectedMethod: "Copy") }
    func testLZMAArchive_everyMemberByteExact() throws { try checkBsdtarArchive("lzma1.7z", expectedMethod: "LZMA") }
    func testLZMA2Archive_everyMemberByteExact() throws { try checkBsdtarArchive("lzma2.7z", expectedMethod: "LZMA2") }
    func testDeflateArchive_everyMemberByteExact() throws { try checkBsdtarArchive("deflate.7z", expectedMethod: "Deflate") }

    func testSolidFolder_membersInOrderAndOutOfOrder() throws {
        // bsdtar writes one solid folder: in order the folder is decoded once; out of order it restarts and still matches.
        let reader = try SevenZipReader(url: Self.fixtures.appendingPathComponent("lzma2.7z"))
        let files = reader.members.filter { !$0.isDirectory }
        XCTAssertEqual(Set(files.map(\.folderIndex)), [0], "a single solid folder")
        for member in files.reversed() {
            XCTAssertEqual(Self.sha256(try extractToData(reader, member)), Self.inputHashes[member.name])
        }
        // Twice the same member: the cached stream is past it, so the folder restarts.
        let first = try XCTUnwrap(files.first)
        XCTAssertEqual(Self.sha256(try extractToData(reader, first)), Self.inputHashes[first.name])
        XCTAssertEqual(Self.sha256(try extractToData(reader, first)), Self.inputHashes[first.name])
    }

    func testBZip2AndPPMd_namedNotOpened() throws {
        for (name, method) in [("bzip2.7z", "BZip2"), ("ppmd.7z", "PPMd")] {
            let reader = try SevenZipReader(url: Self.fixtures.appendingPathComponent(name))
            let files = reader.members.filter { !$0.isDirectory }
            XCTAssertEqual(files.count, 2, name)
            for member in files {
                XCTAssertEqual(member.unsupportedMethod, method, name)
                XCTAssertEqual(member.method, method, name)
                XCTAssertThrowsError(try extractToData(reader, member)) { error in
                    XCTAssertEqual(error as? SevenZipReader.ReadError, .unsupportedMethod(method, member: member.name))
                }
            }
        }
    }

    // MARK: - Ceilings: stated, never silent

    func testBudgetStopsInsideDecoding() throws {
        let reader = try SevenZipReader(url: Self.fixtures.appendingPathComponent("lzma2.7z"))
        let large = try XCTUnwrap(reader.members.first { $0.name == "nested/large.txt" })
        let url = scratch.appendingPathComponent("budget")
        XCTAssertThrowsError(try reader.extract(large, to: url, maxOutputBytes: 10_000)) { error in
            XCTAssertEqual(error as? SevenZipReader.ReadError, .budgetExceeded(member: "nested/large.txt", limit: 10_000))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "partial output removed")
        // The folder is decoded again from the start on the next request and still comes out right.
        XCTAssertEqual(Self.sha256(try extractToData(reader, large)), Self.inputHashes["nested/large.txt"])
    }

    func testDictionaryOverTheGuardIsStatedAndResumable() throws {
        // 8 KiB: enough for the (small) compressed header's window, not for the 150 KB solid folder.
        let reader = try SevenZipReader(url: Self.fixtures.appendingPathComponent("lzma2.7z"), dictionaryLimit: 8_192)
        let readme = try XCTUnwrap(reader.members.first { $0.name == "README.txt" })
        XCTAssertThrowsError(try extractToData(reader, readme)) { error in
            guard case .dictionaryOverLimit(let member, let needed, let limit)? = error as? SevenZipReader.ReadError else {
                return XCTFail("expected dictionaryOverLimit, got \(error)")
            }
            XCTAssertEqual(member, "README.txt")
            XCTAssertEqual(limit, 8_192)
            XCTAssertGreaterThan(needed, 8_192)
            XCTAssertTrue(ExtractionLimits.noteNamesALimit("\(error)"), "the note names a ceiling so Resume picks it up")
        }
        // A larger guard (as Resume grants) opens it.
        let resumed = try SevenZipReader(url: Self.fixtures.appendingPathComponent("lzma2.7z"), dictionaryLimit: 1 << 20)
        XCTAssertEqual(Self.sha256(try extractToData(resumed, readme)), Self.inputHashes["README.txt"])
    }

    // MARK: - Public pack: 7-Zip 26.05 and libarchive's encrypted corpus, against the oracle

    func testPublicPack_libarchiveEncryptedData() throws {
        let rel = "02_archives/public/test_read_format_7zip_encryption.7z"
        let oracle = try Self.oracle(for: rel)
        let url = Self.publicPack.appendingPathComponent(rel)
        // Without a password the member is listed and said to be encrypted.
        let locked = try SevenZipReader(url: url)
        XCTAssertFalse(locked.isHeaderEncrypted)
        XCTAssertEqual(locked.members.map(\.name), ["bar.txt"])
        XCTAssertTrue(locked.members[0].isEncrypted)
        XCTAssertEqual(locked.members[0].method, "7zAES + LZMA")
        XCTAssertThrowsError(try extractToData(locked, locked.members[0])) { error in
            XCTAssertEqual(error as? SevenZipReader.ReadError, .encrypted(member: "bar.txt"))
        }
        // A wrong password is a wrong password, not garbage.
        let wrong = try SevenZipReader(url: url, password: "not-it")
        XCTAssertThrowsError(try extractToData(wrong, wrong.members[0])) { error in
            XCTAssertEqual(error as? SevenZipReader.ReadError, .wrongPassword(member: "bar.txt"))
        }
        // The right one matches the oracle.
        let reader = try SevenZipReader(url: url, password: try XCTUnwrap(oracle.password))
        let data = try extractToData(reader, reader.members[0])
        XCTAssertEqual(data, Data("foo\n".utf8))
        XCTAssertEqual(Self.sha256(data), oracle.members[0].sha256)
    }

    func testPublicPack_libarchiveEncryptedHeader() throws {
        let rel = "02_archives/public/test_read_format_7zip_encryption_header.7z"
        let oracle = try Self.oracle(for: rel)
        let url = Self.publicPack.appendingPathComponent(rel)
        XCTAssertThrowsError(try SevenZipReader(url: url)) { error in
            XCTAssertEqual(error as? SevenZipReader.ReadError, .encrypted(member: "archive index"))
        }
        XCTAssertThrowsError(try SevenZipReader(url: url, password: "wrong")) { error in
            XCTAssertEqual(error as? SevenZipReader.ReadError, .wrongPassword(member: "archive index"))
        }
        let reader = try SevenZipReader(url: url, password: try XCTUnwrap(oracle.password))
        XCTAssertTrue(reader.isHeaderEncrypted)
        XCTAssertEqual(reader.members.map(\.name), ["bar.txt"])
        XCTAssertEqual(Self.sha256(try extractToData(reader, reader.members[0])), oracle.members[0].sha256)
    }

    func testPublicPack_libarchivePartiallyEncrypted() throws {
        let rel = "02_archives/public/test_read_format_7zip_encryption_partially.7z"
        let oracle = try Self.oracle(for: rel)
        let url = Self.publicPack.appendingPathComponent(rel)
        let locked = try SevenZipReader(url: url)
        let byName = Dictionary(uniqueKeysWithValues: locked.members.map { ($0.name, $0) })
        let plain = try XCTUnwrap(byName["bar_unencrypted.txt"]), encrypted = try XCTUnwrap(byName["bar_encrypted.txt"])
        XCTAssertFalse(plain.isEncrypted); XCTAssertTrue(encrypted.isEncrypted)
        // The plain member reads without a password; the encrypted one says so.
        let plainHash = try XCTUnwrap(oracle.members.first { $0.path == "bar_unencrypted.txt" }).sha256
        XCTAssertEqual(Self.sha256(try extractToData(locked, plain)), plainHash)
        XCTAssertThrowsError(try extractToData(locked, encrypted)) { error in
            XCTAssertEqual(error as? SevenZipReader.ReadError, .encrypted(member: "bar_encrypted.txt"))
        }
        let reader = try SevenZipReader(url: url, password: try XCTUnwrap(oracle.password))
        for member in reader.members {
            let expected = try XCTUnwrap(oracle.members.first { $0.path == member.name }).sha256
            XCTAssertEqual(Self.sha256(try extractToData(reader, member)), expected, member.name)
        }
    }

    func testPublicPack_sevenZip2605_AES256_encryptedHeader_everyMemberMatchesOracle() throws {
        let rel = "02_archives/7zip_generated/7zip_AES256_header_encrypted.7z"
        let oracle = try Self.oracle(for: rel)
        let url = Self.publicPack.appendingPathComponent(rel)
        XCTAssertThrowsError(try SevenZipReader(url: url)) { error in
            XCTAssertEqual(error as? SevenZipReader.ReadError, .encrypted(member: "archive index"))
        }
        XCTAssertThrowsError(try SevenZipReader(url: url, password: "mailin-fixture-2025")) { error in
            XCTAssertEqual(error as? SevenZipReader.ReadError, .wrongPassword(member: "archive index"))
        }
        let reader = try SevenZipReader(url: url, password: try XCTUnwrap(oracle.password))
        XCTAssertTrue(reader.isHeaderEncrypted)
        let files = reader.members.filter { !$0.isDirectory }
        XCTAssertEqual(Set(files.map(\.name)), Set(oracle.members.map(\.path)))
        for member in files {
            XCTAssertTrue(member.isEncrypted)
            XCTAssertTrue(member.method.hasPrefix("7zAES"), member.method)
            let expected = try XCTUnwrap(oracle.members.first { $0.path == member.name })
            let data = try extractToData(reader, member)
            XCTAssertEqual(data.count, expected.bytes, member.name)
            XCTAssertEqual(Self.sha256(data), expected.sha256, member.name)
        }
        let readme = try XCTUnwrap(files.first { $0.name == "README.txt" })
        XCTAssertTrue(String(decoding: try extractToData(reader, readme), as: UTF8.self).contains("MAILIN-PROTECTED-CONTENT-20261107"))
    }

    // MARK: - Spec-built archives: BCJ x86 and Delta filters, empty files, directories, unsafe names

    func testBCJx86Filter_roundTripsEncodedCode() throws {
        // A buffer with E8/E9 "calls" whose operands the encoder rewrites; the decoder must restore them.
        var payload = [UInt8](repeating: 0x90, count: 5_000)
        var i = 7
        while i + 5 < payload.count {
            payload[i] = i % 3 == 0 ? 0xE9 : 0xE8
            payload[i + 1] = UInt8(truncatingIfNeeded: i); payload[i + 2] = UInt8(truncatingIfNeeded: i >> 3)
            payload[i + 3] = i % 5 == 0 ? 0xFF : 0x00; payload[i + 4] = i % 2 == 0 ? 0x00 : 0xFF
            i += 37
        }
        let encoded = SevenZipFixtureWriter.bcjX86Encode(payload)
        XCTAssertNotEqual(encoded, payload, "the filter changed something")
        let url = scratch.appendingPathComponent("bcj.7z")
        try SevenZipFixtureWriter.write([.init(name: "code.bin", data: Data(payload))], to: url, filter: .bcjX86(encoded: Data(encoded)))
        let reader = try SevenZipReader(url: url)
        XCTAssertEqual(reader.members.map(\.method), ["Copy + BCJ x86"])
        XCTAssertEqual([UInt8](try extractToData(reader, reader.members[0])), payload)
    }

    func testDeltaFilter_roundTrips() throws {
        let payload = (0..<3_000).map { UInt8(truncatingIfNeeded: ($0 * 7) ^ ($0 >> 3)) }
        let encoded = SevenZipFixtureWriter.deltaEncode(payload, distance: 4)
        let url = scratch.appendingPathComponent("delta.7z")
        try SevenZipFixtureWriter.write([.init(name: "samples.raw", data: Data(payload))], to: url, filter: .delta(distance: 4, encoded: Data(encoded)))
        let reader = try SevenZipReader(url: url)
        XCTAssertEqual(reader.members.map(\.method), ["Copy + Delta"])
        XCTAssertEqual([UInt8](try extractToData(reader, reader.members[0])), payload)
    }

    func testEmptyFilesDirectoriesAndUnsafeNamesAreListedHonestly() throws {
        let url = scratch.appendingPathComponent("shape.7z")
        try SevenZipFixtureWriter.write([
            .init(name: "docs/", data: nil, isDirectory: true),
            .init(name: "docs/empty.txt", data: Data()),
            .init(name: "docs/a.txt", data: Data("alpha".utf8)),
            .init(name: "../escape.txt", data: Data("nope".utf8)),
            .init(name: "/abs.txt", data: Data("nope".utf8)),
        ], to: url)
        let reader = try SevenZipReader(url: url)
        let byName = Dictionary(uniqueKeysWithValues: reader.members.map { ($0.name, $0) })
        XCTAssertTrue(try XCTUnwrap(byName["docs/"]).isDirectory)
        let empty = try XCTUnwrap(byName["docs/empty.txt"])
        XCTAssertFalse(empty.isDirectory); XCTAssertEqual(empty.size, 0); XCTAssertNil(empty.folderIndex)
        XCTAssertEqual(try extractToData(reader, empty), Data())
        XCTAssertEqual(try extractToData(reader, try XCTUnwrap(byName["docs/a.txt"])), Data("alpha".utf8))
        XCTAssertEqual(byName["../escape.txt"]?.unsafePath, "parent-directory reference")
        XCTAssertEqual(byName["/abs.txt"]?.unsafePath, "absolute path")
        XCTAssertThrowsError(try extractToData(reader, try XCTUnwrap(byName["../escape.txt"]))) { error in
            XCTAssertEqual(error as? SevenZipReader.ReadError, .unsafePath(member: "../escape.txt", reason: "parent-directory reference"))
        }
    }

    func testTruncatedAndDamagedArchivesAreErrorsNotTraps() throws {
        let whole = try Data(contentsOf: Self.fixtures.appendingPathComponent("lzma2.7z"))
        let truncated = scratch.appendingPathComponent("t.7z")
        try whole.prefix(whole.count / 2).write(to: truncated)
        XCTAssertThrowsError(try SevenZipReader(url: truncated))
        var damaged = whole
        damaged[damaged.count - 3] ^= 0xFF   // inside the encoded header
        let damagedURL = scratch.appendingPathComponent("d.7z")
        try damaged.write(to: damagedURL)
        XCTAssertThrowsError(try SevenZipReader(url: damagedURL))
        let notA7z = scratch.appendingPathComponent("n.7z")
        try Data("PK\u{03}\u{04}not seven zip at all".utf8).write(to: notA7z)
        XCTAssertThrowsError(try SevenZipReader(url: notA7z)) { error in
            XCTAssertEqual(error as? SevenZipReader.ReadError, .notASevenZip)
        }
    }

    /// Safety (directive §6): 200 random mutations of a valid archive; every
    /// outcome is a thrown error or a clean read, never a trap.
    func testFuzz_200MutationsNeverTrap() throws {
        let seeds = ["lzma2.7z", "copy.7z", "deflate.7z"].map { Self.fixtures.appendingPathComponent($0) }
        var generator = SystemRandomNumberGenerator()
        var outcomes: [String: Int] = [:]
        for round in 0..<200 {
            let seed = seeds[round % seeds.count]
            var bytes = [UInt8](try Data(contentsOf: seed))
            let flips = Int.random(in: 1...8, using: &generator)
            for _ in 0..<flips {
                // Headers live at the end; weight mutations towards them and the start header.
                let headerZone = Bool.random(using: &generator)
                let index = headerZone ? Int.random(in: max(0, bytes.count - 200)..<bytes.count, using: &generator)
                                       : Int.random(in: 0..<bytes.count, using: &generator)
                bytes[index] = UInt8.random(in: 0...255, using: &generator)
            }
            if round % 11 == 0 { bytes.removeLast(Int.random(in: 1...min(64, bytes.count - 1), using: &generator)) }
            let url = scratch.appendingPathComponent("fuzz-\(round).7z")
            try Data(bytes).write(to: url)
            do {
                let reader = try SevenZipReader(url: url, dictionaryLimit: 8 << 20)
                for member in reader.members where !member.isDirectory && member.unsafePath == nil {
                    do { _ = try extractToData(reader, member, maxOutputBytes: 4 << 20); outcomes["read", default: 0] += 1 }
                    catch { outcomes["member error", default: 0] += 1 }
                }
            } catch {
                outcomes["open error", default: 0] += 1
            }
            try? FileManager.default.removeItem(at: url)
        }
        XCTAssertEqual(outcomes.values.reduce(0, +) > 0, true, "\(outcomes)")
    }
}

// MARK: - A spec-built 7z writer (Copy coder, optional filter) for shapes no local tool produces

enum SevenZipFixtureWriter {
    struct Entry {
        let name: String
        let data: Data?
        var isDirectory = false
        init(name: String, data: Data?, isDirectory: Bool = false) { self.name = name; self.data = data; self.isDirectory = isDirectory }
    }

    enum Filter {
        /// The folder's packed bytes are `encoded` (the filter's output); the member is the original.
        case bcjX86(encoded: Data)
        case delta(distance: Int, encoded: Data)
    }

    static func number(_ v: UInt64) -> [UInt8] {
        var first: UInt8 = 0
        var mask: UInt8 = 0x80
        var i = 0
        while i < 8 {
            if v < (UInt64(1) << UInt64(7 * (i + 1))) { first |= UInt8(truncatingIfNeeded: v >> UInt64(8 * i)); break }
            first |= mask; mask >>= 1; i += 1
        }
        return [first] + (0..<i).map { UInt8(truncatingIfNeeded: v >> UInt64(8 * $0)) }
    }
    static func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)] }
    static func le64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: v >> UInt64(8 * $0)) } }

    /// One folder (Copy, or filter + Copy) holding every non-empty file in
    /// order; `solid: false` writes one Copy folder per file (as 7-Zip's
    /// -ms=off does), so members live in separate pack streams.
    static func write(_ entries: [Entry], to url: URL, filter: Filter? = nil, solid: Bool = true) throws {
        let withData = entries.filter { ($0.data?.count ?? 0) > 0 }
        var packed = Data()
        for e in withData { packed.append(e.data!) }
        if let filter {
            switch filter {
            case .bcjX86(let encoded), .delta(_, let encoded): packed = encoded
            }
        }
        var header: [UInt8] = [0x01]
        if !withData.isEmpty, !solid {
            header += [0x04]
            header += [0x06] + number(0) + number(UInt64(withData.count)) + [0x09]
            for e in withData { header += number(UInt64(e.data!.count)) }
            header += [0x00]
            header += [0x07, 0x0B] + number(UInt64(withData.count)) + [0x00]
            for _ in withData { header += number(1) + [0x01, 0x00] }                                   // each folder: one Copy coder
            header += [0x0C]
            for e in withData { header += number(UInt64(e.data!.count)) }
            header += [0x00]
            header += [0x08, 0x0A, 0x01]                                                                  // SubStreamsInfo: one per folder, digests
            for e in withData { header += le32(ZIPArchiveReader.CRC32.checksum(e.data!)) }
            header += [0x00, 0x00]
        } else if !withData.isEmpty {
            header += [0x04]                      // MainStreamsInfo
            header += [0x06] + number(0) + number(1) + [0x09] + number(UInt64(packed.count)) + [0x00]   // PackInfo
            header += [0x07, 0x0B] + number(1) + [0x00]                                               // UnpackInfo, one folder, inline
            let total = UInt64(withData.reduce(0) { $0 + $1.data!.count })
            switch filter {
            case nil:
                header += number(1) + [0x01, 0x00]                                                   // one coder: Copy
                header += [0x0C] + number(total)
            case .bcjX86?:
                header += number(2)
                header += [0x04, 0x03, 0x03, 0x01, 0x03]                                            // coder 0: BCJ x86
                header += [0x01, 0x00]                                                               // coder 1: Copy
                header += number(0) + number(1)                                                      // bind pair: BCJ in 0 ← Copy out 1
                header += [0x0C] + number(total) + number(total)
            case .delta(let distance, _)?:
                header += number(2)
                header += [0x21, 0x03] + number(1) + [UInt8(distance - 1)]                           // coder 0: Delta with its property
                header += [0x01, 0x00]
                header += number(0) + number(1)
                header += [0x0C] + number(total) + number(total)
            }
            header += [0x00]
            header += [0x08, 0x0D] + number(UInt64(withData.count))                                 // SubStreamsInfo
            if withData.count > 1 {
                header += [0x09]
                for e in withData.dropLast() { header += number(UInt64(e.data!.count)) }
            }
            header += [0x0A, 0x01]
            for e in withData { header += le32(ZIPArchiveReader.CRC32.checksum(e.data!)) }
            header += [0x00, 0x00]
        }
        // FilesInfo
        header += [0x05] + number(UInt64(entries.count))
        let empties = entries.map { ($0.data?.count ?? 0) == 0 }
        if empties.contains(true) {
            header += [0x0E] + number(UInt64((empties.count + 7) / 8)) + bitVector(empties)
            let emptyFiles = entries.filter { ($0.data?.count ?? 0) == 0 }.map { !$0.isDirectory }
            header += [0x0F] + number(UInt64((emptyFiles.count + 7) / 8)) + bitVector(emptyFiles)
        }
        var names: [UInt8] = [0x00]
        for e in entries {
            for unit in e.name.utf16 { names += [UInt8(unit & 0xFF), UInt8(unit >> 8)] }
            names += [0, 0]
        }
        header += [0x11] + number(UInt64(names.count)) + names
        header += [0x00, 0x00]

        let headerData = Data(header)
        var start: [UInt8] = [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0x00, 0x04]
        let tail = le64(UInt64(packed.count)) + le64(UInt64(headerData.count)) + le32(ZIPArchiveReader.CRC32.checksum(headerData))
        start += le32(ZIPArchiveReader.CRC32.checksum(Data(tail))) + tail
        var out = Data(start)
        out.append(packed)
        out.append(headerData)
        try out.write(to: url)
    }

    static func bitVector(_ bits: [Bool]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: (bits.count + 7) / 8)
        for (i, b) in bits.enumerated() where b { out[i / 8] |= 0x80 >> UInt8(i % 8) }
        return out
    }

    /// The encoding direction of Bra86.c — the inverse of `BCJX86Stream`.
    static func bcjX86Encode(_ input: [UInt8]) -> [UInt8] {
        var data = input
        let maskToAllowed: [Bool] = [true, true, true, false, true, false, false, false]
        let maskToBitNumber: [Int] = [0, 1, 2, 2, 3, 3, 3, 3]
        func msb(_ b: UInt8) -> Bool { b == 0 || b == 0xFF }
        let size = data.count
        guard size >= 5 else { return data }
        let ip: UInt32 = 5
        var prevMask: UInt32 = 0
        var bufferPos: UInt = 0
        var prevPosT: UInt = UInt(0) &- 1
        let limit = UInt(size - 4)
        while true {
            var p = bufferPos
            while p < limit, data[Int(p)] & 0xFE != 0xE8 { p += 1 }
            bufferPos = p
            if p >= limit { break }
            prevPosT = bufferPos &- prevPosT
            if prevPosT > 3 { prevMask = 0 } else {
                prevMask = (prevMask << UInt32(prevPosT - 1)) & 0x7
                if prevMask != 0 {
                    let b = data[Int(p) + 4 - maskToBitNumber[Int(prevMask)]]
                    if !maskToAllowed[Int(prevMask)] || msb(b) {
                        prevPosT = bufferPos; prevMask = ((prevMask << 1) & 0x7) | 1; bufferPos += 1; continue
                    }
                }
            }
            prevPosT = bufferPos
            if msb(data[Int(p) + 4]) {
                var src = UInt32(data[Int(p) + 4]) << 24 | UInt32(data[Int(p) + 3]) << 16 | UInt32(data[Int(p) + 2]) << 8 | UInt32(data[Int(p) + 1])
                var dest: UInt32
                while true {
                    dest = (ip &+ UInt32(truncatingIfNeeded: bufferPos)) &+ src
                    if prevMask == 0 { break }
                    let index = maskToBitNumber[Int(prevMask)] * 8
                    let b = UInt8(truncatingIfNeeded: dest >> UInt32(24 - index))
                    if !msb(b) { break }
                    src = dest ^ ((UInt32(1) << UInt32(32 - index)) &- 1)
                }
                data[Int(p) + 4] = ~UInt8(truncatingIfNeeded: ((dest >> 24) & 1) &- 1)
                data[Int(p) + 3] = UInt8(truncatingIfNeeded: dest >> 16)
                data[Int(p) + 2] = UInt8(truncatingIfNeeded: dest >> 8)
                data[Int(p) + 1] = UInt8(truncatingIfNeeded: dest)
                bufferPos += 5
            } else {
                prevMask = ((prevMask << 1) & 0x7) | 1
                bufferPos += 1
            }
        }
        return data
    }

    static func deltaEncode(_ input: [UInt8], distance: Int) -> [UInt8] {
        var out = input
        for i in input.indices { out[i] = input[i] &- (i >= distance ? input[i - distance] : 0) }
        return out
    }
}
