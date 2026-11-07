//
//  RARReader.swift
//  ArchiveCore
//
//  Completion directive 2026-11-07 §6 "Containers": RAR archives read from
//  the published format descriptions — the RAR 5.0 header layout
//  (rarlab.com/technote.htm) and the RAR 1.5–4.x block layout (unrarsrc's
//  headers). Every member is listed exactly: name, sizes, CRC-32, compression
//  method and algorithm version, dictionary, encryption, solid and split
//  flags, directory / link kind. Stored members (method 0) are copied and
//  CRC-verified here. GAP-RAR (owner 2026-11-07): compressed members are
//  decoded by the vendored libarchive reader (RARDecompressor.swift) — the
//  RAR 2.9–4.x algorithm (LZSS, PPMd, the standard filters) and the RAR 5.0
//  algorithm (solid archives included, x86/ARM/delta filters). What it does
//  not open is refused per member with the reason (`compressionRefusal`):
//  the RAR 1.5 and 2.0 algorithms, RAR 1.5–4.x solid members after the first,
//  the RAR 7.0 algorithm, and RAR 5.0 dictionaries over 64 MiB. Encrypted
//  members and headers (RAR5 type-4 header, RAR4 MHD_PASSWORD) stay locked:
//  no password is asked for. Multi-volume sets are read as one archive by
//  RARVolumeSet.swift.
//
//  Every header is CRC-checked; a damaged header ends the walk with a note
//  instead of a crash, and what was read before it is kept.
//

import Foundation

struct RARReader {

    /// Bound into import identities; bump when extraction behaviour changes.
    /// 2: compressed members decoded (vendored libarchive); volume sets read as one.
    static let version = 2
    static let diskMarginBytes: Int64 = ZIPArchiveReader.diskMarginBytes
    private static let windowSize = 64 * 1024
    /// RAR 5.0 caps a header at 2 MiB; a larger declared size is damage.
    private static let maxHeaderBytes = 2 * 1_048_576

    enum Format: String, Sendable { case rar4 = "RAR 1.5–4.x", rar5 = "RAR 5.0" }

    static func isRAR(head: Data) -> Bool {
        head.count >= 7 && head.prefix(6).elementsEqual([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07]) && (head[head.startIndex + 6] == 0x00 || head[head.startIndex + 6] == 0x01)
    }

    struct Member: Sendable, Equatable {
        let name: String
        let unpackedSize: Int64
        var packedSize: Int64
        var crc32: UInt32?
        /// 0 = stored; 1…5 = RAR's compression levels (RAR4 0x31…0x35, RAR5 method field).
        let method: Int
        /// RAR4: the unpack version the member needs (20, 29 …); RAR5: 0 for the 5.0 algorithm, 1 for 7.0.
        let algorithmVersion: Int
        let isDirectory: Bool
        let isEncrypted: Bool
        let isSolid: Bool
        let isSplitBefore: Bool
        var isSplitAfter: Bool
        let isSymlink: Bool
        let hostOS: String
        let dataOffset: Int64
        let format: Format
        /// RAR 5.0: the dictionary the member declares (nil for RAR 1.5–4.x, directories, RAR 7.0).
        var dictionaryBytes: Int64? = nil
        /// False when a RAR 5.0 header says the unpacked size is unknown.
        var sizeIsKnown = true
        /// Index among the archive's file headers (one per member of a merged volume set) — the decoder's entry number.
        var ordinal = 0
        /// Volumes (0-based, within a set) holding the member's first and last part; 0 for a single archive.
        var firstVolume = 0
        var lastVolume = 0

        var methodName: String {
            if method == 0 { return "store" }
            switch format {
            case .rar4: return "RAR\(algorithmVersion / 10).\(algorithmVersion % 10) method \(method)"
            case .rar5: return "RAR\(algorithmVersion == 0 ? "5.0" : "7.0") method \(method)"
            }
        }
        var isJunk: Bool {
            let base = (name as NSString).lastPathComponent
            return name.hasPrefix("__MACOSX/") || base == ".DS_Store" || base == "Thumbs.db" || base.hasPrefix("._") || name.hasPrefix(".")
        }
        var unsafePath: String? { SevenZipReader.unsafePathReason(name) }

