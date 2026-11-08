//
//  LibArchiveRARTests.swift
//  ArchiveCoreTests
//
//  GAP-RAR (owner decision 2026-11-07): compressed RAR members decoded by the
//  vendored libarchive 3.8.11 reader (CLibArchiveRAR). The fixtures are the
//  WinRAR-written archives of libarchive's own test suite
//  (Fixtures/libarchive-rar, MANIFEST.md); the oracle is what libarchive's
//  test_read_format_rar.c / test_read_format_rar5.c assert for the same files
//  — exact bytes, tails, sizes and CRC-32 values — plus the CRC-32 WinRAR
//  wrote into every file header, which the extractor checks itself.
//
//  The testREAL_* rows go through the entry points that existed before this
//  change (DocumentTextExtractor / ParserFactory.containerSteps /
//  SourcePreflight), so they fail on the old reader, which named every
//  compressed member "RAR compression not opened (needs a RAR decompressor)".
//

import XCTest
import CryptoKit
@testable import ArchiveCore

final class LibArchiveRARTests: XCTestCase {

    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/libarchive-rar", isDirectory: true)

    private var scratch: URL!
    private var savedOverride: ExtractionLimits?

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("libarchive-rar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        savedOverride = ExtractionLimits.baseOverride
    }
    override func tearDown() {
        ExtractionLimits.baseOverride = savedOverride
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    private func fixture(_ name: String) -> URL { Self.fixtures.appendingPathComponent(name) }

    private func children(_ result: OfficeTextExtractor.Result) -> [String: ChildDocument] {
        Dictionary(result.children.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func crc32(_ data: Data) -> UInt32 { ZIPArchiveReader.CRC32.checksum(data) }

    /// libarchive test_read_format_rar5.c `verify_data`: little-endian Int32
    /// k*k − 3k + (1 + magic), floored at 0, for k = 1 … size/4.
    static func rar5TestData(magic: Int32, size: Int) -> Data {
        var out = Data(capacity: size)
        for i in 0..<(size / 4) {
            let k = Int32(i + 1)
            var value = k &* k &- 3 &* k &+ (1 &+ magic)
            if value < 0 { value = 0 }
            withUnsafeBytes(of: UInt32(bitPattern: value).littleEndian) { out.append(contentsOf: $0) }
        }
        return out
    }

    // libarchive test_read_format_rar.c oracle strings.
    static let htmlTail = Data("<P STYLE=\"margin-bottom: 0in\"><BR>\n</P>\n</BODY>\n</HTML>".utf8)
    static let testText = Data("test text document\r\n".utf8)

    /// A binary child was decoded: its hash is the oracle's. (Without the
    /// app's reader a `.bin` is then "not read inside archives: .bin" —
    /// decoded, hashed, but not text; never a RAR refusal or a failure.)
    private func assertDecoded(_ child: ChildDocument, equals expected: Data, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(child.sha256, Self.sha256(expected), child.path, file: file, line: line)
        XCTAssertEqual(child.bytes, expected.count, child.path, file: file, line: line)
        XCTAssertNotEqual(child.state, .failed, child.note ?? "", file: file, line: line)
        XCTAssertFalse(child.note?.contains("RAR") == true, child.note ?? "", file: file, line: line)
    }

    private func extractWhole(_ extractor: RARReader.Extractor, _ name: String, maxOutputBytes: Int64? = nil) throws -> Data {
        let member = try XCTUnwrap(extractor.archive.members.first { $0.name == name }, name)
        let out = scratch.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: out) }
        try extractor.extract(member, to: out, maxOutputBytes: maxOutputBytes)
        return try Data(contentsOf: out)
    }

    // MARK: - RAR 1.5–4.x (WinRAR, RAR 2.9 algorithm)

    func testREAL_libarchiveRAR4_compressedMembersRead() throws {
        for name in ["test_read_format_rar_compress_normal.rar", "test_read_format_rar_compress_best.rar"] {
            let url = fixture(name)
            let archive = try RARReader.read(url: url)
            XCTAssertEqual(archive.format, .rar4, name)
            XCTAssertEqual(archive.members.map(\.name), ["LibarchiveAddingTest.html", "testlink", "testdir/test.txt",
                                                         "testdir/LibarchiveAddingTest.html", "testdir", "testemptydir"], name)
            XCTAssertTrue(archive.members.filter { !$0.isDirectory && !$0.isSymlink }.allSatisfy { $0.method != 0 && $0.algorithmVersion == 29 }, name)

            // Through the attachment reader: every file a child, compressed members read.
            let result = try DocumentTextExtractor.extract(fileURL: url, kind: .rar, logicalName: name)
            let byPath = children(result)
            for html in ["LibarchiveAddingTest.html", "testdir/LibarchiveAddingTest.html"] {
                let child = try XCTUnwrap(byPath[html], "\(name): \(html)")
                XCTAssertEqual(child.state, .extracted, "\(name): \(html) \(child.note ?? "")")
                XCTAssertEqual(child.bytes, 20111, "\(name): \(html)")
                XCTAssertTrue(child.text?.contains("BODY") == true || child.text?.isEmpty == false, "\(name): \(html)")
            }
            let txt = try XCTUnwrap(byPath["testdir/test.txt"])
            XCTAssertEqual(txt.state, .extracted, txt.note ?? "")
            XCTAssertEqual(txt.sha256, Self.sha256(Self.testText))
            XCTAssertEqual(byPath["testlink"]?.state, .unsupported)
            XCTAssertEqual(byPath["testlink"]?.note, "a symbolic link, not followed")

            // The bytes themselves: the tail libarchive's test asserts, and WinRAR's header CRC (checked in extract).
            let extractor = try RARReader.Extractor(url: url)
            let html = try extractWhole(extractor, "testdir/LibarchiveAddingTest.html")
            XCTAssertEqual(html.count, 20111)
            XCTAssertEqual(html.suffix(Self.htmlTail.count), Self.htmlTail, name)
            XCTAssertEqual(try extractWhole(extractor, "LibarchiveAddingTest.html"), html, "out-of-order request reopens the pass")
        }

        // RAR 3 low-distance reset: libarchive's exact 64 expected bytes.
        let lowdist = try RARReader.Extractor(url: fixture("test_read_format_rar3_lowdist_reset.rar"))
        let expected: [UInt8] = Array(0x00...0x27) + [0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x0d, 0x0e, 0x0f] + Array(0x28...0x36)
        XCTAssertEqual([UInt8](try extractWhole(lowdist, "lowdist-reset.bin")), expected)

        // The RAR 3 VM filter (E8 on a Windows executable): the PE signature libarchive asserts.
        let filter = try RARReader.Extractor(url: fixture("test_read_format_rar_filter.rar"))
        let exe = try extractWhole(filter, "bsdcat.exe")
        XCTAssertEqual(exe.count, 204288)
        XCTAssertEqual([UInt8](exe.prefix(12)), [0x4d, 0x5a, 0x90, 0x00, 0x03, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00])
    }

    /// PPMd → LZSS switching inside one 241,647,978-byte member: read whole
    /// (no hidden cap), the tail libarchive asserts; under a ceiling the copy
    /// stops with the ceiling named; the attachment reader names its per-part guard.
    func testREAL_libarchiveRAR4_ppmdMemberReadWhole_andCeilingNamed() throws {
        let url = fixture("test_read_format_rar_ppmd_lzss_conversion.rar")
        let extractor = try RARReader.Extractor(url: url)
        let member = try XCTUnwrap(extractor.archive.members.first)
        XCTAssertEqual(member.name, "ppmd_lzss_conversion_test.txt")
        XCTAssertEqual(member.unpackedSize, 241_647_978)

        let out = scratch.appendingPathComponent("ppmd.txt")
        try extractor.extract(member, to: out)
        let handle = try FileHandle(forReadingFrom: out)
        defer { try? handle.close() }
        XCTAssertEqual(try handle.seekToEnd(), 241_647_978)
        let tail = Data("gin-bottom: 0in\"><BR>\n</P>\n</BODY>\n</HTML>".utf8)
        try handle.seek(toOffset: UInt64(241_647_978 - tail.count))
        XCTAssertEqual(try handle.readToEnd(), tail)
        try? FileManager.default.removeItem(at: out)

        XCTAssertThrowsError(try extractor.extract(member, to: out, maxOutputBytes: 1_048_576)) { error in
            XCTAssertEqual(error as? RARReader.ReadError, .budgetExceeded(member: member.name, limit: 1_048_576))
            XCTAssertEqual(ContainerTextExtractor.classify(error).note, "decompression stopped at the 1048576-byte budget")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), "a stopped copy leaves no partial file")

        let result = try DocumentTextExtractor.extract(fileURL: url, kind: .rar, logicalName: "big.rar")
        let child = try XCTUnwrap(result.children.first)
        XCTAssertEqual(child.state, .unsupported)
        XCTAssertEqual(child.note, "241647978 bytes, over the \(ExtractionLimits.effective.partBytes)-byte guard")
        XCTAssertTrue(ExtractionLimits.noteNamesALimit(child.note), "Resume can reopen it")
    }

