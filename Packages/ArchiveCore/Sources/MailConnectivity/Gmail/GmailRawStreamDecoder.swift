//
//  GmailRawStreamDecoder.swift
//  MailConnectivity
//
//  Plan v4 V4-05 (§3 A04, §5.2): `users.messages.get?format=raw` answers with
//  a JSON object whose "raw" member is the COMPLETE RFC 822 message in
//  base64url. This decoder reads that JSON as it arrives, chunk by chunk:
//   • the "raw" string is base64url-decoded incrementally and every decoded
//     byte is handed on immediately (to the staging file) — the message is
//     never held whole, and never turned into a Swift String;
//   • every other member (id, labelIds, historyId, internalDate …) is copied
//     into a small metadata JSON (with "raw" emptied) decoded at the end.
//  A response that ends before its JSON closes is a TRUNCATED transfer, never
//  a preserved message.
//

import Foundation

public enum GmailRawDecodeError: Error, Equatable, LocalizedError {
    /// The stream ended before the JSON object closed (transfer cut short).
    case truncated
    /// The JSON is not a Gmail message object, or the raw value is not base64url.
    case malformed(String)
    /// The message object carried no "raw" member.
    case missingRaw

    public var errorDescription: String? {
        switch self {
        case .truncated: return "The Gmail response ended before the message was complete."
        case .malformed(let why): return "The Gmail response could not be read (\(why))."
        case .missingRaw: return "Gmail returned the message without its raw bytes."
        }
    }
}

/// Incremental base64url (RFC 4648 §5) decoder. Also accepts the standard
/// alphabet's `+` `/` and `=` padding, and ignores CR/LF.
struct Base64URLStreamDecoder {
    private var quad: UInt32 = 0
    private var count = 0
    private var padded = false
    private(set) var output = Data()

    mutating func push(_ c: UInt8) throws {
        let value: UInt32
        switch c {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): value = UInt32(c - UInt8(ascii: "A"))
        case UInt8(ascii: "a")...UInt8(ascii: "z"): value = UInt32(c - UInt8(ascii: "a")) + 26
        case UInt8(ascii: "0")...UInt8(ascii: "9"): value = UInt32(c - UInt8(ascii: "0")) + 52
        case UInt8(ascii: "-"), UInt8(ascii: "+"): value = 62
        case UInt8(ascii: "_"), UInt8(ascii: "/"): value = 63
        case UInt8(ascii: "="): padded = true; return
        case UInt8(ascii: "\r"), UInt8(ascii: "\n"): return
        default: throw GmailRawDecodeError.malformed("a raw byte outside base64url")
        }
        if padded { throw GmailRawDecodeError.malformed("base64url continues after padding") }
        quad = quad << 6 | value
        count += 1
        if count == 4 {
            output.append(UInt8(truncatingIfNeeded: quad >> 16))
            output.append(UInt8(truncatingIfNeeded: quad >> 8))
            output.append(UInt8(truncatingIfNeeded: quad))
            quad = 0; count = 0
        }
    }

    /// Takes what is decoded so far.
    mutating func drain() -> Data {
        defer { output.removeAll(keepingCapacity: true) }
        return output
    }

    mutating func finish() throws {
        switch count {
        case 0: break
        case 2: output.append(UInt8(truncatingIfNeeded: quad >> 4))
        case 3:
            output.append(UInt8(truncatingIfNeeded: quad >> 10))
            output.append(UInt8(truncatingIfNeeded: quad >> 2))
        default: throw GmailRawDecodeError.malformed("base64url ends in the middle of a byte")
        }
        quad = 0; count = 0
    }
}

/// The streaming reader of one `format=raw` response.
struct GmailRawStreamDecoder {
    /// The response JSON with the raw value emptied (small).
    private(set) var metadataJSON = Data()
    private(set) var rawByteCount: Int64 = 0
    private var base64 = Base64URLStreamDecoder()

    private var depth = 0
    private var inString = false
    private var escaped = false
    private var expectingKey = false
    private var keyBuffer: [UInt8]?
    private var lastKey: String?
    private var valueKey: String?
    private var inRaw = false
    private var rawEscape: [UInt8]?
    private var sawRaw = false
    private var complete = false

