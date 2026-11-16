//
//  NSFODSReader.swift
//  ArchiveCore
//
//  GAP-NSF (owner decision 2026-11-07): a reader for the real Notes on-disk
//  structure (ODS), written beside the old heuristic `NSFParser` (rule 14 —
//  the old path is untouched and stays the default). Switch:
//  `NotesODSPolicy.isEnabled` (preview, OFF by default, rule 15).
//
//  What it reads, in the order Notes lays it out:
//   1. File header (0x1A 0x00) and the 1,024-byte database header: ODS
//      version, the four superblock positions and the two bucket descriptor
//      block (BDB) positions.
//   2. The superblock with the highest write count (CX-compressed): the
//      summary / non-summary bucket position tables and the current data
//      RRV bucket (the on-disk copy of that bucket can be stale — on the
//      public SampleNSF.nsf it is all 0xFF).
//   3. The BDB with the highest write count (CX-compressed): the RRV bucket
//      descriptors and the unique-name-key (UNK) table — item names, types.
//   4. Every RRV bucket: note ID → (summary bucket, slot) or → file position
//      (objects: attachments and other non-note records).
//   5. Each note: the 100-byte header (class, flags, item count, non-summary
//      record), the item table, summary values in the bucket slot and
//      non-summary values in the record the header names.
//
//  Mail notes (class DOCUMENT; Form Memo/Reply or no Form, with From or
//  SendTo) become one RFC 5322 message each:
//   • native-MIME mail ($NoteHasNativeMIME): the RFC822_TEXT items are the
//     original header lines, the MIME_PART items the original parts in
//     order; a part stored in an attachment object (MIME_PART flag
//     BODY_IN_DBOBJECT) gets that object's bytes back. 8-bit/binary part
//     content is carried as base64 (Content-Transfer-Encoding rewritten) so
//     the text round-trip through `processRawMessage` is lossless.
//   • Notes rich-text mail (Body is TYPE_COMPOSITE): header fields from
//     From/SendTo/CopyTo/BlindCopyTo/Subject/PostedDate/$MessageID; the CD
//     records' text runs (CDTEXT) and paragraph breaks become a text/plain
//     body; $FILE attachments are added as base64 parts. Tables, fonts,
//     links and embedded images in the CD stream are NOT rendered.
//  Everything else is counted out by class or form in `Inventory`, never
//  dropped silently. What a mail note could not give back is named per
//  message in `RawEmail.anomalies` ("NSF ODS: …").
//
//  Also read (R6, 2026-11-09): folder membership from each folder design
//  note's $FolderIDTable object (`NotesFolders`, NSFODSFolders.swift);
//  Huffman-compressed attachment objects (`NotesHuffman`); every bucket
//  descriptor page the superblock declares.
//
//  NOT read (stated in the format registry): LZ1-compressed attachment
//  objects (no public description, no sample) and objects longer than their
//  one record (no public description of the continuation, none in the
//  sample) — named on the message, bytes not returned; sealed (encrypted)
//  items — they need the owner's Notes ID file; named on the message.
//
//  Sources (URLs in Tests/ArchiveCoreTests/Fixtures/NSF_ODS_SOURCES.md):
//  Joachim Metz, "Notes Storage Facility (NSF) database file format"
//  (libyal/libnsfdb documentation, GFDL); the libnsfdb C sources (LGPL,
//  read for understanding only — no code copied); the HCL/IBM Notes C API
//  reference for TIMEDATE, FILEOBJECT, MIME_PART, RFC822ITEMDESC and CD
//  record signatures; and what the public sample itself shows, every
//  layout claim checked there (NSFODSReaderTests).
//

import Foundation
import os

/// Pushed by CapabilityWiring (the app's `notesODSReader` capability, preview).
/// OFF: `.nsf` files are read by the old heuristic `NSFParser`, as before.
public enum NotesODSPolicy {
    nonisolated(unsafe) public static var isEnabled = false
}

// MARK: - CX (Notes "Huffman") decompression

/// The CX bit-stream used for superblocks and bucket descriptor blocks:
/// tag bits LSB-first; 0 = literal byte, 1 = back reference with a
/// variable-length length and an optional extended offset. Written from the
/// format description; verified by decoding the public sample's superblocks
/// (output length equals the declared uncompressed size, bucket tables that
/// point at real bucket signatures) and its BDB (UNK names readable).
enum NotesCX {
    struct DecodeError: Error {}

    static func decompress(_ input: Data, limit: Int) throws -> Data {
        let bytes = [UInt8](input)
        let n = bytes.count
        guard n > 0, bytes[0] & 0x07 > 3 else { throw DecodeError() }
        var out = [UInt8]()
        out.reserveCapacity(min(limit, 1 << 22))
        var pos = 0
        var bit = 3

        func word() -> Int { Int(bytes[pos]) | (pos + 1 < n ? Int(bytes[pos + 1]) << 8 : 0) }
        func nextBit() -> Int {
            let b = (Int(bytes[pos]) >> bit) & 1
            bit += 1
            if bit >= 8 { bit = 0; pos += 1 }
            return b
        }
        func nextByte() -> UInt8 {
            let v = (word() >> bit) & 0xFF
            pos += 1
            return UInt8(v)
        }
        /// A value whose width is the number of zero bits that precede it.
        func nextVariable() throws -> Int {
            guard pos < n else { throw DecodeError() }
            var v = ((word() >> bit) & 0xFF) | 0x100
            var width = 1
            while v & 1 == 0 { v >>= 1; width += 1 }
            bit += width
            if bit >= 8 { bit &= 7; pos += 1 }
            guard pos < n else { throw DecodeError() }
            var value = Int(bytes[pos]) >> bit
            bit += width
            if bit >= 8 && pos + 1 < n {
                value |= Int(bytes[pos + 1]) << (8 + width - bit)
                bit &= 7
                pos += 1
            }
            let mask = (1 << width) - 1
            return mask + (value & mask)
        }

        while pos < n {
            if nextBit() == 0 {
                guard pos < n else { break }
                out.append(nextByte())
            } else {
                guard pos < n else { break }
                var length = 0
                var offset = 0
                if nextBit() == 0 { length = try nextVariable() }
                length += 2
                if length >= 0x102 { break }                 // end marker
                if length > 2 {
                    guard pos < n else { throw DecodeError() }
                    if nextBit() == 0 { offset = try nextVariable() << 8 }
                }
                guard pos < n else { throw DecodeError() }
                offset |= Int(nextByte())
                guard offset > 0, offset <= out.count else { throw DecodeError() }
                for _ in 0..<length { out.append(out[out.count - offset]) }
            }
            if out.count > limit { throw DecodeError() }
        }
        return Data(out)
    }
}

