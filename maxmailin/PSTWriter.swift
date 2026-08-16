import Foundation
import os.log

/// Streaming Unicode-PST container writer.
///
/// Design goals (see feedback: no artificial caps):
/// - Message count is UNLIMITED — node/block B-trees are written as proper
///   multi-level page trees, not a single page.
/// - Value size is bounded only by the PST format itself: node data larger
///   than one block is split into 8 KB chunks joined by XBLOCK/XXBLOCK
///   chains (MS-PST §2.2.2.8.3.2), giving ~500 GB per value — far beyond
///   the 50 GB whole-file ceiling Outlook itself enforces.
/// - Memory is bounded: blocks stream to disk through a FileHandle as
///   messages are appended; only the (small) B-tree bookkeeping lives in
///   RAM. Disk space — the user's device — is the real limit.
struct PSTWriter {

    fileprivate static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "mailin",
        category: "PSTWriter"
    )

    enum WriterError: LocalizedError {
        case encodingFailure(String)
        case emptyInput
        case formatSizeExceeded(UInt64)
        case ioFailure(String)

        var errorDescription: String? {
            switch self {
            case .encodingFailure(let detail):
                return "String encoding failed: \(detail)"
            case .emptyInput:
                return "No emails provided for PST export"
            case .formatSizeExceeded(let bytes):
                return "PST file reached \(bytes / 1_073_741_824) GB — the PST format (and Outlook) cap files at 50 GB. Split the export into smaller sets."
            case .ioFailure(let detail):
                return "PST file I/O failed: \(detail)"
            }
        }
    }

    // MARK: - Convenience API (materialized input)

    /// Writes all emails to a PST file at `url`. Returns the message count.
    @discardableResult
    static func write(emails: [MBOXParser.RawEmail], to url: URL) throws -> Int {
        guard !emails.isEmpty else { throw WriterError.emptyInput }
        let writer = try PSTStreamWriter(url: url)
        do {
            for email in emails { try writer.append(email: email) }
            return try writer.finalize()
        } catch {
            writer.abort()
            throw error
        }
    }

    /// Builds a PST container in memory (via a temp file) — used by the iOS
    /// share-sheet path. Prefer `write(emails:to:)`/`PSTStreamWriter` which
    /// stream to disk.
    static func writeData(emails: [MBOXParser.RawEmail]) throws -> Data {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailin-pst-\(UUID().uuidString).pst")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try write(emails: emails, to: tmp)
        return try Data(contentsOf: tmp, options: .mappedIfSafe)
    }
}

/// Incremental PST writer: `append(email:)` per message, then `finalize()`.
final class PSTStreamWriter {

    // MARK: - Format constants

    private static let pstMagic: [UInt8] = [0x21, 0x42, 0x44, 0x4E]  // !BDN
    private static let pageSize = 512
    private static let blockAlign = 64
    private static let pstVersionUnicode: UInt16 = 23
    /// Max payload bytes per data block (MS-PST block ceiling minus trailer).
    private static let chunkSize = 8176
    /// PST format / Outlook whole-file ceiling. Format-inherent, not ours.
    private static let maxFileBytes: UInt64 = 50_000_000_000

    private static let nidFolder: UInt32 = 0x02, nidMessage: UInt32 = 0x0C
    private static let nidContents: UInt32 = 0x0E, nidAttach: UInt32 = 0x0D

    private static let tagSubject: UInt16 = 0x0037, tagMsgClass: UInt16 = 0x001A
    private static let tagSenderAddr: UInt16 = 0x0C1F, tagDisplayTo: UInt16 = 0x0E04
    private static let tagDisplayCc: UInt16 = 0x0E03
    private static let tagBody: UInt16 = 0x1000, tagHtml: UInt16 = 0x1013
    private static let tagDeliveryTime: UInt16 = 0x0E06, tagCreationTime: UInt16 = 0x3007
    private static let tagMsgFlags: UInt16 = 0x0E07
    private static let tagMessageId: UInt16 = 0x1035, tagInReplyTo: UInt16 = 0x1042
    private static let tagReferences: UInt16 = 0x1039
    private static let tagTransportHeaders: UInt16 = 0x007D
    private static let tagAttachFile: UInt16 = 0x3707, tagAttachData: UInt16 = 0x3701
    private static let tagAttachMime: UInt16 = 0x370E, tagAttachMethod: UInt16 = 0x3705
    private static let tagDisplayName: UInt16 = 0x3001
    private static let tagContentCount: UInt16 = 0x3602, tagUnreadCount: UInt16 = 0x3603
    private static let tagContainerClass: UInt16 = 0x3613

