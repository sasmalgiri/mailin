//
//  PSTSpecReader.swift
//  ArchiveCore
//
//  An Outlook PST/OST reader written from Microsoft's published [MS-PST]
//  specification (free to implement), replacing the heuristic reader for
//  real Outlook files. It reads the NDB layer (header, node and block
//  B-trees, data trees, subnode trees, NDB_CRYPT_PERMUTE / CYCLIC decoding)
//  and the LTP layer (heap-on-node, BTH, property contexts and table
//  contexts), for both ANSI (Outlook 97–2002) and Unicode files.
//
//  Messages are NID type 0x04 (NID_TYPE_NORMAL_MESSAGE); each names its
//  folder in the NBT entry's nidParent. Recipients come from the recipient
//  table (NID 0x692), attachments from the attachment table (NID 0x671).
//
//  Found 2026-10-13 against Digital Corpora's public Outlook PSTs, checked
//  with libpst's readpst: the heuristic reader took NID type 0x0C (an
//  outgoing-queue table) for messages and decoded "compressible encryption"
//  with a corrupted copy of the encode table, so it read one item or none
//  from real files.
//

import Foundation

enum PSTSpec {
    /// [MS-PST] 5.1 mpbbCrypt: mpbbR (encode), mpbbS, mpbbI (decode = inverse of R).
    static let crypt: [UInt8] = [
        65, 54, 19, 98, 168, 33, 110, 187, 244, 22, 204, 4, 127, 100, 232, 93,
        30, 242, 203, 42, 116, 197, 94, 53, 210, 149, 71, 158, 150, 45, 154, 136,
        76, 125, 132, 63, 219, 172, 49, 182, 72, 95, 246, 196, 216, 57, 139, 231,
        35, 59, 56, 142, 200, 193, 223, 37, 177, 32, 165, 70, 96, 78, 156, 251,
        170, 211, 86, 81, 69, 124, 85, 0, 7, 201, 43, 157, 133, 155, 9, 160,
        143, 173, 179, 15, 99, 171, 137, 75, 215, 167, 21, 90, 113, 102, 66, 191,
        38, 74, 107, 152, 250, 234, 119, 83, 178, 112, 5, 44, 253, 89, 58, 134,
        126, 206, 6, 235, 130, 120, 87, 199, 141, 67, 175, 180, 28, 212, 91, 205,
        226, 233, 39, 79, 195, 8, 114, 128, 207, 176, 239, 245, 40, 109, 190, 48,
        77, 52, 146, 213, 14, 60, 34, 50, 229, 228, 249, 159, 194, 209, 10, 129,
        18, 225, 238, 145, 131, 118, 227, 151, 230, 97, 138, 23, 121, 164, 183, 220,
        144, 122, 92, 140, 2, 166, 202, 105, 222, 80, 26, 17, 147, 185, 82, 135,
        88, 252, 237, 29, 55, 73, 27, 106, 224, 41, 51, 153, 189, 108, 217, 148,
        243, 64, 84, 111, 240, 198, 115, 184, 214, 62, 101, 24, 68, 31, 221, 103,
        16, 241, 12, 25, 236, 174, 3, 161, 20, 123, 169, 11, 255, 248, 163, 192,
        162, 1, 247, 46, 188, 36, 104, 117, 13, 254, 186, 47, 181, 208, 218, 61,
        20, 83, 15, 86, 179, 200, 122, 156, 235, 101, 72, 23, 22, 21, 159, 2,
        204, 84, 124, 131, 0, 13, 12, 11, 162, 98, 168, 118, 219, 217, 237, 199,
        197, 164, 220, 172, 133, 116, 214, 208, 167, 155, 174, 154, 150, 113, 102, 195,
        99, 153, 184, 221, 115, 146, 142, 132, 125, 165, 94, 209, 93, 147, 177, 87,
        81, 80, 128, 137, 82, 148, 79, 78, 10, 107, 188, 141, 127, 110, 71, 70,
        65, 64, 68, 1, 17, 203, 3, 63, 247, 244, 225, 169, 143, 60, 58, 249,
        251, 240, 25, 48, 130, 9, 46, 201, 157, 160, 134, 73, 238, 111, 77, 109,
        196, 45, 129, 52, 37, 135, 27, 136, 170, 252, 6, 161, 18, 56, 253, 76,
        66, 114, 100, 19, 55, 36, 106, 117, 119, 67, 255, 230, 180, 75, 54, 92,
        228, 216, 53, 61, 69, 185, 44, 236, 183, 49, 43, 41, 7, 104, 163, 14,
        105, 123, 24, 158, 33, 57, 190, 40, 26, 91, 120, 245, 35, 202, 42, 176,
        175, 62, 254, 4, 140, 231, 229, 152, 50, 149, 211, 246, 74, 232, 166, 234,
        233, 243, 213, 47, 112, 32, 242, 31, 5, 103, 173, 85, 16, 206, 205, 227,
        39, 59, 218, 186, 215, 194, 38, 212, 145, 29, 210, 28, 34, 51, 248, 250,
        241, 90, 239, 207, 144, 182, 139, 181, 189, 192, 191, 8, 151, 30, 108, 226,
        97, 224, 198, 193, 89, 171, 187, 88, 222, 95, 223, 96, 121, 126, 178, 138,
        71, 241, 180, 230, 11, 106, 114, 72, 133, 78, 158, 235, 226, 248, 148, 83,
        224, 187, 160, 2, 232, 90, 9, 171, 219, 227, 186, 198, 124, 195, 16, 221,
        57, 5, 150, 48, 245, 55, 96, 130, 140, 201, 19, 74, 107, 29, 243, 251,
        143, 38, 151, 202, 145, 23, 1, 196, 50, 45, 110, 49, 149, 255, 217, 35,
        209, 0, 94, 121, 220, 68, 59, 26, 40, 197, 97, 87, 32, 144, 61, 131,
        185, 67, 190, 103, 210, 70, 66, 118, 192, 109, 91, 126, 178, 15, 22, 41,
        60, 169, 3, 84, 13, 218, 93, 223, 246, 183, 199, 98, 205, 141, 6, 211,
        105, 92, 134, 214, 20, 247, 165, 102, 117, 172, 177, 233, 69, 33, 112, 12,
        135, 159, 116, 164, 34, 76, 111, 191, 31, 86, 170, 46, 179, 120, 51, 80,
        176, 163, 146, 188, 207, 25, 28, 167, 99, 203, 30, 77, 62, 75, 27, 155,
        79, 231, 240, 238, 173, 58, 181, 89, 4, 234, 64, 85, 37, 81, 229, 122,
        137, 56, 104, 82, 123, 252, 39, 174, 215, 189, 250, 7, 244, 204, 142, 95,
        239, 53, 156, 132, 43, 21, 213, 119, 52, 73, 182, 18, 10, 127, 113, 136,
        253, 157, 24, 65, 125, 147, 216, 88, 44, 206, 254, 36, 175, 222, 184, 54,
        200, 161, 128, 166, 153, 152, 168, 47, 14, 129, 101, 115, 228, 194, 162, 138,
        212, 225, 17, 208, 8, 139, 42, 242, 237, 154, 100, 63, 193, 108, 249, 236,
    ]

