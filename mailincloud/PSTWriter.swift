import Foundation
import os.log

struct PSTWriter {

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "mailin",
        category: "PSTWriter"
    )

    enum WriterError: LocalizedError {
        case estimatedSizeTooLarge(Int)
        case encodingFailure(String)
        case emptyInput

        var errorDescription: String? {
            switch self {
            case .estimatedSizeTooLarge(let bytes):
                return "Estimated PST size (\(bytes / 1_048_576) MB) exceeds 4 GB limit"
            case .encodingFailure(let detail):
                return "String encoding failed: \(detail)"
            case .emptyInput:
                return "No emails provided for PST export"
            }
        }
    }

    // MARK: - Public API

    static func write(emails: [MBOXParser.RawEmail], to url: URL) throws -> Int {
        let exportCount = min(emails.count, maxEmailsPerPST)
        let data = try writeData(emails: emails)
        try data.write(to: url, options: .atomic)
        logger.info("Wrote PST file with \(exportCount) messages to \(url.path)")
        return exportCount
    }

    private static let maxEmailsPerPST = 5000

    static func writeData(emails: [MBOXParser.RawEmail]) throws -> Data {
        guard !emails.isEmpty else { throw WriterError.emptyInput }

        let exportEmails = Array(emails.prefix(maxEmailsPerPST))
        if emails.count > maxEmailsPerPST {
            logger.warning("PST export limited to \(maxEmailsPerPST) emails (requested \(emails.count)). Use MSG or EML export for larger sets.")
        }

        let estimatedSize = exportEmails.reduce(0) { total, email in
            total + email.rawSource.utf8.count + email.htmlBody.utf8.count
                + email.attachments.reduce(0) { $0 + $1.size }
        }
        guard estimatedSize < 4_294_967_296 else {
            throw WriterError.estimatedSizeTooLarge(estimatedSize)
        }

        do {
            let result = try buildPST(emails: exportEmails)
            logger.info("Built PST data: \(result.count) bytes, \(exportEmails.count) messages")
            return result
        } catch {
            logger.error("Failed to build PST: \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - PST Format Constants

    private static let pstMagic: [UInt8] = [0x21, 0x42, 0x44, 0x4E]  // !BDN
    private static let pageSize = 512
    private static let blockAlign = 64
    private static let pstVersionUnicode: UInt16 = 23

    private static let nidFolder: UInt32 = 0x02, nidMessage: UInt32 = 0x0C
    private static let nidContents: UInt32 = 0x0E, nidAttach: UInt32 = 0x0D

    private static let tagSubject: UInt16 = 0x0037, tagMsgClass: UInt16 = 0x001A
    private static let tagSenderAddr: UInt16 = 0x0C1F, tagDisplayTo: UInt16 = 0x0E04
    private static let tagBody: UInt16 = 0x1000, tagHtml: UInt16 = 0x1013
    private static let tagDeliveryTime: UInt16 = 0x0E06, tagCreationTime: UInt16 = 0x3007
    private static let tagMsgFlags: UInt16 = 0x0E07
    private static let tagAttachFile: UInt16 = 0x3707, tagAttachData: UInt16 = 0x3701
    private static let tagAttachMime: UInt16 = 0x370E, tagAttachMethod: UInt16 = 0x3705
    private static let tagDisplayName: UInt16 = 0x3001
    private static let tagContentCount: UInt16 = 0x3602, tagUnreadCount: UInt16 = 0x3603
    private static let tagContainerClass: UInt16 = 0x3613

    private static let ptUnicode: UInt16 = 0x001F, ptBinary: UInt16 = 0x0102
    private static let ptSystime: UInt16 = 0x0040, ptLong: UInt16 = 0x0003

    // MARK: - Internal Types

    private struct PropEntry { let id: UInt16, type: UInt16, fixed: UInt64, variable: Data? }
    private struct Block { let data: Data; var bid: UInt64 = 0 }
    private struct NRef { let nid: UInt32, dataBid: UInt64, subBid: UInt64 }
    private struct BRef { let bid: UInt64, offset: UInt64, size: UInt16 }

    // MARK: - Build PST

    private static func buildPST(emails: [MBOXParser.RawEmail]) throws -> Data {
        var blocks: [Block] = []
        var nodes: [NRef] = []
        var nextBid: UInt64 = 4
        var nextIdx: UInt32 = 0x20

        func bid() -> UInt64 { defer { nextBid += 4 }; return nextBid }
        func idx() -> UInt32 { defer { nextIdx += 1 }; return nextIdx }

        let rootIdx = idx()
        let rootNid = (rootIdx << 5) | nidFolder
        let rootBid = bid()
        blocks.append(Block(
            data: folderPC(name: "Top of Personal Folders", count: emails.count),
            bid: rootBid
        ))
        nodes.append(NRef(nid: rootNid, dataBid: rootBid, subBid: 0))

        let ctNid = (rootIdx << 5) | nidContents
        let ctBid = bid()
        blocks.append(Block(data: contentsTable(emails), bid: ctBid))
        nodes.append(NRef(nid: ctNid, dataBid: ctBid, subBid: 0))

        for (i, email) in emails.enumerated() {
            let mi = idx()
            let mNid = (mi << 5) | nidMessage
            let pc = try messagePC(email: email)
            let mBid = bid()
            blocks.append(Block(data: pc, bid: mBid))

            var sub: UInt64 = 0
            if !email.attachments.isEmpty {
                let subData = try attachSubnodes(
                    email: email,
                    blocks: &blocks,
                    bid: bid,
                    idx: idx
                )
                let sBid = bid()
                blocks.append(Block(data: subData, bid: sBid))
                sub = sBid
            }

            nodes.append(NRef(nid: mNid, dataBid: mBid, subBid: sub))

            if (i + 1) % 500 == 0 {
                logger.debug("Prepared \(i + 1)/\(emails.count) messages")
            }
        }

        return try layoutFile(blocks: blocks, nodes: nodes)
    }

    // MARK: - Property Context Builders

    private static func folderPC(name: String, count: Int) -> Data {
        serializePC([
            strProp(tagDisplayName, name),
            strProp(tagContainerClass, "IPF.Note"),
            PropEntry(id: tagContentCount, type: ptLong, fixed: UInt64(count), variable: nil),
            PropEntry(id: tagUnreadCount, type: ptLong, fixed: 0, variable: nil),
        ])
    }

    private static func contentsTable(_ emails: [MBOXParser.RawEmail]) -> Data {
        var d = Data()
        appendU32(&d, UInt32(emails.count))
        for i in 0..<emails.count {
            appendU32(&d, (UInt32(0x21 + i) << 5) | nidMessage)
        }
        return d
    }

    private static func messagePC(email: MBOXParser.RawEmail) throws -> Data {
        var e: [PropEntry] = [strProp(tagMsgClass, "IPM.Note")]

        if let s = email.headers["Subject"] {
            e.append(strProp(tagSubject, s))
        }
        if let f = email.headers["From"] {
            e.append(strProp(tagSenderAddr, extractAddr(f)))
        }
        if let t = email.headers["To"] {
            e.append(strProp(tagDisplayTo, t))
        }
        if !email.plainBody.isEmpty {
            e.append(strProp(tagBody, email.plainBody))
        }
        if !email.htmlBody.isEmpty {
            guard let hd = email.htmlBody.data(using: .utf8) else {
                throw WriterError.encodingFailure("HTML body")
            }
            e.append(PropEntry(id: tagHtml, type: ptBinary, fixed: 0, variable: hd))
        }
        if let date = parseISO(email.timestamp) {
            let ft = fileTime(date)
            e.append(PropEntry(id: tagDeliveryTime, type: ptSystime, fixed: ft, variable: nil))
            e.append(PropEntry(id: tagCreationTime, type: ptSystime, fixed: ft, variable: nil))
        }

        var flags: UInt32 = 0x01  // MSGFLAG_READ
        if !email.attachments.isEmpty { flags |= 0x10 }
        e.append(PropEntry(id: tagMsgFlags, type: ptLong, fixed: UInt64(flags), variable: nil))

        return serializePC(e)
    }

    private static func attachSubnodes(
        email: MBOXParser.RawEmail,
        blocks: inout [Block],
        bid: () -> UInt64,
        idx: () -> UInt32
    ) throws -> Data {
        // Subnode BTree: count header + 24-byte entries (nid, pad, dataBid, subBid)
        var sn = Data()
        appendU32(&sn, UInt32(email.attachments.count))

        for att in email.attachments {
            let aNid = (idx() << 5) | nidAttach

            var props: [PropEntry] = [
                strProp(tagAttachFile, att.filename),
                strProp(tagAttachMime, att.mimeType),
                PropEntry(id: tagAttachMethod, type: ptLong, fixed: 1, variable: nil),
            ]
            if let b64 = att.base64, let bin = Data(base64Encoded: b64) {
                props.append(PropEntry(id: tagAttachData, type: ptBinary, fixed: 0, variable: bin))
            }

            let aBid = bid()
            blocks.append(Block(data: serializePC(props), bid: aBid))

            appendU32(&sn, aNid)
            appendU32(&sn, 0)
            appendU64(&sn, aBid)
            appendU64(&sn, 0)
        }

        return sn
    }

    // MARK: - Property Context Serialization

    private static func serializePC(_ entries: [PropEntry]) -> Data {
        // HN header: 8 bytes, bClientSig = 0x7C marks a property context
        var hdr = Data(repeating: 0, count: 8)
        hdr[2] = 0x0C  // bSig
        hdr[3] = 0x7C  // bClientSig = property context
        hdr[5] = 0x20  // hidUserRoot points to offset 32

        // BTH header at offset 32: describes the property table layout
        var bth = Data(repeating: 0, count: 8)
        bth[0] = 0x02  // bType = BTree on Heap
        bth[1] = 0x02  // cbKey = 2 bytes (property ID)
        bth[2] = 0x06  // cbEnt = 6 bytes (type 2 + value ref 4)
        bth[4] = 0x40  // hidRoot -> offset 64

        // Each entry: propID (2) + propType (2) + value/heap-ref (4) = 8 bytes
        var fixed = Data()
        var heap = Data()
        var heapOff: UInt32 = 0

        for p in entries {
            appendU16(&fixed, p.id)
            appendU16(&fixed, p.type)
            if let v = p.variable {
                appendU32(&fixed, heapOff | 0x80000000)
                heap.append(v)
                heapOff += UInt32(v.count)
            } else {
                appendU32(&fixed, UInt32(p.fixed & 0xFFFFFFFF))
            }
        }

        var result = Data()
        result.append(hdr)
        result.append(Data(repeating: 0, count: 24))  // pad to offset 32
        result.append(bth)
        result.append(Data(repeating: 0, count: 24))  // pad to offset 64
        result.append(fixed)

        if !heap.isEmpty {
            let hs = UInt16(result.count)
            result.append(heap)
            result[0] = UInt8(hs & 0xFF)
            result[1] = UInt8(hs >> 8)
        }

        return result
    }

    // MARK: - File Layout

    private static func layoutFile(blocks: [Block], nodes: [NRef]) throws -> Data {
        // 564-byte Unicode PST header
        var hdr = Data(repeating: 0, count: 564)
        hdr[0] = pstMagic[0]; hdr[1] = pstMagic[1]
        hdr[2] = pstMagic[2]; hdr[3] = pstMagic[3]
        hdr[8] = 0x53; hdr[9] = 0x4D  // wMagicClient = "SM"
        w16(&hdr, 10, pstVersionUnicode)
        w16(&hdr, 12, 19)  // wVerClient
        hdr[14] = 0x01     // bPlatformCreate
        hdr[15] = 0x01     // bPlatformAccess

        // Place data blocks starting at 4096 (first page boundary after header)
        let dataStart: UInt64 = 4096
        var off = dataStart
        var bRefs: [BRef] = []
        var chunks: [(UInt64, Data)] = []

        for b in blocks {
            bRefs.append(BRef(bid: b.bid, offset: off, size: UInt16(b.data.count)))
            chunks.append((off, b.data))
            let aligned = ((b.data.count + blockAlign - 1) / blockAlign) * blockAlign
            off += UInt64(max(aligned, blockAlign))
        }

        let nbtOff = pageAlign(off)
        off = nbtOff + UInt64(pageSize)
        let bbtOff = pageAlign(off)
        off = bbtOff + UInt64(pageSize)
        let eof = pageAlign(off)

        // Root info: offsets follow MS-PST Unicode header layout
        w64(&hdr, 180, 4)             // bidNextP
        w64(&hdr, 184, eof)           // ibFileEof
        w64(&hdr, 192, eof)           // ibAMapLast
        w64(&hdr, 200, 0)             // cbAMapFree
        w64(&hdr, 208, 0)             // cbPMapFree
        w64(&hdr, 216, 1)             // BREFNBT.bid
        w64(&hdr, 224, nbtOff)        // BREFNBT.ib
        w64(&hdr, 232, 2)             // BREFBBT.bid
        w64(&hdr, 240, bbtOff)        // BREFBBT.ib

        hdr[513] = 0x01  // bCryptMethod = NDB_CRYPT_PERMUTE

        let maxBid = blocks.map(\.bid).max() ?? 4
        w64(&hdr, 328, maxBid + 4)    // bidNextB
        w32(&hdr, 340, UInt32(blocks.count + 1))  // dwUnique

        // rgnid counters: 32 slots of 4 bytes at offset 344
        let mc = nodes.filter { ($0.nid & 0x1F) == nidMessage }.count
        w32(&hdr, 344 + Int(nidMessage) * 4, UInt32(mc))

        // CRC of partial header (bytes 8..183) at offset 4
        w32(&hdr, 4, crc32(Data(hdr[8..<184])))
        // CRC of root area (bytes 184..515) at offset 524
        if hdr.count >= 524 {
            w32(&hdr, 524, crc32(Data(hdr[184..<516])))
        }

        // Assemble final file data
        var file = Data()
        file.append(hdr)
        pad(&file, to: Int(dataStart))

        for (o, d) in chunks {
            pad(&file, to: Int(o))
            file.append(d)
            let aligned = ((d.count + blockAlign - 1) / blockAlign) * blockAlign
            if aligned > d.count {
                file.append(Data(repeating: 0, count: aligned - d.count))
            }
        }

        pad(&file, to: Int(nbtOff))
        file.append(nbtPage(nodes))

        pad(&file, to: Int(bbtOff))
        file.append(bbtPage(bRefs))

        pad(&file, to: Int(eof))
        return file
    }

    // MARK: - BTree Pages

    private static func nbtPage(_ records: [NRef]) -> Data {
        var pg = Data(repeating: 0, count: pageSize)
        // NBT leaf entry: nid(4) + pad(4) + dataBid(8) + subBid(8) + parentNid(4) + pad(4) = 32 bytes
        let n = min(records.count, 15)
        for i in 0..<n {
            let r = records[i]
            let b = i * 32
            w32(&pg, b, r.nid)
            w32(&pg, b + 4, 0)
            w64(&pg, b + 8, r.dataBid)
            w64(&pg, b + 16, r.subBid)
            w32(&pg, b + 24, 0)
            w32(&pg, b + 28, 0)
        }

        // Page trailer at offset 488
        pg[488] = UInt8(n)   // cEnt
        pg[489] = UInt8(n)   // cEntMax
        pg[490] = 32         // cbEnt
        pg[491] = 0          // cLevel (leaf)
        pg[496] = 0x81       // ptype = ptypeNBT
        pg[497] = 0x81       // ptypeRepeat
        w32(&pg, 500, crc32(Data(pg[0..<496])))
        w64(&pg, 504, 1)

        return pg
    }

    private static func bbtPage(_ records: [BRef]) -> Data {
        var pg = Data(repeating: 0, count: pageSize)
        // BBT leaf entry: bid(8) + offset(8) + size(2) + pad(6) = 24 bytes
        let n = min(records.count, 20)
        for i in 0..<n {
            let r = records[i]
            let b = i * 24
            w64(&pg, b, r.bid)
            w64(&pg, b + 8, r.offset)
            w16(&pg, b + 16, r.size)
        }

        pg[488] = UInt8(n)
        pg[489] = UInt8(n)
        pg[490] = 24
        pg[491] = 0
        pg[496] = 0x82       // ptype = ptypeBBT
        pg[497] = 0x82
        w32(&pg, 500, crc32(Data(pg[0..<496])))
        w64(&pg, 504, 2)

        return pg
    }

    // MARK: - Helpers

    private static func strProp(_ id: UInt16, _ val: String) -> PropEntry {
        PropEntry(id: id, type: ptUnicode, fixed: 0, variable: val.data(using: .utf16LittleEndian) ?? Data())
    }

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

    private static func pad(_ data: inout Data, to target: Int) {
        if data.count < target { data.append(Data(repeating: 0, count: target - data.count)) }
    }

    // MARK: - Binary Write Helpers

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
        while d.count < o + 2 { d.append(0) }
        d[o] = UInt8(v & 0xFF); d[o + 1] = UInt8(v >> 8)
    }

    private static func w32(_ d: inout Data, _ o: Int, _ v: UInt32) {
        while d.count < o + 4 { d.append(0) }
        for i in 0..<4 { d[o + i] = UInt8((v >> (i * 8)) & 0xFF) }
    }

    private static func w64(_ d: inout Data, _ o: Int, _ v: UInt64) {
        while d.count < o + 8 { d.append(0) }
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
