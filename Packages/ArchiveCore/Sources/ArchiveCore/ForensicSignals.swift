//
//  ForensicSignals.swift
//  ArchiveCore
//
//  3.1 F1–F4 (switch: `v31ForensicTimestamps`, preview, off) — what a message
//  says about its own history, decoded offline.
//
//  F1  Hidden timestamps: Outlook Thread-Index ([MS-OXOMSG] conversation
//      index: 6-byte FILETIME header + 5-byte child blocks), Outlook MIME
//      boundaries (`_NextPart_…_01D6A2B3.4C5D6E70` = FILETIME high.low),
//      JavaMail boundaries and Message-IDs carrying Unix epochs, every
//      Received hop and the Date header — one timeline, each with its source.
//  F2  Missing DKIM: mail from a provider that signs everything, dated after
//      it began signing, with no DKIM-Signature.
//  F3  Offline DKIM verification (rsa-sha256, ed25519-sha256; simple/relaxed)
//      against keys the examiner imports. No DNS lookup is ever made.
//  F4  Removed-attachment signals and the Received trace (hops, delays,
//      clock going backwards).
//

import Foundation
import CryptoKit
import Security

public enum ForensicSignalsPolicy {
    nonisolated(unsafe) public static var isEnabled = false
}

// MARK: - F1 Timestamps

public struct ForensicTimestamp: Sendable, Equatable {
    public var source: String
    public var date: Date
    public var raw: String
}

public enum HiddenTimestamps {
    /// FILETIME (100-ns intervals since 1601-01-01) → Date.
    static func date(fileTime: UInt64) -> Date? {
        let unix = Double(fileTime) / 10_000_000 - 11_644_473_600
        guard unix > 631_152_000, unix < Date().timeIntervalSince1970 + 366 * 86_400 else { return nil }   // 1990 … next year
        return Date(timeIntervalSince1970: unix)
    }

    /// Thread-Index: header FILETIME, then one entry per reply/forward.
    public static func threadIndex(_ value: String) -> [ForensicTimestamp] {
        guard let data = Data(base64Encoded: value.trimmingCharacters(in: .whitespacesAndNewlines)), data.count >= 22 else { return [] }
        let b = [UInt8](data)
        var ft: UInt64 = 0
        for i in 0..<6 { ft = (ft << 8) | UInt64(b[i]) }
        ft <<= 16
        guard let start = date(fileTime: ft) else { return [] }
        var out = [ForensicTimestamp(source: "Thread-Index (conversation start)", date: start, raw: value)]
        var off = 22
        var current = ft
        var n = 1
        while off + 5 <= b.count {
            let word = (UInt32(b[off]) << 24) | (UInt32(b[off + 1]) << 16) | (UInt32(b[off + 2]) << 8) | UInt32(b[off + 3])
            let delta: UInt64 = (word & 0x8000_0000) == 0
                ? UInt64(word & 0x7FFF_FFFF) << 18
                : UInt64(word & 0x7FFF_FFFF) << 23
            current &+= delta
            if let d = date(fileTime: current) {
                out.append(ForensicTimestamp(source: "Thread-Index (reply/forward \(n))", date: d, raw: value))
            }
            off += 5
            n += 1
        }
        return out
    }