    static func decodePermute(_ d: inout [UInt8]) {
        for i in d.indices { d[i] = crypt[512 + Int(d[i])] }
    }

    /// [MS-PST] 5.2 CryptCyclic (symmetric); key = low DWORD of the block's BID.
    static func cyclic(_ d: inout [UInt8], key: UInt32) {
        var w = UInt16(truncatingIfNeeded: key ^ (key >> 16))
        for i in d.indices {
            var b = d[i]
            b = b &+ UInt8(truncatingIfNeeded: w)
            b = crypt[Int(b)]
            b = b &+ UInt8(truncatingIfNeeded: w >> 8)
            b = crypt[256 + Int(b)]
            b = b &- UInt8(truncatingIfNeeded: w >> 8)
            b = crypt[512 + Int(b)]
            b = b &- UInt8(truncatingIfNeeded: w)
            d[i] = b
            w = w &+ 1
        }
    }
}

/// One property value from a property context or table row.
enum PSTValue {
    case int(Int64)
    case bool(Bool)
    case string(String)
    case binary([UInt8])
    case time(Date)

    var string: String? { if case .string(let s) = self { return s }; return nil }
    var int: Int64? { if case .int(let n) = self { return n }; if case .bool(let b) = self { return b ? 1 : 0 }; return nil }
    var bytes: [UInt8]? { if case .binary(let b) = self { return b }; return nil }
    var date: Date? { if case .time(let d) = self { return d }; return nil }
}

final class PSTSpecReader {
    struct Node { let nid: UInt32; let dataBid: UInt64; let subBid: UInt64; let parent: UInt32 }
    struct Block { let ib: UInt64; let cb: Int }

    let bytes: Data
    let unicode: Bool
    let crypt: UInt8
    private(set) var nodes: [UInt32: Node] = [:]
    private(set) var blocks: [UInt64: Block] = [:]
    private var visitedPages = 0

    init(data: Data) throws {
        bytes = data
        guard data.count >= 512, data[0] == 0x21, data[1] == 0x42, data[2] == 0x44, data[3] == 0x4E else {
            throw PSTError.invalidFormat("not a PST/OST file")
        }
        let ver = Self.u16(data, 10)
        unicode = ver >= 23
        crypt = data[unicode ? 513 : 461]
        guard crypt <= 2 else { throw PSTError.invalidFormat("unknown encoding \(crypt)") }
        let nbtIB = unicode ? Self.u64(data, 224) : UInt64(Self.u32(data, 188))
        let bbtIB = unicode ? Self.u64(data, 240) : UInt64(Self.u32(data, 196))
        try walk(page: nbtIB, nbt: true, depth: 0)
        try walk(page: bbtIB, nbt: false, depth: 0)
    }

