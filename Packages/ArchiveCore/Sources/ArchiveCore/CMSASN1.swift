//
//  CMSASN1.swift
//  ArchiveCore
//
//  R6 (S/MIME on iPhone and iPad): the ASN.1 layer of the portable CMS
//  reader. A BER reader — S/MIME written by Apple Mail and by OpenSSL's
//  streaming mode uses indefinite lengths and constructed OCTET STRINGs, which
//  strict DER parsers refuse — and a small DER writer used to build
//  certificates, envelopes and signatures for round-trip verification.
//
//  Bounded by design: nesting depth, length fields and element counts are
//  checked against the bytes actually present, so a hostile part cannot make
//  the reader recurse without end or allocate beyond its own size.
//

import Foundation

/// One BER element: identifier byte, the whole encoding and the contents.
struct ASN1Node: Sendable {
    /// The identifier octet (class, constructed bit, tag number < 31).
    let tag: UInt8
    /// The whole TLV, end-of-contents octets included for indefinite lengths.
    let raw: ArraySlice<UInt8>
    /// The contents octets (without end-of-contents).
    let content: ArraySlice<UInt8>
    let isIndefinite: Bool
    let depth: Int

    var isConstructed: Bool { tag & 0x20 != 0 }
    /// Context-specific tag number when the class is context-specific, else nil.
    var contextNumber: Int? { tag & 0xC0 == 0x80 ? Int(tag & 0x1F) : nil }

    static let maxDepth = 48

    /// Parses exactly one element from the start of `bytes`.
    static func parse(_ bytes: ArraySlice<UInt8>, depth: Int = 0) throws -> (node: ASN1Node, rest: ArraySlice<UInt8>) {
        guard depth <= maxDepth else { throw CMSError.malformed("nesting deeper than \(maxDepth) levels") }
        var i = bytes.startIndex
        guard i < bytes.endIndex else { throw CMSError.malformed("element expected, end of data found") }
        let tag = bytes[i]; i += 1
        guard tag & 0x1F != 0x1F else { throw CMSError.malformed("high tag numbers are not used by CMS") }
        guard i < bytes.endIndex else { throw CMSError.malformed("length missing") }
        let first = bytes[i]; i += 1
        if first == 0x80 {
            // Indefinite length: constructed only; children until 00 00.
            guard tag & 0x20 != 0 else { throw CMSError.malformed("indefinite length on a primitive element") }
            let contentStart = i
            var cursor = bytes[i...]
            while true {
                guard cursor.count >= 2 else { throw CMSError.malformed("end-of-contents missing") }
                if cursor[cursor.startIndex] == 0, cursor[cursor.startIndex + 1] == 0 {
                    let contentEnd = cursor.startIndex
                    let end = cursor.startIndex + 2
                    let node = ASN1Node(tag: tag, raw: bytes[bytes.startIndex..<end], content: bytes[contentStart..<contentEnd],
                                        isIndefinite: true, depth: depth)
                    return (node, bytes[end...])
                }
                cursor = try parse(cursor, depth: depth + 1).rest
            }
        }
        var length = 0
        if first & 0x80 == 0 {
            length = Int(first)
        } else {
            let count = Int(first & 0x7F)
            guard count <= 4, bytes.endIndex - i >= count else { throw CMSError.malformed("length field of \(count) bytes") }
            for _ in 0..<count { length = (length << 8) | Int(bytes[i]); i += 1 }
        }
        guard length <= bytes.endIndex - i else { throw CMSError.malformed("element of \(length) bytes runs past the end of the data") }
        let end = i + length
        let node = ASN1Node(tag: tag, raw: bytes[bytes.startIndex..<end], content: bytes[i..<end], isIndefinite: false, depth: depth)
        return (node, bytes[end...])
    }

    static func parse(_ bytes: [UInt8]) throws -> ASN1Node { try parse(bytes[...]).node }

    /// The elements inside a constructed element.
    func children() throws -> [ASN1Node] {
        guard isConstructed else { throw CMSError.malformed("primitive element has no children") }
        var out: [ASN1Node] = []
        var rest = content
        while !rest.isEmpty {
            let (child, next) = try ASN1Node.parse(rest, depth: depth + 1)
            out.append(child)
            rest = next
        }
        return out
    }

    /// The octets of an OCTET STRING (or implicitly tagged one), primitive or
    /// constructed from segments as BER allows.
    func octets() throws -> [UInt8] {
        if !isConstructed { return Array(content) }
        var out: [UInt8] = []
        for child in try children() { out += try child.octets() }
        return out
    }

    /// Dotted form of an OBJECT IDENTIFIER.
    func oid() throws -> String {
        guard tag == 0x06, !content.isEmpty else { throw CMSError.malformed("object identifier expected") }
        var parts: [String] = []
        var value = 0
        var firstDone = false
        for byte in content {
            guard value < (Int.max >> 8) else { throw CMSError.malformed("object identifier arc too large") }
            value = (value << 7) | Int(byte & 0x7F)
            if byte & 0x80 == 0 {
                if !firstDone {
                    let a = min(value / 40, 2)
                    parts.append(String(a)); parts.append(String(value - a * 40))
                    firstDone = true
                } else {
                    parts.append(String(value))
                }
                value = 0
            }
        }
        return parts.joined(separator: ".")
    }

