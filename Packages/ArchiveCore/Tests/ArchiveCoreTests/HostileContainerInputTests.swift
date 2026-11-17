//
//  HostileContainerInputTests.swift
//  ArchiveCoreTests
//
//  CODE_REVIEW_2026-11-16 A2 / A3 / A12 / A15 / A20: container readers fed
//  hostile bytes built here. Each case trapped, hung or exhausted memory
//  before its fix; with it, each is a named error (or a bounded read).
//
//  A2  — declared sizes near Int64.max: `size + diskMargin` and
//        `offset + size` overflowed (ZIP64, TAR base-256 / PAX, 7z, RAR).
//  A3  — CAB `cString` sliced past the end (cbCFHeader = 0xFFFF).
//  A12 — split-ZIP volume check summed a ZIP64 offset of Int64.max.
//  A15 — a whole CAB folder was inflated and cached; now streamed to the
//        member's end, and a CFDATA block over 32 KiB is refused.
//  A20 — the ZIP central directory was read in one read; now streamed.
//

import XCTest
import Compression
@testable import ArchiveCore

final class HostileContainerInputTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("hostile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir); super.tearDown() }

    // MARK: - Byte helpers

    private func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
    private func le32(_ v: UInt32) -> Data { Data((0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) }) }
    private func le64(_ v: UInt64) -> Data { Data((0..<8).map { UInt8((v >> (8 * $0)) & 0xFF) }) }

    /// Plenty of room, so only an overflowing "needed" can fail the disk check.
    private let plentyOfDisk: Int64 = 1 << 50

    // MARK: - A2 ZIP: ZIP64 uncompressed size of Int64.max

    func testA2_zip64SizeNearInt64Max_isInsufficientDisk_notATrap() throws {
        let name = Data("huge.mbox".utf8)
        let payload = Data("x".utf8)
        var file = le32(0x0403_4B50) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0)
        file += le32(0) + le32(UInt32(payload.count)) + le32(1) + le16(UInt16(name.count)) + le16(0) + name + payload
        let cdOffset = UInt32(file.count)
        let extra = le16(0x0001) + le16(8) + le64(UInt64(Int64.max))   // only the uncompressed size is saturated
        var central = le32(0x0201_4B50) + le16(45) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0)
        central += le32(0) + le32(UInt32(payload.count)) + le32(0xFFFF_FFFF)
        central += le16(UInt16(name.count)) + le16(UInt16(extra.count)) + le16(0) + le16(0) + le16(0) + le32(0) + le32(0)
        central += name + extra
        file += central
        file += le32(0x0605_4B50) + le16(0) + le16(0) + le16(1) + le16(1) + le32(UInt32(central.count)) + le32(cdOffset) + le16(0)
        let url = dir.appendingPathComponent("huge.zip")
        try file.write(to: url)

        let member = try XCTUnwrap(try ZIPArchiveReader.members(of: url).first)
        XCTAssertEqual(member.uncompressedSize, Int64.max)
        XCTAssertThrowsError(try ZIPArchiveReader.extract(member, from: url, to: dir.appendingPathComponent("out"), availableDiskBytes: plentyOfDisk)) { error in
            XCTAssertEqual(error as? ZIPArchiveReader.ReadError,
                           .insufficientDisk(member: "huge.mbox", needed: Int64.max, available: plentyOfDisk))
        }
    }

    // MARK: - A2 TAR: PAX size=Int64.max, base-256 size near Int64.max

    private func tarHeader(name: String, size: Data, type: UInt8) -> Data {
        var block = [UInt8](repeating: 0, count: 512)
        let n = Array(name.utf8); block.replaceSubrange(0..<n.count, with: n)
        for (i, c) in Array("0000644\0".utf8).enumerated() { block[100 + i] = c }
        for (i, c) in Array("0000000\0".utf8).enumerated() { block[108 + i] = c; block[116 + i] = c }
        block.replaceSubrange(124..<136, with: [UInt8](size))
        for (i, c) in Array("00000000000\0".utf8).enumerated() { block[136 + i] = c }
        block[156] = type
        for (i, c) in Array("ustar\0".utf8).enumerated() { block[257 + i] = c }
        block[263] = 0x30; block[264] = 0x30
        for i in 148..<156 { block[i] = 0x20 }
        let sum = block.reduce(0) { $0 + Int($1) }
        let text = Array(String(format: "%06o", sum).utf8) + [0, 0x20]
        block.replaceSubrange(148..<156, with: text)
        return Data(block)
    }
    private func octalSize(_ v: Int) -> Data { Data(String(format: "%011o", v).utf8) + Data([0]) }
    private func base256Size(_ v: Int64) -> Data { Data([0x80, 0, 0, 0]) + Data((0..<8).reversed().map { UInt8((UInt64(v) >> (8 * UInt64($0))) & 0xFF) }) }
    private func padded(_ d: Data) -> Data { d + Data(count: (512 - d.count % 512) % 512) }

    func testA2_tarPaxSizeInt64Max_isTruncated_notATrap() throws {
        let pax = Data("28 size=9223372036854775807\n".utf8)
        var file = tarHeader(name: "PaxHeader/m.mbox", size: octalSize(pax.count), type: 0x78) + padded(pax)
        file += tarHeader(name: "m.mbox", size: octalSize(0), type: 0x30)
        file += Data(count: 1024)
        let url = dir.appendingPathComponent("pax.tar")
        try file.write(to: url)
        XCTAssertThrowsError(try TARReader.members(of: url)) { error in
            guard case .truncated(let what)? = error as? TARReader.ReadError else { return XCTFail("\(error)") }
            XCTAssertTrue(what.contains("9223372036854775807"), what)
        }
    }

    func testA2_tarBase256SizeNearInt64Max_isTruncated_notATrap() throws {
        for type: UInt8 in [0x4B, 0x30] {   // 'K' (skipped by its rounded size) and a regular file
            let file = tarHeader(name: "m.mbox", size: base256Size(Int64.max), type: type) + Data(count: 1024)
            let url = dir.appendingPathComponent("b256-\(type).tar")
            try file.write(to: url)
            XCTAssertThrowsError(try TARReader.members(of: url), "type \(type)") { error in
                guard case .truncated? = error as? TARReader.ReadError else { return XCTFail("\(error)") }
            }
        }
    }

    func testA2_tarPaxNegativeSize_isRefused_notAWalkBackwards() throws {
        let pax = Data("14 size=-1024\n".utf8)
        var file = tarHeader(name: "PaxHeader/m", size: octalSize(pax.count), type: 0x78) + padded(pax)
        file += tarHeader(name: "m", size: octalSize(0), type: 0x30) + Data(count: 1024)
        let url = dir.appendingPathComponent("neg.tar")
        try file.write(to: url)
        XCTAssertThrowsError(try TARReader.members(of: url)) { error in
            guard case .truncated? = error as? TARReader.ReadError else { return XCTFail("\(error)") }
        }
    }

    func testA2_tarExtractSizeInt64Max_isInsufficientDisk() throws {
        let url = dir.appendingPathComponent("any.tar")
        try (tarHeader(name: "m", size: octalSize(0), type: 0x30) + Data(count: 1024)).write(to: url)
        let member = TARReader.Member(name: "m", size: Int64.max, dataOffset: 512, typeFlag: 0x30)
        XCTAssertThrowsError(try TARReader.extract(member, from: url, to: dir.appendingPathComponent("out"), availableDiskBytes: plentyOfDisk)) { error in
            guard case .insufficientDisk(_, let needed, _)? = error as? TARReader.ReadError else { return XCTFail("\(error)") }
            XCTAssertEqual(needed, Int64.max)
        }
    }

    // MARK: - A2 7z: member size Int64.max

    func testA2_sevenZipSizeInt64Max_isInsufficientDisk_notATrap() throws {
        let url = dir.appendingPathComponent("one.7z")
        try SevenZipFixtureWriter.write([.init(name: "a.txt", data: Data("hello".utf8))], to: url)
        let reader = try SevenZipReader(url: url)
        let real = try XCTUnwrap(reader.members.first)
        let forged = SevenZipReader.Member(name: real.name, size: Int64.max, crc32: nil, isDirectory: false, isAnti: false, isSymlink: false,
                                           isEncrypted: false, method: real.method, unsupportedMethod: nil, folderIndex: real.folderIndex,
                                           offsetInFolder: 0, attributes: nil)
        XCTAssertThrowsError(try reader.extract(forged, to: dir.appendingPathComponent("out"), availableDiskBytes: plentyOfDisk)) { error in
            guard case .insufficientDisk(_, let needed, _)? = error as? SevenZipReader.ReadError else { return XCTFail("\(error)") }
            XCTAssertEqual(needed, Int64.max)
        }
    }

    // MARK: - A2 RAR 1.5–4.x: 64-bit sizes near Int64.max and negative

    private func rar4Block(type: UInt8, flags: UInt16, body: Data) -> Data {
        let rest = Data([type]) + le16(flags) + le16(UInt16(7 + body.count)) + body
        return le16(UInt16(truncatingIfNeeded: ZIPArchiveReader.CRC32.checksum(rest))) + rest
    }

    /// A stored RAR4 member with the 64-bit size flag (0x0100), both sizes = `size`.
    private func rar4StoredMember(size: UInt64, data: Data) -> Data {
        var out = Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00])
        out += rar4Block(type: 0x73, flags: 0, body: le16(0) + le32(0))
        let name = Data("m.eml".utf8)
        let low = UInt32(truncatingIfNeeded: size), high = UInt32(truncatingIfNeeded: size >> 32)
        let hostAndCRC: Data = Data([UInt8(3)]) + le32(0) + le32(0)          // HOST_OS, FILE_CRC, FTIME
        let versionMethod: Data = Data([UInt8(20), UInt8(0x30)])          // UNP_VER 2.0, stored
        var body: Data = le32(low) + le32(low)                            // PACK_SIZE, UNP_SIZE (low words)
        body += hostAndCRC
        body += versionMethod
        body += le16(UInt16(name.count)) + le32(0x81A4)                   // NAME_SIZE, ATTR
        body += le32(high) + le32(high)                                   // HIGH_PACK_SIZE, HIGH_UNP_SIZE
        body += name
        out += rar4Block(type: 0x74, flags: 0x8000 | 0x0100, body: body)
        out += data
        out += rar4Block(type: 0x7B, flags: 0x4000, body: Data())
        return out
    }

    func testA2_rar4SizeNearInt64Max_isInsufficientDisk_notATrap() throws {
        let url = dir.appendingPathComponent("huge.rar")
        try rar4StoredMember(size: UInt64(Int64.max) - 8, data: Data("hi".utf8)).write(to: url)
        let extractor = try RARReader.Extractor(url: url)
        let member = try XCTUnwrap(extractor.archive.members.first)
        XCTAssertEqual(member.unpackedSize, Int64.max - 8)
        XCTAssertThrowsError(try extractor.extract(member, to: dir.appendingPathComponent("out"), availableDiskBytes: plentyOfDisk)) { error in
            guard case .insufficientDisk(_, let needed, _)? = error as? RARReader.ReadError else { return XCTFail("\(error)") }
            XCTAssertEqual(needed, Int64.max)
        }
    }

    func testA2_rar4NegativeSize_isDamage_notATrapOrLoop() throws {
        // Top bit set: the 64-bit size reads as Int64.min. Before the fix the
        // walk went backwards and `length - packedSize` overflowed in extract.
        let url = dir.appendingPathComponent("neg.rar")
        try rar4StoredMember(size: UInt64(1) << 63, data: Data()).write(to: url)
        let extractor = try RARReader.Extractor(url: url)
        XCTAssertNotNil(extractor.archive.damage)
        let member = try XCTUnwrap(extractor.archive.members.first)
        XCTAssertThrowsError(try extractor.extract(member, to: dir.appendingPathComponent("out"), availableDiskBytes: plentyOfDisk)) { error in
            guard case .truncated? = error as? RARReader.ReadError else { return XCTFail("\(error)") }
        }
    }

    func testA2_rar4SizeMinusHeaderLength_endsTheListing_notALoop() throws {
        // A size of minus the header's own length pointed the next block back
        // at the same header: the listing never finished.
        let headerLength = 32 + 8 + 5   // block head and fixed fields + 64-bit sizes + "m.eml"
        let loop = dir.appendingPathComponent("loop.rar")
        try rar4StoredMember(size: UInt64(bitPattern: -Int64(headerLength)), data: Data()).write(to: loop)
        let looping = try RARReader.Extractor(url: loop)
        XCTAssertNotNil(looping.archive.damage)
        XCTAssertEqual(looping.archive.members.count, 1)
    }

    // MARK: - A12 split ZIP with a ZIP64 local-header offset of Int64.max

    func testA12_splitZipLocalOffsetInt64Max_isNotATrap() throws {
        let z01 = dir.appendingPathComponent("s.z01"), last = dir.appendingPathComponent("s.zip")
        try (Data([0x50, 0x4B, 0x07, 0x08]) + Data(count: 96)).write(to: z01)
        let name = Data("m.eml".utf8)
        let extra = le16(0x0001) + le16(8) + le64(0x7FFF_FFFF_FFFF_FFFF)
        var central = le32(0x0201_4B50) + le16(45) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0)
        central += le32(0) + le32(10) + le32(10)
        central += le16(UInt16(name.count)) + le16(UInt16(extra.count)) + le16(0) + le16(0) + le16(0) + le32(0) + le32(0xFFFF_FFFF)
        central += name + extra
        // EOCD: this disk 1, directory on disk 1 at offset 0 of that disk.
        let file = central + le32(0x0605_4B50) + le16(1) + le16(1) + le16(1) + le16(1) + le32(UInt32(central.count)) + le32(0) + le16(0)
        try file.write(to: last)

        // Before the fix the volume check trapped; now the member is a named
        // failure (and, the only member, the archive is "not a package").
        XCTAssertThrowsError(try DocumentTextExtractor.extract(fileURL: last, kind: .zip, logicalName: "s.zip", siblings: [.init(url: z01)])) { error in
            guard case .notAPackage(let detail)? = error as? OfficeTextExtractor.ExtractError else { return XCTFail("\(error)") }
            XCTAssertTrue(detail.contains("m.eml") && detail.contains("overflows"), detail)
        }
    }

    // MARK: - CAB builders

    private struct CabFile { let name: String; let size: Int; let offset: Int }

    /// One folder of `blocks` (each: uncompressed size, payload bytes as stored), the given files.
    private func cabinet(compression: UInt16, blocks: [(uncompressed: Int, payload: Data)], files: [CabFile]) -> Data {
        var fileTable = Data()
        for f in files {
            fileTable += le32(UInt32(f.size)) + le32(UInt32(f.offset)) + le16(0) + le16(0) + le16(0) + le16(0x20)
            fileTable += Data(f.name.utf8) + Data([0])
        }
        let coffFiles = 36 + 8
        let dataStart = coffFiles + fileTable.count
        var data = Data()
        for blk in blocks { data += le32(0) + le16(UInt16(blk.payload.count)) + le16(UInt16(blk.uncompressed)) + blk.payload }
        var out = Data("MSCF".utf8) + le32(0) + le32(UInt32(dataStart + data.count)) + le32(0) + le32(UInt32(coffFiles)) + le32(0)
        out += Data([3, 1]) + le16(1) + le16(UInt16(files.count)) + le16(0) + le16(0) + le16(0)
        out += le32(UInt32(dataStart)) + le16(UInt16(blocks.count)) + le16(compression)
        return out + fileTable + data
    }

    /// One MSZIP block: "CK" + raw DEFLATE of `bytes` (no preset dictionary needed:
    /// each block here compresses its own bytes independently).
    private func mszip(_ bytes: [UInt8]) throws -> Data {
        let compressed = try (Data(bytes) as NSData).compressed(using: .zlib) as Data
        return Data("CK".utf8) + compressed
    }

    // MARK: - A3 CAB header strings past the end

    func testA3_cabinetReservedHeaderPastEnd_isAnError_notATrap() throws {
        // flags 0x0004 (reserve) | 0x0001 (previous cabinet): cbCFHeader = 0xFFFF puts the string at 65,575 in a 60-byte file.
        var file = Data("MSCF".utf8) + le32(0) + le32(60) + le32(0) + le32(44) + le32(0)
        file += Data([3, 1]) + le16(0) + le16(0) + le16(0x0005) + le16(0) + le16(0)
        file += le16(0xFFFF) + Data([0, 0])
        file += Data(count: 60 - file.count)
        XCTAssertEqual(file.count, 60)
        XCTAssertThrowsError(try CabinetReader(data: file)) { error in
            XCTAssertTrue(error is CabinetReader.ReadError, "\(error)")
        }
    }

    // MARK: - A15 CAB folder expansion

    func testA15_cabinetBlockOver32KiB_isRefusedByName() throws {
        let bytes = [UInt8](repeating: 0x41, count: 40_000)
        let file = cabinet(compression: 1, blocks: [(40_000, try mszip(bytes))], files: [CabFile(name: "a.one", size: 40_000, offset: 0)])
        let cab = try CabinetReader(data: file)
        XCTAssertThrowsError(try cab.extract(cab.members[0])) { error in
            let text = (error as? CabinetReader.ReadError)?.text ?? "\(error)"
            XCTAssertTrue(text.contains("at most 32768"), text)
        }
    }

    func testA15_cabinetMemberIsDecodedOnlyToItsEnd() throws {
        // Block 1 holds the member; block 2 is not MSZIP at all. The whole-folder
        // decoder refused the member because of a block it did not need.
        let first = [UInt8]((0..<32_768).map { UInt8($0 % 251) })
        let file = cabinet(compression: 1, blocks: [(32_768, try mszip(first)), (32_768, Data("XXjunk".utf8))],
                           files: [CabFile(name: "a.one", size: 100, offset: 10)])
        let cab = try CabinetReader(data: file)
        XCTAssertEqual(try cab.extract(cab.members[0]), Array(first[10..<110]))
    }

    func testA15_cabinetStreamedMembersAcrossBlocks_inAndOutOfOrder() throws {
        // Stored folder of three blocks; members straddle block boundaries.
        let blocks = (0..<3).map { k in [UInt8]((0..<30_000).map { UInt8(($0 * 7 + k * 13) % 256) }) }
        let all = blocks.flatMap { $0 }
        let files = [CabFile(name: "a", size: 29_990, offset: 5), CabFile(name: "b", size: 30_010, offset: 29_995),
                     CabFile(name: "c", size: 30_000, offset: 60_000), CabFile(name: "empty", size: 0, offset: 90_000)]
        let file = cabinet(compression: 0, blocks: blocks.map { ($0.count, Data($0)) }, files: files)
        let cab = try CabinetReader(data: file)
        for m in cab.members + cab.members.reversed() {
            XCTAssertEqual(try cab.extract(m), Array(all[m.offsetInFolder..<(m.offsetInFolder + m.size)]), m.name)
        }
        // MSZIP with history carried over: the same members through a compressed folder.
        let zipped = cabinet(compression: 1, blocks: try blocks.map { ($0.count, try mszip($0)) }, files: files)
        let zcab = try CabinetReader(data: zipped)
        for m in zcab.members.reversed() + zcab.members {
            XCTAssertEqual(try zcab.extract(m), Array(all[m.offsetInFolder..<(m.offsetInFolder + m.size)]), m.name)
        }
        // A member past the folder's end is still named.
        let past = cabinet(compression: 0, blocks: [(10, Data(count: 10))], files: [CabFile(name: "p", size: 5, offset: 8)])
        let pcab = try CabinetReader(data: past)
        XCTAssertThrowsError(try pcab.extract(pcab.members[0])) { error in
            XCTAssertTrue(((error as? CabinetReader.ReadError)?.text ?? "").contains("needs 5 bytes"), "\(error)")
        }
    }

    func testA15_cabinetMembersReadInOrder_decodeEachBlockOnce() throws {
        // Review a177c8b..dd0c10d #1: 200 small members across 8 blocks, read in
        // folder order. Each member ends mid-block, inside the next member's
        // start; the reader must serve the next member from the block it holds,
        // not restart the folder (members × blocks decodes).
        let blockSize = 1_000
        let blocks = (0..<8).map { k in [UInt8]((0..<blockSize).map { UInt8(($0 * 3 + k * 17) % 256) }) }
        let all = blocks.flatMap { $0 }
        let files = (0..<200).map { i in CabFile(name: "m\(i)", size: 40, offset: i * 40) }
        for compression: UInt16 in [0, 1] {
            let payloads = try blocks.map { compression == 0 ? Data($0) : try mszip($0) }
            let cab = try CabinetReader(data: cabinet(compression: compression, blocks: zip(blocks, payloads).map { ($0.0.count, $0.1) }, files: files))
            for m in cab.members {
                XCTAssertEqual(try cab.extract(m), Array(all[m.offsetInFolder..<(m.offsetInFolder + m.size)]), m.name)
            }
            XCTAssertEqual(cab.blocksDecoded, blocks.count, "compression \(compression): each block decoded once in order")
            // Out of order still restarts and still reads right.
            XCTAssertEqual(try cab.extract(cab.members[0]), Array(all[0..<40]))
        }
    }

    // MARK: - A20 ZIP central directory streamed

    /// A random-access source over a sparse virtual file: zeros except the
    /// given regions. It records the largest single read asked of it and
    /// refuses any read over 64 MiB (a whole-directory read of 2 GiB would
    /// otherwise allocate it).
    private final class VirtualSource: RandomAccessSource {
        let length: Int64
        let regions: [(offset: Int64, bytes: Data)]
        private(set) var largestRead = 0
        init(length: Int64, regions: [(offset: Int64, bytes: Data)]) { self.length = length; self.regions = regions }
        func read(at offset: Int64, count: Int) throws -> Data {
            largestRead = max(largestRead, count)
            guard count <= 64 << 20 else { throw CocoaError(.fileReadTooLarge) }
            guard offset >= 0, offset < length, count > 0 else { return Data() }
            let n = Int(min(Int64(count), length - offset))
            var out = Data(count: n)
            for r in regions {
                let lo = max(offset, r.offset), hi = min(offset + Int64(n), r.offset + Int64(r.bytes.count))
                if lo < hi {
                    out.replaceSubrange(Int(lo - offset)..<Int(hi - offset),
                                        with: r.bytes[(r.bytes.startIndex + Int(lo - r.offset))..<(r.bytes.startIndex + Int(hi - r.offset))])
                }
            }
            return out
        }
        func diskBase(_ disk: Int) -> Int64? { disk == 0 ? 0 : nil }
        func isDiskMissing(_ disk: Int) -> Bool { false }
        var volumeCount: Int { 1 }
    }

    func testA20_hugeCentralDirectory_isStreamed_notReadWhole() throws {
        // A 2 GiB central directory of zeros (a bad signature at entry 0): the
        // reader must find that through a bounded window, not one 2 GiB read.
        let cdSize: UInt32 = 0x8000_0000
        let eocd = le32(0x0605_4B50) + le16(0) + le16(0) + le16(1) + le16(1) + le32(cdSize) + le32(0) + le16(0)
        let source = VirtualSource(length: Int64(cdSize) + 22, regions: [(Int64(cdSize), eocd)])
        XCTAssertThrowsError(try ZIPArchiveReader.members(source: source)) { error in
            guard case .malformed(let what)? = error as? ZIPArchiveReader.ReadError else { return XCTFail("\(error)") }
            XCTAssertTrue(what.contains("signature at 0"), what)
        }
        XCTAssertLessThanOrEqual(source.largestRead, 4 << 20, "the central directory was read in one \(source.largestRead)-byte read")
    }

    func testA20_streamedDirectory_entriesAcrossWindows_allParsed() throws {
        // 30,000 entries × 106 bytes ≈ 3.2 MB of directory: entries straddle every window boundary.
        let count = 30_000
        var central = Data()
        var names: [String] = []
        for i in 0..<count {
            let name = String(format: "folder-%05d/message-with-a-long-enough-name-%05d.eml", i, i)
            names.append(name)
            let n = Data(name.utf8)
            central += le32(0x0201_4B50) + le16(20) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0)
            central += le32(UInt32(i)) + le32(0) + le32(0) + le16(UInt16(n.count)) + le16(0) + le16(i % 3 == 0 ? 3 : 0)
            central += le16(0) + le16(0) + le32(0) + le32(0) + n
            if i % 3 == 0 { central += Data("cmt".utf8) }
        }
        let eocd = le32(0x0605_4B50) + le16(0) + le16(0) + le16(0xFFFF & UInt16(count)) + le16(0xFFFF & UInt16(count))
            + le32(UInt32(central.count)) + le32(0) + le16(0)
        let source = VirtualSource(length: Int64(central.count + eocd.count), regions: [(0, central), (Int64(central.count), eocd)])
        let members = try ZIPArchiveReader.members(source: source)
        XCTAssertEqual(members.count, count)
        XCTAssertEqual(members.map(\.name), names)
        XCTAssertEqual(members.map(\.crc32), (0..<count).map { UInt32($0) })
        XCTAssertLessThanOrEqual(source.largestRead, 4 << 20)
    }
}
