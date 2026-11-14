//
//  OpenPGPCrypto.swift
//  ArchiveCore
//
//  GAP-PGP (owner decision 2026-11-07): OpenPGP signatures are VERIFIED
//  against public keys the person imported — good / bad / unknown key /
//  cannot verify. Public keys only: no secret keys, no passphrases, no
//  decryption, nothing fetched from a key server.
//
//  This file holds the packet-level pieces (RFC 4880 §5.2/§5.5, RFC 9580
//  §5.2/§5.5): public-key and signature packets, subpackets, fingerprints
//  and key IDs (v4 SHA-1, v6 SHA-256), the hash input of a signature
//  (v4 trailer, v6 salt and trailer, v3), and the signature check itself:
//
//    RSA (1, 3)            Security.framework, PKCS#1 v1.5 over the digest
//                          (a DER RSAPublicKey is built from n and e)
//    ECDSA (19)            CryptoKit P-256 / P-384 / P-521 (raw r ‖ s)
//    EdDSA legacy (22)     CryptoKit Curve25519.Signing (Ed25519 OID only)
//    Ed25519 (27, v6)      CryptoKit Curve25519.Signing
//
//  Hashes: SHA-1, SHA2-256/384/512 (CryptoKit). Anything else — DSA,
//  Elgamal, Ed448, Brainpool or secp256k1 curves, SHA-224, SHA-3, MD5,
//  RIPEMD-160 — is "cannot verify: … not supported", never "bad".
//
//  Every read is bounds-checked; malformed input throws `OpenPGPFormatError`
//  and is never trapped on.
//

import Foundation
import CryptoKit
import Security

enum OpenPGPFormatError: Error, Equatable, LocalizedError {
    case malformed(String)
    var errorDescription: String? {
        switch self { case .malformed(let what): return "malformed OpenPGP data: \(what)" }
    }
}

/// A bounds-checked cursor over packet bytes.
struct PGPByteReader {
    let bytes: [UInt8]
    private(set) var pos: Int

    init(_ bytes: [UInt8], at pos: Int = 0) { self.bytes = bytes; self.pos = pos }

    var remaining: Int { bytes.count - pos }
    var atEnd: Bool { pos >= bytes.count }

    mutating func u8(_ what: String) throws -> UInt8 {
        guard pos < bytes.count else { throw OpenPGPFormatError.malformed("\(what) is missing") }
        defer { pos += 1 }
        return bytes[pos]
    }

    mutating func u16(_ what: String) throws -> Int {
        let b = try take(2, what)
        return Int(b[0]) << 8 | Int(b[1])
    }

    mutating func u32(_ what: String) throws -> UInt32 {
        let b = try take(4, what)
        return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }

    mutating func take(_ count: Int, _ what: String) throws -> [UInt8] {
        guard count >= 0, count <= remaining else { throw OpenPGPFormatError.malformed("\(what) runs past the end (\(count) bytes declared, \(max(0, remaining)) present)") }
        defer { pos += count }
        return Array(bytes[pos..<(pos + count)])
    }

    /// RFC 4880 §3.2 multiprecision integer: a two-octet bit count, then the bytes.
    mutating func mpi(_ what: String) throws -> [UInt8] {
        let bits = try u16(what)
        return try take((bits + 7) / 8, what)
    }

    mutating func rest() -> [UInt8] {
        defer { pos = bytes.count }
        return pos < bytes.count ? Array(bytes[pos...]) : []
    }
}