    /// Outlook boundaries: `…_01D6A2B3.4C5D6E70` (FILETIME high.low, hex).
    public static func outlookBoundary(_ boundary: String) -> ForensicTimestamp? {
        guard let r = boundary.range(of: #"([0-9A-Fa-f]{8})\.([0-9A-Fa-f]{8})"#, options: .regularExpression) else { return nil }
        let parts = boundary[r].split(separator: ".")
        guard parts.count == 2, let hi = UInt64(parts[0], radix: 16), let lo = UInt64(parts[1], radix: 16),
              let d = date(fileTime: (hi << 32) | lo) else { return nil }
        return ForensicTimestamp(source: "MIME boundary (Outlook FILETIME)", date: d, raw: boundary)
    }

    /// 13-digit millisecond or 10-digit second Unix times inside a token.
    public static func epoch(in token: String, source: String) -> ForensicTimestamp? {
        let now = Date().timeIntervalSince1970
        for pattern in [#"(?<!\d)1\d{12}(?!\d)"#, #"(?<!\d)1\d{9}(?!\d)"#] {
            guard let r = token.range(of: pattern, options: .regularExpression), let v = Double(token[r]) else { continue }
            let secs = token[r].count == 13 ? v / 1000 : v
            if secs > 946_684_800, secs < now + 366 * 86_400 {      // 2000 … next year
                return ForensicTimestamp(source: source, date: Date(timeIntervalSince1970: secs), raw: token)
            }
        }
        return nil
    }

    /// Gmail MIME boundary: 28 hex digits, `000000000000` + A(6) + B(8) + 2;
    /// B followed by A is a Unix time in microseconds (Metaspike, "Dates in
    /// Hiding" part 2: `000000000000b6809105a0ae7b18` → 2020-03-12 20:49:03.864 UTC).
    public static func gmailBoundary(_ boundary: String) -> ForensicTimestamp? {
        let b = boundary.lowercased()
        guard b.count == 28, b.hasPrefix("000000000000"), b.allSatisfy(\.isHexDigit) else { return nil }
        let chars = Array(b)
        let a = String(chars[12..<18]), bPart = String(chars[18..<26])
        guard let micros = UInt64(bPart + a, radix: 16) else { return nil }
        let secs = Double(micros / 1_000) / 1_000   // millisecond precision, as published
        guard secs > 946_684_800, secs < Date().timeIntervalSince1970 + 366 * 86_400 else { return nil }
        return ForensicTimestamp(source: "MIME boundary (Gmail)", date: Date(timeIntervalSince1970: secs), raw: boundary)
    }

    /// Gmail's internal message / thread id (X-GM-MSGID, X-GM-THRID; decimal
    /// in Takeout, hex in the API): without its last 5 hex digits it is Unix
    /// time in milliseconds (Metaspike part 3: 172ed79b0337c14f → 2020-06-25
    /// 21:54:34.675 UTC).
    public static func gmailInternalID(_ value: String, source: String) -> ForensicTimestamp? {
        let v = value.trimmingCharacters(in: .whitespaces)
        let hex: String
        if v.allSatisfy(\.isNumber), let n = UInt64(v) { hex = String(n, radix: 16) }
        else if v.allSatisfy(\.isHexDigit) { hex = v.lowercased() } else { return nil }
        guard hex.count > 5, let ms = UInt64(hex.dropLast(5), radix: 16) else { return nil }
        let secs = Double(ms) / 1000
        guard secs > 1_099_000_000, secs < Date().timeIntervalSince1970 + 366 * 86_400 else { return nil }   // Gmail began 2004
        return ForensicTimestamp(source: source, date: Date(timeIntervalSince1970: secs), raw: value)
    }

    /// Version-1 UUIDs (RFC 4122) carry their creation time: 100-ns ticks since 1582-10-15.
    public static func uuidV1(in token: String) -> ForensicTimestamp? {
        guard let r = token.range(of: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-1[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}"#,
                                  options: .regularExpression) else { return nil }
        let parts = token[r].split(separator: "-")
        guard parts.count == 5, let low = UInt64(parts[0], radix: 16), let mid = UInt64(parts[1], radix: 16),
              let hi = UInt64(parts[2], radix: 16) else { return nil }
        let ticks = ((hi & 0x0FFF) << 48) | (mid << 32) | low
        let secs = Double(ticks) / 10_000_000 - 12_219_292_800
        guard secs > 631_152_000, secs < Date().timeIntervalSince1970 + 366 * 86_400 else { return nil }
        return ForensicTimestamp(source: "Message-ID (version-1 UUID)", date: Date(timeIntervalSince1970: secs), raw: String(token[r]))
    }

    /// Every timestamp the message carries, oldest first.
    public static func all(headers: [String: String], rawSource: String) -> [ForensicTimestamp] {
        var out: [ForensicTimestamp] = []
        if let d = headers["Date"], let date = RFC5322Date.parse(d) {
            out.append(ForensicTimestamp(source: "Date header", date: date, raw: d))
        }
        if let ti = headers["Thread-Index"] { out += threadIndex(ti) }
        if let mid = headers["Message-ID"] {
            if let t = epoch(in: mid, source: "Message-ID (Unix time)") { out.append(t) }
            if let t = uuidV1(in: mid) { out.append(t) }
        }
        if let id = RecoveryDetector.value(headers, "X-GM-MSGID"), let t = gmailInternalID(id, source: "Gmail message id") { out.append(t) }
        if let id = RecoveryDetector.value(headers, "X-GM-THRID"), let t = gmailInternalID(id, source: "Gmail thread id (conversation start)") { out.append(t) }
        for hop in ReceivedTrace.hops(rawSource: rawSource) {
            if let d = hop.date { out.append(ForensicTimestamp(source: "Received (\(hop.by.isEmpty ? "hop \(hop.index)" : hop.by))", date: d, raw: hop.raw)) }
        }
        for b in boundaries(rawSource) {
            if let t = gmailBoundary(b) { out.append(t) }
            else if let t = outlookBoundary(b) { out.append(t) }
            else if let t = epoch(in: b, source: "MIME boundary (Unix time)") { out.append(t) }
        }
        return out.sorted { $0.date < $1.date }
    }

    static func boundaries(_ raw: String) -> [String] {
        var out: [String] = []
        var search = raw.startIndex..<raw.endIndex
        while let r = raw.range(of: #"boundary="?([^";\r\n]+)"?"#, options: [.regularExpression, .caseInsensitive], range: search) {
            var b = String(raw[r]).replacingOccurrences(of: "boundary=", with: "", options: .caseInsensitive)
            b = b.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !out.contains(b) { out.append(b) }
            search = r.upperBound..<raw.endIndex
        }
        return out
    }
}

/// RFC 5322 dates with the variants seen in real mail.
public enum RFC5322Date {
    static let formats = ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z",
                          "EEE, d MMM yyyy HH:mm:ss zzz", "d MMM yyyy HH:mm:ss zzz", "EEE, d MMM yy HH:mm:ss Z"]
    public static func parse(_ s: String) -> Date? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let p = t.range(of: #"\s*\([^)]*\)\s*$"#, options: .regularExpression) { t.removeSubrange(p) }
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in formats {
            f.dateFormat = fmt
            if let d = f.date(from: t) { return d }
        }
        return nil
    }
}