        /// Why the vendored decoder is not asked for this compressed member,
        /// or nil when it will be (always nil for a stored member).
        var compressionRefusal: String? {
            guard method != 0, !isDirectory else { return nil }
            switch format {
            case .rar4:
                // unrar: 15 = RAR 1.5, 20/26 = RAR 2.x, 29/36 = RAR 2.9–4.x; libarchive implements only the last.
                guard algorithmVersion == 29 || algorithmVersion == 36 else {
                    return "RAR \(algorithmVersion / 10).\(algorithmVersion % 10) compression not opened (the RAR 1.5 and 2.0 algorithms are not in the vendored decoder)"
                }
                if isSolid {
                    return "RAR 4 solid compression not opened (the vendored decoder reads only the first member of a RAR 4 solid archive)"
                }
            case .rar5:
                guard algorithmVersion == 0 else { return "RAR 7.0 compression not opened (the vendored decoder reads the RAR 5.0 algorithm)" }
                if let dictionaryBytes, dictionaryBytes > RARReader.maxDecoderDictionaryBytes {
                    return "needs a \(dictionaryBytes)-byte RAR dictionary, over the \(RARReader.maxDecoderDictionaryBytes)-byte limit of the vendored decoder"
                }
            }
            return nil
        }
    }

    struct Archive: Sendable {
        let format: Format
        var members: [Member] = []
        var isMultiVolume = false
        var isFirstVolume = true
        var isLastVolume = true
        var volumeNumber: Int?
        var isSolid = false
        var hasRecoveryRecord = false
        var isLocked = false
        /// Where the header walk had to stop, when it did (damage named, members before it kept).
        var damage: String?
    }

    enum ReadError: Error, CustomStringConvertible, Equatable {
        case notARar
        case truncated(String)
        case malformed(String)
        case encryptedHeaders
        case encrypted(member: String)
        /// A compressed member the vendored decoder does not open, with the reason.
        case compressionNotOpened(member: String, reason: String)
        /// The decoder stopped inside the member's data (damaged data, a failed BLAKE2 check …).
        case decodeFailed(member: String, detail: String)
        case splitAcrossVolumes(member: String, detail: String)
        case crcMismatch(member: String)
        case sizeMismatch(member: String, declared: Int64, actual: Int64)
        case budgetExceeded(member: String, limit: Int64)
        case insufficientDisk(member: String, needed: Int64, available: Int64)
        case unsafePath(member: String, reason: String)

        var description: String {
            switch self {
            case .notARar: return "Not a RAR archive (no Rar! signature)."
            case .truncated(let what): return "Archive is truncated: \(what)."
            case .malformed(let what): return "Archive is malformed: \(what)."
            case .encryptedHeaders: return "The archive's headers are encrypted; its members are unknown until it is unlocked (RAR decryption is not implemented)."
            case .encrypted(let member): return "\(member): encrypted; RAR decryption is not implemented."
            case .compressionNotOpened(let member, let reason): return "\(member): \(reason)."
            case .decodeFailed(let member, let detail): return "\(member): the RAR data could not be decoded (\(detail)) — the member is damaged."
            case .splitAcrossVolumes(let member, let detail): return "\(member): \(detail)."
            case .crcMismatch(let member): return "\(member): CRC-32 does not match — the member is damaged."
            case .sizeMismatch(let member, let declared, let actual): return "\(member): declared \(declared) bytes, produced \(actual) — refused."
            case .budgetExceeded(let member, let limit): return "\(member): copying stopped at the \(limit)-byte budget."
            case .insufficientDisk(let member, let needed, let available): return "\(member): needs \(needed) bytes of scratch space, \(available) available."
            case .unsafePath(let member, let reason): return "\(member): unsafe path (\(reason))."
            }
        }
    }

    // MARK: - Reading

    static func read(url: URL) throws -> Archive {
        try read(source: try FileRandomAccessSource(url: url))
    }

    static func read(source: RandomAccessSource) throws -> Archive {
        let head = try source.read(at: 0, count: 8)
        guard isRAR(head: head) else { throw ReadError.notARar }
        if head[head.startIndex + 6] == 0x01 {
            guard head.count == 8, head[head.startIndex + 7] == 0x00 else { throw ReadError.notARar }
            return try readRAR5(source)
        }
        return try readRAR4(source)
    }

    // MARK: RAR 5.0

