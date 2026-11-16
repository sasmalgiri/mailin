//
//  WriterConformanceTests.swift
//  ArchiveCoreTests
//
//  Review 2026-11-16 B13 + E (writers):
//    • The .msg writer is checked against MS-CFB / MS-OXMSG by a compound-file
//      reader written here from the specification — NOT through MSGParser /
//      OLE2Reader (the review's "verify-vs-self" finding). It checks the
//      header, FAT + DIFAT chains, the red-black directory, the required
//      storages and streams, and that every properties stream has an entry
//      (with the right size) for every property stream / storage written.
//    • Files above 109 FAT sectors get DIFAT sectors (tested on a version 3,
//      512-byte-sector file, where 109 FAT sectors cover only ~7 MB).
//    • Write errors throw a named reason.
//    • ExportSigner never replaces a stored key it cannot read.
//    • PSTSpecWriter: no precondition traps; a > 4 GiB item is a stated limit.
//
//  Set MAILIN_MSG_DUMP_DIR to keep the written files for an outside reader
//  (olefile / extract_msg) check.
//

import XCTest
import Foundation
import CryptoKit
@testable import ArchiveCore

// MARK: - An independent MS-CFB reader

private struct CFBFile {
    struct Entry {
        var name: String
        var type: UInt8
        var red: Bool
        var left: UInt32, right: UInt32, child: UInt32
        var clsid: Data
        var start: UInt32
        var size: UInt64
    }
    enum Problem: Error, CustomStringConvertible {
        case bad(String)
        var description: String { if case .bad(let s) = self { return s }; return "" }
    }

    static let endOfChain: UInt32 = 0xFFFF_FFFE, free: UInt32 = 0xFFFF_FFFF
    static let fatSect: UInt32 = 0xFFFF_FFFD, difSect: UInt32 = 0xFFFF_FFFC, noStream: UInt32 = 0xFFFF_FFFF

    let data: Data
    let major: UInt16
    let sectorSize: Int
    let fat: [UInt32]
    let miniFat: [UInt32]
    let entries: [Entry]
    let miniStream: Data
    let fatSectorCount: Int
    let difatSectorCount: Int

    static func u16(_ d: Data, _ o: Int) -> UInt16 { UInt16(d[d.startIndex + o]) | UInt16(d[d.startIndex + o + 1]) << 8 }
    static func u32(_ d: Data, _ o: Int) -> UInt32 { (0..<4).reduce(UInt32(0)) { $0 | UInt32(d[d.startIndex + o + $1]) << (8 * $1) } }
    static func u64(_ d: Data, _ o: Int) -> UInt64 { (0..<8).reduce(UInt64(0)) { $0 | UInt64(d[d.startIndex + o + $1]) << (8 * $1) } }

    func sector(_ n: UInt32) throws -> Data {
        let offset = (Int(n) + 1) * sectorSize
        guard offset + sectorSize <= data.count else { throw Problem.bad("sector \(n) is past the end of the file") }
        return data.subdata(in: offset..<offset + sectorSize)
    }

    static func chain(_ start: UInt32, in table: [UInt32]) throws -> [UInt32] {
        var out: [UInt32] = [], seen = Set<UInt32>(), s = start
        while s != endOfChain {
            guard Int(s) < table.count, seen.insert(s).inserted else { throw Problem.bad("chain from \(start) is broken at \(s)") }
            out.append(s); s = table[Int(s)]
        }
        return out
    }