    private static let quote = UInt8(ascii: "\"")
    private static let backslash = UInt8(ascii: "\\")

    private static func isWhitespace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09 }

    /// Feeds the next chunk; decoded message bytes go to `emit` before it returns.
    mutating func feed(_ chunk: Data, emit: (Data) throws -> Void) throws {
        for byte in chunk { try step(byte) }
        let decoded = base64.drain()
        if !decoded.isEmpty {
            rawByteCount += Int64(decoded.count)
            try emit(decoded)
        }
    }

    /// The stream ended: checks the object closed and the raw value was there.
    mutating func finish(emit: (Data) throws -> Void) throws {
        guard complete, !inRaw else { throw GmailRawDecodeError.truncated }
        guard sawRaw else { throw GmailRawDecodeError.missingRaw }
        let tail = base64.drain()
        if !tail.isEmpty { rawByteCount += Int64(tail.count); try emit(tail) }
    }

    private mutating func step(_ byte: UInt8) throws {
        if complete {
            guard Self.isWhitespace(byte) else { throw GmailRawDecodeError.malformed("data after the message object") }
            return
        }
        if inRaw { try rawStep(byte); return }
        if depth == 0 {
            if Self.isWhitespace(byte) { return }
            guard byte == UInt8(ascii: "{") else { throw GmailRawDecodeError.malformed("not a JSON object") }
        }
        metadataJSON.append(byte)
        if inString {
            if escaped { escaped = false; keyBuffer?.append(byte); return }
            if byte == Self.backslash { escaped = true; keyBuffer?.append(byte); return }
            if byte == Self.quote {
                inString = false
                if let key = keyBuffer { lastKey = String(decoding: key, as: UTF8.self); keyBuffer = nil }
                return
            }
            if keyBuffer != nil {
                if keyBuffer!.count < 64 { keyBuffer!.append(byte) } else { keyBuffer = [UInt8(ascii: "#")] }
            }
            return
        }
        switch byte {
        case Self.quote:
            if depth == 1, valueKey == "raw" {
                guard !sawRaw else { throw GmailRawDecodeError.malformed("two raw members") }
                // The opening quote is in the metadata; the content is not.
                inRaw = true; sawRaw = true; valueKey = nil
                return
            }
            inString = true
            if depth == 1, expectingKey { keyBuffer = []; expectingKey = false }
            valueKey = nil
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            depth += 1
            if depth == 1 { expectingKey = true }
            valueKey = nil
        case UInt8(ascii: "}"), UInt8(ascii: "]"):
            depth -= 1
            guard depth >= 0 else { throw GmailRawDecodeError.malformed("unbalanced JSON") }
            if depth == 0 { complete = true }
            valueKey = nil
        case UInt8(ascii: ":"):
            if depth == 1 { valueKey = lastKey }
        case UInt8(ascii: ","):
            if depth == 1 { expectingKey = true; valueKey = nil }
        default:
            if depth == 1, !Self.isWhitespace(byte) { valueKey = nil }
        }
    }

    private mutating func rawStep(_ byte: UInt8) throws {
        if var escape = rawEscape {
            escape.append(byte)
            if escape.count == 1 {
                switch byte {
                case UInt8(ascii: "u"): rawEscape = escape; return
                case UInt8(ascii: "/"): rawEscape = nil; try base64.push(UInt8(ascii: "/")); return
                default: throw GmailRawDecodeError.malformed("an escape inside the raw value")
                }
            }
            if escape.count < 5 { rawEscape = escape; return }
            // \uXXXX — Google's JSON writer escapes "=" as backslash-u-003d.
            guard let scalar = UInt32(String(decoding: escape.dropFirst(), as: UTF8.self), radix: 16), scalar < 0x80 else {
                throw GmailRawDecodeError.malformed("an escape inside the raw value")
            }
            rawEscape = nil
            try base64.push(UInt8(scalar))
            return
        }
        if byte == Self.quote {
            inRaw = false
            try base64.finish()
            metadataJSON.append(Self.quote)
            return
        }
        if byte == Self.backslash { rawEscape = []; return }
        try base64.push(byte)
    }
}
