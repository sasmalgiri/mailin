//
//  OpenPGPVerify.swift
//  ArchiveCore
//
//  GAP-PGP: verifying OpenPGP document signatures (types 0x00 binary and
//  0x01 canonical text) against the keyring, in the four places they occur:
//
//    cleartext signed     "-----BEGIN PGP SIGNED MESSAGE-----" (RFC 9580 §7):
//                         dash-escapes removed, trailing spaces/tabs removed,
//                         CRLF line endings, the last line ending excluded;
//                         any armor header other than "Hash:" → not verified
//    inline signed        one-pass signature + literal data + signature (or
//                         signature + literal), inside ZIP/ZLIB compression too
//    detached             a .sig/.asc next to the file it signs (same name
//                         minus the extension) — the caller hands the bytes in
//    PGP/MIME             multipart/signed (RFC 3156 §5): the first body part's
//                         exact bytes from the raw message, CRLF-canonical
//
//  Verdicts: good (key, user ID, time, whether the key had expired or been
//  revoked by then), bad (the data or signature does not match), unknown key
//  (the issuer named), cannot verify (the reason). Nothing is stored: the
//  verdict is derived whenever a message is described, so importing a key
//  changes the next description and never the original message.
//

import Foundation

enum OpenPGPVerdict: Equatable, Sendable {
    struct Good: Equatable, Sendable {
        /// Primary key fingerprint.
        let fingerprint: String
        /// The subkey that made the signature, when not the primary.
        let subkeyFingerprint: String?
        let userID: String?
        let signedAt: Date?
        let algorithm: String
        let hash: String
        /// Set when the key had already expired at the signature time.
        let keyExpiredOn: Date?
        let revocation: OpenPGPRevocation?
        /// True when the revocation predates the signature (or is "hard").
        let madeAfterRevocation: Bool
        let signatureExpiredOn: Date?
        let keyCreatedAfterSignature: Bool
    }

    case good(Good)
    /// The key is known and the check failed: the data or the signature was changed.
    case bad(issuer: String, reason: String)
    case unknownKey(issuer: String)
    case cannotVerify(reason: String)

    var isGood: Bool { if case .good = self { return true }; return false }
    var isBad: Bool { if case .bad = self { return true }; return false }

    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"
        return f.string(from: date)
    }

    /// The sentence the coverage row and the message view carry.
    var description: String {
        switch self {
        case .good(let g):
            var s = "good signature from " + (g.userID.map { "“\($0)” " } ?? "") + "(key \(g.fingerprint))"
            if let sub = g.subkeyFingerprint { s += " by its subkey \(sub)" }
            if let at = g.signedAt { s += ", made \(Self.time(at))" }
            s += ", \(g.algorithm)/\(g.hash)"
            if g.hash == "SHA-1" { s += " (SHA-1 is no longer considered strong)" }
            if g.keyCreatedAfterSignature { s += "; the signature is dated before the key was created" }
            if let expired = g.keyExpiredOn { s += "; the key had expired on \(Self.day(expired)) when it signed" }
            if let sigExpired = g.signatureExpiredOn { s += "; the signature itself expired on \(Self.day(sigExpired))" }
            if let r = g.revocation {
                if g.madeAfterRevocation {
                    s += "; WARNING: the key was revoked on \(Self.day(r.date)) (\(r.reasonDescription))"
                        + (r.isHard ? " — no signature by it can be relied on" : " — this signature was made after the revocation")
                } else {
                    s += "; the key was revoked on \(Self.day(r.date)) (\(r.reasonDescription)), after this signature was made"
                }
            }
            return s
        case .bad(let issuer, let reason):
            return "BAD signature by key \(issuer): \(reason)"
        case .unknownKey(let issuer):
            return "signature by unknown key \(issuer) — import the signer's public key to verify it"
        case .cannotVerify(let reason):
            return "signature cannot be verified: \(reason)"
        }
    }
}

enum OpenPGPVerifier {