    /// A small non-negative INTEGER.
    func int() throws -> Int {
        guard tag == 0x02, !content.isEmpty, content.count <= 8 else { throw CMSError.malformed("integer expected") }
        var v = 0
        for b in content { v = (v << 8) | Int(b) }
        return v
    }

    /// Re-encodes an implicitly tagged SET (`[n] IMPLICIT SET OF`) as the
    /// universal SET it stands for — what signed and authenticated attributes
    /// are signed or authenticated as (RFC 5652 §5.4, RFC 5083 §2.1).
    func asUniversalSet() -> [UInt8] {
        if !isIndefinite {
            var out = Array(raw)
            out[0] = 0x31
            return out
        }
        return ASN1.tlv(0x31, Array(content))
    }
}

/// A parsed AlgorithmIdentifier.
struct ASN1Algorithm: Sendable {
    let oid: String
    let parameters: ASN1Node?
    let raw: [UInt8]

    init(_ node: ASN1Node) throws {
        let parts = try node.children()
        guard node.tag == 0x30, let first = parts.first else { throw CMSError.malformed("algorithm identifier expected") }
        oid = try first.oid()
        parameters = parts.count > 1 && parts[1].tag != 0x05 ? parts[1] : nil
        raw = Array(node.raw)
    }
}

/// DER writer.
enum ASN1 {
    static func length(_ n: Int) -> [UInt8] {
        if n < 0x80 { return [UInt8(n)] }
        var bytes: [UInt8] = []
        var v = n
        while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
        return [0x80 | UInt8(bytes.count)] + bytes
    }
    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] { [tag] + length(content.count) + content }
    static func sequence(_ items: [[UInt8]]) -> [UInt8] { tlv(0x30, items.flatMap { $0 }) }
    /// SET OF in DER order (elements sorted by their encodings).
    static func set(_ items: [[UInt8]]) -> [UInt8] { tlv(0x31, items.sorted { $0.lexicographicallyPrecedes($1) }.flatMap { $0 }) }
    static func octetString(_ b: [UInt8]) -> [UInt8] { tlv(0x04, b) }
    static func bitString(_ b: [UInt8]) -> [UInt8] { tlv(0x03, [0] + b) }
    static let null: [UInt8] = [0x05, 0x00]
    static func explicit(_ n: UInt8, _ content: [UInt8]) -> [UInt8] { tlv(0xA0 | n, content) }
    static func implicitPrimitive(_ n: UInt8, _ content: [UInt8]) -> [UInt8] { tlv(0x80 | n, content) }
    static func implicitConstructed(_ n: UInt8, _ content: [UInt8]) -> [UInt8] { tlv(0xA0 | n, content) }
    static func utf8String(_ s: String) -> [UInt8] { tlv(0x0C, Array(s.utf8)) }
    static func ia5String(_ s: String) -> [UInt8] { tlv(0x16, Array(s.utf8)) }

    static func integer(_ v: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        var x = v
        repeat { bytes.insert(UInt8(x & 0xFF), at: 0); x >>= 8 } while x > 0
        return integer(bytes)
    }
    /// An unsigned big-endian magnitude as a DER INTEGER.
    static func integer(_ magnitude: [UInt8]) -> [UInt8] {
        var m = Array(magnitude.drop { $0 == 0 })
        if m.isEmpty { m = [0] }
        if m[0] & 0x80 != 0 { m.insert(0, at: 0) }
        return tlv(0x02, m)
    }

    static func oid(_ dotted: String) -> [UInt8] {
        let arcs = dotted.split(separator: ".").compactMap { Int($0) }
        guard arcs.count >= 2 else { return tlv(0x06, []) }
        var body: [UInt8] = []
        func base128(_ v: Int) -> [UInt8] {
            var out: [UInt8] = [UInt8(v & 0x7F)]
            var x = v >> 7
            while x > 0 { out.insert(UInt8(x & 0x7F) | 0x80, at: 0); x >>= 7 }
            return out
        }
        body += base128(arcs[0] * 40 + arcs[1])
        for arc in arcs.dropFirst(2) { body += base128(arc) }
        return tlv(0x06, body)
    }

    static func algorithm(_ oid: String, _ parameters: [UInt8]? = nil) -> [UInt8] {
        sequence([self.oid(oid)] + (parameters.map { [$0] } ?? []))
    }

    static func utcTime(_ date: Date) -> [UInt8] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyMMddHHmmss'Z'"
        return tlv(0x17, Array(f.string(from: date).utf8))
    }

    static func time(_ node: ASN1Node) -> Date? {
        guard let s = String(bytes: node.content, encoding: .ascii) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        switch node.tag {
        case 0x17: f.dateFormat = "yyMMddHHmmss'Z'"
        case 0x18: f.dateFormat = "yyyyMMddHHmmss'Z'"
        default: return nil
        }
        return f.date(from: s)
    }
}

