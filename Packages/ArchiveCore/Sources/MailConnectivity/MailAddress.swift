//
//  MailAddress.swift
//  MailConnectivity
//
//  Plan v4 V4-09 (§3 A13, §6 "Drafts, identities and reading"): a real
//  RFC 5322 §3.4 address parser. The old compose sheet split recipient
//  fields on commas, so `"Doe, Jane" <jane@example.com>` became two broken
//  recipients. This parser understands quoted display names (with commas and
//  escaped quotes), comments, groups (`Team: a@x, b@y;`), angle and bare
//  addresses, obsolete routes and phrases, RFC 2047 encoded-word display
//  names, internationalised domains (IDNA A-labels via RFC 3492 Punycode) and
//  internationalised local parts (RFC 6532 — such a message needs SMTPUTF8).
//
//  Header injection: any control character (C0 including CR/LF, DEL, C1,
//  U+2028/U+2029) in user input is refused, never stripped — a recipient
//  field cannot smuggle a second header or a Bcc line.
//

import Foundation

public struct MailAddress: Codable, Sendable, Hashable, CustomStringConvertible {
    /// Decoded display name, nil when none was given.
    public var displayName: String?
    /// The local part, unquoted (`"john smith"` is stored as `john smith`).
    public var localPart: String
    /// The domain as written (Unicode U-labels allowed; a domain literal keeps its brackets).
    public var domain: String

    public init(displayName: String? = nil, localPart: String, domain: String) {
        let trimmed = displayName?.trimmingCharacters(in: .whitespaces)
        self.displayName = (trimmed?.isEmpty ?? true) ? nil : trimmed
        self.localPart = localPart
        self.domain = domain
    }

    /// Parses exactly one mailbox (not a group, not a list).
    public init(parsing text: String) throws {
        let list = try MailAddressParser.parseList(text)
        guard list.count == 1 else { throw MailAddressError.notSingleAddress(text) }
        self = list[0]
    }

    /// `local@domain` with the local part quoted when it is not a dot-atom (Unicode form).
    public var addrSpec: String { "\(MailAddressParser.quotedLocalPartIfNeeded(localPart))@\(domain)" }

    /// The address with an ASCII (A-label) domain. The local part stays as is;
    /// a non-ASCII local part needs SMTPUTF8 (`requiresSMTPUTF8`).
    public func asciiAddrSpec() throws -> String {
        "\(MailAddressParser.quotedLocalPartIfNeeded(localPart))@\(try MailAddressParser.asciiDomain(domain))"
    }

    /// RFC 6532: a non-ASCII local part can only travel over SMTPUTF8 / a UTF-8 header.
    public var requiresSMTPUTF8: Bool { !localPart.unicodeScalars.allSatisfy(\.isASCII) }

    /// Comparison key for de-duplication and self-alias matching: the local
    /// part case-folded (every mainstream provider treats it so) and the
    /// domain as its lowercased A-label, so `Bob@BÜCHER.example` and
    /// `bob@xn--bcher-kva.example` are the same mailbox.
    public var normalizedKey: String {
        let domainKey = (try? MailAddressParser.asciiDomain(domain)) ?? domain.lowercased()
        return "\(localPart.precomposedStringWithCanonicalMapping.lowercased())@\(domainKey.lowercased())"
    }

    public var description: String {
        if let displayName { return "\(displayName) <\(addrSpec)>" }
        return addrSpec
    }

    /// Hash/equality on the mailbox only would hide display-name edits, so
    /// equality is field-wise; use `normalizedKey` to compare mailboxes.
}

public enum MailAddressError: LocalizedError, Equatable {
    case controlCharacter(field: String)
    case empty
    case malformed(String)
    case notSingleAddress(String)
    case invalidDomain(String)

    public var errorDescription: String? {
        switch self {
        case .controlCharacter(let field): return "The \(field) contains a line break or control character, which is not allowed."
        case .empty: return "No address was given."
        case .malformed(let text): return "“\(text)” is not a valid email address."
        case .notSingleAddress(let text): return "“\(text)” must be exactly one email address."
        case .invalidDomain(let domain): return "“\(domain)” is not a valid mail domain."
        }
    }
}

/// One entry of an address list: a mailbox or a named group of mailboxes.
public enum AddressListEntry: Sendable, Equatable {
    case mailbox(MailAddress)
    case group(name: String, members: [MailAddress])
}