    private struct VintReader {
        let bytes: [UInt8]
        var position = 0
        var remaining: Int { bytes.count - position }
        mutating func byte() throws -> UInt8 {
            guard position < bytes.count else { throw ReadError.truncated("RAR header field") }
            let b = bytes[position]; position += 1; return b
        }
        /// RAR5 variable-length integer: 7 bits per byte, low first, high bit = more.
        mutating func vint() throws -> UInt64 {
            var value: UInt64 = 0
            for i in 0..<10 {
                let b = try byte()
                value |= UInt64(b & 0x7F) << UInt64(7 * i)
                if b & 0x80 == 0 { return value }
            }
            throw ReadError.malformed("RAR header integer longer than 10 bytes")
        }
        mutating func int(_ what: String) throws -> Int {
            let v = try vint()
            guard v <= UInt64(Int.max) else { throw ReadError.malformed("\(what) \(v) out of range") }
            return Int(v)
        }
        mutating func u32() throws -> UInt32 {
            let b = try take(4)
            return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
        }
        mutating func take(_ n: Int) throws -> [UInt8] {
            guard n >= 0, n <= remaining else { throw ReadError.truncated("RAR header field") }
            let out = Array(bytes[position..<(position + n)]); position += n; return out
        }
    }

    private static func readRAR5(_ source: RandomAccessSource) throws -> Archive {
        var archive = Archive(format: .rar5)
        var position: Int64 = 8
        let length = source.length
        while position + 7 <= length {
            // CRC32 (4) + header size (vint, up to 3 bytes for the 2 MiB cap).
            let lead = try source.read(at: position, count: 7)
            guard lead.count == 7 else { archive.damage = "header at \(position) is cut off"; break }
            let leadBytes = [UInt8](lead)
            let declaredCRC = UInt32(leadBytes[0]) | UInt32(leadBytes[1]) << 8 | UInt32(leadBytes[2]) << 16 | UInt32(leadBytes[3]) << 24
            var sizeReader = VintReader(bytes: Array(leadBytes[4...]))
            let headerSize: Int
            do { headerSize = try sizeReader.int("header size") } catch { archive.damage = "header size at \(position) is unreadable"; break }
            let sizeFieldLength = sizeReader.position
            guard headerSize >= 2, headerSize <= maxHeaderBytes else { archive.damage = "header at \(position) declares \(headerSize) bytes"; break }
            let headerStart = position + 4
            let total = sizeFieldLength + headerSize
            let raw = try source.read(at: headerStart, count: total)
            guard raw.count == total else { archive.damage = "header at \(position) runs past the end of the file"; break }
            guard ZIPArchiveReader.CRC32.checksum(raw) == declaredCRC else { archive.damage = "header at \(position) fails its CRC check"; break }
            var r = VintReader(bytes: Array([UInt8](raw)[sizeFieldLength...]))
            let type = try r.vint()
            let flags = try r.vint()
            var extraSize = 0, dataSize: Int64 = 0
            if flags & 0x0001 != 0 { extraSize = try r.int("extra area size") }
            if flags & 0x0002 != 0 {
                let v = try r.vint()
                guard v <= UInt64(Int64.max) else { throw ReadError.malformed("data size out of range") }
                dataSize = Int64(v)
            }
            let dataOffset = headerStart + Int64(total)
            switch type {
            case 1:   // main archive header
                let archiveFlags = try r.vint()
                archive.isMultiVolume = archiveFlags & 0x0001 != 0
                if archiveFlags & 0x0002 != 0 { archive.volumeNumber = try r.int("volume number"); archive.isFirstVolume = false }
                archive.isSolid = archiveFlags & 0x0004 != 0
                archive.hasRecoveryRecord = archiveFlags & 0x0008 != 0
                archive.isLocked = archiveFlags & 0x0010 != 0
            case 2, 3:   // file header, service header
                guard type == 2 else { break }
                let fileFlags = try r.vint()
                let unpackedRaw = try r.vint()
                let attributes = try r.vint()
                if fileFlags & 0x0002 != 0 { _ = try r.u32() }   // mtime
                var crc: UInt32?
                if fileFlags & 0x0004 != 0 { crc = try r.u32() }
                let compression = try r.vint()
                let hostOS = try r.vint()
                let nameLength = try r.int("name length")
                let nameBytes = try r.take(nameLength)
                let name = String(decoding: nameBytes, as: UTF8.self)
                var isEncrypted = false, isSymlink = false
                if extraSize > 0 {
                    let extraStart = r.bytes.count - extraSize
                    guard extraStart >= r.position else { throw ReadError.malformed("\(name): extra area overlaps the header") }
                    var e = VintReader(bytes: Array(r.bytes[extraStart...]))
                    while e.remaining > 0 {
                        let recordSize = try e.int("extra record size")
                        guard recordSize >= 1, recordSize <= e.remaining else { break }
                        let recordEnd = e.position + recordSize
                        let recordType = try e.vint()
                        switch recordType {
                        case 1: isEncrypted = true
                        case 5:
                            let redirectType = try e.vint()
                            if (1...3).contains(redirectType) { isSymlink = true }
                        default: break
                        }
                        e.position = recordEnd
                    }
                }
                let isDirectory = fileFlags & 0x0001 != 0
                let unknownSize = fileFlags & 0x0008 != 0
                let unpacked = unknownSize ? dataSize : Int64(min(unpackedRaw, UInt64(Int64.max)))
                let method = Int((compression >> 7) & 0x07)
                let version = Int(compression & 0x3F)
                let unixMode = hostOS == 1 ? attributes : 0
                if (unixMode & 0xF000) == 0xA000 { isSymlink = true }
                // Bits 10–14: dictionary = 128 KiB << N (RAR 5.0 algorithm; RAR 7.0 adds a fraction).
                let dictionary: Int64? = isDirectory || version != 0 ? nil : Int64(0x20000) << Int64((compression >> 10) & 0x0F)
                archive.members.append(Member(name: name, unpackedSize: unpacked, packedSize: dataSize, crc32: crc, method: method,
                                              algorithmVersion: version, isDirectory: isDirectory, isEncrypted: isEncrypted,
                                              isSolid: compression & 0x40 != 0, isSplitBefore: flags & 0x0008 != 0, isSplitAfter: flags & 0x0010 != 0,
                                              isSymlink: isSymlink, hostOS: hostOS == 0 ? "Windows" : (hostOS == 1 ? "Unix" : "OS \(hostOS)"),
                                              dataOffset: dataOffset, format: .rar5, dictionaryBytes: dictionary, sizeIsKnown: !unknownSize,
                                              ordinal: archive.members.count))
            case 4:   // archive encryption header: everything after it is encrypted
                throw ReadError.encryptedHeaders
            case 5:   // end of archive
                let endFlags = try r.vint()
                archive.isLastVolume = endFlags & 0x0001 == 0
                return archive
            default:
                break   // unknown header types are skipped by their declared size
            }
            let (next, overflow) = dataOffset.addingReportingOverflow(dataSize)
            guard !overflow, next <= length else { archive.damage = "\(archive.members.last?.name ?? "a member")'s data runs past the end of the file"; break }
            position = next
        }
        return archive
    }

