//
//  IMAPResponseReader.swift
//  MailConnectivity
//
//  Plan v4 V4-07 (§3 A07, §9 T13): the IMAP4rev1 / IMAP4rev2 response
//  reader, over RAW BYTES.
//
//  Framing is decided by bytes only:
//   • a response is text up to CRLF, EXCEPT that a line ending in a literal
//     marker `{n}` / `{n+}` / `~{n}` is followed by EXACTLY n bytes of literal
//     data, after which the same response continues;
//   • literal bytes are counted, never scanned: a message body containing
//     "a1 OK", "* BYE", "\r\n.\r\n" or "{5}\r\n" cannot end a response;
//   • network chunks may split anything anywhere (a CRLF, a marker, a UTF-8
//     sequence): nothing is converted to a String before its response is
//     complete, and message literals are never converted at all.
//
//  A literal the caller routes (the BODY[] of a UID FETCH) is streamed out
//  chunk by chunk as it arrives and never held whole in memory.
//
//  The old `maxmailin/IMAPClient.swift` parser (String-based, line-counting,
//  sequence-number FETCH) is NOT reused.
//

import Foundation

// MARK: - Values

/// One parsed IMAP value (RFC 9051 §4).
public indirect enum IMAPValue: Sendable, Equatable {
    /// An atom (or a number, or a FETCH item name such as `BODY[]<0>`).
    case atom(String)
    /// A quoted string or a buffered literal: the exact bytes.
    case string([UInt8])
    case nilValue
    case list([IMAPValue])
    /// A literal that was streamed to a sink: only its length is kept.
    case streamed(Int64)

    public var atomText: String? { if case .atom(let a) = self { return a }; return nil }
    public var number: UInt64? { atomText.flatMap { UInt64($0) } }
    public var list: [IMAPValue]? { if case .list(let l) = self { return l }; return nil }

    /// Bytes of an astring / nstring (atoms count as their ASCII bytes).
    public var bytes: [UInt8]? {
        switch self {
        case .string(let b): return b
        case .atom(let a): return Array(a.utf8)
        default: return nil
        }
    }

    /// Text of an astring decoded as UTF-8 (for protocol text, never for mail content).
    public var text: String? { bytes.map { String(decoding: $0, as: UTF8.self) } }
}

/// `OK` / `NO` / `BAD` / `BYE` / `PREAUTH`.
public enum IMAPStatus: String, Sendable, Equatable {
    case ok = "OK", no = "NO", bad = "BAD", bye = "BYE", preauth = "PREAUTH"
}

/// A bracketed response code: `[UIDVALIDITY 3857529045]`, `[READ-ONLY]` …
public struct IMAPResponseCode: Sendable, Equatable {
    public var name: String
    /// The raw argument text after the name (may be empty).
    public var argument: String
    public var number: UInt64? { UInt64(argument.trimmingCharacters(in: .whitespaces)) }
}

public struct IMAPStatusResponse: Sendable, Equatable {
    public var status: IMAPStatus
    public var code: IMAPResponseCode?
    public var text: String
}

public enum IMAPResponse: Sendable, Equatable {
    /// `+ text` — the server waits for more client data.
    case continuation(String)
    /// `tag OK|NO|BAD …` — completion of the tagged command.
    case tagged(tag: String, IMAPStatusResponse)
    /// `* OK|NO|BAD|BYE|PREAUTH …`
    case untaggedStatus(IMAPStatusResponse)
    /// `* <n> EXISTS|RECENT|EXPUNGE`
    case numbered(UInt64, String)
    /// `* <n> FETCH (…)` — attribute name/value pairs in server order.
    case fetch(sequence: UInt64, [(name: String, value: IMAPValue)])
    /// `* CAPABILITY …`, `* LIST …`, `* SEARCH …` …: keyword + values.
    case data(String, [IMAPValue])

