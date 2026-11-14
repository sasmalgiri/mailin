//
//  RARDecryptedArchive.swift
//  ArchiveCore
//
//  Audit R6 (RAR row): an encrypted RAR archive opened with its password.
//  libarchive does not decrypt RAR, so the decoder is handed a plain view of
//  the archive instead of the file: the members' headers as they read once
//  decrypted, with the encryption records taken out (and, where the archive
//  keyed its checksums to the password, the checksums too — the extractor
//  checks those itself), followed by each member's data decrypted on the fly
//  as the decoder pulls it. Nothing is written to disk and the decoder never
//  sees the password. A solid stream is presented whole, so its members are
//  decoded in order through one window, exactly as from a plain archive.
//
//  The view holds the members that lie whole in one volume; one split over
//  volumes is not in it and is named by the extractor.
//

import Foundation
import CLibArchiveRAR

/// The password given for one archive and the keys derived from it, cached
/// per salt (RAR 3 derivation is 262,144 SHA-1 rounds; RAR 5.0 is PBKDF2).
/// Lives as long as the extractor that was given the password — never stored.
final class RARKeyring {
    let password: String
    private var rar3: [[UInt8]: RARCrypto.RAR3Key] = [:]
    private var rar5: [[UInt8]: RARCrypto.RAR5Keys] = [:]

    init(password: String) { self.password = password }

    func rar3Key(salt: [UInt8]?) -> RARCrypto.RAR3Key {
        let id = salt ?? []
        if let key = rar3[id] { return key }
        let key = RARCrypto.rar3Key(password: password, salt: salt)
        rar3[id] = key
        return key
    }

    func rar5Keys(salt: [UInt8], log2Count: Int) -> RARCrypto.RAR5Keys {
        let id = salt + [UInt8(log2Count)]
        if let keys = rar5[id] { return keys }
        let keys = RARCrypto.rar5Keys(password: password, salt: salt, log2Count: log2Count)
        rar5[id] = keys
        return keys
    }
}

extension RARReader {

    /// The plain stream the decoder reads: literal header bytes and member data, decrypted as it is read.
    final class DecryptedStream {
        enum Segment {
            case bytes([UInt8])
            case plain(RandomAccessSource, offset: Int64, length: Int64)
            /// AES-CBC data: `cipherLength` bytes at `offset`, of which the first `outputLength` decrypted ones are handed out.
            case encrypted(RandomAccessSource, offset: Int64, cipherLength: Int64, outputLength: Int64, key: () throws -> (key: [UInt8], iv: [UInt8]))
            /// Built when the stream reaches it (a member whose header needs its key to be written).
            case deferred(() throws -> [Segment])

            /// -1: not known until built.
            var length: Int64 {
                switch self {
                case .bytes(let b): return Int64(b.count)
                case .plain(_, _, let length): return length
                case .encrypted(_, _, _, let output, _): return output
                case .deferred: return -1
                }
            }
        }

        private var segments: [Segment]
        private var index = 0
        /// Position inside the current segment (output bytes).
        private var offset: Int64 = 0
        private var decryptor: RARCrypto.CBCDecryptor?
        private var cachedKey: (index: Int, key: [UInt8], iv: [UInt8])?
        private static let chunk = 256 * 1024
        private let buffer = UnsafeMutableRawPointer.allocate(byteCount: DecryptedStream.chunk, alignment: 16)
        /// What stopped the stream, for the decoder's message.
        private(set) var failure: Error?

        init(segments: [Segment]) { self.segments = segments.filter { $0.length != 0 } }

        /// Replaces a deferred segment at `index` by what it builds.
        private func expand() throws {
            guard index < segments.count, case .deferred(let make) = segments[index] else { return }
            segments.replaceSubrange(index...index, with: try make().filter { $0.length != 0 })
            offset = 0
            decryptor = nil
            cachedKey = nil
        }
        deinit { buffer.deallocate() }