    // MARK: RAR 1.5–4.x

    private static func readRAR4(_ source: RandomAccessSource) throws -> Archive {
        var archive = Archive(format: .rar4)
        var position: Int64 = 7
        let length = source.length
        while position + 7 <= length {
            let block = [UInt8](try source.read(at: position, count: 7))
            guard block.count == 7 else { archive.damage = "block at \(position) is cut off"; break }
            let declaredCRC = UInt16(block[0]) | UInt16(block[1]) << 8
            let type = block[2]
            let flags = UInt16(block[3]) | UInt16(block[4]) << 8
            let headerSize = Int(UInt16(block[5]) | UInt16(block[6]) << 8)
            guard headerSize >= 7 else { archive.damage = "block at \(position) declares \(headerSize) header bytes"; break }
            let header = [UInt8](try source.read(at: position, count: headerSize))
            guard header.count == headerSize else { archive.damage = "block at \(position) runs past the end of the file"; break }
            // Header CRC: low 16 bits of CRC-32 over the header after the CRC field.
            let crc = ZIPArchiveReader.CRC32.checksum(Data(header[2...]))
            guard UInt16(truncatingIfNeeded: crc) == declaredCRC else { archive.damage = "block at \(position) fails its CRC check"; break }
            var addSize: Int64 = 0
            if flags & 0x8000 != 0 || type == 0x74 || type == 0x7A {
                guard headerSize >= 11 else { archive.damage = "block at \(position) is too short for its data size"; break }
                addSize = Int64(u32(header, 7))
            }
            switch type {
            case 0x73:   // main header
                archive.isMultiVolume = flags & 0x0001 != 0
                archive.isLocked = flags & 0x0004 != 0
                archive.isSolid = flags & 0x0008 != 0
                archive.hasRecoveryRecord = flags & 0x0040 != 0
                archive.isFirstVolume = flags & 0x0100 != 0 || !archive.isMultiVolume
                if flags & 0x0080 != 0 { throw ReadError.encryptedHeaders }
            case 0x74:   // file header
                guard headerSize >= 32 else { archive.damage = "file header at \(position) is too short"; break }
                var packed = Int64(u32(header, 7))
                var unpacked = Int64(u32(header, 11))
                // PACK_SIZE 7, UNP_SIZE 11, HOST_OS 15, FILE_CRC 16, FTIME 20, UNP_VER 24, METHOD 25, NAME_SIZE 26, ATTR 28, name 32.
                let hostOS = header[15]
                let fileCRC = u32(header, 16)
                let unpVer = Int(header[24])
                let method = Int(header[25]) - 0x30
                let nameSize = Int(UInt16(header[26]) | UInt16(header[27]) << 8)
                let attributes = u32(header, 28)
                var cursor = 32
                if flags & 0x0100 != 0 {
                    guard headerSize >= cursor + 8 else { archive.damage = "file header at \(position) lacks its 64-bit sizes"; break }
                    packed |= Int64(u32(header, cursor)) << 32
                    unpacked |= Int64(u32(header, cursor + 4)) << 32
                    cursor += 8
                }
                guard cursor + nameSize <= headerSize else { archive.damage = "file header at \(position) has a name longer than the header"; break }
                let nameBytes = Array(header[cursor..<(cursor + nameSize)])
                // RAR 1.5–4.x stores paths with "\" whatever the host (unrar and libarchive turn them into "/").
                let name = (flags & 0x0200 != 0 ? decodeRAR4UnicodeName(nameBytes) : (String(bytes: nameBytes, encoding: .utf8) ?? String(bytes: nameBytes, encoding: .isoLatin1) ?? "member"))
                    .replacingOccurrences(of: "\\", with: "/")
                addSize = packed
                let isDirectory = flags & 0xE0 == 0xE0
                let isSymlink = hostOS == 3 && (attributes & 0xF000) == 0xA000
                archive.members.append(Member(name: name, unpackedSize: unpacked, packedSize: packed, crc32: fileCRC, method: max(0, method),
                                              algorithmVersion: unpVer, isDirectory: isDirectory, isEncrypted: flags & 0x0004 != 0,
                                              isSolid: flags & 0x0010 != 0, isSplitBefore: flags & 0x0001 != 0, isSplitAfter: flags & 0x0002 != 0,
                                              isSymlink: isSymlink, hostOS: rar4HostOS(hostOS), dataOffset: position + Int64(headerSize), format: .rar4,
                                              ordinal: archive.members.count))
            case 0x7B:   // end of archive
                archive.isLastVolume = flags & 0x0001 == 0
                return archive
            default:
                break   // marker, comment, AV, sub-blocks, recovery, signature: skipped by size
            }
            if archive.damage != nil { break }
            let (next, overflow) = (position + Int64(headerSize)).addingReportingOverflow(addSize)
            guard !overflow, next <= length else { archive.damage = "\(archive.members.last?.name ?? "a member")'s data runs past the end of the file"; break }
            position = next
        }
        return archive
    }