    // MARK: Little-endian reads (bounds-checked; out of range reads 0)

    static func u16(_ d: Data, _ o: Int) -> UInt16 {
        guard o >= 0, o + 2 <= d.count else { return 0 }
        let b = d.startIndex + o
        return UInt16(d[b]) | UInt16(d[b + 1]) << 8
    }
    static func u32(_ d: Data, _ o: Int) -> UInt32 {
        guard o >= 0, o + 4 <= d.count else { return 0 }
        let b = d.startIndex + o
        return UInt32(d[b]) | UInt32(d[b + 1]) << 8 | UInt32(d[b + 2]) << 16 | UInt32(d[b + 3]) << 24
    }
    static func u64(_ d: Data, _ o: Int) -> UInt64 { UInt64(u32(d, o)) | UInt64(u32(d, o + 4)) << 32 }
    static func u16(_ a: [UInt8], _ o: Int) -> UInt16 { o >= 0 && o + 2 <= a.count ? UInt16(a[o]) | UInt16(a[o + 1]) << 8 : 0 }
    static func u32(_ a: [UInt8], _ o: Int) -> UInt32 {
        o >= 0 && o + 4 <= a.count ? UInt32(a[o]) | UInt32(a[o + 1]) << 8 | UInt32(a[o + 2]) << 16 | UInt32(a[o + 3]) << 24 : 0
    }
    static func u64(_ a: [UInt8], _ o: Int) -> UInt64 { UInt64(u32(a, o)) | UInt64(u32(a, o + 4)) << 32 }

    // MARK: NDB — B-trees

    /// [MS-PST] 2.2.2.7: 512-byte pages; leaves hold NBT or BBT entries.
    private func walk(page ib: UInt64, nbt: Bool, depth: Int) throws {
        guard depth < 32 else { throw PSTError.depthLimitExceeded }
        visitedPages += 1
        guard visitedPages < 5_000_000 else { throw PSTError.depthLimitExceeded }
        let o = Int(ib)
        guard o >= 0, o + 512 <= bytes.count else { return }
        let entriesEnd = unicode ? 488 : 496
        let cEnt = Int(bytes[bytes.startIndex + o + entriesEnd])
        let cbEnt = Int(bytes[bytes.startIndex + o + entriesEnd + 2])
        let cLevel = Int(bytes[bytes.startIndex + o + entriesEnd + 3])
        guard cbEnt > 0, cEnt * cbEnt <= entriesEnd else { return }
        for i in 0..<cEnt {
            let e = o + i * cbEnt
            if cLevel > 0 {
                let child = unicode ? Self.u64(bytes, e + 16) : UInt64(Self.u32(bytes, e + 8))
                try walk(page: child, nbt: nbt, depth: depth + 1)
            } else if nbt {
                let nid = Self.u32(bytes, e)
                if unicode {
                    nodes[nid] = Node(nid: nid, dataBid: Self.u64(bytes, e + 8), subBid: Self.u64(bytes, e + 16), parent: Self.u32(bytes, e + 24))
                } else {
                    nodes[nid] = Node(nid: nid, dataBid: UInt64(Self.u32(bytes, e + 4)), subBid: UInt64(Self.u32(bytes, e + 8)), parent: Self.u32(bytes, e + 12))
                }
            } else {
                let bid = unicode ? Self.u64(bytes, e) : UInt64(Self.u32(bytes, e))
                let bib = unicode ? Self.u64(bytes, e + 8) : UInt64(Self.u32(bytes, e + 4))
                let cb = Int(Self.u16(bytes, e + (unicode ? 16 : 8)))
                blocks[bid & ~1] = Block(ib: bib, cb: cb)
            }
        }
    }

    // MARK: NDB — blocks, data trees, subnodes

    /// One block's bytes; external (data) blocks are decoded.
    func block(_ bid: UInt64) -> [UInt8]? {
        guard let b = blocks[bid & ~1] else { return nil }
        let o = Int(b.ib)
        guard o >= 0, b.cb >= 0, o + b.cb <= bytes.count else { return nil }
        var d = [UInt8](bytes[(bytes.startIndex + o)..<(bytes.startIndex + o + b.cb)])
        if bid & 2 == 0 {   // external block
            if crypt == 1 { PSTSpec.decodePermute(&d) }
            // [MS-PST] 2.2.2.2: bit 0 of a BID is reserved and read as zero, also
            // for the cyclic key; some files set it in subnode references.
            else if crypt == 2 { PSTSpec.cyclic(&d, key: UInt32(truncatingIfNeeded: bid & ~1)) }
        }
        return d
    }

