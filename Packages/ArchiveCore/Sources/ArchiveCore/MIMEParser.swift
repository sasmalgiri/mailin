import Foundation

public class MIMEParser {
    public static func parseEmail(rawEmail: String, depth: Int = 0) -> (headers: [String: String], parts: [MIMEPart]) {
        #if canImport(SwiftEmailKit)
        if let kitParser = SwiftEmailKit.MIMEParser as AnyObject?,
           let parseFunc = kitParser.parseEmail as? (String) -> (headers: [String: String], parts: [Any]) {
            let (headers, partsAny) = parseFunc(rawEmail)
            let parts: [MIMEPart] = partsAny.compactMap { p in
                if let part = p as? MIMEPart { return part }
                if let kitPart = p as? SwiftEmailKit.MIMEPart {
                    return MIMEPart(
                        headers: kitPart.headers,
                        body: kitPart.body,
                        rawBody: kitPart.rawBody,
                        mimeType: kitPart.mimeType,
                        contentDisposition: kitPart.contentDisposition,
                        filename: kitPart.filename,
                        transferEncoding: kitPart.transferEncoding,
                        charset: kitPart.charset,
                        subparts: kitPart.subparts.map { $0 as? MIMEPart ?? MIMEPart(
                            headers: $0.headers,
                            body: $0.body,
                            rawBody: $0.rawBody,
                            mimeType: $0.mimeType,
                            contentDisposition: $0.contentDisposition,
                            filename: $0.filename,
                            transferEncoding: $0.transferEncoding,
                            charset: $0.charset,
                            subparts: [],
                            rawData: $0.rawData
                        ) },
                        rawData: kitPart.rawData
                    )
                }
                return nil
            }
            return (headers, parts)
        }
        #endif
        // ---- Legacy fallback parsing ----
        // Byte-level split at the first blank line (CRLF CRLF when the text
        // has one anywhere, else LF LF — the same rule the String version
        // applied). `components(separatedBy:)` over the whole message went
        // through Foundation's UTF-16 bridge and was the largest single cost
        // in the import profile after the base64 fix (2026-09-28).
        guard let split = ByteSplit.headerAndBody(of: rawEmail) else {
            return (headers: [:], parts: [])
        }
        let headerBlock = split.head
        let bodyBlock = split.rest
        let headers = parseHeaders(from: headerBlock)
        let contentType = headers["Content-Type"] ?? "text/plain"
        let boundary = extractBoundary(contentType)
        let parts: [MIMEPart]
        guard depth < maxRecursionDepth else { return (headers, []) }
        if let boundary = boundary {
            parts = buildRecursiveParts(bodyBlock, boundary: boundary, defaultContentType: contentType, depth: depth)
        } else {
            parts = [makeSinglePart(headers: headers, content: bodyBlock)]
        }
        return (headers, parts)
    }

    // --- Helper: Identify attachment vs body (prevents double decoding) ---
    private static func isAttachment(_ headers: [String: String]) -> Bool {
        let disposition = headers["Content-Disposition"]?.lowercased() ?? ""
        let filename = headers["Content-Disposition"].flatMap { extractFilename($0) } ?? headers["Content-Type"].flatMap { extractFilename($0) }
        return disposition.contains("attachment") ||
               ((filename != nil) && !disposition.contains("inline"))
    }