// MARK: - The ODS reader

struct NSFODSReader {
    /// Bump when extraction or ordering changes (resume checkpoints, B5).
    static let parserVersion = 2

    enum ReadError: LocalizedError {
        case notNSF(String)
        case unsupported(String)
        case damaged(String)

        /// Refused for its layout (not a Notes database, or a header this reader does not read) — the
        /// earlier reader is tried. Damage inside a real ODS database is not a refusal: it is reported.
        var isLayoutRefusal: Bool {
            switch self {
            case .notNSF, .unsupported: return true
            case .damaged: return false
            }
        }

        var errorDescription: String? {
            switch self {
            case .notNSF(let why): return "Not a Notes database: \(why)"
            case .unsupported(let why): return "Notes database layout not supported: \(why)"
            case .damaged(let why): return "Notes database structure unreadable: \(why)"
            }
        }
    }

    /// What the database holds, every note accounted for.
    struct Inventory: Equatable, Sendable {
        var odsVersion = 0
        var rrvBuckets = 0
        /// RRV entries that point somewhere (a bucket slot or a file position).
        var rrvEntries = 0
        /// Entries resolving to a note header that carries the same note ID.
        var noteRecords = 0
        /// File-position entries: attachment objects and other non-note records.
        var objects = 0
        /// Entries whose target does not carry their note ID (stale or damaged).
        var unresolvedEntries: [UInt32] = []
        /// Design notes (forms, views, agents, …) by note class.
        var designNotesByClass: [UInt16: Int] = [:]
        /// 64-byte deletion stubs (no items, nothing to read).
        var deletionStubs = 0
        /// Documents with a full header but no items.
        var emptyDocuments = 0
        /// Documents that are not mail, by Form ("" when the note has none).
        var otherDocumentsByForm: [String: Int] = [:]
        /// Documents whose item values could not be placed (named, not read).
        var unplacedDocuments: [UInt32] = []
        /// Of those, the ones the placement search gave up on at its step limit.
        var unplacedAtStepLimit: [UInt32] = []
        /// Mail notes found / turned into messages / failed (note ID → reason).
        var mailNotes = 0
        var mailRead = 0
        var mailFailed: [UInt32: String] = [:]
        /// Mail notes whose body is native MIME vs Notes rich text.
        var nativeMIMEMail = 0
        var richTextMail = 0
        /// Attachment objects decoded / named as not decoded.
        var attachmentObjectsDecoded = 0
        var attachmentObjectsNotDecoded = 0
        /// Of the decoded ones, how many were Huffman-compressed.
        var attachmentObjectsHuffman = 0
        /// Mail notes sealed (encrypted) for their recipients: the sealed
        /// items need the owner's Notes ID file and are named, not read.
        var sealedMailNotes = 0
        /// Bucket descriptor pages followed (summary / non-summary).
        var summaryDescriptorPages = 0
        var nonSummaryDescriptorPages = 0
        /// Folder design notes found / whose member list was read, and the
        /// ones that could not be read (title → reason).
        var folders = 0
        var foldersRead = 0
        var foldersUnread: [String: String] = [:]
        /// Mail notes given at least one folder / given none.
        var mailInFolders = 0
        var mailWithoutFolder = 0

        var designNotes: Int { designNotesByClass.values.reduce(0, +) }
        var otherDocuments: Int { otherDocumentsByForm.values.reduce(0, +) }
    }

    private static let logger = Logger(subsystem: "com.mailin", category: "NSFODSReader")

    let data: Data
    let odsVersion: Int
    private let summaryBuckets: [Int]
    private let nonSummaryBuckets: [Int]
    private let names: [(name: String, cls: UInt8, type: UInt8)]
    /// Note ID → raw RRV entry, ascending by ID.
    private let rrv: [(id: UInt32, a: UInt32, b: UInt32)]
    let rrvBucketCount: Int
    /// Bucket descriptor pages the superblock declares (each followed).
    let summaryDescriptorPages: Int
    let nonSummaryDescriptorPages: Int

    // MARK: Bucket descriptor pages

    /// One summary page is 8,206 bytes with its descriptors (14 bytes each)
    /// from offset 224; one non-summary page 8,198 bytes with descriptors
    /// (6 bytes each) from offset 70 — the layout the format notes give and
    /// the public sample (one summary page, 76 buckets) confirms.
    struct DescriptorLayout {
        let pageSize: Int
        let tableOffset: Int
        let entrySize: Int
        /// Descriptors one page can hold, most likely first: what physically
        /// fits after the table offset, then the group-based figures the
        /// format notes suggest (21 groups / 32 groups per page).
        let capacities: [Int]

        static let summary = DescriptorLayout(
            pageSize: 8206, tableOffset: 224, entrySize: 14,
            capacities: [570] + (18...27).reversed().map { 21 * $0 })
        static let nonSummary = DescriptorLayout(
            pageSize: 8198, tableOffset: 70, entrySize: 6,
            capacities: [1354] + (34...42).reversed().map { 32 * $0 })
    }

    /// Bucket file positions from `pages` consecutive descriptor pages.
    /// With more than one page, how many descriptors each page holds is not
    /// stated in any source; pages are filled in order, and a page capacity
    /// is accepted only when every descriptor it yields points at a bucket
    /// signature (02 42) in the file — otherwise nil (the database is refused
    /// with that reason, never read with guessed buckets).
    static func descriptorPositions(_ body: Data, start: Int, pages: Int, layout: DescriptorLayout, count: Int,
                                    isBucket: (Int) -> Bool) -> [Int]? {
        guard count > 0, pages > 0 else { return [] }
        guard body.count >= start + pages * layout.pageSize else { return nil }
        func read(capacity: Int) -> [Int]? {
            guard layout.tableOffset + layout.entrySize * capacity <= layout.pageSize,
                  capacity * pages >= count, capacity * (pages - 1) < count else { return nil }
            var out: [Int] = []
            out.reserveCapacity(count)
            for i in 0..<count {
                let page = i / capacity, slot = i % capacity
                let pos = Int(u32(body, start + page * layout.pageSize + layout.tableOffset + layout.entrySize * slot)) << 8
                guard isBucket(pos) else { return nil }
                out.append(pos)
            }
            return out
        }
        if pages == 1 {
            return layout.tableOffset + layout.entrySize * count <= layout.pageSize ? read(capacity: count) : nil
        }
        for capacity in layout.capacities {
            if let positions = read(capacity: capacity) { return positions }
        }
        return nil
    }