    /// A node's data as its list of data blocks (XBLOCK / XXBLOCK expanded).
    func dataBlocks(_ bid: UInt64, depth: Int = 0) -> [[UInt8]] {
        guard depth < 4, bid != 0, let d = block(bid) else { return [] }
        guard bid & 2 != 0 else { return [d] }
        // XBLOCK (cLevel 1) or XXBLOCK (cLevel 2): btype 0x01.
        guard d.count >= 8, d[0] == 0x01 else { return [] }
        let count = Int(Self.u16(d, 2))
        let w = unicode ? 8 : 4
        var out: [[UInt8]] = []
        for i in 0..<count {
            let child = unicode ? Self.u64(d, 8 + i * w) : UInt64(Self.u32(d, 8 + i * w))
            out += dataBlocks(child, depth: depth + 1)
        }
        return out
    }

    /// Subnode tree (SLBLOCK / SIBLOCK): nid → (data, sub) bids.
    func subnodes(_ bid: UInt64, depth: Int = 0) -> [UInt32: (UInt64, UInt64)] {
        guard depth < 4, bid != 0, let d = block(bid), d.count >= 8, d[0] == 0x02 else { return [:] }
        let level = d[1]
        let count = Int(Self.u16(d, 2))
        var out: [UInt32: (UInt64, UInt64)] = [:]
        let head = unicode ? 8 : 4
        if level == 0 {
            let size = unicode ? 24 : 12
            for i in 0..<count {
                let e = head + i * size
                let nid = Self.u32(d, e)
                let data = unicode ? Self.u64(d, e + 8) : UInt64(Self.u32(d, e + 4))
                let sub = unicode ? Self.u64(d, e + 16) : UInt64(Self.u32(d, e + 8))
                out[nid] = (data, sub)
            }
        } else {
            let size = unicode ? 16 : 8
            for i in 0..<count {
                let child = unicode ? Self.u64(d, head + i * size + 8) : UInt64(Self.u32(d, head + i * size + 4))
                out.merge(subnodes(child, depth: depth + 1)) { a, _ in a }
            }
        }
        return out
    }

    // MARK: LTP — heap-on-node

    struct Heap {
        let pages: [[UInt8]]
        let clientSig: UInt8
        let userRoot: UInt32

        init?(_ pages: [[UInt8]]) {
            guard let first = pages.first, first.count >= 12, first[2] == 0xEC else { return nil }
            self.pages = pages
            clientSig = first[3]
            userRoot = PSTSpecReader.u32(first, 4)
        }

        /// Bytes of one heap allocation (HID: index bits 5–15, block bits 16–31).
        func alloc(_ hid: UInt32) -> [UInt8]? {
            guard hid & 0x1F == 0 else { return nil }
            let index = Int((hid >> 5) & 0x7FF)
            let page = Int(hid >> 16)
            guard index > 0, page < pages.count else { return nil }
            let p = pages[page]
            let map = Int(PSTSpecReader.u16(p, 0))
            guard map + 4 <= p.count else { return nil }
            let cAlloc = Int(PSTSpecReader.u16(p, map))
            guard index <= cAlloc else { return nil }
            let start = Int(PSTSpecReader.u16(p, map + 4 + (index - 1) * 2))
            let end = Int(PSTSpecReader.u16(p, map + 4 + index * 2))
            guard start <= end, end <= p.count else { return nil }
            return Array(p[start..<end])
        }
    }

    /// BTH records [(key, data)] under `hid` (the BTHHEADER).
    func bth(_ heap: Heap, _ hid: UInt32) -> [([UInt8], [UInt8])] {
        guard let h = heap.alloc(hid), h.count >= 8, h[0] == 0xB5 else { return [] }
        let cbKey = Int(h[1]), cbEnt = Int(h[2]), levels = Int(h[3])
        var out: [([UInt8], [UInt8])] = []
        func visit(_ hid: UInt32, _ level: Int) {
            guard hid != 0, let r = heap.alloc(hid) else { return }
            let size = level > 0 ? cbKey + 4 : cbKey + cbEnt
            guard size > 0 else { return }
            var o = 0
            while o + size <= r.count {
                if level > 0 { visit(Self.u32(r, o + cbKey), level - 1) }
                else { out.append((Array(r[o..<(o + cbKey)]), Array(r[(o + cbKey)..<(o + size)]))) }
                o += size
            }
        }
        visit(Self.u32(h, 4), levels)
        return out
    }

    // MARK: LTP — property context

    /// Property context of a node (or subnode): id → value.
    func propertyContext(dataBid: UInt64, subBid: UInt64) -> [UInt16: PSTValue] {
        guard let heap = Heap(dataBlocks(dataBid)), heap.clientSig == 0xBC else { return [:] }
        let subs = subnodes(subBid)
        var out: [UInt16: PSTValue] = [:]
        for (k, v) in bth(heap, heap.userRoot) where k.count == 2 && v.count == 6 {
            let id = Self.u16(k, 0)
            let type = Self.u16(v, 0)
            let raw = Self.u32(v, 2)
            if let value = value(type: type, inline: raw, heap: heap, subnodes: subs) { out[id] = value }
        }
        return out
    }

