import Foundation

public struct QuotedPrintableDecoder {
    public static func decode(_ input: String, isHeader: Bool = false, charset: String? = nil) -> String {
        #if canImport(SwiftEmailKit)
        if let kit = SwiftEmailKit.QuotedPrintableDecoder as AnyObject?,
           let method = kit.decode as? (String, Bool, String?) -> String {
            return method(input, isHeader, charset)
        }
        #endif
        var cleaned = input.replacingOccurrences(of: "=\r\n", with: "")
                           .replacingOccurrences(of: "=\n", with: "")
        if isHeader { cleaned = cleaned.replacingOccurrences(of: "_", with: " ") }
        var output = Data()
        var i = cleaned.startIndex
        let end = cleaned.endIndex
        while i < end {
            let char = cleaned[i]
            if char == "=" {
                let hex1 = cleaned.index(i, offsetBy: 1, limitedBy: end)
                let hex2 = cleaned.index(i, offsetBy: 2, limitedBy: end)
                if let h1 = hex1, let h2 = hex2, h2 < end {
                    let hex = String(cleaned[h1...h2])
                    if let byte = UInt8(hex, radix: 16) {
                        output.append(byte)
                        i = cleaned.index(i, offsetBy: 3)
                        continue
                    }
                }
                // Trailing `=` at EOF is a soft line break — skip it
                if hex1 == nil || hex1 == end {
                    i = cleaned.index(after: i)
                    continue
                }
                output.append(UInt8(ascii: "="))
                i = cleaned.index(after: i)
            } else {
                if let ascii = char.asciiValue {
                    output.append(ascii)
                } else {
                    let charStr = String(char)
                    if let utf8Data = charStr.data(using: .utf8) {
                        output.append(contentsOf: utf8Data)
                    }
                }
                i = cleaned.index(after: i)
            }
        }
        if let charset = charset?.lowercased(), charset != "utf-8",
           let str = String(data: output, encoding: stringEncoding(for: charset)) {
            return str
        }
        if let str = String(data: output, encoding: .utf8) { return str }
        if let str = String(data: output, encoding: .isoLatin1) { return str }
        return String(decoding: output, as: UTF8.self)
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
