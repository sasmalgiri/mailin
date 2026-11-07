//
//  CabinetReader.swift
//  ArchiveCore
//
//  Directive 2026-11-07 §6 "Other business formats": a Microsoft cabinet
//  (MS-CAB) — the container of a OneNote notebook package (.onepkg).
//  CFHEADER names the folders and files; each CFFOLDER is a compressed
//  stream split into CFDATA blocks of at most 32,768 uncompressed bytes;
//  each CFFILE is a byte range of one folder. MSZIP (MS-MCI) is the only
//  compression opened: every block is a raw DEFLATE stream after the two
//  bytes "CK", and the 32 KiB history carries over from block to block, so
//  the system zlib inflates each block with the previous output preset as
//  its dictionary. "None" folders are copied. LZX and Quantum folders are
//  named by the caller as not opened. A CFDATA checksum, when the writer
//  supplied one, is verified and a mismatch is noted. Nothing is executed.
//

import Foundation
import zlib

final class CabinetReader {

    struct ReadError: Error, LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    enum Compression: Equatable {
        case none, mszip, quantum, lzx
        var isReadable: Bool { self == .none || self == .mszip }
        var name: String {
            switch self { case .none: return "stored"; case .mszip: return "MSZIP"; case .quantum: return "Quantum"; case .lzx: return "LZX" }
        }
    }

    struct Folder {
        let dataOffset: Int
        let blockCount: Int
        let compression: Compression
    }

    struct Member {
        let name: String
        let size: Int
        let offsetInFolder: Int
        let folderIndex: Int
        /// The member continues in the previous or next cabinet of a set.
        let spansCabinets: Bool
    }

    static func hasSignature(_ head: Data) -> Bool {
        head.count >= 4 && head[head.startIndex] == 0x4D && head[head.startIndex + 1] == 0x53 && head[head.startIndex + 2] == 0x43 && head[head.startIndex + 3] == 0x46
    }

    let folders: [Folder]
    let members: [Member]
    /// Observations while reading (checksum mismatches, members spanning cabinets).
    private(set) var notes: [String] = []
    private let b: [UInt8]
    private let reservePerBlock: Int
    private var folderCache: [Int: [UInt8]] = [:]

    init(data: Data) throws {
        b = [UInt8](data)
        guard Self.hasSignature(data), b.count >= 36 else { throw ReadError(text: "not a cabinet: no MSCF header") }
        let cFolders = Int(Self.le16(b, 26)), cFiles = Int(Self.le16(b, 28)), flags = Self.le16(b, 30)
        let coffFiles = Int(Self.le32(b, 16))
        var pos = 36
        var reserveFolder = 0, reserveData = 0
        if flags & 4 != 0 {
            guard b.count >= 40 else { throw ReadError(text: "cabinet header is truncated") }
            let cbCFHeader = Int(Self.le16(b, 36))
            reserveFolder = Int(b[38]); reserveData = Int(b[39])
            pos = 40 + cbCFHeader
        }
        var spanNotes: [String] = []
        if flags & 1 != 0 {
            let previous = try Self.cString(b, &pos); _ = try Self.cString(b, &pos)
            spanNotes.append("continues a cabinet set from \(previous)")
        }
        if flags & 2 != 0 {
            let next = try Self.cString(b, &pos); _ = try Self.cString(b, &pos)
            spanNotes.append("continues in \(next)")
        }
        var folders: [Folder] = []
        for _ in 0..<cFolders {
            guard pos + 8 <= b.count else { throw ReadError(text: "cabinet folder table is truncated") }
            let type = Int(Self.le16(b, pos + 6)) & 0xF
            let compression: Compression
            switch type { case 0: compression = .none; case 1: compression = .mszip; case 2: compression = .quantum; default: compression = .lzx }
            folders.append(Folder(dataOffset: Int(Self.le32(b, pos)), blockCount: Int(Self.le16(b, pos + 4)), compression: compression))
            pos += 8 + reserveFolder
        }
        var members: [Member] = []
        pos = coffFiles
        for _ in 0..<cFiles {
            guard pos + 16 <= b.count else { throw ReadError(text: "cabinet file table is truncated") }
            let size = Int(Self.le32(b, pos)), offset = Int(Self.le32(b, pos + 4))
            let iFolder = Int(Self.le16(b, pos + 8)), attributes = Self.le16(b, pos + 14)
            pos += 16
            let name = try Self.name(b, &pos, utf8: attributes & 0x80 != 0)
            var folderIndex = iFolder
            var spans = false
            if iFolder >= 0xFFFD {
                spans = true
                folderIndex = iFolder == 0xFFFD ? 0 : max(folders.count - 1, 0)
            }
            guard folderIndex < folders.count else { throw ReadError(text: "\(name): folder \(iFolder) is not in the cabinet") }
            members.append(Member(name: name, size: size, offsetInFolder: offset, folderIndex: folderIndex, spansCabinets: spans))
        }
        self.folders = folders
        self.members = members
        reservePerBlock = reserveData
        notes = spanNotes
        for m in members where m.spansCabinets { notes.append("\(m.name) continues in another cabinet of the set; only the part in this file is here") }
    }