    /// A value from its 4-byte cell: inline for small fixed types, else an HNID.
    func value(type: UInt16, inline raw: UInt32, heap: Heap, subnodes subs: [UInt32: (UInt64, UInt64)], cell: [UInt8]? = nil) -> PSTValue? {
        func referenced() -> [UInt8]? {
            if raw == 0 { return [] }
            if raw & 0x1F == 0 { return heap.alloc(raw) }
            guard let s = subs[raw] else { return nil }
            return dataBlocks(s.0).flatMap { $0 }
        }
        switch type {
        case 0x0002: return .int(Int64(Int16(truncatingIfNeeded: raw)))
        case 0x0003: return .int(Int64(Int32(bitPattern: raw)))
        case 0x000B: return .bool(raw & 0xFF != 0)
        case 0x0014:
            if let c = cell, c.count >= 8 { return .int(Int64(bitPattern: Self.u64(c, 0))) }
            guard let d = referenced(), d.count >= 8 else { return nil }
            return .int(Int64(bitPattern: Self.u64(d, 0)))
        case 0x0040:
            let ft: UInt64
            if let c = cell, c.count >= 8 { ft = Self.u64(c, 0) } else {
                guard let d = referenced(), d.count >= 8 else { return nil }
                ft = Self.u64(d, 0)
            }
            guard ft > 0 else { return nil }
            return .time(Date(timeIntervalSince1970: Double(ft) / 10_000_000 - 11_644_473_600))
        case 0x001F:
            guard let d = referenced() else { return nil }
            var s = String(decoding: stride(from: 0, to: d.count - 1, by: 2).map { UInt16(d[$0]) | UInt16(d[$0 + 1]) << 8 }, as: UTF16.self)
            if let z = s.firstIndex(of: "\0") { s = String(s[..<z]) }
            return .string(s)
        case 0x001E:
            guard let d = referenced() else { return nil }
            let trimmed = d.prefix { $0 != 0 }
            return .string(String(bytes: trimmed, encoding: .windowsCP1252) ?? String(decoding: trimmed, as: UTF8.self))
        case 0x0102:
            guard let d = referenced() else { return nil }
            return .binary(d)
        case 0x000D:
            // PtypObject ([MS-PST] 2.3.3.5): 8 bytes, the subnode's NID and the object's size.
            guard let d = referenced(), d.count >= 8 else { return nil }
            return .binary(d)
        default:
            return nil
        }
    }

    // MARK: LTP — table context

    /// Rows of a table context: each row's id plus the requested columns.
    func table(dataBid: UInt64, subBid: UInt64) -> [(rowID: UInt32, values: [UInt32: PSTValue])] {
        guard let heap = Heap(dataBlocks(dataBid)), heap.clientSig == 0x7C,
              let info = heap.alloc(heap.userRoot), info.count >= 22, info[0] == 0x7C else { return [] }
        let subs = subnodes(subBid)
        let cols = Int(info[1])
        let rowSize = Int(Self.u16(info, 8))         // rgib[TCI_bm]: end of the cell-existence bitmap
        let ceb = Int(Self.u16(info, 6))             // rgib[TCI_1b]: start of the bitmap
        let hnidRows = Self.u32(info, 14)
        guard rowSize > 0, info.count >= 22 + cols * 8 else { return [] }
        struct Col { let tag: UInt32; let ib: Int; let cb: Int; let bit: Int }
        let colDescs = (0..<cols).map { i -> Col in
            let o = 22 + i * 8
            return Col(tag: Self.u32(info, o), ib: Int(Self.u16(info, o + 4)), cb: Int(info[o + 6]), bit: Int(info[o + 7]))
        }
        // The row matrix: one heap allocation, or a subnode whose blocks each hold whole rows.
        var rowBlocks: [[UInt8]] = []
        if hnidRows == 0 { return [] }
        if hnidRows & 0x1F == 0 { if let r = heap.alloc(hnidRows) { rowBlocks = [r] } }
        else if let s = subs[hnidRows] { rowBlocks = dataBlocks(s.0) }
        var out: [(UInt32, [UInt32: PSTValue])] = []
        for blk in rowBlocks {
            var o = 0
            while o + rowSize <= blk.count {
                let row = Array(blk[o..<(o + rowSize)])
                var values: [UInt32: PSTValue] = [:]
                for c in colDescs {
                    let byte = ceb + c.bit / 8
                    guard byte < row.count, row[byte] & (0x80 >> UInt8(c.bit % 8)) != 0, c.ib + c.cb <= row.count else { continue }
                    let cell = Array(row[c.ib..<(c.ib + c.cb)])
                    let raw = c.cb >= 4 ? Self.u32(cell, 0) : (c.cb == 2 ? UInt32(Self.u16(cell, 0)) : UInt32(cell.first ?? 0))
                    if let v = value(type: UInt16(c.tag & 0xFFFF), inline: raw, heap: heap, subnodes: subs, cell: c.cb == 8 ? cell : nil) {
                        values[c.tag] = v
                    }
                }
                out.append((Self.u32(row, 0), values))
                o += rowSize
            }
        }
        return out
    }