    private static func rar4HostOS(_ code: UInt8) -> String {
        switch code {
        case 0: return "MS-DOS"
        case 1: return "OS/2"
        case 2: return "Windows"
        case 3: return "Unix"
        case 4: return "Mac OS"
        case 5: return "BeOS"
        default: return "OS \(code)"
        }
    }

    /// RAR 2.9 Unicode file names: a zero-terminated 8-bit name followed by
    /// an encoded form that patches it to UTF-16 (unrarsrc DecodeFileName).
    static func decodeRAR4UnicodeName(_ bytes: [UInt8]) -> String {
        guard let zero = bytes.firstIndex(of: 0) else { return String(decoding: bytes, as: UTF8.self) }
        let name = Array(bytes[..<zero])
        let enc = Array(bytes[(zero + 1)...])
        guard !enc.isEmpty else { return String(bytes: name, encoding: .utf8) ?? String(decoding: name, as: UTF8.self) }
        var out: [UInt16] = []
        var encPos = 0, decPos = 0
        var flags: UInt8 = 0, flagBits = 0
        let highByte = UInt16(enc[encPos]); encPos += 1
        let maxDecoded = name.count + 1
        while encPos < enc.count, decPos < maxDecoded {
            if flagBits == 0 { flags = enc[encPos]; encPos += 1; flagBits = 8 }
            switch flags >> 6 {
            case 0:
                guard encPos < enc.count else { break }
                out.append(UInt16(enc[encPos])); encPos += 1; decPos += 1
            case 1:
                guard encPos < enc.count else { break }
                out.append(UInt16(enc[encPos]) + (highByte << 8)); encPos += 1; decPos += 1
            case 2:
                guard encPos + 1 < enc.count else { encPos = enc.count; break }
                out.append(UInt16(enc[encPos]) | UInt16(enc[encPos + 1]) << 8); encPos += 2; decPos += 1
            default:
                guard encPos < enc.count else { break }
                var length = Int(enc[encPos]); encPos += 1
                if length & 0x80 != 0 {
                    guard encPos < enc.count else { break }
                    let correction = UInt16(enc[encPos]); encPos += 1
                    length = (length & 0x7F) + 2
                    while length > 0, decPos < maxDecoded, decPos < name.count {
                        out.append(((UInt16(name[decPos]) + correction) & 0xFF) + (highByte << 8))
                        length -= 1; decPos += 1
                    }
                } else {
                    length += 2
                    while length > 0, decPos < maxDecoded, decPos < name.count {
                        out.append(UInt16(name[decPos]))
                        length -= 1; decPos += 1
                    }
                }
            }
            flags <<= 2
            flagBits -= 2
        }
        if let end = out.firstIndex(of: 0) { out.removeSubrange(end...) }
        return String(decoding: out, as: UTF16.self)
    }