    // MARK: Opening

    init(data: Data) throws {
        self.data = data
        guard data.count >= 0x1000 else { throw ReadError.notNSF("file too small") }
        guard Self.u16(data, 0) == 0x001A else { throw ReadError.notNSF("no 0x1A00 signature") }
        guard Self.u32(data, 2) == 1024 else {
            throw ReadError.unsupported("database header size \(Self.u32(data, 2)), expected 1024")
        }
        odsVersion = Int(Self.u32(data, 6))

        // DBINFO2 starts at 0x208 in the 1,024-byte header (measured on the
        // public sample: superblock 1 at 0x400 and 2 at 0x8400, the positions
        // the format notes say are usual).
        let info2 = 0x208
        var superblocks: [(offset: Int, limit: Int)] = []
        for i in 0..<4 {
            let pos = Int(Self.u32(data, info2 + 40 + 8 * i)) << 8
            let size = Int(Self.u32(data, info2 + 44 + 8 * i))
            if pos > 0 && pos + 100 < data.count { superblocks.append((pos, size)) }
        }
        var bdbs: [Int] = []
        for i in 0..<2 {
            let pos = Int(Self.u32(data, info2 + 108 + 8 * i)) << 8
            if pos > 0 && pos + 66 < data.count { bdbs.append(pos) }
        }

        // Superblock: highest write count that decodes.
        var best: (writeCount: UInt32, offset: Int, body: Data)?
        for sb in superblocks where Self.u16(data, sb.offset) == 0x000E {
            let stored = Int(Self.u32(data, sb.offset + 64))
            let uncompressed = Int(Self.u32(data, sb.offset + 10))
            let compression = Self.u16(data, sb.offset + 68)
            guard stored > 116, sb.offset + stored <= data.count, compression == 1 else { continue }
            let packed = data.subdata(in: (sb.offset + 104)..<(sb.offset + stored - 12))
            guard let body = try? NotesCX.decompress(packed, limit: uncompressed), body.count == uncompressed else { continue }
            let wc = Self.u32(data, sb.offset + 60)
            if best == nil || wc > best!.writeCount { best = (wc, sb.offset, body) }
        }
        guard let sb = best else { throw ReadError.damaged("no superblock decodes") }
        let sbo = sb.offset
        let summaryCount = Int(Self.u32(data, sbo + 14))
        let nonSummaryCount = Int(Self.u32(data, sbo + 18))
        let bitmapCount = Int(Self.u32(data, sbo + 22))
        let rrvBucketSize = Int(Self.u32(data, sbo + 26))
        let summaryPages = Int(Self.u32(data, sbo + 70))
        let nonSummaryPages = Int(Self.u32(data, sbo + 74))
        guard rrvBucketSize >= 64 else { throw ReadError.damaged("RRV bucket size \(rrvBucketSize)") }
        let body = sb.body
        let isBucket: (Int) -> Bool = { pos in pos + 66 <= data.count && data[pos] == 0x02 && data[pos + 1] == 0x42 }
        guard let summary = Self.descriptorPositions(
            body, start: 0, pages: summaryPages, layout: .summary, count: summaryCount, isBucket: isBucket) else {
            throw ReadError.damaged("\(summaryCount) summary bucket descriptors on \(summaryPages) page(s) do not all point at a bucket")
        }
        var cursor = summaryPages * DescriptorLayout.summary.pageSize
        guard let nonSummary = Self.descriptorPositions(
            body, start: cursor, pages: nonSummaryPages, layout: .nonSummary, count: nonSummaryCount, isBucket: isBucket) else {
            throw ReadError.damaged("\(nonSummaryCount) non-summary bucket descriptors on \(nonSummaryPages) page(s) do not all point at a bucket")
        }
        cursor += nonSummaryPages * DescriptorLayout.nonSummary.pageSize
        cursor += 20 * bitmapCount
        var currentRRV: Data?
        if body.count >= cursor + rrvBucketSize, body[cursor] == 0x06, body[cursor + 1] == 0x20 {
            currentRRV = body.subdata(in: cursor..<(cursor + rrvBucketSize))
        }
        summaryBuckets = summary
        nonSummaryBuckets = nonSummary
        summaryDescriptorPages = summaryPages
        nonSummaryDescriptorPages = nonSummaryPages

        // BDB: highest write count that decodes.
        var bestBDB: (writeCount: UInt32, offset: Int, body: Data)?
        for off in bdbs where Self.u16(data, off) == 0x0001 && Self.u16(data, off + 2) == 0x0002 && Self.u16(data, off + 4) == 1 {
            let stored = Int(Self.u32(data, off + 14))
            let uncompressed = Int(Self.u32(data, off + 6))
            guard stored > 82, off + stored <= data.count else { continue }
            let packed = data.subdata(in: (off + 70)..<(off + stored - 12))
            guard let body = try? NotesCX.decompress(packed, limit: max(uncompressed, 1)) else { continue }
            let wc = Self.u32(data, off + 10)
            if bestBDB == nil || wc > bestBDB!.writeCount { bestBDB = (wc, off, body) }
        }
        guard let bdb = bestBDB else { throw ReadError.damaged("no bucket descriptor block decodes") }
        let rrvDescriptorCount = Int(Self.u32(data, bdb.offset + 38))
        let unkCount = Int(Self.u32(data, bdb.offset + 26))
        let unkTextSize = Int(Self.u32(data, bdb.offset + 34))
        let bd = bdb.body
        let entries = 8 * rrvDescriptorCount
        let textStart = entries + 10 * unkCount + 4
        guard textStart + unkTextSize <= bd.count else { throw ReadError.damaged("unique name key table") }
        var unk: [(String, UInt8, UInt8)] = []
        unk.reserveCapacity(unkCount)
        for i in 0..<unkCount {
            let e = entries + 10 * i
            let off = Int(Self.u32(bd, e)), len = Int(Self.u16(bd, e + 4))
            guard off + len <= unkTextSize else { throw ReadError.damaged("unique name key \(i)") }
            let name = LMBCS.decode(bd.subdata(in: (textStart + off)..<(textStart + off + len)))
            unk.append((name, bd[e + 7], bd[e + 6]))
        }
        names = unk.map { (name: $0.0, cls: $0.1, type: $0.2) }

        // RRV buckets; the superblock's current copy replaces the on-disk one with the same first ID.
        var table: [(UInt32, UInt32, UInt32)] = []
        var bucketCount = 0
        let currentFirst = currentRRV.map { Self.u32($0, 6) }
        for i in 0..<rrvDescriptorCount {
            let pos = Int(Self.u32(bd, 8 * i) & ~1) << 8
            let first = Self.u32(bd, 8 * i + 4)
            let bucket: Data
            if let current = currentRRV, currentFirst == first {
                bucket = current
            } else {
                guard pos + rrvBucketSize <= data.count, data[pos] == 0x06, data[pos + 1] == 0x20 else {
                    throw ReadError.damaged("RRV bucket \(i) at \(pos)")
                }
                bucket = data.subdata(in: pos..<(pos + rrvBucketSize))
            }
            bucketCount += 1
            var id = Self.u32(bucket, 6)
            var e = 32
            while e + 8 <= bucket.count {
                table.append((id, Self.u32(bucket, e), Self.u32(bucket, e + 4)))
                id &+= 4
                e += 8
            }
        }
        table.sort { $0.0 < $1.0 }
        rrv = table.map { (id: $0.0, a: $0.1, b: $0.2) }
        rrvBucketCount = bucketCount
    }