    public static func == (a: IMAPResponse, b: IMAPResponse) -> Bool {
        switch (a, b) {
        case (.continuation(let x), .continuation(let y)): return x == y
        case (.tagged(let t1, let s1), .tagged(let t2, let s2)): return t1 == t2 && s1 == s2
        case (.untaggedStatus(let x), .untaggedStatus(let y)): return x == y
        case (.numbered(let n1, let k1), .numbered(let n2, let k2)): return n1 == n2 && k1 == k2
        case (.fetch(let s1, let a1), .fetch(let s2, let a2)):
            return s1 == s2 && a1.count == a2.count && zip(a1, a2).allSatisfy { $0.name == $1.name && $0.value == $1.value }
        case (.data(let k1, let v1), .data(let k2, let v2)): return k1 == k2 && v1 == v2
        default: return false
        }
    }
}

public enum IMAPProtocolError: Error, Sendable, Equatable, LocalizedError {
    case malformed(String)
    case literalTooLarge(String)
    public var errorDescription: String? {
        switch self {
        case .malformed(let why): return "The mail server sent a response mailin cannot read: \(why)."
        case .literalTooLarge(let n): return "The mail server announced a literal of \(n) bytes, which is not a valid size."
        }
    }
}

// MARK: - Framing

/// One complete response as framed bytes: text segments and literals in order.
public struct IMAPRawResponse: Sendable, Equatable {
    public enum Segment: Sendable, Equatable {
        case text([UInt8])
        case literal([UInt8])
        case streamed(Int64)
    }
    public var segments: [Segment]
}

/// Where a routed literal's bytes go, chunk by chunk.
public typealias IMAPLiteralSink = @Sendable (Data) throws -> Void

/// Incremental framer: feed it network chunks of any size; it returns every
/// response completed by those bytes. Not thread-safe (one per connection).
public final class IMAPResponseFramer {
    /// Decides, from the text of the current response so far (ending just
    /// before the literal marker), whether a literal is streamed. nil = buffered.
    public var literalRouter: ((_ precedingText: [UInt8], _ length: Int64) -> IMAPLiteralSink?)?

    private var segments: [IMAPRawResponse.Segment] = []
    private var line: [UInt8] = []
    private var literalRemaining: Int64 = 0
    private var literalBuffer: [UInt8] = []
    private var literalSink: IMAPLiteralSink?
    private var inLiteral = false

    public init() {}

    /// True while no partial response is held.
    public var isIdle: Bool { segments.isEmpty && line.isEmpty && !inLiteral }

    public func feed(_ data: Data) throws -> [IMAPRawResponse] {
        var out: [IMAPRawResponse] = []
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var i = 0
            let n = bytes.count
            while i < n {
                if inLiteral {
                    let take = Int(min(Int64(n - i), literalRemaining))
                    let slice = UnsafeBufferPointer(rebasing: bytes[i..<(i + take)])
                    if let sink = literalSink {
                        try sink(Data(buffer: slice))
                    } else {
                        literalBuffer.append(contentsOf: slice)
                    }
                    literalRemaining -= Int64(take)
                    i += take
                    if literalRemaining == 0 { endLiteral() }
                    continue
                }
                // Text: scan to LF.
                var j = i
                while j < n && bytes[j] != 0x0A { j += 1 }
                line.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[i..<j]))
                if j == n { i = n; break }
                i = j + 1                       // past LF
                if line.last == 0x0D { line.removeLast() }
                if let length = try Self.literalMarker(&line) {
                    segments.append(.text(line))
                    let preceding = line
                    line = []
                    beginLiteral(length: length, preceding: preceding)
                    if literalRemaining == 0 { endLiteral() }
                } else {
                    segments.append(.text(line))
                    line = []
                    out.append(IMAPRawResponse(segments: segments))
                    segments = []
                }
            }
        }
        return out
    }

    private func beginLiteral(length: Int64, preceding: [UInt8]) {
        inLiteral = true
        literalRemaining = length
        literalBuffer = []
        literalSink = literalRouter?(precedingText(preceding), length)
        if literalSink != nil {
            segments.append(.streamed(length))
        }
    }

    private func precedingText(_ last: [UInt8]) -> [UInt8] {
        var all: [UInt8] = []
        for case .text(let t) in segments.dropLast() { all += t }
        return all + last
    }

    private func endLiteral() {
        if literalSink == nil { segments.append(.literal(literalBuffer)) }
        literalBuffer = []
        literalSink = nil
        inLiteral = false
    }

    /// Strips a trailing `{n}`, `{n+}`, `{n-}` or `~{n}` from `line` and returns n.
    static func literalMarker(_ line: inout [UInt8]) throws -> Int64? {
        guard line.last == UInt8(ascii: "}") else { return nil }
        var k = line.count - 2
        var plus = false
        if k >= 0, line[k] == UInt8(ascii: "+") || line[k] == UInt8(ascii: "-") { plus = true; k -= 1 }
        let digitsEnd = k
        while k >= 0, line[k] >= 0x30, line[k] <= 0x39 { k -= 1 }
        guard k >= 0, line[k] == UInt8(ascii: "{"), k < digitsEnd else { return nil }
        _ = plus
        let digits = line[(k + 1)...digitsEnd]
        guard digits.count <= 18, let n = Int64(String(decoding: digits, as: UTF8.self)) else {
            throw IMAPProtocolError.literalTooLarge(String(decoding: digits, as: UTF8.self))
        }
        var cut = k
        if cut > 0, line[cut - 1] == UInt8(ascii: "~") { cut -= 1 }      // literal8
        line.removeSubrange(cut...)
        return n
    }
}

