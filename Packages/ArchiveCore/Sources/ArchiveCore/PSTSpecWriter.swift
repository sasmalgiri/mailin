//
//  PSTSpecWriter.swift
//  ArchiveCore
//
//  3.0 B8: an Outlook PST writer built from Microsoft's published [MS-PST]
//  specification — Unicode file, no data encoding — in place of the earlier
//  writer's simplified layout that only mailin itself could read.
//
//  NDB: 512-byte header with both CRCs, density list, allocation maps (AMap,
//  one per 253,952 bytes) and page maps, 64-byte-aligned blocks with
//  trailers (signature, CRC), XBLOCK/XXBLOCK data trees, SLBLOCK/SIBLOCK
//  subnode trees, node and block B-trees of 512-byte pages.
//  LTP: heap-on-node over as many blocks as needed (HNHDR, HNPAGEHDR,
//  HNBITMAPHDR), B-trees on the heap, property contexts and table contexts
//  with the column layouts Outlook itself writes (taken from real Outlook
//  files in the Digital Corpora set).
//  Messaging: message store, name-to-ID map, root folder, "Top of Personal
//  Folders", Search Root, Deleted Items, the export's folders, the table
//  templates, and per message its property context, recipient table,
//  attachment table and attachment objects.
//
//  Memory stays flat at any message count: blocks go to disk as they are
//  made; each folder's contents table is built while messages stream in;
//  node and block index entries are spilled to scratch files in sorted
//  order (ids only ever grow) and turned into B-tree pages at the end.
//
//  Checked with libpff (pypff) and libpst (readpst) as independent readers.
//  Outlook itself has not opened its files yet: switch `v3PSTSpecWriter`
//  is a preview until it does (rule 15).
//

import Foundation

public enum PSTWriterPolicy {
    /// Pushed by CapabilityWiring (`v3PSTSpecWriter`).
    nonisolated(unsafe) public static var useSpecWriter = false
}

/// What both PST writers offer the export service.
protocol PSTStreamWriting: AnyObject {
    var dataBytesWritten: UInt64 { get }
    func appendMessage(_ email: MBOXParser.RawEmail) throws
    @discardableResult func finalize() throws -> Int
    func abort()
}

extension PSTStreamWriter: PSTStreamWriting {
    func appendMessage(_ email: MBOXParser.RawEmail) throws { try append(email: email, folder: PSTStreamWriter.rootFolderNid) }
}

enum PSTWriterFactory {
    static func make(url: URL) throws -> PSTStreamWriting {
        PSTWriterPolicy.useSpecWriter ? try PSTSpecWriter(url: url) : try PSTStreamWriter(url: url)
    }
}

// MARK: - Little-endian helpers

private extension Data {
    mutating func u8(_ v: UInt8) { append(v) }
    mutating func u16(_ v: UInt16) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func u64(_ v: UInt64) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func put16(_ o: Int, _ v: UInt16) { self[o] = UInt8(v & 0xFF); self[o + 1] = UInt8(v >> 8) }
    mutating func put32(_ o: Int, _ v: UInt32) { for i in 0..<4 { self[o + i] = UInt8((v >> (8 * UInt32(i))) & 0xFF) } }
    mutating func put64(_ o: Int, _ v: UInt64) { for i in 0..<8 { self[o + i] = UInt8((v >> (8 * UInt64(i))) & 0xFF) } }
}

enum PSTSpecFormat {
    /// [MS-PST] 5.3: CRC-32 with the reflected 0xEDB88320 table, starting at 0, no final inversion.
    static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ 0xEDB8_8320 : c >> 1 }
        return c
    }
    static func crc(_ d: Data) -> UInt32 {
        var c: UInt32 = 0
        for b in d { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c
    }
    /// [MS-PST] 5.5: block and page signature.
    static func sig(_ ib: UInt64, _ bid: UInt64) -> UInt16 {
        let x = ib ^ bid
        return UInt16(truncatingIfNeeded: (x >> 16) ^ x)
    }
    static func fileTime(_ d: Date) -> UInt64 { UInt64(max(0, (d.timeIntervalSince1970 + 11_644_473_600) * 10_000_000)) }
    static func utf16(_ s: String) -> Data {
        var d = Data(capacity: s.utf16.count * 2)
        for u in s.utf16 { d.u16(u) }
        return d
    }

    static let pageSize = 512
    static let blockDataMax = 8176          // 8192 minus the 16-byte trailer
    static let maxAllocation = 3580          // largest heap allocation
    static let amapBase: UInt64 = 0x4400
    static let amapRegion: UInt64 = 253_952  // 496 bytes × 8 bits × 64 bytes
    static let dlistIB: UInt64 = 0x4200

    // NID types ([MS-PST] 2.2.2.1)
    static let tHID: UInt32 = 0x00, tInternal: UInt32 = 0x01, tFolder: UInt32 = 0x02, tSearchFolder: UInt32 = 0x03
    static let tMessage: UInt32 = 0x04, tAttachment: UInt32 = 0x05, tHierarchy: UInt32 = 0x0D, tContents: UInt32 = 0x0E
    static let tAssoc: UInt32 = 0x0F, tLTP: UInt32 = 0x1F
    static func nid(_ index: UInt32, _ type: UInt32) -> UInt32 { (index << 5) | type }
}

// MARK: - Property values

enum PSTSpecValue {
    case long(UInt32), short(UInt16), bool(Bool), time(Date), i64(UInt64)
    case unicode(String), binary(Data)

    var type: UInt16 {
        switch self {
        case .long: return 0x0003
        case .short: return 0x0002
        case .bool: return 0x000B
        case .time: return 0x0040
        case .i64: return 0x0014
        case .unicode: return 0x001F
        case .binary: return 0x0102
        }
    }
    /// Inline 4-byte value when the type fits ([MS-PST] 2.3.3.3).
    var inline: UInt32? {
        switch self {
        case .long(let v): return v
        case .short(let v): return UInt32(v)
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }
    /// Bytes of a non-inline value.
    var bytes: Data {
        switch self {
        case .time(let d): var x = Data(); x.u64(PSTSpecFormat.fileTime(d)); return x
        case .i64(let v): var x = Data(); x.u64(v); return x
        case .unicode(let s): return PSTSpecFormat.utf16(s)
        case .binary(let b): return b
        case .long(let v): var x = Data(); x.u32(v); return x
        case .short(let v): var x = Data(); x.u16(v); return x
        case .bool(let b): return Data([b ? 1 : 0])
        }
    }
}

// MARK: - The writer

final class PSTSpecWriter: PSTStreamWriting {
    typealias F = PSTSpecFormat

    enum WriteError: LocalizedError {
        case io(String)
        var errorDescription: String? { if case .io(let s) = self { return s }; return nil }
    }

    // File
    private let url: URL
    private let handle: FileHandle
    private var finished = false

    // NDB allocation: a bump allocator that steps over the fixed map pages.
    private var eof: UInt64 = 0x4800
    private var nextBid: UInt64 = 4
    private var nextPageBid: UInt64 = 1
    private var allocated: [(UInt64, UInt64)] = []   // merged [start, end) runs

    // Sorted index spills: the block index (bid order) and the message nodes (nid order).
    private let scratch: URL
    private let bbtSpill: FileHandle
    private let msgNbtSpill: FileHandle
    private var bbtCount = 0, msgNbtCount = 0
    private var specialNodes: [(nid: UInt32, data: UInt64, sub: UInt64, parent: UInt32)] = []

    // Store identity
    private let storeKey = Data((0..<16).map { _ in UInt8.random(in: 0...255) })

    // Folders
    private struct Folder {
        let nid: UInt32
        let name: String
        let parent: UInt32
        var count = 0
        var unread = 0
        var contents: TableBuilder?
        var containerClass: String?
        var children: [UInt32] = []
    }
    private var folders: [UInt32: Folder] = [:]
    private var folderOrder: [UInt32] = []
    private var nextFolderIndex: UInt32 = 0x404           // 0x401–0x403 are the fixed folders
    private var nextMessageIndex: UInt32 = 0x10000         // message NIDs sort after every other node
    private var rowVersion: UInt32 = 0x40
    private var recipientRowID: UInt32 = 0
    /// Recipient row IDs: unique in the file and never 0.
    func nextRecipientRowID() -> UInt32 { recipientRowID += 1; return recipientRowID }