/// The object identifiers the CMS reader knows.
enum CMSOID {
    static let data = "1.2.840.113549.1.7.1"
    static let signedData = "1.2.840.113549.1.7.2"
    static let envelopedData = "1.2.840.113549.1.7.3"
    static let authEnvelopedData = "1.2.840.113549.1.9.16.1.23"

    static let contentTypeAttr = "1.2.840.113549.1.9.3"
    static let messageDigestAttr = "1.2.840.113549.1.9.4"
    static let signingTimeAttr = "1.2.840.113549.1.9.5"

    static let rsaEncryption = "1.2.840.113549.1.1.1"
    static let rsaOAEP = "1.2.840.113549.1.1.7"
    static let mgf1 = "1.2.840.113549.1.1.8"
    static let rsaPSS = "1.2.840.113549.1.1.10"
    static let sha1WithRSA = "1.2.840.113549.1.1.5"
    static let sha256WithRSA = "1.2.840.113549.1.1.11"
    static let sha384WithRSA = "1.2.840.113549.1.1.12"
    static let sha512WithRSA = "1.2.840.113549.1.1.13"
    static let ecPublicKey = "1.2.840.10045.2.1"
    static let ecdsaSHA1 = "1.2.840.10045.4.1"
    static let ecdsaSHA256 = "1.2.840.10045.4.3.2"
    static let ecdsaSHA384 = "1.2.840.10045.4.3.3"
    static let ecdsaSHA512 = "1.2.840.10045.4.3.4"

    static let sha1 = "1.3.14.3.2.26"
    static let sha256 = "2.16.840.1.101.3.4.2.1"
    static let sha384 = "2.16.840.1.101.3.4.2.2"
    static let sha512 = "2.16.840.1.101.3.4.2.3"

    static let p256 = "1.2.840.10045.3.1.7"
    static let p384 = "1.3.132.0.34"
    static let p521 = "1.3.132.0.35"

    static let aes128CBC = "2.16.840.1.101.3.4.1.2"
    static let aes192CBC = "2.16.840.1.101.3.4.1.22"
    static let aes256CBC = "2.16.840.1.101.3.4.1.42"
    static let aes128GCM = "2.16.840.1.101.3.4.1.6"
    static let aes192GCM = "2.16.840.1.101.3.4.1.26"
    static let aes256GCM = "2.16.840.1.101.3.4.1.46"
    static let aes128Wrap = "2.16.840.1.101.3.4.1.5"
    static let aes192Wrap = "2.16.840.1.101.3.4.1.25"
    static let aes256Wrap = "2.16.840.1.101.3.4.1.45"
    static let desEDE3CBC = "1.2.840.113549.3.7"
    static let rc2CBC = "1.2.840.113549.3.2"
    static let desCBC = "1.3.14.3.2.7"

    /// ECDH single-pass schemes (RFC 5753, SEC 1) → the X9.63 KDF hash.
    static let ecdhSchemes: [String: CMSHash] = [
        "1.3.133.16.840.63.0.2": .sha1, "1.3.133.16.840.63.0.3": .sha1,       // std / cofactor, SHA-1 KDF
        "1.3.132.1.11.1": .sha256, "1.3.132.1.14.1": .sha256,
        "1.3.132.1.11.2": .sha384, "1.3.132.1.14.2": .sha384,
        "1.3.132.1.11.3": .sha512, "1.3.132.1.14.3": .sha512,
    ]

    static let subjectKeyIdentifierExt = "2.5.29.14"
    static let commonName = "2.5.4.3"
    static let emailAddress = "1.2.840.113549.1.9.1"
    static let subjectAltName = "2.5.29.17"

    /// A readable name for the algorithms a locked reason may name.
    static func name(_ oid: String) -> String {
        switch oid {
        case rc2CBC: return "RC2-CBC"
        case desCBC: return "DES-CBC"
        case "1.2.840.113549.1.9.16.3.6": return "3DES key wrap"
        case "1.2.840.113549.1.9.16.3.9": return "RC2 key wrap"
        case "1.3.132.1.11.0", "1.3.132.1.14.0": return "ECDH with a SHA-224 KDF"
        default: return oid
        }
    }
}

/// Hash functions CMS names (digest, OAEP, KDF).
public enum CMSHash: String, Sendable, CaseIterable {
    case sha1, sha256, sha384, sha512

    init?(oid: String) {
        switch oid {
        case CMSOID.sha1: self = .sha1
        case CMSOID.sha256: self = .sha256
        case CMSOID.sha384: self = .sha384
        case CMSOID.sha512: self = .sha512
        default: return nil
        }
    }

    var oid: String {
        switch self {
        case .sha1: return CMSOID.sha1
        case .sha256: return CMSOID.sha256
        case .sha384: return CMSOID.sha384
        case .sha512: return CMSOID.sha512
        }
    }
}