// MARK: - Tokenizer

/// Reads values from a framed response: text bytes with literals in place.
struct IMAPTokenCursor {
    private let segments: [IMAPRawResponse.Segment]
    private var seg = 0
    private var pos = 0

    init(_ response: IMAPRawResponse) { segments = response.segments }

    /// The current text byte, nil at a literal or the end.
    var peek: UInt8? {
        guard seg < segments.count else { return nil }
        if case .text(let t) = segments[seg] {
            if pos < t.count { return t[pos] }
            return nil
        }
        return nil
    }

    var atLiteral: Bool {
        normalizedSegment().flatMap { s -> Bool? in
            switch segments[s] { case .literal, .streamed: return true; default: return false }
        } ?? false
    }

    var atEnd: Bool { normalizedSegment() == nil }

    /// Index of the segment holding the next value (skipping exhausted text).
    private func normalizedSegment() -> Int? {
        var s = seg, p = pos
        while s < segments.count {
            if case .text(let t) = segments[s] {
                if p < t.count { return s }
                s += 1; p = 0
            } else {
                return s
            }
        }
        return nil
    }

    private mutating func normalize() {
        while seg < segments.count, case .text(let t) = segments[seg], pos >= t.count {
            seg += 1; pos = 0
        }
    }

    mutating func advance() { pos += 1 }

    mutating func skipSpaces() {
        normalize()
        while peek == 0x20 { advance(); normalize() }
    }

    /// The remaining text of the current text segment (resp-text).
    mutating func restOfText() -> [UInt8] {
        normalize()
        guard seg < segments.count, case .text(let t) = segments[seg] else { return [] }
        let r = Array(t[pos...])
        pos = t.count
        return r
    }

    /// One atom-like word (stops at SP, parens, quotes, CR/LF). Brackets of a
    /// FETCH section (`BODY[HEADER.FIELDS (A B)]<0>`) are kept whole.
    mutating func word() -> String {
        normalize()
        var out: [UInt8] = []
        var depth = 0
        while let c = peek {
            if depth == 0 && (c == 0x20 || c == UInt8(ascii: "(") || c == UInt8(ascii: ")") || c == UInt8(ascii: "\"")) { break }
            if c == UInt8(ascii: "[") { depth += 1 }
            if c == UInt8(ascii: "]") {
                if depth == 0 { break }
                depth -= 1
            }
            out.append(c); advance()
        }
        return String(decoding: out, as: UTF8.self)
    }

