//
//  OLE2Reader.swift
//  ArchiveCore
//
//  The OLE2 / MS-CFB compound-file reader behind Outlook .msg/.oft and the
//  legacy Office readers (Word, Excel, PowerPoint, Publisher, Visio, Project).
//
//  CLOSE-01 (v4 plan §8.1): the reader used to take the whole file as one
//  `Data`, so a .msg file was read whole into memory and anything above
//  2,000,000,000 bytes was refused. It now reads through a `RandomAccessSource`
//  (a file handle, or memory for an attachment that is already in hand):
//
//   • the FAT and the mini FAT are read a sector at a time when a chain is
//     walked (a small cache, never the whole table);
//   • directory entries are read when the tree is walked;
//   • the mini stream is read mini sector by mini sector from its container;
//   • `streamEntry` hands a stream's bytes over in slices (contiguous sectors
//     coalesced into one read), so a multi-gigabyte attachment or body passes
//     through bounded memory and can be cancelled between slices.
//
//  Kept, and checked on every read: a chain that comes back to a sector it
//  already visited stops there (a loop), sector numbers outside the FAT or
//  the file end the chain, sizes are clamped, and `streamEntry` refuses a
//  stream whose chain loops, leaves the file or ends before its declared size
//  — with that reason, never a silently short stream.
//

import Foundation

/// A flat byte source over bytes already in memory (an attached .msg, an Office part).
final class DataRandomAccessSource: RandomAccessSource {
    private let data: Data
    let length: Int64
    let volumeCount = 1

    init(data: Data) {
        self.data = data
        length = Int64(data.count)
    }

    func read(at offset: Int64, count: Int) throws -> Data {
        guard offset >= 0, offset < length, count > 0 else { return Data() }
        let start = data.startIndex + Int(offset)
        let end = start + Int(min(Int64(count), length - offset))
        return data.subdata(in: start..<end)
    }
    func diskBase(_ disk: Int) -> Int64? { disk == 0 ? 0 : nil }
    func isDiskMissing(_ disk: Int) -> Bool { false }
}

/// Sectors a chain has visited: a set while the chain is short, a bitmap over
/// the file's sectors once it is long — memory follows the file's sector count
/// (one bit each), never the stream's bytes.
struct OLE2VisitedSectors {
    private var small = Set<Int>()
    private var bits: [UInt64] = []
    private let capacity: Int

    init(sectorCapacity: Int) { capacity = max(0, sectorCapacity) }

    /// False when `sector` was visited before.
    mutating func insert(_ sector: Int) -> Bool {
        if !bits.isEmpty, sector >= 0, sector < capacity {
            let word = sector >> 6, mask = UInt64(1) << UInt64(sector & 63)
            if bits[word] & mask != 0 { return false }
            bits[word] |= mask
            return true
        }
        guard small.insert(sector).inserted else { return false }
        if bits.isEmpty, small.count > 4_096, capacity > 0 {
            bits = [UInt64](repeating: 0, count: (capacity + 63) / 64)
            for s in small where s >= 0 && s < capacity {
                bits[s >> 6] |= UInt64(1) << UInt64(s & 63)
            }
            small = small.filter { $0 < 0 || $0 >= capacity }
        }
        return true
    }
}

/// One allocation table (the FAT or the mini FAT), read a sector at a time.
final class OLE2SectorTable {
    private let source: RandomAccessSource
    private let sectorSize: Int
    /// The table's own sectors, in order.
    let sectors: [Int]
    private let entriesPerSector: Int
    private var cache: [Int: Data] = [:]

    init(source: RandomAccessSource, sectorSize: Int, sectors: [Int]) {
        self.source = source
        self.sectorSize = sectorSize
        self.sectors = sectors
        entriesPerSector = sectorSize / 4
    }