    // MARK: - RAR 5.0

    func testREAL_libarchiveRAR5_compressedRead() throws {
        let url = fixture("test_read_format_rar5_compressed.rar")
        let result = try DocumentTextExtractor.extract(fileURL: url, kind: .rar, logicalName: "c.rar")
        let child = try XCTUnwrap(children(result)["test.bin"])
        assertDecoded(child, equals: Self.rar5TestData(magic: 0, size: 1200))

        let blake = try RARReader.Extractor(url: fixture("test_read_format_rar5_blake2.rar"))
        let poem = try extractWhole(blake, try XCTUnwrap(blake.archive.members.first).name)
        XCTAssertEqual(poem.count, 814)
        XCTAssertEqual(Self.crc32(poem), 0x7E5E_C49E, "BLAKE2sp-checked member, CRC libarchive's test asserts")

        let arm = try RARReader.Extractor(url: fixture("test_read_format_rar5_arm.rar"))
        let elf = try extractWhole(arm, try XCTUnwrap(arm.archive.members.first).name)
        XCTAssertEqual(elf.count, 90808)
        XCTAssertEqual(Self.crc32(elf), 0x886F_91EB, "ARM filter")

        // A stored RAR5 member still takes the direct path.
        let stored = try RARReader.Extractor(url: fixture("test_read_format_rar5_stored.rar"))
        XCTAssertEqual(try extractWhole(stored, "helloworld.txt"), Data("hello libarchive test suite!\n".utf8))
    }

    func testREAL_libarchiveRAR5_solidRead() throws {
        for name in ["test_read_format_rar5_multiple_files.rar", "test_read_format_rar5_multiple_files_solid.rar"] {
            let url = fixture(name)
            let archive = try RARReader.read(url: url)
            XCTAssertEqual(archive.isSolid, name.contains("solid"), name)
            let byPath = children(try DocumentTextExtractor.extract(fileURL: url, kind: .rar, logicalName: name))
            for i in 1...4 {
                let child = try XCTUnwrap(byPath["test\(i).bin"], "\(name) test\(i).bin")
                assertDecoded(child, equals: Self.rar5TestData(magic: Int32(i), size: 4096))
            }
        }
        // test_read_format_rar5_solid.rar: libarchive's CRCs; members asked for out of order
        // (a later one first, then an earlier one: a second pass through the solid stream).
        let extractor = try RARReader.Extractor(url: fixture("test_read_format_rar5_solid.rar"))
        XCTAssertTrue(extractor.archive.isSolid)
        XCTAssertEqual(extractor.archive.members.map(\.name), ["test.bin"] + (1...6).map { "test\($0).bin" })
        XCTAssertEqual(Self.crc32(try extractWhole(extractor, "test6.bin")), 0x36A4_48FF)
        XCTAssertEqual(Self.crc32(try extractWhole(extractor, "test1.bin")), 0x7E13_B2C6)
        XCTAssertEqual(Self.crc32(try extractWhole(extractor, "test.bin")), 0x7CCA_70CD)
        XCTAssertEqual(try extractWhole(extractor, "test2.bin"), Self.rar5TestData(magic: 2, size: 4096))
    }

    // MARK: - Multi-volume sets