public enum MailAddressParser {
    public enum InputKind: Sendable {
        /// Typed by the user: any control character, CR or LF is refused.
        case userInput
        /// A header value from an archived message: RFC 5322 folding (CRLF + WSP)
        /// is unfolded first; any other control character is still refused.
        case header
    }

    /// Every mailbox in the list, groups flattened, in order.
    public static func parseList(_ text: String, kind: InputKind = .userInput) throws -> [MailAddress] {
        try parseEntries(text, kind: kind).flatMap { entry -> [MailAddress] in
            switch entry {
            case .mailbox(let m): return [m]
            case .group(_, let members): return members
            }
        }
    }

    public static func parseEntries(_ text: String, kind: InputKind = .userInput) throws -> [AddressListEntry] {
        var input = text
        if kind == .header {
            input = input.replacingOccurrences(of: "\r\n ", with: " ").replacingOccurrences(of: "\r\n\t", with: " ")
                .replacingOccurrences(of: "\n ", with: " ").replacingOccurrences(of: "\n\t", with: " ")
        }
        try refuseControlCharacters(input, field: "address")
        var parser = Parser(tokens: try tokenize(input))
        return try parser.addressList()
    }

    /// Refuses C0 controls (TAB allowed as whitespace), DEL, C1 controls and
    /// the Unicode line/paragraph separators.
    public static func refuseControlCharacters(_ text: String, field: String, allowTab: Bool = true) throws {
        for s in text.unicodeScalars {
            let v = s.value
            if v == 0x09 && allowTab { continue }
            if v < 0x20 || v == 0x7F || (0x80...0x9F).contains(v) || v == 0x2028 || v == 0x2029 {
                throw MailAddressError.controlCharacter(field: field)
            }
        }
    }

    /// Drops later duplicates (by `normalizedKey`), keeping the first spelling.
    public static func deduplicated(_ list: [MailAddress], excluding: Set<String> = []) -> [MailAddress] {
        var seen = excluding
        return list.filter { seen.insert($0.normalizedKey).inserted }
    }

    // MARK: Tokens

    enum Token: Equatable {
        case atom(String)          // atext run (Unicode allowed, RFC 6532)
        case quoted(String)        // quoted-string content, unescaped
        case comment(String)
        case domainLiteral(String) // including brackets
        case special(Character)    // < > @ , ; : .
    }

    static let specials: Set<Character> = ["<", ">", "@", ",", ";", ":", "."]

    static func tokenize(_ s: String) throws -> [Token] {
        var tokens: [Token] = []
        let chars = Array(s)
        var i = 0
        func malformed() -> MailAddressError { .malformed(s) }
        while i < chars.count {
            let c = chars[i]
            if c == " " || c == "\t" { i += 1; continue }
            if c == "\"" {
                var value = ""
                i += 1
                var closed = false
                while i < chars.count {
                    let d = chars[i]
                    if d == "\\" { guard i + 1 < chars.count else { throw malformed() }; value.append(chars[i + 1]); i += 2; continue }
                    if d == "\"" { closed = true; i += 1; break }
                    value.append(d); i += 1
                }
                guard closed else { throw malformed() }
                tokens.append(.quoted(value))
            } else if c == "(" {
                var depth = 1, value = ""
                i += 1
                while i < chars.count, depth > 0 {
                    let d = chars[i]
                    if d == "\\" { guard i + 1 < chars.count else { throw malformed() }; value.append(chars[i + 1]); i += 2; continue }
                    if d == "(" { depth += 1 } else if d == ")" { depth -= 1; if depth == 0 { i += 1; break } }
                    value.append(d); i += 1
                }
                guard depth == 0 else { throw malformed() }
                tokens.append(.comment(value))
            } else if c == "[" {
                var value = "["
                i += 1
                var closed = false
                while i < chars.count {
                    let d = chars[i]
                    if d == "\\" { guard i + 1 < chars.count else { throw malformed() }; value.append(chars[i + 1]); i += 2; continue }
                    value.append(d); i += 1
                    if d == "]" { closed = true; break }
                    if d == "[" { throw malformed() }
                }
                guard closed else { throw malformed() }
                tokens.append(.domainLiteral(value))
            } else if specials.contains(c) {
                tokens.append(.special(c)); i += 1
            } else if c == ")" || c == "]" || c == "\\" {
                throw malformed()
            } else {
                var value = ""
                while i < chars.count {
                    let d = chars[i]
                    if d == " " || d == "\t" || d == "\"" || d == "(" || d == ")" || d == "[" || d == "]" || d == "\\" || specials.contains(d) { break }
                    value.append(d); i += 1
                }
                tokens.append(.atom(value))
            }
        }
        return tokens
    }

