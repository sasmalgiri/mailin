//
//  NSFODSDepthTests.swift
//  ArchiveCoreTests
//
//  R6 (audit, NSF row): what the public SampleNSF.nsf cannot show, on a
//  database built byte by byte here — the ODS structures the reader walks
//  (header, CX-coded superblock with TWO summary bucket descriptor pages,
//  CX-coded BDB with the name table, an RRV bucket, summary buckets, object
//  records) holding:
//   • folders: ($Inbox), a nested user folder "Projects\2015", an empty
//     ($Trash), an empty hidden ($Alarms), and a folder whose ID table is
//     inconsistent (named unread, never guessed);
//   • a mail note in two folders, one in one, one in none;
//   • attachments Huffman-compressed (decoded), LZ1-compressed (named) and
//     longer than their one record (named);
//   • a sealed (encrypted) mail note whose sealed Body stays locked by name;
//   • every mail note sits in a bucket listed on the SECOND descriptor page.
//  Before R6 the reader refused this database ("2 summary … pages; this
//  reader reads one of each"), so every test here fails without the change.
//

import XCTest
@testable import ArchiveCore

final class NSFODSDepthTests: XCTestCase {

    // MARK: - Builder

    /// A minimal ODS 43 database in the layout `NSFODSReader` documents.
    struct Builder {
        struct ItemSpec { let name: String; let cls: UInt8; let type: UInt8; let flags: UInt16; let value: Data }
        struct NoteSpec { let id: UInt32; let noteClass: UInt16; let items: [ItemSpec]; let bucket: Int }

        var notes: [NoteSpec] = []
        var objects: [(id: UInt32, payload: Data, declaredExtra: Int)] = []
        var summaryBuckets = 580
        var summaryPages = 2
        /// Break one descriptor on page 2 (it then points at no bucket).
        var corruptDescriptor: Int?
        let firstID: UInt32 = 0x100

        static func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        static func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

        /// CX stream of literals only: 3 header bits, then (tag 0, 8 bits LSB-first)
        /// per byte; the input is padded with zeros so the bits end on a byte.
        static func cx(_ input: Data) -> (stream: Data, decodedCount: Int) {
            var plain = [UInt8](input)
            while plain.count % 8 != 5 { plain.append(0) }
            var bits: [UInt8] = []
            for b in plain {
                bits.append(0)
                for i in 0..<8 { bits.append((b >> i) & 1) }
            }
            var out = [UInt8](repeating: 0, count: (3 + bits.count) / 8)
            out[0] = 0x04
            for (i, bit) in bits.enumerated() where bit == 1 { out[(i + 3) / 8] |= UInt8(1 << ((i + 3) % 8)) }
            return (Data(out), plain.count)
        }