    func testREAL_libarchiveRAR_multiVolumeSetsRead_missingVolumeNamed() throws {
        // RAR 5.0 solid set, four volumes: libarchive's CRCs for every member.
        let rar5 = (1...4).map { fixture("test_read_format_rar5_multiarchive_solid.part0\($0).rar") }
        let set5 = try RARReader.Extractor(url: rar5[0], siblings: rar5.dropFirst().map { .init(url: $0) })
        XCTAssertTrue(set5.isVolumeSet)
        XCTAssertEqual(set5.decodableVolumeCount, 4)
        let expected5: [(String, UInt32)] = [("cebula.txt", 0x7E5EC49E), ("test.bin", 0x7cca70cd), ("test1.bin", 0x7e13b2c6), ("test2.bin", 0xf166afcb),
                                             ("test3.bin", 0x9fb123d9), ("test4.bin", 0x10c43ed4), ("test5.bin", 0xb9d155f2), ("test6.bin", 0x36a448ff),
                                             ("elf-Linux-ARMv7-ls", 0x886F91EB)]
        XCTAssertEqual(Array(set5.archive.members.map(\.name).prefix(expected5.count)), expected5.map(\.0))
        for (name, crc) in expected5 {
            XCTAssertNil(set5.refusal(for: try XCTUnwrap(set5.archive.members.first { $0.name == name })), name)
            XCTAssertEqual(Self.crc32(try extractWhole(set5, name)), crc, name)
        }
        // Opened from a later volume: the same set.
        let fromThird = try RARReader.Extractor(url: rar5[2], siblings: rar5.map { .init(url: $0) })
        XCTAssertEqual(fromThird.archive.members.map(\.name), set5.archive.members.map(\.name))

        // RAR 4 set (four volumes), its first member split over all of them.
        let rar4 = (1...4).map { fixture("test_read_format_rar_multivolume.part000\($0).rar") }
        let set4 = try RARReader.Extractor(url: rar4[0], siblings: rar4.map { .init(url: $0) })
        XCTAssertEqual(set4.archive.members.map(\.name), ["ppmd_lzss_conversion_test.txt", "LibarchiveAddingTest.html", "testlink",
                                                          "testdir/test.txt", "testdir/LibarchiveAddingTest.html", "testdir", "testemptydir"])
        let first = set4.archive.members[0]
        XCTAssertEqual(first.firstVolume, 0)
        XCTAssertGreaterThan(first.lastVolume, 0, "merged across volumes")
        XCTAssertFalse(first.isSplitAfter)
        XCTAssertEqual(try extractWhole(set4, "testdir/test.txt"), Self.testText)
        XCTAssertEqual(try extractWhole(set4, "LibarchiveAddingTest.html").suffix(Self.htmlTail.count), Self.htmlTail)

        // Volume 2 missing: what needs it is named, nothing is dropped from the listing.
        let gap = try RARReader.Extractor(url: rar5[0], siblings: [.init(url: rar5[2]), .init(url: rar5[3])])
        XCTAssertEqual(gap.decodableVolumeCount, 1)
        XCTAssertEqual(gap.archive.members.map(\.name), set5.archive.members.map(\.name), "members of the volumes after the gap are still listed")
        let note = "not opened: volume 2 (test_read_format_rar5_multiarchive_solid.part02.rar) missing"
        let refused = gap.archive.members.filter { gap.refusal(for: $0) == note }
        XCTAssertFalse(refused.isEmpty)
        let partial = try ContainerTextExtractor.extract(fileURL: rar5[0], kind: .rar, logicalName: "test_read_format_rar5_multiarchive_solid.part01.rar",
                                                         siblings: [.init(url: rar5[2]), .init(url: rar5[3])])
        XCTAssertEqual(partial.children.count, gap.archive.members.filter { !$0.isDirectory }.count)
        XCTAssertTrue(partial.children.contains { $0.note == note })
        // A lone first volume (no siblings) is the set's start: the member running on is named with volume 2.
        let lone = try ContainerTextExtractor.extract(fileURL: rar5[0], kind: .rar, logicalName: "test_read_format_rar5_multiarchive_solid.part01.rar")
        XCTAssertTrue(lone.children.contains { $0.note == note }, "\(lone.children.map { "\($0.path): \($0.note ?? "-")" })")

        // Volume naming.
        XCTAssertEqual(RARVolumeSet.part(ofName: "a.part07.rar"), .init(stem: "a", number: 7, style: .partN(width: 2)))
        XCTAssertEqual(RARVolumeSet.part(ofName: "a.r00"), .init(stem: "a", number: 2, style: .oldStyle))
        XCTAssertEqual(RARVolumeSet.part(ofName: "a.s01"), .init(stem: "a", number: 103, style: .oldStyle))
        XCTAssertEqual(RARVolumeSet.volumeName(stem: "a", number: 3, style: .oldStyle), "a.r01")
        XCTAssertEqual(RARVolumeSet.volumeName(stem: "a", number: 102, style: .oldStyle), "a.s00")
        XCTAssertEqual(RARVolumeSet.volumeName(stem: "a", number: 2, style: .partN(width: 4)), "a.part0002.rar")
    }

    // MARK: - Locked and damaged

    func testREAL_libarchiveRAR_encryptedStillLocked() throws {
        for name in ["test_read_format_rar4_encrypted.rar", "test_read_format_rar5_encrypted.rar"] {
            let byPath = children(try DocumentTextExtractor.extract(fileURL: fixture(name), kind: .rar, logicalName: name))
            XCTAssertEqual(Set(byPath.keys), ["a.txt", "b.txt", "c.txt", "d.txt"], name)
            for plain in ["a.txt", "c.txt"] {
                XCTAssertEqual(byPath[plain]?.state, .extracted, "\(name) \(plain): \(byPath[plain]?.note ?? "")")
                XCTAssertEqual(byPath[plain]?.bytes, 18, name)
            }
            for locked in ["b.txt", "d.txt"] {
                XCTAssertEqual(byPath[locked]?.state, .locked, "\(name) \(locked)")
                XCTAssertEqual(byPath[locked]?.note, "password-protected")
            }
        }
        // Solid + encrypted: every file locked, never handed to the decoder.
        let solid = try DocumentTextExtractor.extract(fileURL: fixture("test_read_format_rar4_solid_encrypted.rar"), kind: .rar, logicalName: "s.rar")
        XCTAssertFalse(solid.children.isEmpty)
        XCTAssertTrue(solid.children.allSatisfy { $0.state == .locked }, "\(solid.children.map { "\($0.path) \($0.state)" })")
        // Encrypted headers: the archive is locked as a whole.
        XCTAssertThrowsError(try RARReader.read(url: fixture("test_read_format_rar_encryption_header.rar"))) { error in
            XCTAssertEqual(error as? RARReader.ReadError, .encryptedHeaders)
        }
        XCTAssertThrowsError(try DocumentTextExtractor.extract(fileURL: fixture("test_read_format_rar_encryption_header.rar"), kind: .rar, logicalName: "h.rar")) { error in
            XCTAssertEqual(error as? OfficeTextExtractor.ExtractError, .encrypted)
        }
    }