    // MARK: Locating records

    enum Target: Equatable {
        case note(offset: Int, size: Int)
        case object(offset: Int)
    }

    static func entryTarget(a: UInt32, b: UInt32) -> (bucket: Int, slot: Int)? {
        guard a & 0x8000_0000 != 0 else { return nil }
        let bucket = Int(a & 0x00FF_FFFF)
        guard bucket != 0, bucket != 0x00FF_FFFF else { return nil }
        return (bucket, Int(b & 0x7FF))
    }

    private func target(a: UInt32, b: UInt32) -> Target? {
        if let (bucket, slot) = Self.entryTarget(a: a, b: b) {
            guard bucket - 1 < summaryBuckets.count, let s = slotRange(bucketOffset: summaryBuckets[bucket - 1], slot: slot) else { return nil }
            return .note(offset: s.offset, size: s.size)
        }
        guard a != 0, a != 0x7FFF_FFFF, a != 0xFFFF_FFFF else { return nil }
        let pos = Int(a) << 8
        guard pos + 6 <= data.count else { return nil }
        return .object(offset: pos)
    }

    private func slotRange(bucketOffset b: Int, slot: Int) -> (offset: Int, size: Int)? {
        guard slot >= 1, b + 66 <= data.count else { return nil }
        let size = Int(Self.u32(data, b + 6)), slots = Int(Self.u32(data, b + 44)), footer = Int(Self.u32(data, b + 50))
        let end = b + size - footer
        guard slot <= slots, end <= data.count, end - 4 * slot >= b + 66 else { return nil }
        let off = Int(Self.u16(data, end - 4 * slot)), len = Int(Self.u16(data, end - 4 * slot + 2))
        guard b + off + len <= b + size else { return nil }
        return (b + off, len)
    }

