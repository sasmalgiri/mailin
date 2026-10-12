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

    /// Every timestamp the message carries, oldest first.
    public static func all(headers: [String: String], rawSource: String) -> [ForensicTimestamp] {
        var out: [ForensicTimestamp] = []
        if let d = headers["Date"], let date = RFC5322Date.parse(d) {
            out.append(ForensicTimestamp(source: "Date header", date: date, raw: d))
        }
        if let ti = headers["Thread-Index"] { out += threadIndex(ti) }
        if let mid = headers["Message-ID"], let t = epoch(in: mid, source: "Message-ID (Unix time)") { out.append(t) }
        for hop in ReceivedTrace.hops(rawSource: rawSource) {
            if let d = hop.date { out.append(ForensicTimestamp(source: "Received (\(hop.by.isEmpty ? "hop \(hop.index)" : hop.by))", date: d, raw: hop.raw)) }
        }
        for b in boundaries(rawSource) {
            if let t = outlookBoundary(b) { out.append(t) } else if let t = epoch(in: b, source: "MIME boundary (Unix time)") { out.append(t) }
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
    public static func verify(rawSource: String, keys: DKIMKeyCache) -> DKIMResult {
        let raw = rawSource.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        guard let split = raw.range(of: "\r\n\r\n") else { return .unsupported("no header/body separator") }
        let headerBlock = String(raw[..<split.lowerBound]) + "\r\n"
        let body = String(raw[split.upperBound...])
        let fields = unfoldFields(headerBlock)
        guard let sigField = fields.first(where: { $0.name.lowercased() == "dkim-signature" }) else { return .noSignature }
        let tags = parseTags(sigField.value)
        guard let d = tags["d"], let s = tags["s"], let b = tags["b"], let bh = tags["bh"], let h = tags["h"] else {
            return .fail("DKIM-Signature is missing a required tag")
        }
        let alg = (tags["a"] ?? "rsa-sha256").lowercased()
        let canon = (tags["c"] ?? "simple/simple").lowercased().split(separator: "/").map(String.init)
        let hCanon = canon.first ?? "simple", bCanon = canon.count > 1 ? canon[1] : "simple"
        guard alg == "rsa-sha256" || alg == "ed25519-sha256" else { return .unsupported("algorithm \(alg)") }
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
        if sigLine.hasSuffix("\r\n") { sigLine.removeLast(2) }
        data += sigLine
        guard let sig = Data(base64Encoded: b.filter { !$0.isWhitespace }) else { return .fail("signature is not base64") }
        let message = Data(data.utf8)

        if alg == "ed25519-sha256" {
            guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { return .fail("bad ed25519 key") }
            let digest = Data(SHA256.hash(data: message))
            return key.isValidSignature(sig, for: digest) ? .pass(domain: d, selector: s) : .fail("signature does not verify: a signed header was changed")
        }
        guard let pkcs1 = rsaPublicKeyPKCS1(fromSPKI: keyData),
              let key = SecKeyCreateWithData(pkcs1 as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, nil) else {
            return .fail("bad RSA key")
        }
        let ok = SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, sig as CFData, nil)
        return ok ? .pass(domain: d, selector: s) : .fail("signature does not verify: a signed header was changed")
    }

    struct Field { var name: String; var value: String; var raw: String }

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
        while b.hasSuffix("\r\n\r\n") { b.removeLast(2) }
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