    // MARK: - Extraction (stored members)

    /// Copies a stored member to `destination`, CRC-32 verified. Encrypted
    /// and split members throw their named refusal; a compressed member is
    /// decoded only through `RARReader.Extractor`, which has the archive's
    /// file(s) for the libarchive pass.
    static func extract(_ member: Member, source: RandomAccessSource, to destination: URL,
                        maxOutputBytes: Int64? = nil, availableDiskBytes: Int64? = nil) throws {
        if let reason = member.unsafePath { throw ReadError.unsafePath(member: member.name, reason: reason) }
        guard !member.isDirectory else { throw ReadError.malformed("\(member.name): is a directory") }
        if member.isEncrypted { throw ReadError.encrypted(member: member.name) }
        if member.isSplitBefore || member.isSplitAfter {
            throw ReadError.splitAcrossVolumes(member: member.name, detail: member.isSplitBefore ? "continues from the previous volume" : "continues in the next volume")
        }
        guard member.method == 0 else {
            throw ReadError.compressionNotOpened(member: member.name, reason: member.compressionRefusal ?? "\(member.methodName) is decoded from the archive file, not from a byte source")
        }
        guard member.packedSize == member.unpackedSize else {
            throw ReadError.sizeMismatch(member: member.name, declared: member.unpackedSize, actual: member.packedSize)
        }
        let available = availableDiskBytes ?? ZIPArchiveReader.freeSpace(at: destination.deletingLastPathComponent())
        if let available, available < member.unpackedSize + diskMarginBytes {
            throw ReadError.insufficientDisk(member: member.name, needed: member.unpackedSize + diskMarginBytes, available: available)
        }
        guard member.dataOffset >= 0, member.dataOffset <= source.length - member.packedSize else {
            throw ReadError.truncated("\(member.name): data")
        }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let out = try FileHandle(forWritingTo: destination)
        var succeeded = false
        defer {
            try? out.close()
            if !succeeded { try? FileManager.default.removeItem(at: destination) }
        }
        var crc = ZIPArchiveReader.CRC32()
        var written: Int64 = 0
        var cursor = member.dataOffset
        while written < member.packedSize {
            let chunk = try source.read(at: cursor, count: Int(min(Int64(windowSize), member.packedSize - written)))
            guard !chunk.isEmpty else { throw ReadError.truncated("\(member.name): data") }
            written += Int64(chunk.count)
            cursor += Int64(chunk.count)
            if let maxOutputBytes, written > maxOutputBytes { throw ReadError.budgetExceeded(member: member.name, limit: maxOutputBytes) }
            crc.update(chunk)
            try out.write(contentsOf: chunk)
        }
        if let expected = member.crc32, crc.value != expected { throw ReadError.crcMismatch(member: member.name) }
        succeeded = true
    }

    private static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }
}
