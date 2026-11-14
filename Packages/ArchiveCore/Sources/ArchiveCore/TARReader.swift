//
//  TARReader.swift
//  mailin
//
//  TYPE-06 (owner directive 2026-11-06): TAR wrappers as import sources.
//
//  A tape archive is a sequence of 512-byte header blocks, each followed by
//  the member's bytes padded to 512. mailin reads the headers (POSIX ustar,
//  GNU long names, PAX extended headers) and streams one member at a time to
//  a scratch file, where the ordinary classifier judges it on its own bytes —
//  exactly how ZIP members are handled by `ZIPArchiveReader`. A `.tgz` /
//  `.tar.gz` is gzip → tar → members, one level inside the other.
//
//  What is checked, and what is not a limit:
//   • The header checksum of every member is verified; a wrong one stops the
//     walk at that point and names the member — a tar that is damaged half
//     way still yields every member before the damage.
//   • A member whose declared size runs past the end of the file is refused
//     as truncated, never imported short.
//   • Sizes above 8 GiB (GNU base-256 and PAX `size=`) are honoured; there is
//     no member cap of mailin's own. The only ceiling is the scratch volume's
//     free space, with the same margin ZIP members get.
//

import Foundation

struct TARReader {

    /// Bumped when which members come out of the same archive changes.
    static let version = 1

    private static let blockSize = 512
    private static let windowSize = 64 * 1024

    struct Member: Sendable, Equatable {
        let name: String
        let size: Int64
        /// Offset of the first data byte in the archive.
        let dataOffset: Int64
        let typeFlag: UInt8

        /// Regular files only; directories, links and device nodes carry no
        /// mail. Type '0', NUL and '7' (contiguous) are regular files.
        var isRegularFile: Bool { typeFlag == 0x30 || typeFlag == 0 || typeFlag == 0x37 }
        var isDirectory: Bool { typeFlag == 0x35 || name.hasSuffix("/") }

        /// OS junk that is never mail (same rule as ZIP members).
        var isJunk: Bool {
            let base = (name as NSString).lastPathComponent
            return name.hasPrefix("__MACOSX/") || name.contains("/__MACOSX/") || base == ".DS_Store"
                || base == "Thumbs.db" || base.hasPrefix("._") || name.hasPrefix(".")
        }
    }

    enum ReadError: Error, CustomStringConvertible, Equatable {
        case notATar
        case truncated(String)
        case badChecksum(member: String)
        case insufficientDisk(member: String, needed: Int64, available: Int64)

        var description: String {
            switch self {
            case .notATar: return "Not a tar archive (no ustar header in the first block)."
            case .truncated(let what): return "Archive is truncated: \(what)."
            case .badChecksum(let member): return "\(member): header checksum does not match — the archive is damaged here."
            case .insufficientDisk(let member, let needed, let available): return "\(member): needs \(needed) bytes of scratch space, \(available) available."
            }
        }
    }

    // MARK: - Signature

    /// True when `data` (the first bytes of a file) starts with a tar header:
    /// the ustar magic at offset 257, or — for pre-POSIX archives without the
    /// magic — a header whose checksum field verifies.
    static func looksLikeTar(_ data: Data) -> Bool {
        guard data.count >= blockSize else { return false }
        let block = Data(data.prefix(blockSize))
        if hasUstarMagic(block) { return true }
        return checksumMatches(block) && block[block.startIndex] != 0
    }

    private static func hasUstarMagic(_ block: Data) -> Bool {
        let magic = Array(block[block.startIndex + 257 ..< block.startIndex + 262])
        return magic == [0x75, 0x73, 0x74, 0x61, 0x72]   // "ustar"
    }

    // MARK: - Walking the headers

    /// Every member in archive order. Only headers are read; member bytes are
    /// skipped over, so listing costs one seek per member.
    static func members(of url: URL) throws -> [Member] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = Int64(try handle.seekToEnd())
        guard fileSize >= Int64(blockSize) else { throw ReadError.notATar }

