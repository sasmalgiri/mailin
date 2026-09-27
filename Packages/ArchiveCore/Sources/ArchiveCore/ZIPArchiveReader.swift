//
//  ZIPArchiveReader.swift
//  maxmailin
//
//  Bounded container import (v2.1 backlog #1). Streams ONE member at a time
//  out of a ZIP — or the single payload of a gzip — to a scratch file, so the
//  importer can hand that file to the ordinary format classifier and parser
//  and delete it before the next member is touched.
//
//  What "bounded" means here, and what limits apply:
//   • The archive is never loaded into memory. The central directory is read
//     (it is small: ~80 bytes per member), then each member's bytes stream
//     through a 64 KiB window into the destination file.
//   • The only size ceiling is the DEVICE's: a member is refused when the
//     volume holding the scratch file lacks room for its declared size plus a
//     margin. There is no arbitrary "members over N MB are skipped" cap —
//     the format has none, so the app must not invent one.
//   • A member whose output exceeds its declared uncompressed size is aborted
//     and refused (zip-bomb shape: the directory lies about the size). A
//     member whose output is short, or whose CRC-32 does not match, is refused
//     too — a truncated mailbox imported "successfully" would be a lie.
//   • Encrypted members and compression methods other than stored/deflate are
//     refused by name. Nested containers are left to the caller, which refuses
//     them rather than recursing without bound.
//
//  ZIP64 is supported (Google Takeout exports over 4 GB use it): the ZIP64
//  end-of-central-directory record and the 0x0001 extra field are honoured.
//  Deflate is decoded with the Compression framework's `COMPRESSION_ZLIB`,
//  which is raw DEFLATE — exactly what ZIP method 8 and the gzip body carry.
//

import Foundation
import Compression

struct ZIPArchiveReader {

    /// Bumped when extraction behaviour changes in a way that alters which
    /// messages come out of the same archive; bound into import identities.
    static let version = 1

    /// Kept free on the scratch volume beyond a member's declared size, so an
    /// extraction cannot fill the disk to the last byte.
    static let diskMarginBytes: Int64 = 64 * 1024 * 1024

    private static let windowSize = 64 * 1024

    struct Member: Sendable, Equatable {
        let name: String
        let compressedSize: Int64
        let uncompressedSize: Int64
        let method: UInt16
        let crc32: UInt32
        let localHeaderOffset: Int64
        let isEncrypted: Bool

        var isDirectory: Bool { name.hasSuffix("/") }

        /// Members that are never mail and should not even be extracted.
        var isJunk: Bool {
            let base = (name as NSString).lastPathComponent
            return name.hasPrefix("__MACOSX/") || base == ".DS_Store" || base == "Thumbs.db"
                || base.hasPrefix("._") || name.hasPrefix(".")
        }
    }

    enum ReadError: Error, CustomStringConvertible, Equatable {
        case notAZip
        case truncated(String)
        case malformed(String)
        case unsupportedMethod(UInt16, member: String)
        case encrypted(member: String)
        case sizeMismatch(member: String, declared: Int64, actual: Int64)
        case crcMismatch(member: String)
        case insufficientDisk(member: String, needed: Int64, available: Int64)

        var description: String {
            switch self {
            case .notAZip: return "Not a ZIP archive (no end-of-central-directory record)."
            case .truncated(let what): return "Archive is truncated: \(what)."
            case .malformed(let what): return "Archive is malformed: \(what)."
            case .unsupportedMethod(let m, let member): return "\(member): compression method \(m) is not supported (only stored and deflate)."
            case .encrypted(let member): return "\(member): encrypted members cannot be imported."
            case .sizeMismatch(let member, let declared, let actual): return "\(member): declared \(declared) bytes, produced \(actual) — refused."
            case .crcMismatch(let member): return "\(member): CRC-32 does not match — the member is damaged."
            case .insufficientDisk(let member, let needed, let available): return "\(member): needs \(needed) bytes of scratch space, \(available) available."
            }
        }
    }

    // MARK: - Central directory

    /// Every entry in the archive's central directory, in directory order.
    static func members(of url: URL) throws -> [Member] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = Int64((try handle.seekToEnd()))