        func build() -> Data {
            var file = Data(count: 0x1000)
            func align() { while file.count % 256 != 0 { file.append(0) } }
            func put(_ d: Data) -> Int { align(); let at = file.count; file.append(d); return at }
            func set32(_ at: Int, _ v: UInt32) { file.replaceSubrange(at..<(at + 4), with: Self.le32(v)) }
            func set16(_ at: Int, _ v: UInt16) { file.replaceSubrange(at..<(at + 2), with: Self.le16(v)) }

            // Unique name keys.
            var keys: [(String, UInt8, UInt8)] = []
            func key(_ s: ItemSpec) -> Int {
                if let i = keys.firstIndex(where: { $0.0 == s.name && $0.1 == s.cls && $0.2 == s.type }) { return i }
                keys.append((s.name, s.cls, s.type)); return keys.count - 1
            }
            // Note records.
            func record(_ n: NoteSpec) -> Data {
                var table = Data(), values = Data()
                for item in n.items {
                    table += Self.le16(UInt16(key(item))) + Self.le16(item.flags) + Self.le16(UInt16(item.value.count)) + Self.le16(0)
                    values += item.value
                }
                var h = Data(count: 100)
                h.replaceSubrange(0..<2, with: Self.le16(0x0004))
                h.replaceSubrange(2..<6, with: Self.le32(UInt32(100 + table.count + values.count)))
                h.replaceSubrange(6..<10, with: Self.le32(n.id))
                h.replaceSubrange(10..<26, with: Data((0..<16).map { UInt8(truncatingIfNeeded: Int(n.id) &+ $0) }))
                h.replaceSubrange(40..<42, with: Self.le16(n.noteClass))
                h.replaceSubrange(50..<52, with: Self.le16(UInt16(n.items.count)))
                return h + table + values
            }
            // Summary buckets: a note's bucket holds it in slot 1; the rest are empty.
            var bucketPositions: [Int] = []
            for b in 1...summaryBuckets {
                var payload = Data()
                var slots = 0
                if let n = notes.first(where: { $0.bucket == b }) { payload = record(n); slots = 1 }
                var size = 66 + payload.count + 4 * slots
                size = (size + 255) / 256 * 256
                var bucket = Data(count: size)
                bucket[0] = 0x02; bucket[1] = 0x42
                bucket.replaceSubrange(6..<10, with: Self.le32(UInt32(size)))
                bucket.replaceSubrange(44..<48, with: Self.le32(UInt32(slots)))
                if slots == 1 {
                    bucket.replaceSubrange(66..<(66 + payload.count), with: payload)
                    bucket.replaceSubrange((size - 4)..<(size - 2), with: Self.le16(66))
                    bucket.replaceSubrange((size - 2)..<size, with: Self.le16(UInt16(payload.count)))
                }
                bucketPositions.append(put(bucket))
            }
            // Object records (LSIG 0x0007, size, 16 header bytes, payload).
            var objectPositions: [UInt32: Int] = [:]
            for o in objects {
                var rec = Self.le16(0x0007) + Self.le32(UInt32(22 + o.payload.count)) + Data(count: 16)
                rec += o.payload
                objectPositions[o.id] = put(rec)
            }
            // One RRV bucket: 256 entries from firstID.
            let entries = 256
            var rrv = Data(count: 32 + 8 * entries)
            rrv[0] = 0x06; rrv[1] = 0x20
            rrv.replaceSubrange(6..<10, with: Self.le32(firstID))
            for n in notes {
                let e = 32 + 8 * Int((n.id - firstID) / 4)
                rrv.replaceSubrange(e..<(e + 4), with: Self.le32(0x8000_0000 | UInt32(n.bucket)))
                rrv.replaceSubrange((e + 4)..<(e + 8), with: Self.le32(1))
            }
            for (id, pos) in objectPositions {
                let e = 32 + 8 * Int((id - firstID) / 4)
                rrv.replaceSubrange(e..<(e + 4), with: Self.le32(UInt32(pos >> 8)))
            }
            let rrvPos = put(rrv)

            // BDB: RRV descriptor, UNK table, text.
            var text = Data(), unk = Data()
            for (name, cls, type) in keys {
                let bytes = Data(name.utf8)
                unk += Self.le32(UInt32(text.count)) + Self.le16(UInt16(bytes.count)) + Data([type, cls, 0, 0])
                text += bytes
            }
            let bdbBody = Self.le32(UInt32(rrvPos >> 8)) + Self.le32(firstID) + unk + Data(count: 4) + text
            let bdbCX = Self.cx(bdbBody)
            var bdb = Data(count: 66)
            bdb.replaceSubrange(0..<2, with: Self.le16(1)); bdb.replaceSubrange(2..<4, with: Self.le16(2))
            bdb.replaceSubrange(4..<6, with: Self.le16(1))
            bdb.replaceSubrange(6..<10, with: Self.le32(UInt32(bdbCX.decodedCount)))
            bdb.replaceSubrange(10..<14, with: Self.le32(1))
            bdb.replaceSubrange(14..<18, with: Self.le32(UInt32(70 + bdbCX.stream.count + 12)))
            bdb.replaceSubrange(26..<30, with: Self.le32(UInt32(keys.count)))
            bdb.replaceSubrange(34..<38, with: Self.le32(UInt32(text.count)))
            bdb.replaceSubrange(38..<42, with: Self.le32(1))
            bdb += Self.le32(UInt32(bdbCX.stream.count)) + bdbCX.stream + Data(count: 12)
            let bdbPos = put(bdb)

            // Superblock: summary pages filled 570 per page.
            var body = Data(count: summaryPages * 8206)
            for (i, pos) in bucketPositions.enumerated() {
                let at = (i / 570) * 8206 + 224 + 14 * (i % 570)
                let value = corruptDescriptor == i ? UInt32(1) : UInt32(pos >> 8)
                body.replaceSubrange(at..<(at + 4), with: Self.le32(value))
            }
            let sbCX = Self.cx(body)
            var sb = Data(count: 100)
            sb.replaceSubrange(0..<2, with: Self.le16(0x000E))
            sb.replaceSubrange(10..<14, with: Self.le32(UInt32(sbCX.decodedCount)))
            sb.replaceSubrange(14..<18, with: Self.le32(UInt32(summaryBuckets)))
            sb.replaceSubrange(26..<30, with: Self.le32(UInt32(rrv.count)))
            sb.replaceSubrange(60..<64, with: Self.le32(1))
            sb.replaceSubrange(64..<68, with: Self.le32(UInt32(104 + sbCX.stream.count + 12)))
            sb.replaceSubrange(68..<70, with: Self.le16(1))
            sb.replaceSubrange(70..<74, with: Self.le32(UInt32(summaryPages)))
            sb += Self.le32(UInt32(sbCX.stream.count)) + sbCX.stream + Data(count: 12)
            let sbPos = put(sb)
            align()

            // File + database header, DBINFO2 at 0x208.
            set16(0, 0x001A); set32(2, 1024); set32(6, 43)
            set32(0x208 + 40, UInt32(sbPos >> 8)); set32(0x208 + 44, UInt32(sb.count))
            set32(0x208 + 108, UInt32(bdbPos >> 8))
            return file
        }
    }