    /// The entry for `index`, or nil when the table has no such entry (its
    /// sector is outside the table or the file).
    func entry(_ index: Int) throws -> Int32? {
        guard index >= 0 else { return nil }
        let which = index / entriesPerSector
        guard which < sectors.count else { return nil }
        let block: Data
        if let cached = cache[which] {
            block = cached
        } else {
            let offset = (Int64(sectors[which]) + 1) * Int64(sectorSize)
            block = sectors[which] < 0 ? Data() : try source.read(at: offset, count: sectorSize)
            // A cache of recently used table sectors, emptied when it fills:
            // chains are walked in order, so the next entry is almost always
            // in the sector just read.
            if cache.count >= 256 { cache.removeAll(keepingCapacity: true) }
            cache[which] = block
        }
        let position = (index % entriesPerSector) * 4
        guard position + 4 <= block.count else { return nil }
        return Int32(bitPattern: ole2UInt32(block, position))
    }
}

struct OLE2Reader {
    private let source: RandomAccessSource
    private let sectorSize: Int
    private let miniSectorSize: Int
    private let miniStreamCutoff: Int
    private let fat: OLE2SectorTable
    private let miniFat: OLE2SectorTable
    private let directoryChain: [Int]
    private let directoryCount: Int
    /// The mini stream's container (the root entry's chain) and its readable length.
    private let rootChain: [Int]
    private let miniStreamLength: Int64
    private let directoryCache = OLE2DirectoryCache()

    // R5b: no fixed sector-chain or directory-entry count. A chain is bounded by
    // the FAT it walks (each sector visited once), the directory by the sectors
    // of its own chain; the former 100,000-sector chain cap silently cut every
    // stream above 51 MB (512-byte sectors) and returned it as whole. CLOSE-01:
    // the former 1,000-sector DIFAT walk (about 8 GB of 512-byte sectors) is
    // bounded the same way — by the header's count and each sector visited once.

    struct DirectoryEntry {
        let index: Int
        let name: String
        let type: UInt8
        let startSector: Int
        let size: Int
        let childID: Int
        let leftSiblingID: Int
        let rightSiblingID: Int
    }

    /// The bytes already in memory (an attached message, an Office part).
    init(data: Data) throws {
        try self.init(source: DataRandomAccessSource(data: data))
    }

    /// The file itself, read through a handle as the reader needs it.
    init(fileURL: URL) throws {
        try self.init(source: FileRandomAccessSource(url: fileURL))
    }