    struct Parser {
        var tokens: [Token]
        var pos = 0
        init(tokens: [Token]) { self.tokens = tokens }

        var source: String {
            tokens.map { t -> String in
                switch t {
                case .atom(let a): return a
                case .quoted(let q): return "\"\(q)\""
                case .comment(let c): return "(\(c))"
                case .domainLiteral(let d): return d
                case .special(let s): return String(s)
                }
            }.joined(separator: " ")
        }

        func malformed() -> MailAddressError { .malformed(source) }

        mutating func skipComments() -> [String] {
            var comments: [String] = []
            while pos < tokens.count, case .comment(let c) = tokens[pos] { comments.append(c); pos += 1 }
            return comments
        }

        func peekSpecial() -> Character? {
            guard pos < tokens.count, case .special(let c) = tokens[pos] else { return nil }
            return c
        }

        mutating func addressList() throws -> [AddressListEntry] {
            var out: [AddressListEntry] = []
            while true {
                _ = skipComments()
                if pos >= tokens.count { break }
                if peekSpecial() == "," { pos += 1; continue }   // obs-addr-list: empty elements
                out.append(try address())
                _ = skipComments()
                if pos >= tokens.count { break }
                guard peekSpecial() == "," else { throw malformed() }
                pos += 1
            }
            guard !out.isEmpty else { throw MailAddressError.empty }
            return out
        }

        /// Words of a phrase (atoms, quoted strings, obs-phrase dots) up to the next special.
        mutating func phrase() -> (words: [Token], comments: [String]) {
            var words: [Token] = [], comments: [String] = []
            while pos < tokens.count {
                switch tokens[pos] {
                case .atom, .quoted: words.append(tokens[pos]); pos += 1
                case .comment(let c): comments.append(c); pos += 1
                case .special("."): words.append(tokens[pos]); pos += 1
                default: return (words, comments)
                }
            }
            return (words, comments)
        }

        static func displayText(_ words: [Token]) -> String {
            var out = ""
            for w in words {
                switch w {
                case .special("."): out += "."
                case .atom(let a): out += (out.isEmpty ? "" : " ") + a
                case .quoted(let q): out += (out.isEmpty ? "" : " ") + q
                default: break
                }
            }
            return EncodedWord.decode(out).trimmingCharacters(in: .whitespaces)
        }

        mutating func address() throws -> AddressListEntry {
            let start = pos
            let (words, _) = phrase()
            switch peekSpecial() {
            case "<":
                return .mailbox(try angleAddress(displayName: words.isEmpty ? nil : Self.displayText(words)))
            case ":":
                guard !words.isEmpty else { throw malformed() }
                pos += 1
                var members: [MailAddress] = []
                while true {
                    _ = skipComments()
                    if peekSpecial() == ";" { pos += 1; break }
                    if peekSpecial() == "," { pos += 1; continue }
                    guard pos < tokens.count else { throw malformed() }   // unterminated group
                    let entry = try address()
                    guard case .mailbox(let m) = entry else { throw malformed() }   // no nested groups
                    members.append(m)
                }
                return .group(name: Self.displayText(words), members: members)
            case "@":
                pos = start
                let spec = try addrSpec()
                let trailing = skipComments()
                let name = trailing.last.map { EncodedWord.decode($0) }
                return .mailbox(MailAddress(displayName: name, localPart: spec.local, domain: spec.domain))
            default:
                throw malformed()   // a bare name or word with no address
            }
        }

        mutating func angleAddress(displayName: String?) throws -> MailAddress {
            guard peekSpecial() == "<" else { throw malformed() }
            pos += 1
            _ = skipComments()
            // obs-route: "@a.example,@b.example:" — read and discarded.
            if peekSpecial() == "@" {
                while peekSpecial() == "@" || peekSpecial() == "," {
                    pos += 1
                    _ = skipComments()
                    if pos < tokens.count, case .atom = tokens[pos] { _ = try domain() }
                    _ = skipComments()
                }
                guard peekSpecial() == ":" else { throw malformed() }
                pos += 1
            }
            let spec = try addrSpec()
            _ = skipComments()
            guard peekSpecial() == ">" else { throw malformed() }
            pos += 1
            _ = skipComments()
            return MailAddress(displayName: displayName, localPart: spec.local, domain: spec.domain)
        }