    init(_ data: Data) throws {
        self.data = data
        guard data.count >= 512, [UInt8](data.prefix(8)) == [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1] else { throw Problem.bad("no CFB signature") }
        guard Self.u16(data, 28) == 0xFFFE else { throw Problem.bad("byte order mark") }
        major = Self.u16(data, 26)
        let shift = Int(Self.u16(data, 30))
        guard (major == 3 && shift == 9) || (major == 4 && shift == 12) else { throw Problem.bad("version \(major) with sector shift \(shift)") }
        guard Self.u16(data, 32) == 6, Self.u32(data, 56) == 4096 else { throw Problem.bad("mini sector size / cutoff") }
        sectorSize = 1 << shift
        guard (data.count - sectorSize) % sectorSize == 0 else { throw Problem.bad("file is not whole sectors: \(data.count)") }
        if major == 3, Self.u32(data, 40) != 0 { throw Problem.bad("version 3 must record 0 directory sectors") }
        let nFat = Int(Self.u32(data, 44))
        let nDifat = Int(Self.u32(data, 72))
        fatSectorCount = nFat; difatSectorCount = nDifat
        // FAT sector list: 109 in the header, then the DIFAT chain.
        var fatSectors: [UInt32] = []
        for i in 0..<109 {
            let s = Self.u32(data, 76 + i * 4)
            if i < nFat { fatSectors.append(s) } else if s != Self.free { throw Problem.bad("header DIFAT[\(i)] should be free") }
        }
        var difatSector = Self.u32(data, 68)
        var difatSectors: [UInt32] = []
        let per = sectorSize / 4
        for _ in 0..<nDifat {
            difatSectors.append(difatSector)
            let offset = (Int(difatSector) + 1) * sectorSize
            guard offset + sectorSize <= data.count else { throw Problem.bad("DIFAT sector \(difatSector) past the end") }
            let d = data.subdata(in: offset..<offset + sectorSize)
            for j in 0..<(per - 1) {
                let s = Self.u32(d, j * 4)
                if fatSectors.count < nFat { fatSectors.append(s) } else if s != Self.free { throw Problem.bad("unused DIFAT slot not free") }
            }
            difatSector = Self.u32(d, (per - 1) * 4)
        }
        guard difatSector == Self.endOfChain else { throw Problem.bad("DIFAT chain does not end in ENDOFCHAIN") }
        guard fatSectors.count == nFat else { throw Problem.bad("DIFAT lists \(fatSectors.count) of \(nFat) FAT sectors") }
        var fat: [UInt32] = []
        for s in fatSectors {
            let offset = (Int(s) + 1) * sectorSize
            guard offset + sectorSize <= data.count else { throw Problem.bad("FAT sector \(s) past the end") }
            let d = data.subdata(in: offset..<offset + sectorSize)
            for j in 0..<per { fat.append(Self.u32(d, j * 4)) }
        }
        let totalSectors = (data.count - sectorSize) / sectorSize
        guard fat.count >= totalSectors else { throw Problem.bad("FAT covers \(fat.count) of \(totalSectors) sectors") }
        for s in fatSectors where fat[Int(s)] != Self.fatSect { throw Problem.bad("FAT sector \(s) not marked FATSECT") }
        for s in difatSectors where fat[Int(s)] != Self.difSect { throw Problem.bad("DIFAT sector \(s) not marked DIFSECT") }
        self.fat = fat

        func read(_ start: UInt32, _ table: [UInt32], from sectorData: (UInt32) throws -> Data) throws -> Data {
            var out = Data()
            for s in try Self.chain(start, in: table) { out.append(try sectorData(s)) }
            return out
        }
        let sectorRead: (UInt32) throws -> Data = { n in
            let offset = (Int(n) + 1) * (1 << shift)
            guard offset + (1 << shift) <= data.count else { throw Problem.bad("sector \(n) past the end") }
            return data.subdata(in: offset..<offset + (1 << shift))
        }
        let dirChain = try Self.chain(Self.u32(data, 48), in: fat)
        if major == 4, Int(Self.u32(data, 40)) != dirChain.count { throw Problem.bad("directory sector count \(Self.u32(data, 40)) ≠ chain \(dirChain.count)") }
        let dir = try read(Self.u32(data, 48), fat, from: sectorRead)
        var entries: [Entry] = []
        for i in 0..<(dir.count / 128) {
            let e = dir.subdata(in: i * 128..<(i + 1) * 128)
            let nameLen = Int(Self.u16(e, 64))
            var units: [UInt16] = []
            if nameLen >= 2 { for k in 0..<(nameLen / 2 - 1) { units.append(Self.u16(e, k * 2)) } }
            let type = e[e.startIndex + 66]
            let entry = Entry(name: String(decoding: units, as: UTF16.self), type: type, red: e[e.startIndex + 67] == 0,
                              left: Self.u32(e, 68), right: Self.u32(e, 72), child: Self.u32(e, 76),
                              clsid: e.subdata(in: 80..<96), start: Self.u32(e, 116),
                              size: major == 3 ? UInt64(Self.u32(e, 120)) : Self.u64(e, 120))
            if type == 0, entry.left != Self.noStream || entry.right != Self.noStream || entry.child != Self.noStream {
                throw Problem.bad("unused directory entry \(i) has links (must be NOSTREAM)")
            }
            entries.append(entry)
        }
        guard entries.first?.type == 5, entries.first?.name == "Root Entry" else { throw Problem.bad("first entry is not the root") }
        self.entries = entries
        let root = entries[0]
        miniStream = root.size == 0 ? Data() : try read(root.start, fat, from: sectorRead).prefix(Int(root.size))
        let miniFatStart = Self.u32(data, 60)
        var miniFat: [UInt32] = []
        if miniFatStart != Self.endOfChain {
            let mf = try read(miniFatStart, fat, from: sectorRead)
            if Int(Self.u32(data, 64)) != mf.count / sectorSize { throw Problem.bad("mini FAT sector count") }
            for j in 0..<(mf.count / 4) { miniFat.append(Self.u32(mf, j * 4)) }
        }
        self.miniFat = miniFat
    }

