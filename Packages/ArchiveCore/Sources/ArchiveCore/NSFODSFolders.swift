//
//  NSFODSFolders.swift
//  ArchiveCore
//
//  R6 (audit, NSF row): the two Notes ODS structures the GAP-NSF reader
//  could not read before — folder membership and Huffman-compressed
//  attachment objects. Part of the preview ODS reader (`NotesODSPolicy`,
//  off by default); the old `NSFParser` is untouched (rule 14).
//
//  Neither layout is in the libnsfdb notes or the C API reference; both were
//  worked out on the public SampleNSF.nsf and are accepted only where the
//  file checks itself (NSFODSReaderTests):
//
//  Folder membership. A folder is a view-class design note (NOTE_CLASS_VIEW
//  0x0008) whose $Flags contain "F". Its $FolderIDTable item is an object
//  descriptor (WORD object type 0x000A, DWORD RRV ID) naming an object
//  record that holds the folder's note-ID table:
//      DWORD 4 · WORD number of IDs · WORD number of runs · WORD flags ·
//      TIMEDATE · runs of (BYTE extra, DWORD first ID)
//  where a run is `first`, `first + 4`, … `first + 4 × extra` (note IDs step
//  by 4). On the sample every table's ID count equals the sum of its runs
//  (Inbox: 343 IDs in 6 runs), and every live mail note the Inbox table
//  names is also in the Inbox's $FolderObject records — 36-byte entries
//  ending (UNID, note ID) — with the UNID equal to that note's own OID.
//  Folder names nest with "\" ("Projects\2015" → Projects/2015). The
//  standard mail folders ($Inbox, ($Drafts)/(Drafts), ($Sent)/(Sent),
//  ($Trash), ($JunkMail)) get their display names; other hidden helper
//  folders "(…)" keep their inner name and are listed only when they hold
//  mail.
//
//  Huffman (FILEOBJECT CompressionType 1). The object holds DWORD checksum
//  (the byte sum of the decoded file), WORD tree size in bytes, the tree as
//  signed 16-bit pairs (node 0 = root; a negative value -k points at pair
//  k, 0…255 is a byte, 256 ends the stream), then the code bits, most
//  significant bit of each byte first, bit 1 taking the first value of a
//  pair. Checked on the sample's three Huffman objects (design-note bitmaps):
//  each decodes to exactly its FILEOBJECT size, its BMP header states that
//  size, the checksum matches, and the stream is used to its last byte.
//

import Foundation

enum NotesFolders {
    struct Folder: Equatable, Sendable {
        let noteID: UInt32
        let title: String
        /// "/"-separated archive path.
        let path: String
        /// A hidden helper folder "(…)" that is not one of the standard mail folders.
        let hidden: Bool
        /// Note IDs the folder's table names (live or not).
        let members: [UInt32]
    }

    struct Directory: Sendable {
        var folders: [Folder] = []
        /// Folder design notes whose members could not be read: title → reason.
        var unread: [String: String] = [:]
        private var byNote: [UInt32: [Int]] = [:]

        init(folders: [Folder] = [], unread: [String: String] = [:]) {
            self.folders = folders
            self.unread = unread
            for (index, folder) in folders.enumerated() {
                for id in folder.members where !(byNote[id]?.contains(index) ?? false) {
                    byNote[id, default: []].append(index)
                }
            }
        }

        /// The folder paths a note belongs to: standard and user folders
        /// first (in folder note-ID order), hidden helper folders after.
        func paths(for noteID: UInt32) -> [String] {
            let indices = byNote[noteID] ?? []
            var out: [String] = []
            for i in indices where !folders[i].hidden && !out.contains(folders[i].path) { out.append(folders[i].path) }
            for i in indices where folders[i].hidden && !out.contains(folders[i].path) { out.append(folders[i].path) }
            return out
        }

        /// Folders the archive should show even when empty: every folder
        /// that is not a hidden helper.
        var declared: [String] {
            var out: [String] = []
            for f in folders where !f.hidden && !out.contains(f.path) { out.append(f.path) }
            return out
        }
    }

    static let viewClass: UInt16 = 0x0008

    static func isFolder(_ note: NSFODSReader.Note) -> Bool {
        guard let flags = note.first("$Flags") else { return false }
        return NotesValue.string(flags).contains("F")
    }

    /// Every folder of the database, its members read from $FolderIDTable.
    static func read(_ reader: NSFODSReader) -> Directory {
        var folders: [Folder] = []
        var unread: [String: String] = [:]
        for note in reader.notes(ofClass: viewClass) where isFolder(note) {
            let title = note.first("$TITLE").map(NotesValue.string) ?? ""
            let label = title.isEmpty ? String(format: "folder note 0x%X", note.id) : title
            guard let (path, hidden) = path(forTitle: title) else {
                unread[label] = "the folder has no name"
                continue
            }
            guard let item = note.first("$FolderIDTable") else {
                unread[label] = "no $FolderIDTable item (the member list kept only in the folder's collection is not decoded)"
                continue
            }
            guard item.value.count >= 6, let payload = reader.objectPayload(rrvID: NSFODSReader.u32(item.value, 2)) else {
                unread[label] = "its $FolderIDTable object is not in the file"
                continue
            }
            do {
                folders.append(Folder(noteID: note.id, title: title, path: path, hidden: hidden, members: try idTable(payload)))
            } catch {
                unread[label] = "\(error.localizedDescription)"
            }
        }
        return Directory(folders: folders, unread: unread)
    }

