import Foundation

public struct QuotedPrintableDecoder {
    /// RFC 2045 §6.7 quoted-printable, decoded over UTF-8 BYTES. The previous
    /// version walked the text Character by Character with
    /// `index(_:offsetBy:)` — a grapheme walk per step — and showed up in the
    /// import profile as `Substring.index(offsetBy:)` (2026-09-28). Same
    /// rules as before: `=\r\n` and `=\n` are soft breaks and vanish; `=XX`
    /// with two hex digits is one byte; a lone `=` at the very end is dropped;
    /// any other `=` is literal; in header mode `_` is a space; every other
    /// byte passes through unchanged (non-ASCII UTF-8 sequences included).
    public static func decode(_ input: String, isHeader: Bool = false, charset: String? = nil) -> String {
        #if canImport(SwiftEmailKit)
        if let kit = SwiftEmailKit.QuotedPrintableDecoder as AnyObject?,
           let method = kit.decode as? (String, Bool, String?) -> String {
            return method(input, isHeader, charset)
        }
        #endif
        var input = input
        let output: [UInt8] = input.withUTF8 { bytes in decodeBytes(bytes, isHeader: isHeader) }
        let data = Data(output)
        if let charset = charset?.lowercased(), charset != "utf-8",
           let str = String(data: data, encoding: stringEncoding(for: charset)) {
            return str
        }
        if let str = String(data: data, encoding: .utf8) { return str }
        if let str = String(data: data, encoding: .isoLatin1) { return str }
        return String(decoding: data, as: UTF8.self)
    }

    /// The transfer decode itself: quoted-printable bytes in, the original
    /// bytes out, with NO character-set interpretation. This is the entry
    /// point for attachment payloads (audit F07, 2026-09-28): routing a binary
    /// part through `decode(_:)` turned every byte ≥ 0x80 into its two-byte
    /// UTF-8 spelling (`FF 00 80` → `C3 BF 00 C2 80`).
    public static func decodeBytes(_ data: Data, isHeader: Bool = false) -> Data {
        data.withUnsafeBytes { raw -> Data in
            Data(decodeBytes(raw.bindMemory(to: UInt8.self), isHeader: isHeader))
        }
    }

    static func decodeBytes(_ bytes: UnsafeBufferPointer<UInt8>, isHeader: Bool) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        let count = bytes.count
        var i = 0
        while i < count {
            let byte = bytes[i]
            if byte == UInt8(ascii: "=") {
                // Soft line break: "=\r\n" or "=\n".
                if i + 2 < count, bytes[i + 1] == 0x0D, bytes[i + 2] == 0x0A { i += 3; continue }
                if i + 1 < count, bytes[i + 1] == 0x0A { i += 2; continue }
                if i + 2 < count, let hi = hexValue(bytes[i + 1]), let lo = hexValue(bytes[i + 2]) {
                    out.append(hi << 4 | lo)
                    i += 3
                    continue
                }
                // Trailing `=` at the end of the text is a soft break too.
                if i + 1 >= count { i += 1; continue }
                out.append(byte)
                i += 1
            } else if isHeader, byte == UInt8(ascii: "_") {
                out.append(0x20)
                i += 1
            } else {
                out.append(byte)
                i += 1
            }
        }
        return out
    }

    @inline(__always)
    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    public static func isQuotedPrintable(_ text: String) -> Bool {
        text.range(of: "=[0-9A-Fa-f]{2}", options: .regularExpression) != nil
    }

    private static func stringEncoding(for charset: String) -> String.Encoding {
        switch charset.lowercased() {
            case "utf-8", "utf8": return .utf8
            case "iso-8859-1", "latin1", "latin-1": return .isoLatin1
            case "iso-8859-2", "latin2", "latin-2": return .isoLatin2
            case "us-ascii", "ascii": return .ascii
            case "windows-1252", "cp1252": return .windowsCP1252
            case "windows-1251", "cp1251":
                return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.windowsCyrillic.rawValue)))
            case "shift_jis", "shift-jis", "sjis": return .shiftJIS
            case "euc-jp": return .japaneseEUC
            case "iso-2022-jp": return .iso2022JP
            default:
                let cfEnc = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
                if cfEnc != kCFStringEncodingInvalidId {
                    return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEnc))
                }
                return .utf8
        }
    }
}