    /// The member's bytes; the folder is decompressed once and kept for the
    /// other members of the same folder.
    func extract(_ member: Member) throws -> [UInt8] {
        let folder = try folderBytes(member.folderIndex)
        guard member.offsetInFolder >= 0, member.offsetInFolder <= folder.count else {
            throw ReadError(text: "\(member.name) starts at \(member.offsetInFolder), past the folder's \(folder.count) bytes")
        }
        let available = folder.count - member.offsetInFolder
        guard member.size <= available else {
            if member.spansCabinets { return Array(folder[member.offsetInFolder...]) }
            throw ReadError(text: "\(member.name) needs \(member.size) bytes but the folder holds \(available) after its start")
        }
        return Array(folder[member.offsetInFolder..<(member.offsetInFolder + member.size)])
    }

    private func folderBytes(_ index: Int) throws -> [UInt8] {
        if let cached = folderCache[index] { return cached }
        let folder = folders[index]
        guard folder.compression.isReadable else { throw ReadError(text: "\(folder.compression.name)-compressed folder is not opened") }
        var out: [UInt8] = []
        var pos = folder.dataOffset
        var inflater: Inflater? = folder.compression == .mszip ? try Inflater() : nil
        for block in 0..<folder.blockCount {
            guard pos >= 0, pos + 8 + reservePerBlock <= b.count else { throw ReadError(text: "data block \(block + 1) of folder \(index + 1) lies outside the file") }
            let checksum = Self.le32(b, pos)
            let compressedSize = Int(Self.le16(b, pos + 4)), uncompressedSize = Int(Self.le16(b, pos + 6))
            let headerRange = (pos + 4)..<(pos + 8 + reservePerBlock)
            pos += 8 + reservePerBlock
            guard pos + compressedSize <= b.count else { throw ReadError(text: "data block \(block + 1) of folder \(index + 1) is truncated") }
            let payload = b[pos..<(pos + compressedSize)]
            pos += compressedSize
            if checksum != 0 {
                let expected = Self.checksum(b[headerRange], seed: Self.checksum(payload, seed: 0))
                if expected != checksum { notes.append("data block \(block + 1) of folder \(index + 1): checksum mismatch") }
            }
            if uncompressedSize == 0 { break }                       // the block continues in the next cabinet
            switch folder.compression {
            case .none:
                out.append(contentsOf: payload)
            case .mszip:
                guard payload.count >= 2, payload[payload.startIndex] == 0x43, payload[payload.startIndex + 1] == 0x4B else {
                    throw ReadError(text: "data block \(block + 1) of folder \(index + 1) has no MSZIP signature")
                }
                let inflated = try inflater!.inflate(Array(payload.dropFirst(2)), expected: uncompressedSize, history: Array(out.suffix(32768)))
                guard inflated.count == uncompressedSize else {
                    throw ReadError(text: "data block \(block + 1) of folder \(index + 1) inflated to \(inflated.count) bytes, \(uncompressedSize) declared")
                }
                out.append(contentsOf: inflated)
            case .quantum, .lzx:
                break
            }
        }
        inflater = nil
        folderCache[index] = out
        return out
    }

