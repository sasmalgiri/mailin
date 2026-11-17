//
//  HostilePSTInputTests.swift
//  ArchiveCoreTests
//
//  CODE_REVIEW_2026-11-16 A1 / A4 / A14: hostile PST bytes built in code.
//  Before the fix each of these trapped the process (Int(UInt64) with bit 63
//  set, a header read one byte past a 512/513-byte file) or multiplied one
//  block into thousands (an XBLOCK listing the same child again and again).
//  Each must now throw or return an empty/partial result.
//

import XCTest
import Foundation
@testable import ArchiveCore

final class HostilePSTInputTests: XCTestCase {

    // MARK: Byte-building helpers (little-endian)

    private static func put16(_ b: inout [UInt8], _ o: Int, _ v: UInt16) {
        b[o] = UInt8(v & 0xFF); b[o + 1] = UInt8(v >> 8)
    }
    private static func put32(_ b: inout [UInt8], _ o: Int, _ v: UInt32) {
        for i in 0..<4 { b[o + i] = UInt8(truncatingIfNeeded: v >> (8 * UInt32(i))) }
    }
    private static func put64(_ b: inout [UInt8], _ o: Int, _ v: UInt64) {
        for i in 0..<8 { b[o + i] = UInt8(truncatingIfNeeded: v >> (8 * UInt64(i))) }
    }