// MARK: - F4 Received trace

public struct ReceivedHop: Sendable, Equatable {
    public var index: Int
    public var from: String
    public var by: String
    public var with: String
    public var date: Date?
    public var raw: String
    /// Seconds since the previous hop (nil when either date is missing).
    public var delay: TimeInterval?
}

public enum ReceivedTrace {
    /// Hops in travel order (the bottom Received header is the first hop).
    public static func hops(rawSource: String) -> [ReceivedHop] {
        let normalized = rawSource.replacingOccurrences(of: "\r\n", with: "\n")
        let headerPart = normalized.range(of: "\n\n").map { String(normalized[..<$0.lowerBound]) } ?? normalized
        var fields: [String] = []
        var current: String?
        for line in headerPart.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.first == " " || line.first == "\t" {
                current = (current ?? "") + " " + line.trimmingCharacters(in: .whitespaces)
            } else {
                if let c = current, c.lowercased().hasPrefix("received:") { fields.append(String(c.dropFirst(9)).trimmingCharacters(in: .whitespaces)) }
                current = String(line)
            }
        }
        if let c = current, c.lowercased().hasPrefix("received:") { fields.append(String(c.dropFirst(9)).trimmingCharacters(in: .whitespaces)) }
        var out: [ReceivedHop] = []
        for (i, f) in fields.reversed().enumerated() {
            func clause(_ k: String) -> String {
                guard let r = f.range(of: #"\b\#(k)\s+([^\s;()]+)"#, options: [.regularExpression, .caseInsensitive]) else { return "" }
                return String(f[r]).components(separatedBy: .whitespaces).dropFirst().joined(separator: " ")
            }
            let date = f.split(separator: ";").last.flatMap { RFC5322Date.parse(String($0)) }
            var hop = ReceivedHop(index: i + 1, from: clause("from"), by: clause("by"), with: clause("with"), date: date, raw: f)
            if let d = date, let prev = out.last?.date { hop.delay = d.timeIntervalSince(prev) }
            out.append(hop)
        }
        return out
    }
}

