//
//  ProtectedContentUnlocker.swift
//  ArchiveCore
//
//  Plan v4 §13.8 step 5 (COMP-13): password-protected content opened with a
//  password the person types ONCE. Three families, all offline:
//
//    ZIP members    PKWARE traditional encryption (ZipCrypto) and WinZip AES
//                   (method 99, AE-1/AE-2: PBKDF2-HMAC-SHA1, AES-CTR, HMAC-SHA1)
//    Office files   ECMA-376 Standard encryption (Office 2007: AES-ECB, SHA-1
//                   spun 50,000 times) and Agile encryption (Office 2010+: an
//                   XML descriptor, AES-CBC per 4,096-byte segment, SHA-512
//                   by default) — the EncryptedPackage of a compound file
//    PDF            PDFKit's own unlock, in the app layer
//
//  Nothing here stores a password or a derived key; the caller decides
//  whether the decrypted TEXT is kept (indexed) or shown once. A wrong
//  password is `ProtectedContentError.wrongPassword`, never a crash and
//  never garbage read as text. The encryptors exist so fixtures can be
//  built from the specification and round-tripped.
//

import Foundation
import CommonCrypto
import CryptoKit

enum ProtectedContentError: Error, Equatable, LocalizedError {
    case wrongPassword
    case unsupported(String)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .wrongPassword: return "the password did not open the file"
        case .unsupported(let what): return "encryption not supported: \(what)"
        case .malformed(let what): return "encrypted file is malformed: \(what)"
        }
    }
}

// MARK: - Primitives (CommonCrypto, one unsafe call each)

enum CryptoPrimitives {
    /// AES in ECB mode, no padding, `input` a multiple of 16 bytes. Encrypt or decrypt.
    static func aesECB(_ input: [UInt8], key: [UInt8], encrypt: Bool) throws -> [UInt8] {
        try aes(input, key: key, iv: nil, options: UInt32(kCCOptionECBMode), encrypt: encrypt)
    }

    /// AES in CBC mode, no padding, `input` a multiple of 16 bytes.
    static func aesCBC(_ input: [UInt8], key: [UInt8], iv: [UInt8], encrypt: Bool) throws -> [UInt8] {
        try aes(input, key: key, iv: iv, options: 0, encrypt: encrypt)
    }

    private static func aes(_ input: [UInt8], key: [UInt8], iv: [UInt8]?, options: UInt32, encrypt: Bool) throws -> [UInt8] {
        guard input.count % 16 == 0 else { throw ProtectedContentError.malformed("cipher text is not a whole number of blocks") }
        guard [16, 24, 32].contains(key.count) else { throw ProtectedContentError.unsupported("AES key of \(key.count * 8) bits") }
        var output = [UInt8](repeating: 0, count: input.count + 16)
        var moved = 0
        let ivBytes = iv ?? [UInt8](repeating: 0, count: 16)
        let status = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { inp in
                key.withUnsafeBytes { k in
                    ivBytes.withUnsafeBytes { v in
                        unsafe CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(options),
                                       k.baseAddress, key.count, options == 0 ? v.baseAddress : nil,
                                       inp.baseAddress, input.count, out.baseAddress, out.count, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw ProtectedContentError.malformed("AES failed (\(status))") }
        return Array(output.prefix(moved))
    }

    /// PBKDF2 with HMAC-SHA1 (WinZip AES uses 1,000 rounds).
    static func pbkdf2SHA1(password: String, salt: [UInt8], rounds: UInt32, length: Int) -> [UInt8] {
        var derived = [UInt8](repeating: 0, count: length)
        let passwordBytes = Array(password.utf8)
        _ = derived.withUnsafeMutableBytes { out in
            passwordBytes.withUnsafeBytes { pw in
                salt.withUnsafeBytes { s in
                    unsafe CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.baseAddress?.assumingMemoryBound(to: CChar.self), passwordBytes.count,
                                                s.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                                                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), rounds,
                                                out.baseAddress?.assumingMemoryBound(to: UInt8.self), length)
                }
            }
        }
        return derived
    }