    /// A Unicode (wVer 23) header: "!BDN", NBT root at 224, BBT root at 240, bCryptMethod 0 at 513.
    private static func unicodeFile(size: Int, nbt: UInt64, bbt: UInt64) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: size)
        b[0] = 0x21; b[1] = 0x42; b[2] = 0x44; b[3] = 0x4E
        put16(&b, 10, 23)
        put64(&b, 224, nbt)
        put64(&b, 240, bbt)
        b[513] = 0
        return b
    }

    /// A 512-byte Unicode B-tree page at `at`: cEnt, cbEnt, cLevel at 488/490/491, ptype at 496.
    private static func page(_ b: inout [UInt8], at: Int, cEnt: Int, cbEnt: Int, level: UInt8, ptype: UInt8) {
        b[at + 488] = UInt8(cEnt)
        b[at + 489] = UInt8(cEnt)          // cEntMax
        b[at + 490] = UInt8(cbEnt)
        b[at + 491] = level
        b[at + 496] = ptype
        b[at + 497] = ptype
    }

    /// One BBT leaf entry: bid, ib, cb (24 bytes, Unicode).
    private static func bbtEntry(_ b: inout [UInt8], page: Int, index: Int, bid: UInt64, ib: UInt64, cb: UInt16) {
        let e = page + index * 24
        put64(&b, e, bid); put64(&b, e + 8, ib); put16(&b, e + 16, cb); put16(&b, e + 18, 1)
    }

    /// An XBLOCK / XXBLOCK: btype 0x01, cLevel, cEnt, lcbTotal, then the child BIDs.
    private static func xblock(_ b: inout [UInt8], at: Int, level: UInt8, children: [UInt64], total: UInt32) {
        b[at] = 0x01; b[at + 1] = level
        put16(&b, at + 2, UInt16(children.count))
        put32(&b, at + 4, total)
        for (i, c) in children.enumerated() { put64(&b, at + 8 + i * 8, c) }
    }

    private static let hugeIB: UInt64 = 0x8000_0000_0000_0000

    // MARK: A1 — spec reader

    /// NBT and BBT roots at 0x8000_0000_0000_0000: Int(ib) trapped before the `o >= 0` guard.
    func testSpecReaderRootBREFWithBit63DoesNotTrap() throws {
        let file = Data(Self.unicodeFile(size: 4096, nbt: Self.hugeIB, bbt: Self.hugeIB))
        let reader = try PSTSpecReader(data: file)
        XCTAssertTrue(reader.nodes.isEmpty)
        XCTAssertTrue(reader.blocks.isEmpty)
        XCTAssertTrue(reader.messages().isEmpty)
    }

    /// A branch page whose child BREF is 0x8000…, and a BBT leaf whose block ib is 0x8000…:
    /// reading that block and carving unallocated space trapped.
    func testSpecReaderChildBREFAndBlockIBWithBit63DoNotTrap() throws {
        var b = Self.unicodeFile(size: 8192, nbt: 1024, bbt: 1536)
        // NBT root: a branch page (cLevel 1) with one child at the hostile offset.
        Self.page(&b, at: 1024, cEnt: 1, cbEnt: 24, level: 1, ptype: 0x81)
        Self.put64(&b, 1024 + 16, Self.hugeIB)
        // BBT root: a leaf with two blocks at hostile offsets.
        Self.page(&b, at: 1536, cEnt: 2, cbEnt: 24, level: 0, ptype: 0x80)
        Self.bbtEntry(&b, page: 1536, index: 0, bid: 0x04, ib: Self.hugeIB, cb: 64)
        Self.bbtEntry(&b, page: 1536, index: 1, bid: 0x08, ib: UInt64.max - 8, cb: 64)
        let reader = try PSTSpecReader(data: Data(b))
        XCTAssertEqual(reader.blocks.count, 2)
        XCTAssertNil(reader.block(0x04))
        XCTAssertNil(reader.block(0x08))
        XCTAssertTrue(reader.dataBlocks(0x04).isEmpty)
        XCTAssertTrue(reader.carveUnallocated(listed: []).isEmpty)
    }

    // MARK: A4 — header shorter than the crypt byte

    /// A 512- or 513-byte "!BDN" Unicode file: the guard checked 512 bytes, then byte 513 was read.
    func testSpecReaderShortHeaderThrowsInsteadOfTrapping() {
        for size in [512, 513] {
            let file = Data(Self.unicodeFile(size: 514, nbt: 0, bbt: 0).prefix(size))
            XCTAssertThrowsError(try PSTSpecReader(data: file), "size \(size)") { error in
                guard case PSTError.invalidFormat = error else { return XCTFail("size \(size): \(error)") }
            }
        }
        // 514 bytes holds the crypt byte: no longer a header error.
        XCTAssertNoThrow(try PSTSpecReader(data: Data(Self.unicodeFile(size: 514, nbt: 0, bbt: 0))))
    }

    // MARK: A14 — data trees that list the same child again and again

    /// A file with one 64-byte data block (bid 0x04) at 2048 and a BBT leaf at 1536.
    private static func dataTreeFile(extra: (inout [UInt8]) -> [(bid: UInt64, ib: UInt64, cb: UInt16)]) -> Data {
        var b = unicodeFile(size: 1 << 17, nbt: 1024, bbt: 1536)
        page(&b, at: 1024, cEnt: 0, cbEnt: 32, level: 0, ptype: 0x81)
        for i in 0..<64 { b[2048 + i] = UInt8(i) }
        var entries: [(bid: UInt64, ib: UInt64, cb: UInt16)] = [(0x04, 2048, 64), (0x08, 2048, 64)]
        entries += extra(&b)
        page(&b, at: 1536, cEnt: entries.count, cbEnt: 24, level: 0, ptype: 0x80)
        for (i, e) in entries.enumerated() { bbtEntry(&b, page: 1536, index: i, bid: e.bid, ib: e.ib, cb: e.cb) }
        return Data(b)
    }

    /// An XBLOCK naming data block 0x04 1,000 times, lcbTotal 64: the reader returned 64,000 bytes.
    func testSpecReaderXBLOCKRepeatingOneChildIsNotMultiplied() throws {
        let n = 1000
        let file = Self.dataTreeFile { b in
            Self.xblock(&b, at: 4096, level: 1, children: Array(repeating: 0x04, count: n), total: 64)
            return [(0x06, 4096, UInt16(8 + 8 * n))]
        }
        let reader = try PSTSpecReader(data: file)
        let total = reader.dataBlocks(0x06).reduce(0) { $0 + $1.count }
        XCTAssertLessThanOrEqual(total, 64, "a repeated child BID must not be appended again")
    }

    /// An XXBLOCK naming the same XBLOCK 1,000 times: the reader appended it 1,000 times.
    func testSpecReaderXXBLOCKRepeatingOneXBLOCKIsNotMultiplied() throws {
        let n = 1000
        let file = Self.dataTreeFile { b in
            Self.xblock(&b, at: 4096, level: 1, children: [0x04], total: 64)
            Self.xblock(&b, at: 8192, level: 2, children: Array(repeating: 0x06, count: n), total: 64)
            return [(0x06, 4096, 16), (0x0A, 8192, UInt16(8 + 8 * n))]
        }
        let reader = try PSTSpecReader(data: file)
        let total = reader.dataBlocks(0x0A).reduce(0) { $0 + $1.count }
        XCTAssertLessThanOrEqual(total, 64)
    }

    /// Distinct children whose bytes exceed the XBLOCK's declared lcbTotal: the tree is corrupt.
    func testSpecReaderXBLOCKOverDeclaredTotalIsRejected() throws {
        let file = Self.dataTreeFile { b in
            Self.xblock(&b, at: 4096, level: 1, children: [0x04, 0x08], total: 64)
            return [(0x06, 4096, 24)]
        }
        let reader = try PSTSpecReader(data: file)
        let total = reader.dataBlocks(0x06).reduce(0) { $0 + $1.count }
        XCTAssertLessThanOrEqual(total, 64)
    }

    /// A well-formed XBLOCK (two distinct children, lcbTotal 128) still reads both.
    func testSpecReaderWellFormedXBLOCKStillReads() throws {
        let file = Self.dataTreeFile { b in
            Self.xblock(&b, at: 4096, level: 1, children: [0x04, 0x08], total: 128)
            return [(0x06, 4096, 24)]
        }
        let reader = try PSTSpecReader(data: file)
        XCTAssertEqual(reader.dataBlocks(0x06).map(\.count), [64, 64])
    }

    /// Review a177c8b..dd0c10d #5: mailin's earlier PSTWriter writes lcbTotal as
    /// UInt32(clamping:), so 0xFFFFFFFF means "4 GiB or more", not a 4 GiB cap
    /// (PSTParser already reads it so). Distinct children read in full under that
    /// sentinel, through an XBLOCK and an XXBLOCK; a repeated BID is still refused.
    func testSpecReaderLcbTotalSentinelReadsDistinctChildren_repeatsStillRefused() throws {
        let sentinel = UInt32.max
        // The sentinel sets no total cap (an item over 4 GiB cannot be built here,
        // so the budget is checked directly); any other value is the strict cap.
        XCTAssertEqual(PSTSpecReader.dataTreeBudget(declared: sentinel), Int.max, "0xFFFFFFFF is \"not stated\", not 4 GiB")
        XCTAssertEqual(PSTSpecReader.dataTreeBudget(declared: 0xFFFF_FFFE), 0xFFFF_FFFE)
        XCTAssertEqual(PSTSpecReader.dataTreeBudget(declared: 64), 64)
        let file = Self.dataTreeFile { b in
            Self.xblock(&b, at: 4096, level: 1, children: [0x04, 0x08], total: sentinel)
            Self.xblock(&b, at: 8192, level: 1, children: [0x04, 0x08, 0x04], total: sentinel)
            Self.xblock(&b, at: 12288, level: 2, children: [0x06], total: sentinel)
            return [(0x06, 4096, 24), (0x0E, 8192, 32), (0x0A, 12288, 16)]
        }
        let reader = try PSTSpecReader(data: file)
        XCTAssertEqual(reader.dataBlocks(0x06).map(\.count), [64, 64], "XBLOCK with lcbTotal 0xFFFFFFFF")
        XCTAssertEqual(reader.dataBlocks(0x0A).map(\.count), [64, 64], "XXBLOCK with lcbTotal 0xFFFFFFFF")
        XCTAssertTrue(reader.dataBlocks(0x0E).isEmpty, "a repeated child BID is still a corrupt tree under the sentinel")
    }

    /// A BTH whose index record lists itself three times, ten levels deep: the walk
    /// visited it 3^10 times (118,098 records from one 18-byte allocation).
    func testSpecReaderBTHSelfReferenceIsReadOnce() throws {
        var p = [UInt8](repeating: 0, count: 48)
        Self.put16(&p, 0, 38)                        // ibHnpm: page map at 38
        p[2] = 0xEC; p[3] = 0xBC
        Self.put32(&p, 4, 0x20)                      // hidUserRoot → allocation 1
        // Allocation 1 (12..<20): BTHHEADER, cbKey 2, cbEnt 6, 10 levels, root → allocation 2.
        p[12] = 0xB5; p[13] = 2; p[14] = 6; p[15] = 10
        Self.put32(&p, 16, 0x40)
        // Allocation 2 (20..<38): three index records, each pointing back at allocation 2.
        for i in 0..<3 { Self.put16(&p, 20 + i * 6, UInt16(i)); Self.put32(&p, 22 + i * 6, 0x40) }
        // Page map: cAlloc 2, cFree 0, rgibAlloc [12, 20, 38].
        Self.put16(&p, 38, 2); Self.put16(&p, 42, 12); Self.put16(&p, 44, 20); Self.put16(&p, 46, 38)
        let reader = try PSTSpecReader(data: Data(Self.unicodeFile(size: 514, nbt: 0, bbt: 0)))
        let heap = try XCTUnwrap(PSTSpecReader.Heap([p]))
        XCTAssertLessThanOrEqual(reader.bth(heap, 0x20).count, 3)
    }

    // MARK: A1 / A14 — the heuristic reader (PSTReader)

    /// Header roots at 0x8000…: Int(pstReadUInt64) trapped in readNodeBTree / readBlockBTree.
    func testHeuristicReaderRootWithBit63DoesNotTrap() throws {
        let file = Data(Self.unicodeFile(size: 4096, nbt: Self.hugeIB, bbt: Self.hugeIB))
        let reader = try PSTReader(data: file)
        XCTAssertTrue(try reader.readAllMessages().isEmpty)
    }

    /// Branch pages with 0x8000… children, and a message whose block lies at 0x8000…
    /// (also scanned by deep recovery): every conversion trapped.
    func testHeuristicReaderChildAndBlockOffsetsWithBit63DoNotTrap() throws {
        var b = Self.unicodeFile(size: 8192, nbt: 1024, bbt: 1536)
        Self.page(&b, at: 1024, cEnt: 2, cbEnt: 32, level: 0, ptype: 0x81)
        Self.put32(&b, 1024, 0x2C); Self.put64(&b, 1024 + 8, 0x04)            // message node → bid 0x04
        Self.put32(&b, 1024 + 32, 0x4C); Self.put64(&b, 1024 + 40, 0x08)       // message node → bid 0x08
        Self.page(&b, at: 1536, cEnt: 2, cbEnt: 24, level: 1, ptype: 0x80)    // BBT branch
        Self.put64(&b, 1536 + 16, Self.hugeIB)
        Self.put64(&b, 1536 + 24 + 16, 2048)
        Self.page(&b, at: 2048, cEnt: 2, cbEnt: 24, level: 0, ptype: 0x80)    // BBT leaf
        Self.bbtEntry(&b, page: 2048, index: 0, bid: 0x04, ib: Self.hugeIB, cb: 64)
        Self.bbtEntry(&b, page: 2048, index: 1, bid: 0x08, ib: UInt64.max - 8, cb: 64)
        let savedRecovery = RecoveryPolicy.isEnabled, savedDeep = RecoveryPolicy.deepRecoveryEnabled
        RecoveryPolicy.isEnabled = true; RecoveryPolicy.deepRecoveryEnabled = true
        defer { RecoveryPolicy.isEnabled = savedRecovery; RecoveryPolicy.deepRecoveryEnabled = savedDeep }
        let reader = try PSTReader(data: Data(b))
        let messages = try reader.readAllMessages()
        XCTAssertTrue(messages.allSatisfy { $0.bodyText.isEmpty && $0.subject.isEmpty })
    }

    /// A node-tree branch naming the same leaf page twice (and itself): the heuristic reader
    /// read the leaf once per mention, so one message came out twice.
    func testHeuristicReaderBranchRepeatingAPageReadsItOnce() throws {
        var b = Self.unicodeFile(size: 8192, nbt: 1024, bbt: 2560)
        Self.page(&b, at: 1024, cEnt: 3, cbEnt: 24, level: 1, ptype: 0x81)   // NBT branch
        Self.put64(&b, 1024 + 16, 1536)
        Self.put64(&b, 1024 + 24 + 16, 1536)
        Self.put64(&b, 1024 + 48 + 16, 1024)                                  // and itself
        Self.page(&b, at: 1536, cEnt: 1, cbEnt: 32, level: 0, ptype: 0x81)   // NBT leaf
        Self.put32(&b, 1536, 0x2C); Self.put64(&b, 1536 + 8, 0x04)
        let pc = 4096
        b[pc + 3] = 0x7C
        Self.page(&b, at: 2560, cEnt: 1, cbEnt: 24, level: 0, ptype: 0x80)
        Self.bbtEntry(&b, page: 2560, index: 0, bid: 0x04, ib: UInt64(pc), cb: 64)
        let reader = try PSTReader(data: Data(b))
        XCTAssertEqual(try reader.readAllMessages().count, 1)
    }

    /// An XBLOCK naming the same property-context block 1,000 times: the heuristic reader
    /// concatenated 1,000 copies, so the HTML body (a binary running to the end of the
    /// node's data) grew 1,000-fold.
    func testHeuristicReaderXBLOCKRepeatingOneChildIsNotMultiplied() throws {
        let n = 1000
        var b = Self.unicodeFile(size: 1 << 17, nbt: 1024, bbt: 1536)
        Self.page(&b, at: 1024, cEnt: 1, cbEnt: 32, level: 0, ptype: 0x81)
        Self.put32(&b, 1024, 0x2C); Self.put64(&b, 1024 + 8, 0x06)            // message node → XBLOCK 0x06
        // Data block 0x04: a minimal property context (all bytes 7-bit, so valid UTF-8):
        // PidTagHtml (0x1013, PT_BINARY) at offset 16, then 48 bytes of 'A'.
        let pc = 2048
        b[pc + 3] = 0x7C
        Self.put16(&b, pc + 8, 0x1013); Self.put16(&b, pc + 10, 0x0102); Self.put32(&b, pc + 12, 16)
        for i in 16..<64 { b[pc + i] = 0x41 }
        Self.xblock(&b, at: 4096, level: 1, children: Array(repeating: 0x04, count: n), total: 64)
        Self.page(&b, at: 1536, cEnt: 2, cbEnt: 24, level: 0, ptype: 0x80)
        Self.bbtEntry(&b, page: 1536, index: 0, bid: 0x04, ib: UInt64(pc), cb: 64)
        Self.bbtEntry(&b, page: 1536, index: 1, bid: 0x06, ib: 4096, cb: UInt16(8 + 8 * n))
        let reader = try PSTReader(data: Data(b))
        let messages = try reader.readAllMessages()
        XCTAssertEqual(messages.count, 1)
        XCTAssertLessThanOrEqual(messages.first?.bodyHTML.utf8.count ?? 0, 48)
    }
}