    func testREAL_libarchiveRAR_corruptMemberNamed() throws {
        // One flipped byte inside the first compressed member's data: that member
        // fails, named; the members after it are still read.
        let source = fixture("test_read_format_rar_compress_normal.rar")
        let archive = try RARReader.read(url: source)
        let victim = archive.members[0]
        var bytes = [UInt8](try Data(contentsOf: source))
        bytes[Int(victim.dataOffset + victim.packedSize / 2)] ^= 0x5A
        let damaged = scratch.appendingPathComponent("damaged.rar")
        try Data(bytes).write(to: damaged)
        let result = try DocumentTextExtractor.extract(fileURL: damaged, kind: .rar, logicalName: "damaged.rar")
        let byPath = children(result)
        let bad = try XCTUnwrap(byPath[victim.name])
        XCTAssertEqual(bad.state, .failed)
        XCTAssertTrue(bad.note?.hasPrefix("\(victim.name): ") == true, bad.note ?? "")
        XCTAssertTrue(bad.note?.contains("CRC-32 does not match") == true || bad.note?.contains("could not be decoded") == true, bad.note ?? "")
        XCTAssertEqual(byPath["testdir/test.txt"]?.state, .extracted, byPath["testdir/test.txt"]?.note ?? "")
        XCTAssertEqual(byPath["testdir/LibarchiveAddingTest.html"]?.state, .extracted)

        // libarchive's own damaged fixtures: every member named, nothing traps.
        for name in ["test_read_format_rar5_bad_tables.rar", "test_read_format_rar5_truncated_huff.rar", "test_read_format_rar_invalid1.rar"] {
            do {
                let r = try DocumentTextExtractor.extract(fileURL: fixture(name), kind: .rar, logicalName: name)
                for child in r.children where child.state != .extracted && child.state != .noText {
                    XCTAssertNotNil(child.note, "\(name): \(child.path) is named")
                }
                XCTAssertTrue(r.children.allSatisfy { $0.state != .extracted || !$0.sha256.isEmpty }, name)
            } catch {
                XCTAssertFalse("\(error)".isEmpty, name)   // the archive as a whole refused, with a reason
            }
        }
    }

    // MARK: - Refusals the decoder never sees

    func testRAR_compressionRefusalsNamed() throws {
        func member(_ format: RARReader.Format, method: Int = 3, version: Int, solid: Bool = false, dictionary: Int64? = nil) -> RARReader.Member {
            RARReader.Member(name: "m.txt", unpackedSize: 10, packedSize: 5, crc32: nil, method: method, algorithmVersion: version, isDirectory: false,
                             isEncrypted: false, isSolid: solid, isSplitBefore: false, isSplitAfter: false, isSymlink: false, hostOS: "Windows",
                             dataOffset: 0, format: format, dictionaryBytes: dictionary)
        }
        XCTAssertNil(member(.rar4, version: 29).compressionRefusal)
        XCTAssertNil(member(.rar4, version: 36).compressionRefusal)
        XCTAssertNil(member(.rar4, method: 0, version: 20).compressionRefusal, "stored is always read")
        XCTAssertEqual(member(.rar4, version: 20).compressionRefusal, "RAR 2.0 compression not opened (the RAR 1.5 and 2.0 algorithms are not in the vendored decoder)")
        XCTAssertEqual(member(.rar4, version: 15).compressionRefusal, "RAR 1.5 compression not opened (the RAR 1.5 and 2.0 algorithms are not in the vendored decoder)")
        XCTAssertNil(member(.rar4, version: 29, solid: true).compressionRefusal, "R6: RAR 4 solid members after the first are decoded")
        XCTAssertNil(member(.rar5, version: 0, solid: true, dictionary: 32 << 20).compressionRefusal, "RAR 5 solid is read")
        XCTAssertEqual(member(.rar5, version: 1).compressionRefusal, "RAR 7.0 compression not opened (the vendored decoder reads the RAR 5.0 algorithm)")
        XCTAssertEqual(member(.rar5, version: 0, dictionary: 128 << 20).compressionRefusal,
                       "needs a 134217728-byte RAR dictionary, over the 67108864-byte limit of the vendored decoder")
        XCTAssertEqual(ContainerTextExtractor.classify(RARReader.ReadError.compressionNotOpened(member: "m", reason: "R")).state, .unsupported)

        // The dictionary is read from the RAR5 header (WinRAR's choice for these files).
        let solid = try RARReader.read(url: fixture("test_read_format_rar5_solid.rar"))
        XCTAssertTrue(solid.members.allSatisfy { ($0.dictionaryBytes ?? 0) >= 128 * 1024 && ($0.dictionaryBytes ?? 0) <= RARReader.maxDecoderDictionaryBytes })
    }

    // MARK: - Mail-source path