    // MARK: - Item values

    static func text(_ name: String, _ s: String, flags: UInt16 = 0x000C) -> Builder.ItemSpec {
        .init(name: name, cls: 5, type: 0, flags: flags, value: Data(s.utf8))
    }

    /// CDTEXT runs separated by CDPARAGRAPH, as Notes rich text.
    static func richText(_ s: String, flags: UInt16 = 0x0008) -> Builder.ItemSpec {
        let t = Data(s.utf8)
        var d = Data([0x81, 0x02, 0x85, 0xFF]) + Builder.le16(UInt16(8 + t.count)) + Data(count: 4) + t
        if d.count % 2 == 1 { d.append(0) }
        return .init(name: "Body", cls: 0, type: 1, flags: flags, value: d)
    }

    static func fileItem(_ name: String, rrv: UInt32, compression: UInt16, size: Int) -> Builder.ItemSpec {
        let n = Data(name.utf8)
        var v = Builder.le16(0) + Builder.le32(rrv) + Builder.le16(UInt16(n.count)) + Builder.le16(0)
        v += Builder.le16(compression) + Builder.le16(0) + Builder.le16(0) + Builder.le32(UInt32(size)) + Data(count: 16) + n
        return .init(name: "$FILE", cls: 0, type: 3, flags: 0x000C, value: v)
    }

    static func objectRef(_ name: String, type: UInt16, rrv: UInt32) -> Builder.ItemSpec {
        .init(name: name, cls: 0, type: 3, flags: 0x000C, value: Builder.le16(type) + Builder.le32(rrv))
    }

    /// A folder ID table: (extra, first) runs.
    static func idTable(_ runs: [(UInt8, UInt32)], statedTotal: Int? = nil) -> Data {
        let total = statedTotal ?? runs.reduce(0) { $0 + Int($1.0) + 1 }
        var d = Builder.le32(4) + Builder.le16(UInt16(total)) + Builder.le16(UInt16(runs.count)) + Builder.le16(1) + Data(count: 8)
        for (extra, first) in runs { d.append(extra); d += Builder.le32(first) }
        return d
    }