    init(source: RandomAccessSource) throws {
        let header = try source.read(at: 0, count: 512)
        guard header.count >= 512 else {
            throw MSGError.invalidFormat("File too small for OLE2")
        }
        guard header[0] == 0xD0, header[1] == 0xCF, header[2] == 0x11, header[3] == 0xE0,
              header[4] == 0xA1, header[5] == 0xB1, header[6] == 0x1A, header[7] == 0xE1 else {
            throw MSGError.invalidFormat("Not a valid OLE2 compound document (bad magic bytes)")
        }
        self.source = source

        let sectorSizePower = Int(ole2UInt16(header, 30))
        guard sectorSizePower >= 7 && sectorSizePower <= 16 else {
            throw MSGError.invalidFormat("Invalid sector size power: \(sectorSizePower)")
        }
        let sectorSize = 1 << sectorSizePower
        self.sectorSize = sectorSize
        let miniSectorSizePower = Int(ole2UInt16(header, 32))
        guard miniSectorSizePower >= 0 && miniSectorSizePower <= 16 else {
            throw MSGError.invalidFormat("Invalid mini sector size power: \(miniSectorSizePower)")
        }
        self.miniSectorSize = 1 << miniSectorSizePower
        self.miniStreamCutoff = Int(ole2UInt32(header, 56))

        let fatSectorCount = Int(ole2UInt32(header, 44))
        let firstDirSector = Int(Int32(bitPattern: ole2UInt32(header, 48)))
        let firstMiniFatSector = Int(Int32(bitPattern: ole2UInt32(header, 60)))
        let miniFatSectorCount = Int(ole2UInt32(header, 64))
        let difatFirstSector = Int(Int32(bitPattern: ole2UInt32(header, 68)))
        let difatSectorCount = Int(ole2UInt32(header, 72))
        let capacity = Int(min(Int64(Int.max / 2), source.length / Int64(sectorSize) + 1))

        var fatSectorList: [Int] = []
        for i in 0..<min(fatSectorCount, 109) {
            let sector = Int(Int32(bitPattern: ole2UInt32(header, 76 + i * 4)))
            if sector >= 0 { fatSectorList.append(sector) }
        }
        if difatSectorCount > 0 && difatFirstSector >= 0 {
            var difatSector = difatFirstSector
            var difatRead = 0
            var visited = OLE2VisitedSectors(sectorCapacity: capacity)
            let entriesPerSector = (sectorSize / 4) - 1
            while difatSector >= 0 && difatRead < difatSectorCount && visited.insert(difatSector) {
                let block = try source.read(at: (Int64(difatSector) + 1) * Int64(sectorSize), count: sectorSize)
                guard !block.isEmpty else { break }
                for i in 0..<entriesPerSector {
                    let pos = i * 4
                    guard pos + 4 <= block.count else { break }
                    let s = Int(Int32(bitPattern: ole2UInt32(block, pos)))
                    if s >= 0 { fatSectorList.append(s) }
                }
                let nextPos = entriesPerSector * 4
                difatSector = nextPos + 4 <= block.count ? Int(Int32(bitPattern: ole2UInt32(block, nextPos))) : -1
                difatRead += 1
            }
        }
        fat = OLE2SectorTable(source: source, sectorSize: sectorSize, sectors: fatSectorList)

        directoryChain = try Self.chain(start: firstDirSector, table: fat, capacity: capacity)
        directoryCount = directoryChain.count * (sectorSize / 128)

        if firstMiniFatSector >= 0 && miniFatSectorCount > 0 {
            miniFat = OLE2SectorTable(source: source, sectorSize: sectorSize,
                                      sectors: try Self.chain(start: firstMiniFatSector, table: fat, capacity: capacity))
        } else {
            miniFat = OLE2SectorTable(source: source, sectorSize: sectorSize, sectors: [])
        }

        // The root entry (directory entry 0) holds the mini stream.
        var rootChain: [Int] = []
        var miniLength: Int64 = 0
        if let firstSector = directoryChain.first {
            let raw = try source.read(at: (Int64(firstSector) + 1) * Int64(sectorSize), count: 128)
            if raw.count == 128, let root = Self.parseDirectoryEntry(raw, index: 0, sectorSize: sectorSize), root.size > 0 {
                rootChain = try Self.chain(start: root.startSector, table: fat, capacity: capacity)
                var readable: Int64 = 0
                for sector in rootChain {
                    let offset = (Int64(sector) + 1) * Int64(sectorSize)
                    guard offset < source.length else { break }
                    readable += min(Int64(sectorSize), source.length - offset)
                }
                miniLength = min(Int64(root.size), readable)
            }
        }
        self.rootChain = rootChain
        self.miniStreamLength = miniLength
    }

    /// The number of sectors the file can address — the bound on every chain.
    private var sectorCapacity: Int {
        Int(min(Int64(Int.max / 2), source.length / Int64(sectorSize) + 1))
    }

    // MARK: - Chains

    /// Why a chain walk stopped.
    enum ChainEnd: Equatable {
        case endOfChain
        case stoppedByCaller
        case loop(sector: Int)
        case outsideTable(sector: Int)
    }

    /// Walks a chain in order, visiting each sector once: a sector seen before
    /// ends the walk (a loop), as does an entry outside the table.
    @discardableResult
    private static func walk(start: Int, table: OLE2SectorTable, capacity: Int,
                             visit: (Int) throws -> Bool) throws -> ChainEnd {
        var visited = OLE2VisitedSectors(sectorCapacity: capacity)
        var current = start
        while current >= 0 {
            guard let next = try table.entry(current) else { return .outsideTable(sector: current) }
            guard visited.insert(current) else { return .loop(sector: current) }
            guard try visit(current) else { return .stoppedByCaller }
            if next == -2 || next == -1 { return .endOfChain }   // ENDOFCHAIN or FREESECT
            current = Int(next)
        }
        return .endOfChain
    }