    // MARK: Messaging layer

    static let nidTypeFolder: UInt32 = 0x02, nidTypeMessage: UInt32 = 0x04
    static let nidRecipientTable: UInt32 = 0x692, nidAttachmentTable: UInt32 = 0x671

    func folderPath(_ nid: UInt32) -> String? {
        var parts: [String] = []
        var current = nid
        var seen = Set<UInt32>()
        while let n = nodes[current], current & 0x1F == Self.nidTypeFolder, seen.insert(current).inserted {
            let name = propertyContext(dataBid: n.dataBid, subBid: n.subBid)[0x3001]?.string ?? ""
            if n.parent == current || n.parent == 0 { break }   // the root folder points at itself
            if !name.isEmpty { parts.append(name) }
            current = n.parent
        }
        return nodes[nid] != nil && nid & 0x1F == Self.nidTypeFolder ? parts.reversed().joined(separator: "/") : nil
    }

    /// An embedded message rebuilt as RFC 822 text from its own properties (the
    /// original transport headers are not reused: their MIME boundaries would not
    /// match the rebuilt body). Marked as reconstructed.
    func embeddedMessage(data: UInt64, sub: UInt64) -> (message: [UInt8], subject: String)? {
        let pc = propertyContext(dataBid: data, subBid: sub)
        guard !pc.isEmpty else { return nil }
        let subject = Self.subject(pc[0x0037]?.string ?? "")
        var lines: [String] = []
        let fromAddr = pc[0x0C1F]?.string ?? pc[0x0065]?.string ?? ""
        let fromName = pc[0x0C1A]?.string ?? pc[0x0042]?.string ?? ""
        if !fromAddr.isEmpty || !fromName.isEmpty {
            lines.append("From: " + (fromName.isEmpty || fromName == fromAddr ? fromAddr : "\"\(fromName)\" <\(fromAddr)>"))
        }
        if let to = pc[0x0E04]?.string, !to.isEmpty { lines.append("To: \(to)") }
        if let cc = pc[0x0E03]?.string, !cc.isEmpty { lines.append("Cc: \(cc)") }
        lines.append("Subject: \(subject)")
        if let d = pc[0x0E06]?.date ?? pc[0x0039]?.date {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
            lines.append("Date: \(f.string(from: d))")
        }
        if let id = pc[0x1035]?.string { lines.append("Message-ID: \(id)") }
        lines.append("MIME-Version: 1.0")
        lines.append("X-Mailin-Reconstructed: rebuilt from an Outlook embedded message")
        var body = pc[0x1000]?.string ?? ""
        if body.isEmpty, let html = pc[0x1013] {
            lines.append("Content-Type: text/html; charset=utf-8")
            body = html.string ?? html.bytes.map { String(decoding: $0, as: UTF8.self) } ?? ""
        } else {
            lines.append("Content-Type: text/plain; charset=utf-8")
        }
        return (Array((lines.joined(separator: "\r\n") + "\r\n\r\n" + body).utf8), subject)
    }