    // --- Legacy fallback helpers ---
    private static func parseHeaders(from raw: String) -> [String: String] {
        var headers = [String: String]()
        var currentKey: String?
        var currentValue = ""
        let lines = raw.components(separatedBy: .newlines)
        for line in lines {
            if line.isEmpty { continue }
            if line.first == " " || line.first == "\t" {
                currentValue += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let range = line.range(of: ":") {
                if let key = currentKey {
                    headers[key] = currentValue.trimmingCharacters(in: .whitespaces)
                }
                currentKey = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                currentValue = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else {
                currentValue += " " + line.trimmingCharacters(in: .whitespaces)
            }
        }
        if let key = currentKey {
            headers[key] = currentValue.trimmingCharacters(in: .whitespaces)
        }
        return headers
    }
    // Compiled once: `NSRegularExpression.init` (an ICU compile) showed up in
    // the import profile because these were rebuilt for every MIME part.
    private static let boundaryRegex = try? NSRegularExpression(pattern: #"boundary="?([^";\r\n]+)"?"#, options: .caseInsensitive)
    private static let charsetRegex = try? NSRegularExpression(pattern: #"charset="?([^";\r\n]+)"?"#, options: .caseInsensitive)
    private static let filenameStarRegex = try? NSRegularExpression(pattern: #"filename\*\s*=\s*(?:[\w-]+'[\w-]*')?([^;"]+)"#, options: .caseInsensitive)
    private static let filenameQuotedRegex = try? NSRegularExpression(pattern: #"filename\s*=\s*"([^"]+)""#, options: .caseInsensitive)
    private static let filenameBareRegex = try? NSRegularExpression(pattern: #"filename\s*=\s*([^;\s]+)"#, options: .caseInsensitive)

    public static func extractBoundary(_ contentType: String) -> String? {
        if let regex = boundaryRegex,
           let match = regex.firstMatch(in: contentType, range: NSRange(contentType.startIndex..., in: contentType)),
           let range = Range(match.range(at: 1), in: contentType) {
            return String(contentType[range])
        }
        return nil
    }
    public static func extractCharset(_ contentType: String) -> String {
        if let regex = charsetRegex,
           let match = regex.firstMatch(in: contentType, range: NSRange(contentType.startIndex..., in: contentType)),
           let range = Range(match.range(at: 1), in: contentType) {
            return String(contentType[range]).lowercased()
        }
        return "utf-8"
    }
    private static let maxRecursionDepth = 20

    private static func buildRecursiveParts(_ body: String, boundary: String, defaultContentType: String, depth: Int) -> [MIMEPart] {
        guard depth < maxRecursionDepth else { return [] }
        guard !boundary.isEmpty else { return [] }
        // Segments between `--boundary` markers, split and trimmed at the
        // byte level; each part's header/body split likewise.
        let segments = ByteSplit.segments(of: body, separatedBy: "--\(boundary)")
        var parts: [MIMEPart] = []
        for segment in segments {
            autoreleasepool {
                guard let trimmedSection = ByteSplit.trimmedPart(segment) else { return }
                let headerSection = trimmedSection.head
                let rawBody = trimmedSection.rest
                let headers = parseHeaders(from: headerSection)
                let contentType = headers["Content-Type"] ?? defaultContentType
                let charset = extractCharset(contentType)
                let encoding = headers["Content-Transfer-Encoding"] ?? ""
                let bodyToStore = isAttachment(headers) ? rawBody : decodeBody(rawBody, encoding: encoding, charset: charset)
                var part = MIMEPart(
                    headers: headers,
                    body: bodyToStore,
                    rawBody: rawBody,
                    mimeType: contentType,
                    contentDisposition: headers["Content-Disposition"] ?? "",
                    filename: extractFilename(headers["Content-Disposition"]) ?? extractFilename(headers["Content-Type"]),
                    transferEncoding: encoding,
                    charset: charset,
                    subparts: []
                )
                if contentType.lowercased().hasPrefix("multipart/"),
                   let nestedBoundary = extractBoundary(contentType) {
                    part.subparts = buildRecursiveParts(part.body, boundary: nestedBoundary, defaultContentType: contentType, depth: depth + 1)
                } else if contentType.lowercased().hasPrefix("message/rfc822"), depth + 1 < maxRecursionDepth,
                          !part.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let nested = parseEmail(rawEmail: part.body, depth: depth + 1)
                    part.subparts = nested.parts
                }
                parts.append(part)
            }
        }
        return parts
    }
    private static func decodeBody(_ content: String, encoding: String, charset: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        switch encoding.lowercased() {
        case "base64":
            #if canImport(SwiftEmailKit)
            if let kit = SwiftEmailKit.Base64Decoder as AnyObject?,
               let decode = kit.decode as? (String) -> Data?,
               let data = decode(trimmed) {
                if let str = String(data: data, encoding: .utf8) {
                    return str
                }
            }
            #endif
            // The decoder skips whitespace itself; the Character-level filter
            // that preceded it walked every grapheme of the body.
            if let data = Data(base64Encoded: trimmed, options: [.ignoreUnknownCharacters]) {
                return decodeData(data, charset: charset)
            }
            return trimmed
        case "quoted-printable":
            return QuotedPrintableDecoder.decode(trimmed, isHeader: false, charset: charset)
        case "7bit", "8bit", "binary":
            // A Swift String is already valid UTF-8: re-decoding it as UTF-8
            // is the identity and cost two copies of every text body.
            let encoding = stringEncoding(for: charset)
            if encoding == .utf8 { return trimmed }
            if let data = trimmed.data(using: .utf8),
               let decoded = String(data: data, encoding: encoding) {
                return decoded
            }
            return trimmed
        default:
            let encoding = stringEncoding(for: charset)
            if encoding == .utf8 { return trimmed }
            if let data = trimmed.data(using: .utf8),
               let decoded = String(data: data, encoding: encoding) {
                return decoded
            }
            return trimmed
        }
    }
    private static func decodeData(_ data: Data, charset: String) -> String {
        if let s = String(data: data, encoding: stringEncoding(for: charset)) { return s }
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .isoLatin1) { return s }
        return String(decoding: data, as: UTF8.self)
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
            case "macintosh", "macosroman": return .macOSRoman
            case "utf-16", "utf16": return .utf16
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
    private static func makeSinglePart(headers: [String: String], content: String) -> MIMEPart {
        let contentType = headers["Content-Type"] ?? "text/plain"
        let charset = extractCharset(contentType)
        let encoding = headers["Content-Transfer-Encoding"] ?? ""
        // *** Only decode text parts, not attachments ***
        let bodyToStore = isAttachment(headers) ? content : decodeBody(content, encoding: encoding, charset: charset)
        return MIMEPart(
            headers: headers,
            body: bodyToStore,
            rawBody: content,
            mimeType: contentType,
            contentDisposition: headers["Content-Disposition"] ?? "",
            filename: extractFilename(headers["Content-Disposition"]) ?? extractFilename(headers["Content-Type"]),
            transferEncoding: encoding,
            charset: charset,
            subparts: []
        )
    }
    private static func extractFilename(_ header: String?) -> String? {
        guard let header = header, !header.isEmpty else { return nil }
        let headerRange = NSRange(header.startIndex..., in: header)

        if let regex = filenameStarRegex,
           let match = regex.firstMatch(in: header, range: headerRange),
           let range = Range(match.range(at: 1), in: header) {
            return header[range].removingPercentEncoding?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let regex = filenameQuotedRegex,
           let match = regex.firstMatch(in: header, range: headerRange),
           let range = Range(match.range(at: 1), in: header) {
            return String(header[range])
        }

        if let regex = filenameBareRegex,
           let match = regex.firstMatch(in: header, range: headerRange),
           let range = Range(match.range(at: 1), in: header) {
            return String(header[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return nil
    }
}

// MARK: - Byte-level splitting

/// The String-shaped splits the MIME parser needs, done over UTF-8 bytes.
/// Every boundary this parser looks for is ASCII (`\r\n\r\n`, `\n\n`,
/// `--boundary`), and in UTF-8 an ASCII byte never occurs inside a multi-byte
/// sequence, so byte search is exact. Results come back as Strings decoded
/// from byte slices of a String that was valid UTF-8 to begin with, so the
/// text is unchanged — only the walk is different.
enum ByteSplit {
    private static let crlfcrlf: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
    private static let lflf: [UInt8] = [0x0A, 0x0A]

    /// Header block and the rest, split at the FIRST blank line. CRLF CRLF
    /// is the separator when the text contains one anywhere (the rule the
    /// String version used), otherwise LF LF. Nil when there is no blank line.
    static func headerAndBody(of text: String) -> (head: String, rest: String)? {
        var text = text
        return text.withUTF8 { bytes -> (String, String)? in
            let separator: [UInt8]
            if firstIndex(of: crlfcrlf, in: bytes, from: 0) != nil { separator = crlfcrlf } else { separator = lflf }
            guard let at = firstIndex(of: separator, in: bytes, from: 0) else { return nil }
            let head = String(decoding: UnsafeBufferPointer(rebasing: bytes[0..<at]), as: UTF8.self)
            let rest = String(decoding: UnsafeBufferPointer(rebasing: bytes[(at + separator.count)...]), as: UTF8.self)
            return (head, rest)
        }
    }

    /// The pieces between occurrences of `marker`, like
    /// `components(separatedBy:)`: the text before the first marker, between
    /// markers, and after the last. Each piece is returned as its own String.
    static func segments(of text: String, separatedBy marker: String) -> [String] {
        let needle = Array(marker.utf8)
        guard !needle.isEmpty else { return [text] }
        var text = text
        return text.withUTF8 { bytes -> [String] in
            var out: [String] = []
            var start = 0
            while let at = firstIndex(of: needle, in: bytes, from: start) {
                out.append(String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<at]), as: UTF8.self))
                start = at + needle.count
            }
            out.append(String(decoding: UnsafeBufferPointer(rebasing: bytes[start...]), as: UTF8.self))
            return out
        }
    }

    /// One MIME part's segment, trimmed, then split into its header section
    /// and raw body at the first blank line. Nil when the trimmed segment is
    /// empty or is the closing `--` of the boundary. A segment with no blank
    /// line is all headers and an empty body, as before.
    static func trimmedPart(_ segment: String) -> (head: String, rest: String)? {
        // Trim: ASCII whitespace at the byte level; if a non-ASCII byte sits
        // at either edge, defer to the String rule for exactness (rare).
        var trimmed = segment
        var edgeIsNonASCII = false
        trimmed.withUTF8 { bytes in
            if let f = bytes.first, f >= 0x80 { edgeIsNonASCII = true }
            if let l = bytes.last, l >= 0x80 { edgeIsNonASCII = true }
        }
        if edgeIsNonASCII {
            trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            trimmed = trimmed.withUTF8 { bytes -> String in
                var first = 0, last = bytes.count
                while first < last, isSpace(bytes[first]) { first += 1 }
                while last > first, isSpace(bytes[last - 1]) { last -= 1 }
                if first == 0, last == bytes.count { return segment }
                return String(decoding: UnsafeBufferPointer(rebasing: bytes[first..<last]), as: UTF8.self)
            }
        }
        if trimmed.isEmpty || trimmed.hasPrefix("--") { return nil }
        if let split = headerAndBody(of: trimmed) { return split }
        return (trimmed, "")
    }

    @inline(__always)
    private static func isSpace(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x0B || b == 0x0C
    }

    static func firstIndex(of needle: [UInt8], in haystack: UnsafeBufferPointer<UInt8>, from start: Int) -> Int? {
        let n = needle.count, h = haystack.count
        guard n > 0, h >= n, start <= h - n else { return nil }
        let first = needle[0]
        var i = start
        let limit = h - n
        while i <= limit {
            if haystack[i] == first {
                var j = 1
                while j < n, haystack[i + j] == needle[j] { j += 1 }
                if j == n { return i }
            }
            i += 1
        }
        return nil
    }
}