    func object(rrvID: UInt32) -> Int? {
        var lo = 0, hi = rrv.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if rrv[mid].id == rrvID {
                if case .object(let off)? = target(a: rrv[mid].a, b: rrv[mid].b) { return off }
                return nil
            }
            if rrv[mid].id < rrvID { lo = mid + 1 } else { hi = mid - 1 }
        }
        return nil
    }

    // MARK: Notes

    struct Item {
        let name: String
        /// Full Notes type word (class << 8 | type), after any stored type word.
        let type: UInt16
        let flags: UInt16
        let value: Data
    }

    struct Note {
        let id: UInt32
        let noteClass: UInt16
        let statusFlags: UInt16
        let items: [Item]
        /// The 100-byte note header as stored (parent ID at 80, folder
        /// reference count at 86, folder note ID at 94).
        var header = Data()

        func first(_ name: String) -> Item? { items.first { $0.name == name } }
        func all(_ name: String) -> [Item] { items.filter { $0.name == name } }
    }

    enum Record {
        case note(Note)
        case design(id: UInt32, noteClass: UInt16)
        case deletionStub(id: UInt32)
        case empty(id: UInt32)
        case unplaced(id: UInt32)
        /// Unplaced because the placement search passed `placementStepLimit`
        /// (a hostile item table) — named with that reason in the import.
        case unplacedAtStepLimit(id: UInt32)
        case object
        case unresolved(id: UInt32)
    }

    /// Records in ascending note-ID order, one at a time (OPEN-02).
    struct Cursor { var index = 0 }

    var entryCount: Int { rrv.count }

    /// Any note record (design notes too) by ID, with its items; nil for
    /// stubs, objects and entries whose target does not carry that ID.
    func note(id: UInt32) -> Note? {
        var lo = 0, hi = rrv.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if rrv[mid].id == id {
                guard case .note(let off, let size)? = target(a: rrv[mid].a, b: rrv[mid].b),
                      size >= 100, off + 100 <= data.count, Self.u16(data, off) == 0x0004, Self.u32(data, off + 6) == id,
                      Self.u32(data, off + 2) >= 100, let items = readItems(noteOffset: off, size: size) else { return nil }
                return Note(id: id, noteClass: Self.u16(data, off + 40), statusFlags: Self.u16(data, off + 38), items: items,
                            header: data.subdata(in: off..<(off + 100)))
            }
            if rrv[mid].id < id { lo = mid + 1 } else { hi = mid - 1 }
        }
        return nil
    }

    var summaryBucketCount: Int { summaryBuckets.count }
    /// Every note of one class (design notes: forms, views and folders, …)
    /// with its items; the class is checked in the header before any item
    /// is read.
    func notes(ofClass want: UInt16) -> [Note] {
        rrv.compactMap { e -> Note? in
            guard case .note(let off, let size)? = target(a: e.a, b: e.b), size >= 100, off + 100 <= data.count,
                  Self.u16(data, off) == 0x0004, Self.u32(data, off + 6) == e.id, Self.u32(data, off + 2) >= 100,
                  Self.u16(data, off + 40) & 0x7FFF == want,
                  let items = readItems(noteOffset: off, size: size) else { return nil }
            return Note(id: e.id, noteClass: Self.u16(data, off + 40), statusFlags: Self.u16(data, off + 38), items: items,
                        header: data.subdata(in: off..<(off + 100)))
        }
    }

    /// An object record's bytes after its 22-byte header (LSIG 0x0007), as
    /// far as the record's own length runs.
    func objectPayload(rrvID: UInt32) -> Data? {
        guard let off = object(rrvID: rrvID), Self.u16(data, off) == 0x0007 else { return nil }
        let size = Int(Self.u32(data, off + 2))
        guard size >= 22, off + size <= data.count else { return nil }
        return data.subdata(in: (off + 22)..<(off + size))
    }

    /// The next record that an RRV entry points at, or nil at the end.
    func next(_ cursor: inout Cursor) -> Record? {
        while cursor.index < rrv.count {
            let e = rrv[cursor.index]
            cursor.index += 1
            guard let t = target(a: e.a, b: e.b) else { continue }
            switch t {
            case .object:
                return .object
            case .note(let off, let size):
                guard size >= 64, off + 64 <= data.count, Self.u16(data, off) == 0x0004, Self.u32(data, off + 6) == e.id else {
                    return .unresolved(id: e.id)
                }
                let noteClass = Self.u16(data, off + 40)
                if size < 100 || Self.u32(data, off + 2) < 100 { return .deletionStub(id: e.id) }
                if noteClass & 0x7FFF != 0x0001 { return .design(id: e.id, noteClass: noteClass) }
                if Self.u16(data, off + 50) == 0 { return .empty(id: e.id) }
                let read = readItemsOutcome(noteOffset: off, size: size)
                if read.stepLimit { return .unplacedAtStepLimit(id: e.id) }
                guard let items = read.items else { return .unplaced(id: e.id) }
                return .note(Note(id: e.id, noteClass: noteClass, statusFlags: Self.u16(data, off + 38), items: items,
                                  header: data.subdata(in: off..<(off + 100))))
            }
        }
        return nil
    }

    private struct Entry { let unk: Int; let flags: UInt16; let size: Int }

    /// Item values: summary values follow the item table in the bucket slot,
    /// non-summary values follow the 68-byte header of the record the note
    /// header names, each in item order. On the public sample a few items
    /// sit on the other side of what their ITEM_SUMMARY flag says (e.g. a
    /// non-summary-flagged $MessageID in the slot); the exact non-summary
    /// length the header states decides which, and every RFC822_TEXT and
    /// MIME_PART value must start with its structure version or the
    /// placement is rejected. Up to three such items per note are searched.
    private func readItems(noteOffset off: Int, size: Int) -> [Item]? {
        readItemsOutcome(noteOffset: off, size: size).items
    }

    /// The items, or nil; `stepLimit` when the placement search stopped at its limit.
    private func readItemsOutcome(noteOffset off: Int, size: Int) -> (items: [Item]?, stepLimit: Bool) {
        var stepLimited = false
        let items = placeItems(noteOffset: off, size: size, stepLimited: &stepLimited)
        return (items, stepLimited)
    }

    private func placeItems(noteOffset off: Int, size: Int, stepLimited: inout Bool) -> [Item]? {
        let count = Int(Self.u16(data, off + 50))
        let tableEnd = off + 100 + 8 * count
        guard tableEnd <= off + size else { return nil }
        var entries: [Entry] = []
        entries.reserveCapacity(count)
        for i in 0..<count {
            let p = off + 100 + 8 * i
            let unk = Int(Self.u16(data, p))
            guard unk < names.count else { return nil }
            entries.append(Entry(unk: unk, flags: Self.u16(data, p + 2), size: Int(Self.u16(data, p + 4))))
        }
        let nsID = Self.u32(data, off + 56)
        let nsSize = Int(Self.u32(data, off + 60))
        var nsStart = 0
        var nsBytes = 0
        if nsID != 0 {
            if nsID & 0x8000_0000 != 0 {
                let bucket = Int(nsID & 0x00FF_FFFF), slot = Int((nsID >> 24) & 0x7F)
                guard bucket >= 1, bucket - 1 < nonSummaryBuckets.count,
                      let s = slotRange(bucketOffset: nonSummaryBuckets[bucket - 1], slot: slot) else { return nil }
                nsStart = s.offset
            } else {
                nsStart = Int(nsID) << 8
            }
            guard nsSize >= 68, nsStart + nsSize <= data.count, Self.u16(data, nsStart) == 0x0010,
                  Self.u32(data, nsStart + 6) == Self.u32(data, off + 6) else { return nil }
            nsBytes = nsSize - 68
        }
        let sized = entries.indices.filter { entries[$0].size > 0 }
        var placement: Set<Int>?
        if nsID == 0 {
            placement = Set(sized)
            if !valid(entries, inSummary: placement!, tableEnd: tableEnd, noteEnd: off + size, nsStart: 0) { placement = nil }
        } else {
            let defaultSummary = Set(sized.filter { entries[$0].flags & 0x0004 != 0 })
            let required: [UInt16] = entries.map { e in
                let key = names[e.unk]
                if key.cls == 5, key.type == 2 { return 0x000E }       // RFC822_TEXT / MIME_PART structure version
                if key.cls == 0, key.type == 25 { return 0x0002 }
                return 0
            }
            switch Self.searchPlacement(sizes: entries.map(\.size), defaultSummary: defaultSummary, required: required,
                                        nsBytes: nsBytes, data: data, tableEnd: tableEnd, nsBase: nsStart + 68, noteEnd: off + size,
                                        stepLimit: placementStepLimit,
                                        confirm: { valid(entries, inSummary: $0, tableEnd: tableEnd, noteEnd: off + size, nsStart: nsStart + 68) }) {
            case .placed(let set): placement = set
            case .notFound, .cancelled: break
            case .stepLimit:
                stepLimited = true
                Self.logger.error("NSF ODS: note 0x\(String(Self.u32(self.data, off + 6), radix: 16), privacy: .public) unplaced: the item placement search passed its limit of \(placementStepLimit, privacy: .public) steps (\(count, privacy: .public) items)")
            }
        }
        guard let inSummary = placement else { return nil }
        var items: [Item] = []
        items.reserveCapacity(count)
        var s = tableEnd, n = nsStart + 68
        for (i, e) in entries.enumerated() {
            var value = Data()
            if e.size > 0 {
                if inSummary.contains(i) { value = data.subdata(in: s..<(s + e.size)); s += e.size }
                else { value = data.subdata(in: n..<(n + e.size)); n += e.size }
            }
            let key = names[e.unk]
            var type = UInt16(key.cls) << 8 | UInt16(key.type)
            // A value whose type differs from the name key's carries its own type word.
            if e.flags & 0x0008 == 0, value.count >= 2 {
                let w = Self.u16(value, 0)
                let known: Set<UInt16> = [0x0500, 0x0501, 0x0502, 0x0400, 0x0401, 0x0300, 0x0301]
                if known.contains(w) {
                    type = w; value = value.subdata(in: 2..<value.count)
                } else if key.cls == 0, key.type == 3, value[0] == 0x03 {
                    type = 0x0003; value = value.subdata(in: 2..<value.count)
                }
            }
            items.append(Item(name: key.name, type: type, flags: e.flags, value: value))
        }
        return items
    }

    private func valid(_ entries: [Entry], inSummary: Set<Int>, tableEnd: Int, noteEnd: Int, nsStart: Int) -> Bool {
        var s = tableEnd, n = nsStart
        for (i, e) in entries.enumerated() where e.size > 0 {
            let at: Int
            if inSummary.contains(i) { at = s; s += e.size } else { at = n; n += e.size }
            guard at + e.size <= data.count else { return false }
            let key = names[e.unk]
            if key.cls == 5, key.type == 2, e.size >= 2, Self.u16(data, at) != 0x000E { return false }
            if key.cls == 0, key.type == 25, e.size >= 2, Self.u16(data, at) != 0x0002 { return false }
        }
        return s <= noteEnd
    }

    // MARK: Item placement search (code review 2026-11-16, A18)

    /// Most work one note's placement search may take: 16,777,216 steps (one
    /// step = one item looked at or one candidate weighed — well under a
    /// second). A real note is placed in a few thousand steps; only a hostile
    /// item table reaches this. The note is then reported unplaced (counted in
    /// the import's failures, never dropped silently) and the limit is logged.
    static let placementStepLimit = 1 << 24

    /// This reader's limit (the stated one; tests lower it to reach the path).
    var placementStepLimit = NSFODSReader.placementStepLimit

    /// Import-report category for documents unplaced at the step limit
    /// (a subset of the unplaced documents, never counted twice).
    static let stepLimitCategory = "nsf_document_items_unplaced_step_limit"

    enum PlacementOutcome: Equatable {
        case placed(Set<Int>)
        case notFound
        case stepLimit
        case cancelled
    }

    /// Finds which items' values sit on the other side of what their
    /// ITEM_SUMMARY flag says: no flip, then one, two or three flips whose
    /// sizes make the non-summary length come out exactly — the FIRST such set
    /// in the order of the earlier search (single i, then pairs (i, j) for
    /// each i in item order; then triples in lexicographic order) for which
    /// every RFC822_TEXT / MIME_PART value starts with its structure version.
    ///
    /// The earlier search tried every combination and checked each one over
    /// all items: O(n³–n⁴) for up to 65,535 items, with no way out. Here a
    /// candidate is checked in O(1): an item's position after the flips
    /// depends only on its side and on the summed size change of the flips
    /// before it, so with per-side prefix sums each checked item is one
    /// lookup, and a stretch between two flips is scanned once per size
    /// change (remembered). Candidates come from a by-size index, never by
    /// scanning every pair. The chosen set is still confirmed by `confirm`
    /// (the full check). `stepLimit` bounds hostile tables; cancellation is
    /// honoured.
    ///
    /// - Parameters:
    ///   - sizes: value length per item (0 = no value).
    ///   - defaultSummary: items whose flag says "summary" (sized items only).
    ///   - required: the 16-bit structure version a value must start with, 0 = unchecked.
    static func searchPlacement(sizes: [Int], defaultSummary: Set<Int>, required: [UInt16], nsBytes: Int,
                                data: Data, tableEnd: Int, nsBase: Int, noteEnd: Int,
                                stepLimit: Int = placementStepLimit,
                                confirm: (Set<Int>) -> Bool) -> PlacementOutcome {
        struct Stop: Error { let outcome: PlacementOutcome }
        let sized = sizes.indices.filter { sizes[$0] > 0 }
        let m = sized.count
        var inSummary = [Bool](repeating: false, count: m)
        var delta = [Int](repeating: 0, count: m)
        var summaryBefore = [Int](repeating: 0, count: m)
        var nsBefore = [Int](repeating: 0, count: m)
        var req = [UInt16](repeating: 0, count: m)
        var summaryTotal = 0, nsTotal = 0
        for p in 0..<m {
            let i = sized[p], size = sizes[i]
            inSummary[p] = defaultSummary.contains(i)
            summaryBefore[p] = summaryTotal
            nsBefore[p] = nsTotal
            if inSummary[p] { summaryTotal += size; delta[p] = size } else { nsTotal += size; delta[p] = -size }
            req[p] = size >= 2 ? required[i] : 0
        }
        // Flipping p changes the non-summary length by delta[p]; the flips must add up to `need`.
        let need = nsBytes - nsTotal
        // Every candidate leaves the same lengths on each side (summary: all
        // sizes minus nsBytes), so the bounds part of the full check is the
        // same for all of them: decided once.
        let summaryAfter = summaryTotal + nsTotal - nsBytes
        guard summaryAfter >= 0, tableEnd + summaryAfter <= noteEnd,
              summaryAfter == 0 || tableEnd + summaryAfter <= data.count,
              nsBytes == 0 || nsBase + nsBytes <= data.count else { return .notFound }

        // `d` = summed delta of the flips before p.
        func okStay(_ p: Int, _ d: Int) -> Bool {
            guard req[p] != 0 else { return true }
            return u16(data, inSummary[p] ? tableEnd + summaryBefore[p] - d : nsBase + nsBefore[p] + d) == req[p]
        }
        func okMove(_ p: Int, _ d: Int) -> Bool {
            guard req[p] != 0 else { return true }
            return u16(data, inSummary[p] ? nsBase + nsBefore[p] + d : tableEnd + summaryBefore[p] - d) == req[p]
        }
        var steps = 0
        func step() throws {
            steps += 1
            if steps > stepLimit { throw Stop(outcome: .stepLimit) }
            if steps & 0xFFFF == 0, Task.isCancelled { throw Stop(outcome: .cancelled) }
        }
        func placed(_ flips: [Int]) throws -> Set<Int>? {
            for _ in 0..<(m >> 10) { try step() }                     // the full check is O(n)
            let set = defaultSummary.symmetricDifference(flips.map { sized[$0] })
            return confirm(set) ? set : nil
        }
        // First item failing in place with no flip before it / with all flips before it.
        let firstFailAtZero = (0..<m).first { !okStay($0, 0) } ?? m
        let lastFailAtNeed = (0..<m).last { !okStay($0, need) } ?? -1
        var byDelta: [Int: [Int]] = [:]
        for p in 0..<m { byDelta[delta[p], default: []].append(p) }
        func firstIndex(in list: [Int], after v: Int) -> Int {
            var lo = 0, hi = list.count
            while lo < hi { let mid = (lo + hi) / 2; if list[mid] <= v { lo = mid + 1 } else { hi = mid } }
            return lo
        }
        // Per summed delta: items [from, okUntil) stay valid; `failed` = okUntil itself does not.
        var runs: [Int: (from: Int, okUntil: Int, failed: Bool)] = [:]
        /// The first item in [s, t) that is not valid in place after flips summing to `d`.
        func firstFail(_ d: Int, _ s: Int, _ t: Int) throws -> Int? {
            guard s < t else { return nil }
            var from = s, p = s
            if let r = runs[d], r.from <= s, s <= r.okUntil {
                if r.okUntil >= t { return nil }
                if r.failed { return r.okUntil }
                from = r.from; p = r.okUntil
            }
            while p < t {
                try step()
                if !okStay(p, d) { runs[d] = (from, p, true); return p }
                p += 1
            }
            runs[d] = (from, t, false)
            return nil
        }

        do {
            if need == 0, firstFailAtZero == m, let set = try placed([]) { return .placed(set) }
            // An item before the first flip sees no change, so the first flip
            // is at or before `firstFailAtZero`; the last at or after `lastFailAtNeed`.
            let xEnd = min(m, firstFailAtZero + 1)
            for x in 0..<xEnd {
                try step()
                guard okMove(x, 0) else { continue }
                let d = delta[x]
                if d == need, lastFailAtNeed <= x, let set = try placed([x]) { return .placed(set) }
                guard let ys = byDelta[need - d] else { continue }
                var k = firstIndex(in: ys, after: max(x, lastFailAtNeed - 1))
                while k < ys.count {
                    let y = ys[k]
                    try step()
                    if try firstFail(d, x + 1, y) != nil { break }
                    if okMove(y, d), let set = try placed([x, y]) { return .placed(set) }
                    k += 1
                }
            }
            // Triples. The third flip is at or after `lastFailAtNeed`; when few
            // size changes occur there, only the y that can pair with one are visited.
            var zDeltas = Set<Int>()
            for p in max(lastFailAtNeed, 0)..<m { zDeltas.insert(delta[p]) }
            let fewZ = zDeltas.count <= 16
            for x in 0..<xEnd {
                try step()
                guard okMove(x, 0) else { continue }
                let d1 = delta[x]
                var candidates: [Int] = []
                if fewZ {
                    for v in zDeltas {
                        guard let list = byDelta[need - d1 - v] else { continue }
                        let from = firstIndex(in: list, after: x)
                        for _ in 0..<((list.count - from) >> 6) { try step() }
                        candidates += list[from...]
                    }
                    candidates.sort()
                }
                var c = 0
                var y = fewZ ? (candidates.first ?? m) : x + 1
                while y < m {
                    try step()
                    if try firstFail(d1, x + 1, y) != nil { break }
                    if okMove(y, d1) {
                        let d2 = d1 + delta[y]
                        if let zs = byDelta[need - d2] {
                            var k = firstIndex(in: zs, after: max(y, lastFailAtNeed - 1))
                            while k < zs.count {
                                let z = zs[k]
                                try step()
                                if try firstFail(d2, y + 1, z) != nil { break }
                                if okMove(z, d2), let set = try placed([x, y, z]) { return .placed(set) }
                                k += 1
                            }
                        }
                    }
                    if fewZ { c += 1; y = c < candidates.count ? candidates[c] : m } else { y += 1 }
                }
            }
        } catch let stop as Stop {
            return stop.outcome
        } catch {
            return .notFound
        }
        return .notFound
    }

    // MARK: Byte helpers

    static func u16(_ d: Data, _ o: Int) -> UInt16 {
        let i = d.startIndex + o
        guard o >= 0, i + 2 <= d.endIndex else { return 0 }
        return UInt16(d[i]) | UInt16(d[i + 1]) << 8
    }

    static func u32(_ d: Data, _ o: Int) -> UInt32 {
        let i = d.startIndex + o
        guard o >= 0, i + 4 <= d.endIndex else { return 0 }
        return UInt32(d[i]) | UInt32(d[i + 1]) << 8 | UInt32(d[i + 2]) << 16 | UInt32(d[i + 3]) << 24
    }
}

