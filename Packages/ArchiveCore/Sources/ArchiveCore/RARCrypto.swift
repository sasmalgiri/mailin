//
//  RARCrypto.swift
//  ArchiveCore
//
//  Audit R6 (RAR row): the key derivations and ciphers of encrypted RAR
//  archives, from the published format descriptions (rarlab's technote /
//  "RAR 5.0 archive format", unrarsrc crypt3.cpp / crypt5.cpp). libarchive
//  does not decrypt RAR; mailin decrypts here and hands the decoder a plain
//  view of the archive (RARDecryptedArchive.swift). The password lives only
//  for the call that was given it — nothing here stores it.
//
//  RAR 3.x/4.x (unpack version 29/36): AES-128-CBC. Key and IV from SHA-1
//  over 0x40000 rounds of (password as UTF-16LE ‖ salt ‖ 3-byte round
//  number); the IV collects one byte of an intermediate digest every
//  0x4000 rounds. RAR's own SHA-1 for this ("sha1_process_rar29") writes
//  the expanded message schedule back into the password buffer when one
//  update holds a whole 64-byte block of it — passwords over 28 characters
//  — so that path is reproduced exactly; shorter ones use CryptoKit's SHA-1.
//
//  RAR 5.0: AES-256-CBC. PBKDF2-HMAC-SHA256 over the UTF-8 password and the
//  16-byte salt with 2^n iterations gives the key; 16 and 32 iterations
//  more give the MAC key for checksums and the password check value (eight
//  bytes, XOR-folded), which says "wrong password" before any data is read.
//

import Foundation
import CommonCrypto
import CryptoKit

enum RARCrypto {

    /// RAR 3.x/4.x rounds of the SHA-1 key derivation.
    static let rar3Rounds = 0x40000
    /// RAR 5.0: unrar refuses a KDF count over 2^24.
    static let rar5MaxLog2Count = 24

    // MARK: RAR 3.x / 4.x

    struct RAR3Key: Equatable, Sendable { let key: [UInt8]; let iv: [UInt8] }

    static func rar3Key(password: String, salt: [UInt8]?) -> RAR3Key {
        // unrar: the password as 16-bit little-endian characters, then the 8-byte salt.
        let raw = rar3Raw(password: password, salt: salt)
        if raw.count < 65 { return rar3KeyCryptoKit(raw) }
        return rar3KeyQuirk(raw)
    }

    private static func rar3Raw(password: String, salt: [UInt8]?) -> [UInt8] {
        var raw: [UInt8] = []
        for unit in password.utf16 { raw.append(UInt8(unit & 0xFF)); raw.append(UInt8(unit >> 8)) }
        return raw + (salt ?? [])
    }
    /// Both derivations on the same input (tests: they must agree below 65 bytes).
    static func rar3KeyCryptoKitForTesting(password: String, salt: [UInt8]?) -> RAR3Key { rar3KeyCryptoKit(rar3Raw(password: password, salt: salt)) }
    static func rar3KeyQuirkForTesting(password: String, salt: [UInt8]?) -> RAR3Key { rar3KeyQuirk(rar3Raw(password: password, salt: salt)) }

    /// No update ever holds a full block of the password buffer: plain SHA-1.
    private static func rar3KeyCryptoKit(_ raw: [UInt8]) -> RAR3Key {
        var hash = Insecure.SHA1()
        var iv = [UInt8](repeating: 0, count: 16)
        for i in 0..<rar3Rounds {
            hash.update(data: raw)
            hash.update(data: [UInt8(i & 0xFF), UInt8((i >> 8) & 0xFF), UInt8((i >> 16) & 0xFF)])
            if i % (rar3Rounds / 16) == 0 {
                let digest = Array(hash.finalize())
                iv[i / (rar3Rounds / 16)] = digest[19]
            }
        }
        return RAR3Key(key: rar3KeyBytes(Array(hash.finalize())), iv: iv)
    }

    /// unrar: AESKey[I*4+J] = (byte)(digest[I] >> (J*8)) — each 32-bit word of the digest, low byte first.
    private static func rar3KeyBytes(_ digest: [UInt8]) -> [UInt8] {
        var key = [UInt8](repeating: 0, count: 16)
        for i in 0..<4 { for j in 0..<4 { key[i * 4 + j] = digest[i * 4 + 3 - j] } }
        return key
    }