    /// A .rar opened as an import source: compressed members are extracted
    /// (decoded, verified) and judged on their bytes, not refused.
    func testREAL_libarchiveRAR_mailSourceStepsDecodeCompressedMembers() throws {
        let url = scratch.appendingPathComponent("export.rar")
        try FileManager.default.copyItem(at: fixture("test_read_format_rar_compress_normal.rar"), to: url)
        let steps = try ParserFactory.containerSteps(url, format: .rar)
        XCTAssertEqual(steps.map(\.name), ["LibarchiveAddingTest.html", "testlink", "testdir/test.txt", "testdir/LibarchiveAddingTest.html"])
        let txt = try XCTUnwrap(steps.first { $0.name == "testdir/test.txt" })
        let out = scratch.appendingPathComponent("t.txt")
        try txt.extract(out)
        XCTAssertEqual(try Data(contentsOf: out), Self.testText)
        for step in steps where step.name.hasSuffix(".html") {
            let dest = scratch.appendingPathComponent(UUID().uuidString)
            XCTAssertNotEqual(try ParserFactory.containerMemberDisposition(step, extractingTo: dest), .refused, step.name)
        }
        let preflight = SourceFormatClassifier.preflight(url: url)
        XCTAssertEqual(preflight.condition, .ready, preflight.detail)
        XCTAssertFalse(preflight.detail.contains("compress"), preflight.detail)

        // A multi-volume set in a folder: opened from any volume, read with the volumes beside it.
        let folder = scratch.appendingPathComponent("set", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for n in 1...4 {
            try FileManager.default.copyItem(at: fixture("test_read_format_rar_multivolume.part000\(n).rar"),
                                            to: folder.appendingPathComponent("mail.part\(n).rar"))
        }
        let setSteps = try ParserFactory.containerSteps(folder.appendingPathComponent("mail.part2.rar"), format: .rar)
        let html = try XCTUnwrap(setSteps.first { $0.name == "testdir/LibarchiveAddingTest.html" })
        let htmlOut = scratch.appendingPathComponent("h.html")
        try html.extract(htmlOut)
        XCTAssertEqual(try Data(contentsOf: htmlOut).suffix(Self.htmlTail.count), Self.htmlTail)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("mail.part3.rar"))
        let gapPreflight = SourceFormatClassifier.preflight(url: folder.appendingPathComponent("mail.part1.rar"))
        XCTAssertTrue(gapPreflight.detail.contains("continue in another volume that is not in the folder"), gapPreflight.detail)
    }

    // MARK: - R6: RAR 4 solid, passwords, attached volume sets

    /// libarchive test_read_format_rar_encryption.c: four files a…d.txt, each
    /// "This is from <name>" (18 bytes); solid archives and archives with
    /// encrypted file names use the password "password" for every file; the
    /// non-solid ones leave a.txt and c.txt plain, b.txt under "password",
    /// d.txt under "password2". WinRAR's CRC-32s (the RAR 4 headers):
    static let encryptionFixtureCRCs: [String: UInt32] = ["a.txt": 0xEE5A_6E55, "b.txt": 0xA9FA_1485, "c.txt": 0x949A_3D35, "d.txt": 0x26BA_E125]
    static func encryptionFixtureText(_ name: String) -> Data { Data("This is from \(name)".utf8) }

    private func assertFourFiles(_ result: OfficeTextExtractor.Result, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let byPath = children(result)
        XCTAssertEqual(Set(byPath.keys), ["a.txt", "b.txt", "c.txt", "d.txt"], label, file: file, line: line)
        for name in ["a.txt", "b.txt", "c.txt", "d.txt"] {
            let child = byPath[name]
            XCTAssertEqual(child?.state, .extracted, "\(label) \(name): \(child?.note ?? "")", file: file, line: line)
            XCTAssertEqual(child?.text, "This is from \(name)", "\(label) \(name)", file: file, line: line)
            XCTAssertEqual(child?.sha256, Self.sha256(Self.encryptionFixtureText(name)), "\(label) \(name)", file: file, line: line)
        }
    }

    /// RAR 4 solid: every member after the first decoded (was "RAR 4 solid
    /// compression not opened"), in order and out of order. The only RAR 4
    /// solid files in libarchive's suite are encrypted, so the plain solid
    /// archive is the decrypted view of one (headers and data exactly as
    /// WinRAR's compressor wrote them), read from disk by the file path.
    func testR6_rar4SolidMembersAfterTheFirstRead() throws {
        let fixtureURL = fixture("test_read_format_rar4_solid_encrypted.rar")
        let encrypted = try RARReader.read(url: fixtureURL)
        XCTAssertTrue(encrypted.isSolid)
        XCTAssertEqual(encrypted.members.map(\.isSolid), [false, true, true, true])
        XCTAssertTrue(encrypted.members.allSatisfy { $0.method == 3 && $0.algorithmVersion == 29 })

        let keyring = RARKeyring(password: "password")
        let source = try FileRandomAccessSource(url: fixtureURL)
        let stream = try RARReader.decryptedStream(format: .rar4, isSolid: true, members: encrypted.members, keyring: keyring, source: { _ in source })
        var plainBytes = Data()
        while true {
            let n = stream.next()
            XCTAssertGreaterThanOrEqual(n, 0)
            if n <= 0 { break }
            plainBytes.append(stream.bufferPointer.assumingMemoryBound(to: UInt8.self), count: n)
        }
        let plainURL = scratch.appendingPathComponent("solid4.rar")
        try plainBytes.write(to: plainURL)

        let plain = try RARReader.Extractor(url: plainURL)
        XCTAssertTrue(plain.archive.isSolid)
        XCTAssertEqual(plain.archive.members.map(\.name), ["a.txt", "b.txt", "c.txt", "d.txt"])
        XCTAssertTrue(plain.archive.members.allSatisfy { !$0.isEncrypted && plain.refusal(for: $0) == nil })
        // Out of order: the last member first (the pass decodes a, b, c on the way), then an earlier one (a second pass).
        for name in ["d.txt", "b.txt", "a.txt", "c.txt", "d.txt"] {
            let bytes = try extractWhole(plain, name)
            XCTAssertEqual(bytes, Self.encryptionFixtureText(name), name)
            XCTAssertEqual(Self.crc32(bytes), Self.encryptionFixtureCRCs[name], name)
        }
        // Through the attachment reader and the mail-source steps.
        assertFourFiles(try DocumentTextExtractor.extract(fileURL: plainURL, kind: .rar, logicalName: "solid4.rar"), "plain solid")
        let steps = try ParserFactory.containerSteps(plainURL, format: .rar)
        let out = scratch.appendingPathComponent("c.txt")
        try XCTUnwrap(steps.first { $0.name == "c.txt" }).extract(out)
        XCTAssertEqual(try Data(contentsOf: out), Self.encryptionFixtureText("c.txt"))
        XCTAssertEqual(SourceFormatClassifier.preflight(url: plainURL).condition, .ready)

        // A damaged member of the solid stream: it and the members after it are named, never wrong bytes.
        var damaged = [UInt8](plainBytes)
        let b = try XCTUnwrap(plain.archive.members.first { $0.name == "b.txt" })
        damaged[Int(b.dataOffset)] ^= 0xFF
        let damagedURL = scratch.appendingPathComponent("damaged-solid4.rar")
        try Data(damaged).write(to: damagedURL)
        let byPath = children(try DocumentTextExtractor.extract(fileURL: damagedURL, kind: .rar, logicalName: "d.rar"))
        XCTAssertEqual(byPath["a.txt"]?.state, .extracted)
        for name in ["b.txt", "c.txt", "d.txt"] {
            XCTAssertNotEqual(byPath[name]?.state, .extracted, "\(name): \(byPath[name]?.note ?? "")")
            XCTAssertNotNil(byPath[name]?.note, name)
        }
    }