    func stream(_ index: Int) throws -> Data {
        let e = entries[index]
        guard e.type == 2 else { throw Problem.bad("\(e.name) is not a stream") }
        if e.size == 0 { return Data() }
        if e.size < 4096 {
            var out = Data()
            for s in try Self.chain(e.start, in: miniFat) {
                let o = Int(s) * 64
                guard o + 64 <= miniStream.count else { throw Problem.bad("mini sector \(s) past the mini stream") }
                out.append(miniStream.subdata(in: o..<o + 64))
            }
            guard out.count >= Int(e.size) else { throw Problem.bad("\(e.name): mini chain too short") }
            return out.prefix(Int(e.size))
        }
        var out = Data()
        for s in try Self.chain(e.start, in: fat) { out.append(try sector(s)) }
        guard out.count >= Int(e.size) else { throw Problem.bad("\(e.name): chain too short") }
        return out.prefix(Int(e.size))
    }

    static func nameLess(_ a: String, _ b: String) -> Bool {
        if a.utf16.count != b.utf16.count { return a.utf16.count < b.utf16.count }
        return a.uppercased().utf16.lexicographicallyPrecedes(b.uppercased().utf16)
    }

    /// The children of a storage by an in-order walk of its red-black tree,
    /// checking order, colour rules and equal black height.
    func children(of storage: Int) throws -> [String: Int] {
        var out: [(String, Int)] = []
        var visited = Set<Int>()
        func walk(_ id: UInt32, parentRed: Bool) throws -> Int {
            if id == Self.noStream { return 1 }
            let i = Int(id)
            guard i < entries.count, visited.insert(i).inserted else { throw Problem.bad("sibling tree revisits \(id)") }
            let e = entries[i]
            if e.red && parentRed { throw Problem.bad("red entry \(e.name) has a red parent") }
            let l = try walk(e.left, parentRed: e.red)
            out.append((e.name, i))
            let r = try walk(e.right, parentRed: e.red)
            guard l == r else { throw Problem.bad("unequal black height under \(e.name)") }
            return l + (e.red ? 0 : 1)
        }
        let rootID = entries[storage].child
        if rootID != Self.noStream, entries[Int(rootID)].red { throw Problem.bad("tree root under \(entries[storage].name) is red") }
        _ = try walk(rootID, parentRed: false)
        for (a, b) in zip(out, out.dropFirst()) where !Self.nameLess(a.0, b.0) {
            throw Problem.bad("siblings out of order: \(a.0) before \(b.0)")
        }
        return Dictionary(out, uniquingKeysWith: { a, _ in a })
    }

    /// Every entry reachable from the root once (none orphaned or shared).
    func reachableCount() throws -> Int {
        var count = 1
        var queue = [0]
        while let s = queue.popLast() {
            for (_, i) in try children(of: s) {
                count += 1
                if entries[i].type == 1 { queue.append(i) }
            }
        }
        return count
    }
}

// MARK: - MS-OXMSG structural checks

private struct PropertyEntry { let tag: UInt32; let flags: UInt32; let value: Data }

private enum MSGConformance {
    enum Kind { case topLevel, embedded, recipient, attachment
        var header: Int { switch self { case .topLevel: return 32; case .embedded: return 24; default: return 8 } }
    }

    static func properties(_ cfb: CFBFile, _ children: [String: Int], kind: Kind) throws -> (header: Data, entries: [UInt32: PropertyEntry]) {
        guard let idx = children["__properties_version1.0"] else { throw CFBFile.Problem.bad("no __properties_version1.0") }
        let d = try cfb.stream(idx)
        guard d.count >= kind.header, (d.count - kind.header) % 16 == 0 else {
            throw CFBFile.Problem.bad("properties stream is \(d.count) bytes; header \(kind.header) + 16-byte entries expected")
        }
        var out: [UInt32: PropertyEntry] = [:]
        var o = kind.header
        while o < d.count {
            let tag = CFBFile.u32(d, o)
            out[tag] = PropertyEntry(tag: tag, flags: CFBFile.u32(d, o + 4), value: d.subdata(in: o + 8..<o + 16))
            o += 16
        }
        return (d.prefix(kind.header), out)
    }

