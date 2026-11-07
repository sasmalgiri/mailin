//
//  OpenPGP.swift
//  ArchiveCore
//
//  Directive 2026-11-07 §6 "Protected mail/documents": OpenPGP mail and
//  attachments, DETECTED AND DESCRIBED WITHOUT A KEY. This release has no
//  OpenPGP key store and never attempts decryption or signature verification;
//  what it can say truthfully comes from the packet headers alone (RFC 4880
//  §4, RFC 9580 for v6):
//
//    PKESK  tag 1   encrypted to a public key — key ID (8 bytes, or the v6
//                   fingerprint) and the public-key algorithm
//    SKESK  tag 3   encrypted with a passphrase (symmetric) — the cipher
//    SIG    tag 2   a signature — version, type, hash and key algorithms,
//                   issuer key ID / fingerprint, creation time
//    OPS    tag 4   a one-pass signature (signed message ahead)
//    COMP   tag 8   compressed data (algorithm)
//    SED    tag 9   encrypted data WITHOUT integrity protection (no MDC)
//    LIT    tag 11  literal data (filename, date)
//    SEIPD  tag 18  encrypted data with an MDC (v1) or AEAD (v2)
//    AEAD   tag 20  AEAD-encrypted data (draft-ietf-openpgp-rfc4880bis)
//    keys   tags 5/6/7/14, user IDs 13, marker 10, trust 12, padding 21
//
//  ASCII armor (RFC 4880 §6) is decoded with its CRC-24 checked; clearsigned
//  messages keep their readable text. PGP/MIME (RFC 3156) and inline PGP are
//  classified from the content type and the armor markers.
//
//  Encrypted content is reported LOCKED with a note naming the recipient key
//  IDs; signatures as "signature present, not verified (no OpenPGP trust
//  store)". Nothing here derives, stores or guesses a key.
//

import Foundation

enum OpenPGP {

    // MARK: - Classification of mail

    enum MailKind: String, Sendable {
        /// multipart/encrypted; protocol="application/pgp-encrypted" (RFC 3156 §4)
        case pgpMIMEEncrypted
        /// multipart/signed; protocol="application/pgp-signature" (RFC 3156 §5)
        case pgpMIMESigned
        /// "-----BEGIN PGP MESSAGE-----" in a text body
        case inlineEncrypted
        /// "-----BEGIN PGP SIGNED MESSAGE-----" in a text body
        case inlineSigned

        var isEncrypted: Bool { self == .pgpMIMEEncrypted || self == .inlineEncrypted }
    }

    /// The message's OpenPGP kind from its top-level Content-Type and, for
    /// inline PGP, its text body. Nil when the message is ordinary mail.
    static func mailKind(contentType: String, body: String? = nil) -> MailKind? {
        let ct = contentType.lowercased()
        if ct.contains("multipart/encrypted"), ct.contains("application/pgp-encrypted") { return .pgpMIMEEncrypted }
        if ct.contains("multipart/signed"), ct.contains("application/pgp-signature") { return .pgpMIMESigned }
        if let body {
            if body.contains("-----BEGIN PGP MESSAGE-----") { return .inlineEncrypted }
            if body.contains("-----BEGIN PGP SIGNED MESSAGE-----") { return .inlineSigned }
        }
        return nil
    }

    /// The same decision from a parsed MIME tree (the root's type, then text parts for inline armor).
    static func mailKind(root: MIMEPart) -> MailKind? {
        if let kind = mailKind(contentType: root.mimeType + "; " + (root.headers["content-type"] ?? "")) { return kind }
        var stack = [root]
        while let part = stack.popLast() {
            if part.isText, let kind = mailKind(contentType: "", body: part.body) { return kind }
            if part.mimeType.lowercased() == "application/pgp-encrypted" { return .pgpMIMEEncrypted }
            if part.mimeType.lowercased() == "application/pgp-signature" { return .pgpMIMESigned }
            stack.append(contentsOf: part.subparts)
        }
        return nil
    }