    /// PidTagAttachSize as Outlook computes it: the bytes of every property value — strings
    /// and binaries by length, 4 per 32-bit integer (this one included), 1 per boolean,
    /// 8 per time. Matches 78 of 80 attachments in real Outlook files (the other two are
    /// embedded messages, which mailin writes as .eml files).
    static func attachmentSize(_ props: [(UInt16, PSTSpecValue)]) -> UInt32 {
        var n = 4   // PidTagAttachSize itself
        for (_, v) in props {
            switch v {
            case .long: n += 4
            case .bool: n += 1
            case .time, .i64: n += 8
            case .short: n += 0
            case .unicode, .binary: n += v.bytes.count
            }
        }
        return UInt32(clamping: n)
    }

    /// A MAPI one-off EntryID ([MS-OXCDATA] 2.2.5.1) for an SMTP recipient, Unicode, no rich info.
    static func oneOffEntryID(name: String, email: String) -> Data {
        var d = Data(count: 4)
        d.append(Data([0x81, 0x2B, 0x1F, 0xA4, 0xBE, 0xA3, 0x10, 0x19, 0x9D, 0x6E, 0x00, 0xDD, 0x01, 0x0F, 0x54, 0x02]))
        d.u16(0x0000); d.u16(0x8001)
        for s in [name.isEmpty ? email : name, "SMTP", email] { d.append(PSTSpecFormat.utf16(s)); d.u16(0) }
        return d
    }
    /// A rising row version for each table row, as Outlook numbers them.
    func nextRowVersion() -> UInt32 { rowVersion += 4; return rowVersion }
    /// Highest NID index used for NID_TYPE_LTP subnodes: the header's rgnid[31] must be past
    /// it (SCANPST "Header NID high-water mark has incorrect value (type=31)").
    private var maxLTPIndex: UInt32 = 1
    func noteLTPIndex(_ i: UInt32) { maxLTPIndex = max(maxLTPIndex, i) }
    private(set) var defaultFolder: UInt32 = 0
    private var messages = 0

    static let rootNid = F.nid(0x9, F.tFolder)             // 0x122
    static let ipmSubtreeNid = F.nid(0x401, F.tFolder)     // 0x8022
    static let maxFileBytes: UInt64 = 50_000_000_000
    static let searchRootNid = F.nid(0x402, F.tFolder)     // 0x8042
    static let spamSearchFolderNid = F.nid(0x111, 3)        // 0x2223, NID_TYPE_SEARCH_FOLDER
    static let spamSearchFolderName = "SPAM Search Folder 2"
    static let deletedItemsNid = F.nid(0x403, F.tFolder)   // 0x8062

    var dataBytesWritten: UInt64 { eof }

    init(url: URL, exportFolderName: String = "mailin export") throws {
        self.url = url
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: url) else { throw WriteError.io("Cannot open \(url.lastPathComponent) for writing") }
        handle = h
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("pstspec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        for name in ["bbt", "nbt"] { FileManager.default.createFile(atPath: scratch.appendingPathComponent(name).path, contents: nil) }
        bbtSpill = try FileHandle(forWritingTo: scratch.appendingPathComponent("bbt"))
        msgNbtSpill = try FileHandle(forWritingTo: scratch.appendingPathComponent("nbt"))

        folders[Self.rootNid] = Folder(nid: Self.rootNid, name: "", parent: Self.rootNid)
        folders[Self.ipmSubtreeNid] = Folder(nid: Self.ipmSubtreeNid, name: "Top of Personal Folders", parent: Self.rootNid)
        folders[Self.searchRootNid] = Folder(nid: Self.searchRootNid, name: "Search Root", parent: Self.rootNid)
        folders[Self.deletedItemsNid] = Folder(nid: Self.deletedItemsNid, name: "Deleted Items", parent: Self.ipmSubtreeNid, containerClass: "IPF.Note")
        folderOrder = [Self.rootNid, Self.ipmSubtreeNid, Self.searchRootNid, Self.deletedItemsNid]
        folders[Self.rootNid]!.children = [Self.ipmSubtreeNid, Self.searchRootNid]
        folders[Self.ipmSubtreeNid]!.children = [Self.deletedItemsNid]
        defaultFolder = appendFolder(name: exportFolderName)
    }

    deinit { try? FileManager.default.removeItem(at: scratch) }