        // End of central directory: at most 65,535 bytes of comment precede
        // the end of file, plus the 22-byte record itself.
        let tailLength = Int(min(fileSize, 65_557))
        try handle.seek(toOffset: UInt64(fileSize - Int64(tailLength)))
        let tail = try handle.read(upToCount: tailLength) ?? Data()
        guard let eocdIndex = lastIndex(of: [0x50, 0x4B, 0x05, 0x06], in: tail) else { throw ReadError.notAZip }
        // Copied, not sliced: a Data slice keeps its parent's indices, and the
        // little-endian readers below index from zero.
        let eocd = Data(tail[eocdIndex...])
        guard eocd.count >= 22 else { throw ReadError.truncated("end-of-central-directory record") }

        var entryCount = Int64(u16(eocd, 10))
        var cdSize = Int64(u32(eocd, 12))
        var cdOffset = Int64(u32(eocd, 16))

        // ZIP64: any 0xFFFF / 0xFFFFFFFF field means "see the ZIP64 record",
        // located by the 20-byte locator that immediately precedes the EOCD.
        if entryCount == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {
            let locatorStart = eocdIndex - 20
            guard locatorStart >= tail.startIndex,
                  tail[locatorStart..<locatorStart + 4].elementsEqual([0x50, 0x4B, 0x06, 0x07]) else {
                throw ReadError.malformed("ZIP64 fields present but no ZIP64 locator")
            }
            let zip64Offset = Int64(u64(tail, locatorStart + 8))
            guard zip64Offset >= 0, zip64Offset + 56 <= fileSize else { throw ReadError.truncated("ZIP64 end-of-central-directory record") }
            try handle.seek(toOffset: UInt64(zip64Offset))
            let z = try handle.read(upToCount: 56) ?? Data()
            guard z.count == 56, z.prefix(4).elementsEqual([0x50, 0x4B, 0x06, 0x06]) else {
                throw ReadError.malformed("ZIP64 end-of-central-directory signature")
            }
            entryCount = Int64(u64(z, 32))
            cdSize = Int64(u64(z, 40))
            cdOffset = Int64(u64(z, 48))
        }

        guard cdOffset >= 0, cdSize >= 0, cdOffset + cdSize <= fileSize else {
            throw ReadError.truncated("central directory")
        }
        try handle.seek(toOffset: UInt64(cdOffset))
        let directory = try handle.read(upToCount: Int(cdSize)) ?? Data()
        guard Int64(directory.count) == cdSize else { throw ReadError.truncated("central directory") }