enum PGPBytes {
    static func u16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    static func u32(_ v: Int) -> [UInt8] { [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    static func u32(_ v: UInt32) -> [UInt8] { u32(Int(v)) }
    static func uint32(_ b: ArraySlice<UInt8>) -> UInt32? {
        guard b.count == 4 else { return nil }
        let s = b.startIndex
        return UInt32(b[s]) << 24 | UInt32(b[s + 1]) << 16 | UInt32(b[s + 2]) << 8 | UInt32(b[s + 3])
    }
    static func strippingLeadingZeros(_ b: [UInt8]) -> [UInt8] {
        guard let first = b.firstIndex(where: { $0 != 0 }) else { return [] }
        return Array(b[first...])
    }
    /// Left-pads `b` to `size` bytes; nil when the value does not fit.
    static func leftPadded(_ b: [UInt8], to size: Int) -> [UInt8]? {
        let v = strippingLeadingZeros(b)
        guard v.count <= size else { return nil }
        return [UInt8](repeating: 0, count: size - v.count) + v
    }
}

// MARK: - Elliptic curves by OID

enum OpenPGPCurve: String, Sendable, Equatable {
    case p256 = "P-256", p384 = "P-384", p521 = "P-521"

    var fieldBytes: Int { switch self { case .p256: return 32; case .p384: return 48; case .p521: return 66 } }

    static func from(oid: [UInt8]) -> OpenPGPCurve? {
        switch oid {
        case [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]: return .p256
        case [0x2B, 0x81, 0x04, 0x00, 0x22]: return .p384
        case [0x2B, 0x81, 0x04, 0x00, 0x23]: return .p521
        default: return nil
        }
    }

    static let ed25519LegacyOID: [UInt8] = [0x2B, 0x06, 0x01, 0x04, 0x01, 0xDA, 0x47, 0x0F, 0x01]

    /// A readable name for a curve this release does not verify on.
    static func name(oid: [UInt8]) -> String {
        switch oid {
        case [0x2B, 0x24, 0x03, 0x03, 0x02, 0x08, 0x01, 0x01, 0x07]: return "brainpoolP256r1"
        case [0x2B, 0x24, 0x03, 0x03, 0x02, 0x08, 0x01, 0x01, 0x0B]: return "brainpoolP384r1"
        case [0x2B, 0x24, 0x03, 0x03, 0x02, 0x08, 0x01, 0x01, 0x0D]: return "brainpoolP512r1"
        case [0x2B, 0x81, 0x04, 0x00, 0x0A]: return "secp256k1"
        case [0x2B, 0x06, 0x01, 0x04, 0x01, 0x97, 0x55, 0x01, 0x05, 0x01]: return "Curve25519"
        case [0x2B, 0x65, 0x71]: return "Ed448"
        case ed25519LegacyOID: return "Ed25519"
        default: return "curve " + OpenPGP.hex(oid)
        }
    }
}

// MARK: - Public-key packets (tags 6 and 14)

struct OpenPGPPublicKeyPacket: Sendable, Equatable {
    enum Material: Sendable, Equatable {
        case rsa(n: [UInt8], e: [UInt8])
        case ecdsa(OpenPGPCurve, point: [UInt8])
        /// EdDSA legacy (22) on the Ed25519 OID, or native Ed25519 (27): the 32-byte key.
        case ed25519([UInt8])
        /// Parsed for its fingerprint; signatures by it are not checked in this release.
        case unsupported(String)
    }

    let version: UInt8
    let created: UInt32
    let algorithm: UInt8
    let material: Material
    /// The packet body exactly as received (hashed for fingerprints and key signatures).
    let body: [UInt8]
    let fingerprint: [UInt8]
    let keyID: [UInt8]

    var createdDate: Date { Date(timeIntervalSince1970: TimeInterval(created)) }
    var fingerprintHex: String { OpenPGP.hex(fingerprint) }
    var keyIDHex: String { OpenPGP.hex(keyID) }

    init(body: [UInt8]) throws {
        var r = PGPByteReader(body)
        let version = try r.u8("key version")
        guard version == 4 || version == 6 else {
            throw OpenPGPFormatError.malformed(version == 5 ? "version 5 keys (LibrePGP) are not supported" : "version \(version) keys are not supported")
        }
        let created = try r.u32("key creation time")
        let algorithm = try r.u8("key algorithm")
        var m: PGPByteReader
        if version == 6 {
            let length = Int(try r.u32("key material length"))
            m = PGPByteReader(try r.take(length, "key material"))
        } else {
            m = PGPByteReader(r.rest())
        }
        let material: Material
        switch algorithm {
        case 1, 2, 3:
            material = .rsa(n: try m.mpi("RSA modulus"), e: try m.mpi("RSA exponent"))
        case 19:
            let oid = try m.take(Int(try m.u8("curve OID length")), "curve OID")
            let point = try m.mpi("ECDSA point")
            if let curve = OpenPGPCurve.from(oid: oid) { material = .ecdsa(curve, point: point) }
            else { material = .unsupported("ECDSA on \(OpenPGPCurve.name(oid: oid))") }
        case 22:
            let oid = try m.take(Int(try m.u8("curve OID length")), "curve OID")
            let point = try m.mpi("EdDSA point")
            if oid == OpenPGPCurve.ed25519LegacyOID {
                guard point.count == 33, point[0] == 0x40 else { throw OpenPGPFormatError.malformed("EdDSA point is not a 0x40-prefixed Ed25519 key") }
                material = .ed25519(Array(point[1...]))
            } else {
                material = .unsupported("EdDSA on \(OpenPGPCurve.name(oid: oid))")
            }
        case 27:
            material = .ed25519(try m.take(32, "Ed25519 key"))
        default:
            material = .unsupported(OpenPGP.publicKeyAlgorithm(algorithm))
        }
        self.version = version
        self.created = created
        self.algorithm = algorithm
        self.material = material
        self.body = body
        if version == 6 {
            self.fingerprint = Array(SHA256.hash(data: [0x9B] + PGPBytes.u32(body.count) + body))
            self.keyID = Array(fingerprint.prefix(8))
        } else {
            self.fingerprint = Array(Insecure.SHA1.hash(data: [0x99] + PGPBytes.u16(body.count) + body))
            self.keyID = Array(fingerprint.suffix(8))
        }
    }

    /// The key as it enters a key-signature hash (RFC 9580 §5.2.4).
    var hashFraming: [UInt8] {
        version == 6 ? [0x9B] + PGPBytes.u32(body.count) + body : [0x99] + PGPBytes.u16(body.count) + body
    }

    /// "RSA 3072", "ECDSA P-256", "EdDSA (Ed25519)", "Ed25519", or the unsupported description.
    var algorithmDescription: String {
        switch material {
        case .rsa(let n, _):
            let v = PGPBytes.strippingLeadingZeros(n)
            let bits = v.isEmpty ? 0 : (v.count - 1) * 8 + (8 - v[0].leadingZeroBitCount)
            return "RSA \(bits)"
        case .ecdsa(let curve, _): return "ECDSA \(curve.rawValue)"
        case .ed25519: return algorithm == 22 ? "EdDSA (Ed25519)" : "Ed25519"
        case .unsupported(let what): return what
        }
    }

    var unsupportedReason: String? {
        if case .unsupported(let what) = material { return what }
        if algorithm == 2 { return "RSA (encrypt-only)" }
        return nil
    }

    func matches(keyID id: [UInt8]?, fingerprint fp: [UInt8]?) -> Bool {
        if let fp, !fp.isEmpty { return fp == fingerprint }
        if let id, id.count == 8 { return id == keyID }
        return false
    }
}

// MARK: - Signature packets (tag 2)

struct OpenPGPSubpacket: Sendable, Equatable {
    let type: UInt8
    let critical: Bool
    let body: [UInt8]

    static func parse(_ area: [UInt8]) throws -> [OpenPGPSubpacket] {
        var r = PGPByteReader(area)
        var out: [OpenPGPSubpacket] = []
        while !r.atEnd {
            let l0 = Int(try r.u8("subpacket length"))
            let length: Int
            if l0 < 192 { length = l0 }
            else if l0 < 255 { length = ((l0 - 192) << 8) + Int(try r.u8("subpacket length")) + 192 }
            else { length = Int(try r.u32("subpacket length")) }
            guard length >= 1 else { throw OpenPGPFormatError.malformed("empty subpacket") }
            let raw = try r.take(length, "subpacket")
            out.append(OpenPGPSubpacket(type: raw[0] & 0x7F, critical: raw[0] & 0x80 != 0, body: Array(raw[1...])))
        }
        return out
    }

    /// Subpacket types RFC 4880 / RFC 9580 define; a CRITICAL unknown one makes the signature unusable.
    static let known: Set<UInt8> = [2, 3, 4, 5, 6, 7, 9, 10, 11, 12, 16, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 37, 39]
}

struct OpenPGPSignaturePacket: Sendable, Equatable {
    let version: UInt8
    let type: UInt8
    let keyAlgorithm: UInt8
    let hashAlgorithm: UInt8
    /// v4/v6: the octets from the version through the end of the hashed
    /// subpackets (they enter the hash with the trailer). v3: type + time.
    let hashedPortion: [UInt8]
    let hashed: [OpenPGPSubpacket]
    let unhashed: [OpenPGPSubpacket]
    let left16: [UInt8]
    /// v6 only (RFC 9580 §5.2.3): hashed before the data.
    let salt: [UInt8]
    /// MPIs (RSA: one; ECDSA/EdDSA legacy: r, s) or the native 64-byte Ed25519 signature.
    let material: [[UInt8]]
    private let v3Created: UInt32?
    private let v3Issuer: [UInt8]?

    init(body: [UInt8]) throws {
        var r = PGPByteReader(body)
        let version = try r.u8("signature version")
        switch version {
        case 3:
            guard try r.u8("v3 hashed length") == 5 else { throw OpenPGPFormatError.malformed("v3 signature hashed length is not 5") }
            let type = try r.u8("signature type")
            let time = try r.u32("signature time")
            v3Created = time
            v3Issuer = try r.take(8, "issuer key ID")
            self.type = type
            hashedPortion = [type] + PGPBytes.u32(time)
            keyAlgorithm = try r.u8("key algorithm")
            hashAlgorithm = try r.u8("hash algorithm")
            hashed = []
            unhashed = []
        case 4, 6:
            type = try r.u8("signature type")
            keyAlgorithm = try r.u8("key algorithm")
            hashAlgorithm = try r.u8("hash algorithm")
            let hashedLength = version == 6 ? Int(try r.u32("hashed subpacket length")) : try r.u16("hashed subpacket length")
            let hashedArea = try r.take(hashedLength, "hashed subpackets")
            hashedPortion = Array(body[0..<r.pos])
            hashed = try OpenPGPSubpacket.parse(hashedArea)
            let unhashedLength = version == 6 ? Int(try r.u32("unhashed subpacket length")) : try r.u16("unhashed subpacket length")
            unhashed = try OpenPGPSubpacket.parse(try r.take(unhashedLength, "unhashed subpackets"))
            v3Created = nil
            v3Issuer = nil
        default:
            throw OpenPGPFormatError.malformed("signature version \(version) is not supported")
        }
        self.version = version
        left16 = try r.take(2, "left 16 bits of the hash")
        var saltBytes: [UInt8] = []
        if version == 6 {
            saltBytes = try r.take(Int(try r.u8("salt length")), "salt")
        }
        self.salt = saltBytes
        // The signature value itself: a damaged one still lets the issuer be
        // named ("unknown key"); against a known key it is BAD.
        var material: [[UInt8]] = []
        var damaged = false
        let valueStart = r
        do {
            switch keyAlgorithm {
            case 1, 2, 3: material = [try r.mpi("RSA signature")]
            case 17, 19, 22: material = [try r.mpi("signature r"), try r.mpi("signature s")]
            case 27: material = [try r.take(64, "Ed25519 signature")]
            default: material = [r.rest()]
            }
        } catch {
            r = valueStart
            material = [r.rest()]
            damaged = true
        }
        self.material = material
        self.materialIsMalformed = damaged
    }

    /// True when the signature value could not be read as its algorithm's MPIs.
    let materialIsMalformed: Bool

    private func first(_ type: UInt8, hashedOnly: Bool = false) -> OpenPGPSubpacket? {
        hashed.first { $0.type == type } ?? (hashedOnly ? nil : unhashed.first { $0.type == type })
    }

    var created: UInt32? {
        if let v3Created { return v3Created }
        return first(2, hashedOnly: true).flatMap { PGPBytes.uint32($0.body[...]) }
    }
    var createdDate: Date? { created.map { Date(timeIntervalSince1970: TimeInterval($0)) } }

    /// Subpacket 33: the issuer's full fingerprint (v4: 20 bytes, v6: 32).
    var issuerFingerprint: [UInt8]? {
        guard let sp = first(33), sp.body.count >= 2 else { return nil }
        return Array(sp.body[1...])
    }

    var issuerKeyID: [UInt8]? {
        if let v3Issuer { return v3Issuer }
        if let sp = first(16), sp.body.count == 8 { return sp.body }
        if let fp = issuerFingerprint { return fp.count == 32 ? Array(fp.prefix(8)) : Array(fp.suffix(8)) }
        return nil
    }

    /// The issuer as people read it: the fingerprint when the signature names it, else the key ID.
    var issuerDescription: String {
        if let fp = issuerFingerprint { return OpenPGP.hex(fp) }
        if let id = issuerKeyID { return OpenPGP.hex(id) }
        return "(no issuer named)"
    }

    var keyExpirationSeconds: UInt32? { first(9, hashedOnly: true).flatMap { PGPBytes.uint32($0.body[...]) } }
    var signatureExpirationSeconds: UInt32? { first(3, hashedOnly: true).flatMap { PGPBytes.uint32($0.body[...]) } }
    var isPrimaryUserID: Bool { (first(25, hashedOnly: true)?.body.first ?? 0) != 0 }
    var keyFlags: UInt8? { first(27, hashedOnly: true)?.body.first }
    var revocationReason: (code: UInt8, text: String)? {
        guard let sp = first(29, hashedOnly: true), let code = sp.body.first else { return nil }
        return (code, String(decoding: sp.body.dropFirst(), as: UTF8.self))
    }
    /// Subpacket 32: the embedded (primary-key binding) signatures.
    var embedded: [OpenPGPSignaturePacket] {
        (hashed + unhashed).filter { $0.type == 32 }.compactMap { try? OpenPGPSignaturePacket(body: $0.body) }
    }
    var unknownCriticalSubpacket: UInt8? {
        hashed.first { $0.critical && !OpenPGPSubpacket.known.contains($0.type) }?.type
    }

    func isIssued(by key: OpenPGPPublicKeyPacket) -> Bool {
        if let fp = issuerFingerprint { return fp == key.fingerprint }
        if let id = issuerKeyID { return id == key.keyID }
        return true   // no issuer named: only a check against the key can tell
    }
}

// MARK: - Hashing

struct OpenPGPDigest {
    let algorithm: UInt8
    let bytes: [UInt8]
    let digest: any Digest
}

enum OpenPGPHasher {
    case sha1(Insecure.SHA1)
    case sha256(SHA256)
    case sha384(SHA384)
    case sha512(SHA512)

    /// SHA-1 and SHA2-256/384/512; nil for the rest (stated as unsupported, never as bad).
    init?(algorithm: UInt8) {
        switch algorithm {
        case 2: self = .sha1(Insecure.SHA1())
        case 8: self = .sha256(SHA256())
        case 9: self = .sha384(SHA384())
        case 10: self = .sha512(SHA512())
        default: return nil
        }
    }

    static func isSupported(_ algorithm: UInt8) -> Bool { OpenPGPHasher(algorithm: algorithm) != nil }

    mutating func update(_ bytes: [UInt8]) {
        switch self {
        case .sha1(var h): h.update(data: bytes); self = .sha1(h)
        case .sha256(var h): h.update(data: bytes); self = .sha256(h)
        case .sha384(var h): h.update(data: bytes); self = .sha384(h)
        case .sha512(var h): h.update(data: bytes); self = .sha512(h)
        }
    }

    func finalize() -> OpenPGPDigest {
        switch self {
        case .sha1(let h): let d = h.finalize(); return OpenPGPDigest(algorithm: 2, bytes: Array(d), digest: d)
        case .sha256(let h): let d = h.finalize(); return OpenPGPDigest(algorithm: 8, bytes: Array(d), digest: d)
        case .sha384(let h): let d = h.finalize(); return OpenPGPDigest(algorithm: 9, bytes: Array(d), digest: d)
        case .sha512(let h): let d = h.finalize(); return OpenPGPDigest(algorithm: 10, bytes: Array(d), digest: d)
        }
    }
}

// MARK: - The check

enum OpenPGPSignatureCheck: Equatable, Sendable {
    case valid
    /// The quick check or the cryptographic check failed.
    case invalid(String)
    /// The algorithm, hash or version cannot be checked here.
    case unsupported(String)
}

enum OpenPGPSignatureMath {

    /// RFC 9580 §5.2.4: the hash of `data` (already framed for the signature
    /// type) under `signature`: v6 salt first, then the data, then the hashed
    /// portion and the trailer. Nil when the hash algorithm is unsupported.
    static func digest(_ signature: OpenPGPSignaturePacket, over data: [[UInt8]]) -> OpenPGPDigest? {
        guard var h = OpenPGPHasher(algorithm: signature.hashAlgorithm) else { return nil }
        if signature.version == 6 { h.update(signature.salt) }
        for chunk in data { h.update(chunk) }
        h.update(signature.hashedPortion)
        switch signature.version {
        case 4: h.update([0x04, 0xFF] + PGPBytes.u32(signature.hashedPortion.count))
        case 6: h.update([0x06, 0xFF] + PGPBytes.u32(signature.hashedPortion.count))
        default: break   // v3: the five hashed octets only
        }
        return h.finalize()
    }

    /// The whole check: algorithm and hash support, the left-16 quick check, then the cryptography.
    static func check(_ signature: OpenPGPSignaturePacket, over data: [[UInt8]], key: OpenPGPPublicKeyPacket) -> OpenPGPSignatureCheck {
        if let reason = key.unsupportedReason { return .unsupported("algorithm \(reason) not supported") }
        guard OpenPGPHasher.isSupported(signature.hashAlgorithm) else {
            return .unsupported("hash \(OpenPGP.hashAlgorithm(signature.hashAlgorithm)) not supported")
        }
        if signature.version == 6, key.version != 6 { return .invalid("a version 6 signature cannot come from a version \(key.version) key") }
        if key.version == 6, signature.version != 6 { return .invalid("a version 6 key makes version 6 signatures only") }
        if let critical = signature.unknownCriticalSubpacket { return .unsupported("critical subpacket \(critical) not understood") }
        if signature.materialIsMalformed { return .invalid("the signature value is malformed") }
        guard let digest = digest(signature, over: data) else { return .unsupported("hash \(OpenPGP.hashAlgorithm(signature.hashAlgorithm)) not supported") }
        guard digest.bytes.count >= 2, Array(digest.bytes.prefix(2)) == signature.left16 else {
            return .invalid("the data does not match the signature (hash check failed)")
        }
        return verify(digest, signature: signature, key: key)
    }

    static func verify(_ digest: OpenPGPDigest, signature: OpenPGPSignaturePacket, key: OpenPGPPublicKeyPacket) -> OpenPGPSignatureCheck {
        let mismatch = OpenPGPSignatureCheck.invalid("the signature does not match the data")
        switch key.material {
        case .rsa(let n, let e):
            guard [1, 3].contains(signature.keyAlgorithm), let s = signature.material.first else { return .invalid("signature algorithm does not match the key") }
            return rsa(n: n, e: e, signature: s, digest: digest) ? .valid : mismatch
        case .ecdsa(let curve, let point):
            guard signature.keyAlgorithm == 19, signature.material.count == 2 else { return .invalid("signature algorithm does not match the key") }
            return ecdsa(curve, point: point, r: signature.material[0], s: signature.material[1], digest: digest.digest) ? .valid : mismatch
        case .ed25519(let raw):
            let sig: [UInt8]
            switch signature.keyAlgorithm {
            case 22 where key.algorithm == 22:
                guard signature.material.count == 2, let r = PGPBytes.leftPadded(signature.material[0], to: 32),
                      let s = PGPBytes.leftPadded(signature.material[1], to: 32) else { return mismatch }
                sig = r + s
            case 27 where key.algorithm == 27:
                guard let native = signature.material.first, native.count == 64 else { return mismatch }
                sig = native
            default:
                return .invalid("signature algorithm does not match the key")
            }
            guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return .invalid("the Ed25519 key is not a valid point") }
            return publicKey.isValidSignature(sig, for: digest.bytes) ? .valid : mismatch
        case .unsupported(let what):
            return .unsupported("algorithm \(what) not supported")
        }
    }

    // MARK: RSA (Security.framework)

    static func derLength(_ n: Int) -> [UInt8] {
        if n < 128 { return [UInt8(n)] }
        var bytes: [UInt8] = []
        var v = n
        while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    static func derInteger(_ value: [UInt8]) -> [UInt8] {
        var v = PGPBytes.strippingLeadingZeros(value)
        if v.isEmpty { v = [0] }
        if v[0] & 0x80 != 0 { v.insert(0, at: 0) }
        return [0x02] + derLength(v.count) + v
    }

    /// PKCS#1 RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER }
    static func pkcs1PublicKey(n: [UInt8], e: [UInt8]) -> [UInt8] {
        let body = derInteger(n) + derInteger(e)
        return [0x30] + derLength(body.count) + body
    }

    static func rsa(n: [UInt8], e: [UInt8], signature: [UInt8], digest: OpenPGPDigest) -> Bool {
        let modulus = PGPBytes.strippingLeadingZeros(n)
        guard !modulus.isEmpty, let padded = PGPBytes.leftPadded(signature, to: modulus.count) else { return false }
        let algorithm: SecKeyAlgorithm
        switch digest.algorithm {
        case 2: algorithm = .rsaSignatureDigestPKCS1v15SHA1
        case 8: algorithm = .rsaSignatureDigestPKCS1v15SHA256
        case 9: algorithm = .rsaSignatureDigestPKCS1v15SHA384
        case 10: algorithm = .rsaSignatureDigestPKCS1v15SHA512
        default: return false
        }
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic,
                                           kSecAttrKeySizeInBits: modulus.count * 8]
        guard let key = SecKeyCreateWithData(Data(pkcs1PublicKey(n: n, e: e)) as CFData, attributes as CFDictionary, nil) else { return false }
        return SecKeyVerifySignature(key, algorithm, Data(digest.bytes) as CFData, Data(padded) as CFData, nil)
    }

    // MARK: ECDSA (CryptoKit)

    static func ecdsa<D: Digest>(_ curve: OpenPGPCurve, point: [UInt8], r: [UInt8], s: [UInt8], digest: D) -> Bool {
        guard let rp = PGPBytes.leftPadded(r, to: curve.fieldBytes), let sp = PGPBytes.leftPadded(s, to: curve.fieldBytes) else { return false }
        let raw = rp + sp
        switch curve {
        case .p256:
            guard let key = try? P256.Signing.PublicKey(x963Representation: point),
                  let sig = try? P256.Signing.ECDSASignature(rawRepresentation: raw) else { return false }
            return key.isValidSignature(sig, for: digest)
        case .p384:
            guard let key = try? P384.Signing.PublicKey(x963Representation: point),
                  let sig = try? P384.Signing.ECDSASignature(rawRepresentation: raw) else { return false }
            return key.isValidSignature(sig, for: digest)
        case .p521:
            guard let key = try? P521.Signing.PublicKey(x963Representation: point),
                  let sig = try? P521.Signing.ECDSASignature(rawRepresentation: raw) else { return false }
            return key.isValidSignature(sig, for: digest)
        }
    }
}