        var members: [Member] = []
        var offset: Int64 = 0
        var pendingLongName: String?
        var paxPath: String?
        var paxSize: Int64?
        var globalPaxPath: String?
        var sawHeader = false
        var zeroBlocks = 0

        while offset + Int64(blockSize) <= fileSize {
            try handle.seek(toOffset: UInt64(offset))
            let block = try handle.read(upToCount: blockSize) ?? Data()
            guard block.count == blockSize else { throw ReadError.truncated("header at offset \(offset)") }

            if block.allSatisfy({ $0 == 0 }) {
                // Two zero blocks end the archive; one is tolerated.
                zeroBlocks += 1
                if zeroBlocks >= 2 { break }
                offset += Int64(blockSize)
                continue
            }
            zeroBlocks = 0

            if !sawHeader, !hasUstarMagic(block), !checksumMatches(block) { throw ReadError.notATar }
            sawHeader = true
            let rawName = string(block, 0, 100)
            guard checksumMatches(block) else {
                throw ReadError.badChecksum(member: pendingLongName ?? paxPath ?? rawName)
            }

            let declaredSize = try parseSize(block, 124, 12, context: rawName)
            let typeFlag = block[block.startIndex + 156]
            let dataOffset = offset + Int64(blockSize)
            let paddedSize = (declaredSize + Int64(blockSize) - 1) / Int64(blockSize) * Int64(blockSize)

            switch typeFlag {
            case 0x4C:   // 'L' GNU long name: the data block holds the next member's name
                pendingLongName = try readString(handle, at: dataOffset, count: declaredSize, fileSize: fileSize, what: "GNU long name")
            case 0x4B:   // 'K' GNU long link name: not mail, skip
                break
            case 0x78:   // 'x' PAX extended header for the next member
                let records = try parsePax(try readString(handle, at: dataOffset, count: declaredSize, fileSize: fileSize, what: "PAX header"))
                paxPath = records["path"]
                if let sizeText = records["size"], let size = Int64(sizeText) { paxSize = size }
            case 0x67:   // 'g' PAX global header
                let records = try parsePax(try readString(handle, at: dataOffset, count: declaredSize, fileSize: fileSize, what: "PAX global header"))
                if let path = records["path"] { globalPaxPath = path }
            default:
                var name = paxPath ?? pendingLongName ?? globalPaxPath ?? rawName
                if paxPath == nil, pendingLongName == nil {
                    // ustar prefix field (155 bytes at 345) precedes the name.
                    let prefix = hasUstarMagic(block) ? string(block, 345, 155) : ""
                    if !prefix.isEmpty { name = prefix + "/" + rawName }
                }
                let size = paxSize ?? declaredSize
                guard dataOffset + size <= fileSize else {
                    throw ReadError.truncated("\(name): declares \(size) bytes, the file ends \(dataOffset + size - fileSize) bytes early")
                }
                members.append(Member(name: name, size: size, dataOffset: dataOffset, typeFlag: typeFlag))
                pendingLongName = nil
                paxPath = nil
                paxSize = nil
                offset = dataOffset + (size + Int64(blockSize) - 1) / Int64(blockSize) * Int64(blockSize)
                continue
            }
            offset = dataOffset + paddedSize
        }
        guard sawHeader else { throw ReadError.notATar }
        return members
    }

    // MARK: - Extraction

    /// Streams `member` into `destination` through a 64 KiB window. Refused
    /// before a byte is written when the scratch volume lacks room.
    static func extract(_ member: Member, from url: URL, to destination: URL,
                        availableDiskBytes: Int64? = nil) throws {
        let available = availableDiskBytes ?? ZIPArchiveReader.freeSpace(at: destination.deletingLastPathComponent())
        if let available, available < member.size + ZIPArchiveReader.diskMarginBytes {
            throw ReadError.insufficientDisk(member: member.name,
                                             needed: member.size + ZIPArchiveReader.diskMarginBytes,
                                             available: available)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = Int64(try handle.seekToEnd())
        guard member.dataOffset + member.size <= fileSize else {
            throw ReadError.truncated("\(member.name): member data")
        }
        try handle.seek(toOffset: UInt64(member.dataOffset))

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let out = try FileHandle(forWritingTo: destination)
        var succeeded = false
        defer {
            try? out.close()
            if !succeeded { try? FileManager.default.removeItem(at: destination) }
        }
        var remaining = member.size
        while remaining > 0 {
            // CLOSE-01 follow-up: each window in its own autorelease pool —
            // without it every window of the member stayed resident until the
            // extraction returned (measured: +1.9 GB for a 2 GB .msg member).
            let count = try autoreleasepool { () throws -> Int in
                let chunk = try handle.read(upToCount: Int(min(Int64(windowSize), remaining))) ?? Data()
                guard !chunk.isEmpty else { throw ReadError.truncated("\(member.name): member data") }
                try out.write(contentsOf: chunk)
                return chunk.count
            }
            remaining -= Int64(count)
        }
        succeeded = true
    }

    // MARK: - Header fields

    private static func string(_ block: Data, _ offset: Int, _ length: Int) -> String {
        let start = block.startIndex + offset
        let field = block[start ..< start + length]
        let bytes = field.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Octal ASCII, or GNU base-256 when the first byte has its high bit set.
    private static func parseSize(_ block: Data, _ offset: Int, _ length: Int, context: String) throws -> Int64 {
        let start = block.startIndex + offset
        let field = Array(block[start ..< start + length])
        if let first = field.first, first & 0x80 != 0 {
            var value: Int64 = 0
            for (index, byte) in field.enumerated() {
                let b = index == 0 ? byte & 0x7F : byte
                guard value <= (Int64.max >> 8) else { throw ReadError.truncated("\(context): size field overflows") }
                value = (value << 8) | Int64(b)
            }
            return value
        }
        let text = String(decoding: field.prefix { $0 != 0 && $0 != 0x20 }, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return 0 }
        guard let value = Int64(text, radix: 8) else { throw ReadError.truncated("\(context): size field is not octal") }
        return value
    }

    /// The header checksum: the unsigned sum of all 512 bytes with the eight
    /// checksum bytes taken as spaces. Some old writers summed signed bytes;
    /// both are accepted.
    private static func checksumMatches(_ block: Data) -> Bool {
        let start = block.startIndex
        let field = Array(block[start + 148 ..< start + 156])
        let text = String(decoding: field.prefix { $0 != 0 && $0 != 0x20 }, as: UTF8.self)
        guard let declared = Int(text, radix: 8) else { return false }
        var unsignedSum = 0, signedSum = 0
        for (index, byte) in block.enumerated() {
            if (148 ..< 156).contains(index) {
                unsignedSum += 0x20; signedSum += 0x20
            } else {
                unsignedSum += Int(byte)
                signedSum += Int(Int8(bitPattern: byte))
            }
        }
        return declared == unsignedSum || declared == signedSum
    }

    private static func readString(_ handle: FileHandle, at offset: Int64, count: Int64, fileSize: Int64, what: String) throws -> String {
        guard count >= 0, offset + count <= fileSize, count <= 1 << 20 else { throw ReadError.truncated(what) }
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.read(upToCount: Int(count)) ?? Data()
        guard Int64(data.count) == count else { throw ReadError.truncated(what) }
        return String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// PAX records: "<length> <key>=<value>\n", length counting the whole record.
    private static func parsePax(_ text: String) throws -> [String: String] {
        var records: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let space = line.firstIndex(of: " ") else { continue }
            let body = line[line.index(after: space)...]
            guard let equals = body.firstIndex(of: "=") else { continue }
            records[String(body[..<equals])] = String(body[body.index(after: equals)...])
        }
        return records
    }
}