// MARK: - Values

enum NotesValue {
    /// TIMEDATE: hundredths of a second since midnight GMT, then the Julian
    /// day in the low 24 bits (zone/DST in the high byte, not needed for the
    /// instant). Checked on the sample against the RFC 822 Date text stored
    /// beside the same value (44 of 45 agree to the second; the 45th's day
    /// field is damaged in the file, its time of day agrees).
    static func date(_ v: Data) -> Date? {
        guard v.count >= 8 else { return nil }
        let ticks = NSFODSReader.u32(v, 0), day = NSFODSReader.u32(v, 4)
        guard ticks != 0xFFFF_FFFF, day != 0xFFFF_FFFF else { return nil }
        let julian = Int(day & 0x00FF_FFFF)
        guard julian > 2_000_000, julian < 3_000_000 else { return nil }
        let seconds = Double(julian - 2_440_588) * 86_400 + Double(ticks) / 100
        return Date(timeIntervalSince1970: seconds)
    }

    static func text(_ v: Data) -> String { LMBCS.decode(v) }

    static func textList(_ v: Data) -> [String] {
        guard v.count >= 2 else { return [] }
        let count = Int(NSFODSReader.u16(v, 0))
        var lengths: [Int] = []
        var p = 2
        for _ in 0..<count {
            guard p + 2 <= v.count else { return [] }
            lengths.append(Int(NSFODSReader.u16(v, p))); p += 2
        }
        var out: [String] = []
        for len in lengths {
            guard p + len <= v.count else { break }
            out.append(LMBCS.decode(v.subdata(in: p..<(p + len)))); p += len
        }
        return out
    }