        private func key(for segment: Int) throws -> (key: [UInt8], iv: [UInt8]) {
            if let cachedKey, cachedKey.index == segment { return (cachedKey.key, cachedKey.iv) }
            guard case .encrypted(_, _, _, _, let provider) = segments[segment] else { throw ReadError.malformed("not an encrypted segment") }
            let k = try provider()
            cachedKey = (segment, k.key, k.iv)
            return k
        }

        /// The next chunk in `buffer`: its length, 0 at the end, -1 on failure.
        func next() -> Int {
            do {
                while index < segments.count {
                    if case .deferred = segments[index] { try expand(); continue }
                    let segment = segments[index]
                    let left = segment.length - offset
                    if left <= 0 { index += 1; offset = 0; decryptor = nil; continue }
                    switch segment {
                    case .deferred:
                        continue
                    case .bytes(let bytes):
                        let n = Int(min(left, Int64(Self.chunk)))
                        bytes.withUnsafeBytes { buffer.copyMemory(from: $0.baseAddress! + Int(offset), byteCount: n) }
                        offset += Int64(n)
                        return n
                    case .plain(let source, let start, _):
                        let data = try source.read(at: start + offset, count: Int(min(left, Int64(Self.chunk))))
                        guard !data.isEmpty else { throw ReadError.truncated("member data") }
                        data.withUnsafeBytes { buffer.copyMemory(from: $0.baseAddress!, byteCount: data.count) }
                        offset += Int64(data.count)
                        return data.count
                    case .encrypted(let source, let start, let cipherLength, _, _):
                        if decryptor == nil {
                            // CBC: the IV of a block is the cipher block before it.
                            let k = try key(for: index)
                            let iv = offset == 0 ? k.iv : [UInt8](try source.read(at: start + offset - 16, count: 16))
                            decryptor = try RARCrypto.CBCDecryptor(key: k.key, iv: iv)
                        }
                        let cipherLeft = cipherLength - offset
                        let take = Int(min(cipherLeft, Int64(Self.chunk))) & ~15
                        guard take > 0 else { throw ReadError.malformed("encrypted data is not a whole number of AES blocks") }
                        let cipher = [UInt8](try source.read(at: start + offset, count: take))
                        guard cipher.count == take else { throw ReadError.truncated("member data") }
                        let plain = try decryptor!.update(cipher)
                        let n = Int(min(Int64(take), left))
                        plain.withUnsafeBytes { buffer.copyMemory(from: $0.baseAddress!, byteCount: n) }
                        offset += Int64(take)
                        return n
                    }
                }
                return 0
            } catch {
                failure = error
                return -1
            }
        }

        /// Passes over up to `request` bytes without reading them (0 when it cannot).
        func skip(_ request: Int64) -> Int64 {
            guard index < segments.count, request > 0 else { return 0 }
            if case .deferred = segments[index] {
                do { try expand() } catch { return 0 }
                return skip(request)
            }
            let segment = segments[index]
            let left = segment.length - offset
            if case .encrypted = segment {
                // Only whole blocks can be passed over; the decryptor restarts from the previous cipher block.
                guard request < left else {
                    index += 1; offset = 0; decryptor = nil
                    return left
                }
                let step = request & ~15
                guard step > 0 else { return 0 }
                offset += step
                decryptor = nil
                return step
            }
            let step = min(request, left)
            offset += step
            if offset >= segment.length { index += 1; offset = 0; decryptor = nil }
            return step
        }

        var bufferPointer: UnsafeRawPointer { UnsafeRawPointer(buffer) }
    }

    // MARK: - Building the plain view