    mutating func value() throws -> IMAPValue {
        skipSpaces()
        if atLiteral {
            let s = normalizedSegment()!
            seg = s + 1; pos = 0
            switch segments[s] {
            case .literal(let b): return .string(b)
            case .streamed(let n): return .streamed(n)
            case .text: break
            }
        }
        guard let c = peek else { throw IMAPProtocolError.malformed("a value was expected") }
        switch c {
        case UInt8(ascii: "("):
            advance()
            var items: [IMAPValue] = []
            while true {
                skipSpaces()
                if peek == UInt8(ascii: ")") { advance(); return .list(items) }
                if atEnd { throw IMAPProtocolError.malformed("an unclosed list") }
                items.append(try value())
            }
        case UInt8(ascii: "\""):
            advance()
            var out: [UInt8] = []
            while true {
                guard let b = peek else { throw IMAPProtocolError.malformed("an unterminated quoted string") }
                advance()
                if b == UInt8(ascii: "\\") {
                    guard let e = peek else { throw IMAPProtocolError.malformed("an unterminated quoted string") }
                    out.append(e); advance()
                } else if b == UInt8(ascii: "\"") {
                    return .string(out)
                } else {
                    out.append(b)
                }
            }
        case UInt8(ascii: ")"):
            throw IMAPProtocolError.malformed("an unexpected ')'")
        default:
            let w = word()
            if w.isEmpty { advance(); throw IMAPProtocolError.malformed("an unexpected byte") }
            if w.uppercased() == "NIL" { return .nilValue }
            return .atom(w)
        }
    }

    mutating func values() throws -> [IMAPValue] {
        var out: [IMAPValue] = []
        while true {
            skipSpaces()
            if atEnd { return out }
            out.append(try value())
        }
    }
}

// MARK: - Response parsing

public enum IMAPResponseParser {
    public static func parse(_ raw: IMAPRawResponse) throws -> IMAPResponse {
        var cursor = IMAPTokenCursor(raw)
        let first = cursor.word()
        if first.hasPrefix("+") {
            // "+" may be followed directly by text, or by SP text.
            var rest = Array(first.utf8.dropFirst())
            let tail = cursor.restOfText()
            rest += tail
            return .continuation(String(decoding: rest, as: UTF8.self).trimmingCharacters(in: .whitespaces))
        }
        guard cursor.peek == 0x20 else { throw IMAPProtocolError.malformed("a response without a tag") }
        cursor.skipSpaces()
        if first == "*" {
            let keyword = cursor.word()
            let upper = keyword.uppercased()
            if let status = IMAPStatus(rawValue: upper) {
                return .untaggedStatus(statusResponse(status, &cursor))
            }
            if let n = UInt64(keyword) {
                cursor.skipSpaces()
                let kind = cursor.word().uppercased()
                if kind == "FETCH" {
                    let list = try cursor.value()
                    guard case .list(let items) = list else { throw IMAPProtocolError.malformed("FETCH without a list") }
                    var pairs: [(String, IMAPValue)] = []
                    var k = 0
                    while k + 1 < items.count {
                        guard let name = items[k].atomText else { throw IMAPProtocolError.malformed("a FETCH item without a name") }
                        pairs.append((name.uppercased(), items[k + 1]))
                        k += 2
                    }
                    return .fetch(sequence: n, pairs.map { (name: $0.0, value: $0.1) })
                }
                return .numbered(n, kind)
            }
            return .data(upper, try cursor.values())
        }
        let word = cursor.word().uppercased()
        guard let status = IMAPStatus(rawValue: word) else {
            throw IMAPProtocolError.malformed("a tagged response without OK, NO or BAD")
        }
        return .tagged(tag: first, statusResponse(status, &cursor))
    }

