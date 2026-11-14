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
//  algorithm (solid archives included, x86/ARM/delta filters), and — rar7
//  patch, 2026-11-09 — the RAR 7.0 algorithm and dictionaries of any size
//  (the window is sized to the data, see `decoderWindowBytes`). The RAR 1.5
//  and RAR 2.0 algorithms are mailin's own (RARLegacyDecoder.swift). What
//  is not opened is refused per member with the reason (`compressionRefusal`):
//  a decoding window over the device limit, RAR 1.5/2.0 solid members after
//  the first, unknown algorithm versions. Audit R6:
//  RAR 4 solid archives are decoded member after member (the vendored
//  reader carries one window through them — patch in VENDORED.md), and
//  encrypted members and headers (RAR5 type-4 header, RAR4 MHD_PASSWORD)
//  open with the password given through Unlock… (RARCrypto.swift,
//  RARDecryptedArchive.swift); without one they stay locked. Multi-volume
//  sets are read as one archive by RARVolumeSet.swift.
//
//  Every header is CRC-checked; a damaged header ends the walk with a note
//  instead of a crash, and what was read before it is kept.
//

import Foundation

struct RARReader {

    /// Bound into import identities; bump when extraction behaviour changes.
    /// 2: compressed members decoded (vendored libarchive); volume sets read as one.
    /// 3: RAR 4 solid members after the first decoded; encrypted members opened with a password.
    /// 4: RAR 7.0 compression and RAR 5.0/7.0 dictionaries over 64 MiB decoded; RAR 1.5 and 2.0 compression decoded.
    static let version = 4
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
        /// RAR 5.0/7.0: the dictionary the member declares (nil for RAR 1.5–4.x and directories).
        var dictionaryBytes: Int64? = nil
        /// RAR 7.0 header whose data is in the RAR 5.0 algorithm (technote bit 0x100000).
        var rar5CompatibleAlgorithm = false
        /// RAR 5.0/7.0: the window the vendored decoder allocates for this
        /// member — the smallest power of two (at least 8 MiB) holding the
        /// stream up to the member's end, at most the declared dictionary
        /// rounded up to a power of two (`assignDecoderWindows`).
        var decoderWindowBytes: Int64? = nil
        /// False when a RAR 5.0 header says the unpacked size is unknown.
        var sizeIsKnown = true
        /// Index among the archive's file headers (one per member of a merged volume set) — the decoder's entry number.
        var ordinal = 0
        /// Volumes (0-based, within a set) holding the member's first and last part; 0 for a single archive.
        var firstVolume = 0
        var lastVolume = 0
        /// How the member's data is encrypted (nil when it is not).
        var encryption: Encryption? = nil
        /// The member's whole header block as read — decrypted when the
        /// archive's headers are encrypted. The decrypted view of the archive
        /// is built from it.
        var rawHeader: [UInt8] = []
        /// RAR 5.0: the BLAKE2sp digest from the hash record (a MAC when `encryption.useMAC`).
        var blake2: [UInt8]? = nil

        var methodName: String {
            if method == 0 { return "store" }
            switch format {
            case .rar4: return "RAR\(algorithmVersion / 10).\(algorithmVersion % 10) method \(method)"
            case .rar5: return "RAR\(algorithmVersion == 0 ? "5.0" : (algorithmVersion == 1 ? "7.0" : "algorithm \(algorithmVersion)")) method \(method)"
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
                // 15 = RAR 1.5, 20/26 = RAR 2.0 (mailin's decoder); 29/36 = RAR 2.9–4.x (libarchive).
                if RARReader.legacyAlgorithmVersions.contains(algorithmVersion) {
                    if isSolid {
                        return "RAR \(algorithmVersion / 10).\(algorithmVersion % 10) solid member after the first not opened (no real solid RAR 1.5/2.0 archive was available to verify the decoder on)"
                    }
                    if firstVolume != lastVolume {
                        return "a RAR \(algorithmVersion / 10).\(algorithmVersion % 10) member split across volumes is not opened"
                    }
                    return nil
                }
                guard algorithmVersion == 29 || algorithmVersion == 36 else {
                    return "RAR \(algorithmVersion / 10).\(algorithmVersion % 10) compression not opened (RAR 1.5, 2.0 and 2.9–4.x are read)"
                }
            case .rar5:
                guard algorithmVersion <= 1 else { return "RAR compression algorithm version \(algorithmVersion) not opened (RAR 5.0 and 7.0 are read)" }
                guard sizeIsKnown else { return "the unpacked size is not recorded in the header (the vendored decoder needs it)" }
                if let window = decoderWindowBytes, window > RARReader.maxDecoderWindowBytes {
                    let declared = dictionaryBytes.map { " for its \($0)-byte dictionary" } ?? ""
                    return "needs a \(window)-byte RAR decoding window\(declared), over this device's \(RARReader.maxDecoderWindowBytes)-byte limit"
                }
            }
            return nil
        }