    static func randomBytes(_ count: Int) -> [UInt8] {
        (0..<count).map { _ in UInt8.random(in: 0...255) }
    }
}

// MARK: - ZipCrypto (PKWARE traditional encryption)

struct ZipCryptoCipher {
    private var key0: UInt32 = 0x1234_5678
    private var key1: UInt32 = 0x2345_6789
    private var key2: UInt32 = 0x3456_7890

    init(password: String) {
        for byte in password.utf8 { update(byte) }
    }

    private mutating func update(_ byte: UInt8) {
        key0 = Self.crcTable[Int((key0 ^ UInt32(byte)) & 0xFF)] ^ (key0 >> 8)
        key1 = key1 &+ (key0 & 0xFF)
        key1 = key1 &* 134_775_813 &+ 1
        key2 = Self.crcTable[Int((key2 ^ (key1 >> 24)) & 0xFF)] ^ (key2 >> 8)
    }

    private var keyByte: UInt8 {
        let temp = UInt16(truncatingIfNeeded: key2 | 2)
        return UInt8(truncatingIfNeeded: (UInt32(temp) &* UInt32(temp ^ 1)) >> 8)
    }

    mutating func decrypt(_ data: Data) -> Data {
        var out = Data(capacity: data.count)
        for cipherByte in data {
            let plain = cipherByte ^ keyByte
            update(plain)
            out.append(plain)
        }
        return out
    }

    mutating func encrypt(_ data: Data) -> Data {
        var out = Data(capacity: data.count)
        for plain in data {
            let cipherByte = plain ^ keyByte
            update(plain)
            out.append(cipherByte)
        }
        return out
    }

    /// The 12-byte encryption header for `crc32` of the plain member (its
    /// last byte is the check byte a reader verifies before trusting the password).
    static func header(crc32: UInt32) -> Data {
        var header = Data(CryptoPrimitives.randomBytes(11))
        header.append(UInt8(truncatingIfNeeded: crc32 >> 24))
        return header
    }

    static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }
}

// MARK: - WinZip AES (method 99)

enum WinZipAES {
    static func saltLength(strength: UInt8) -> Int { strength == 1 ? 8 : (strength == 2 ? 12 : 16) }
    static func keyLength(strength: UInt8) -> Int { strength == 1 ? 16 : (strength == 2 ? 24 : 32) }

    struct Keys {
        let encryption: [UInt8]
        let authentication: [UInt8]
        let verifier: [UInt8]
    }

    static func keys(password: String, salt: [UInt8], strength: UInt8) -> Keys {
        let keyLength = keyLength(strength: strength)
        let derived = CryptoPrimitives.pbkdf2SHA1(password: password, salt: salt, rounds: 1000, length: keyLength * 2 + 2)
        return Keys(encryption: Array(derived[0..<keyLength]),
                    authentication: Array(derived[keyLength..<(keyLength * 2)]),
                    verifier: Array(derived[(keyLength * 2)...]))
    }

    /// AES-CTR as WinZip does it: a 16-byte little-endian counter starting
    /// at 1, encrypted with AES-ECB, XORed with the data; usable across calls.
    struct CounterStream {
        private let key: [UInt8]
        private var counter: UInt64 = 1
        private var keystream: [UInt8] = []
        private var used = 0

        init(key: [UInt8]) { self.key = key }

        mutating func process(_ data: Data) throws -> Data {
            var out = Data(capacity: data.count)
            var index = data.startIndex
            while index < data.endIndex {
                if used == keystream.count {
                    // Encrypt a run of counter blocks at once.
                    let blocks = min(256, (data.endIndex - index + 15) / 16)
                    var counters = [UInt8](repeating: 0, count: blocks * 16)
                    for b in 0..<blocks {
                        var value = counter &+ UInt64(b)
                        for i in 0..<8 { counters[b * 16 + i] = UInt8(value & 0xFF); value >>= 8 }
                    }
                    counter &+= UInt64(blocks)
                    keystream = try CryptoPrimitives.aesECB(counters, key: key, encrypt: true)
                    used = 0
                }
                let take = min(keystream.count - used, data.endIndex - index)
                for i in 0..<take { out.append(data[index + i] ^ keystream[used + i]) }
                used += take
                index += take
            }
            return out
        }
    }