    /// RFC822ITEMDESC (14 bytes): version 0x0E, flags, then the lengths of
    /// the Notes-native value, the header name, the delimiter and the header
    /// body; the original header line is name + delimiter + body.
    static func rfc822(_ v: Data) -> (native: Data, line: Data)? {
        guard v.count >= 14, NSFODSReader.u16(v, 0) == 0x000E else { return nil }
        let native = Int(NSFODSReader.u16(v, 6)), name = Int(NSFODSReader.u16(v, 8))
        let delim = Int(NSFODSReader.u16(v, 10)), body = Int(NSFODSReader.u16(v, 12))
        guard 14 + native + name + delim + body <= v.count else { return nil }
        return (v.subdata(in: 14..<(14 + native)), v.subdata(in: (14 + native)..<(14 + native + name + delim + body)))
    }

    /// Fallback when the four lengths do not add up: the bytes after the
    /// native value, when they read as one `Name: value` header line.
    static func rfc822HeaderLine(_ v: Data) -> Data? {
        guard v.count >= 14, NSFODSReader.u16(v, 0) == 0x000E else { return nil }
        let native = Int(NSFODSReader.u16(v, 6))
        guard 14 + native < v.count else { return nil }
        let rest = v.subdata(in: (14 + native)..<v.count)
        guard let text = String(data: rest, encoding: .isoLatin1),
              text.range(of: #"^[!-9;-~]+: "#, options: .regularExpression) != nil else { return nil }
        return rest
    }

    /// The value as display text, whatever its stored form.
    static func string(_ item: NSFODSReader.Item) -> String {
        switch item.type {
        case 0x0502: return rfc822(item.value).map { LMBCS.decode($0.native) } ?? ""
        case 0x0501: return textList(item.value).joined(separator: ", ")
        default: return text(item.value)
        }
    }

    static func dateValue(_ item: NSFODSReader.Item) -> Date? {
        switch item.type {
        case 0x0400: return date(item.value)
        case 0x0502: return rfc822(item.value).flatMap { date($0.native) }
        default: return nil
        }
    }
}

/// Lotus Multi-Byte Character Set, the parts mail needs: ASCII; group 1
/// (code page 850) for prefixed or unprefixed high bytes; group 0x14
/// (UCS-2, big-endian) for everything else. Other group prefixes are kept
/// as the bytes that follow them in code page 850.
enum LMBCS {
    private static let cp850 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosLatin1.rawValue)))

    static func decode(_ d: Data) -> String {
        if !d.contains(where: { $0 >= 0x80 || ($0 > 0 && $0 < 0x20 && $0 != 0x09 && $0 != 0x0A && $0 != 0x0D) }) {
            return String(decoding: d.filter { $0 != 0 }, as: UTF8.self)
        }
        var out = ""
        let b = [UInt8](d)
        var i = 0
        while i < b.count {
            let c = b[i]
            if c == 0x14, i + 2 < b.count {
                let u = UInt16(b[i + 1]) << 8 | UInt16(b[i + 2])
                if let s = Unicode.Scalar(u) { out.unicodeScalars.append(s) }
                i += 3
            } else if c >= 0x01, c <= 0x13, c != 0x09, c != 0x0A, c != 0x0D, i + 1 < b.count, b[i + 1] >= 0x80 {
                out += String(data: Data([b[i + 1]]), encoding: cp850) ?? ""
                i += 2
            } else if c >= 0x80 {
                out += String(data: Data([c]), encoding: cp850) ?? ""
                i += 1
            } else {
                if c != 0 { out.unicodeScalars.append(Unicode.Scalar(c)) }
                i += 1
            }
        }
        return out
    }
}