    /// The decoder's view of `members` (in archive order) with every
    /// encrypted one decrypted by `keyring`. `source(volume)` opens a volume.
    static func decryptedStream(format: Format, isSolid: Bool, members: [Member], keyring: RARKeyring,
                                source: (Int) throws -> RandomAccessSource) throws -> DecryptedStream {
        var segments: [DecryptedStream.Segment] = []
        switch format {
        case .rar4:
            segments.append(.bytes([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]))
            segments.append(.bytes(rar4Block(type: 0x73, flags: isSolid ? 0x0008 : 0, body: [0, 0, 0, 0, 0, 0])))
        case .rar5:
            segments.append(.bytes([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]))
            segments.append(.bytes(rar5Block(vint(1) + vint(0) + vint(isSolid ? 0x0004 : 0))))
        }
        for member in members {
            let volume = try source(member.firstVolume)
            let isStored = member.method == 0 && !member.isDirectory
            if format == .rar5, member.isEncrypted, !isStored, member.packedSize > 0,
               let encryption = member.encryption, encryption.scheme == .rar5, let salt = encryption.salt {
                // The RAR 5.0 decoder reads compressed blocks until the data ends:
                // the AES padding after the last block is cut off, which needs the key.
                segments.append(.deferred {
                    let key = keyring.rar5Keys(salt: salt, log2Count: encryption.log2Count).key
                    let length = try rar5CompressedLength(source: volume, offset: member.dataOffset, cipherLength: member.packedSize,
                                                          key: key, iv: encryption.iv) ?? member.packedSize
                    return [.bytes(try plainRAR5Header(member, dataSize: length)),
                            .encrypted(volume, offset: member.dataOffset, cipherLength: member.packedSize, outputLength: length,
                                       key: { (key, encryption.iv) })]
                })
                continue
            }
            let dataLength: Int64 = member.isEncrypted && isStored ? member.unpackedSize : member.packedSize
            switch format {
            case .rar4: segments.append(.bytes(try plainRAR4Header(member, packedSize: dataLength)))
            case .rar5: segments.append(.bytes(try plainRAR5Header(member, dataSize: dataLength)))
            }
            guard member.packedSize > 0 else { continue }
            if member.isEncrypted, let encryption = member.encryption {
                guard member.packedSize % 16 == 0 else { throw ReadError.malformed("\(member.name): encrypted data is not a whole number of AES blocks") }
                let provider: () throws -> (key: [UInt8], iv: [UInt8])
                switch encryption.scheme {
                case .rar3:
                    provider = { let k = keyring.rar3Key(salt: encryption.salt); return (k.key, k.iv) }
                case .rar5:
                    guard let salt = encryption.salt else { throw ReadError.malformed("\(member.name): encryption record without a salt") }
                    provider = { (keyring.rar5Keys(salt: salt, log2Count: encryption.log2Count).key, encryption.iv) }
                case .legacy, .unknown:
                    throw ReadError.compressionNotOpened(member: member.name, reason: member.encryptionRefusal ?? "encryption not opened")
                }
                segments.append(.encrypted(volume, offset: member.dataOffset, cipherLength: member.packedSize, outputLength: dataLength, key: provider))
            } else {
                segments.append(.plain(volume, offset: member.dataOffset, length: member.packedSize))
            }
        }
        switch format {
        case .rar4: segments.append(.bytes(rar4Block(type: 0x7B, flags: 0x4000, body: [])))
        case .rar5: segments.append(.bytes(rar5Block(vint(5) + vint(0) + vint(0))))
        }
        return DecryptedStream(segments: segments)
    }