    /// The bytes of one encrypted member (salt, verifier, cipher text, auth
    /// code) and the 0x9901 extra field, for building fixtures and archives.
    static func encryptMember(_ plain: Data, password: String, strength: UInt8 = 3, actualMethod: UInt16 = 0) throws -> (payload: Data, extra: Data) {
        let salt = CryptoPrimitives.randomBytes(saltLength(strength: strength))
        let keys = keys(password: password, salt: salt, strength: strength)
        var stream = CounterStream(key: keys.encryption)
        let cipherText = try stream.process(plain)
        var mac = HMAC<Insecure.SHA1>(key: SymmetricKey(data: keys.authentication))
        mac.update(data: cipherText)
        var payload = Data(salt)
        payload.append(contentsOf: keys.verifier)
        payload.append(cipherText)
        payload.append(Data(mac.finalize()).prefix(10))
        var extra = Data()
        func le16(_ v: UInt16) { extra.append(UInt8(v & 0xFF)); extra.append(UInt8(v >> 8)) }
        le16(0x9901); le16(7); le16(0x0002); extra.append(contentsOf: [0x41, 0x45]); extra.append(strength); le16(actualMethod)
        return (payload, extra)
    }

    struct ExtraField { let strength: UInt8; let actualMethod: UInt16; let vendorVersion: UInt16 }

    /// The AES extra field (0x9901) inside a local or central extra region.
    static func extraField(in extra: Data) -> ExtraField? {
        var e = extra.startIndex
        while e + 4 <= extra.endIndex {
            let id = UInt16(extra[e]) | UInt16(extra[e + 1]) << 8
            let length = Int(UInt16(extra[e + 2]) | UInt16(extra[e + 3]) << 8)
            guard e + 4 + length <= extra.endIndex else { return nil }
            if id == 0x9901, length >= 7 {
                let f = e + 4
                let vendor = UInt16(extra[f]) | UInt16(extra[f + 1]) << 8
                let strength = extra[f + 4]
                let method = UInt16(extra[f + 5]) | UInt16(extra[f + 6]) << 8
                return ExtraField(strength: strength, actualMethod: method, vendorVersion: vendor)
            }
            e += 4 + length
        }
        return nil
    }
}

// MARK: - Office (ECMA-376 / MS-OFFCRYPTO)

enum OfficeCryptoUnlocker {

    /// True when the compound file carries an encrypted Office package.
    static func isEncryptedPackage(_ data: Data) -> Bool {
        guard let ole = try? OLE2Reader(data: data) else { return false }
        return ole.streamData(named: "EncryptionInfo") != nil && ole.streamData(named: "EncryptedPackage") != nil
    }

    /// The plain Office Open XML package, or `wrongPassword`.
    static func decrypt(data: Data, password: String) throws -> Data {
        let ole = try OLE2Reader(data: data)
        guard let info = ole.streamData(named: "EncryptionInfo"), let package = ole.streamData(named: "EncryptedPackage") else {
            throw ProtectedContentError.unsupported("not an encrypted Office package")
        }
        guard info.count >= 8 else { throw ProtectedContentError.malformed("EncryptionInfo too short") }
        let major = u16(info, 0), minor = u16(info, 2)
        if major == 4, minor == 4 { return try decryptAgile(info: info, package: package, password: password) }
        if minor == 2, (2...4).contains(major) { return try decryptStandard(info: info, package: package, password: password) }
        if minor == 3 { throw ProtectedContentError.unsupported("extensible encryption (version \(major).\(minor))") }
        throw ProtectedContentError.unsupported("encryption version \(major).\(minor)")
    }

    // MARK: Agile