    static func statusResponse(_ status: IMAPStatus, _ cursor: inout IMAPTokenCursor) -> IMAPStatusResponse {
        cursor.skipSpaces()
        let rest = cursor.restOfText()
        var code: IMAPResponseCode?
        var textStart = 0
        if rest.first == UInt8(ascii: "[") {
            var depth = 0, k = 1, end: Int?
            while k < rest.count {
                let c = rest[k]
                if c == UInt8(ascii: "(") { depth += 1 } else if c == UInt8(ascii: ")") { depth -= 1 }
                else if c == UInt8(ascii: "]") && depth <= 0 { end = k; break }
                k += 1
            }
            if let end {
                let inside = String(decoding: rest[1..<end], as: UTF8.self)
                let parts = inside.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                code = IMAPResponseCode(name: parts.first.map { $0.uppercased() } ?? "",
                                        argument: parts.count > 1 ? String(parts[1]) : "")
                textStart = end + 1
            }
        }
        let text = String(decoding: rest[min(textStart, rest.count)...], as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return IMAPStatusResponse(status: status, code: code, text: text)
    }
}

// MARK: - UID sets

/// A set of UIDs as sorted, disjoint, non-adjacent ranges; serialises to an
/// IMAP sequence-set ("1:5,7,9:12"). Used for change tokens (the UIDs known at
/// a boundary) and ESEARCH results.
public struct IMAPUIDSet: Sendable, Equatable {
    public private(set) var ranges: [ClosedRange<UInt32>] = []

    public init() {}
    public init<S: Sequence>(_ uids: S) where S.Element == UInt32 {
        for u in uids.sorted() { appendAscending(u) }
    }

    /// Parses "1:5,7,9:12" (no "*").
    public init?(sequenceSet: String) {
        if sequenceSet.isEmpty { return }
        var all: [ClosedRange<UInt32>] = []
        for part in sequenceSet.split(separator: ",") {
            let ends = part.split(separator: ":")
            guard let a = UInt32(ends[0]) else { return nil }
            let b = ends.count > 1 ? UInt32(ends[1]) : a
            guard let b, ends.count <= 2 else { return nil }
            all.append(min(a, b)...max(a, b))
        }
        all.sort { $0.lowerBound < $1.lowerBound }
        for r in all { insert(r) }
    }

    public var isEmpty: Bool { ranges.isEmpty }
    public var count: Int { ranges.reduce(0) { $0 + Int($1.upperBound - $1.lowerBound) + 1 } }
    public var highest: UInt32? { ranges.last?.upperBound }

    public var sequenceSet: String {
        ranges.map { $0.lowerBound == $0.upperBound ? String($0.lowerBound) : "\($0.lowerBound):\($0.upperBound)" }
            .joined(separator: ",")
    }

    public func contains(_ uid: UInt32) -> Bool {
        var lo = 0, hi = ranges.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if ranges[mid].contains(uid) { return true }
            if uid < ranges[mid].lowerBound { hi = mid - 1 } else { lo = mid + 1 }
        }
        return false
    }

    public var uids: [UInt32] { ranges.flatMap { Array($0) } }

    mutating func appendAscending(_ u: UInt32) {
        if let last = ranges.last {
            if last.contains(u) { return }
            if last.upperBound != .max, last.upperBound + 1 == u {
                ranges[ranges.count - 1] = last.lowerBound...u
                return
            }
        }
        ranges.append(u...u)
    }

    public mutating func insert(_ r: ClosedRange<UInt32>) {
        var merged = r
        var out: [ClosedRange<UInt32>] = []
        var placed = false
        for x in ranges {
            let touches = !(UInt64(x.upperBound) + 1 < UInt64(merged.lowerBound) || UInt64(merged.upperBound) + 1 < UInt64(x.lowerBound))
            if touches {
                merged = Swift.min(x.lowerBound, merged.lowerBound)...Swift.max(x.upperBound, merged.upperBound)
            } else if x.upperBound < merged.lowerBound {
                out.append(x)
            } else {
                if !placed { out.append(merged); placed = true }
                out.append(x)
            }
        }
        if !placed { out.append(merged) }
        ranges = out
    }

    public mutating func insert(_ u: UInt32) { insert(u...u) }

    public mutating func remove(_ u: UInt32) {
        guard let i = ranges.firstIndex(where: { $0.contains(u) }) else { return }
        let r = ranges[i]
        var repl: [ClosedRange<UInt32>] = []
        if r.lowerBound < u { repl.append(r.lowerBound...(u - 1)) }
        if u < r.upperBound { repl.append((u + 1)...r.upperBound) }
        ranges.replaceSubrange(i...i, with: repl)
    }

    /// UIDs in self that are not in `other`.
    public func subtracting(_ other: IMAPUIDSet) -> [UInt32] {
        uids.filter { !other.contains($0) }
    }
}