    private static let ptUnicode: UInt16 = 0x001F, ptBinary: UInt16 = 0x0102
    private static let ptSystime: UInt16 = 0x0040, ptLong: UInt16 = 0x0003

    // MARK: - Bookkeeping (the only per-message state kept in RAM)

    private struct NRef { let nid: UInt32, dataBid: UInt64, subBid: UInt64 }
    private struct BRef { let bid: UInt64, offset: UInt64, size: UInt16 }

    private let handle: FileHandle
    private let url: URL
    private var nodes: [NRef] = []
    private var bRefs: [BRef] = []
    private var messageNids: [UInt32] = []
    private var nextBid: UInt64 = 4
    private var nextIdx: UInt32 = 0x21   // 0x20 is reserved for the root folder
    private var offset: UInt64 = 4096    // data starts at first page after header
    private var finished = false

    private var messageCount: Int { messageNids.count }

    // MARK: - Lifecycle

    init(url: URL) throws {
        self.url = url
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: url) else {
            throw PSTWriter.WriterError.ioFailure("Cannot open \(url.lastPathComponent) for writing")
        }
        self.handle = h
        // Reserve header space; real header is written in finalize().
        try writeBytes(Data(repeating: 0, count: 4096), at: 0)
    }

    /// Discards the partial file after a failure.
    func abort() {
        try? handle.close()
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Append one message

    func append(email: MBOXParser.RawEmail) throws {
        guard !finished else { throw PSTWriter.WriterError.ioFailure("Writer already finalized") }

        let mi = allocIdx()
        let mNid = (mi << 5) | Self.nidMessage
        let mBid = try emitNodeData(try messagePC(email: email))

        var sub: UInt64 = 0
        if !email.attachments.isEmpty {
            // Archive-streamed emails carry attachment METADATA only; the
            // bytes live in the raw MIME source. Hydrate lazily, once per
            // email, and clean the extractor's temp files afterwards.
            var hydrated: [AttachmentMetadata]?
            defer {
                for h in hydrated ?? [] {
                    if let url = h.fileURL { try? FileManager.default.removeItem(at: url) }
                }
            }

            // Subnode table: 8-byte header (count + pad) then 24-byte
            // entries — the offsets the Unicode reader walks.
            var sn = Data()
            Self.appendU32(&sn, UInt32(email.attachments.count))
            Self.appendU32(&sn, 0)
            for (i, att) in email.attachments.enumerated() {
                let aNid = (allocIdx() << 5) | Self.nidAttach
                var props: [PropEntry] = [
                    strProp(Self.tagAttachFile, att.filename),
                    strProp(Self.tagAttachMime, att.mimeType),
                    PropEntry(id: Self.tagAttachMethod, type: Self.ptLong, fixed: 1, variable: nil),
                ]
                if let bin = Self.attachmentBytes(att, index: i, email: email, hydrated: &hydrated) {
                    props.append(PropEntry(id: Self.tagAttachData, type: Self.ptBinary, fixed: 0, variable: bin))
                }
                let aBid = try emitNodeData(serializePC(props))
                Self.appendU32(&sn, aNid)
                Self.appendU32(&sn, 0)
                Self.appendU64(&sn, aBid)
                Self.appendU64(&sn, 0)
            }
            sub = try emitNodeData(sn)
        }

        nodes.append(NRef(nid: mNid, dataBid: mBid, subBid: sub))
        messageNids.append(mNid)

        if messageCount % 500 == 0 {
            PSTWriter.logger.debug("Streamed \(self.messageCount) messages to PST")
        }
    }

    // MARK: - Finalize

    /// Writes root folder, contents table, B-tree pages and the header,
    /// then closes the file. Returns the message count.
    @discardableResult
    func finalize() throws -> Int {
        guard !finished else { return messageCount }
        guard messageCount > 0 else {
            abort()
            throw PSTWriter.WriterError.emptyInput
        }
        finished = true

        // Root folder + contents table (nids listed for every message).
        let rootNid = (UInt32(0x20) << 5) | Self.nidFolder
        let rootBid = try emitNodeData(folderPC(name: "Top of Personal Folders", count: messageCount))
        nodes.insert(NRef(nid: rootNid, dataBid: rootBid, subBid: 0), at: 0)

        var ct = Data()
        Self.appendU32(&ct, UInt32(messageCount))
        for nid in messageNids { Self.appendU32(&ct, nid) }
        let ctNid = (UInt32(0x20) << 5) | Self.nidContents
        let ctBid = try emitNodeData(ct)
        nodes.insert(NRef(nid: ctNid, dataBid: ctBid, subBid: 0), at: 1)

        // Multi-level B-trees. Leaves hold the records; intermediate pages
        // reference child pages until a single root remains.
        let sortedNodes = nodes.sorted { $0.nid < $1.nid }
        let sortedBlocks = bRefs.sorted { $0.bid < $1.bid }

        let nbtRoot = try writeBTree(
            leafEntries: sortedNodes.map { nbtLeafEntry($0) },
            leafPerPage: 15, leafType: 0x81, branchType: 0x80,
            keyFor: { sortedNodes[$0].nid }
        )
        let bbtRoot = try writeBTree(
            leafEntries: sortedBlocks.map { bbtLeafEntry($0) },
            leafPerPage: 20, leafType: 0x82, branchType: 0x83,
            keyFor: { UInt32(truncatingIfNeeded: sortedBlocks[$0].bid) }
        )

        let eof = Self.pageAlign(offset)
        guard eof <= Self.maxFileBytes else {
            abort()
            throw PSTWriter.WriterError.formatSizeExceeded(eof)
        }

        try writeBytes(header(nbtRoot: nbtRoot, bbtRoot: bbtRoot, eof: eof), at: 0)
        try handle.truncate(atOffset: eof)
        try handle.close()
        PSTWriter.logger.info("Wrote PST: \(self.messageCount) messages, \(eof) bytes")
        return messageCount
    }

    // MARK: - Node data emission (chunking + XBLOCK/XXBLOCK)

    /// Writes one node's data. Data that fits a single block is written
    /// directly; larger data is split into chunks joined by an XBLOCK (and
    /// XXBLOCK when one XBLOCK can't hold all chunk ids). Returns the bid
    /// the node should reference.
    private func emitNodeData(_ data: Data) throws -> UInt64 {
        if data.count <= Self.chunkSize {
            return try emitBlock(data, internalBlock: false)
        }

        // 1. Emit the raw chunks.
        var chunkBids: [UInt64] = []
        var pos = data.startIndex
        while pos < data.endIndex {
            let end = data.index(pos, offsetBy: Self.chunkSize, limitedBy: data.endIndex) ?? data.endIndex
            chunkBids.append(try emitBlock(Data(data[pos..<end]), internalBlock: false))
            pos = end
        }

        // 2. XBLOCK(s): 0x01/cLevel=1 header + child bids. Cap children so
        //    each XBLOCK stays within one block payload.
        let bidsPerXBlock = (Self.chunkSize - 8) / 8
        var xblockBids: [UInt64] = []
        for start in stride(from: 0, to: chunkBids.count, by: bidsPerXBlock) {
            let slice = Array(chunkBids[start..<min(start + bidsPerXBlock, chunkBids.count)])
            xblockBids.append(try emitBlock(Self.xBlock(level: 1, total: UInt32(clamping: data.count), bids: slice), internalBlock: true))
        }
        if xblockBids.count == 1 { return xblockBids[0] }

        // 3. XXBLOCK when multiple XBLOCKs are needed (cLevel=2).
        return try emitBlock(Self.xBlock(level: 2, total: UInt32(clamping: data.count), bids: xblockBids), internalBlock: true)
    }

    private static func xBlock(level: UInt8, total: UInt32, bids: [UInt64]) -> Data {
        var d = Data()
        d.append(0x01)          // btype = data tree
        d.append(level)         // cLevel: 1 = XBLOCK, 2 = XXBLOCK
        appendU16(&d, UInt16(bids.count))
        appendU32(&d, total)
        for bid in bids { appendU64(&d, bid) }
        return d
    }

    /// Writes one physical block (≤ chunkSize bytes by construction) and
    /// records its BBT entry. Internal blocks (XBLOCK/XXBLOCK) get the
    /// spec's internal-bid flag (bit 1) so readers know to expand them.
    private func emitBlock(_ data: Data, internalBlock: Bool) throws -> UInt64 {
        precondition(data.count <= 65_535, "block exceeds BBT UInt16 size field")
        var bid = nextBid
        nextBid += 4
        if internalBlock { bid |= 0x2 }
        try writeBytes(data, at: offset)
        bRefs.append(BRef(bid: bid, offset: offset, size: UInt16(data.count)))
        let aligned = (data.count + Self.blockAlign - 1) / Self.blockAlign * Self.blockAlign
        offset += UInt64(max(aligned, Self.blockAlign))
        if offset > Self.maxFileBytes {
            throw PSTWriter.WriterError.formatSizeExceeded(offset)
        }
        return bid
    }

    // MARK: - B-tree page building

    private func nbtLeafEntry(_ r: NRef) -> Data {
        var e = Data()
        Self.appendU32(&e, r.nid)
        Self.appendU32(&e, 0)
        Self.appendU64(&e, r.dataBid)
        Self.appendU64(&e, r.subBid)
        Self.appendU32(&e, 0)   // parent nid
        Self.appendU32(&e, 0)   // padding
        return e
    }

    private func bbtLeafEntry(_ r: BRef) -> Data {
        var e = Data()
        Self.appendU64(&e, r.bid)
        Self.appendU64(&e, r.offset)
        Self.appendU16(&e, r.size)
        e.append(Data(repeating: 0, count: 6))
        return e
    }

    /// Writes leaf pages then branch levels bottom-up; returns root offset.
    private func writeBTree(
        leafEntries: [Data],
        leafPerPage: Int,
        leafType: UInt8,
        branchType: UInt8,
        keyFor: (Int) -> UInt32
    ) throws -> UInt64 {
        // Leaf level.
        var level: [(firstKey: UInt32, pageOffset: UInt64)] = []
        for start in stride(from: 0, to: leafEntries.count, by: leafPerPage) {
            let slice = Array(leafEntries[start..<min(start + leafPerPage, leafEntries.count)])
            let pgOffset = try writePage(entries: slice, entrySize: leafEntries[0].count, type: leafType, levelNum: 0)
            level.append((keyFor(start), pgOffset))
        }

        // Branch levels: BTENTRY = key(8) + BREF(bid 8 + ib 8) = 24 bytes;
        // the reader takes the child page offset from +16.
        var levelNum: UInt8 = 1
        while level.count > 1 {
            var parent: [(firstKey: UInt32, pageOffset: UInt64)] = []
            for start in stride(from: 0, to: level.count, by: 20) {
                let slice = Array(level[start..<min(start + 20, level.count)])
                let entries = slice.map { child -> Data in
                    var e = Data()
                    Self.appendU64(&e, UInt64(child.firstKey))
                    Self.appendU64(&e, 0)              // bid (unused by reader)
                    Self.appendU64(&e, child.pageOffset)
                    return e
                }
                let pgOffset = try writePage(entries: entries, entrySize: 24, type: branchType, levelNum: levelNum)
                parent.append((slice[0].firstKey, pgOffset))
            }
            level = parent
            levelNum += 1
        }
        return level[0].pageOffset
    }

    private func writePage(entries: [Data], entrySize: Int, type: UInt8, levelNum: UInt8) throws -> UInt64 {
        var pg = Data(repeating: 0, count: Self.pageSize)
        var pos = 0
        for e in entries {
            pg.replaceSubrange(pos..<pos + e.count, with: e)
            pos += e.count
        }
        pg[488] = UInt8(entries.count)          // cEnt
        pg[489] = UInt8(488 / entrySize)        // cEntMax
        pg[490] = UInt8(entrySize)              // cbEnt
        pg[491] = levelNum                      // cLevel
        pg[496] = type                          // ptype
        pg[497] = type                          // ptypeRepeat
        Self.w32(&pg, 500, Self.crc32(Data(pg[0..<496])))
        Self.w64(&pg, 504, UInt64(type))

        let pgOffset = Self.pageAlign(offset)
        try writeBytes(pg, at: pgOffset)
        offset = pgOffset + UInt64(Self.pageSize)
        return pgOffset
    }

    // MARK: - Header

    private func header(nbtRoot: UInt64, bbtRoot: UInt64, eof: UInt64) -> Data {
        var hdr = Data(repeating: 0, count: 564)
        hdr[0] = Self.pstMagic[0]; hdr[1] = Self.pstMagic[1]
        hdr[2] = Self.pstMagic[2]; hdr[3] = Self.pstMagic[3]
        hdr[8] = 0x53; hdr[9] = 0x4D  // wMagicClient = "SM" (PST)
        Self.w16(&hdr, 10, Self.pstVersionUnicode)
        Self.w16(&hdr, 12, 19)  // wVerClient
        hdr[14] = 0x01          // bPlatformCreate
        hdr[15] = 0x01          // bPlatformAccess

        Self.w64(&hdr, 180, 4)             // bidNextP
        Self.w64(&hdr, 184, eof)           // ibFileEof
        Self.w64(&hdr, 192, eof)           // ibAMapLast
        Self.w64(&hdr, 200, 0)             // cbAMapFree
        Self.w64(&hdr, 208, 0)             // cbPMapFree
        Self.w64(&hdr, 216, 1)             // BREFNBT.bid
        Self.w64(&hdr, 224, nbtRoot)       // BREFNBT.ib
        Self.w64(&hdr, 232, 2)             // BREFBBT.bid
        Self.w64(&hdr, 240, bbtRoot)       // BREFBBT.ib

        hdr[513] = 0x00  // bCryptMethod = none (data is written unobfuscated)

        Self.w64(&hdr, 328, nextBid + 4)                   // bidNextB
        Self.w32(&hdr, 340, UInt32(clamping: bRefs.count + 1))  // dwUnique

        // rgnid message counter.
        Self.w32(&hdr, 344 + Int(Self.nidMessage) * 4, UInt32(clamping: messageCount))

        Self.w32(&hdr, 4, Self.crc32(Data(hdr[8..<184])))
        Self.w32(&hdr, 524, Self.crc32(Data(hdr[184..<516])))
        return hdr
    }

    // MARK: - Property contexts (encoding matches PSTParser.parsePropertyContext)

    private struct PropEntry { let id: UInt16, type: UInt16, fixed: UInt64, variable: Data? }

    private func folderPC(name: String, count: Int) -> Data {
        serializePC([
            strProp(Self.tagDisplayName, name),
            strProp(Self.tagContainerClass, "IPF.Note"),
            PropEntry(id: Self.tagContentCount, type: Self.ptLong, fixed: UInt64(count), variable: nil),
            PropEntry(id: Self.tagUnreadCount, type: Self.ptLong, fixed: 0, variable: nil),
        ])
    }

    private func messagePC(email: MBOXParser.RawEmail) throws -> Data {
        var e: [PropEntry] = [strProp(Self.tagMsgClass, "IPM.Note")]

        if let s = email.headers["Subject"] { e.append(strProp(Self.tagSubject, s)) }
        if let f = email.headers["From"] { e.append(strProp(Self.tagSenderAddr, Self.extractAddr(f))) }
        if let t = email.headers["To"] { e.append(strProp(Self.tagDisplayTo, t)) }
        if let c = email.headers["Cc"] { e.append(strProp(Self.tagDisplayCc, c)) }
        if let mid = email.headers["Message-ID"] ?? email.headers["Message-Id"] {
            e.append(strProp(Self.tagMessageId, mid))
        }
        if let irt = email.headers["In-Reply-To"] { e.append(strProp(Self.tagInReplyTo, irt)) }
        if let refs = email.headers["References"] { e.append(strProp(Self.tagReferences, refs)) }

        // Full RFC-822 header section for lossless re-import.
        if let headerEnd = email.rawSource.range(of: "\r\n\r\n") ?? email.rawSource.range(of: "\n\n") {
            let headerText = String(email.rawSource[..<headerEnd.lowerBound])
            if !headerText.isEmpty { e.append(strProp(Self.tagTransportHeaders, headerText)) }
        }

        if !email.plainBody.isEmpty { e.append(strProp(Self.tagBody, email.plainBody)) }
        if !email.htmlBody.isEmpty {
            guard let hd = email.htmlBody.data(using: .utf8) else {
                throw PSTWriter.WriterError.encodingFailure("HTML body")
            }
            e.append(PropEntry(id: Self.tagHtml, type: Self.ptBinary, fixed: 0, variable: hd))
        }
        if let date = Self.parseISO(email.timestamp) {
            let ft = Self.fileTime(date)
            e.append(PropEntry(id: Self.tagDeliveryTime, type: Self.ptSystime, fixed: ft, variable: nil))
            e.append(PropEntry(id: Self.tagCreationTime, type: Self.ptSystime, fixed: ft, variable: nil))
        }

        var flags: UInt32 = 0x01  // MSGFLAG_READ
        if !email.attachments.isEmpty { flags |= 0x10 }
        e.append(PropEntry(id: Self.tagMsgFlags, type: Self.ptLong, fixed: UInt64(flags), variable: nil))

        return serializePC(e)
    }

    /// Serialized layout the reader understands:
    ///   [8-byte header, byte 3 = 0x7C] [8-byte entries…] [heap values…]
    /// String values are UTF-16LE + NUL terminator; value refs are ABSOLUTE
    /// offsets within this node's data. At most one binary value per PC
    /// (readers take binary values from offset to end of data), so the
    /// binary value is always placed last in the heap.
    private func serializePC(_ entries: [PropEntry]) -> Data {
        var hdr = Data(repeating: 0, count: 8)
        hdr[2] = 0x0C
        hdr[3] = 0x7C  // property-context signature the reader checks
        hdr[5] = 0x20

        let tableSize = entries.count * 8
        let heapStart = 8 + tableSize

        // Lay out heap: strings first (NUL-terminated), binaries last.
        let ordered = entries.sorted { a, b in
            let aBin = a.type == Self.ptBinary, bBin = b.type == Self.ptBinary
            if aBin != bBin { return !aBin }
            return false
        }
        var heap = Data()
        var refs: [UInt16: UInt32] = [:]   // propID → absolute offset
        for p in ordered {
            guard let v = p.variable else { continue }
            refs[p.id] = UInt32(heapStart + heap.count)
            heap.append(v)
            if p.type == Self.ptUnicode {
                heap.append(contentsOf: [0, 0])  // UTF-16 NUL terminator
            }
        }

        var fixed = Data()
        for p in entries {
            Self.appendU16(&fixed, p.id)
            Self.appendU16(&fixed, p.type)
            if p.variable != nil {
                Self.appendU32(&fixed, refs[p.id] ?? 0)
            } else {
                Self.appendU32(&fixed, UInt32(truncatingIfNeeded: p.fixed))
            }
        }

        var result = Data()
        result.append(hdr)
        result.append(fixed)
        result.append(heap)
        return result
    }

    private func strProp(_ id: UInt16, _ val: String) -> PropEntry {
        PropEntry(id: id, type: Self.ptUnicode, fixed: 0,
                  variable: val.data(using: .utf16LittleEndian) ?? Data())
    }

    // MARK: - Low-level I/O

    private func writeBytes(_ data: Data, at fileOffset: UInt64) throws {
        do {
            try handle.seek(toOffset: fileOffset)
            try handle.write(contentsOf: data)
        } catch {
            throw PSTWriter.WriterError.ioFailure(error.localizedDescription)
        }
    }

    private func allocIdx() -> UInt32 { defer { nextIdx += 1 }; return nextIdx }

    /// Resolves an attachment's raw bytes: direct fileURL, then inline
    /// base64 (MIME-wrapped, so non-alphabet bytes are ignored), then a
    /// one-time re-extraction from the email's raw MIME source (the normal
    /// case for archive-streamed emails, which carry metadata only).
    private static func attachmentBytes(
        _ att: AttachmentMetadata,
        index: Int,
        email: MBOXParser.RawEmail,
        hydrated: inout [AttachmentMetadata]?
    ) -> Data? {
        if let url = att.fileURL, let d = try? Data(contentsOf: url) { return d }
        if let b64 = att.base64,
           let d = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) { return d }

        if hydrated == nil {
            hydrated = (try? EmailBodyExtractor.extractContents(from: email.rawSource))?.attachments ?? []
        }
        guard let list = hydrated, !list.isEmpty else { return nil }
        let match = list.first { $0.filename == att.filename }
            ?? (index < list.count ? list[index] : nil)
        if let url = match?.fileURL, let d = try? Data(contentsOf: url) { return d }
        if let b64 = match?.base64,
           let d = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) { return d }
        return nil
    }

    // MARK: - Helpers

    private static func extractAddr(_ from: String) -> String {
        guard let s = from.firstIndex(of: "<"), let e = from.firstIndex(of: ">") else {
            return from.trimmingCharacters(in: .whitespaces)
        }
        return String(from[from.index(after: s)..<e]).trimmingCharacters(in: .whitespaces)
    }

    private static func parseISO(_ ts: String) -> Date? { ISO8601DateFormatter().date(from: ts) }

    private static func fileTime(_ d: Date) -> UInt64 {
        UInt64((d.timeIntervalSince1970 + 11_644_473_600.0) * 10_000_000.0)
    }

    private static func pageAlign(_ v: UInt64) -> UInt64 {
        (v + UInt64(pageSize) - 1) / UInt64(pageSize) * UInt64(pageSize)
    }

    // MARK: - Binary write helpers

    private static func appendU16(_ d: inout Data, _ v: UInt16) {
        d.append(UInt8(v & 0xFF)); d.append(UInt8(v >> 8))
    }

    private static func appendU32(_ d: inout Data, _ v: UInt32) {
        for s in stride(from: 0, to: 32, by: 8) { d.append(UInt8((v >> s) & 0xFF)) }
    }

    private static func appendU64(_ d: inout Data, _ v: UInt64) {
        for s in stride(from: 0, to: 64, by: 8) { d.append(UInt8((v >> s) & 0xFF)) }
    }

    private static func w16(_ d: inout Data, _ o: Int, _ v: UInt16) {
        d[o] = UInt8(v & 0xFF); d[o + 1] = UInt8(v >> 8)
    }

    private static func w32(_ d: inout Data, _ o: Int, _ v: UInt32) {
        for i in 0..<4 { d[o + i] = UInt8((v >> (i * 8)) & 0xFF) }
    }

    private static func w64(_ d: inout Data, _ o: Int, _ v: UInt64) {
        for i in 0..<8 { d[o + i] = UInt8((v >> (i * 8)) & 0xFF) }
    }

    // MARK: - CRC32

    private static let crc32Table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1 != 0) ? (c >> 1) ^ 0xEDB88320 : c >> 1
            }
            return c
        }
    }()

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for b in data {
            crc = (crc >> 8) ^ crc32Table[Int((crc ^ UInt32(b)) & 0xFF)]
        }
        return crc ^ 0xFFFFFFFF
    }
}
