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
        XCTAssertEqual(member(.rar4, version: 29, solid: true).compressionRefusal, "RAR 4 solid compression not opened (the vendored decoder reads only the first member of a RAR 4 solid archive)")
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