// MARK: - F2 Missing DKIM

public enum DKIMExpectations {
    /// Providers that sign all outgoing mail, with a conservative date from
    /// which every message should carry a signature.
    public static let providers: [(domains: [String], since: String)] = [
        (["gmail.com", "googlemail.com"], "2009-01-01"),
        (["yahoo.com", "ymail.com", "rocketmail.com"], "2009-01-01"),
        (["outlook.com", "hotmail.com", "live.com", "msn.com"], "2014-01-01"),
        (["icloud.com", "me.com", "mac.com"], "2014-01-01"),
        (["aol.com"], "2015-01-01"),
        (["protonmail.com", "proton.me"], "2016-01-01"),
        (["fastmail.com"], "2012-01-01"),
        (["gmx.com", "gmx.net", "gmx.de", "web.de"], "2016-01-01"),
        (["yandex.com", "yandex.ru"], "2012-01-01"),
        (["zoho.com"], "2012-01-01"),
    ]

    /// A reason string when the message should be signed but is not.
    public static func missingSignature(headers: [String: String], date: Date?) -> String? {
        guard headers.keys.first(where: { $0.lowercased() == "dkim-signature" }) == nil else { return nil }
        let from = (headers["From"] ?? "").lowercased()
        guard let at = from.range(of: #"@([a-z0-9.-]+)"#, options: .regularExpression) else { return nil }
        let domain = String(from[at].dropFirst())
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        for p in providers where p.domains.contains(domain) {
            guard let since = f.date(from: p.since), let date, date >= since else { return nil }
            return "From \(domain), dated \(f.string(from: date)), but no DKIM-Signature (\(domain) signs all mail since \(p.since))"
        }
        return nil
    }
}

// MARK: - F3 Offline DKIM

public enum DKIMResult: Sendable, Equatable {
    case pass(domain: String, selector: String)
    case fail(String)
    case noKey(domain: String, selector: String)
    case noSignature
    case unsupported(String)
}

/// Keys the examiner imported (`selector._domainkey.domain` → TXT record).
public struct DKIMKeyCache: Codable, Sendable, Equatable {
    public var records: [String: String] = [:]
    public init(records: [String: String] = [:]) { self.records = records }
    public func record(selector: String, domain: String) -> String? {
        records["\(selector)._domainkey.\(domain)".lowercased()]
    }
    /// Lines like `sel._domainkey.example.com  "v=DKIM1; k=rsa; p=MIIB…"`.
    public static func parse(_ text: String) -> DKIMKeyCache {
        var c = DKIMKeyCache()
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            let value = parts[1].replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespaces)
            c.records[name] = value
        }
        return c
    }
}

public enum DKIMVerifier {
    /// Every signature in the message is checked; the result is a pass when
    /// any one verifies, else the first signature's failure. `signatureHeader`
    /// "ARC-Message-Signature" checks the ARC message signatures the same way
    /// (RFC 8617 §4.1.2; the ARC-Seal chain is not checked).
    public static func verify(rawSource: String, keys: DKIMKeyCache,
                              signatureHeader: String = "DKIM-Signature") -> DKIMResult {
        let raw = rawSource.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        guard let split = raw.range(of: "\r\n\r\n") else { return .unsupported("no header/body separator") }
        let headerBlock = String(raw[..<split.lowerBound]) + "\r\n"
        let body = String(raw[split.upperBound...])
        let fields = unfoldFields(headerBlock)
        let sigs = fields.filter { $0.name.lowercased() == signatureHeader.lowercased() }
        guard !sigs.isEmpty else { return .noSignature }
        var first: DKIMResult?
        for sig in sigs {
            let r = verifyOne(sig, fields: fields, body: body, keys: keys)
            if case .pass = r { return r }
            if first == nil { first = r }
        }
        return first ?? .noSignature
    }