    /// Encrypted members with the password given through Unlock…: RAR 3/4
    /// (AES-128, SHA-1 key derivation) and RAR 5.0 (AES-256, PBKDF2, check
    /// value, checksums keyed to the password), solid and not.
    func testR6_encryptedMembersOpenWithPassword_wrongPasswordNamed() throws {
        for name in ["test_read_format_rar4_encrypted.rar", "test_read_format_rar5_encrypted.rar"] {
            // b.txt is under "password", d.txt under "password2".
            let first = children(try DocumentTextExtractor.extract(fileURL: fixture(name), kind: .rar, logicalName: name, password: "password"))
            for plain in ["a.txt", "b.txt", "c.txt"] {
                XCTAssertEqual(first[plain]?.state, .extracted, "\(name) \(plain): \(first[plain]?.note ?? "")")
                XCTAssertEqual(first[plain]?.text, "This is from \(plain)", name)
            }
            XCTAssertEqual(first["d.txt"]?.state, .locked, name)
            XCTAssertEqual(first["d.txt"]?.note, "the password did not open it", name)

            let second = children(try DocumentTextExtractor.extract(fileURL: fixture(name), kind: .rar, logicalName: name, password: "password2"))
            XCTAssertEqual(second["d.txt"]?.state, .extracted, "\(name): \(second["d.txt"]?.note ?? "")")
            XCTAssertEqual(second["d.txt"]?.text, "This is from d.txt")
            XCTAssertEqual(second["b.txt"]?.note, "the password did not open it", name)
            XCTAssertEqual(second["a.txt"]?.state, .extracted, "plain members do not need the password")

            // Without a password: locked as before.
            let none = children(try DocumentTextExtractor.extract(fileURL: fixture(name), kind: .rar, logicalName: name))
            XCTAssertEqual(none["b.txt"]?.note, "password-protected")
        }

        // Solid + encrypted, RAR 4 and RAR 5.0: every member, in order and out of order.
        for name in ["test_read_format_rar4_solid_encrypted.rar", "test_read_format_rar5_solid_encrypted.rar"] {
            assertFourFiles(try DocumentTextExtractor.extract(fileURL: fixture(name), kind: .rar, logicalName: name, password: "password"), name)
            let extractor = try RARReader.Extractor(url: fixture(name), password: "password")
            for member in ["c.txt", "a.txt", "d.txt"] { XCTAssertEqual(try extractWhole(extractor, member), Self.encryptionFixtureText(member), "\(name) \(member)") }
            let wrong = try DocumentTextExtractor.extract(fileURL: fixture(name), kind: .rar, logicalName: name, password: "not it")
            XCTAssertEqual(wrong.children.count, 4)
            XCTAssertTrue(wrong.children.allSatisfy { $0.state == .locked && $0.note == "the password did not open it" },
                          "\(name): \(wrong.children.map { "\($0.path) \($0.state) \($0.note ?? "")" })")
            let locked = try DocumentTextExtractor.extract(fileURL: fixture(name), kind: .rar, logicalName: name)
            XCTAssertTrue(locked.children.allSatisfy { $0.state == .locked && $0.note == "password-protected" }, name)
        }

        // RAR 5.0 keys its checksums to the password: the stored CRC-32 is the MAC of WinRAR's plain one.
        let rar5 = try RARReader.read(url: fixture("test_read_format_rar5_encrypted.rar"))
        let b = try XCTUnwrap(rar5.members.first { $0.name == "b.txt" })
        let encryption = try XCTUnwrap(b.encryption)
        XCTAssertEqual(encryption.scheme, .rar5)
        XCTAssertTrue(encryption.useMAC)
        XCTAssertEqual(encryption.log2Count, 15)
        let keys = RARCrypto.rar5Keys(password: "password", salt: try XCTUnwrap(encryption.salt), log2Count: encryption.log2Count)
        XCTAssertEqual(keys.passwordCheck, encryption.passwordCheck, "the check value recognises the right password")
        XCTAssertNotEqual(RARCrypto.rar5Keys(password: "password2", salt: encryption.salt!, log2Count: 15).passwordCheck, encryption.passwordCheck)
        XCTAssertEqual(RARCrypto.mac(crc: Self.encryptionFixtureCRCs["b.txt"]!, hashKey: keys.hashKey), b.crc32)

        // A wrong RAR 5.0 password is known from the check value alone; RAR 4 from the decode.
        let rar5Extractor = try RARReader.Extractor(url: fixture("test_read_format_rar5_encrypted.rar"), password: "nope")
        XCTAssertThrowsError(try extractWhole(rar5Extractor, "b.txt")) { error in
            XCTAssertEqual(error as? RARReader.ReadError, .wrongPassword(member: "b.txt"))
            XCTAssertEqual(ContainerTextExtractor.classify(error).note, "the password did not open it")
            XCTAssertEqual(ContainerTextExtractor.classify(error).state, .locked)
        }
        let rar4Extractor = try RARReader.Extractor(url: fixture("test_read_format_rar4_encrypted.rar"), password: "nope")
        XCTAssertThrowsError(try extractWhole(rar4Extractor, "b.txt")) { error in
            XCTAssertEqual(error as? RARReader.ReadError, .wrongPassword(member: "b.txt"))
        }
    }