    private static func chain(start: Int, table: OLE2SectorTable, capacity: Int) throws -> [Int] {
        var result: [Int] = []
        try walk(start: start, table: table, capacity: capacity) { result.append($0); return true }
        return result
    }

    // MARK: - Directory

    private static func parseDirectoryEntry(_ raw: Data, index: Int, sectorSize: Int) -> DirectoryEntry? {
        guard raw.count >= 128 else { return nil }
        let rawNameLen = Int(ole2UInt16(raw, 64))
        let nameLen = (rawNameLen / 2) * 2
        let nameData = raw.subdata(in: 0..<min(nameLen, 64))
        let name = String(data: nameData, encoding: .utf16LittleEndian)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""
        // MS-CFB §2.6.1: left sibling at 68, right sibling at 72, child at 76
        // (checked against a real Word file: Root Entry = -1, -1, 3). The
        // three were read in the wrong order before §13.8 step 3, so no
        // storage's children could be walked — a real .msg came out empty.
        let type = raw[66]
        let leftID = Int(Int32(bitPattern: ole2UInt32(raw, 68)))
        let rightID = Int(Int32(bitPattern: ole2UInt32(raw, 72)))
        let childID = Int(Int32(bitPattern: ole2UInt32(raw, 76)))
        let startSector = Int(Int32(bitPattern: ole2UInt32(raw, 116)))
        let size: Int
        if sectorSize == 4096 {
            // clamping: a crafted 64-bit size with the high bit set
            // would trap `Int(UInt64)`.
            size = Int(clamping: ole2UInt64(raw, 120))
        } else {
            size = Int(ole2UInt32(raw, 120))
        }
        // Every entry keeps its position: sibling and child ids are
        // absolute, so an unallocated entry (type 0) is kept as a hole.
        return DirectoryEntry(index: index, name: type > 0 ? name : "", type: type,
                              startSector: startSector, size: max(0, size),
                              childID: type > 0 ? childID : -1, leftSiblingID: type > 0 ? leftID : -1,
                              rightSiblingID: type > 0 ? rightID : -1)
    }

    /// Directory entry `index`, read when first asked for; nil outside the
    /// directory or the file.
    private func directory(_ index: Int) -> DirectoryEntry? {
        guard index >= 0, index < directoryCount else { return nil }
        if let cached = directoryCache.entries[index] { return cached }
        let perSector = sectorSize / 128
        let sector = directoryChain[index / perSector]
        let offset = (Int64(sector) + 1) * Int64(sectorSize) + Int64((index % perSector) * 128)
        guard let raw = try? source.read(at: offset, count: 128),
              let entry = Self.parseDirectoryEntry(raw, index: index, sectorSize: sectorSize) else { return nil }
        if directoryCache.entries.count >= 65_536 { directoryCache.entries.removeAll(keepingCapacity: true) }
        directoryCache.entries[index] = entry
        return entry
    }

    // MARK: - Directory Tree Traversal

    private func childrenOf(directoryIndex: Int) -> [DirectoryEntry] {
        guard let parent = directory(directoryIndex) else { return [] }
        guard parent.childID >= 0 && parent.childID < directoryCount else { return [] }
        var result: [DirectoryEntry] = []
        var visited = Set<Int>()
        collectTree(parent.childID, into: &result, visited: &visited)
        return result
    }

    private func collectTree(_ nodeIndex: Int, into result: inout [DirectoryEntry], visited: inout Set<Int>) {
        // Iterative in-order traversal with an explicit stack. A recursive walk
        // could overflow the stack on a degenerate/hostile directory chain
        // (e.g. 500k right-siblings). `visited` guards cycles and bounds the
        // output by the directory itself.
        var stack: [DirectoryEntry] = []
        var current = nodeIndex
        while true {
            while current >= 0 && current < directoryCount && visited.insert(current).inserted,
                  let entry = directory(current) {
                stack.append(entry)
                current = entry.leftSiblingID
            }
            guard let node = stack.popLast() else { break }
            result.append(node)
            current = node.rightSiblingID
        }
    }

    // MARK: - Read MAPI Properties