    /// Checks one storage; returns problems found (empty = conformant).
    static func check(_ cfb: CFBFile, storage: Int, kind: Kind, path: String, problems: inout [String]) throws {
        let children = try cfb.children(of: storage)
        let (header, props) = try properties(cfb, children, kind: kind)
        let variableTypes: Set<UInt32> = [0x001F, 0x001E, 0x0102, 0x000D]
        // Every property stream / storage has an entry, with the right size.
        for (name, idx) in children where name.hasPrefix("__substg1.0_") {
            guard let tag = UInt32(name.dropFirst(12), radix: 16) else { problems.append("\(path)/\(name): bad tag"); continue }
            guard let entry = props[tag] else { problems.append("\(path)/\(name): no properties-stream entry"); continue }
            let size = CFBFile.u32(entry.value, 0)
            switch tag & 0xFFFF {
            case 0x001F:
                if UInt64(size) != cfb.entries[idx].size + 2 { problems.append("\(path)/\(name): size \(size), stream \(cfb.entries[idx].size) (+2 expected)") }
            case 0x001E:
                if UInt64(size) != cfb.entries[idx].size + 1 { problems.append("\(path)/\(name): size \(size) (+1 expected)") }
            case 0x0102:
                if UInt64(size) != cfb.entries[idx].size { problems.append("\(path)/\(name): size \(size), stream \(cfb.entries[idx].size)") }
            case 0x000D:
                if cfb.entries[idx].type != 1 { problems.append("\(path)/\(name): object property is not a storage") }
                if size != 0xFFFF_FFFF { problems.append("\(path)/\(name): object entry size \(size), 0xFFFFFFFF expected") }
            default: break
            }
            if entry.flags & 0x6 != 0x6 { problems.append("\(path)/\(name): entry not readable+writable") }
        }
        // Every variable-length entry has its stream / storage.
        for (tag, _) in props where variableTypes.contains(tag & 0xFFFF) {
            let name = "__substg1.0_" + String(format: "%08X", tag)
            if children[name] == nil { problems.append("\(path): entry \(String(format: "%08X", tag)) has no \(name)") }
        }
        switch kind {
        case .topLevel, .embedded:
            guard let mc = children["__substg1.0_001A001F"] else { problems.append("\(path): no PR_MESSAGE_CLASS stream"); break }
            let cls = String(data: try cfb.stream(mc), encoding: .utf16LittleEndian) ?? ""
            if !cls.hasPrefix("IPM.") { problems.append("\(path): message class \(cls)") }
            if kind == .topLevel {
                guard let nid = children["__nameid_version1.0"], cfb.entries[nid].type == 1 else {
                    problems.append("\(path): no __nameid_version1.0 storage"); break
                }
                let named = try cfb.children(of: nid)
                for s in ["__substg1.0_00020102", "__substg1.0_00030102", "__substg1.0_00040102"] where named[s] == nil {
                    problems.append("\(path)/__nameid_version1.0: no \(s)")
                }
            }
            let recips = children.keys.filter { $0.hasPrefix("__recip_version1.0_#") }.sorted()
            let attachs = children.keys.filter { $0.hasPrefix("__attach_version1.0_#") }.sorted()
            if Int(CFBFile.u32(header, 16)) != recips.count { problems.append("\(path): header recipient count \(CFBFile.u32(header, 16)) ≠ \(recips.count) storages") }
            if Int(CFBFile.u32(header, 20)) != attachs.count { problems.append("\(path): header attachment count \(CFBFile.u32(header, 20)) ≠ \(attachs.count) storages") }
            if Int(CFBFile.u32(header, 8)) < recips.count { problems.append("\(path): next recipient ID below the count") }
            if Int(CFBFile.u32(header, 12)) < attachs.count { problems.append("\(path): next attachment ID below the count") }
            for (i, r) in recips.enumerated() {
                if r != "__recip_version1.0_#" + String(format: "%08X", i) { problems.append("\(path): recipient storage \(r) out of sequence") }
                let idx = children[r]!
                try check(cfb, storage: idx, kind: .recipient, path: "\(path)/\(r)", problems: &problems)
                let rc = try cfb.children(of: idx)
                let (_, rp) = try properties(cfb, rc, kind: .recipient)
                guard let type = rp[0x0C15_0003] else { problems.append("\(path)/\(r): no PR_RECIPIENT_TYPE"); continue }
                if !(1...3).contains(CFBFile.u32(type.value, 0)) { problems.append("\(path)/\(r): recipient type \(CFBFile.u32(type.value, 0))") }
                for tag in [0x3001_001F, 0x3002_001F, 0x3003_001F, 0x39FE_001F] as [UInt32] where rp[tag] == nil {
                    problems.append("\(path)/\(r): no \(String(format: "%08X", tag))")
                }
            }
            for a in attachs {
                let idx = children[a]!
                try check(cfb, storage: idx, kind: .attachment, path: "\(path)/\(a)", problems: &problems)
                let ac = try cfb.children(of: idx)
                if let emb = ac["__substg1.0_3701000D"] {
                    try check(cfb, storage: emb, kind: .embedded, path: "\(path)/\(a)/__substg1.0_3701000D", problems: &problems)
                }
            }
        case .recipient, .attachment:
            break
        }
    }

    static func string(_ cfb: CFBFile, _ children: [String: Int], _ tag: String) throws -> String? {
        guard let i = children["__substg1.0_" + tag] else { return nil }
        return String(data: try cfb.stream(i), encoding: .utf16LittleEndian)
    }
}