    /// Encrypted headers (RAR 4 MHD_PASSWORD, RAR 5.0 archive encryption
    /// header): the member list is known only with the password.
    func testR6_encryptedHeadersOpenWithPassword() throws {
        for name in ["test_read_format_rar4_encrypted_filenames.rar", "test_read_format_rar4_solid_encrypted_filenames.rar",
                     "test_read_format_rar5_encrypted_filenames.rar", "test_read_format_rar5_solid_encrypted_filenames.rar"] {
            XCTAssertThrowsError(try RARReader.read(url: fixture(name)), name) { error in
                XCTAssertEqual(error as? RARReader.ReadError, .encryptedHeaders, name)
            }
            XCTAssertThrowsError(try DocumentTextExtractor.extract(fileURL: fixture(name), kind: .rar, logicalName: name), name) { error in
                XCTAssertEqual(error as? OfficeTextExtractor.ExtractError, .encrypted, name)
            }
            XCTAssertThrowsError(try DocumentTextExtractor.extract(fileURL: fixture(name), kind: .rar, logicalName: name, password: "password2"), name) { error in
                XCTAssertEqual(error as? OfficeTextExtractor.ExtractError, .wrongPassword, name)
            }
            let archive = try RARReader.read(url: fixture(name), password: "password")
            XCTAssertTrue(archive.headersEncrypted, name)
            XCTAssertNil(archive.damage, name)
            XCTAssertEqual(archive.members.map(\.name), ["a.txt", "b.txt", "c.txt", "d.txt"], name)
            for member in archive.members { XCTAssertEqual(member.unpackedSize, 18, name) }
            assertFourFiles(try DocumentTextExtractor.extract(fileURL: fixture(name), kind: .rar, logicalName: name, password: "password"), name)
        }
        // libarchive's other encrypted RAR 4 files (WinRAR, password "12345678"): foo.txt / bar.txt,
        // "data of <name>\n", 16 bytes each, checked against WinRAR's CRC-32 (0xA6AD865C / 0xCD90E2BE).
        func data(_ name: String) -> Data { Data("data of \(name)\n".utf8) }
        for name in ["test_read_format_rar_encryption_header.rar", "test_read_format_rar_encryption_data.rar",
                     "test_read_format_rar_encryption_partially.rar"] {
            let extractor = try RARReader.Extractor(url: fixture(name), password: "12345678")
            XCTAssertEqual(extractor.archive.members.map(\.name), ["foo.txt", "bar.txt"], name)
            for member in ["foo.txt", "bar.txt"] {
                let bytes = try extractWhole(extractor, member)
                XCTAssertEqual(bytes, data(member), "\(name) \(member)")
                XCTAssertEqual(Self.crc32(bytes), member == "foo.txt" ? 0xA6AD_865C : 0xCD90_E2BE, "\(name) \(member)")
            }
            let byPath = children(try DocumentTextExtractor.extract(fileURL: fixture(name), kind: .rar, logicalName: name, password: "12345678"))
            XCTAssertEqual(byPath["foo.txt"]?.text, "data of foo.txt\n", name)
            XCTAssertEqual(byPath["bar.txt"]?.state, .extracted, name)
        }
        XCTAssertThrowsError(try DocumentTextExtractor.extract(fileURL: fixture("test_read_format_rar_encryption_header.rar"), kind: .rar,
                                                               logicalName: "h.rar", password: "password")) { error in
            XCTAssertEqual(error as? OfficeTextExtractor.ExtractError, .wrongPassword)
        }
        // Partially encrypted: the plain member needs no password, the encrypted one is named.
        let partial = children(try DocumentTextExtractor.extract(fileURL: fixture("test_read_format_rar_encryption_partially.rar"), kind: .rar,
                                                                 logicalName: "p.rar", password: "wrong"))
        XCTAssertEqual(partial["bar.txt"]?.text, "data of bar.txt\n")
        XCTAssertEqual(partial["foo.txt"]?.note, "the password did not open it")
    }