    /// The properties of one message storage. The fixed-property stream's
    /// header is 32 bytes at the root, 24 in an embedded message, 8 in an
    /// attachment or recipient (MS-OXMSG §2.4.1) — reading with the wrong
    /// header misaligns every entry, so the caller says which it is.
    ///
    /// CLOSE-01: with `deferStreamsAbove`, a string or binary property stream
    /// larger than that many bytes is not read; it is listed in `deferred` so
    /// the caller can stream it (`streamEntry`).
    func readMAPIProperties(storage: Int = 0, propertiesHeader: Int = 32, deferStreamsAbove: Int? = nil) throws -> MAPIPropertySet {
        var props = MAPIPropertySet()

        for entry in childrenOf(directoryIndex: storage) {
            if entry.name.hasPrefix("__substg1.0_"), entry.type == 2 {
                parseSubstgEntry(entry, into: &props, deferStreamsAbove: deferStreamsAbove)
            } else if entry.name.lowercased() == "__properties_version1.0" {
                let streamData = readEntryData(entry)
                Self.parseFixedProperties(from: streamData, into: &props, header: propertiesHeader)
            }
        }
        return props
    }

    /// One attachment storage: its metadata and, for an embedded message
    /// (PR_ATTACH_METHOD 5, `__substg1.0_3701000D` storage), where it lives.
    struct AttachmentRecord {
        var metadata: AttachmentMetadata
        var embeddedMessageStorage: Int?
        /// CLOSE-01: the attachment's data stream when it was too large to read
        /// in place (`deferStreamsAbove`); `metadata` then carries its size only.
        var deferredData: DirectoryEntry? = nil
    }

    private func parseSubstgEntry(_ entry: DirectoryEntry, into props: inout MAPIPropertySet, deferStreamsAbove: Int? = nil) {
        let tag = String(entry.name.dropFirst(12).prefix(8))
        guard let tagInt = UInt32(tag, radix: 16) else { return }
        let propID = UInt16(tagInt >> 16)
        let propType = UInt16(tagInt & 0xFFFF)
        if let limit = deferStreamsAbove, entry.size > limit, [0x001F, 0x001E, 0x0102].contains(propType) {
            props.deferred[propID] = MAPIPropertySet.DeferredStream(entry: entry, propType: propType)
            return
        }
        let streamData = readEntryData(entry)

        switch propType {
        case 0x001F: // Unicode string
            if let str = String(data: streamData, encoding: .utf16LittleEndian) ?? String(data: streamData, encoding: .utf8) {
                props.strings[propID] = str
            }
        case 0x001E: // ANSI string
            if let str = String(data: streamData, encoding: .windowsCP1252) ?? String(data: streamData, encoding: .ascii) ?? String(data: streamData, encoding: .utf8) {
                props.strings[propID] = str
            }
        case 0x0102: // Binary
            props.binaries[propID] = streamData
        default:
            break
        }
    }

    // MARK: - Attachment Reading (Properly Scoped)

    func readAttachments() throws -> [AttachmentMetadata] {
        try readAttachments(storage: 0).map(\.metadata)
    }

