//
//  IMAPMailboxName.swift
//  MailConnectivity
//
//  Plan v4 V4-07: mailbox names on the wire. Without UTF8=ACCEPT a name is
//  modified UTF-7 (RFC 3501 §5.1.3: "&" shifts into modified BASE64 of
//  UTF-16, "-" shifts back, "&-" is "&"). With UTF8=ACCEPT enabled (RFC 6855)
//  names are UTF-8 and sent as quoted strings.
//

import Foundation

public enum IMAPModifiedUTF7 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+,".utf8)
    private static let reverse: [UInt8: UInt8] = {
        var m: [UInt8: UInt8] = [:]
        for (i, c) in alphabet.enumerated() { m[c] = UInt8(i) }
        return m
    }()

    public static func encode(_ name: String) -> String {
        var out = ""
        var pending: [UInt16] = []
        func flush() {
            guard !pending.isEmpty else { return }
            var bytes: [UInt8] = []
            for u in pending { bytes.append(UInt8(u >> 8)); bytes.append(UInt8(u & 0xFF)) }
            var s = "&"
            var i = 0
            while i < bytes.count {
                let b0 = bytes[i], b1 = i + 1 < bytes.count ? bytes[i + 1] : 0, b2 = i + 2 < bytes.count ? bytes[i + 2] : 0
                let n = bytes.count - i
                let c0 = b0 >> 2, c1 = ((b0 & 0x03) << 4) | (b1 >> 4), c2 = ((b1 & 0x0F) << 2) | (b2 >> 6), c3 = b2 & 0x3F
                s.unicodeScalars.append(Unicode.Scalar(alphabet[Int(c0)]))
                s.unicodeScalars.append(Unicode.Scalar(alphabet[Int(c1)]))
                if n > 1 { s.unicodeScalars.append(Unicode.Scalar(alphabet[Int(c2)])) }
                if n > 2 { s.unicodeScalars.append(Unicode.Scalar(alphabet[Int(c3)])) }
                i += 3
            }
            out += s + "-"
            pending = []
        }
        for scalar in name.unicodeScalars {
            let v = scalar.value
            if v >= 0x20 && v <= 0x7E {
                flush()
                out += v == 0x26 ? "&-" : String(scalar)
            } else {
                pending.append(contentsOf: Array(String(scalar).utf16))
            }
        }
        flush()
        return out
    }

    /// nil when `wire` is not valid modified UTF-7.
    public static func decode(_ wire: [UInt8]) -> String? {
        var out: [UInt16] = []
        var i = 0
        while i < wire.count {
            let c = wire[i]
            guard c >= 0x20 && c <= 0x7E else { return nil }
            if c != UInt8(ascii: "&") { out.append(UInt16(c)); i += 1; continue }
            i += 1
            var sextets: [UInt8] = []
            while i < wire.count, wire[i] != UInt8(ascii: "-") {
                guard let v = reverse[wire[i]] else { return nil }
                sextets.append(v); i += 1
            }
            guard i < wire.count else { return nil }        // no closing "-"
            i += 1
            if sextets.isEmpty { out.append(0x26); continue } // "&-"
            var bits: UInt32 = 0, nbits = 0
            var bytes: [UInt8] = []
            for s in sextets {
                bits = (bits << 6) | UInt32(s); nbits += 6
                if nbits >= 8 { nbits -= 8; bytes.append(UInt8((bits >> UInt32(nbits)) & 0xFF)) }
            }
            guard bytes.count % 2 == 0, !bytes.isEmpty else { return nil }
            for k in stride(from: 0, to: bytes.count, by: 2) { out.append(UInt16(bytes[k]) << 8 | UInt16(bytes[k + 1])) }
        }
        return String(utf16CodeUnits: out, count: out.count).nilIfInvalid(out)
    }
}

private extension String {
    func nilIfInvalid(_ units: [UInt16]) -> String? {
        // Reject unpaired surrogates (String would replace them silently).
        var it = units.makeIterator()
        var decoder = UTF16()
        loop: while true {
            switch decoder.decode(&it) {
            case .scalarValue: continue
            case .emptyInput: break loop
            case .error: return nil
            }
        }
        return self
    }
}

/// A mailbox as the server names it (the wire bytes) and as mailin shows it.
public struct IMAPMailboxName: Sendable, Hashable {
    /// The exact bytes the server sent (what EXAMINE must send back).
    public var wire: [UInt8]
    /// Decoded Unicode name; also the folder's stable `serverID`.
    public var name: String

    /// `utf8`: the session enabled UTF8=ACCEPT, so names are UTF-8.
    public init(wire: [UInt8], utf8: Bool) {
        self.wire = wire
        if wire.count == 5, String(decoding: wire, as: UTF8.self).uppercased() == "INBOX" {
            name = "INBOX"                      // case-insensitive (RFC 3501 §5.1)
        } else if utf8, let s = String(bytes: wire, encoding: .utf8) {
            name = s
        } else if let s = IMAPModifiedUTF7.decode(wire) {
            name = s
        } else {
            // Some servers send raw 8-bit names without UTF8=ACCEPT.
            name = String(decoding: wire, as: UTF8.self)
        }
    }

    /// The bytes to send for `name` in a session with or without UTF8=ACCEPT.
    public static func wireBytes(for name: String, utf8: Bool) -> [UInt8] {
        if name == "INBOX" { return Array("INBOX".utf8) }
        return utf8 ? Array(name.utf8) : Array(IMAPModifiedUTF7.encode(name).utf8)
    }
}