    func abort() {
        try? handle.close()
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: Folders and messages

    /// Adds a mail folder; returns its NID. Default parent: Top of Personal Folders.
    @discardableResult
    func appendFolder(name: String, parent: UInt32 = PSTSpecWriter.ipmSubtreeNid) -> UInt32 {
        let nid = F.nid(nextFolderIndex, F.tFolder)
        nextFolderIndex += 1
        folders[nid] = Folder(nid: nid, name: name, parent: parent, containerClass: "IPF.Note")
        folders[parent]?.children.append(nid)
        folderOrder.append(nid)
        return nid
    }

    func appendMessage(_ email: MBOXParser.RawEmail) throws { try append(email: email, folder: defaultFolder) }

    func append(email: MBOXParser.RawEmail, folder: UInt32) throws {
        guard !finished else { throw WriteError.io("The PST writer is already finished") }
        guard folders[folder] != nil else { throw WriteError.io("Unknown folder") }
        // Same stated ceiling as the earlier writer: Outlook refuses larger files.
        guard eof <= Self.maxFileBytes else { throw PSTWriter.WriterError.formatSizeExceeded(eof) }
        let nid = F.nid(nextMessageIndex, F.tMessage)
        nextMessageIndex += 1
        var msg = try MessageBuild(writer: self, email: email)
        let (data, sub) = try msg.write()
        try spillNBT(msgNbtSpill, nid: nid, data: data, sub: sub, parent: folder)
        msgNbtCount += 1
        messages += 1
        folders[folder]!.count += 1
        if folders[folder]!.contents == nil { folders[folder]!.contents = TableBuilder(writer: self, columns: Templates.contents) }
        try folders[folder]!.contents!.addRow(rowID: nid, msg.contentsRow)
    }

    // MARK: NDB — allocation and blocks

    private func fixedPage(at ib: UInt64) -> UInt64? {
        // AMap at the start of each region; a PMap right after it in every 8th region.
        guard ib >= F.amapBase else { return nil }
        let k = (ib - F.amapBase) / F.amapRegion
        let a = F.amapBase + k * F.amapRegion
        if ib >= a && ib < a + 512 { return a + 512 }
        if k % 8 == 0 && ib >= a + 512 && ib < a + 1024 { return a + 1024 }
        return nil
    }

    private func reserve(_ size: Int, align: UInt64) -> UInt64 {
        var pos = (eof + align - 1) / align * align
        while true {
            var moved = false
            var p = pos
            while p < pos + UInt64(size) {
                if let end = fixedPage(at: p) { pos = (end + align - 1) / align * align; moved = true; break }
                p += 512 - (p % 512)
            }
            if !moved { break }
        }
        let end = pos + UInt64(size)
        if let last = allocated.last, last.1 == pos { allocated[allocated.count - 1].1 = end } else { allocated.append((pos, end)) }
        eof = max(eof, end)
        return pos
    }

    private func writeAt(_ d: Data, _ ib: UInt64) throws {
        try handle.seek(toOffset: ib)
        try handle.write(contentsOf: d)
    }

    private func spillNBT(_ h: FileHandle, nid: UInt32, data: UInt64, sub: UInt64, parent: UInt32) throws {
        var r = Data(); r.u32(nid); r.u32(parent); r.u64(data); r.u64(sub)
        try h.write(contentsOf: r)
    }

    /// One block (≤ 8176 bytes), 64-byte aligned, with its trailer; recorded in the block index.
    func writeBlock(_ data: Data, isInternal: Bool) throws -> UInt64 {
        precondition(data.count <= F.blockDataMax)
        let bid = nextBid | (isInternal ? 2 : 0)
        nextBid += 4
        let total = (data.count + 16 + 63) / 64 * 64
        let ib = reserve(total, align: 64)
        var blk = data
        blk.append(Data(repeating: 0, count: total - 16 - data.count))
        blk.u16(UInt16(data.count)); blk.u16(F.sig(ib, bid)); blk.u32(F.crc(data)); blk.u64(bid)
        try writeAt(blk, ib)
        var r = Data(); r.u64(bid); r.u64(ib); r.u16(UInt16(data.count)); r.u16(2)
        try bbtSpill.write(contentsOf: r)
        bbtCount += 1
        return bid
    }

    /// A node's data: one block, or an XBLOCK / XXBLOCK over already written blocks.
    func dataTree(_ bids: [UInt64], totalBytes: Int) throws -> UInt64 {
        if bids.isEmpty { return 0 }
        if bids.count == 1 { return bids[0] }
        func xblock(level: UInt8, _ children: [UInt64], _ total: Int) throws -> UInt64 {
            var d = Data(); d.u8(1); d.u8(level); d.u16(UInt16(children.count)); d.u32(UInt32(total))
            for c in children { d.u64(c) }
            return try writeBlock(d, isInternal: true)
        }
        if bids.count <= 1021 { return try xblock(level: 1, bids, totalBytes) }
        var xs: [UInt64] = []
        var remaining = totalBytes
        for start in stride(from: 0, to: bids.count, by: 1021) {
            let part = Array(bids[start..<min(start + 1021, bids.count)])
            let bytes = min(remaining, part.count * F.blockDataMax)
            remaining -= bytes
            xs.append(try xblock(level: 1, part, bytes))
        }
        precondition(xs.count <= 1021, "node data above 8.5 GB")
        return try xblock(level: 2, xs, totalBytes)
    }

    func writeData(_ d: Data) throws -> UInt64 {
        if d.isEmpty { return 0 }
        var bids: [UInt64] = []
        for start in stride(from: 0, to: d.count, by: F.blockDataMax) {
            bids.append(try writeBlock(d.subdata(in: start..<min(start + F.blockDataMax, d.count)), isInternal: false))
        }
        return try dataTree(bids, totalBytes: d.count)
    }

    /// A subnode tree (SLBLOCK, or SIBLOCK over SLBLOCKs).
    func subnodeTree(_ entries: [(nid: UInt32, data: UInt64, sub: UInt64)]) throws -> UInt64 {
        if entries.isEmpty { return 0 }
        let sorted = entries.sorted { $0.nid < $1.nid }
        func sl(_ part: ArraySlice<(nid: UInt32, data: UInt64, sub: UInt64)>) throws -> UInt64 {
            var d = Data(); d.u8(2); d.u8(0); d.u16(UInt16(part.count)); d.u32(0)
            for e in part { d.u64(UInt64(e.nid)); d.u64(e.data); d.u64(e.sub) }
            return try writeBlock(d, isInternal: true)
        }
        if sorted.count <= 340 { return try sl(sorted[...]) }
        var d = Data(); var children: [(UInt32, UInt64)] = []
        for start in stride(from: 0, to: sorted.count, by: 340) {
            let part = sorted[start..<min(start + 340, sorted.count)]
            children.append((part.first!.nid, try sl(part)))
        }
        precondition(children.count <= 510)
        d.u8(2); d.u8(1); d.u16(UInt16(children.count)); d.u32(0)
        for (nid, bid) in children { d.u64(UInt64(nid)); d.u64(bid) }
        return try writeBlock(d, isInternal: true)
    }

    // MARK: LTP — heap-on-node

    /// Builds a heap over as many blocks as it needs; blocks after the first go
    /// to disk as soon as they are full.
    final class HeapBuilder {
        private unowned let writer: PSTSpecWriter
        let clientSig: UInt8
        private var blockIndex = 0
        private var current = Data()          // allocations of the open block
        private var starts: [Int] = []        // allocation start offsets (relative to the block)
        private var header: Int { Self.headerSize(blockIndex) }
        private var block0: Data?
        private var bids: [UInt64] = []        // index 1… (index 0 written at finish)
        private var fill: [Int: UInt8] = [:]
        private(set) var totalBytes = 0

        init(writer: PSTSpecWriter, clientSig: UInt8) { self.writer = writer; self.clientSig = clientSig; starts = [] }

        static func headerSize(_ i: Int) -> Int { i == 0 ? 12 : ((i - 8) % 128 == 0 && i >= 8 ? 66 : 2) }

        private func pageMapSize(_ allocs: Int) -> Int { 4 + 2 * (allocs + 1) }

        func alloc(_ bytes: Data) throws -> UInt32 {
            precondition(bytes.count <= PSTSpecFormat.maxAllocation)
            let used = header + current.count + bytes.count
            if (used + 1) / 2 * 2 + pageMapSize(starts.count + 1) > PSTSpecFormat.blockDataMax {
                try closeBlock()
            }
            starts.append(header + current.count)
            current.append(bytes)
            return UInt32(blockIndex << 16) | UInt32(starts.count << 5)
        }

        private static func level(_ free: Int) -> UInt8 {
            switch free {
            case 3584...: return 0x0
            case 2560...: return 0x1
            case 2048...: return 0x2
            case 1792...: return 0x3
            case 1536...: return 0x4
            case 1280...: return 0x5
            case 1024...: return 0x6
            case 768...: return 0x7
            case 512...: return 0x8
            case 256...: return 0x9
            case 128...: return 0xA
            case 64...: return 0xB
            case 32...: return 0xC
            case 16...: return 0xD
            case 8...: return 0xE
            default: return 0xF
            }
        }

        private func blockBytes(root: UInt32) -> Data {
            var d = Data(count: header)
            d.append(current)
            if d.count % 2 == 1 { d.append(0) }
            let ibHnpm = UInt16(d.count)
            d.u16(UInt16(starts.count)); d.u16(0)
            for s in starts { d.u16(UInt16(s)) }
            d.u16(UInt16(header + current.count))
            d.put16(0, ibHnpm)
            if blockIndex == 0 {
                d[2] = 0xEC; d[3] = clientSig; d.put32(4, root)
                // rgbFillLevel for blocks 0–7 (two per byte, low nibble first).
                var levels = [UInt8](repeating: 0, count: 8)
                levels[0] = Self.level(PSTSpecFormat.blockDataMax - d.count)
                for i in 1..<8 { levels[i] = fill[i] ?? 0 }
                for i in 0..<4 { d[8 + i] = levels[2 * i] | (levels[2 * i + 1] << 4) }
            } else if (blockIndex - 8) % 128 == 0 && blockIndex >= 8 {
                // HNBITMAPHDR: its own level is known; later blocks are not yet, so they read as full.
                var levels = [UInt8](repeating: 0xF, count: 128)
                levels[0] = Self.level(PSTSpecFormat.blockDataMax - d.count)
                for i in 0..<64 { d[2 + i] = levels[2 * i] | (levels[2 * i + 1] << 4) }
            }
            return d
        }

        private func closeBlock() throws {
            var d = blockBytes(root: 0)
            fill[blockIndex] = Self.level(PSTSpecFormat.blockDataMax - d.count)
            // A heap block followed by another is padded to the whole block after its page
            // map, as Outlook writes them: every block but the last in a data tree must be
            // full (SCANPST "Middle page not full"). ibHnpm still points at the map.
            if d.count < PSTSpecFormat.blockDataMax { d.append(Data(count: PSTSpecFormat.blockDataMax - d.count)) }
            totalBytes += d.count
            if blockIndex == 0 { block0 = d } else { bids.append(try writer.writeBlock(d, isInternal: false)) }
            blockIndex += 1
            current = Data(); starts = []
        }

        /// Writes the heap; returns the node's data BID.
        func finish(root: UInt32) throws -> UInt64 {
            if blockIndex == 0 {
                let d = blockBytes(root: root)
                totalBytes += d.count
                return try writer.writeBlock(d, isInternal: false)
            }
            // Close the open block, then write block 0 with the root and fill levels.
            if !current.isEmpty || starts.isEmpty == false { try closeBlock() }
            var b0 = block0!
            b0.put32(4, root)
            var levels = [UInt8](repeating: 0, count: 8)
            for i in 0..<8 { levels[i] = fill[i] ?? 0 }
            for i in 0..<4 { b0[8 + i] = levels[2 * i] | (levels[2 * i + 1] << 4) }
            let bid0 = try writer.writeBlock(b0, isInternal: false)
            return try writer.dataTree([bid0] + bids, totalBytes: totalBytes)
        }
    }

    // MARK: LTP — B-tree on heap

    /// Records added in ascending key order; leaves go to the heap as they fill.
    final class BTHBuilder {
        private let heap: HeapBuilder
        let cbKey: Int, cbEnt: Int
        private var leaf = Data()
        private var leafFirst: Data?
        private var level0: [(Data, UInt32)] = []
        private var perLeaf: Int { PSTSpecFormat.maxAllocation / (cbKey + cbEnt) }
        private var inLeaf = 0

        init(heap: HeapBuilder, cbKey: Int, cbEnt: Int) { self.heap = heap; self.cbKey = cbKey; self.cbEnt = cbEnt }

        func add(key: Data, value: Data) throws {
            precondition(key.count == cbKey && value.count == cbEnt)
            if leafFirst == nil { leafFirst = key }
            leaf.append(key); leaf.append(value); inLeaf += 1
            if inLeaf == perLeaf { try flush() }
        }

        private func flush() throws {
            guard inLeaf > 0, let first = leafFirst else { return }
            level0.append((first, try heap.alloc(leaf)))
            leaf = Data(); leafFirst = nil; inLeaf = 0
        }

        /// Writes index levels and the BTHHEADER; returns the header's HID.
        func finish() throws -> UInt32 {
            try flush()
            var levels: UInt8 = 0
            var nodes = level0
            let perIndex = PSTSpecFormat.maxAllocation / (cbKey + 4)
            while nodes.count > 1 {
                var up: [(Data, UInt32)] = []
                for start in stride(from: 0, to: nodes.count, by: perIndex) {
                    var d = Data()
                    for (k, hid) in nodes[start..<min(start + perIndex, nodes.count)] { d.append(k); d.u32(hid) }
                    up.append((nodes[start].0, try heap.alloc(d)))
                }
                nodes = up
                levels += 1
            }
            var h = Data(); h.u8(0xB5); h.u8(UInt8(cbKey)); h.u8(UInt8(cbEnt)); h.u8(levels); h.u32(nodes.first?.1 ?? 0)
            return try heap.alloc(h)
        }
    }

    // MARK: LTP — property context

    /// Writes a property context node; large values become subnodes.
    func propertyContext(_ props: [(UInt16, PSTSpecValue)], extraSubnodes: [(nid: UInt32, data: UInt64, sub: UInt64)] = [],
                         nextSubnodeIndex: inout UInt32) throws -> (data: UInt64, sub: UInt64) {
        let heap = HeapBuilder(writer: self, clientSig: 0xBC)
        let bth = BTHBuilder(heap: heap, cbKey: 2, cbEnt: 6)
        var subs = extraSubnodes
        for (id, v) in props.sorted(by: { $0.0 < $1.0 }) {
            var hnid: UInt32
            if let inline = v.inline {
                hnid = inline
            } else {
                let bytes = v.bytes
                if bytes.isEmpty {
                    hnid = 0
                } else if bytes.count <= F.maxAllocation {
                    hnid = try heap.alloc(bytes)
                } else {
                    let snid = F.nid(nextSubnodeIndex, F.tLTP)
                    noteLTPIndex(nextSubnodeIndex)
                    nextSubnodeIndex += 1
                    subs.append((snid, try writeData(bytes), 0))
                    hnid = snid
                }
            }
            var k = Data(); k.u16(id)
            var e = Data(); e.u16(v.type); e.u32(hnid)
            try bth.add(key: k, value: e)
        }
        let root = try bth.finish()
        return (try heap.finish(root: root), try subnodeTree(subs))
    }

    // MARK: LTP — table context

    struct Column { let tag: UInt32; let ib: Int; let cb: Int; let bit: Int }

    /// A table built row by row; rows and heap blocks go to disk as they fill.
    final class TableBuilder {
        private unowned let writer: PSTSpecWriter
        let columns: [Column]
        let rowSize: Int
        private let cebOffset: Int
        private let heap: HeapBuilder
        private let index: BTHBuilder
        private var rowBlock = Data()
        private var rowBids: [UInt64] = []
        private var rowBytes = 0
        private(set) var rows = 0
        private var extraSubnodes: [(nid: UInt32, data: UInt64, sub: UInt64)] = []
        private var nextSub: UInt32 = 2
        private var perBlock: Int { PSTSpecFormat.blockDataMax / rowSize }

        init(writer: PSTSpecWriter, columns: Templates.Layout) {
            self.writer = writer
            self.columns = columns.columns
            rowSize = columns.rgib.3
            cebOffset = columns.rgib.2
            heap = HeapBuilder(writer: writer, clientSig: 0x7C)
            index = BTHBuilder(heap: heap, cbKey: 4, cbEnt: 4)
            rgib = columns.rgib
        }
        private let rgib: (Int, Int, Int, Int)

        private var lastRowID: UInt32?

        func addRow(rowID: UInt32, _ values: [UInt32: PSTSpecValue]) throws {
            // The row index is a B-tree streamed in key order: a row ID out of order (or
            // repeated) makes the table invalid ("keys overlap" in SCANPST).
            if let last = lastRowID, rowID <= last {
                throw WriteError.io("Table rows must be added in ascending row ID (\(rowID) after \(last))")
            }
            lastRowID = rowID
            var row = Data(count: rowSize)
            var vals = values
            vals[0x67F2_0003] = .long(rowID)
            // PidTagLtpRowVer: Outlook numbers row versions; a zero version on every row is not what it writes.
            if vals[0x67F3_0003] == nil { vals[0x67F3_0003] = .long(writer.nextRowVersion()) }
            for c in columns {
                guard let v = vals[c.tag] else { continue }
                if c.cb == 1 { row[c.ib] = UInt8(truncatingIfNeeded: v.inline ?? 0) }
                else if c.cb == 2 { row.put16(c.ib, UInt16(truncatingIfNeeded: v.inline ?? 0)) }
                else if c.cb == 8 { row.replaceSubrange(c.ib..<c.ib + 8, with: v.bytes) }
                else if let inline = v.inline { row.put32(c.ib, inline) }
                else {
                    let bytes = v.bytes
                    var hnid: UInt32 = 0
                    if !bytes.isEmpty {
                        if bytes.count <= PSTSpecFormat.maxAllocation { hnid = try heap.alloc(bytes) }
                        else {
                            let snid = PSTSpecFormat.nid(nextSub, PSTSpecFormat.tLTP); writer.noteLTPIndex(nextSub); nextSub += 1
                            extraSubnodes.append((snid, try writer.writeData(bytes), 0))
                            hnid = snid
                        }
                    }
                    row.put32(c.ib, hnid)
                }
                row[cebOffset + c.bit / 8] |= UInt8(0x80 >> (c.bit % 8))
            }
            var k = Data(); k.u32(rowID)
            var e = Data(); e.u32(UInt32(rows))
            try index.add(key: k, value: e)
            rowBlock.append(row)
            rows += 1
            if rowBlock.count / rowSize == perBlock { try flushRows(padToBlock: true) }
        }

        /// A full block of rows is padded to the whole block: every block but the last in
        /// a data tree must be full (SCANPST: "Middle page not full"; Outlook pads them).
        private func flushRows(padToBlock: Bool = false) throws {
            guard !rowBlock.isEmpty else { return }
            if padToBlock, rowBlock.count < PSTSpecFormat.blockDataMax {
                rowBlock.append(Data(count: PSTSpecFormat.blockDataMax - rowBlock.count))
            }
            rowBids.append(try writer.writeBlock(rowBlock, isInternal: false))
            rowBytes += rowBlock.count
            rowBlock = Data()
        }

        /// Writes the table; returns the node's data and subnode BIDs.
        func finish() throws -> (data: UInt64, sub: UInt64) {
            var hnidRows: UInt32 = 0
            var subs = extraSubnodes
            if rows > 0 {
                if rowBids.isEmpty && rowBlock.count <= PSTSpecFormat.maxAllocation {
                    hnidRows = try heap.alloc(rowBlock)
                } else {
                    try flushRows()
                    let snid = PSTSpecFormat.nid(1, PSTSpecFormat.tLTP)
                    subs.append((snid, try writer.dataTree(rowBids, totalBytes: rowBytes), 0))
                    hnidRows = snid
                }
            }
            let rowIndex = try index.finish()
            var t = Data()
            t.u8(0x7C); t.u8(UInt8(columns.count))
            t.u16(UInt16(rgib.0)); t.u16(UInt16(rgib.1)); t.u16(UInt16(rgib.2)); t.u16(UInt16(rgib.3))
            t.u32(rowIndex); t.u32(hnidRows); t.u32(0)
            for c in columns.sorted(by: { $0.tag < $1.tag }) { t.u32(c.tag); t.u16(UInt16(c.ib)); t.u8(UInt8(c.cb)); t.u8(UInt8(c.bit)) }
            let root = try heap.alloc(t)
            return (try heap.finish(root: root), try writer.subnodeTree(subs))
        }
    }

    // MARK: Table layouts (as Outlook writes them; Digital Corpora files)

    enum Templates {
        struct Layout { let rgib: (Int, Int, Int, Int); let columns: [Column] }
        private static func L(_ rgib: (Int, Int, Int, Int), _ c: [(UInt32, Int, Int, Int)]) -> Layout {
            Layout(rgib: rgib, columns: c.map { Column(tag: $0.0, ib: $0.1, cb: $0.2, bit: $0.3) })
        }
        static let hierarchy = L((52, 52, 53, 55), [
            (0x0E30_0102, 20, 4, 6), (0x0E33_0014, 24, 8, 7), (0x0E34_0102, 32, 4, 8), (0x0E38_0003, 36, 4, 9),
            (0x3001_001F, 8, 4, 2), (0x3602_0003, 12, 4, 3), (0x3603_0003, 16, 4, 4), (0x360A_000B, 52, 1, 5),
            (0x3613_001F, 40, 4, 10), (0x6635_0003, 44, 4, 11), (0x6636_0003, 48, 4, 12),
            (0x67F2_0003, 0, 4, 0), (0x67F3_0003, 4, 4, 1)])
        static let contents = L((120, 120, 122, 126), [
            (0x0017_0003, 20, 4, 5), (0x001A_001F, 12, 4, 3), (0x0036_0003, 60, 4, 15), (0x0037_001F, 28, 4, 7),
            (0x0039_0040, 40, 8, 9), (0x0042_001F, 24, 4, 6), (0x0057_000B, 120, 1, 13), (0x0058_000B, 121, 1, 14),
            (0x0070_001F, 68, 4, 17), (0x0071_0102, 72, 4, 18), (0x0E03_001F, 56, 4, 12), (0x0E04_001F, 52, 4, 11),
            (0x0E06_0040, 32, 8, 8), (0x0E07_0003, 16, 4, 4), (0x0E08_0003, 48, 4, 10), (0x0E17_0003, 8, 4, 2),
            (0x0E30_0102, 92, 4, 22), (0x0E33_0014, 96, 8, 23), (0x0E34_0102, 104, 4, 24), (0x0E38_0003, 116, 4, 27),
            (0x0E3C_0102, 112, 4, 26), (0x0E3D_0102, 108, 4, 25), (0x1097_0003, 64, 4, 16), (0x3008_0040, 84, 8, 21),
            (0x3013_0102, 76, 4, 19), (0x65C6_0003, 80, 4, 20), (0x67F2_0003, 0, 4, 0), (0x67F3_0003, 4, 4, 1)])
        static let assoc = L((56, 56, 57, 59), [
            (0x001A_001F, 12, 4, 3), (0x0E07_0003, 16, 4, 4), (0x0E17_0003, 8, 4, 2), (0x3001_001F, 20, 4, 5),
            (0x67F2_0003, 0, 4, 0), (0x67F3_0003, 4, 4, 1), (0x6800_001F, 44, 4, 11), (0x6803_000B, 56, 1, 12),
            (0x6805_1003, 48, 4, 13), (0x682F_001F, 52, 4, 14), (0x7003_0003, 24, 4, 6), (0x7004_0102, 28, 4, 7),
            (0x7005_0102, 32, 4, 8), (0x7006_001F, 36, 4, 9), (0x7007_0003, 40, 4, 10)])
        static let searchContents = L((72, 72, 75, 78), [
            (0x0017_0003, 28, 4, 7), (0x001A_001F, 20, 4, 5), (0x0036_0003, 60, 4, 16), (0x0037_001F, 36, 4, 9),
            (0x0042_001F, 32, 4, 8), (0x0057_000B, 72, 1, 14), (0x0058_000B, 73, 1, 15), (0x0E03_001F, 56, 4, 13),
            (0x0E04_001F, 52, 4, 12), (0x0E05_001F, 12, 4, 3), (0x0E06_0040, 40, 8, 10), (0x0E07_0003, 24, 4, 6),
            (0x0E08_0003, 48, 4, 11), (0x0E17_0003, 16, 4, 4), (0x0E2A_000B, 74, 1, 17), (0x3008_0040, 64, 8, 18),
            (0x67F1_0003, 8, 4, 2), (0x67F2_0003, 0, 4, 0), (0x67F3_0003, 4, 4, 1)])
        static let attachments = L((24, 24, 24, 25), [
            (0x0E20_0003, 12, 4, 3), (0x3704_001F, 20, 4, 5), (0x3705_0003, 16, 4, 4), (0x370B_0003, 8, 4, 2),
            (0x67F2_0003, 0, 4, 0), (0x67F3_0003, 4, 4, 1)])
        static let recipients = L((48, 48, 50, 52), [
            (0x0C15_0003, 24, 4, 7), (0x0E0F_000B, 48, 1, 2), (0x0FF9_0102, 32, 4, 9), (0x0FFE_0003, 36, 4, 10),
            (0x0FFF_0102, 16, 4, 5), (0x3001_001F, 20, 4, 6), (0x3002_001F, 8, 4, 3), (0x3003_001F, 12, 4, 4),
            (0x300B_0102, 28, 4, 8), (0x3900_0003, 40, 4, 11), (0x39FF_001F, 44, 4, 13), (0x3A40_000B, 49, 1, 12),
            (0x67F2_0003, 0, 4, 0), (0x67F3_0003, 4, 4, 1)])
        // The four further templates, as Outlook 2010 writes them (Digital Corpora bill.jobs PST).
        static let receiveFolders = L((16, 16, 16, 17), [
            (0x001A_001F, 12, 4, 3), (0x6605_0003, 8, 4, 2), (0x67F2_0003, 0, 4, 0), (0x67F3_0003, 4, 4, 1)])
        static let outgoingQueue = L((48, 48, 48, 50), [
            (0x000F_0040, 40, 8, 9), (0x0039_0040, 16, 8, 4), (0x0E07_0003, 36, 4, 8), (0x0E10_0003, 12, 4, 3),
            (0x0E14_0003, 8, 4, 2), (0x0E29_001F, 32, 4, 7), (0x0EA2_0003, 24, 4, 5), (0x67F1_0003, 28, 4, 6),
            (0x67F2_0003, 0, 4, 0), (0x67F3_0003, 4, 4, 1)])
        static let changeHistory = L((40, 40, 40, 42), [
            (0x001A_001F, 36, 4, 8), (0x0E30_0102, 16, 4, 4), (0x0E31_0102, 12, 4, 3), (0x0E33_0014, 28, 8, 7),
            (0x0E34_0102, 24, 4, 6), (0x0E38_0003, 20, 4, 5), (0x0E3E_0102, 8, 4, 2), (0x67F2_0003, 0, 4, 0),
            (0x67F3_0003, 4, 4, 1)])
        static let tombstones = L((24, 24, 24, 25), [
            (0x0E33_0014, 16, 8, 3), (0x3007_0040, 8, 8, 2), (0x67F2_0003, 0, 4, 0), (0x67F3_0003, 4, 4, 1)])
        static let searchFolders = L((24, 24, 24, 25), [
            (0x0E33_0014, 8, 8, 2), (0x0E37_0102, 16, 4, 3), (0x0E38_0003, 20, 4, 4),
            (0x67F2_0003, 0, 4, 0), (0x67F3_0003, 4, 4, 1)])
    }

    // MARK: Messages

    struct Address { let name: String; let email: String }

    static func addresses(_ header: String?) -> [Address] {
        guard let header, !header.isEmpty else { return [] }
        var out: [Address] = []
        var depth = 0, inQuote = false, cur = ""
        func flush() {
            let part = cur.trimmingCharacters(in: .whitespaces); cur = ""
            guard !part.isEmpty else { return }
            if let lt = part.lastIndex(of: "<"), let gt = part.lastIndex(of: ">"), lt < gt {
                let email = String(part[part.index(after: lt)..<gt]).trimmingCharacters(in: .whitespaces)
                let name = String(part[..<lt]).trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
                out.append(Address(name: name.isEmpty ? email : name, email: email))
            } else {
                out.append(Address(name: part, email: part))
            }
        }
        for ch in header {
            if ch == "\"" { inQuote.toggle() }
            if ch == "<" { depth += 1 } else if ch == ">" { depth -= 1 }
            if ch == ",", !inQuote, depth == 0 { flush() } else { cur.append(ch) }
        }
        flush()
        return out
    }

    /// One message: its property context, recipient table, attachment table
    /// and attachment objects; and the row for its folder's contents table.
    struct MessageBuild {
        unowned let writer: PSTSpecWriter
        let email: MBOXParser.RawEmail
        var contentsRow: [UInt32: PSTSpecValue] = [:]

        init(writer: PSTSpecWriter, email: MBOXParser.RawEmail) throws {
            self.writer = writer
            self.email = email
        }

        private func header(_ name: String) -> String? {
            email.headers[name] ?? email.headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }

        mutating func write() throws -> (data: UInt64, sub: UInt64) {
            let date = ISO8601DateFormatter().date(from: email.timestamp) ?? RFC5322Date.parse(header("Date") ?? "") ?? Date(timeIntervalSince1970: 0)
            let from = PSTSpecWriter.addresses(header("From")).first
            let to = PSTSpecWriter.addresses(header("To")), cc = PSTSpecWriter.addresses(header("Cc")), bcc = PSTSpecWriter.addresses(header("Bcc"))
            let subject = header("Subject") ?? ""
            let hasAttachments = !email.attachments.isEmpty
            let flags: UInt32 = 0x01 | (hasAttachments ? 0x10 : 0)
            var size = email.rawSource.utf8.count
            if size == 0 { size = email.plainBody.utf8.count + email.htmlBody.utf8.count }

            var p: [(UInt16, PSTSpecValue)] = [
                (0x001A, .unicode("IPM.Note")), (0x0037, .unicode(subject)), (0x0070, .unicode(subject)),
                (0x0017, .long(1)), (0x0036, .long(0)),
                (0x0039, .time(date)), (0x0E06, .time(date)), (0x3007, .time(date)), (0x3008, .time(date)),
                // PidTagMessageStatus and PidTagHasAttachments are computed by the store
                // ([MS-PST] 2.5.2.3: SPGET_MSGSTATUS, SPGET_HASATTACH; not settable) and Outlook
                // never stores them on the message; the status lives in the contents row.
                (0x0E07, .long(flags)), (0x0E08, .long(UInt32(min(size, Int(UInt32.max))))),
                (0x0E04, .unicode(to.map(\.name).joined(separator: "; "))),
                // PidTagSearchKey: required on every Message object PC ([MS-PST] 2.4.5.1.1);
                // 16 bytes, the email's own identifier, so it is unique and stable.
                (0x300B, .binary(withUnsafeBytes(of: email.id.uuid) { Data($0) })),
            ]
            // DisplayCc / DisplayBcc are computed from the recipient table by the store
            // ([MS-PST] 2.5.2.3, SPGET_DISPLAY); Outlook does not store them, and SCANPST
            // reports a contents row that differs from the computed value.
            if let f = from {
                p += [(0x0C1A, .unicode(f.name)), (0x0C1E, .unicode("SMTP")), (0x0C1F, .unicode(f.email)),
                      (0x0042, .unicode(f.name)), (0x0064, .unicode("SMTP")), (0x0065, .unicode(f.email))]
            }
            if let mid = header("Message-ID") { p.append((0x1035, .unicode(mid))) }
            if let irt = header("In-Reply-To") { p.append((0x1042, .unicode(irt))) }
            if let refs = header("References") { p.append((0x1039, .unicode(refs))) }
            if let end = email.rawSource.range(of: "\r\n\r\n") ?? email.rawSource.range(of: "\n\n") {
                let h = String(email.rawSource[..<end.lowerBound])
                if !h.isEmpty { p.append((0x007D, .unicode(h))) }
            }
            if !email.plainBody.isEmpty { p.append((0x1000, .unicode(email.plainBody))) }
            if !email.htmlBody.isEmpty { p.append((0x1013, .binary(Data(email.htmlBody.utf8)))) }

            var subIndex: UInt32 = 0x400
            var subs: [(nid: UInt32, data: UInt64, sub: UInt64)] = []

            // Recipients ([MS-PST] 2.4.5.3), always present, possibly empty.
            let recips = TableBuilder(writer: writer, columns: Templates.recipients)
            for (kind, list) in [(UInt32(1), to), (2, cc), (3, bcc)] {
                for a in list {
                    var search = Data("SMTP:\(a.email.uppercased())".utf8); search.append(0)
                    // Row IDs unique and non-zero, as Outlook numbers recipients (a row ID 0
                    // reads as "keys overlap" to SCANPST), with the one-off EntryID Outlook stores.
                    try recips.addRow(rowID: writer.nextRecipientRowID(), [
                        0x0FFF_0102: .binary(PSTSpecWriter.oneOffEntryID(name: a.name, email: a.email)),
                        0x0C15_0003: .long(kind), 0x0E0F_000B: .bool(true), 0x0FFE_0003: .long(6),
                        0x3001_001F: .unicode(a.name), 0x3002_001F: .unicode("SMTP"), 0x3003_001F: .unicode(a.email),
                        0x300B_0102: .binary(search), 0x3900_0003: .long(0), 0x39FF_001F: .unicode(a.name), 0x3A40_000B: .bool(false),
                    ])
                }
            }
            let r = try recips.finish()
            subs.append((0x692, r.data, r.sub))

            // Attachments: a table plus one object per attachment. Outlook writes the
            // table even when it is empty, and libpff rejects a message whose subnode
            // tree has recipients but no attachment table.
            let table = TableBuilder(writer: writer, columns: Templates.attachments)
            if hasAttachments {
                let cache = AttachmentHydrator.Cache()
                for (i, att) in email.attachments.enumerated() {
                    let anid = PSTSpecFormat.nid(subIndex, PSTSpecFormat.tAttachment)
                    subIndex += 1
                    let bytes = AttachmentHydrator.data(for: att, index: i, email: email, cache: cache) ?? Data()
                    let ext = (att.filename as NSString).pathExtension
                    var ap: [(UInt16, PSTSpecValue)] = [
                        (0x3705, .long(1)), (0x370B, .long(0xFFFF_FFFF)),
                        (0x3704, .unicode(att.filename)), (0x3707, .unicode(att.filename)), (0x3001, .unicode(att.filename)),
                        (0x370E, .unicode(att.mimeType)), (0x3701, .binary(bytes)),
                    ]
                    if !ext.isEmpty { ap.append((0x3703, .unicode("." + ext))) }
                    if let cid = att.contentID { ap.append((0x3712, .unicode(cid))) }
                    let attachSize = PSTSpecWriter.attachmentSize(ap)
                    ap.insert((0x0E20, .long(attachSize)), at: 0)
                    var attSub: UInt32 = 0x400
                    let a = try writer.propertyContext(ap, nextSubnodeIndex: &attSub)
                    subs.append((anid, a.data, a.sub))
                    try table.addRow(rowID: anid, [0x0E20_0003: .long(attachSize), 0x3704_001F: .unicode(att.filename),
                                                   0x3705_0003: .long(1), 0x370B_0003: .long(0xFFFF_FFFF)])
                }
                cache.removeTemporaryFiles()
            }
            let t = try table.finish()
            subs.append((0x671, t.data, t.sub))

            contentsRow = [
                0x0017_0003: .long(1), 0x001A_001F: .unicode("IPM.Note"), 0x0036_0003: .long(0), 0x0037_001F: .unicode(subject),
                0x0039_0040: .time(date), 0x0070_001F: .unicode(subject),
                0x0E04_001F: .unicode(to.map(\.name).joined(separator: "; ")), 0x0E06_0040: .time(date), 0x0E07_0003: .long(flags),
                0x0E08_0003: .long(UInt32(min(size, Int(UInt32.max)))), 0x0E17_0003: .long(0), 0x3008_0040: .time(date),
            ]
            if let f = from { contentsRow[0x0042_001F] = .unicode(f.name) }

            return try writer.propertyContext(p, extraSubnodes: subs, nextSubnodeIndex: &subIndex)
        }
    }

    // MARK: Finish

    private func entryID(_ nid: UInt32) -> Data {
        var d = Data(count: 4); d.append(storeKey); d.u32(nid); return d
    }

    private func emptyTable(_ layout: Templates.Layout) throws -> (data: UInt64, sub: UInt64) {
        try TableBuilder(writer: self, columns: layout).finish()
    }

    @discardableResult
    func finalize() throws -> Int {
        guard !finished else { return messages }
        finished = true
        var unused: UInt32 = 0x400

        // Message store, name-to-ID map.
        let store = try propertyContext([
            (0x0FF9, .binary(storeKey)), (0x3001, .unicode(url.deletingPathExtension().lastPathComponent)),
            (0x35DF, .long(0x89)), (0x35E0, .binary(entryID(Self.ipmSubtreeNid))),
            (0x35E3, .binary(entryID(Self.deletedItemsNid))), (0x35E7, .binary(entryID(Self.searchRootNid))),
            (0x67FF, .long(0)),
        ], nextSubnodeIndex: &unused)
        specialNodes.append((0x21, store.data, store.sub, 0))
        // Name-to-ID map ([MS-PST] 2.4.7): one standard named property, PidLidCommonStart
        // (PSETID_Common, 0x8516) as property 0x8000, with its hash bucket — readers
        // such as libpff refuse a map without entries. Bucket = (id ^ (wGuid<<1 | N)) % 251,
        // checked against an Outlook file (259 of 259 entries).
        let psetidCommon = Data([0x08, 0x20, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46])
        let lid: UInt32 = 0x8516, guidField: UInt16 = (3 << 1) | 0   // GUID stream index 0 → wGuid 3
        var nameEntry = Data(); nameEntry.u32(lid); nameEntry.u16(guidField); nameEntry.u16(0)
        let bucket = UInt16(0x1000 + (lid ^ UInt32(guidField)) % 251)
        let names = try propertyContext([(0x0001, .long(251)), (0x0002, .binary(psetidCommon)), (0x0003, .binary(nameEntry)),
                                         (0x0004, .binary(Data())), (bucket, .binary(nameEntry))],
                                        nextSubnodeIndex: &unused)
        specialNodes.append((0x61, names.data, names.sub, 0))
        specialNodes.append((0x1E1, 0, 0, 0))
        // The search activity list names the search folders (Outlook writes the spam folder first).
        var sal = Data(); sal.u32(Self.spamSearchFolderNid)
        specialNodes.append((0x201, try writeBlock(sal, isInternal: false), 0, 0))

        // Table templates.
        for (nid, layout) in [(UInt32(0x60D), Templates.hierarchy), (0x60E, Templates.contents), (0x60F, Templates.assoc),
                              (0x610, Templates.searchContents), (0x671, Templates.attachments), (0x692, Templates.recipients),
                              (0x6B6, Templates.searchFolders),
                              // The further templates an Outlook-made PST carries (SCANPST: "Missing template (nid=6F8)").
                              (0x64C, Templates.outgoingQueue),
                              (0x6D7, Templates.changeHistory), (0x6F8, Templates.tombstones)] {
            let t = try emptyTable(layout)
            specialNodes.append((nid, t.data, t.sub, 0))
        }

        // Receive folder table (0x62B): which folder new mail of each class goes to, the four
        // rows Outlook writes (SCANPST: "Receive folder table missing default message class").
        let inbox = folders.values.first { $0.name == "Inbox" && $0.parent == Self.ipmSubtreeNid }?.nid ?? defaultFolder
        let receive = TableBuilder(writer: self, columns: Templates.receiveFolders)
        for (i, (cls, target)) in [("", inbox), ("IPM", inbox), ("Report.IPM", inbox), ("IPC", Self.rootNid)].enumerated() {
            try receive.addRow(rowID: UInt32(i + 1), [0x001A_001F: .unicode(cls), 0x6605_0003: .long(target)])
        }
        let rf = try receive.finish()
        specialNodes.append((0x62B, rf.data, rf.sub, 0))

        // Folders: property context and the three tables each.
        for nid in folderOrder {
            guard let f = folders[nid] else { continue }
            var props: [(UInt16, PSTSpecValue)] = [
                (0x3001, .unicode(f.name)), (0x3602, .long(UInt32(f.count))), (0x3603, .long(UInt32(f.unread))),
                (0x360A, .bool(!f.children.isEmpty)),
            ]
            if let c = f.containerClass { props.append((0x3613, .unicode(c))) }
            let pcNode = try propertyContext(props, nextSubnodeIndex: &unused)
            specialNodes.append((nid, pcNode.data, pcNode.sub, f.parent))

            let hier = TableBuilder(writer: self, columns: Templates.hierarchy)
            if nid == Self.rootNid {
                // The spam search folder is a child of the root, listed in its hierarchy table (as
                // Outlook writes it); its NID (0x2223) sorts before the folders, so it comes first.
                try hier.addRow(rowID: Self.spamSearchFolderNid, [0x3001_001F: .unicode(Self.spamSearchFolderName), 0x3602_0003: .long(0),
                                                                  0x3603_0003: .long(0), 0x360A_000B: .bool(false)])
            }
            for child in f.children.sorted() {
                guard let c = folders[child] else { continue }
                var row: [UInt32: PSTSpecValue] = [0x3001_001F: .unicode(c.name), 0x3602_0003: .long(UInt32(c.count)),
                                                    0x3603_0003: .long(UInt32(c.unread)), 0x360A_000B: .bool(!c.children.isEmpty)]
                if let cls = c.containerClass { row[0x3613_001F] = .unicode(cls) }
                try hier.addRow(rowID: child, row)
            }
            let h = try hier.finish()
            let index = nid >> 5
            specialNodes.append((F.nid(index, F.tHierarchy), h.data, h.sub, 0))
            let c = try (f.contents ?? TableBuilder(writer: self, columns: Templates.contents)).finish()
            specialNodes.append((F.nid(index, F.tContents), c.data, c.sub, 0))
            let a = try emptyTable(Templates.assoc)
            specialNodes.append((F.nid(index, F.tAssoc), a.data, a.sub, 0))
        }

        // [MS-PST] 2.7.1 mandatory node 0x2223, the spam search folder (2.7.3.4.4), with the
        // objects Outlook writes beside it: its search update queue (0x2226, empty), search
        // criteria object (0x2227) and search contents table (0x2230). Outlook refuses a PST
        // without them; libpff and libpst do not notice.
        let spam = try propertyContext([(0x3001, .unicode(Self.spamSearchFolderName)), (0x3602, .long(0)),
                                        (0x3603, .long(0)), (0x360A, .bool(false))], nextSubnodeIndex: &unused)
        specialNodes.append((Self.spamSearchFolderNid, spam.data, spam.sub, Self.rootNid))
        specialNodes.append((F.nid(0x111, 6), 0, 0, 0))
        let criteria = try propertyContext([(0x660B, .long(0))], nextSubnodeIndex: &unused)
        specialNodes.append((F.nid(0x111, 7), criteria.data, criteria.sub, 0))
        let searchContents = try emptyTable(Templates.searchContents)
        specialNodes.append((F.nid(0x111, 0x10), searchContents.data, searchContents.sub, 0))

        // B-trees from the sorted spills.
        try bbtSpill.close(); try msgNbtSpill.close()
        let nbtRoot = try writeNBT()
        let bbtRoot = try writeBBT()

        // Density list, allocation maps, page maps, header.
        let regions = Int((max(eof, F.amapBase + 1) - F.amapBase + F.amapRegion - 1) / F.amapRegion)
        let fileEnd = F.amapBase + UInt64(regions) * F.amapRegion
        var amapFree: UInt64 = 0
        for r in 0..<regions {
            let base = F.amapBase + UInt64(r) * F.amapRegion
            var bits = Data(count: 496)
            func mark(_ s: UInt64, _ e: UInt64) {
                let lo = max(s, base), hi = min(e, base + F.amapRegion)
                guard lo < hi else { return }
                var u = (lo - base) / 64
                while base + u * 64 < hi { bits[Int(u / 8)] |= UInt8(0x80 >> (u % 8)); u += 1 }
            }
            mark(base, base + 512)
            if r % 8 == 0 { mark(base + 512, base + 1024) }
            for (s, e) in allocated where e > base && s < base + F.amapRegion { mark(s, e) }
            amapFree += UInt64(bits.reduce(0) { $0 + (8 - $1.nonzeroBitCount) }) * 64
            try writeMapPage(bits, ptype: 0x84, at: base)
            if r % 8 == 0 { try writeMapPage(Data(repeating: 0xFF, count: 496), ptype: 0x83, at: base + 512) }
        }
        var dlist = Data(count: 496)
        dlist[0] = 0                      // bFlags; no entries
        let dlistBid = nextPageBid; nextPageBid += 1
        try writePage(dlist, ptype: 0x86, at: F.dlistIB, bid: dlistBid)
        // The file ends where its last allocation map ends (as Outlook writes it).
        try handle.truncate(atOffset: fileEnd)
        try writeAt(header(nbt: nbtRoot, bbt: bbtRoot, eof: fileEnd,
                           amapLast: F.amapBase + UInt64(regions - 1) * F.amapRegion, amapFree: amapFree), 0)
        try handle.synchronize()
        try handle.close()
        try? FileManager.default.removeItem(at: scratch)
        return messages
    }

    private func writeMapPage(_ content: Data, ptype: UInt8, at ib: UInt64) throws {
        var d = content
        d.u8(ptype); d.u8(ptype); d.u16(0); d.u32(F.crc(content)); d.u64(ib)
        try writeAt(d, ib)
    }

    private func writePage(_ content: Data, ptype: UInt8, at ib: UInt64, bid: UInt64) throws {
        precondition(content.count == 496)
        var d = content
        d.u8(ptype); d.u8(ptype); d.u16(F.sig(ib, bid)); d.u32(F.crc(content)); d.u64(bid)
        try writeAt(d, ib)
    }

    /// Writes leaf pages from a sorted stream of entries, then the levels above; returns (bid, ib) of the root.
    private func writeTree(entries: AnyIterator<(key: UInt64, bytes: Data)>, leafSize: Int, ptype: UInt8) throws -> (UInt64, UInt64) {
        let leafMax = 488 / leafSize
        var level: [(UInt64, UInt64, UInt64)] = []      // (first key, bid, ib)
        var buf: [(key: UInt64, bytes: Data)] = []
        func page(_ items: [(key: UInt64, bytes: Data)], cbEnt: Int, max: Int, cLevel: UInt8) throws -> (UInt64, UInt64, UInt64) {
            var d = Data()
            for it in items { d.append(it.bytes) }
            d.append(Data(count: 488 - d.count))
            d.u8(UInt8(items.count)); d.u8(UInt8(max)); d.u8(UInt8(cbEnt)); d.u8(cLevel); d.u32(0)
            let ib = reserve(512, align: 512)
            let bid = nextPageBid; nextPageBid += 1
            try writePage(d, ptype: ptype, at: ib, bid: bid)
            return (items.first?.key ?? 0, bid, ib)
        }
        while let e = entries.next() {
            buf.append(e)
            if buf.count == leafMax { level.append(try page(buf, cbEnt: leafSize, max: leafMax, cLevel: 0)); buf = [] }
        }
        if !buf.isEmpty || level.isEmpty { level.append(try page(buf, cbEnt: leafSize, max: leafMax, cLevel: 0)) }
        var cLevel: UInt8 = 1
        while level.count > 1 {
            var up: [(UInt64, UInt64, UInt64)] = []
            for start in stride(from: 0, to: level.count, by: 20) {
                let items = level[start..<min(start + 20, level.count)].map { k, bid, ib -> (key: UInt64, bytes: Data) in
                    var d = Data(); d.u64(k); d.u64(bid); d.u64(ib); return (k, d)
                }
                up.append(try page(items, cbEnt: 24, max: 20, cLevel: cLevel))
            }
            level = up
            cLevel += 1
        }
        return (level[0].1, level[0].2)
    }

    private func spillReader(_ name: String, recordSize: Int) throws -> AnyIterator<Data> {
        let h = try FileHandle(forReadingFrom: scratch.appendingPathComponent(name))
        var buffer = Data()
        return AnyIterator {
            if buffer.count < recordSize {
                if let more = try? h.read(upToCount: recordSize * 4096), !more.isEmpty { buffer.append(more) }
            }
            guard buffer.count >= recordSize else { try? h.close(); return nil }
            let r = buffer.prefix(recordSize)
            buffer.removeFirst(recordSize)
            return Data(r)
        }
    }

    private func writeNBT() throws -> (UInt64, UInt64) {
        func leaf(_ nid: UInt32, _ data: UInt64, _ sub: UInt64, _ parent: UInt32) -> (key: UInt64, bytes: Data) {
            var d = Data(); d.u64(UInt64(nid)); d.u64(data); d.u64(sub); d.u32(parent); d.u32(0)
            return (UInt64(nid), d)
        }
        let special = specialNodes.sorted { $0.nid < $1.nid }.map { leaf($0.nid, $0.data, $0.sub, $0.parent) }
        var si = special.makeIterator()
        let msgs = try spillReader("nbt", recordSize: 24)
        let all = AnyIterator<(key: UInt64, bytes: Data)> {
            if let s = si.next() { return s }
            guard let r = msgs.next() else { return nil }
            func u32(_ o: Int) -> UInt32 { r.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) } }
            func u64(_ o: Int) -> UInt64 { r.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt64.self) } }
            return leaf(u32(0), u64(8), u64(16), u32(4))
        }
        return try writeTree(entries: all, leafSize: 32, ptype: 0x81)
    }

    private func writeBBT() throws -> (UInt64, UInt64) {
        let blocks = try spillReader("bbt", recordSize: 20)
        // Pages written for the NBT/BBT are not blocks; the spill is complete here.
        let all = AnyIterator<(key: UInt64, bytes: Data)> {
            guard let r = blocks.next() else { return nil }
            var d = Data(r.prefix(20)); d.u32(0)
            let bid = r.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
            return (bid, d)
        }
        return try writeTree(entries: all, leafSize: 24, ptype: 0x80)
    }

    private func header(nbt: (UInt64, UInt64), bbt: (UInt64, UInt64), eof: UInt64, amapLast: UInt64, amapFree: UInt64) -> Data {
        var h = Data(count: 564)
        h.replaceSubrange(0..<4, with: Data([0x21, 0x42, 0x44, 0x4E]))      // "!BDN"
        h.replaceSubrange(8..<10, with: Data([0x53, 0x4D]))                // "SM"
        h.put16(10, 23); h.put16(12, 19); h[14] = 1; h[15] = 1
        h.put64(32, nextPageBid)                                           // bidNextP
        h.put32(40, UInt32(messages + 1))                                  // dwUnique
        // rgnid: next free index per NID type.
        for t in 0..<32 { h.put32(44 + 4 * t, 0x400) }
        // Types this writer does not allocate: the values Outlook writes in a new file.
        h.put32(44 + 4 * 3, 0x4001); h.put32(44 + 4 * 6, 0x4001); h.put32(44 + 4 * 7, 0x4001); h.put32(44 + 4 * 8, 0x8000)
        h.put32(44 + 4 * Int(F.tLTP), max(0x400, maxLTPIndex + 1))
        h.put32(44 + 4 * Int(F.tFolder), nextFolderIndex)
        h.put32(44 + 4 * Int(F.tMessage), nextMessageIndex)
        h.put32(44 + 4 * Int(F.tHierarchy), nextFolderIndex)
        h.put32(44 + 4 * Int(F.tContents), nextFolderIndex)
        h.put32(44 + 4 * Int(F.tAssoc), nextFolderIndex)
        // ROOT
        h.put64(184, eof); h.put64(192, amapLast); h.put64(200, amapFree); h.put64(208, 0)
        h.put64(216, nbt.0); h.put64(224, nbt.1); h.put64(232, bbt.0); h.put64(240, bbt.1)
        h[248] = 2                                                         // fAMapValid = VALID_AMAP2
        for i in 256..<512 { h[i] = 0xFF }                                 // rgbFM, rgbFP (unused, 0xFF)
        h[512] = 0x80                                                      // bSentinel
        h[513] = 0                                                         // bCryptMethod: none
        h.put64(516, nextBid)                                              // bidNextB
        h.put32(4, F.crc(h.subdata(in: 8..<(8 + 471))))                   // dwCRCPartial
        h.put32(524, F.crc(h.subdata(in: 8..<(8 + 516))))                 // dwCRCFull
        return h
    }
}