        mutating func addrSpec() throws -> (local: String, domain: String) {
            var local = ""
            var expectWord = true
            while pos < tokens.count {
                switch tokens[pos] {
                case .comment: pos += 1
                case .atom(let a) where expectWord: local += a; expectWord = false; pos += 1
                case .quoted(let q) where expectWord: local += q; expectWord = false; pos += 1
                case .special(".") where !expectWord: local += "."; expectWord = true; pos += 1
                case .special("@"):
                    guard !local.isEmpty, !expectWord else { throw malformed() }
                    pos += 1
                    return (local, try domain())
                default: throw malformed()
                }
            }
            throw malformed()
        }

        mutating func domain() throws -> String {
            _ = skipComments()
            guard pos < tokens.count else { throw malformed() }
            if case .domainLiteral(let d) = tokens[pos] { pos += 1; return d }
            var out = ""
            var expectLabel = true
            while pos < tokens.count {
                switch tokens[pos] {
                case .atom(let a) where expectLabel: out += a; expectLabel = false; pos += 1
                case .special(".") where !expectLabel: out += "."; expectLabel = true; pos += 1
                // A comment after a complete domain ends it (and may be the display name).
                case .comment where expectLabel: pos += 1
                default:
                    guard !out.isEmpty, !expectLabel else { throw malformed() }
                    _ = try MailAddressParser.asciiDomain(out)
                    return out
                }
            }
            guard !out.isEmpty, !expectLabel else { throw malformed() }
            _ = try MailAddressParser.asciiDomain(out)
            return out
        }
    }

    // MARK: Local part