    struct TableError: LocalizedError {
        let errorDescription: String?
    }

    /// The note IDs of a folder ID table (layout in the file header).
    static func idTable(_ v: Data) throws -> [UInt32] {
        guard v.count >= 18, NSFODSReader.u32(v, 0) == 4 else {
            throw TableError(errorDescription: "its ID table does not start with the table signature")
        }
        let total = Int(NSFODSReader.u16(v, 4)), runs = Int(NSFODSReader.u16(v, 6))
        guard 18 + 5 * runs <= v.count else {
            throw TableError(errorDescription: "its ID table declares \(runs) runs in \(v.count) bytes")
        }
        var ids: [UInt32] = []
        ids.reserveCapacity(total)
        for r in 0..<runs {
            let at = 18 + 5 * r
            let extra = Int(v[v.startIndex + at])
            let first = NSFODSReader.u32(v, at + 1)
            for k in 0...extra { ids.append(first &+ UInt32(4 * k)) }
        }
        guard ids.count == total else {
            throw TableError(errorDescription: "its ID table's runs hold \(ids.count) IDs, the table says \(total)")
        }
        return ids
    }

    private static let standard: [String: String] = [
        "$inbox": "Inbox", "$drafts": "Drafts", "drafts": "Drafts", "$sent": "Sent", "sent": "Sent",
        "$trash": "Trash", "$junkmail": "Junk Mail",
    ]

    /// Archive path for a folder title (first alias before "|"); nil for an
    /// empty name. "\" nests; a "/" inside one name becomes "-" so it does
    /// not read as nesting.
    static func path(forTitle title: String) -> (path: String, hidden: Bool)? {
        var name = (title.split(separator: "|", omittingEmptySubsequences: false).first.map(String.init) ?? "")
            .trimmingCharacters(in: .whitespaces)
        var hidden = false
        if name.hasPrefix("("), name.hasSuffix(")"), name.count >= 2 {
            name = String(name.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            if let display = standard[name.lowercased()] { return (display, false) }
            hidden = true
            if name.hasPrefix("$") { name.removeFirst() }
        }
        let parts = name.components(separatedBy: "\\")
            .map { $0.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return (parts.joined(separator: "/"), hidden)
    }
}

/// Notes attachment Huffman decoding (FILEOBJECT CompressionType 1); the
/// layout is described in the file header above.
enum NotesHuffman {
    struct DecodeError: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    static func decompress(_ v: Data, expectedSize: Int) throws -> Data {
        guard v.count >= 6 else { throw DecodeError("Huffman object shorter than its header") }
        let checksum = NSFODSReader.u32(v, 0)
        let treeBytes = Int(NSFODSReader.u16(v, 4))
        guard treeBytes >= 4, treeBytes % 4 == 0, 6 + treeBytes <= v.count else {
            throw DecodeError("Huffman tree of \(treeBytes) bytes does not fit the object")
        }
        let tree = (0..<(treeBytes / 2)).map { Int(Int16(bitPattern: NSFODSReader.u16(v, 6 + 2 * $0))) }
        let pairs = tree.count / 2
        var out = [UInt8]()
        out.reserveCapacity(expectedSize)
        var node = 0
        var ended = false
        let bytes = [UInt8](v.suffix(from: v.startIndex + 6 + treeBytes))
        outer: for byte in bytes {
            for k in 0..<8 {
                let bit = Int((byte >> (7 - k)) & 1)
                let value = tree[2 * node + (1 - bit)]
                if value < 0 {
                    node = -value
                    guard node < pairs else { throw DecodeError("Huffman tree points outside itself") }
                } else if value == 256 {
                    ended = true
                    break outer
                } else if value < 256 {
                    out.append(UInt8(value))
                    node = 0
                    guard out.count <= expectedSize else { throw DecodeError("Huffman stream runs past the file size \(expectedSize)") }
                } else {
                    throw DecodeError("Huffman tree holds symbol \(value)")
                }
            }
        }
        guard ended, out.count == expectedSize else {
            throw DecodeError("Huffman stream gave \(out.count) of \(expectedSize) bytes\(ended ? "" : " without its end code")")
        }
        let sum = out.reduce(UInt32(0)) { $0 &+ UInt32($1) }
        guard sum == checksum else { throw DecodeError("Huffman output checksum differs from the stored one") }
        return Data(out)
    }
}