    /// The SHA-1 under RAR 3's key derivation: identical to SHA-1 when the
    /// write-back cannot happen (CryptoKit as the oracle, every length to
    /// three blocks); the write-back changes the next round's input only
    /// for a block hashed straight from the caller's buffer.
    func testR6_rar29SHA1MatchesSHA1_andKeyDerivationPathsAgree() throws {
        for length in [0, 1, 55, 56, 63, 64, 65, 127, 128, 191, 200] {
            var data = (0..<length).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) }
            var sha = RARCrypto.RAR29SHA1()
            sha.update(&data, writeBack: false)
            XCTAssertEqual(sha.finalize(), Array(Insecure.SHA1.hash(data: data)), "length \(length)")
        }
        var block = [UInt8](repeating: 0x61, count: 130)
        let before = block
        var quirk = RARCrypto.RAR29SHA1()
        quirk.update(&block, writeBack: true)
        XCTAssertEqual(quirk.finalize(), Array(Insecure.SHA1.hash(data: before)), "the digest itself is SHA-1")
        // 130 bytes into an empty context: bytes 0…63 go through the context's own buffer, 64…127 are hashed in place.
        XCTAssertEqual(Array(block[0..<64]), Array(before[0..<64]), "a block copied into the context is not written back")
        XCTAssertNotEqual(Array(block[64..<128]), Array(before[64..<128]), "the block hashed from the caller's buffer was overwritten")
        XCTAssertEqual(Array(block[128...]), Array(before[128...]), "the tail is untouched")
        // Below 65 bytes of password + salt both derivations agree (the CryptoKit path is the one the fixtures verify).
        let salt: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        XCTAssertEqual(RARCrypto.rar3KeyCryptoKitForTesting(password: "password", salt: salt), RARCrypto.rar3KeyQuirkForTesting(password: "password", salt: salt))
    }

    /// A two-volume RAR set attached to one message: the extractor reads it
    /// with the other volume handed over as a sibling (the app's
    /// `volumeSiblings`), whatever the attachment files are called on disk.
    func testR6_twoVolumeSetAttachedAsSiblingsRead() throws {
        let payload = Data((0..<3000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let second = Data("the second file, whole in volume 2\n".utf8)
        let volumes = Self.twoVolumeStoredRAR4(splitting: payload, named: "report.bin", then: second, named: "notes.txt", at: 1200)
        let v1 = scratch.appendingPathComponent(UUID().uuidString)
        let v2 = scratch.appendingPathComponent(UUID().uuidString)
        try volumes.0.write(to: v1)
        try volumes.1.write(to: v2)

        let extractor = try RARReader.Extractor(url: v1, logicalName: "mail.part1.rar", siblings: [.init(name: "mail.part2.rar", url: v2)])
        XCTAssertTrue(extractor.isVolumeSet)
        XCTAssertEqual(extractor.volumes.count, 2)
        XCTAssertEqual(extractor.archive.members.map(\.name), ["report.bin", "notes.txt"])
        XCTAssertEqual(extractor.archive.members[0].lastVolume, 1, "merged across the two volumes")
        XCTAssertEqual(try extractWhole(extractor, "report.bin"), payload)
        XCTAssertEqual(try extractWhole(extractor, "notes.txt"), second)

        let result = try DocumentTextExtractor.extract(fileURL: v1, kind: .rar, logicalName: "mail.part1.rar",
                                                       siblings: [.init(name: "mail.part2.rar", url: v2)])
        let byPath = children(result)
        assertDecoded(try XCTUnwrap(byPath["report.bin"]), equals: payload)
        XCTAssertEqual(byPath["notes.txt"]?.text, "the second file, whole in volume 2\n")
        // Opened from the second attachment, the first handed over.
        let fromSecond = children(try DocumentTextExtractor.extract(fileURL: v2, kind: .rar, logicalName: "mail.part2.rar",
                                                                    siblings: [.init(name: "mail.part1.rar", url: v1)]))
        XCTAssertEqual(fromSecond["report.bin"]?.sha256, Self.sha256(payload))
        // Without the sibling: the split member names the missing volume, the rest is read.
        let alone = children(try DocumentTextExtractor.extract(fileURL: v1, kind: .rar, logicalName: "mail.part1.rar", siblings: []))
        XCTAssertEqual(alone["report.bin"]?.note, "not opened: volume 2 (mail.part2.rar) missing")
    }

    /// A RAR 4 two-volume set written from the format description: stored
    /// `first` split at `split` over the two volumes, `second` whole in volume 2.
    static func twoVolumeStoredRAR4(splitting first: Data, named firstName: String, then second: Data, named secondName: String,
                                    at split: Int) -> (Data, Data) {
        func block(_ type: UInt8, _ flags: UInt16, _ body: [UInt8]) -> [UInt8] {
            let size = UInt16(7 + body.count)
            var b: [UInt8] = [0, 0, type, UInt8(flags & 0xFF), UInt8(flags >> 8), UInt8(size & 0xFF), UInt8(size >> 8)] + body
            let crc = UInt16(truncatingIfNeeded: ZIPArchiveReader.CRC32.checksum(Data(b[2...])))
            b[0] = UInt8(crc & 0xFF); b[1] = UInt8(crc >> 8)
            return b
        }
        func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)] }
        func file(_ name: String, flags: UInt16, part: Data, total: Int, crc: UInt32) -> [UInt8] {
            let n = [UInt8](name.utf8)
            // PACK_SIZE, UNP_SIZE, HOST_OS (Windows), FILE_CRC, FTIME, UNP_VER 29, METHOD store, NAME_SIZE, ATTR (archive)
            let body = le32(UInt32(part.count)) + le32(UInt32(total)) + [2] + le32(crc) + le32(0x5B21_0000) + [29, 0x30]
                + [UInt8(n.count & 0xFF), UInt8(n.count >> 8)] + le32(0x20) + n
            return block(0x74, 0x8000 | flags, body) + [UInt8](part)
        }
        let marker: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]
        let partA = first.prefix(split), partB = first.suffix(from: split)
        let crc = ZIPArchiveReader.CRC32.checksum
        var v1 = marker + block(0x73, 0x0001 | 0x0100, [0, 0, 0, 0, 0, 0])
        v1 += file(firstName, flags: 0x0002, part: Data(partA), total: first.count, crc: crc(Data(partA)))
        v1 += block(0x7B, 0x4001, [])
        var v2 = marker + block(0x73, 0x0001, [0, 0, 0, 0, 0, 0])
        v2 += file(firstName, flags: 0x0001, part: Data(partB), total: first.count, crc: crc(first))
        v2 += file(secondName, flags: 0, part: second, total: second.count, crc: crc(second))
        v2 += block(0x7B, 0x4000, [])
        return (Data(v1), Data(v2))
    }

    // MARK: - Robustness and attribution

    /// 200 mutations of real compressed archives through the decoder: every
    /// outcome is a result or a named error, never a trap.
    func testRAR_decoderFuzz200MutationsNeverTrap() throws {
        let seeds = ["test_read_format_rar_compress_normal.rar", "test_read_format_rar5_multiple_files_solid.rar",
                     "test_read_format_rar5_blake2.rar", "test_read_format_rar3_lowdist_reset.rar"].map { fixture($0) }
        var generator = SystemRandomNumberGenerator()
        var outcomes: [String: Int] = [:]
        for round in 0..<200 {
            var bytes = [UInt8](try Data(contentsOf: seeds[round % seeds.count]))
            for _ in 0..<Int.random(in: 1...6, using: &generator) {
                bytes[Int.random(in: 7..<bytes.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
            }
            if round % 9 == 0 { bytes.removeLast(Int.random(in: 1...min(40, bytes.count - 8), using: &generator)) }
            let mutated = scratch.appendingPathComponent("fuzz-\(round).rar")
            try Data(bytes).write(to: mutated)
            do {
                let extractor = try RARReader.Extractor(url: mutated)
                for member in extractor.archive.members where !member.isDirectory {
                    let out = scratch.appendingPathComponent("out-\(round)")
                    do { try extractor.extract(member, to: out, maxOutputBytes: 1 << 22); outcomes["read", default: 0] += 1 }
                    catch { outcomes["member error", default: 0] += 1 }
                    try? FileManager.default.removeItem(at: out)
                }
            } catch { outcomes["open error", default: 0] += 1 }
            try? FileManager.default.removeItem(at: mutated)
        }
        XCTAssertGreaterThan(outcomes.values.reduce(0, +), 0, "\(outcomes)")
    }

    func testVendoredLibarchive_versionAndNoticeMatchCOPYING() throws {
        XCTAssertEqual(RARReader.decoderVersion, "libarchive 3.8.11")
        let copying = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CLibArchiveRAR/COPYING"), encoding: .utf8)
        let licence = try XCTUnwrap(copying.range(of: "Copyright (c) 2003-2018 <author(s)>")).lowerBound
        let body = copying[licence...].trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(VendoredNotices.libarchive.contains(body), "the app's notice carries libarchive's licence verbatim")
        XCTAssertEqual(VendoredNotices.all.count, 1)
    }
}