/// Notes rich text (TYPE_COMPOSITE): CD records with byte (BSIG), word
/// (WSIG, 0xFF marker) or long (LSIG, 0x00 marker) headers. Only text runs
/// (SIG_CD_TEXT 0xFF85: 4-byte font ID, then LMBCS text) and paragraph
/// breaks (SIG_CD_PARAGRAPH 0x81) are turned into text. Verified on a
/// synthetic CD stream only — the public sample has no rich-text mail.
enum NotesRichText {
    static func plainText(_ v: Data) -> String {
        var out = ""
        var p = 0
        let n = v.count
        while p + 2 <= n {
            let sig = v[v.startIndex + p], marker = v[v.startIndex + p + 1]
            var length: Int
            var header: Int
            if marker == 0xFF {
                guard p + 4 <= n else { break }
                length = Int(NSFODSReader.u16(v, p + 2)); header = 4
            } else if marker == 0x00 {
                guard p + 6 <= n else { break }
                length = Int(NSFODSReader.u32(v, p + 2)); header = 6
            } else {
                length = Int(marker); header = 2
            }
            guard length >= header, p + length <= n else { break }
            if sig == 0x85, marker == 0xFF, length >= 8 {
                out += LMBCS.decode(v.subdata(in: (p + 8)..<(p + length)))
            } else if sig == 0x81 {
                out += "\n"
            }
            p += length + (length & 1)          // records are word-aligned
        }
        return out
    }
}