        /// Why the member stays locked even with a password, or nil.
        var encryptionRefusal: String? {
            guard isEncrypted, let encryption else { return nil }
            switch encryption.scheme {
            case .rar3, .rar5: return nil
            case .legacy(let version):
                return "RAR \(version / 10).\(version % 10) encryption not opened (only the RAR 3.x–5.0 AES encryption is implemented)"
            case .unknown(let version):
                return "RAR 5.0 encryption version \(version) not opened"
            }
        }
    }

    /// The parameters an encrypted member's data needs.
    struct Encryption: Sendable, Equatable {
        enum Scheme: Sendable, Equatable {
            /// RAR 2.9–4.x: AES-128, SHA-1 key derivation.
            case rar3
            /// RAR 5.0: AES-256, PBKDF2-HMAC-SHA256.
            case rar5
            /// RAR 1.3–2.x's own ciphers (unpack version).
            case legacy(Int)
            /// RAR 5.0 encryption record with a version other than 0.
            case unknown(Int)
        }
        var scheme: Scheme
        /// RAR 4: 8 bytes, or nil (no salt); RAR 5.0: 16 bytes.
        var salt: [UInt8]?
        /// RAR 5.0: the data's AES IV.
        var iv: [UInt8] = []
        /// RAR 5.0: log2 of the PBKDF2 iteration count.
        var log2Count = 0
        /// RAR 5.0: the 8-byte password check value, when stored and intact.
        var passwordCheck: [UInt8]? = nil
        /// RAR 5.0: the stored CRC-32 / BLAKE2sp are MACs keyed by the password.
        var useMAC = false
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
        /// The headers were encrypted (and read with the password given).
        var headersEncrypted = false
        /// Where the header walk had to stop, when it did (damage named, members before it kept).
        var damage: String?
    }

    enum ReadError: Error, CustomStringConvertible, Equatable {
        case notARar
        case truncated(String)
        case malformed(String)
        case encryptedHeaders
        case encrypted(member: String)
        /// The password did not open the member (or, member nil, the archive's headers).
        case wrongPassword(member: String?)
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
            case .encryptedHeaders: return "The archive's headers are encrypted; its members are unknown until it is unlocked with its password."
            case .encrypted(let member): return "\(member): encrypted; it opens with its password."
            case .wrongPassword(let member): return member.map { "\($0): the password did not open it." } ?? "The password did not open the archive's encrypted headers."
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

    /// `password` is used only for an archive whose headers are encrypted
    /// (without one it throws `encryptedHeaders`; a wrong one, `wrongPassword`).
    static func read(url: URL, password: String? = nil) throws -> Archive {
        try read(source: try FileRandomAccessSource(url: url), keyring: password.map { RARKeyring(password: $0) })
    }

    static func read(source: RandomAccessSource, password: String? = nil) throws -> Archive {
        try read(source: source, keyring: password.map { RARKeyring(password: $0) })
    }

    static func read(source: RandomAccessSource, keyring: RARKeyring?) throws -> Archive {
        let head = try source.read(at: 0, count: 8)
        guard isRAR(head: head) else { throw ReadError.notARar }
        if head[head.startIndex + 6] == 0x01 {
            guard head.count == 8, head[head.startIndex + 7] == 0x00 else { throw ReadError.notARar }
            return try readRAR5(source, keyring: keyring)
        }
        return try readRAR4(source, keyring: keyring)
    }

    private static func roundUp16(_ n: Int) -> Int { (n + 15) & ~15 }

    // MARK: RAR 5.0

    struct VintReader {
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

    private static func readRAR5(_ source: RandomAccessSource, keyring: RARKeyring?) throws -> Archive {
        var archive = Archive(format: .rar5)
        var position: Int64 = 8
        let length = source.length
        /// After a type-4 header: every header is an IV and AES-256 blocks.
        var headerKey: [UInt8]?
        var firstEncryptedHeader = true
        while position + 7 <= length {
            // The header block as stored: CRC32 (4) + header size (vint) + header.
            let declaredCRC: UInt32
            let raw: [UInt8]          // size field + header
            let sizeFieldLength: Int
            let headerSize: Int
            let dataOffset: Int64
            if let headerKey {
                guard position + 32 <= length else { archive.damage = "encrypted header at \(position) is cut off"; break }
                let iv = [UInt8](try source.read(at: position, count: 16))
                let first = try RARCrypto.decryptCBC([UInt8](try source.read(at: position + 16, count: 16)), key: headerKey, iv: iv)
                var sizeReader = VintReader(bytes: Array(first[4...]))
                guard let size = try? sizeReader.int("header size"), size >= 2, size <= maxHeaderBytes else {
                    if firstEncryptedHeader { throw ReadError.wrongPassword(member: nil) }
                    archive.damage = "encrypted header at \(position) is unreadable"; break
                }
                let total = 4 + sizeReader.position + size
                let padded = roundUp16(total)
                let cipher = [UInt8](try source.read(at: position + 16, count: padded))
                guard cipher.count == padded else {
                    // A wrong key reads a nonsense size: that is the password's, not damage.
                    if firstEncryptedHeader { throw ReadError.wrongPassword(member: nil) }
                    archive.damage = "encrypted header at \(position) runs past the end of the file"; break
                }
                let plain = try RARCrypto.decryptCBC(cipher, key: headerKey, iv: iv)
                declaredCRC = UInt32(plain[0]) | UInt32(plain[1]) << 8 | UInt32(plain[2]) << 16 | UInt32(plain[3]) << 24
                raw = Array(plain[4..<total])
                sizeFieldLength = sizeReader.position
                headerSize = size
                dataOffset = position + 16 + Int64(padded)
            } else {
                let lead = try source.read(at: position, count: 7)
                guard lead.count == 7 else { archive.damage = "header at \(position) is cut off"; break }
                let leadBytes = [UInt8](lead)
                declaredCRC = UInt32(leadBytes[0]) | UInt32(leadBytes[1]) << 8 | UInt32(leadBytes[2]) << 16 | UInt32(leadBytes[3]) << 24
                var sizeReader = VintReader(bytes: Array(leadBytes[4...]))
                do { headerSize = try sizeReader.int("header size") } catch { archive.damage = "header size at \(position) is unreadable"; break }
                sizeFieldLength = sizeReader.position
                guard headerSize >= 2, headerSize <= maxHeaderBytes else { archive.damage = "header at \(position) declares \(headerSize) bytes"; break }
                let total = sizeFieldLength + headerSize
                let read = try source.read(at: position + 4, count: total)
                guard read.count == total else { archive.damage = "header at \(position) runs past the end of the file"; break }
                raw = [UInt8](read)
                dataOffset = position + 4 + Int64(total)
            }
            guard ZIPArchiveReader.CRC32.checksum(Data(raw)) == declaredCRC else {
                if headerKey != nil, firstEncryptedHeader { throw ReadError.wrongPassword(member: nil) }
                archive.damage = "header at \(position) fails its CRC check"; break
            }
            if headerKey != nil { firstEncryptedHeader = false }
            let rawHeader = [UInt8(declaredCRC & 0xFF), UInt8((declaredCRC >> 8) & 0xFF), UInt8((declaredCRC >> 16) & 0xFF), UInt8(declaredCRC >> 24)] + raw
            var r = VintReader(bytes: Array(raw[sizeFieldLength...]))
            _ = headerSize
            let type = try r.vint()
            let flags = try r.vint()
            var extraSize = 0, dataSize: Int64 = 0
            if flags & 0x0001 != 0 { extraSize = try r.int("extra area size") }
            if flags & 0x0002 != 0 {
                let v = try r.vint()
                guard v <= UInt64(Int64.max) else { throw ReadError.malformed("data size out of range") }
                dataSize = Int64(v)
            }
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
                var encryption: Encryption?
                var blake2: [UInt8]?
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
                        case 1:
                            isEncrypted = true
                            encryption = try? parseRAR5Encryption(&e)
                            if encryption == nil { encryption = Encryption(scheme: .unknown(-1), salt: nil) }
                        case 2:
                            if (try? e.vint()) == 0, let digest = try? e.take(32) { blake2 = digest }
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
                // Technote: dictionary = 128 KiB << N, N in bits 10–14 (4 bits used by
                // version 0, 5 by version 1); version 1 adds N/32 steps (bits 15–19).
                var dictionary: Int64?
                if !isDirectory, version <= 1 {
                    var d = Int64(0x20000) << Int64((compression >> 10) & (version == 0 ? 0x0F : 0x1F))
                    if version == 1 { d += d / 32 * Int64((compression >> 15) & 0x1F) }
                    dictionary = d
                }
                var member = Member(name: name, unpackedSize: unpacked, packedSize: dataSize, crc32: crc, method: method,
                                    algorithmVersion: version, isDirectory: isDirectory, isEncrypted: isEncrypted,
                                    isSolid: compression & 0x40 != 0, isSplitBefore: flags & 0x0008 != 0, isSplitAfter: flags & 0x0010 != 0,
                                    isSymlink: isSymlink, hostOS: hostOS == 0 ? "Windows" : (hostOS == 1 ? "Unix" : "OS \(hostOS)"),
                                    dataOffset: dataOffset, format: .rar5, dictionaryBytes: dictionary, sizeIsKnown: !unknownSize,
                                    ordinal: archive.members.count)
                member.encryption = encryption
                member.rawHeader = rawHeader
                member.blake2 = blake2
                member.rar5CompatibleAlgorithm = version == 1 && compression & 0x100000 != 0
                archive.members.append(member)
            case 4:   // archive encryption header: everything after it is encrypted
                guard let keyring else { throw ReadError.encryptedHeaders }
                let version = try r.vint()
                guard version == 0 else { throw ReadError.malformed("RAR 5.0 header encryption version \(version)") }
                let cryptFlags = try r.vint()
                let log2Count = Int(try r.byte())
                guard log2Count <= RARCrypto.rar5MaxLog2Count else { throw ReadError.malformed("RAR 5.0 key derivation count 2^\(log2Count)") }
                let salt = try r.take(16)
                let keys = keyring.rar5Keys(salt: salt, log2Count: log2Count)
                if cryptFlags & 0x0001 != 0 {
                    let check = try r.take(8), checksum = try r.take(4)
                    if RARCrypto.checkFieldIsIntact(check, checksum: checksum), check != keys.passwordCheck {
                        throw ReadError.wrongPassword(member: nil)
                    }
                }
                headerKey = keys.key
                archive.headersEncrypted = true
            case 5:   // end of archive
                let endFlags = try r.vint()
                archive.isLastVolume = endFlags & 0x0001 == 0
                assignDecoderWindows(&archive)
                return archive
            default:
                break   // unknown header types are skipped by their declared size
            }
            let (next, overflow) = dataOffset.addingReportingOverflow(dataSize)
            guard !overflow, next <= length else { archive.damage = "\(archive.members.last?.name ?? "a member")'s data runs past the end of the file"; break }
            position = next
        }
        assignDecoderWindows(&archive)
        return archive
    }

    /// The largest decoding window mailin lets the vendored RAR 5.0/7.0
    /// decoder allocate: a quarter of this device's memory, at most 4 GiB.
    static let maxDecoderWindowBytes: Int64 = min(Int64(4) << 30, Int64(ProcessInfo.processInfo.physicalMemory / 4))
    /// Kept for callers of the former 64 MiB dictionary ceiling: the limit is now the decoding window.
    static var maxDecoderDictionaryBytes: Int64 { maxDecoderWindowBytes }

    /// RAR 5.0/7.0: the window the patched libarchive reader allocates for
    /// each compressed member (rar7.patch, same rule): enough for every byte
    /// of the stream up to the member's end — in a solid archive the members
    /// before it count too — as a power of two of at least 8 MiB, never more
    /// than the declared dictionary rounded up to a power of two, and never
    /// shrinking inside a solid archive. Over-counts (stored members, parts
    /// of one member) only make the estimate safer.
    static func assignDecoderWindows(_ archive: inout Archive) {
        guard archive.format == .rar5 else { return }
        var streamBytes: Int64 = 0
        var solidWindow: Int64 = 0
        for i in archive.members.indices {
            let m = archive.members[i]
            guard !m.isDirectory, let declared = m.dictionaryBytes else { continue }
            let (sum, overflow) = (archive.isSolid ? streamBytes : 0).addingReportingOverflow(max(0, m.unpackedSize))
            let need = overflow ? Int64.max : sum
            if archive.isSolid { streamBytes = need }
            var declaredPow2: Int64 = 0x20000
            while declaredPow2 < declared && declaredPow2 < (Int64(1) << 61) { declaredPow2 <<= 1 }
            var window: Int64 = 8 * 1_048_576
            while window < need && window < declaredPow2 { window <<= 1 }
            window = min(window, declaredPow2)
            if archive.isSolid { window = max(window, solidWindow); solidWindow = window }
            if m.method != 0 { archive.members[i].decoderWindowBytes = window }
        }
    }

    /// The fields of a RAR 5.0 file encryption record (after its type).
    private static func parseRAR5Encryption(_ e: inout VintReader) throws -> Encryption {
        let version = try e.int("encryption version")
        guard version == 0 else { return Encryption(scheme: .unknown(version), salt: nil) }
        let flags = try e.vint()
        let log2Count = Int(try e.byte())
        guard log2Count <= RARCrypto.rar5MaxLog2Count else { return Encryption(scheme: .unknown(version), salt: nil) }
        var encryption = Encryption(scheme: .rar5, salt: try e.take(16))
        encryption.iv = try e.take(16)
        encryption.log2Count = log2Count
        if flags & 0x0001 != 0 {
            let check = try e.take(8), checksum = try e.take(4)
            if RARCrypto.checkFieldIsIntact(check, checksum: checksum) { encryption.passwordCheck = check }
        }
        encryption.useMAC = flags & 0x0002 != 0
        return encryption
    }

    // MARK: RAR 1.5–4.x

    private static func readRAR4(_ source: RandomAccessSource, keyring: RARKeyring?) throws -> Archive {
        var archive = Archive(format: .rar4)
        var position: Int64 = 7
        let length = source.length
        /// After a main header with MHD_PASSWORD: every block is an 8-byte salt and AES-128 blocks.
        var encryptedHeaders = false
        var firstEncryptedHeader = true
        while position + 7 <= length {
            let header: [UInt8]
            let dataStart: Int64
            if encryptedHeaders, let keyring {
                guard position + 24 <= length else { archive.damage = "encrypted block at \(position) is cut off"; break }
                let salt = [UInt8](try source.read(at: position, count: 8))
                let key = keyring.rar3Key(salt: salt)
                let first = try RARCrypto.decryptCBC([UInt8](try source.read(at: position + 8, count: 16)), key: key.key, iv: key.iv)
                let size = Int(UInt16(first[5]) | UInt16(first[6]) << 8)
                guard size >= 7 else {
                    if firstEncryptedHeader { throw ReadError.wrongPassword(member: nil) }
                    archive.damage = "encrypted block at \(position) declares \(size) header bytes"; break
                }
                let padded = roundUp16(size)
                let cipher = [UInt8](try source.read(at: position + 8, count: padded))
                guard cipher.count == padded else {
                    // A wrong key reads a nonsense size: that is the password's, not damage.
                    if firstEncryptedHeader { throw ReadError.wrongPassword(member: nil) }
                    archive.damage = "encrypted block at \(position) runs past the end of the file"; break
                }
                header = Array(try RARCrypto.decryptCBC(cipher, key: key.key, iv: key.iv).prefix(size))
                dataStart = position + 8 + Int64(padded)
            } else {
                let block = [UInt8](try source.read(at: position, count: 7))
                guard block.count == 7 else { archive.damage = "block at \(position) is cut off"; break }
                let size = Int(UInt16(block[5]) | UInt16(block[6]) << 8)
                guard size >= 7 else { archive.damage = "block at \(position) declares \(size) header bytes"; break }
                header = [UInt8](try source.read(at: position, count: size))
                guard header.count == size else { archive.damage = "block at \(position) runs past the end of the file"; break }
                dataStart = position + Int64(size)
            }
            let headerSize = header.count
            let declaredCRC = UInt16(header[0]) | UInt16(header[1]) << 8
            let type = header[2]
            let flags = UInt16(header[3]) | UInt16(header[4]) << 8
            // Header CRC: low 16 bits of CRC-32 over the header after the CRC field.
            var crc = ZIPArchiveReader.CRC32.checksum(Data(header[2...]))
            if UInt16(truncatingIfNeeded: crc) != declaredCRC, type == 0x74, flags & 0x0008 != 0, headerSize >= 32 {
                // RAR 1.5–2.x file comment inside the header (LHD_COMMENT): the CRC
                // covers the fields before it — through the name (and salt) only.
                let nameSize = Int(UInt16(header[26]) | UInt16(header[27]) << 8)
                let end = 32 + (flags & 0x0100 != 0 ? 8 : 0) + nameSize + (flags & 0x0400 != 0 ? 8 : 0)
                if end <= headerSize { crc = ZIPArchiveReader.CRC32.checksum(Data(header[2..<end])) }
            }
            if UInt16(truncatingIfNeeded: crc) != declaredCRC, type == 0x73, flags & 0x0002 != 0, headerSize >= 13 {
                // Likewise the RAR 1.5–2.x archive comment inside the main header (MHD_COMMENT).
                crc = ZIPArchiveReader.CRC32.checksum(Data(header[2..<13]))
            }
            guard UInt16(truncatingIfNeeded: crc) == declaredCRC else {
                if encryptedHeaders, firstEncryptedHeader { throw ReadError.wrongPassword(member: nil) }
                archive.damage = "block at \(position) fails its CRC check"; break
            }
            if encryptedHeaders { firstEncryptedHeader = false }
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
                if flags & 0x0080 != 0 {
                    guard keyring != nil else { throw ReadError.encryptedHeaders }
                    encryptedHeaders = true
                    archive.headersEncrypted = true
                }
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
                cursor += nameSize
                // RAR 1.5–4.x stores paths with "\" whatever the host (unrar and libarchive turn them into "/").
                let name = (flags & 0x0200 != 0 ? decodeRAR4UnicodeName(nameBytes) : (String(bytes: nameBytes, encoding: .utf8) ?? String(bytes: nameBytes, encoding: .isoLatin1) ?? "member"))
                    .replacingOccurrences(of: "\\", with: "/")
                addSize = packed
                let isDirectory = flags & 0xE0 == 0xE0
                let isSymlink = hostOS == 3 && (attributes & 0xF000) == 0xA000
                let isEncrypted = flags & 0x0004 != 0
                var member = Member(name: name, unpackedSize: unpacked, packedSize: packed, crc32: fileCRC, method: max(0, method),
                                    algorithmVersion: unpVer, isDirectory: isDirectory, isEncrypted: isEncrypted,
                                    isSolid: flags & 0x0010 != 0, isSplitBefore: flags & 0x0001 != 0, isSplitAfter: flags & 0x0002 != 0,
                                    isSymlink: isSymlink, hostOS: rar4HostOS(hostOS), dataOffset: dataStart, format: .rar4,
                                    ordinal: archive.members.count)
                if isEncrypted {
                    // FHD_SALT: eight bytes after the name. unrar: unpack version 29+ is AES (RAR 3), older its own ciphers.
                    let salt: [UInt8]? = flags & 0x0400 != 0 && cursor + 8 <= headerSize ? Array(header[cursor..<(cursor + 8)]) : nil
                    member.encryption = Encryption(scheme: unpVer >= 29 ? .rar3 : .legacy(unpVer), salt: salt)
                }
                member.rawHeader = header
                archive.members.append(member)
            case 0x7B:   // end of archive
                archive.isLastVolume = flags & 0x0001 == 0
                return archive
            default:
                break   // marker, comment, AV, sub-blocks, recovery, signature: skipped by size
            }
            if archive.damage != nil { break }
            let (next, overflow) = dataStart.addingReportingOverflow(addSize)
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