    struct AgileDescriptor {
        // keyData
        var saltValue: [UInt8] = []
        var blockSize = 16
        var keyBits = 256
        var hashAlgorithm = "SHA512"
        var hashSize = 64
        var cipherChaining = "ChainingModeCBC"
        // encryptedKey (password key encryptor)
        var spinCount = 100_000
        var keySalt: [UInt8] = []
        var keyBlockSize = 16
        var keyKeyBits = 256
        var keyHashAlgorithm = "SHA512"
        var keyHashSize = 64
        var encryptedVerifierHashInput: [UInt8] = []
        var encryptedVerifierHashValue: [UInt8] = []
        var encryptedKeyValue: [UInt8] = []
    }

    static let verifierHashInputBlock: [UInt8] = [0xFE, 0xA7, 0xD2, 0x76, 0x3B, 0x4B, 0x9E, 0x79]
    static let verifierHashValueBlock: [UInt8] = [0xD7, 0xAA, 0x0F, 0x6D, 0x30, 0x61, 0x34, 0x4E]
    static let keyValueBlock: [UInt8] = [0x14, 0x6E, 0x0B, 0xE7, 0xAB, 0xAC, 0xD0, 0xD6]

    static func hash(_ algorithm: String, _ data: [UInt8]) -> [UInt8] {
        switch algorithm.uppercased().replacingOccurrences(of: "-", with: "") {
        case "SHA1": return Array(Insecure.SHA1.hash(data: data))
        case "SHA256": return Array(SHA256.hash(data: data))
        case "SHA384": return Array(SHA384.hash(data: data))
        default: return Array(SHA512.hash(data: data))
        }
    }

    static func decryptAgile(info: Data, package: Data, password: String) throws -> Data {
        let xml = info.subdata(in: (info.startIndex + 8)..<info.endIndex)
        let descriptor = try parseAgile(xml)
        guard descriptor.cipherChaining == "ChainingModeCBC" else { throw ProtectedContentError.unsupported(descriptor.cipherChaining) }
        // The password hash, spun.
        var h = hash(descriptor.keyHashAlgorithm, descriptor.keySalt + Array(password.data(using: .utf16LittleEndian) ?? Data()))
        for i in 0..<UInt32(descriptor.spinCount) {
            h = hash(descriptor.keyHashAlgorithm, [UInt8(i & 0xFF), UInt8((i >> 8) & 0xFF), UInt8((i >> 16) & 0xFF), UInt8(i >> 24)] + h)
        }
        let keyBytes = descriptor.keyKeyBits / 8
        func blockKey(_ block: [UInt8]) -> [UInt8] { fit(hash(descriptor.keyHashAlgorithm, h + block), to: keyBytes) }
        let iv = fit(descriptor.keySalt, to: descriptor.keyBlockSize)
        guard descriptor.encryptedVerifierHashInput.count % 16 == 0, descriptor.encryptedVerifierHashValue.count % 16 == 0, descriptor.encryptedKeyValue.count % 16 == 0 else {
            throw ProtectedContentError.malformed("verifier fields are not whole blocks")
        }
        let verifierInput = try CryptoPrimitives.aesCBC(descriptor.encryptedVerifierHashInput, key: blockKey(verifierHashInputBlock), iv: iv, encrypt: false)
        let verifierHash = try CryptoPrimitives.aesCBC(descriptor.encryptedVerifierHashValue, key: blockKey(verifierHashValueBlock), iv: iv, encrypt: false)
        let expected = hash(descriptor.keyHashAlgorithm, Array(verifierInput.prefix(descriptor.keyBlockSize)))
        guard Array(verifierHash.prefix(descriptor.keyHashSize)) == Array(expected.prefix(descriptor.keyHashSize)) else { throw ProtectedContentError.wrongPassword }
        let intermediate = Array(try CryptoPrimitives.aesCBC(descriptor.encryptedKeyValue, key: blockKey(keyValueBlock), iv: iv, encrypt: false).prefix(keyBytes))

        // The package: its size, then 4,096-byte segments each with its own IV.
        guard package.count >= 8 else { throw ProtectedContentError.malformed("EncryptedPackage too short") }
        let size = Int(clamping: u64(package, 0))
        var plain = Data(capacity: size)
        var offset = 8
        var segment: UInt32 = 0
        while offset < package.count {
            let end = min(offset + 4096, package.count)
            var chunk = Array(package[(package.startIndex + offset)..<(package.startIndex + end)])
            chunk = Array(chunk.prefix(chunk.count / 16 * 16))
            if chunk.isEmpty { break }
            let iv = fit(hash(descriptor.hashAlgorithm, descriptor.saltValue + [UInt8(segment & 0xFF), UInt8((segment >> 8) & 0xFF), UInt8((segment >> 16) & 0xFF), UInt8(segment >> 24)]), to: descriptor.blockSize)
            plain.append(contentsOf: try CryptoPrimitives.aesCBC(chunk, key: fit(intermediate, to: descriptor.keyBits / 8), iv: iv, encrypt: false))
            offset = end
            segment += 1
        }
        return plain.prefix(size)
    }