    // MARK: - MSZIP via the system zlib

    /// One raw-DEFLATE decoder reused block by block. SAFETY: `z_stream` is a
    /// C struct driven through pointers; the input and output buffers are
    /// Swift arrays whose pointers are valid only inside the `withUnsafe…`
    /// closures where `inflate` runs, and `avail_in`/`avail_out` are set to
    /// exactly those buffers' counts, so zlib never reads or writes past them.
    private final class Inflater {
        private var stream = z_stream()

        init() throws {
            let status = unsafe inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            guard status == Z_OK else { throw ReadError(text: "the DEFLATE decoder could not start (zlib \(status))") }
        }

        deinit { _ = unsafe inflateEnd(&stream) }

        func inflate(_ input: [UInt8], expected: Int, history: [UInt8]) throws -> [UInt8] {
            guard unsafe inflateReset(&stream) == Z_OK else { throw ReadError(text: "the DEFLATE decoder could not reset") }
            if !history.isEmpty {
                let status = history.withUnsafeBufferPointer { unsafe inflateSetDictionary(&stream, $0.baseAddress, UInt32($0.count)) }
                guard status == Z_OK else { throw ReadError(text: "the DEFLATE history could not be preset (zlib \(status))") }
            }
            var source = input
            var output = [UInt8](repeating: 0, count: max(expected, 1))
            let status: Int32 = source.withUnsafeMutableBufferPointer { inPtr in
                output.withUnsafeMutableBufferPointer { outPtr in
                    unsafe stream.next_in = inPtr.baseAddress
                    unsafe stream.avail_in = UInt32(inPtr.count)
                    unsafe stream.next_out = outPtr.baseAddress
                    unsafe stream.avail_out = UInt32(outPtr.count)
                    return unsafe zlib.inflate(&stream, Z_FINISH)
                }
            }
            let produced = Int(stream.total_out)
            guard status == Z_STREAM_END || ((status == Z_OK || status == Z_BUF_ERROR) && produced == expected) else {
                throw ReadError(text: "the DEFLATE block is corrupt (zlib \(status))")
            }
            return Array(output[0..<min(produced, output.count)])
        }
    }

    // MARK: - Helpers

    /// MS-CAB checksum: 32-bit little-endian words XORed, the 1–3 tail bytes folded in.
    static func checksum(_ s: ArraySlice<UInt8>, seed: UInt32) -> UInt32 {
        var csum = seed
        var i = s.startIndex
        let whole = s.count / 4
        for _ in 0..<whole {
            csum ^= UInt32(s[i]) | UInt32(s[i + 1]) << 8 | UInt32(s[i + 2]) << 16 | UInt32(s[i + 3]) << 24
            i += 4
        }
        var tail: UInt32 = 0
        switch s.count % 4 {
        case 3: tail |= UInt32(s[i]) << 16; i += 1; fallthrough
        case 2: tail |= UInt32(s[i]) << 8; i += 1; fallthrough
        case 1: tail |= UInt32(s[i])
        default: break
        }
        return csum ^ tail
    }

    private static func le16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
    private static func le32(_ b: [UInt8], _ i: Int) -> UInt32 { UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24 }

    private static func cString(_ b: [UInt8], _ pos: inout Int) throws -> String {
        guard let end = b[pos...].firstIndex(of: 0) else { throw ReadError(text: "cabinet string is not terminated") }
        defer { pos = end + 1 }
        return String(bytes: b[pos..<end], encoding: .utf8) ?? String(bytes: b[pos..<end], encoding: .windowsCP1252) ?? ""
    }

    private static func name(_ b: [UInt8], _ pos: inout Int, utf8: Bool) throws -> String {
        guard pos <= b.count, let end = b[pos...].firstIndex(of: 0) else { throw ReadError(text: "cabinet file name is not terminated") }
        defer { pos = end + 1 }
        let slice = b[pos..<end]
        let decoded = utf8 ? String(bytes: slice, encoding: .utf8) : String(bytes: slice, encoding: .windowsCP1252)
        return (decoded ?? String(bytes: slice, encoding: .isoLatin1) ?? "member").replacingOccurrences(of: "\\", with: "/")
    }
}