// MARK: - Tests

private final class MemoryKeyStore: ExportSigningKeyStore {
    var stored: Data?
    var saves = 0
    init(_ stored: Data?) { self.stored = stored }
    func load() throws -> Data? { stored }
    func save(_ data: Data) throws { saves += 1; stored = data }
}

final class WriterConformanceTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("writer-conformance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func dump(_ data: Data, _ name: String) {
        guard let path = ProcessInfo.processInfo.environment["MAILIN_MSG_DUMP_DIR"] else { return }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: folder.appendingPathComponent(name))
    }

    static func sampleRaw(large: Int = 9_000) -> String {
        let big = Data((0..<large).map { UInt8($0 % 251) }).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        let inner = "From: Inner Sender <inner@x.org>\r\nTo: Dana <dana@y.org>\r\nSubject: Inner note\r\nDate: Tue, 14 Jan 2025 09:00:00 +0000\r\nMessage-ID: <inner@t>\r\n\r\nThe attached message body.\r\n"
        return """
        From: "Ann Archivist" <ann@x.com>\r
        To: "Bob, Jr." <bob@y.org>, carol@z.net\r
        Cc: Dev <dev@x.com>\r
        Bcc: hidden@q.org\r
        Subject: Quarterly figures\r
        Date: Wed, 15 Jan 2025 10:00:30 +0000\r
        Message-ID: <m1@t>\r
        MIME-Version: 1.0\r
        Content-Type: multipart/mixed; boundary="OUTER"\r
        \r
        --OUTER\r
        Content-Type: multipart/alternative; boundary="ALT"\r
        \r
        --ALT\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        Line one.\r
        Line two.\r
        --ALT\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <p>Line one.</p>\r
        --ALT--\r
        --OUTER\r
        Content-Type: text/plain; name="a.txt"\r
        Content-Disposition: attachment; filename="a.txt"\r
        \r
        alpha\r
        --OUTER\r
        Content-Type: application/octet-stream; name="big.bin"\r
        Content-Disposition: attachment; filename="big.bin"\r
        Content-Transfer-Encoding: base64\r
        \r
        \(big)\r
        --OUTER\r
        Content-Type: message/rfc822; name="inner.eml"\r
        Content-Disposition: attachment; filename="inner.eml"\r
        \r
        \(inner)\r
        --OUTER--\r

        """
    }

    // MARK: B13 — MS-OXMSG structure, read independently

    func testMSG_isMSOXMSGConformant_readIndependently() throws {
        let email = try MBOXParser.processRawMessage(Self.sampleRaw(), senderEmail: "")
        XCTAssertEqual(email.attachments.count, 3, "fixture: a.txt, big.bin, inner.eml")
        let data = try MSGWriter.data(for: email)
        dump(data, "conformance.msg")
        let cfb = try CFBFile(data)
        XCTAssertEqual(cfb.major, 4)
        XCTAssertEqual(cfb.difatSectorCount, 0)
        XCTAssertEqual(try cfb.reachableCount(), cfb.entries.filter { $0.type != 0 }.count, "every entry is reachable exactly once")
        XCTAssertEqual(cfb.entries[0].clsid, Data([0x0B, 0x0D, 0x02, 0, 0, 0, 0, 0, 0xC0, 0, 0, 0, 0, 0, 0, 0x46]), "CLSID_MailMessage on the root")

        var problems: [String] = []
        try MSGConformance.check(cfb, storage: 0, kind: .topLevel, path: "", problems: &problems)
        XCTAssertEqual(problems, [], problems.joined(separator: "\n"))

        // Recipients: To ×2 (one with a quoted comma), Cc, Bcc — type, name, address.
        let root = try cfb.children(of: 0)
        var recipients: [(UInt32, String, String, String)] = []
        for i in 0..<4 {
            let r = try XCTUnwrap(root["__recip_version1.0_#" + String(format: "%08X", i)], "recipient \(i)")
            let rc = try cfb.children(of: r)
            let (_, rp) = try MSGConformance.properties(cfb, rc, kind: .recipient)
            recipients.append((CFBFile.u32(rp[0x0C15_0003]!.value, 0),
                               try MSGConformance.string(cfb, rc, "3001001F") ?? "",
                               try MSGConformance.string(cfb, rc, "3003001F") ?? "",
                               try MSGConformance.string(cfb, rc, "39FE001F") ?? ""))
        }
        XCTAssertNil(root["__recip_version1.0_#00000004"])
        XCTAssertEqual(recipients.map(\.0), [1, 1, 2, 3])
        XCTAssertEqual(recipients.map(\.1), ["Bob, Jr.", "carol@z.net", "Dev", "hidden@q.org"])
        XCTAssertEqual(recipients.map(\.2), ["bob@y.org", "carol@z.net", "dev@x.com", "hidden@q.org"])
        XCTAssertEqual(recipients.map(\.3), recipients.map(\.2))

        XCTAssertEqual(try MSGConformance.string(cfb, root, "001A001F"), "IPM.Note")
        XCTAssertEqual(try MSGConformance.string(cfb, root, "0037001F"), "Quarterly figures")
        XCTAssertEqual(try MSGConformance.string(cfb, root, "0C1F001F"), "ann@x.com")

        // Attachments: bytes intact through the regular-sector (> 4 KB) path; the
        // .eml is an embedded message storage with its own recipient.
        let big = try XCTUnwrap(root["__attach_version1.0_#00000001"])
        let bigChildren = try cfb.children(of: big)
        XCTAssertEqual(try MSGConformance.string(cfb, bigChildren, "3707001F"), "big.bin")
        XCTAssertEqual(try cfb.stream(try XCTUnwrap(bigChildren["__substg1.0_37010102"])), Data((0..<9_000).map { UInt8($0 % 251) }))
        let emb = try XCTUnwrap(try cfb.children(of: try XCTUnwrap(root["__attach_version1.0_#00000002"]))["__substg1.0_3701000D"])
        let embChildren = try cfb.children(of: emb)
        XCTAssertEqual(try MSGConformance.string(cfb, embChildren, "0037001F"), "Inner note")
        XCTAssertNotNil(embChildren["__recip_version1.0_#00000000"])
        XCTAssertNil(embChildren["__nameid_version1.0"], "named-property storage only at the top level")

        // The app's own reader still reads it (no regression).
        let back = try MSGParser.parse(data: data)
        XCTAssertEqual(back.headers["Subject"], "Quarterly figures")
        XCTAssertEqual(back.attachments.count, 3)
    }

    /// D-5: an inline image keeps its Content-ID (PR_ATTACH_CONTENT_ID), is
    /// hidden from the attachment list (PR_ATTACHMENT_HIDDEN) and marked as
    /// referenced from the HTML body (PR_ATTACH_FLAGS ATT_MHTML_REF); a
    /// regular attachment is not hidden and carries no flags — read here from
    /// the compound file, not through MSGParser.
    func testMSG_inlineImage_contentIDHiddenAndMHTMLRef_readIndependently() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4]).base64EncodedString()
        let raw = """
        From: Ann <ann@x.com>\r
        To: bob@y.org\r
        Subject: Logo\r
        Date: Wed, 15 Jan 2025 10:00:30 +0000\r
        Message-ID: <cid1@t>\r
        MIME-Version: 1.0\r
        Content-Type: multipart/mixed; boundary="OUTER"\r
        \r
        --OUTER\r
        Content-Type: multipart/related; boundary="REL"\r
        \r
        --REL\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <p>Hi <img src="cid:logo.123@x"></p>\r
        --REL\r
        Content-Type: image/png; name="logo.png"\r
        Content-ID: <logo.123@x>\r
        Content-Disposition: inline; filename="logo.png"\r
        Content-Transfer-Encoding: base64\r
        \r
        \(png)\r
        --REL--\r
        --OUTER\r
        Content-Type: text/plain; name="a.txt"\r
        Content-Disposition: attachment; filename="a.txt"\r
        \r
        alpha\r
        --OUTER--\r

        """
        let email = try MBOXParser.processRawMessage(raw, senderEmail: "")
        let logoIndex = try XCTUnwrap(email.attachments.firstIndex { $0.filename == "logo.png" })
        let textIndex = try XCTUnwrap(email.attachments.firstIndex { $0.filename == "a.txt" })
        XCTAssertTrue(email.attachments[logoIndex].isInline, "fixture: the image is inline")
        let data = try MSGWriter.data(for: email)
        dump(data, "inline-image.msg")
        let cfb = try CFBFile(data)
        var problems: [String] = []
        try MSGConformance.check(cfb, storage: 0, kind: .topLevel, path: "", problems: &problems)
        XCTAssertEqual(problems, [], problems.joined(separator: "\n"))
        let root = try cfb.children(of: 0)

        let logo = try cfb.children(of: try XCTUnwrap(root["__attach_version1.0_#" + String(format: "%08X", logoIndex)]))
        XCTAssertEqual(try MSGConformance.string(cfb, logo, "3712001F"), "logo.123@x", "PR_ATTACH_CONTENT_ID")
        let (_, lp) = try MSGConformance.properties(cfb, logo, kind: .attachment)
        XCTAssertEqual(lp[0x7FFE_000B].map { CFBFile.u32($0.value, 0) }, 1, "PR_ATTACHMENT_HIDDEN = true")
        XCTAssertEqual(lp[0x3714_0003].map { CFBFile.u32($0.value, 0) }, 0x4, "PR_ATTACH_FLAGS = ATT_MHTML_REF")

        let text = try cfb.children(of: try XCTUnwrap(root["__attach_version1.0_#" + String(format: "%08X", textIndex)]))
        XCTAssertNil(text["__substg1.0_3712001F"], "no Content-ID on the regular attachment")
        let (_, tp) = try MSGConformance.properties(cfb, text, kind: .attachment)
        XCTAssertEqual(tp[0x7FFE_000B].map { CFBFile.u32($0.value, 0) }, 0, "PR_ATTACHMENT_HIDDEN = false")
        XCTAssertNil(tp[0x3714_0003], "no PR_ATTACH_FLAGS on the regular attachment")

        let back = try MSGParser.parse(data: data)
        XCTAssertEqual(back.attachments[logoIndex].contentID, "logo.123@x")
        XCTAssertTrue(back.attachments[logoIndex].isInline)
        XCTAssertFalse(back.attachments[textIndex].isInline)
    }

    /// The minimal message (no recipients, no attachments) is conformant too.
    func testMSG_minimalMessageConformant() throws {
        let email = try MBOXParser.processRawMessage("Subject: only\r\n\r\nbody\r\n", senderEmail: "")
        let data = try MSGWriter.data(for: email)
        dump(data, "minimal.msg")
        let cfb = try CFBFile(data)
        var problems: [String] = []
        try MSGConformance.check(cfb, storage: 0, kind: .topLevel, path: "", problems: &problems)
        XCTAssertEqual(problems, [])
    }

    // MARK: B13 — DIFAT, not a hidden 109-FAT-sector cap

    /// 109 FAT sectors of 512 bytes cover 109 × 128 sectors (~7 MB); a 9 MB
    /// stream needs DIFAT. Before the fix this threw "message too large".
    func testCompoundFile_aboveHeaderFATCapacity_usesDIFAT_readIndependently() throws {
        let payload = Data((0..<9_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let small = Data("small stream".utf8)
        let data = try MSGWriter.compoundFile(streams: [("store/big", payload), ("small", small)], sectorShift: 9)
        dump(data, "difat-v3.cfb")
        let cfb = try CFBFile(data)
        XCTAssertEqual(cfb.major, 3)
        XCTAssertGreaterThan(cfb.fatSectorCount, 109)
        XCTAssertGreaterThanOrEqual(cfb.difatSectorCount, 1)
        let root = try cfb.children(of: 0)
        let store = try cfb.children(of: try XCTUnwrap(root["store"]))
        XCTAssertEqual(try cfb.stream(try XCTUnwrap(store["big"])), payload)
        XCTAssertEqual(try cfb.stream(try XCTUnwrap(root["small"])), small)
    }

    /// Version 4 just past the header's capacity (109 FAT sectors × 1,024 =
    /// 111,616 sectors ≈ 457 MB). Allocates ~1 GB, so it runs only with
    /// MAILIN_LARGE_CFB=1 (the v3 test above covers the same DIFAT code).
    func testCompoundFile_v4Above457MB_usesDIFAT() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MAILIN_LARGE_CFB"] == "1", "set MAILIN_LARGE_CFB=1 to run the 460 MB check")
        var payload = Data(count: 460 * 1_048_576)
        payload[0] = 0xAB; payload[payload.count - 1] = 0xCD
        let data = try MSGWriter.compoundFile(streams: [("big", payload)])
        dump(data, "difat-v4.cfb")
        let cfb = try CFBFile(data)
        XCTAssertEqual(cfb.major, 4)
        XCTAssertGreaterThan(cfb.fatSectorCount, 109)
        XCTAssertEqual(cfb.difatSectorCount, 1)
        let read = try cfb.stream(try XCTUnwrap(try cfb.children(of: 0)["big"]))
        XCTAssertEqual(read.count, payload.count)
        XCTAssertEqual(read.first, 0xAB); XCTAssertEqual(read.last, 0xCD)
    }

    // MARK: B13 — errors are thrown with a reason

    func testCompoundFile_nameTooLong_throwsNamedReason() {
        let name = String(repeating: "n", count: 32)
        XCTAssertThrowsError(try MSGWriter.compoundFile(streams: [(name, Data("x".utf8))])) { error in
            XCTAssertEqual(error as? MSGWriterError, .entryNameTooLong(name))
            XCTAssertTrue(error.localizedDescription.contains("31 characters"), error.localizedDescription)
        }
        // 31 is allowed and kept whole (the old writer cut names to 30).
        let ok = String(repeating: "m", count: 31)
        XCTAssertNoThrow(try {
            let cfb = try CFBFile(try MSGWriter.compoundFile(streams: [(ok, Data("x".utf8))]))
            XCTAssertNotNil(try cfb.children(of: 0)[ok])
        }())
    }

    // MARK: E — ExportSigner keeps a key it cannot read

    @MainActor
    func testExportSigner_unreadableStoredKey_throwsAndIsNotReplaced() throws {
        let garbage = Data([1, 2, 3])
        let store = MemoryKeyStore(garbage)
        let signer = ExportSigner(keyStore: store)
        XCTAssertThrowsError(try signer.sign(Data("payload".utf8))) { error in
            XCTAssertEqual(error as? ExportSignerError, .storedKeyUnreadable(byteCount: 3))
            XCTAssertTrue(error.localizedDescription.contains("did not replace"), error.localizedDescription)
        }
        XCTAssertEqual(store.saves, 0, "the unreadable key is not overwritten")
        XCTAssertEqual(store.stored, garbage)

        // A readable stored key is used as it is; an empty store gets one new key, once.
        let key = Curve25519.Signing.PrivateKey()
        let good = MemoryKeyStore(key.rawRepresentation)
        XCTAssertEqual(try ExportSigner(keyStore: good).publicKeyBytes(), key.publicKey.rawRepresentation)
        XCTAssertEqual(good.saves, 0)
        let empty = MemoryKeyStore(nil)
        let fresh = ExportSigner(keyStore: empty)
        let pk = try fresh.publicKeyBytes()
        XCTAssertEqual(try fresh.publicKeyBytes(), pk)
        XCTAssertEqual(empty.saves, 1)
    }

    // MARK: E — PSTSpecWriter: thrown errors, stated 4 GiB limit

    func testPSTSpecWriter_itemAbove4GiB_isStatedLimit_notATrap() throws {
        let w = try PSTSpecWriter(url: dir.appendingPathComponent("limit.pst"))
        // Fake block ids: the size check comes before anything is written.
        XCTAssertThrowsError(try w.dataTree([4, 8, 12], totalBytes: Int(UInt32.max) + 1)) { error in
            guard case PSTSpecWriter.WriteError.formatLimit(let why)? = error as? PSTSpecWriter.WriteError else {
                return XCTFail("expected formatLimit, got \(error)")
            }
            XCTAssertTrue(why.contains("4294967295"), why)
            XCTAssertTrue(error.localizedDescription.contains("4 GiB"), error.localizedDescription)
        }
        // At the limit itself it is accepted (written as an XBLOCK over the fakes).
        XCTAssertNoThrow(try w.dataTree([4, 8, 12], totalBytes: Int(UInt32.max)))
    }

    func testPSTSpecWriter_invariantBreaks_throwInsteadOfTrapping() throws {
        let w = try PSTSpecWriter(url: dir.appendingPathComponent("inv.pst"))
        func isInconsistent(_ e: Error) -> Bool {
            if case PSTSpecWriter.WriteError.inconsistent? = e as? PSTSpecWriter.WriteError { return true }
            return false
        }
        XCTAssertThrowsError(try w.writeBlock(Data(count: PSTSpecFormat.blockDataMax + 1), isInternal: false)) { XCTAssertTrue(isInconsistent($0), "\($0)") }
        let heap = PSTSpecWriter.HeapBuilder(writer: w, clientSig: 0xBC)
        XCTAssertThrowsError(try heap.alloc(Data(count: PSTSpecFormat.maxAllocation + 1))) { XCTAssertTrue(isInconsistent($0), "\($0)") }
        let hid = try heap.alloc(Data(count: 4))
        XCTAssertThrowsError(try heap.overwrite(hid, with: Data(count: 64))) { XCTAssertTrue(isInconsistent($0), "\($0)") }
        XCTAssertThrowsError(try heap.overwrite(0x0000_7FE0, with: Data(count: 4))) { XCTAssertTrue(isInconsistent($0), "\($0)") }
        XCTAssertNoThrow(try heap.overwrite(hid, with: Data([1, 2, 3, 4])))
        let bth = PSTSpecWriter.BTHBuilder(heap: heap, cbKey: 4, cbEnt: 4)
        XCTAssertThrowsError(try bth.add(key: Data(count: 2), value: Data(count: 4))) { XCTAssertTrue(isInconsistent($0), "\($0)") }
        XCTAssertThrowsError(try PSTSpecWriter(url: dir.appendingPathComponent("c.pst"), cryptMethod: 3)) { XCTAssertTrue(isInconsistent($0), "\($0)") }
        // More sub-objects than one SIBLOCK level holds: a stated limit, checked before writing.
        var entries: [(nid: UInt32, data: UInt64, sub: UInt64)] = []
        for i in 0..<(510 * 340 + 1) {
            let nid = UInt32(0x20 + i * 32) | 0x5
            entries.append((nid: nid, data: UInt64(4), sub: UInt64(0)))
        }
        XCTAssertThrowsError(try w.subnodeTree(entries)) { error in
            guard case PSTSpecWriter.WriteError.formatLimit? = error as? PSTSpecWriter.WriteError else { return XCTFail("\(error)") }
        }
    }
}