    /// Verifies one document signature over `signedData` (nil: the signed data is not available).
    static func verify(_ signature: OpenPGPSignaturePacket, signedData: [UInt8]?, keyring: OpenPGPKeyring) -> OpenPGPVerdict {
        guard signature.type == 0x00 || signature.type == 0x01 else {
            return .cannotVerify(reason: "a \(OpenPGP.signatureType(signature.type)) signature is not a signature over a document")
        }
        guard let found = keyring.lookup(keyID: signature.issuerKeyID, fingerprint: signature.issuerFingerprint) else {
            return .unknownKey(issuer: signature.issuerDescription)
        }
        let cert = found.certificate
        if let sub = found.subkey, let why = sub.unusableReason {
            return .cannotVerify(reason: "subkey \(sub.key.fingerprintHex) of key \(cert.fingerprintHex): \(why)")
        }
        guard let signedData else {
            return .cannotVerify(reason: "the signed data is not with the signature (key \(cert.fingerprintHex) is in the keyring)")
        }
        let data = signature.type == 0x01 ? canonicalText(signedData) : signedData
        switch OpenPGPSignatureMath.check(signature, over: [data], key: found.key) {
        case .unsupported(let why):
            return .cannotVerify(reason: why)
        case .invalid(let why):
            return .bad(issuer: cert.fingerprintHex, reason: why)
        case .valid:
            let at = signature.createdDate
            var expiredOn: Date?
            if let at {
                if let e = cert.expires, e <= at { expiredOn = e }
                if let sub = found.subkey, let e = sub.expires, e <= at { expiredOn = min(expiredOn ?? e, e) }
            }
            let revocation = found.subkey?.revocation ?? cert.revocation
            let after = revocation.map { r in r.isHard || (at.map { r.date <= $0 } ?? true) } ?? false
            let sigExpired = signature.signatureExpirationSeconds.flatMap { s -> Date? in
                guard s != 0, let at else { return nil }
                let end = at.addingTimeInterval(TimeInterval(s))
                return end < Date() ? end : nil
            }
            return .good(.init(fingerprint: cert.fingerprintHex, subkeyFingerprint: found.subkey?.key.fingerprintHex,
                               userID: cert.primaryUserID, signedAt: at,
                               algorithm: found.key.algorithmDescription, hash: OpenPGP.hashAlgorithm(signature.hashAlgorithm),
                               keyExpiredOn: expiredOn, revocation: revocation, madeAfterRevocation: after,
                               signatureExpiredOn: sigExpired,
                               keyCreatedAfterSignature: at.map { $0 < found.key.createdDate } ?? false))
        }
    }