    /// Notes attachment Huffman, encoded the way the sample's objects are
    /// laid out (checksum, tree size, pairs, MSB-first bits; bit 1 = first).
    static func huffman(_ input: Data) -> Data {
        final class Node {
            let symbol: Int?; let first: Node?; let second: Node?; let weight: Int
            init(symbol: Int?, first: Node? = nil, second: Node? = nil, weight: Int) {
                self.symbol = symbol; self.first = first; self.second = second; self.weight = weight
            }
        }
        var freq: [Int: Int] = [256: 1]
        for b in input { freq[Int(b), default: 0] += 1 }
        var queue = freq.sorted { $0.key < $1.key }.map { Node(symbol: $0.key, weight: $0.value) }
        while queue.count > 1 {
            queue.sort { $0.weight < $1.weight }
            let a = queue.removeFirst(), b = queue.removeFirst()
            queue.append(Node(symbol: nil, first: a, second: b, weight: a.weight + b.weight))
        }
        var nodes: [Node] = [queue[0]]
        var pairs: [(Int, Int)] = []
        var i = 0
        while i < nodes.count {
            let n = nodes[i]
            func ref(_ c: Node) -> Int {
                if let s = c.symbol { return s }
                nodes.append(c); return -(nodes.count - 1)
            }
            let f = ref(n.first!), s = ref(n.second!)
            pairs.append((f, s)); i += 1
        }
        var codes: [Int: [UInt8]] = [:]
        func walk(_ n: Node, _ path: [UInt8]) {
            if let s = n.symbol { codes[s] = path; return }
            walk(n.first!, path + [1]); walk(n.second!, path + [0])
        }
        walk(queue[0], [])
        var bits: [UInt8] = []
        for b in input { bits += codes[Int(b)]! }
        bits += codes[256]!
        var stream = [UInt8](repeating: 0, count: (bits.count + 7) / 8)
        for (k, bit) in bits.enumerated() where bit == 1 { stream[k / 8] |= UInt8(0x80 >> (k % 8)) }
        var out = Builder.le32(input.reduce(UInt32(0)) { $0 &+ UInt32($1) }) + Builder.le16(UInt16(4 * pairs.count))
        for (f, s) in pairs { out += Builder.le16(UInt16(bitPattern: Int16(f))) + Builder.le16(UInt16(bitPattern: Int16(s))) }
        return out + Data(stream)
    }

    // MARK: - The database

    static let huffText = Data("Notes keeps attachments Huffman-coded: hello hello hello, folders and all.".utf8)
    static let mailA: UInt32 = 0x200, mailB: UInt32 = 0x204, mailC: UInt32 = 0x208

    static func database(summaryPages: Int = 2, corruptDescriptor: Int? = nil) -> Data {
        var b = Builder()
        b.summaryPages = summaryPages
        b.corruptDescriptor = corruptDescriptor
        // Objects: folder tables and attachments.
        b.objects = [
            (0x300, idTable([(1, mailA)]), 0),                     // Inbox: A, B (one run of 2)
            (0x304, idTable([(0, mailA), (3, 0x400)]), 0),         // Projects\2015: A, plus 4 IDs of no note
            (0x308, idTable([]), 0),                               // Trash: empty
            (0x30C, idTable([]), 0),                               // ($Alarms): empty, hidden
            (0x310, idTable([(1, mailB)], statedTotal: 5), 0),     // Broken: runs say 2, table says 5
            (0x320, huffman(huffText), 0),                         // Huffman attachment
            (0x324, Data(repeating: 0x5A, count: 40), 0),          // LZ1 attachment (bytes not decodable)
            (0x328, Data(repeating: 0x41, count: 100), 0),         // first record of a 300-byte file
        ]
        func folder(_ id: UInt32, _ title: String, _ table: UInt32, bucket: Int) -> Builder.NoteSpec {
            .init(id: id, noteClass: 0x0008, items: [text("$TITLE", title), text("$Flags", "3FY"),
                                                      objectRef("$FolderIDTable", type: 0x000A, rrv: table)], bucket: bucket)
        }
        b.notes = [
            folder(0x110, "($Inbox)", 0x300, bucket: 3),
            folder(0x114, "Projects\\2015|proj", 0x304, bucket: 4),
            folder(0x118, "($Trash)", 0x308, bucket: 5),
            folder(0x11C, "($Alarms)", 0x30C, bucket: 6),
            folder(0x120, "Broken", 0x310, bucket: 7),
            // A view (no "F" in $Flags) is not a folder.
            .init(id: 0x124, noteClass: 0x0008, items: [text("$TITLE", "($All)"), text("$Flags", "Y")], bucket: 8),
            .init(id: mailA, noteClass: 0x0001, items: [
                text("Form", "Memo"), text("From", "Ana <ana@example.org>"), text("SendTo", "bo@example.org"),
                text("Subject", "Folders and attachments"), richText("Body text of A"),
                fileItem("notes.txt", rrv: 0x320, compression: 1, size: huffText.count),
                fileItem("old.doc", rrv: 0x324, compression: 2, size: 120),
                fileItem("big.bin", rrv: 0x328, compression: 0, size: 300),
            ], bucket: 575),
            .init(id: mailB, noteClass: 0x0001, items: [
                text("Form", "Memo"), text("From", "bo@example.org"), text("Subject", "Inbox only"), richText("B"),
            ], bucket: 576),
            .init(id: mailC, noteClass: 0x0001, items: [
                text("Form", "Memo"), text("From", "cy@example.org"), text("Subject", "Sealed one"),
                .init(name: "$Seal", cls: 0, type: 9, flags: 0x0008, value: Data(repeating: 0xC3, count: 24)),
                richText("ciphertext-looking", flags: 0x000A),
            ], bucket: 577),
        ]
        return b.build()
    }