    func readAttachments(storage: Int, deferStreamsAbove: Int? = nil) throws -> [AttachmentRecord] {
        var attachments: [AttachmentRecord] = []
        let rootChildren = childrenOf(directoryIndex: storage)

        for entry in rootChildren where entry.name.hasPrefix("__attach_version1.0") && entry.type == 1 {
            let attachChildren = childrenOf(directoryIndex: entry.index)
            var attachProps = MAPIPropertySet()
            var embeddedStorage: Int?

            for child in attachChildren {
                if child.name.hasPrefix("__substg1.0_3701000D"), child.type == 1 {
                    embeddedStorage = child.index
                } else if child.name.hasPrefix("__substg1.0_"), child.type == 2 {
                    parseSubstgEntry(child, into: &attachProps, deferStreamsAbove: deferStreamsAbove)
                } else if child.name.lowercased() == "__properties_version1.0" {
                    let streamData = readEntryData(child)
                    Self.parseFixedProperties(from: streamData, into: &attachProps, header: 8)
                }
            }

            let filename = attachProps.strings[MAPIPropertyID.attachLongFilename.rawValue]
                ?? attachProps.strings[MAPIPropertyID.attachFilename.rawValue]
                ?? attachProps.strings[MAPIPropertyID.displayName.rawValue]
                ?? "attachment"
            let mimeType = attachProps.strings[MAPIPropertyID.attachMimeTag.rawValue]
                ?? "application/octet-stream"
            let contentID = attachProps.strings[MAPIPropertyID.attachContentId.rawValue]
            let attachData = attachProps.binaries[MAPIPropertyID.attachDataBinary.rawValue]
            let deferredData = attachProps.deferred[MAPIPropertyID.attachDataBinary.rawValue]?.entry
            let isInline = contentID != nil ||
                (attachProps.ints[MAPIPropertyID.attachFlags.rawValue].map { $0 & 0x04 != 0 } ?? false)

            let metadata = AttachmentMetadata(
                filename: filename.trimmingCharacters(in: .controlCharacters),
                mimeType: mimeType.trimmingCharacters(in: .controlCharacters),
                size: attachData?.count ?? deferredData?.size ?? 0,
                isInline: isInline,
                contentID: contentID,
                base64: attachData?.base64EncodedString(),
                fileURL: nil
            )
            // An embedded message (method 5) is expanded by the caller, depth-limited.
            let method = attachProps.ints[MAPIPropertyID.attachMethod.rawValue]
            let hasData = attachData != nil || deferredData != nil
            attachments.append(AttachmentRecord(metadata: metadata,
                                                embeddedMessageStorage: (method == 5 || !hasData) ? embeddedStorage : nil,
                                                deferredData: deferredData))
        }
        return attachments
    }

    // MARK: - Named streams (TYPE-01: legacy Office readers share this container reader)

    /// Every stream and storage name in the compound file, root excluded.
    var streamNames: [String] {
        directoryCount > 1 ? (1..<directoryCount).compactMap { directory($0)?.name } : []
    }

    /// The bytes of the first stream whose name matches (case-insensitive), or nil.
    func streamData(named name: String) -> Data? {
        let wanted = name.lowercased()
        guard directoryCount > 1 else { return nil }
        for index in 1..<directoryCount {
            if let entry = directory(index), entry.type == 2, entry.name.lowercased() == wanted { return readEntryData(entry) }
        }
        return nil
    }

    // MARK: - Storage paths (directive 2026-11-07 §6: Publisher, Visio and Project readers)

    /// One child of a storage, as the other-business-format readers see it.
    struct StorageEntry {
        let name: String
        let isStorage: Bool
        let size: Int
        fileprivate let index: Int
    }

    /// The children of the storage at `path` (the root for `[]`), names matched
    /// case-insensitively; nil when a component is missing or is a stream.
    func entries(at path: [String]) -> [StorageEntry]? {
        guard let storage = storageIndex(at: path) else { return nil }
        return childrenOf(directoryIndex: storage).map { StorageEntry(name: $0.name, isStorage: $0.type == 1, size: $0.size, index: $0.index) }
    }

    /// The bytes of the stream at `path` — `["Quill", "QuillSub", "CONTENTS"]`
    /// for Quill/QuillSub/CONTENTS — or nil when it is not there. Unlike
    /// `streamData(named:)` this never confuses two streams of the same name
    /// in different storages (Publisher has a root `Contents` and a Quill `CONTENTS`).
    func streamData(at path: [String]) -> Data? {
        guard let last = path.last, let storage = storageIndex(at: Array(path.dropLast())) else { return nil }
        let wanted = last.lowercased()
        guard let entry = childrenOf(directoryIndex: storage).first(where: { $0.type == 2 && $0.name.lowercased() == wanted }) else { return nil }
        return readEntryData(entry)
    }

    /// The bytes of a stream found through `entries(at:)`; nil for a storage.
    func data(of entry: StorageEntry) -> Data? {
        guard let found = directory(entry.index), found.type == 2 else { return nil }
        return readEntryData(found)
    }