    /// RAR 5.0 compressed data under AES: the length of its blocks up to the
    /// one marked last (the rest is padding), walking the block headers
    /// (flags, check byte 0x5A ^ flags ^ size bytes, 1–3 size bytes) and
    /// decrypting only the cipher blocks that hold them. Nil when a header
    /// does not check out (a wrong password, or damage).
    static func rar5CompressedLength(source: RandomAccessSource, offset: Int64, cipherLength: Int64,
                                     key: [UInt8], iv: [UInt8]) throws -> Int64? {
        func plain(at position: Int64, count: Int) throws -> [UInt8] {
            let first = position & ~15
            let last = min(cipherLength, (position + Int64(count) + 15) & ~15)
            guard last > first else { return [] }
            let blockIV = first == 0 ? iv : [UInt8](try source.read(at: offset + first - 16, count: 16))
            let cipher = [UInt8](try source.read(at: offset + first, count: Int(last - first)))
            guard cipher.count == Int(last - first), blockIV.count == 16 else { return [] }
            let decrypted = try RARCrypto.decryptCBC(cipher, key: key, iv: blockIV)
            return Array(decrypted[Int(position - first)...].prefix(count))
        }
        var position: Int64 = 0
        while position < cipherLength {
            let h = try plain(at: position, count: 6)
            guard h.count >= 3 else { return nil }
            let flags = h[0]
            let byteCount = Int((flags >> 3) & 7)
            guard byteCount <= 2, h.count >= 3 + byteCount else { return nil }
            var size: Int64 = 0
            for i in 0...byteCount { size |= Int64(h[2 + i]) << Int64(8 * i) }
            var check: UInt8 = 0x5A ^ flags
            for i in 0...byteCount { check ^= h[2 + i] }
            guard check == h[1] else { return nil }
            position += Int64(3 + byteCount) + size
            if flags & 0x40 != 0 { return position <= cipherLength ? position : nil }
        }
        return nil
    }

    // MARK: RAR 1.5–4.x blocks

    private static func rar4Block(type: UInt8, flags: UInt16, body: [UInt8]) -> [UInt8] {
        let size = UInt16(7 + body.count)
        var block: [UInt8] = [0, 0, type, UInt8(flags & 0xFF), UInt8(flags >> 8), UInt8(size & 0xFF), UInt8(size >> 8)] + body
        let crc = UInt16(truncatingIfNeeded: ZIPArchiveReader.CRC32.checksum(Data(block[2...])))
        block[0] = UInt8(crc & 0xFF); block[1] = UInt8(crc >> 8)
        return block
    }

    /// The member's file header without its password flag (and, for a stored
    /// member, with the packed size the plain data has), CRC recomputed.
    static func plainRAR4Header(_ member: Member, packedSize: Int64) throws -> [UInt8] {
        var header = member.rawHeader
        guard header.count >= 32 else { throw ReadError.malformed("\(member.name): file header too short") }
        var flags = UInt16(header[3]) | UInt16(header[4]) << 8
        flags &= ~UInt16(0x0004 | 0x0001 | 0x0002)   // password, split before/after
        header[3] = UInt8(flags & 0xFF); header[4] = UInt8(flags >> 8)
        let low = UInt32(truncatingIfNeeded: packedSize)
        for i in 0..<4 { header[7 + i] = UInt8((low >> UInt32(8 * i)) & 0xFF) }
        if flags & 0x0100 != 0, header.count >= 40 {
            let high = UInt32(truncatingIfNeeded: packedSize >> 32)
            for i in 0..<4 { header[32 + i] = UInt8((high >> UInt32(8 * i)) & 0xFF) }
        } else if packedSize > Int64(UInt32.max) {
            throw ReadError.malformed("\(member.name): sizes do not fit the header")
        }
        let crc = UInt16(truncatingIfNeeded: ZIPArchiveReader.CRC32.checksum(Data(header[2...])))
        header[0] = UInt8(crc & 0xFF); header[1] = UInt8(crc >> 8)
        return header
    }

    // MARK: RAR 5.0 blocks

    static func vint(_ value: UInt64) -> [UInt8] {
        var v = value, out: [UInt8] = []
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }
    static func vint(_ value: Int) -> [UInt8] { vint(UInt64(value)) }
    static func vint(_ value: Int64) -> [UInt8] { vint(UInt64(value)) }