    static let atext: Set<Character> = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-/=?^_`{|}~")

    static func isDotAtom(_ s: String) -> Bool {
        guard !s.isEmpty, !s.hasPrefix("."), !s.hasSuffix("."), !s.contains("..") else { return false }
        return s.allSatisfy { $0 == "." || atext.contains($0) || !$0.isASCII }
    }

    static func quotedLocalPartIfNeeded(_ local: String) -> String {
        if isDotAtom(local) { return local }
        return "\"" + local.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: IDNA

    /// The domain as lowercase A-labels (`bücher.example` → `xn--bcher-kva.example`).
    /// Domain literals are returned unchanged.
    public static func asciiDomain(_ domain: String) throws -> String {
        if domain.hasPrefix("[") { return domain }
        let unified = domain.replacingOccurrences(of: "\u{3002}", with: ".").replacingOccurrences(of: "\u{FF0E}", with: ".")
            .replacingOccurrences(of: "\u{FF61}", with: ".")
        var labels: [String] = []
        for raw in unified.split(separator: ".", omittingEmptySubsequences: false) {
            let label = String(raw).precomposedStringWithCanonicalMapping.lowercased()
            guard !label.isEmpty else { throw MailAddressError.invalidDomain(domain) }
            let ascii: String
            if label.unicodeScalars.allSatisfy(\.isASCII) {
                ascii = label
            } else {
                guard let encoded = Punycode.encode(label) else { throw MailAddressError.invalidDomain(domain) }
                ascii = "xn--" + encoded
            }
            guard ascii.count <= 63, ascii.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }),
                  !ascii.hasPrefix("-"), !ascii.hasSuffix("-") else { throw MailAddressError.invalidDomain(domain) }
            labels.append(ascii)
        }
        let out = labels.joined(separator: ".")
        guard out.utf8.count <= 253 else { throw MailAddressError.invalidDomain(domain) }
        return out
    }
}

/// RFC 3492 Punycode encoder (the IDNA A-label body).
enum Punycode {
    static let base: UInt64 = 36, tmin: UInt64 = 1, tmax: UInt64 = 26, skew: UInt64 = 38, damp: UInt64 = 700

    static func encode(_ input: String) -> String? {
        let codes = input.unicodeScalars.map { UInt64($0.value) }
        var output = String(input.unicodeScalars.filter(\.isASCII).map(Character.init))
        let b = output.count
        var h = b
        if b > 0 { output.append("-") }
        var n: UInt64 = 128, delta: UInt64 = 0, bias: UInt64 = 72
        while h < codes.count {
            guard let m = codes.filter({ $0 >= n }).min() else { return nil }
            delta += (m - n) * UInt64(h + 1)
            guard delta < UInt64(UInt32.max) else { return nil }
            n = m
            for c in codes {
                if c < n { delta += 1 }
                if c == n {
                    var q = delta
                    var k = base
                    while true {
                        let t = k <= bias ? tmin : (k >= bias + tmax ? tmax : k - bias)
                        if q < t { break }
                        output.append(digit(t + (q - t) % (base - t)))
                        q = (q - t) / (base - t)
                        k += base
                    }
                    output.append(digit(q))
                    bias = adapt(delta, UInt64(h + 1), h == b)
                    delta = 0
                    h += 1
                }
            }
            delta += 1
            n += 1
        }
        return output
    }

    static func digit(_ d: UInt64) -> Character {
        Character(Unicode.Scalar(UInt8(d < 26 ? 97 + d : 22 + d)))
    }

    static func adapt(_ delta: UInt64, _ numPoints: UInt64, _ first: Bool) -> UInt64 {
        var delta = first ? delta / damp : delta / 2
        delta += delta / numPoints
        var k: UInt64 = 0
        while delta > ((base - tmin) * tmax) / 2 { delta /= base - tmin; k += base }
        return k + (base - tmin + 1) * delta / (delta + skew)
    }
}

/// RFC 2047 encoded words.
public enum EncodedWord {
    private static let regex = try? NSRegularExpression(pattern: #"=\?([^?\s]+)\?([bBqQ])\?([^?\s]*)\?="#)

    /// Decodes every encoded word; whitespace between two adjacent encoded words is dropped (RFC 2047 §6.2).
    public static func decode(_ text: String) -> String {
        guard text.contains("=?"), let regex else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var out = ""
        var last = 0
        for (i, m) in matches.enumerated() {
            let gap = ns.substring(with: NSRange(location: last, length: m.range.location - last))
            if !(i > 0 && gap.trimmingCharacters(in: .whitespaces).isEmpty) { out += gap }
            let charset = ns.substring(with: m.range(at: 1)).split(separator: "*").first.map(String.init) ?? "utf-8"
            let mode = ns.substring(with: m.range(at: 2)).uppercased()
            let payload = ns.substring(with: m.range(at: 3))
            if let decoded = decodeWord(charset: charset, mode: mode, payload: payload) {
                out += decoded
            } else {
                out += ns.substring(with: m.range)
            }
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    static func decodeWord(charset: String, mode: String, payload: String) -> String? {
        let data: Data?
        if mode == "B" {
            var p = payload
            while p.count % 4 != 0 { p += "=" }
            data = Data(base64Encoded: p)
        } else {
            var bytes: [UInt8] = []
            let u = Array(payload.utf8)
            var i = 0
            while i < u.count {
                if u[i] == UInt8(ascii: "_") { bytes.append(0x20); i += 1 } else if u[i] == UInt8(ascii: "="), i + 2 < u.count,
                    let v = UInt8(String(decoding: u[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) {
                    bytes.append(v); i += 3
                } else { bytes.append(u[i]); i += 1 }
            }
            data = Data(bytes)
        }
        guard let data else { return nil }
        let cf = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
        let encoding: String.Encoding = cf == kCFStringEncodingInvalidId ? .utf8 : String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        return String(data: data, encoding: encoding) ?? String(data: data, encoding: .isoLatin1)
    }

    /// `=?UTF-8?B?…?=` words, each at most 68 characters (a header name and the word fit in 78), never splitting a
    /// character; separated by a single space (which the caller may fold).
    public static func encode(_ text: String) -> [String] {
        var words: [String] = []
        var chunk = Data()
        for ch in text {
            let bytes = Data(String(ch).utf8)
            if chunk.count + bytes.count > 42, !chunk.isEmpty {
                words.append("=?UTF-8?B?\(chunk.base64EncodedString())?=")
                chunk = Data()
            }
            chunk.append(bytes)
        }
        if !chunk.isEmpty { words.append("=?UTF-8?B?\(chunk.base64EncodedString())?=") }
        return words
    }
}