    private func storageIndex(at path: [String]) -> Int? {
        var current = 0
        for component in path {
            let wanted = component.lowercased()
            guard let next = childrenOf(directoryIndex: current).first(where: { $0.type == 1 && $0.name.lowercased() == wanted }) else { return nil }
            current = next.index
        }
        return current
    }

    // MARK: - Stream bytes

    private func isMini(_ entry: DirectoryEntry) -> Bool {
        entry.size < miniStreamCutoff && entry.type != 5
    }

    /// The bytes of mini sector `sector`, short at the end of the mini stream;
    /// empty outside it.
    private func readMiniSector(_ sector: Int) throws -> Data {
        let offset = Int64(sector) * Int64(miniSectorSize)
        guard sector >= 0, offset < miniStreamLength else { return Data() }
        let index = Int(offset / Int64(sectorSize))
        guard index < rootChain.count else { return Data() }
        let fileOffset = (Int64(rootChain[index]) + 1) * Int64(sectorSize) + offset % Int64(sectorSize)
        let count = Int(min(Int64(miniSectorSize), miniStreamLength - offset))
        return try source.read(at: fileOffset, count: count)
    }

    /// A stream's bytes, read leniently, as the in-memory readers always did:
    /// the chain is followed until it ends, loops or leaves the file, and the
    /// result is cut at the declared size.
    private func readEntryData(_ entry: DirectoryEntry) -> Data {
        var result = Data()
        let wanted = max(0, entry.size)
        guard wanted > 0 else { return result }
        if isMini(entry) {
            _ = try? Self.walk(start: entry.startSector, table: miniFat, capacity: Int(miniStreamLength / Int64(max(1, miniSectorSize))) + 1) { sector in
                let bytes = try readMiniSector(sector)
                guard !bytes.isEmpty else { return false }
                result.append(bytes)
                return result.count < wanted
            }
        } else {
            _ = try? Self.walk(start: entry.startSector, table: fat, capacity: sectorCapacity) { sector in
                let offset = (Int64(sector) + 1) * Int64(sectorSize)
                guard offset >= 0, offset < source.length else { return false }
                result.append(try source.read(at: offset, count: Int(min(Int64(sectorSize), Int64(wanted - result.count)))))
                return result.count < wanted
            }
        }
        return result.count > wanted ? Data(result.prefix(wanted)) : result
    }

    /// CLOSE-01: a stream's bytes handed over in slices of at most `sliceBytes`
    /// (contiguous sectors are read together), strictly: a chain that loops,
    /// leaves the file or the table, or ends before the declared size is
    /// refused with that reason. Cancellation is checked between slices.
    /// Returns the number of bytes delivered (the declared size).
    @discardableResult
    func streamEntry(_ entry: DirectoryEntry, sliceBytes: Int = 1 << 20, _ onSlice: (Data) throws -> Void) throws -> Int64 {
        let size = Int64(max(0, entry.size))
        var delivered: Int64 = 0
        guard size > 0 else { return 0 }
        let slice = max(sectorSize, sliceBytes)
        let label = entry.name.isEmpty ? "stream \(entry.index)" : entry.name
        if isMini(entry) {
            var buffer = Data()
            let end = try Self.walk(start: entry.startSector, table: miniFat, capacity: Int(miniStreamLength / Int64(max(1, miniSectorSize))) + 1) { sector in
                let want = Int(min(Int64(miniSectorSize), size - delivered - Int64(buffer.count)))
                let bytes = try readMiniSector(sector)
                guard bytes.count >= want else {
                    throw MSGError.invalidFormat("\(label): mini sector \(sector) lies outside the mini stream")
                }
                buffer.append(bytes.prefix(want))
                if buffer.count >= slice {
                    try Task.checkCancellation()
                    delivered += Int64(buffer.count)
                    try onSlice(buffer)
                    buffer = Data()
                }
                return delivered + Int64(buffer.count) < size
            }
            if !buffer.isEmpty {
                try Task.checkCancellation()
                delivered += Int64(buffer.count)
                try onSlice(buffer)
            }
            guard delivered == size else { throw Self.shortChain(label, end: end, delivered: delivered, size: size) }
            return delivered
        }

        // Runs of contiguous sectors become one read.
        var runStart: Int64 = -1
        var runLength: Int64 = 0
        func flush() throws {
            guard runLength > 0 else { return }
            try Task.checkCancellation()
            let bytes = try source.read(at: runStart, count: Int(runLength))
            guard Int64(bytes.count) == runLength else {
                throw MSGError.invalidFormat("\(label): the file ends inside the stream, after \(delivered + Int64(bytes.count)) of \(size) bytes")
            }
            delivered += runLength
            runLength = 0
            try onSlice(bytes)
        }
        let end = try Self.walk(start: entry.startSector, table: fat, capacity: sectorCapacity) { sector in
            let offset = (Int64(sector) + 1) * Int64(sectorSize)
            let want = min(Int64(sectorSize), size - delivered - runLength)
            guard offset + want <= source.length else {
                throw MSGError.invalidFormat("\(label): sector \(sector) lies outside the file (\(source.length) bytes)")
            }
            if runLength > 0, runStart + runLength == offset, runLength + want <= Int64(slice) {
                runLength += want
            } else {
                try flush()
                runStart = offset
                runLength = want
            }
            return delivered + runLength < size
        }
        try flush()
        guard delivered == size else { throw Self.shortChain(label, end: end, delivered: delivered, size: size) }
        return delivered
    }