    /// RAR's SHA-1 with the write-back (unrarsrc sha1.cpp sha1_process_rar29).
    private static func rar3KeyQuirk(_ rawIn: [UInt8]) -> RAR3Key {
        var raw = rawIn
        var sha = RAR29SHA1()
        var iv = [UInt8](repeating: 0, count: 16)
        for i in 0..<rar3Rounds {
            sha.update(&raw, writeBack: true)
            var number: [UInt8] = [UInt8(i & 0xFF), UInt8((i >> 8) & 0xFF), UInt8((i >> 16) & 0xFF)]
            sha.update(&number, writeBack: true)
            if i % (rar3Rounds / 16) == 0 {
                var copy = sha
                iv[i / (rar3Rounds / 16)] = copy.finalize()[19]
            }
        }
        return RAR3Key(key: rar3KeyBytes(sha.finalize()), iv: iv)
    }

    /// SHA-1 that, like unrar's, overwrites each whole 64-byte block it
    /// hashes straight from the caller's buffer with the final 16 words of
    /// the message schedule (little-endian).
    struct RAR29SHA1 {
        var state: [UInt32] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]
        var count: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 64)

        private static func rol(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }

        /// Hashes one block; returns the schedule's last 16 words (W[64…79] at index t & 15).
        private mutating func transform(_ block: UnsafeBufferPointer<UInt8>) -> [UInt32] {
            var w = [UInt32](repeating: 0, count: 16)
            for t in 0..<16 {
                w[t] = UInt32(block[t * 4]) << 24 | UInt32(block[t * 4 + 1]) << 16 | UInt32(block[t * 4 + 2]) << 8 | UInt32(block[t * 4 + 3])
            }
            var a = state[0], b = state[1], c = state[2], d = state[3], e = state[4]
            for t in 0..<80 {
                let wt: UInt32
                if t < 16 { wt = w[t] } else {
                    let v = Self.rol(w[(t + 13) & 15] ^ w[(t + 8) & 15] ^ w[(t + 2) & 15] ^ w[t & 15], 1)
                    w[t & 15] = v
                    wt = v
                }
                let f: UInt32, k: UInt32
                switch t {
                case 0..<20: f = (b & c) | (~b & d); k = 0x5A827999
                case 20..<40: f = b ^ c ^ d; k = 0x6ED9EBA1
                case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC
                default: f = b ^ c ^ d; k = 0xCA62C1D6
                }
                let temp = Self.rol(a, 5) &+ f &+ e &+ k &+ wt
                e = d; d = c; c = Self.rol(b, 30); b = a; a = temp
            }
            state[0] &+= a; state[1] &+= b; state[2] &+= c; state[3] &+= d; state[4] &+= e
            return w
        }

        mutating func update(_ data: inout [UInt8], writeBack: Bool) {
            let len = data.count
            var j = Int(count & 63)
            count += UInt64(len)
            var i = 0
            if j + len > 63 {
                i = 64 - j
                buffer.replaceSubrange(j..<64, with: data[0..<i])
                let block = buffer
                _ = block.withUnsafeBufferPointer { transform($0) }
                while i + 63 < len {
                    let start = i
                    let schedule = data.withUnsafeBufferPointer { transform(UnsafeBufferPointer(rebasing: $0[start..<(start + 64)])) }
                    if writeBack {
                        for k in 0..<16 {
                            let v = schedule[k]
                            data[start + k * 4] = UInt8(v & 0xFF)
                            data[start + k * 4 + 1] = UInt8((v >> 8) & 0xFF)
                            data[start + k * 4 + 2] = UInt8((v >> 16) & 0xFF)
                            data[start + k * 4 + 3] = UInt8(v >> 24)
                        }
                    }
                    i += 64
                }
                j = 0
            }
            if len > i { buffer.replaceSubrange(j..<(j + len - i), with: data[i..<len]) }
        }

        mutating func finalize() -> [UInt8] {
            let bitCount = count &* 8
            var pad: [UInt8] = [0x80]
            while (Int(count) + pad.count) % 64 != 56 { pad.append(0) }
            for s in stride(from: 56, through: 0, by: -8) { pad.append(UInt8((bitCount >> UInt64(s)) & 0xFF)) }
            update(&pad, writeBack: false)
            var out: [UInt8] = []
            for word in state { out += [UInt8(word >> 24), UInt8((word >> 16) & 0xFF), UInt8((word >> 8) & 0xFF), UInt8(word & 0xFF)] }
            return out
        }
    }

    // MARK: RAR 5.0

    struct RAR5Keys: Equatable, Sendable {
        let key: [UInt8]
        /// Turns a CRC-32 / BLAKE2sp into the MAC stored when the archive says "use MAC".
        let hashKey: [UInt8]
        /// The 8-byte value the archive stores to recognise the right password.
        let passwordCheck: [UInt8]
    }

    static func hmacSHA256(key: [UInt8], _ data: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        key.withUnsafeBytes { k in
            data.withUnsafeBytes { d in
                out.withUnsafeMutableBytes { o in
                    CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), k.baseAddress, k.count, d.baseAddress, d.count, o.baseAddress)
                }
            }
        }
        return out
    }

    static func rar5Keys(password: String, salt: [UInt8], log2Count: Int) -> RAR5Keys {
        let pwd = Array(password.utf8)
        var u = hmacSHA256(key: pwd, salt + [0, 0, 0, 1])
        var fn = u
        var values: [[UInt8]] = []
        for rounds in [(1 << log2Count) - 1, 16, 16] {
            for _ in 0..<rounds {
                u = hmacSHA256(key: pwd, u)
                for k in 0..<fn.count { fn[k] ^= u[k] }
            }
            values.append(fn)
        }
        var check = [UInt8](repeating: 0, count: 8)
        for (i, byte) in values[2].enumerated() { check[i % 8] ^= byte }
        return RAR5Keys(key: values[0], hashKey: values[1], passwordCheck: check)
    }

    /// unrar ConvertHashToMAC for a CRC-32.
    static func mac(crc: UInt32, hashKey: [UInt8]) -> UInt32 {
        let digest = hmacSHA256(key: hashKey, [UInt8(crc & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8((crc >> 16) & 0xFF), UInt8(crc >> 24)])
        var value: UInt32 = 0
        for (i, byte) in digest.enumerated() { value ^= UInt32(byte) << UInt32((i & 3) * 8) }
        return value
    }

    /// unrar ConvertHashToMAC for a BLAKE2sp digest.
    static func mac(digest: [UInt8], hashKey: [UInt8]) -> [UInt8] { hmacSHA256(key: hashKey, digest) }

    /// The archive's 4-byte check of its own password-check field.
    static func checkFieldIsIntact(_ check: [UInt8], checksum: [UInt8]) -> Bool {
        Array(SHA256.hash(data: check).prefix(4)) == checksum
    }

    // MARK: AES-CBC (no padding: RAR pads to the block size itself)

    final class CBCDecryptor {
        private var cryptor: CCCryptorRef?

        init(key: [UInt8], iv: [UInt8]) throws {
            var ref: CCCryptorRef?
            let status = key.withUnsafeBytes { k in
                iv.withUnsafeBytes { v in
                    CCCryptorCreate(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), 0, k.baseAddress, k.count, v.baseAddress, &ref)
                }
            }
            guard status == CCCryptorStatus(kCCSuccess), let ref else { throw RARReader.ReadError.malformed("the AES decryptor could not be started") }
            cryptor = ref
        }
        deinit { if let cryptor { CCCryptorRelease(cryptor) } }

        /// Decrypts whole 16-byte blocks.
        func update(_ input: [UInt8]) throws -> [UInt8] {
            guard input.count % 16 == 0 else { throw RARReader.ReadError.malformed("encrypted data is not a whole number of AES blocks") }
            guard !input.isEmpty else { return [] }
            var out = [UInt8](repeating: 0, count: input.count)
            var moved = 0
            let status = input.withUnsafeBytes { i in
                out.withUnsafeMutableBytes { o in
                    CCCryptorUpdate(cryptor, i.baseAddress, i.count, o.baseAddress, o.count, &moved)
                }
            }
            guard status == CCCryptorStatus(kCCSuccess), moved == input.count else { throw RARReader.ReadError.malformed("AES decryption failed") }
            return out
        }
    }

    static func decryptCBC(_ data: [UInt8], key: [UInt8], iv: [UInt8]) throws -> [UInt8] {
        try CBCDecryptor(key: key, iv: iv).update(data)
    }
}