    /// RFC 9580 §5.2.1.2: a text signature is computed over CRLF line endings.
    static func canonicalText(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + bytes.count / 32)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x0D {
                out += [0x0D, 0x0A]
                if i + 1 < bytes.count, bytes[i + 1] == 0x0A { i += 1 }
            } else if b == 0x0A {
                out += [0x0D, 0x0A]
            } else {
                out.append(b)
            }
            i += 1
        }
        return out
    }

    // MARK: Signatures in a packet stream

    static func signaturePackets(_ packets: [OpenPGP.Packet]) -> [OpenPGPSignaturePacket?] {
        packets.filter { $0.tag == 2 }.map { try? OpenPGPSignaturePacket(body: [UInt8]($0.body)) }
    }

    /// Verdicts for the signatures among `packets` over `signedData`; a signature that cannot be parsed says so.
    static func verdicts(signatures packets: [OpenPGP.Packet], signedData: [UInt8]?, keyring: OpenPGPKeyring) -> [OpenPGPVerdict] {
        signaturePackets(packets).map { sig in
            guard let sig else { return .cannotVerify(reason: "the signature packet is malformed") }
            return verify(sig, signedData: signedData, keyring: keyring)
        }
    }

    /// Inline-signed data (RFC 9580 §10.3): packets after decompression, the literal data's bytes.
    struct Inline {
        var packets: [OpenPGP.Packet]
        var literal: [UInt8]?
        var literalFilename: String?
        var problem: String?
    }

    /// Opens compressed packets (ZIP = raw deflate, ZLIB) so the literal data and signatures inside are reached.
    static func flatten(_ packets: [OpenPGP.Packet], depth: Int = 0) -> Inline {
        var out = Inline(packets: [])
        for p in packets {
            if p.tag == 8 {
                let b = [UInt8](p.body)
                guard let algorithm = b.first else { out.problem = "empty compressed packet"; continue }
                guard depth < 8 else { out.problem = "compressed packets nested deeper than 8 levels"; continue }
                let payload = Data(b.dropFirst())
                let limit = Int(clamping: ExtractionLimits.effective.partBytes)
                var inflated: Data?
                switch algorithm {
                case 0: inflated = payload
                case 1: inflated = try? RawDeflate.inflate(payload, limit: limit)
                case 2:
                    // RFC 1950: 2 header bytes, the deflate stream, a 4-byte Adler-32.
                    if payload.count > 6 { inflated = try? RawDeflate.inflate(payload.dropFirst(2).dropLast(4), limit: limit) }
                default:
                    out.problem = "the signed data is \(OpenPGP.compressionAlgorithm(algorithm))-compressed, which this release does not open"
                    continue
                }
                guard let inflated, let inner = try? OpenPGP.packets(in: inflated) else {
                    out.problem = "the compressed signed data could not be opened (damaged, or larger than the \(ExtractionLimits.bytes(ExtractionLimits.effective.partBytes)) per-part guard)"
                    continue
                }
                let nested = flatten(inner, depth: depth + 1)
                out.packets += nested.packets
                out.literal = out.literal ?? nested.literal
                out.literalFilename = out.literalFilename ?? nested.literalFilename
                out.problem = out.problem ?? nested.problem
            } else {
                out.packets.append(p)
                if p.tag == 11, out.literal == nil {
                    var r = PGPByteReader([UInt8](p.body))
                    if (try? r.u8("format")) != nil, let n = try? r.u8("name length"), let name = try? r.take(Int(n), "name"),
                       (try? r.take(4, "date")) != nil {
                        out.literal = r.rest()
                        out.literalFilename = String(decoding: name, as: UTF8.self)
                    }
                }
            }
        }
        return out
    }

    // MARK: Cleartext signature framework (RFC 9580 §7)

    struct Cleartext {
        /// The signed text: dash-escapes removed, trailing whitespace removed, CRLF, last line ending excluded.
        let signedBytes: [UInt8]
        let signatureData: Data
        /// Armor headers other than "Hash:" between the BEGIN line and the text (RFC 9580 §7.1: MUST decline).
        let unexpectedHeaders: [String]
    }

    static func cleartext(_ data: Data) -> Cleartext? {
        // Bytes ⇄ text without loss: UTF-8 when valid, otherwise ISO Latin-1 (one byte, one character).
        let encoding: String.Encoding = String(data: data, encoding: .utf8) != nil ? .utf8 : .isoLatin1
        guard let text = String(data: data, encoding: encoding) else { return nil }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard let begin = lines.firstIndex(where: { $0.trimmingTrailingWhitespace() == "-----BEGIN PGP SIGNED MESSAGE-----" }) else { return nil }
        var i = begin + 1
        var unexpected: [String] = []
        while i < lines.count, !lines[i].trimmingTrailingWhitespace().isEmpty {
            let header = lines[i]
            if !header.hasPrefix("Hash:") { unexpected.append(header) }
            i += 1
        }
        i += 1
        var body: [String] = []
        while i < lines.count, !lines[i].hasPrefix("-----BEGIN PGP SIGNATURE-----") {
            var line = lines[i]
            if line.hasPrefix("- ") { line.removeFirst(2) }
            body.append(line.trimmingTrailingWhitespace())
            i += 1
        }
        guard i < lines.count else { return nil }
        let signatureArmor = lines[i...].joined(separator: "\n")
        guard let armor = try? OpenPGP.dearmor(signatureArmor), armor.type == "PGP SIGNATURE" else { return nil }
        let joined = body.joined(separator: "\r\n")
        let bytes = [UInt8](joined.data(using: encoding) ?? Data(joined.utf8))
        return Cleartext(signedBytes: bytes, signatureData: armor.data, unexpectedHeaders: unexpected)
    }

    // MARK: PGP/MIME (RFC 3156 §5)

    struct PGPMIMESigned: Equatable, Sendable {
        /// The first body part, header and body, exactly as in the message, with CRLF line endings.
        let signedEntity: Data
        /// The second part's content, transfer-decoded (an armored or binary signature).
        let signature: Data
    }

    /// The signed entity and signature of a multipart/signed (application/pgp-signature) message, from its raw bytes.
    static func pgpMIMESigned(rawMessage: Data) -> PGPMIMESigned? {
        let bytes = [UInt8](rawMessage)
        guard let (headerEnd, bodyStart) = headerBoundary(bytes) else { return nil }
        let headers = unfoldedHeaders(Array(bytes[0..<headerEnd]))
        guard let contentType = headers["content-type"], contentType.lowercased().contains("multipart/signed"),
              contentType.lowercased().contains("application/pgp-signature"),
              let boundary = parameter("boundary", in: contentType), !boundary.isEmpty else { return nil }
        return parts(Array(bytes[bodyStart...]), boundary: boundary)
    }

    private static func parts(_ body: [UInt8], boundary: String) -> PGPMIMESigned? {
        let delimiter = [UInt8](("--" + boundary).utf8)
        // Line starts that hold a delimiter (transport padding — trailing spaces/tabs — allowed).
        var lineStarts: [(start: Int, contentEnd: Int, next: Int, closing: Bool)] = []
        var start = 0
        while start < body.count {
            var end = start
            while end < body.count, body[end] != 0x0A { end += 1 }
            var contentEnd = end
            if contentEnd > start, body[contentEnd - 1] == 0x0D { contentEnd -= 1 }
            let line = Array(body[start..<contentEnd])
            if line.count >= delimiter.count, Array(line[0..<delimiter.count]) == delimiter {
                var tail = Array(line[delimiter.count...])
                let closing = tail.starts(with: [0x2D, 0x2D])
                if closing { tail.removeFirst(2) }
                if tail.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) {
                    lineStarts.append((start, contentEnd, min(end + 1, body.count), closing))
                }
            }
            start = end + 1
        }
        guard lineStarts.count >= 2, !lineStarts[0].closing else { return nil }
        // Part 1: after the first delimiter line, up to the line break before the second delimiter.
        let p1Start = lineStarts[0].next
        var p1End = lineStarts[1].start
        if p1End > p1Start, body[p1End - 1] == 0x0A { p1End -= 1; if p1End > p1Start, body[p1End - 1] == 0x0D { p1End -= 1 } }
        guard p1End >= p1Start else { return nil }
        let signed = OpenPGPVerifier.canonicalText(Array(body[p1Start..<p1End]))
        // Part 2: the signature.
        guard !lineStarts[1].closing else { return nil }
        let p2Start = lineStarts[1].next
        var p2End = lineStarts.count >= 3 ? lineStarts[2].start : body.count
        if p2End > p2Start, body[p2End - 1] == 0x0A { p2End -= 1; if p2End > p2Start, body[p2End - 1] == 0x0D { p2End -= 1 } }
        guard p2End >= p2Start else { return nil }
        let part2 = Array(body[p2Start..<p2End])
        guard let (h2End, b2Start) = headerBoundary(part2) else { return nil }
        let h2 = unfoldedHeaders(Array(part2[0..<h2End]))
        var content = Data(part2[b2Start...])
        if h2["content-transfer-encoding"]?.lowercased().contains("base64") == true,
           let decoded = Data(base64Encoded: content, options: .ignoreUnknownCharacters) { content = decoded }
        return PGPMIMESigned(signedEntity: Data(signed), signature: content)
    }

    /// End of the header block and start of the body (after the first empty line); a part with no header starts with the empty line.
    static func headerBoundary(_ b: [UInt8]) -> (Int, Int)? {
        if b.starts(with: [0x0D, 0x0A]) { return (0, 2) }
        if b.starts(with: [0x0A]) { return (0, 1) }
        var i = 0
        while i < b.count {
            if b[i] == 0x0A {
                if i + 1 < b.count, b[i + 1] == 0x0A { return (i + 1, i + 2) }
                if i + 2 < b.count, b[i + 1] == 0x0D, b[i + 2] == 0x0A { return (i + 1, i + 3) }
            }
            i += 1
        }
        return nil
    }

    static func unfoldedHeaders(_ b: [UInt8]) -> [String: String] {
        let text = String(decoding: b, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        var out: [String: String] = [:]
        var current: (String, String)?
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                if current != nil { current!.1 += " " + line.trimmingCharacters(in: .whitespaces) }
                continue
            }
            if let c = current, out[c.0] == nil { out[c.0] = c.1 }
            current = nil
            if let colon = line.firstIndex(of: ":") {
                current = (line[..<colon].trimmingCharacters(in: .whitespaces).lowercased(),
                           line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            }
        }
        if let c = current, out[c.0] == nil { out[c.0] = c.1 }
        return out
    }

    static func parameter(_ name: String, in header: String) -> String? {
        for piece in header.components(separatedBy: ";").dropFirst() {
            let kv = piece.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2, kv[0].lowercased() == name else { continue }
            var v = kv[1]
            if v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 { v = String(v.dropFirst().dropLast()) }
            return v
        }
        return nil
    }
}