        var members: [Member] = []
        members.reserveCapacity(Int(min(entryCount, 1_000_000)))
        var cursor = directory.startIndex
        while cursor + 46 <= directory.endIndex {
            guard directory[cursor..<cursor + 4].elementsEqual([0x50, 0x4B, 0x01, 0x02]) else {
                throw ReadError.malformed("central directory entry signature at \(cursor - directory.startIndex)")
            }
            let flags = u16(directory, cursor + 8)
            let method = u16(directory, cursor + 10)
            let crc = u32(directory, cursor + 16)
            var compressed = Int64(u32(directory, cursor + 20))
            var uncompressed = Int64(u32(directory, cursor + 24))
            let nameLength = Int(u16(directory, cursor + 28))
            let extraLength = Int(u16(directory, cursor + 30))
            let commentLength = Int(u16(directory, cursor + 32))
            var localOffset = Int64(u32(directory, cursor + 42))

            let nameStart = cursor + 46
            let extraStart = nameStart + nameLength
            let entryEnd = extraStart + extraLength + commentLength
            guard entryEnd <= directory.endIndex else { throw ReadError.truncated("central directory entry") }

            let nameData = directory[nameStart..<extraStart]
            let name = String(data: nameData, encoding: .utf8)
                ?? String(data: nameData, encoding: .isoLatin1) ?? "member-\(members.count)"

            // ZIP64 extra field 0x0001: 8-byte values, present only for the
            // fields that were saturated, in the fixed order size/csize/offset.
            if compressed == 0xFFFF_FFFF || uncompressed == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF {
                var e = extraStart
                let extraEnd = extraStart + extraLength
                while e + 4 <= extraEnd {
                    let id = u16(directory, e), len = Int(u16(directory, e + 2))
                    var f = e + 4
                    if id == 0x0001 {
                        if uncompressed == 0xFFFF_FFFF, f + 8 <= e + 4 + len { uncompressed = Int64(u64(directory, f)); f += 8 }
                        if compressed == 0xFFFF_FFFF, f + 8 <= e + 4 + len { compressed = Int64(u64(directory, f)); f += 8 }
                        if localOffset == 0xFFFF_FFFF, f + 8 <= e + 4 + len { localOffset = Int64(u64(directory, f)); f += 8 }
                        break
                    }
                    e += 4 + len
                }
            }

            members.append(Member(name: name,
                                  compressedSize: compressed,
                                  uncompressedSize: uncompressed,
                                  method: method,
                                  crc32: crc,
                                  localHeaderOffset: localOffset,
                                  isEncrypted: (flags & 0x0001) != 0))
            cursor = entryEnd
        }
        return members
    }

    // MARK: - Extraction

    /// Streams `member` into `destination`, verifying size and CRC-32. On any
    /// failure the partial output is deleted and the error names the member.
    ///
    /// - Parameter availableDiskBytes: room on the destination volume; when
    ///   nil it is read from the file system. The member is refused before a
    ///   byte is written if it would not fit with `diskMarginBytes` to spare.
    static func extract(_ member: Member, from url: URL, to destination: URL,
                        availableDiskBytes: Int64? = nil) throws {
        guard !member.isEncrypted else { throw ReadError.encrypted(member: member.name) }
        guard member.method == 0 || member.method == 8 else {
            throw ReadError.unsupportedMethod(member.method, member: member.name)
        }
        let available = availableDiskBytes ?? freeSpace(at: destination.deletingLastPathComponent())
        if let available, available < member.uncompressedSize + diskMarginBytes {
            throw ReadError.insufficientDisk(member: member.name,
                                             needed: member.uncompressedSize + diskMarginBytes,
                                             available: available)
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = Int64(try handle.seekToEnd())

        // Local file header: 30 fixed bytes, then name and extra (whose
        // lengths may differ from the central directory's — always read the
        // local ones).
        guard member.localHeaderOffset >= 0, member.localHeaderOffset + 30 <= fileSize else {
            throw ReadError.truncated("\(member.name): local header")
        }
        try handle.seek(toOffset: UInt64(member.localHeaderOffset))
        let local = try handle.read(upToCount: 30) ?? Data()
        guard local.count == 30, local.prefix(4).elementsEqual([0x50, 0x4B, 0x03, 0x04]) else {
            throw ReadError.malformed("\(member.name): local header signature")
        }
        let dataStart = member.localHeaderOffset + 30 + Int64(u16(local, 26)) + Int64(u16(local, 28))
        guard dataStart + member.compressedSize <= fileSize else {
            throw ReadError.truncated("\(member.name): member data")
        }
        try handle.seek(toOffset: UInt64(dataStart))

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let out = try FileHandle(forWritingTo: destination)
        var succeeded = false
        defer {
            try? out.close()
            if !succeeded { try? FileManager.default.removeItem(at: destination) }
        }

        var crc = CRC32()
        var written: Int64 = 0
        func sink(_ chunk: UnsafeRawBufferPointer) throws {
            written += Int64(chunk.count)
            if written > member.uncompressedSize {
                throw ReadError.sizeMismatch(member: member.name, declared: member.uncompressedSize, actual: written)
            }
            crc.update(chunk)
            try out.write(contentsOf: Data(chunk))
        }

        if member.method == 0 {
            try copyStored(from: handle, count: member.compressedSize, member: member.name, sink: sink)
        } else {
            try inflate(from: handle, count: member.compressedSize, member: member.name, sink: sink)
        }

        guard written == member.uncompressedSize else {
            throw ReadError.sizeMismatch(member: member.name, declared: member.uncompressedSize, actual: written)
        }
        guard crc.value == member.crc32 else { throw ReadError.crcMismatch(member: member.name) }
        succeeded = true
    }

    // MARK: - gzip

    /// Decompresses a gzip file (RFC 1952) into `destination`, verifying the
    /// trailer's CRC-32 and size. gzip carries no member name; the caller
    /// derives one from the archive's own name.
    static func gunzip(_ url: URL, to destination: URL, availableDiskBytes: Int64? = nil) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = Int64(try handle.seekToEnd())
        guard fileSize >= 18 else { throw ReadError.truncated("gzip header and trailer") }

        try handle.seek(toOffset: 0)
        let header = try handle.read(upToCount: 10) ?? Data()
        guard header.count == 10, header[0] == 0x1F, header[1] == 0x8B else { throw ReadError.malformed("gzip signature") }
        guard header[2] == 8 else { throw ReadError.unsupportedMethod(UInt16(header[2]), member: url.lastPathComponent) }
        let flags = header[3]
        var offset: Int64 = 10
        if flags & 0x04 != 0 {                       // FEXTRA
            try handle.seek(toOffset: UInt64(offset))
            let len = try handle.read(upToCount: 2) ?? Data()
            guard len.count == 2 else { throw ReadError.truncated("gzip extra field") }
            offset += 2 + Int64(u16(len, len.startIndex))
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {   // FNAME, FCOMMENT
            try handle.seek(toOffset: UInt64(offset))
            var found = false
            while !found {
                let chunk = try handle.read(upToCount: 256) ?? Data()
                guard !chunk.isEmpty else { throw ReadError.truncated("gzip header string") }
                if let zero = chunk.firstIndex(of: 0) {
                    offset += Int64(zero - chunk.startIndex + 1)
                    found = true
                } else {
                    offset += Int64(chunk.count)
                }
            }
        }
        if flags & 0x02 != 0 { offset += 2 }         // FHCRC

        // Trailer: CRC-32 and ISIZE (mod 2^32) of the uncompressed data.
        try handle.seek(toOffset: UInt64(fileSize - 8))
        let trailer = try handle.read(upToCount: 8) ?? Data()
        guard trailer.count == 8 else { throw ReadError.truncated("gzip trailer") }
        let expectedCRC = u32(trailer, trailer.startIndex)
        let expectedSizeMod = u32(trailer, trailer.startIndex + 4)

        let compressedLength = fileSize - 8 - offset
        guard compressedLength > 0 else { throw ReadError.truncated("gzip payload") }

        // A gzip trailer only gives the size modulo 2^32, so the disk check
        // uses the compressed length as the floor; the size check after
        // decoding is exact modulo 2^32.
        let available = availableDiskBytes ?? freeSpace(at: destination.deletingLastPathComponent())
        if let available, available < compressedLength + diskMarginBytes {
            throw ReadError.insufficientDisk(member: url.lastPathComponent,
                                             needed: compressedLength + diskMarginBytes, available: available)
        }

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let out = try FileHandle(forWritingTo: destination)
        var succeeded = false
        defer {
            try? out.close()
            if !succeeded { try? FileManager.default.removeItem(at: destination) }
        }
        var crc = CRC32()
        var written: Int64 = 0
        try handle.seek(toOffset: UInt64(offset))
        try inflate(from: handle, count: compressedLength, member: url.lastPathComponent) { chunk in
            written += Int64(chunk.count)
            crc.update(chunk)
            try out.write(contentsOf: Data(chunk))
        }
        guard UInt32(truncatingIfNeeded: written) == expectedSizeMod else {
            throw ReadError.sizeMismatch(member: url.lastPathComponent, declared: Int64(expectedSizeMod), actual: written)
        }
        guard crc.value == expectedCRC else { throw ReadError.crcMismatch(member: url.lastPathComponent) }
        succeeded = true
    }

    // MARK: - Streaming primitives

    private static func copyStored(from handle: FileHandle, count: Int64, member: String,
                                   sink: (UnsafeRawBufferPointer) throws -> Void) throws {
        var remaining = count
        while remaining > 0 {
            let chunk = try handle.read(upToCount: Int(min(Int64(windowSize), remaining))) ?? Data()
            guard !chunk.isEmpty else { throw ReadError.truncated("\(member): stored data") }
            remaining -= Int64(chunk.count)
            try chunk.withUnsafeBytes { try sink($0) }
        }
    }

    /// Raw DEFLATE through a `compression_stream`, `count` compressed bytes
    /// from the handle's current offset, output delivered in windows.
    private static func inflate(from handle: FileHandle, count: Int64, member: String,
                                sink: (UnsafeRawBufferPointer) throws -> Void) throws {
        let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPointer.deallocate() }
        guard compression_stream_init(streamPointer, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ReadError.malformed("\(member): decoder could not start")
        }
        defer { compression_stream_destroy(streamPointer) }

        let source = UnsafeMutablePointer<UInt8>.allocate(capacity: windowSize)
        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: windowSize)
        defer { source.deallocate(); output.deallocate() }

        var remaining = count
        streamPointer.pointee.src_size = 0
        var status = COMPRESSION_STATUS_OK

        while status == COMPRESSION_STATUS_OK {
            if streamPointer.pointee.src_size == 0 && remaining > 0 {
                let chunk = try handle.read(upToCount: Int(min(Int64(windowSize), remaining))) ?? Data()
                guard !chunk.isEmpty else { throw ReadError.truncated("\(member): compressed data") }
                chunk.copyBytes(to: source, count: chunk.count)
                remaining -= Int64(chunk.count)
                streamPointer.pointee.src_ptr = UnsafePointer(source)
                streamPointer.pointee.src_size = chunk.count
            }
            let flags = remaining == 0 ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            streamPointer.pointee.dst_ptr = output
            streamPointer.pointee.dst_size = windowSize
            status = compression_stream_process(streamPointer, flags)
            let produced = windowSize - streamPointer.pointee.dst_size
            if produced > 0 {
                try sink(UnsafeRawBufferPointer(start: output, count: produced))
            }
            if status == COMPRESSION_STATUS_ERROR {
                throw ReadError.malformed("\(member): deflate stream is corrupt")
            }
            // Input exhausted with FINALIZE sent and nothing more produced:
            // the stream ended without signalling END — treat as truncated.
            if status == COMPRESSION_STATUS_OK, remaining == 0,
               streamPointer.pointee.src_size == 0, produced == 0 {
                throw ReadError.truncated("\(member): deflate stream ended early")
            }
        }
    }

    // MARK: - Helpers

    static func freeSpace(at directory: URL) -> Int64? {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private static func lastIndex(of pattern: [UInt8], in data: Data) -> Data.Index? {
        guard data.count >= pattern.count else { return nil }
        var i = data.endIndex - pattern.count
        while i >= data.startIndex {
            if data[i] == pattern[0], data[i..<i + pattern.count].elementsEqual(pattern) { return i }
            if i == data.startIndex { break }
            i -= 1
        }
        return nil
    }

    private static func u16(_ d: Data, _ i: Data.Index) -> UInt16 {
        UInt16(d[i]) | UInt16(d[i + 1]) << 8
    }
    private static func u32(_ d: Data, _ i: Data.Index) -> UInt32 {
        UInt32(d[i]) | UInt32(d[i + 1]) << 8 | UInt32(d[i + 2]) << 16 | UInt32(d[i + 3]) << 24
    }
    private static func u64(_ d: Data, _ i: Data.Index) -> UInt64 {
        UInt64(u32(d, i)) | UInt64(u32(d, i + 4)) << 32
    }

    /// CRC-32 (IEEE 802.3), the checksum ZIP and gzip both carry.
    struct CRC32 {
        private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
            var c = UInt32(n)
            for _ in 0..<8 { c = (c & 1) == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
            return c
        }
        private var state: UInt32 = 0xFFFF_FFFF

        var value: UInt32 { state ^ 0xFFFF_FFFF }

        mutating func update(_ bytes: UnsafeRawBufferPointer) {
            for b in bytes { state = Self.table[Int((state ^ UInt32(b)) & 0xFF)] ^ (state >> 8) }
        }

        mutating func update(_ data: Data) {
            data.withUnsafeBytes { update($0) }
        }

        static func checksum(_ data: Data) -> UInt32 {
            var c = CRC32()
            c.update(data)
            return c.value
        }
    }
}