    func messages() -> [PSTReader.PSTMessage] {
        var folderCache: [UInt32: String?] = [:]
        var out: [PSTReader.PSTMessage] = []
        for node in nodes.values.sorted(by: { $0.nid < $1.nid }) where node.nid & 0x1F == Self.nidTypeMessage {
            autoreleasepool {
                let pc = propertyContext(dataBid: node.dataBid, subBid: node.subBid)
                let messageClass = pc[0x001A]?.string ?? "IPM.Note"
                // Mail only: contacts, calendar, tasks, notes, journal, feeds and
                // configuration items are not emails (stated in the limits doc).
                guard Self.isMail(messageClass) else { return }
                var m = PSTReader.PSTMessage()
                // An item whose properties cannot be read is still imported — empty,
                // marked — never dropped without a word.
                m.unreadable = pc.isEmpty
                m.subject = Self.subject(pc[0x0037]?.string ?? "")
                m.senderName = pc[0x0C1A]?.string ?? pc[0x0042]?.string ?? ""
                m.senderEmail = pc[0x5D01]?.string ?? pc[0x0C1F]?.string ?? pc[0x0065]?.string ?? ""
                m.displayTo = pc[0x0E04]?.string ?? ""
                m.displayCc = pc[0x0E03]?.string ?? ""
                m.displayBcc = pc[0x0E02]?.string ?? ""
                m.bodyText = pc[0x1000]?.string ?? ""
                if let html = pc[0x1013] {
                    m.bodyHTML = html.string ?? html.bytes.map { String(decoding: $0, as: UTF8.self) } ?? ""
                }
                m.internetMessageId = pc[0x1035]?.string
                m.inReplyToId = pc[0x1042]?.string
                m.references = pc[0x1039]?.string
                m.conversationTopic = pc[0x0070]?.string
                m.importance = pc[0x0017]?.int.map { UInt32(truncatingIfNeeded: $0) }
                m.sensitivity = pc[0x0036]?.int.map { UInt32(truncatingIfNeeded: $0) }
                m.transportHeaders = pc[0x007D]?.string ?? ""
                m.deliveryTime = pc[0x0E06]?.date ?? pc[0x0039]?.date
                m.creationTime = pc[0x3007]?.date
                m.lastModificationTime = pc[0x3008]?.date
                m.messageSize = Int(pc[0x0E08]?.int ?? 0)
                m.contentType = messageClass.hasPrefix("IPM.Note") ? nil : messageClass
                let subs = subnodes(node.subBid)
                // Outlook stores DisplayTo but computes DisplayCc/DisplayBcc ([MS-PST] 2.5.2.3,
                // SPGET_DISPLAY): fill each missing line from the recipient table, not only To.
                if m.displayTo.isEmpty || m.displayCc.isEmpty || m.displayBcc.isEmpty || m.senderEmail.isEmpty,
                   let rt = subs[Self.nidRecipientTable] {
                    let rows = table(dataBid: rt.0, subBid: rt.1)
                    func list(_ kind: Int64) -> String {
                        rows.filter { ($0.values[0x0C150003]?.int ?? 1) == kind }.map { r in
                            let name = r.values[0x3001001F]?.string ?? r.values[0x3001001E]?.string ?? ""
                            let addr = r.values[0x39FE001F]?.string ?? r.values[0x3003001F]?.string ?? r.values[0x3003001E]?.string ?? ""
                            return addr.isEmpty ? name : (name.isEmpty || name == addr ? addr : "\(name) <\(addr)>")
                        }.joined(separator: ", ")
                    }
                    if m.displayTo.isEmpty { m.displayTo = list(1) }
                    if m.displayCc.isEmpty { m.displayCc = list(2) }
                    if m.displayBcc.isEmpty { m.displayBcc = list(3) }
                }
                // Attachments: the attachment table's rows, plus any attachment object
                // (NID type 0x05) the table does not list — some damaged files lost the
                // table but kept the objects (Digital Corpora "Jean" PST; readpst finds them too).
                let listed = subs[Self.nidAttachmentTable].map { table(dataBid: $0.0, subBid: $0.1).map(\.rowID) } ?? []
                let unlisted = subs.keys.filter { $0 & 0x1F == 0x05 && !listed.contains($0) }.sorted()
                let attachmentNids = listed + unlisted
                if !attachmentNids.isEmpty {
                    for rowID in attachmentNids {
                        guard let a = subs[rowID] else { continue }
                        let apc = propertyContext(dataBid: a.0, subBid: a.1)
                        var name = apc[0x3707]?.string ?? apc[0x3704]?.string ?? apc[0x3001]?.string ?? "attachment"
                        var bytes = apc[0x3701]?.bytes
                        var mime = apc[0x370E]?.string ?? "application/octet-stream"
                        // An attached email (method 5, ATTACH_EMBEDDED_MSG) becomes an .eml file
                        // instead of an empty attachment.
                        if apc[0x3705]?.int == 5, let obj = bytes, obj.count >= 8,
                           let inner = subnodes(a.1)[Self.u32(obj, 0)],
                           let eml = embeddedMessage(data: inner.0, sub: inner.1) {
                            bytes = eml.message
                            mime = "message/rfc822"
                            if apc[0x3707] == nil && apc[0x3704] == nil { name = eml.subject.isEmpty ? "attached message" : eml.subject }
                            if !name.lowercased().hasSuffix(".eml") { name += ".eml" }
                        }
                        let size = bytes?.count ?? Int(apc[0x0E20]?.int ?? 0)
                        // The attachment's content travels with it, as the earlier reader
                        // did; without it the import kept only names and sizes (B8 test).
                        m.attachments.append(AttachmentMetadata(filename: name, mimeType: mime,
                                                                size: size, isInline: apc[0x3712] != nil, contentID: apc[0x3712]?.string,
                                                                base64: bytes.map { Data($0).base64EncodedString() }))
                    }
                    m.hasAttachments = !m.attachments.isEmpty
                }
                if folderCache[node.parent] == nil { folderCache[node.parent] = folderPath(node.parent) }
                let path = folderCache[node.parent] ?? nil
                m.folderPath = path ?? ""
                if RecoveryPolicy.isEnabled {
                    if let path { m.recovery = RecoveryDetector.fromFolder(path, method: "pst-folder") }
                    else if node.parent != 0 {
                        m.recovery = RecoveryInfo(state: .orphan, method: "pst-orphan",
                                                  evidence: String(format: "node 0x%08X, parent 0x%08X is not a folder", node.nid, node.parent))
                    }
                }
                out.append(m)
            }
        }
        return out
    }