    /// Truncate, or pad with 0x36, to `length` (MS-OFFCRYPTO 2.3.4.12).
    static func fit(_ bytes: [UInt8], to length: Int) -> [UInt8] {
        if bytes.count >= length { return Array(bytes.prefix(length)) }
        return bytes + [UInt8](repeating: 0x36, count: length - bytes.count)
    }

    static func parseAgile(_ xml: Data) throws -> AgileDescriptor {
        let collector = AgileXMLCollector()
        guard collector.parse(xml) else { throw ProtectedContentError.malformed("EncryptionInfo XML") }
        var d = AgileDescriptor()
        if let keyData = collector.keyData {
            d.saltValue = Array(Data(base64Encoded: keyData["saltValue"] ?? "") ?? Data())
            d.blockSize = Int(keyData["blockSize"] ?? "") ?? 16
            d.keyBits = Int(keyData["keyBits"] ?? "") ?? 256
            d.hashAlgorithm = keyData["hashAlgorithm"] ?? "SHA512"
            d.hashSize = Int(keyData["hashSize"] ?? "") ?? 64
            d.cipherChaining = keyData["cipherChaining"] ?? "ChainingModeCBC"
        }
        guard let key = collector.encryptedKey else { throw ProtectedContentError.unsupported("no password key encryptor (certificate-only encryption)") }
        d.spinCount = Int(key["spinCount"] ?? "") ?? 100_000
        d.keySalt = Array(Data(base64Encoded: key["saltValue"] ?? "") ?? Data())
        d.keyBlockSize = Int(key["blockSize"] ?? "") ?? 16
        d.keyKeyBits = Int(key["keyBits"] ?? "") ?? 256
        d.keyHashAlgorithm = key["hashAlgorithm"] ?? "SHA512"
        d.keyHashSize = Int(key["hashSize"] ?? "") ?? 64
        d.encryptedVerifierHashInput = Array(Data(base64Encoded: key["encryptedVerifierHashInput"] ?? "") ?? Data())
        d.encryptedVerifierHashValue = Array(Data(base64Encoded: key["encryptedVerifierHashValue"] ?? "") ?? Data())
        d.encryptedKeyValue = Array(Data(base64Encoded: key["encryptedKeyValue"] ?? "") ?? Data())
        guard !d.saltValue.isEmpty, !d.keySalt.isEmpty else { throw ProtectedContentError.malformed("missing salt") }
        guard d.spinCount <= 10_000_000 else { throw ProtectedContentError.malformed("spin count \(d.spinCount)") }
        return d
    }