    private static func shortChain(_ label: String, end: ChainEnd, delivered: Int64, size: Int64) -> MSGError {
        switch end {
        case .loop(let sector):
            return .invalidFormat("\(label): its sector chain loops back to sector \(sector) after \(delivered) of \(size) bytes")
        case .outsideTable(let sector):
            return .invalidFormat("\(label): sector \(sector) is outside the allocation table, after \(delivered) of \(size) bytes")
        case .endOfChain, .stoppedByCaller:
            return .invalidFormat("\(label): its sector chain ends after \(delivered) of \(size) bytes")
        }
    }

    // MARK: - Fixed properties

    private static func parseFixedProperties(from data: Data, into props: inout MAPIPropertySet, header: Int) {
        var offset = min(header, data.count)
        while offset + 16 <= data.count {
            let propType = ole2UInt16(data, offset)
            let propID = ole2UInt16(data, offset + 2)
            switch propType {
            case 0x0040: // PT_SYSTIME
                let fileTime = ole2UInt64(data, offset + 8)
                if fileTime > 0 {
                    let seconds = Double(fileTime) / 10_000_000.0 - 11_644_473_600.0
                    props.dates[propID] = Date(timeIntervalSince1970: seconds)
                }
            case 0x0003: // PT_LONG
                let value = ole2UInt32(data, offset + 8)
                props.ints[propID] = value
            case 0x000B: // PT_BOOLEAN
                let value = ole2UInt16(data, offset + 8)
                props.ints[propID] = UInt32(value)
            default:
                break
            }
            offset += 16
        }
    }
}

/// Directory entries read so far (a cache; emptied when it grows large).
final class OLE2DirectoryCache {
    var entries: [Int: OLE2Reader.DirectoryEntry] = [:]
}

// MARK: - Binary Read Helpers (0-based `Data`)

private func ole2UInt16(_ data: Data, _ offset: Int) -> UInt16 {
    let i = data.startIndex + offset
    guard offset >= 0, offset + 2 <= data.count else { return 0 }
    return UInt16(data[i]) | (UInt16(data[i + 1]) << 8)
}

private func ole2UInt32(_ data: Data, _ offset: Int) -> UInt32 {
    let i = data.startIndex + offset
    guard offset >= 0, offset + 4 <= data.count else { return 0 }
    return UInt32(data[i]) | (UInt32(data[i + 1]) << 8) | (UInt32(data[i + 2]) << 16) | (UInt32(data[i + 3]) << 24)
}

private func ole2UInt64(_ data: Data, _ offset: Int) -> UInt64 {
    guard offset >= 0, offset + 8 <= data.count else { return 0 }
    return UInt64(ole2UInt32(data, offset)) | (UInt64(ole2UInt32(data, offset + 4)) << 32)
}