    /// CRC-32 ‖ size ‖ body, the CRC over size and body.
    private static func rar5Block(_ body: [UInt8]) -> [UInt8] {
        let sized = vint(body.count) + body
        let crc = ZIPArchiveReader.CRC32.checksum(Data(sized))
        return [UInt8(crc & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8((crc >> 16) & 0xFF), UInt8(crc >> 24)] + sized
    }

    /// The member's file header without its encryption record; when the
    /// archive keyed the checksums to the password, without the CRC-32 and
    /// hash record too (they are MACs the decoder cannot check).
    static func plainRAR5Header(_ member: Member, dataSize: Int64) throws -> [UInt8] {
        let raw = member.rawHeader
        guard raw.count > 5 else { throw ReadError.malformed("\(member.name): file header too short") }
        var sizeReader = VintReader(bytes: Array(raw[4...]))
        let headerSize = try sizeReader.int("header size")
        let start = 4 + sizeReader.position
        guard start + headerSize <= raw.count else { throw ReadError.malformed("\(member.name): file header too short") }
        var r = VintReader(bytes: Array(raw[start..<(start + headerSize)]))
        let type = try r.vint()
        let flags = try r.vint()
        var extraSize = 0
        if flags & 0x0001 != 0 { extraSize = try r.int("extra area size") }
        if flags & 0x0002 != 0 { _ = try r.vint() }
        let dropChecksums = member.encryption?.useMAC == true
        var fileFlags = try r.vint()
        let unpacked = try r.vint()
        let attributes = try r.vint()
        var mtime: [UInt8] = []
        if fileFlags & 0x0002 != 0 { mtime = try r.take(4) }
        var crc: [UInt8] = []
        if fileFlags & 0x0004 != 0 { crc = try r.take(4) }
        if dropChecksums { fileFlags &= ~UInt64(0x0004); crc = [] }
        let compression = try r.vint()
        let hostOS = try r.vint()
        let nameLength = try r.int("name length")
        let name = try r.take(nameLength)
        let extraStart = r.bytes.count - extraSize
        guard extraStart >= r.position else { throw ReadError.malformed("\(member.name): extra area overlaps the header") }
        let rest = Array(r.bytes[r.position..<extraStart])
        let fields = vint(fileFlags) + vint(unpacked) + vint(attributes) + mtime + crc + vint(compression) + vint(hostOS) + vint(nameLength) + name + rest
        var extra: [UInt8] = []
        var e = VintReader(bytes: Array(r.bytes[extraStart...]))
        while e.remaining > 0 {
            let recordStart = e.position
            let recordSize = try e.int("extra record size")
            guard recordSize >= 1, recordSize <= e.remaining else { break }
            let recordEnd = e.position + recordSize
            let recordType = try e.vint()
            let keep = recordType != 1 && !(dropChecksums && recordType == 2)
            if keep { extra += Array(e.bytes[recordStart..<recordEnd]) }
            e.position = recordEnd
        }
        var newFlags = flags & ~UInt64(0x0001 | 0x0002 | 0x0008 | 0x0010)
        newFlags |= 0x0002
        if !extra.isEmpty { newFlags |= 0x0001 }
        var body = vint(type) + vint(newFlags)
        if !extra.isEmpty { body += vint(extra.count) }
        body += vint(dataSize) + fields + extra
        return rar5Block(body)
    }

    /// BLAKE2sp of a file's bytes (for a member whose digest the archive keyed to the password).
    static func blake2sp(of url: URL) throws -> [UInt8] {
        guard let state = mailin_blake2sp_new() else { throw ReadError.malformed("BLAKE2sp could not be started") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            chunk.withUnsafeBytes { mailin_blake2sp_update(state, $0.baseAddress, $0.count) }
        }
        var digest = [UInt8](repeating: 0, count: 32)
        digest.withUnsafeMutableBufferPointer { mailin_blake2sp_final(state, $0.baseAddress) }
        return digest
    }
}