    /// Message classes that are mail ([MS-OXCMSG] 2.2.1.3): notes, posts,
    /// meeting messages, reports, recalls. Not: contacts, appointments, tasks,
    /// sticky notes, journal, distribution lists, RSS items, configuration.
    static func isMail(_ cls: String) -> Bool {
        let c = cls.lowercased()
        if c.hasPrefix("ipm.post.rss") { return false }
        for p in ["ipm.note", "ipm.post", "ipm.schedule.meeting", "report.", "ipm.outlook.recall", "ipm.recall", "ipm.sharing", "ipm.document"] where c.hasPrefix(p) { return true }
        return c == "ipm" || c.isEmpty
    }

    /// PR_SUBJECT may begin with a 0x01 + length prefix (the normalized-subject split).
    static func subject(_ s: String) -> String {
        guard let first = s.unicodeScalars.first, first.value == 1, s.count >= 2 else { return s }
        return String(s.dropFirst(2))
    }

    // MARK: Deep recovery — freed heap pages

    /// Property contexts in space no block uses (64-byte steps), read as
    /// single-page heaps; carved and partial, with their byte offsets.
    func carveUnallocated(listed: [PSTReader.PSTMessage]) -> [PSTReader.PSTMessage] {
        // A copy is the same message only if its Message-ID and delivery time
        // match too: identical test messages or alerts are separate evidence.
        func key(_ subject: String, _ body: String, _ id: String?, _ time: Date?) -> String {
            [subject, id ?? "", time.map { String(Int($0.timeIntervalSince1970)) } ?? "", String(body.prefix(64))].joined(separator: "|")
        }
        let listedKeys = Set(listed.map { key($0.subject, $0.bodyText, $0.internetMessageId, $0.deliveryTime) })
        let listedSubjects = Set(listed.map(\.subject))
        var allocated = blocks.values.map { (Int($0.ib), Int($0.ib) + $0.cb + (unicode ? 16 : 12)) }
        allocated.sort { $0.0 < $1.0 }
        var out: [PSTReader.PSTMessage] = []
        var seen = Set<String>()
        var r = 0
        var pos = 4096
        while pos + 64 < bytes.count {
            while r < allocated.count && allocated[r].1 <= pos { r += 1 }
            if r < allocated.count && allocated[r].0 <= pos { pos = (allocated[r].1 + 63) & ~63; continue }
            // Cheap test first: the heap signature bytes, decoded on their own.
            var sig = [bytes[bytes.startIndex + pos + 2], bytes[bytes.startIndex + pos + 3]]
            if crypt == 1 { PSTSpec.decodePermute(&sig) }
            if sig[0] == 0xEC, sig[1] == 0xBC { autoreleasepool {
                let end = min(bytes.count, pos + 8192)
                var chunk = [UInt8](bytes[(bytes.startIndex + pos)..<(bytes.startIndex + end)])
                if crypt == 1 { PSTSpec.decodePermute(&chunk) }
                if chunk.count > 12, let heap = Heap([chunk]) {
                    var pc: [UInt16: PSTValue] = [:]
                    for (k, v) in bth(heap, heap.userRoot) where k.count == 2 && v.count == 6 {
                        if let val = value(type: Self.u16(v, 0), inline: Self.u32(v, 2), heap: heap, subnodes: [:]) { pc[Self.u16(k, 0)] = val }
                    }
                    let subject = Self.subject(pc[0x0037]?.string ?? "")
                    let body = pc[0x1000]?.string ?? ""
                    let key = key(subject, body, pc[0x1035]?.string, pc[0x0E06]?.date)
                    // An exact earlier copy of a listed message adds nothing; an earlier
                    // version that differs is kept and said to be one.
                    if (!subject.isEmpty || !body.isEmpty), Self.isMail(pc[0x001A]?.string ?? ""),
                       !listedKeys.contains(key), seen.insert(key).inserted {
                        var m = PSTReader.PSTMessage()
                        m.subject = subject
                        m.bodyText = body
                        m.senderName = pc[0x0C1A]?.string ?? ""
                        m.senderEmail = pc[0x5D01]?.string ?? pc[0x0C1F]?.string ?? ""
                        m.displayTo = pc[0x0E04]?.string ?? ""
                        m.internetMessageId = pc[0x1035]?.string
                        m.deliveryTime = pc[0x0E06]?.date
                        m.transportHeaders = pc[0x007D]?.string ?? ""
                        let what = listedSubjects.contains(subject)
                            ? "an earlier version of a listed message, in unallocated space at byte \(pos)"
                            : "property context in unallocated space at byte \(pos)"
                        m.recovery = RecoveryInfo(state: .carved, method: "pst-amap-scan", evidence: what, offset: Int64(pos), partial: true)
                        out.append(m)
                    }
                }
            } }
            pos += 64
        }
        return out
    }
}