    private func write(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("r6-\(UUID().uuidString).nsf")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: - Tests

    func testTwoSummaryDescriptorPages_followed_mailInBucketsOfPage2Read() throws {
        let data = Self.database()
        let reader = try NSFODSReader(data: data)
        XCTAssertEqual(reader.summaryDescriptorPages, 2)
        XCTAssertEqual(reader.summaryBucketCount, 580, "570 from page 1, 10 from page 2")
        let result = try NSFODSParser.read(fileURL: try write(data), senderEmail: "")
        XCTAssertEqual(result.inventory.mailNotes, 3)
        XCTAssertEqual(result.inventory.mailRead, 3)
        XCTAssertEqual(result.inventory.summaryDescriptorPages, 2)
        XCTAssertEqual(Set(result.emails.compactMap { $0.headers["Subject"] }), ["Folders and attachments", "Inbox only", "Sealed one"])
    }

    func testDescriptorOnPage2PointingAtNoBucket_refusedWithTheReason() {
        XCTAssertThrowsError(try NSFODSReader(data: Self.database(corruptDescriptor: 572))) { error in
            XCTAssertTrue(error.localizedDescription.contains("580 summary bucket descriptors on 2 page(s) do not all point at a bucket"),
                          error.localizedDescription)
        }
    }

    func testFolders_nestedPaths_multipleMemberships_emptyAndUnreadFoldersNamed() async throws {
        let url = try write(Self.database())
        let result = try NSFODSParser.read(fileURL: url, senderEmail: "")
        let bySubject = Dictionary(uniqueKeysWithValues: result.emails.map { ($0.headers["Subject"] ?? "", $0) })
        XCTAssertEqual(bySubject["Folders and attachments"]?.folderPath, "Inbox")
        XCTAssertEqual(bySubject["Folders and attachments"]?.tags, ["Projects/2015"], "second folder → second membership")
        XCTAssertEqual(bySubject["Inbox only"]?.folderPath, "Inbox")
        XCTAssertEqual(bySubject["Inbox only"]?.tags, [])
        XCTAssertNil(bySubject["Sealed one"]?.folderPath)
        if let a = bySubject["Folders and attachments"] {
            XCTAssertEqual(SQLiteEmailStore.folderPaths(for: a), ["Inbox", "Projects/2015"])
        }

        let inv = result.inventory
        XCTAssertEqual(inv.folders, 5, "five folder design notes; the ($All) view is not one")
        XCTAssertEqual(inv.foldersRead, 4)
        XCTAssertEqual(inv.foldersUnread, ["Broken": "its ID table's runs hold 2 IDs, the table says 5"])
        XCTAssertEqual(inv.mailInFolders, 2)
        XCTAssertEqual(inv.mailWithoutFolder, 1)
        XCTAssertEqual(result.declaredFolders, ["Inbox", "Projects/2015", "Trash"], "hidden ($Alarms) is not declared while empty")

        // The import path carries the folders too.
        NotesODSPolicy.isEnabled = true
        defer { NotesODSPolicy.isEnabled = false }
        var streamed: [MBOXParser.RawEmail] = []
        let report = try await ParserFactory.parseStreamingCallback(fileURL: url, senderEmail: "", batchSize: 2,
                                                                    materializeAttachments: false) { streamed += $0 }
        XCTAssertEqual(report.successfullyParsed, 3)
        XCTAssertEqual(report.declaredFolders, ["Inbox", "Projects/2015", "Trash"])
        XCTAssertEqual(streamed.compactMap(\.folderPath).sorted(), ["Inbox", "Inbox"])
    }

    func testAttachments_huffmanDecoded_lz1AndMultiRecordNamed() throws {
        let result = try NSFODSParser.read(fileURL: try write(Self.database()), senderEmail: "")
        let a = try XCTUnwrap(result.emails.first { $0.headers["Subject"] == "Folders and attachments" })
        XCTAssertEqual(a.attachments.map(\.filename), ["notes.txt"])
        let bytes = try XCTUnwrap(a.attachments.first?.base64.flatMap { Data(base64Encoded: $0) }
                                  ?? a.attachments.first?.fileURL.flatMap { try? Data(contentsOf: $0) })
        XCTAssertEqual(bytes, Self.huffText)
        XCTAssertTrue(a.anomalies.contains { $0.contains("old.doc") && $0.contains("LZ1-compressed") }, "\(a.anomalies)")
        XCTAssertTrue(a.anomalies.contains { $0.contains("big.bin") && $0.contains("holds 100 of 300 bytes") }, "\(a.anomalies)")
        XCTAssertEqual(result.inventory.attachmentObjectsDecoded, 1)
        XCTAssertEqual(result.inventory.attachmentObjectsHuffman, 1)
        XCTAssertEqual(result.inventory.attachmentObjectsNotDecoded, 2)
    }

    func testHuffman_damagedStreamOrChecksum_refusedNotReturned() {
        var packed = Self.huffman(Self.huffText)
        XCTAssertEqual(try NotesHuffman.decompress(packed, expectedSize: Self.huffText.count), Self.huffText)
        XCTAssertThrowsError(try NotesHuffman.decompress(packed, expectedSize: Self.huffText.count + 1), "size must match")
        packed[0] ^= 0x01                                   // checksum
        XCTAssertThrowsError(try NotesHuffman.decompress(packed, expectedSize: Self.huffText.count))
    }

    func testSealedMail_sealedItemsNamedLocked_neverReadAsText() throws {
        let result = try NSFODSParser.read(fileURL: try write(Self.database()), senderEmail: "")
        let c = try XCTUnwrap(result.emails.first { $0.headers["Subject"] == "Sealed one" })
        XCTAssertEqual(result.inventory.sealedMailNotes, 1)
        XCTAssertTrue(c.anomalies.contains { $0.contains("encrypted (sealed)") && $0.contains("Body stay locked") && $0.contains("Notes ID file") },
                      "\(c.anomalies)")
        XCTAssertFalse(c.plainBody.contains("ciphertext-looking"))
        XCTAssertFalse(c.rawSource.contains("ciphertext-looking"))
        XCTAssertEqual(c.headers["From"], "cy@example.org", "unsealed summary items still read")
    }

    func testFolderTitles_mapToArchivePaths() {
        XCTAssertEqual(NotesFolders.path(forTitle: "($Inbox)")?.path, "Inbox")
        XCTAssertEqual(NotesFolders.path(forTitle: "($JunkMail)|JunkMail")?.path, "Junk Mail")
        XCTAssertEqual(NotesFolders.path(forTitle: "(Sent)|IMAPSent")?.path, "Sent")
        XCTAssertEqual(NotesFolders.path(forTitle: "Clients\\Acme\\2015|acme")?.path, "Clients/Acme/2015")
        XCTAssertEqual(NotesFolders.path(forTitle: "Q1/Q2 plans")?.path, "Q1-Q2 plans", "a slash in one name is not nesting")
        XCTAssertEqual(NotesFolders.path(forTitle: "($Alarms)")?.path, "Alarms")
        XCTAssertEqual(NotesFolders.path(forTitle: "($Alarms)")?.hidden, true)
        XCTAssertNil(NotesFolders.path(forTitle: ""))
    }
}