    static func verifyOne(_ sigField: Field, fields: [Field], body: String, keys: DKIMKeyCache) -> DKIMResult {
        guard let tags = strictTags(sigField.value) else { return .fail("the signature's tag list is malformed") }
        guard let d = tags["d"], let s = tags["s"], let b = tags["b"], let bh = tags["bh"], let h = tags["h"], !h.isEmpty else {
            return .fail("the signature is missing a required tag")
        }
        guard let alg = tags["a"]?.lowercased(), !alg.isEmpty else { return .fail("the signature names no algorithm") }
        if sigField.name.lowercased() == "arc-message-signature",
           h.lowercased().split(separator: ":").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "arc-seal" }) {
            return .fail("an ARC-Message-Signature may not sign ARC-Seal headers")
        }
        let canon = (tags["c"] ?? "simple/simple").lowercased().split(separator: "/").map(String.init)
        let hCanon = canon.first ?? "simple", bCanon = canon.count > 1 ? canon[1] : "simple"
        guard algorithms.contains(alg) else {
            return sigField.name.lowercased() == "dkim-signature" ? .unsupported("algorithm \(alg)") : .fail("unknown algorithm \(alg)")
        }
        guard let txt = keys.record(selector: s, domain: d) else { return .noKey(domain: d, selector: s) }
        let keyTags = parseTags(txt)
        guard let p = keyTags["p"], !p.isEmpty, let keyData = Data(base64Encoded: p.filter { !$0.isWhitespace }) else {
            return .fail("the key for \(s)._domainkey.\(d) is revoked or unreadable")
        }

        // Body hash.
        var cbody = bCanon == "relaxed" ? relaxedBody(body) : simpleBody(body)
        if let l = tags["l"], let n = Int(l), n < cbody.utf8.count { cbody = String(decoding: Array(cbody.utf8).prefix(n), as: UTF8.self) }
        let bodyHash = Data(SHA256.hash(data: Data(cbody.utf8))).base64EncodedString()
        guard bodyHash == bh.filter({ !$0.isWhitespace }) else { return .fail("body hash does not match: the body was changed after signing") }

        // Signed headers, bottom-up for repeated names.
        var used: [String: Int] = [:]
        var data = ""
        for name in h.split(separator: ":").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) {
            let matches = fields.filter { $0.name.lowercased() == name }
            let k = used[name, default: 0]
            used[name] = k + 1
            guard k < matches.count else { continue }
            let f = matches[matches.count - 1 - k]
            data += hCanon == "relaxed" ? relaxedHeader(f.name, f.value) : f.raw
        }
        let sigNoB = sigField.raw.replacingOccurrences(of: #"(\bb\s*=)[^;]*"#, with: "$1", options: .regularExpression)
        var sigLine = hCanon == "relaxed"
            ? relaxedHeader(sigField.name, String(sigNoB.drop(while: { $0 != ":" }).dropFirst()))
            : sigNoB
        if sigLine.hasSuffix("\r\n") { sigLine.removeLast() }   // "\r\n" is one Character
        data += sigLine
        guard let sig = Data(base64Encoded: b.filter { !$0.isWhitespace }) else { return .fail("signature is not base64") }
        if let why = keyProblem(alg: alg, keyData: keyData) { return .fail(why) }
        return verifySignature(alg: alg, keyData: keyData, message: Data(data.utf8), signature: sig)
            ? .pass(domain: d, selector: s) : .fail("signature does not verify: a signed header was changed")
    }

    /// RFC 8301: RSA keys shorter than 1024 bits must not be trusted.
    static func keyProblem(alg: String, keyData: Data) -> String? {
        guard alg == "rsa-sha256" else { return nil }
        guard let pkcs1 = rsaPublicKeyPKCS1(fromSPKI: keyData),
              let key = SecKeyCreateWithData(pkcs1 as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, nil) else {
            return "bad RSA key"
        }
        let bits = SecKeyGetBlockSize(key) * 8
        return bits < 1024 ? "the RSA key has \(bits) bits; at least 1024 are required (RFC 8301)" : nil
    }

    struct Field { var name: String; var value: String; var raw: String }

    /// Verifies `message` with the key published for `s`/`d` (rsa-sha256 or ed25519-sha256).
    static func verifySignature(alg: String, keyData: Data, message: Data, signature: Data) -> Bool {
        if alg == "ed25519-sha256" {
            guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { return false }
            return key.isValidSignature(signature, for: Data(SHA256.hash(data: message)))
        }
        guard let pkcs1 = rsaPublicKeyPKCS1(fromSPKI: keyData),
              let key = SecKeyCreateWithData(pkcs1 as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, nil) else {
            return false
        }
        return SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, signature as CFData, nil)
    }

    // MARK: ARC chain (RFC 8617)

    public enum ARCResult: Sendable, Equatable {
        case none
        case pass(instances: Int)
        case fail(instance: Int, why: String)
        case noKey(instance: Int, domain: String, selector: String)
    }

    /// RFC 8617 §5.2: every set 1…n present once; ARC-Seal 1 says cv=none, every
    /// later one cv=pass; each ARC-Seal verifies over the sets 1…i (relaxed,
    /// in the order AAR, AMS, AS, its own b= emptied); the newest ARC-Message-
    /// Signature verifies like DKIM.
    public static func verifyARCChain(rawSource: String, keys: DKIMKeyCache) -> ARCResult {
        let raw = rawSource.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        guard let split = raw.range(of: "\r\n\r\n") else { return .none }
        let fields = unfoldFields(String(raw[..<split.lowerBound]) + "\r\n")
        let body = String(raw[split.upperBound...])
        func instance(_ f: Field) -> Int? { parseTags(f.value)["i"].flatMap { Int($0) } }
        var sets: [Int: (aar: Field?, ams: Field?, seal: Field?)] = [:]
        for f in fields {
            let n = f.name.lowercased()
            guard ["arc-authentication-results", "arc-message-signature", "arc-seal"].contains(n) else { continue }
            // AAR's instance tag is "i=N;" at the start of its value.
            guard let i = instance(f) ?? f.value.range(of: #"i\s*=\s*(\d+)"#, options: .regularExpression)
                    .flatMap({ Int(f.value[$0].filter(\.isNumber)) }) else { return .fail(instance: 0, why: "an ARC header has no instance") }
            var set = sets[i] ?? (nil, nil, nil)
            switch n {
            case "arc-authentication-results": if set.aar != nil { return .fail(instance: i, why: "two ARC-Authentication-Results") }; set.aar = f
            case "arc-message-signature": if set.ams != nil { return .fail(instance: i, why: "two ARC-Message-Signatures") }; set.ams = f
            default: if set.seal != nil { return .fail(instance: i, why: "two ARC-Seals") }; set.seal = f
            }
            sets[i] = set
        }
        guard let n = sets.keys.max() else { return .none }
        guard n <= 50 else { return .fail(instance: n, why: "more than 50 ARC sets") }   // RFC 8617 §4.2.1
        for i in 1...n {
            guard let set = sets[i], set.aar != nil, set.ams != nil, set.seal != nil else {
                return .fail(instance: i, why: "ARC set \(i) is incomplete or missing")
            }
            let cv = parseTags(set.seal!.value)["cv"]?.lowercased() ?? ""
            if i == 1 && cv != "none" { return .fail(instance: 1, why: "the first ARC-Seal must say cv=none") }
            if i > 1 && cv != "pass" { return .fail(instance: i, why: "ARC-Seal \(i) says cv=\(cv)") }
        }
        // Newest message signature, checked like DKIM.
        switch verifyOne(sets[n]!.ams!, fields: fields, body: body, keys: keys) {
        case .pass: break
        case .noKey(let d, let s): return .noKey(instance: n, domain: d, selector: s)
        case .fail(let why): return .fail(instance: n, why: "ARC-Message-Signature: " + why)
        default: return .fail(instance: n, why: "ARC-Message-Signature cannot be checked")
        }
        // Every seal over the sets up to and including its own.
        for i in 1...n {
            let seal = sets[i]!.seal!
            guard let tags = strictTags(seal.value) else { return .fail(instance: i, why: "ARC-Seal tag list is malformed") }
            guard let d = tags["d"], let s = tags["s"], let b = tags["b"], tags["i"] != nil, tags["cv"] != nil,
                  let sig = Data(base64Encoded: b.filter { !$0.isWhitespace }) else {
                return .fail(instance: i, why: "ARC-Seal is missing a required tag")
            }
            if tags["h"] != nil { return .fail(instance: i, why: "an ARC-Seal may not carry h=") }
            guard let alg = tags["a"]?.lowercased(), algorithms.contains(alg) else {
                return .fail(instance: i, why: "ARC-Seal names no known algorithm")
            }
            guard let txt = keys.record(selector: s, domain: d) else { return .noKey(instance: i, domain: d, selector: s) }
            guard let p = parseTags(txt)["p"], !p.isEmpty, let keyData = Data(base64Encoded: p.filter { !$0.isWhitespace }) else {
                return .fail(instance: i, why: "the key for \(s)._domainkey.\(d) is revoked or unreadable")
            }
            var data = ""
            for j in 1...i {
                let set = sets[j]!
                data += relaxedHeader(set.aar!.name, set.aar!.value)
                data += relaxedHeader(set.ams!.name, set.ams!.value)
                if j < i {
                    data += relaxedHeader(set.seal!.name, set.seal!.value)
                } else {
                    let noB = seal.value.replacingOccurrences(of: #"(\bb\s*=)[^;]*"#, with: "$1", options: .regularExpression)
                    var line = relaxedHeader(seal.name, noB)
                    if line.hasSuffix("\r\n") { line.removeLast() }   // "\r\n" is one Character
                    data += line
                }
            }
            if let why = keyProblem(alg: alg, keyData: keyData) { return .fail(instance: i, why: why) }
            guard verifySignature(alg: alg, keyData: keyData, message: Data(data.utf8), signature: sig) else {
                return .fail(instance: i, why: "ARC-Seal \(i) does not verify: an earlier hop's headers were changed")
            }
        }
        return .pass(instances: n)
    }

    static func unfoldFields(_ block: String) -> [Field] {
        var out: [Field] = []
        var cur = ""
        for line in block.components(separatedBy: "\r\n") {
            if line.first == " " || line.first == "\t" { cur += "\r\n" + line; continue }
            if !cur.isEmpty, let c = cur.firstIndex(of: ":") {
                out.append(Field(name: String(cur[..<c]), value: String(cur[cur.index(after: c)...]), raw: cur + "\r\n"))
            }
            cur = line
        }
        return out
    }

    /// RFC 6376 §3.2 tag-list, strictly: names are case-sensitive, start with a
    /// letter and hold only letters, digits and "_"; no name twice; no empty
    /// element except one trailing ";". nil when the list is malformed.
    static func strictTags(_ s: String) -> [String: String]? {
        var parts = s.replacingOccurrences(of: "\r\n", with: "").components(separatedBy: ";")
        if let last = parts.last, last.trimmingCharacters(in: .whitespaces).isEmpty { parts.removeLast() }
        var out: [String: String] = [:]
        for part in parts {
            guard let eq = part.firstIndex(of: "=") else { return nil }
            let name = part[..<eq].trimmingCharacters(in: .whitespaces)
            guard let first = name.first, first.isASCII, first.isLetter,
                  name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }),
                  out[name] == nil else { return nil }
            out[name] = part[part.index(after: eq)...].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return out
    }

    static let algorithms: Set<String> = ["rsa-sha256", "ed25519-sha256"]

    static func parseTags(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        for part in s.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            out[kv[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] =
                kv[1].replacingOccurrences(of: "\r\n", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return out
    }

    static func relaxedHeader(_ name: String, _ value: String) -> String {
        let v = value.replacingOccurrences(of: "\r\n", with: "")
            .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return name.lowercased().trimmingCharacters(in: .whitespaces) + ":" + v + "\r\n"
    }

    static func simpleBody(_ body: String) -> String {
        var b = body
        while b.hasSuffix("\r\n\r\n") { b.removeLast() }   // "\r\n" is one Character
        if b.isEmpty || !b.hasSuffix("\r\n") { b += "\r\n" }
        return b
    }

    static func relaxedBody(_ body: String) -> String {
        var lines = body.components(separatedBy: "\r\n").map {
            $0.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
              .replacingOccurrences(of: #" +$"#, with: "", options: .regularExpression)
        }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        return lines.isEmpty ? "" : lines.joined(separator: "\r\n") + "\r\n"
    }

    /// SubjectPublicKeyInfo → PKCS#1 RSAPublicKey (what SecKey expects); a
    /// key that is already PKCS#1 is returned as is.
    static func rsaPublicKeyPKCS1(fromSPKI der: Data) -> Data? {
        let b = [UInt8](der)
        func length(_ i: inout Int) -> Int? {
            guard i < b.count else { return nil }
            let first = b[i]; i += 1
            if first < 0x80 { return Int(first) }
            let n = Int(first & 0x7F)
            guard n <= 4, i + n <= b.count else { return nil }
            var v = 0
            for _ in 0..<n { v = (v << 8) | Int(b[i]); i += 1 }
            return v
        }
        var i = 0
        guard b.first == 0x30 else { return nil }
        i += 1
        guard length(&i) != nil else { return nil }
        // PKCS#1 starts with INTEGER (modulus) right away.
        if i < b.count, b[i] == 0x02 { return der }
        guard i < b.count, b[i] == 0x30 else { return nil }   // AlgorithmIdentifier
        i += 1
        guard let algLen = length(&i) else { return nil }
        i += algLen
        guard i < b.count, b[i] == 0x03 else { return nil }   // BIT STRING
        i += 1
        guard let bitLen = length(&i), i < b.count else { return nil }
        i += 1                                                // unused-bits byte
        guard i + bitLen - 1 <= b.count else { return nil }
        return Data(b[i..<(i + bitLen - 1)])
    }
}

// MARK: - F4 Removed-attachment and tampering signals

public enum TamperingSignals {
    /// Reasons, each a short sentence; empty = none found.
    public static func find(headers: [String: String], rawSource: String, attachmentCount: Int) -> [String] {
        var out: [String] = []
        let lower = rawSource.lowercased()
        if lower.contains("text/x-moz-deleted") || lower.contains("x-mozilla-altered: attachmentdeleted") {
            out.append("Thunderbird removed an attachment from this message")
        }
        if lower.contains("x-mozilla-external-attachment-url") {
            out.append("An attachment was detached to an external file (Thunderbird)")
        }
        if (headers["X-MS-Has-Attach"] ?? "").lowercased() == "yes", attachmentCount == 0 {
            out.append("Outlook marked the message as having attachments, but none are present")
        }
        let hops = ReceivedTrace.hops(rawSource: rawSource)
        if hops.contains(where: { ($0.delay ?? 0) < -300 }) {
            out.append("A Received hop is dated more than 5 minutes before the previous one")
        }
        if let date = headers["Date"].flatMap(RFC5322Date.parse), let first = hops.first?.date,
           abs(first.timeIntervalSince(date)) > 48 * 3600 {
            out.append("The Date header is more than 48 hours from the first Received hop")
        }
        if let ti = headers["Thread-Index"], let start = HiddenTimestamps.threadIndex(ti).last?.date,
           let date = headers["Date"].flatMap(RFC5322Date.parse), start.timeIntervalSince(date) > 3600 {
            out.append("The Thread-Index time is later than the Date header")
        }
        return out
    }
}