    /// Attachments that are OpenPGP by name or type: .gpg / .pgp / .asc / .sig, application/pgp-*.
    static func isOpenPGPAttachment(mimeType: String, filename: String) -> Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        if ["gpg", "pgp", "asc", "sig"].contains(ext) { return true }
        let mime = mimeType.lowercased()
        return mime.hasPrefix("application/pgp-") || mime == "application/pgp"
    }

    // MARK: - Names

    static func publicKeyAlgorithm(_ id: UInt8) -> String {
        switch id {
        case 1: return "RSA"; case 2: return "RSA (encrypt-only)"; case 3: return "RSA (sign-only)"
        case 16: return "Elgamal"; case 17: return "DSA"; case 18: return "ECDH"; case 19: return "ECDSA"
        case 20: return "Elgamal (sign+encrypt, reserved)"; case 22: return "EdDSA"
        case 25: return "X25519"; case 26: return "X448"; case 27: return "Ed25519"; case 28: return "Ed448"
        default: return "public-key algorithm \(id)"
        }
    }

    static func hashAlgorithm(_ id: UInt8) -> String {
        switch id {
        case 1: return "MD5"; case 2: return "SHA-1"; case 3: return "RIPEMD-160"; case 8: return "SHA-256"
        case 9: return "SHA-384"; case 10: return "SHA-512"; case 11: return "SHA-224"
        case 12: return "SHA3-256"; case 14: return "SHA3-512"
        default: return "hash algorithm \(id)"
        }
    }

    static func symmetricAlgorithm(_ id: UInt8) -> String {
        switch id {
        case 0: return "plaintext"; case 1: return "IDEA"; case 2: return "TripleDES"; case 3: return "CAST5"; case 4: return "Blowfish"
        case 7: return "AES-128"; case 8: return "AES-192"; case 9: return "AES-256"; case 10: return "Twofish"
        case 11: return "Camellia-128"; case 12: return "Camellia-192"; case 13: return "Camellia-256"
        default: return "cipher \(id)"
        }
    }

    static func compressionAlgorithm(_ id: UInt8) -> String {
        switch id { case 0: return "uncompressed"; case 1: return "ZIP"; case 2: return "ZLIB"; case 3: return "BZip2"; default: return "compression \(id)" }
    }

    static func aeadAlgorithm(_ id: UInt8) -> String {
        switch id { case 1: return "EAX"; case 2: return "OCB"; case 3: return "GCM"; default: return "AEAD mode \(id)" }
    }

    static func signatureType(_ id: UInt8) -> String {
        switch id {
        case 0x00: return "binary document"; case 0x01: return "canonical text document"; case 0x02: return "standalone"
        case 0x10, 0x11, 0x12, 0x13: return "certification"; case 0x18: return "subkey binding"; case 0x19: return "primary key binding"
        case 0x1F: return "direct key"; case 0x20: return "key revocation"; case 0x28: return "subkey revocation"
        case 0x30: return "certification revocation"; case 0x40: return "timestamp"; case 0x50: return "third-party confirmation"
        default: return "signature type 0x\(String(id, radix: 16))"
        }
    }

    // MARK: - Packets

    struct Packet: Equatable, Sendable {
        let tag: UInt8
        let body: Data
        let newFormat: Bool
        /// The body length was given in partial-length chunks (new format) or ran to the end (old format type 3).
        let indeterminateLength: Bool
    }

    enum ParseError: Error, Equatable, LocalizedError {
        case notOpenPGP(String)
        case truncated(String)
        case badArmor(String)
        case crcMismatch

        var errorDescription: String? {
            switch self {
            case .notOpenPGP(let why): return "not OpenPGP data: \(why)"
            case .truncated(let what): return "OpenPGP data is truncated: \(what)"
            case .badArmor(let why): return "ASCII armor is malformed: \(why)"
            case .crcMismatch: return "ASCII armor CRC-24 does not match — the block is damaged"
            }
        }
    }

    /// Every packet header in a binary OpenPGP stream, with its body.
    static func packets(in data: Data) throws -> [Packet] {
        var out: [Packet] = []
        let bytes = [UInt8](data)
        var pos = 0
        guard !bytes.isEmpty else { throw ParseError.notOpenPGP("empty") }
        while pos < bytes.count {
            let header = bytes[pos]
            guard header & 0x80 != 0 else { throw out.isEmpty ? ParseError.notOpenPGP("first byte 0x\(String(header, radix: 16)) has no packet bit") : ParseError.truncated("packet header at \(pos)") }
            let newFormat = header & 0x40 != 0
            var tag: UInt8
            var body = Data()
            var indeterminate = false
            pos += 1
            if newFormat {
                tag = header & 0x3F
                // One or more length headers; partial lengths chain until a final one.
                var done = false
                while !done {
                    guard pos < bytes.count else { throw ParseError.truncated("length of packet \(tag)") }
                    let l = Int(bytes[pos]); pos += 1
                    var length: Int
                    if l < 192 { length = l; done = true }
                    else if l < 224 {
                        guard pos < bytes.count else { throw ParseError.truncated("length of packet \(tag)") }
                        length = ((l - 192) << 8) + Int(bytes[pos]) + 192; pos += 1; done = true
                    } else if l == 255 {
                        guard pos + 4 <= bytes.count else { throw ParseError.truncated("length of packet \(tag)") }
                        length = Int(bytes[pos]) << 24 | Int(bytes[pos + 1]) << 16 | Int(bytes[pos + 2]) << 8 | Int(bytes[pos + 3]); pos += 4; done = true
                    } else {
                        length = 1 << (l & 0x1F); indeterminate = true
                    }
                    guard pos + length <= bytes.count else { throw ParseError.truncated("body of packet \(tag) (\(length) bytes declared, \(bytes.count - pos) present)") }
                    body.append(contentsOf: bytes[pos..<(pos + length)])
                    pos += length
                }
            } else {
                tag = (header >> 2) & 0x0F
                let lengthType = header & 0x03
                var length: Int
                switch lengthType {
                case 0:
                    guard pos < bytes.count else { throw ParseError.truncated("length of packet \(tag)") }
                    length = Int(bytes[pos]); pos += 1
                case 1:
                    guard pos + 2 <= bytes.count else { throw ParseError.truncated("length of packet \(tag)") }
                    length = Int(bytes[pos]) << 8 | Int(bytes[pos + 1]); pos += 2
                case 2:
                    guard pos + 4 <= bytes.count else { throw ParseError.truncated("length of packet \(tag)") }
                    length = Int(bytes[pos]) << 24 | Int(bytes[pos + 1]) << 16 | Int(bytes[pos + 2]) << 8 | Int(bytes[pos + 3]); pos += 4
                default:
                    length = bytes.count - pos; indeterminate = true
                }
                guard pos + length <= bytes.count else { throw ParseError.truncated("body of packet \(tag) (\(length) bytes declared, \(bytes.count - pos) present)") }
                body = Data(bytes[pos..<(pos + length)])
                pos += length
            }
            out.append(Packet(tag: tag, body: body, newFormat: newFormat, indeterminateLength: indeterminate))
        }
        return out
    }

    // MARK: - Armor

    struct Armor: Equatable, Sendable {
        /// "PGP MESSAGE", "PGP SIGNATURE", "PGP PUBLIC KEY BLOCK", …
        let type: String
        let headers: [String: String]
        let data: Data
        /// True when a CRC-24 line was present and matched; nil when absent (RFC 9580 allows that).
        let crcVerified: Bool?
        /// For clearsigned messages: the signed text, dash-escapes removed.
        let clearText: String?
        let clearTextHash: String?
    }

    /// The first armored block in `text`.
    static func dearmor(_ text: String) throws -> Armor {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard let beginIndex = lines.firstIndex(where: { $0.hasPrefix("-----BEGIN PGP ") && $0.hasSuffix("-----") }) else {
            throw ParseError.notOpenPGP("no armor header line")
        }
        let type = String(lines[beginIndex].dropFirst(11).dropLast(5))
        var i = beginIndex + 1

        var clearText: String? = nil
        var clearHash: String? = nil
        var headers: [String: String] = [:]
        if type == "PGP SIGNED MESSAGE" {
            // Clearsigned: "Hash:" headers, blank line, dash-escaped text, then a PGP SIGNATURE block.
            while i < lines.count, !lines[i].isEmpty {
                if let colon = lines[i].firstIndex(of: ":") {
                    let key = String(lines[i][..<colon]).trimmingCharacters(in: .whitespaces)
                    let value = String(lines[i][lines[i].index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    headers[key] = value
                    if key == "Hash" { clearHash = value }
                }
                i += 1
            }
            i += 1
            var body: [String] = []
            while i < lines.count, !lines[i].hasPrefix("-----BEGIN PGP SIGNATURE-----") {
                var line = lines[i]
                if line.hasPrefix("- ") { line.removeFirst(2) }
                body.append(line)
                i += 1
            }
            clearText = body.joined(separator: "\n")
            guard i < lines.count else { throw ParseError.badArmor("clearsigned message without its signature block") }
            i += 1
        }

        // Armor headers until the blank line.
        while i < lines.count, !lines[i].isEmpty {
            if let colon = lines[i].firstIndex(of: ":") {
                headers[String(lines[i][..<colon]).trimmingCharacters(in: .whitespaces)] = String(lines[i][lines[i].index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
            i += 1
        }
        i += 1
        var base64 = ""
        var crcLine: String? = nil
        while i < lines.count, !lines[i].hasPrefix("-----END PGP ") {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("=") && line.count == 5 { crcLine = String(line.dropFirst()) } else { base64 += line }
            i += 1
        }
        guard i < lines.count else { throw ParseError.badArmor("no END line for \(type)") }
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters), !data.isEmpty else { throw ParseError.badArmor("body is not base64") }
        var crcVerified: Bool? = nil
        if let crcLine {
            guard let crcBytes = Data(base64Encoded: crcLine), crcBytes.count == 3 else { throw ParseError.badArmor("CRC line") }
            let expected = UInt32(crcBytes[0]) << 16 | UInt32(crcBytes[1]) << 8 | UInt32(crcBytes[2])
            guard crc24(data) == expected else { throw ParseError.crcMismatch }
            crcVerified = true
        }
        return Armor(type: type, headers: headers, data: data, crcVerified: crcVerified, clearText: clearText, clearTextHash: clearHash)
    }

    /// RFC 4880 §6.1 CRC-24 (init 0xB704CE, polynomial 0x1864CFB).
    static func crc24(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xB70_4CE
        for byte in data {
            crc ^= UInt32(byte) << 16
            for _ in 0..<8 {
                crc <<= 1
                if crc & 0x100_0000 != 0 { crc ^= 0x186_4CFB }
            }
        }
        return crc & 0xFF_FFFF
    }

    /// ASCII armor for `data` (fixtures and tests), with the CRC-24 line.
    static func armor(_ data: Data, type: String, headers: [String: String] = ["Version": "mailin test"]) -> String {
        var out = "-----BEGIN \(type)-----\n"
        for (k, v) in headers.sorted(by: { $0.key < $1.key }) { out += "\(k): \(v)\n" }
        out += "\n"
        let b64 = data.base64EncodedString()
        var start = b64.startIndex
        while start < b64.endIndex {
            let end = b64.index(start, offsetBy: 64, limitedBy: b64.endIndex) ?? b64.endIndex
            out += b64[start..<end] + "\n"
            start = end
        }
        let crc = crc24(data)
        out += "=" + Data([UInt8(crc >> 16), UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF)]).base64EncodedString() + "\n"
        out += "-----END \(type)-----\n"
        return out
    }

    // MARK: - Summary

    struct Recipient: Equatable, Sendable {
        /// 16 hex digits; "0000000000000000" is an anonymous ("hidden") recipient.
        let keyID: String
        let algorithm: String
        /// v6 PKESK carries the key's fingerprint instead of a key ID.
        let fingerprint: String?
        var isAnonymous: Bool { keyID == "0000000000000000" }
    }

    struct SignatureInfo: Equatable, Sendable {
        let version: UInt8
        let type: String
        let publicKeyAlgorithm: String
        let hashAlgorithm: String
        let issuerKeyID: String?
        let issuerFingerprint: String?
        let created: Date?
    }

    enum EncryptedData: Equatable, Sendable {
        /// Tag 9: no integrity protection at all.
        case withoutIntegrity
        /// Tag 18 v1: a modification detection code.
        case mdc
        /// Tag 18 v2 (RFC 9580) or tag 20: authenticated encryption.
        case aead(mode: String, cipher: String)
    }

    struct Summary: Equatable, Sendable {
        var armorType: String?
        var armorCRCVerified: Bool?
        var recipients: [Recipient] = []
        var symmetricSessionKeys: [String] = []     // cipher names, one per SKESK
        var signatures: [SignatureInfo] = []
        var onePassSignatures = 0
        var compression: String?
        var literalFilename: String?
        var literalBytes: Int?
        var encryptedData: EncryptedData?
        var publicKeys = 0
        var secretKeys = 0
        var userIDs: [String] = []
        var clearText: String?
        var clearTextHash: String?
        var packetTags: [UInt8] = []

        var isEncrypted: Bool { !recipients.isEmpty || !symmetricSessionKeys.isEmpty || encryptedData != nil }
        var isSigned: Bool { !signatures.isEmpty || onePassSignatures > 0 }
        var isKeyMaterial: Bool { publicKeys + secretKeys > 0 }

        /// The note for the coverage row / lock row. Counts in code; nothing is guessed.
        var description: String {
            var parts: [String] = []
            if isEncrypted {
                var who: [String] = []
                for r in recipients { who.append(r.isAnonymous ? "an anonymous recipient (\(r.algorithm))" : "key \(r.keyID) (\(r.algorithm))") }
                for c in symmetricSessionKeys { who.append("a passphrase (\(c))") }
                parts.append("OpenPGP-encrypted" + (who.isEmpty ? "" : " to " + who.joined(separator: ", ")))
                switch encryptedData {
                case .withoutIntegrity?: parts.append("no integrity protection (SED packet, no MDC)")
                case .mdc?: parts.append("MDC present")
                case .aead(let mode, let cipher)?: parts.append("AEAD \(mode) with \(cipher)")
                case nil: break
                }
                parts.append("not decrypted — this release has no OpenPGP key store")
            }
            if isSigned {
                let issuers = signatures.compactMap { $0.issuerFingerprint ?? $0.issuerKeyID }
                let algorithms = Set(signatures.map { "\($0.publicKeyAlgorithm)/\($0.hashAlgorithm)" }).sorted()
                var s = "signature present, not verified (no OpenPGP trust store)"
                if !issuers.isEmpty { s += "; issuer " + issuers.joined(separator: ", ") }
                if !algorithms.isEmpty { s += "; " + algorithms.joined(separator: ", ") }
                if signatures.isEmpty, onePassSignatures > 0 { s += "; \(onePassSignatures) one-pass signature(s)" }
                parts.append(s)
            }
            if let compression { parts.append("compressed (\(compression))") }
            if let literalFilename { parts.append("literal data" + (literalFilename.isEmpty ? "" : " “\(literalFilename)”") + (literalBytes.map { " (\($0) bytes)" } ?? "")) }
            if isKeyMaterial { parts.append("key material: \(publicKeys) public, \(secretKeys) secret" + (userIDs.isEmpty ? "" : "; " + userIDs.joined(separator: ", "))) }
            if let armorType { parts.append("ASCII armor “\(armorType)”" + (armorCRCVerified == true ? ", CRC-24 verified" : "")) }
            return parts.joined(separator: "; ")
        }
    }

    /// Everything the packet headers say about `data` (binary or armored).
    static func summarize(_ data: Data) throws -> Summary {
        var summary = Summary()
        var binary = data
        if let text = String(data: data.prefix(16_384), encoding: .utf8) ?? String(data: data.prefix(16_384), encoding: .isoLatin1),
           text.contains("-----BEGIN PGP ") {
            let whole = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            let armor = try dearmor(whole)
            summary.armorType = armor.type
            summary.armorCRCVerified = armor.crcVerified
            summary.clearText = armor.clearText
            summary.clearTextHash = armor.clearTextHash
            binary = armor.data
        }
        for packet in try packets(in: binary) {
            summary.packetTags.append(packet.tag)
            let b = [UInt8](packet.body)
            switch packet.tag {
            case 1:
                guard let version = b.first else { continue }
                if version == 3, b.count >= 10 {
                    summary.recipients.append(Recipient(keyID: hex(b[1..<9]), algorithm: publicKeyAlgorithm(b[9]), fingerprint: nil))
                } else if version == 6, b.count >= 2 {
                    let len = Int(b[1])
                    guard len >= 1, b.count >= 2 + len + 1 else { continue }
                    let fp = hex(b[3..<(2 + len)])
                    summary.recipients.append(Recipient(keyID: String(fp.prefix(16)), algorithm: publicKeyAlgorithm(b[2 + len]), fingerprint: fp))
                }
            case 3:
                guard b.count >= 2 else { continue }
                summary.symmetricSessionKeys.append(symmetricAlgorithm(b[1]))
            case 2:
                if let info = signature(b) { summary.signatures.append(info) }
            case 4: summary.onePassSignatures += 1
            case 8: if let a = b.first { summary.compression = compressionAlgorithm(a) }
            case 9: summary.encryptedData = .withoutIntegrity
            case 11:
                guard b.count >= 2 else { continue }
                let nameLength = Int(b[1])
                if b.count >= 2 + nameLength {
                    summary.literalFilename = String(decoding: b[2..<(2 + nameLength)], as: UTF8.self)
                    summary.literalBytes = max(0, b.count - 2 - nameLength - 4)
                }
            case 18:
                if b.first == 2, b.count >= 3 { summary.encryptedData = .aead(mode: aeadAlgorithm(b[2]), cipher: symmetricAlgorithm(b[1])) }
                else { summary.encryptedData = .mdc }
            case 20:
                if b.count >= 3 { summary.encryptedData = .aead(mode: aeadAlgorithm(b[2]), cipher: symmetricAlgorithm(b[1])) }
            case 5, 7: summary.secretKeys += 1
            case 6, 14: summary.publicKeys += 1
            case 13: summary.userIDs.append(String(decoding: b, as: UTF8.self))
            default: break
            }
        }
        if summary.packetTags.isEmpty { throw ParseError.notOpenPGP("no packets") }
        return summary
    }

    private static func signature(_ b: [UInt8]) -> SignatureInfo? {
        guard let version = b.first else { return nil }
        switch version {
        case 3:
            guard b.count >= 17 else { return nil }
            let time = UInt32(b[3]) << 24 | UInt32(b[4]) << 16 | UInt32(b[5]) << 8 | UInt32(b[6])
            return SignatureInfo(version: 3, type: signatureType(b[2]), publicKeyAlgorithm: publicKeyAlgorithm(b[15]), hashAlgorithm: hashAlgorithm(b[16]),
                                 issuerKeyID: hex(b[7..<15]), issuerFingerprint: nil, created: Date(timeIntervalSince1970: TimeInterval(time)))
        case 4, 5, 6:
            guard b.count >= 6 else { return nil }
            let wide = version == 6
            var pos = 4
            func readLength() -> Int? {
                if wide {
                    guard pos + 4 <= b.count else { return nil }
                    let v = Int(b[pos]) << 24 | Int(b[pos + 1]) << 16 | Int(b[pos + 2]) << 8 | Int(b[pos + 3]); pos += 4; return v
                }
                guard pos + 2 <= b.count else { return nil }
                let v = Int(b[pos]) << 8 | Int(b[pos + 1]); pos += 2; return v
            }
            var issuer: String?, fingerprint: String?, created: Date?
            for _ in 0..<2 {
                guard let length = readLength(), pos + length <= b.count else { break }
                let end = pos + length
                while pos < end {
                    // Subpacket: length (1, 2 or 5 octets), type (bit 7 = critical), body.
                    let l0 = Int(b[pos]); pos += 1
                    var sub: Int
                    if l0 < 192 { sub = l0 }
                    else if l0 < 255 { guard pos < end else { break }; sub = ((l0 - 192) << 8) + Int(b[pos]) + 192; pos += 1 }
                    else { guard pos + 4 <= end else { break }; sub = Int(b[pos]) << 24 | Int(b[pos + 1]) << 16 | Int(b[pos + 2]) << 8 | Int(b[pos + 3]); pos += 4 }
                    guard sub >= 1, pos + sub <= end else { pos = end; break }
                    let type = b[pos] & 0x7F
                    let body = b[(pos + 1)..<(pos + sub)]
                    switch type {
                    case 2 where body.count == 4:
                        let t = UInt32(body[body.startIndex]) << 24 | UInt32(body[body.startIndex + 1]) << 16 | UInt32(body[body.startIndex + 2]) << 8 | UInt32(body[body.startIndex + 3])
                        created = created ?? Date(timeIntervalSince1970: TimeInterval(t))
                    case 16 where body.count == 8: issuer = issuer ?? hex(body)
                    case 33 where body.count >= 2: fingerprint = fingerprint ?? hex(body.dropFirst())
                    default: break
                    }
                    pos += sub
                }
                pos = end
            }
            if issuer == nil, let fp = fingerprint { issuer = String(fp.suffix(16)) }
            return SignatureInfo(version: version, type: signatureType(b[1]), publicKeyAlgorithm: publicKeyAlgorithm(b[2]), hashAlgorithm: hashAlgorithm(b[3]),
                                 issuerKeyID: issuer, issuerFingerprint: fingerprint, created: created)
        default:
            return nil
        }
    }

    static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02X", $0) }.joined()
    }

    // MARK: - The document facade

    /// A .gpg / .pgp / .asc attachment through `DocumentTextExtractor`:
    /// encrypted → `encrypted` (the coverage row says locked; `summarize`
    /// names the recipients for the lock row); a clearsigned message → its
    /// text with the unverified signature noted; detached signatures and key
    /// blocks → no text.
    static func extract(fileURL: URL) throws -> OfficeTextExtractor.Result {
        let data = try Data(contentsOf: fileURL)
        guard data.count <= ExtractionLimits.effective.partBytes else {
            throw OfficeTextExtractor.ExtractError.notAPackage("\(data.count) bytes, over the \(ExtractionLimits.effective.partBytes)-byte guard")
        }
        let summary: Summary
        do { summary = try summarize(data) } catch let error as ParseError { throw OfficeTextExtractor.ExtractError.notAPackage(error.localizedDescription) }
        if summary.isEncrypted { throw OfficeTextExtractor.ExtractError.encrypted }
        if let text = summary.clearText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return OfficeTextExtractor.Result(text: "[Signed text]\n" + text + "\n", components: ["Signed text"],
                                              skipped: [summary.description], notText: [])
        }
        throw OfficeTextExtractor.ExtractError.noTextParts
    }
}