    /// An Agile-encrypted package from a plain one (spec-built fixtures and
    /// round-trip tests; `spinCount` low keeps tests fast, Office uses 100,000).
    static func encryptAgile(package plain: Data, password: String, spinCount: Int = 100_000) throws -> Data {
        let keySalt = CryptoPrimitives.randomBytes(16)
        let dataSalt = CryptoPrimitives.randomBytes(16)
        let intermediate = CryptoPrimitives.randomBytes(32)
        var h = hash("SHA512", keySalt + Array(password.data(using: .utf16LittleEndian) ?? Data()))
        for i in 0..<UInt32(spinCount) {
            h = hash("SHA512", [UInt8(i & 0xFF), UInt8((i >> 8) & 0xFF), UInt8((i >> 16) & 0xFF), UInt8(i >> 24)] + h)
        }
        func blockKey(_ block: [UInt8]) -> [UInt8] { fit(hash("SHA512", h + block), to: 32) }
        let iv = fit(keySalt, to: 16)
        let verifierInput = CryptoPrimitives.randomBytes(16)
        let encryptedInput = try CryptoPrimitives.aesCBC(verifierInput, key: blockKey(verifierHashInputBlock), iv: iv, encrypt: true)
        let encryptedHash = try CryptoPrimitives.aesCBC(hash("SHA512", verifierInput), key: blockKey(verifierHashValueBlock), iv: iv, encrypt: true)
        let encryptedKey = try CryptoPrimitives.aesCBC(intermediate, key: blockKey(keyValueBlock), iv: iv, encrypt: true)
        // Package segments.
        var encryptedPackage = Data()
        var size = UInt64(plain.count)
        for _ in 0..<8 { encryptedPackage.append(UInt8(size & 0xFF)); size >>= 8 }
        var offset = 0
        var segment: UInt32 = 0
        while offset < plain.count {
            let end = min(offset + 4096, plain.count)
            var chunk = Array(plain[offset..<end])
            if chunk.count % 16 != 0 { chunk += [UInt8](repeating: 0, count: 16 - chunk.count % 16) }
            let segmentIV = fit(hash("SHA512", dataSalt + [UInt8(segment & 0xFF), UInt8((segment >> 8) & 0xFF), UInt8((segment >> 16) & 0xFF), UInt8(segment >> 24)]), to: 16)
            encryptedPackage.append(contentsOf: try CryptoPrimitives.aesCBC(chunk, key: intermediate, iv: segmentIV, encrypt: true))
            offset = end
            segment += 1
        }
        let b64 = { (bytes: [UInt8]) in Data(bytes).base64EncodedString() }
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <encryption xmlns="http://schemas.microsoft.com/office/2006/encryption" xmlns:p="http://schemas.microsoft.com/office/2006/keyEncryptor/password">\
        <keyData saltSize="16" blockSize="16" keyBits="256" hashSize="64" cipherAlgorithm="AES" cipherChaining="ChainingModeCBC" hashAlgorithm="SHA512" saltValue="\(b64(dataSalt))"/>\
        <keyEncryptors><keyEncryptor uri="http://schemas.microsoft.com/office/2006/keyEncryptor/password">\
        <p:encryptedKey spinCount="\(spinCount)" saltSize="16" blockSize="16" keyBits="256" hashSize="64" cipherAlgorithm="AES" cipherChaining="ChainingModeCBC" hashAlgorithm="SHA512" saltValue="\(b64(keySalt))" encryptedVerifierHashInput="\(b64(encryptedInput))" encryptedVerifierHashValue="\(b64(encryptedHash))" encryptedKeyValue="\(b64(encryptedKey))"/>\
        </keyEncryptor></keyEncryptors></encryption>
        """
        var info = Data([0x04, 0x00, 0x04, 0x00, 0x40, 0x00, 0x00, 0x00])
        info.append(Data(xml.utf8))
        return try MSGWriter.compoundFile(streams: [("EncryptionInfo", info), ("EncryptedPackage", encryptedPackage)])
    }

    // MARK: Standard (Office 2007)

    static func decryptStandard(info: Data, package: Data, password: String) throws -> Data {
        guard info.count >= 12 else { throw ProtectedContentError.malformed("EncryptionInfo header") }
        let headerSize = Int(u32(info, 8))
        guard headerSize >= 32, 12 + headerSize <= info.count else { throw ProtectedContentError.malformed("EncryptionHeader size") }
        let header = 12
        let algID = u32(info, header + 8)
        let keySizeBits = Int(u32(info, header + 16))
        let keyBytes = keySizeBits == 0 ? 16 : keySizeBits / 8
        guard [0x660E, 0x660F, 0x6610].contains(algID) else { throw ProtectedContentError.unsupported("Standard encryption with algorithm 0x\(String(algID, radix: 16)) (only AES)") }
        var v = header + headerSize
        guard v + 4 + 16 + 16 + 4 + 32 <= info.count else { throw ProtectedContentError.malformed("EncryptionVerifier") }
        let saltSize = Int(u32(info, v)); v += 4
        guard saltSize == 16 else { throw ProtectedContentError.malformed("salt size \(saltSize)") }
        let salt = Array(info[(info.startIndex + v)..<(info.startIndex + v + 16)]); v += 16
        let encryptedVerifier = Array(info[(info.startIndex + v)..<(info.startIndex + v + 16)]); v += 16
        let verifierHashSize = Int(u32(info, v)); v += 4
        let encryptedVerifierHash = Array(info[(info.startIndex + v)..<(info.startIndex + v + 32)])

        var h = Array(Insecure.SHA1.hash(data: salt + Array(password.data(using: .utf16LittleEndian) ?? Data())))
        for i in 0..<UInt32(50_000) {
            h = Array(Insecure.SHA1.hash(data: [UInt8(i & 0xFF), UInt8((i >> 8) & 0xFF), UInt8((i >> 16) & 0xFF), UInt8(i >> 24)] + h))
        }
        h = Array(Insecure.SHA1.hash(data: h + [0, 0, 0, 0]))
        var x1Input = [UInt8](repeating: 0x36, count: 64), x2Input = [UInt8](repeating: 0x5C, count: 64)
        for (i, byte) in h.enumerated() { x1Input[i] ^= byte; x2Input[i] ^= byte }
        let x1 = Array(Insecure.SHA1.hash(data: x1Input)), x2 = Array(Insecure.SHA1.hash(data: x2Input))
        let key = Array((x1 + x2).prefix(keyBytes))

        let verifier = try CryptoPrimitives.aesECB(encryptedVerifier, key: key, encrypt: false)
        let verifierHash = try CryptoPrimitives.aesECB(encryptedVerifierHash, key: key, encrypt: false)
        let expected = Array(Insecure.SHA1.hash(data: verifier))
        guard Array(verifierHash.prefix(min(verifierHashSize, 20))) == Array(expected.prefix(min(verifierHashSize, 20))) else { throw ProtectedContentError.wrongPassword }

        guard package.count >= 8 else { throw ProtectedContentError.malformed("EncryptedPackage too short") }
        let size = Int(clamping: u64(package, 0))
        let body = Array(package[(package.startIndex + 8)...])
        let plain = try CryptoPrimitives.aesECB(Array(body.prefix(body.count / 16 * 16)), key: key, encrypt: false)
        return Data(plain.prefix(size))
    }

    // MARK: Byte helpers

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        let b = data.startIndex + offset
        return UInt16(data[b]) | (UInt16(data[b + 1]) << 8)
    }
    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        let b = data.startIndex + offset
        return UInt32(data[b]) | (UInt32(data[b + 1]) << 8) | (UInt32(data[b + 2]) << 16) | (UInt32(data[b + 3]) << 24)
    }
    private static func u64(_ data: Data, _ offset: Int) -> UInt64 {
        UInt64(u32(data, offset)) | (UInt64(u32(data, offset + 4)) << 32)
    }
}

/// The two elements of an Agile EncryptionInfo that matter: keyData and the
/// password key encryptor's encryptedKey, as attribute dictionaries.
final class AgileXMLCollector: NSObject, XMLParserDelegate {
    private(set) var keyData: [String: String]?
    private(set) var encryptedKey: [String: String]?
    private var failed = false

    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldResolveExternalEntities = false
        return parser.parse() && !failed
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if name == "keyData" { keyData = attributes }
        if name == "encryptedKey", encryptedKey == nil, attributes["spinCount"] != nil { encryptedKey = attributes }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { failed = true }
}