private extension String {
    /// RFC 9580 §7.2: spaces and tabs at the end of a line are not signed.
    func trimmingTrailingWhitespace() -> String {
        var s = Substring(self)
        while let last = s.last, last == " " || last == "\t" || last == "\r" { s = s.dropLast() }
        return String(s)
    }
}

extension OpenPGP {

    /// The name of the file a detached signature signs: "memo.txt.sig" → "memo.txt" (.sig, .asc, .gpg, .pgp).
    static func signedFileName(forDetachedSignature filename: String) -> String? {
        let ext = (filename as NSString).pathExtension.lowercased()
        guard ["sig", "asc", "gpg", "pgp"].contains(ext) else { return nil }
        let stem = (filename as NSString).deletingPathExtension
        return stem.isEmpty ? nil : stem
    }

    /// PGP/MIME (RFC 3156): the verdict on each signature of a multipart/signed
    /// message from its raw bytes; nil when the message is not PGP/MIME signed.
    static func verifyPGPMIME(rawMessage: Data, keyring: OpenPGPKeyring = .active) -> [OpenPGPVerdict]? {
        guard let parts = OpenPGPVerifier.pgpMIMESigned(rawMessage: rawMessage) else { return nil }
        guard let summary = try? summarize(parts.signature, keyring: keyring, signedData: parts.signedEntity) else {
            return [.cannotVerify(reason: "the signature part holds no OpenPGP signature")]
        }
        return summary.verdicts
    }

    static func verifyPGPMIME(rawMessage: String, keyring: OpenPGPKeyring = .active) -> [OpenPGPVerdict]? {
        verifyPGPMIME(rawMessage: Data(rawMessage.utf8), keyring: keyring)
    }
}
