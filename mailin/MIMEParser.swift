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
        let separator = rawEmail.contains("\r\n\r\n") ? "\r\n\r\n" : "\n\n"
        let components = rawEmail.components(separatedBy: separator)
        guard components.count >= 2 else {
            return (headers: [:], parts: [])
        }
        let headerBlock = components[0]
        let bodyBlock = components.dropFirst().joined(separator: separator)
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
    public static func extractBoundary(_ contentType: String) -> String? {
        let regex = try? NSRegularExpression(pattern: #"boundary="?([^";\r\n]+)"?"#, options: .caseInsensitive)
        if let regex = regex,
           let match = regex.firstMatch(in: contentType, range: NSRange(contentType.startIndex..., in: contentType)),
           let range = Range(match.range(at: 1), in: contentType) {
            return String(contentType[range])
        }
        return nil
    }
    public static func extractCharset(_ contentType: String) -> String {
        let regex = try? NSRegularExpression(pattern: #"charset="?([^";\r\n]+)"?"#, options: .caseInsensitive)
        if let regex = regex,
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
        let marker = "--\(boundary)"
        let segments = body.components(separatedBy: marker)
        var parts: [MIMEPart] = []
        for segment in segments {
            autoreleasepool {
                let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty || trimmed.hasPrefix("--") { return }
                let partSeparator = trimmed.contains("\r\n\r\n") ? "\r\n\r\n" : "\n\n"
                let sections = trimmed.components(separatedBy: partSeparator)
                let headerSection = sections.first ?? ""
                let rawBody = sections.dropFirst().joined(separator: partSeparator)
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
                } else if contentType.lowercased().hasPrefix("message/rfc822"), depth + 1 < maxRecursionDepth {
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
            let filtered = trimmed.filter { !$0.isWhitespace }
            if let data = Data(base64Encoded: filtered) {
                return decodeData(data, charset: charset)
            }
            return trimmed
        case "quoted-printable":
            return QuotedPrintableDecoder.decode(trimmed, isHeader: false, charset: charset)
        case "7bit", "8bit", "binary":
            if let data = trimmed.data(using: .utf8) {
                if let decoded = String(data: data, encoding: stringEncoding(for: charset)) {
                    return decoded
                }
            }
            return trimmed
        default:
            if let data = trimmed.data(using: .utf8) {
                if let decoded = String(data: data, encoding: stringEncoding(for: charset)) {
                    return decoded
                }
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

        if let regex = try? NSRegularExpression(pattern: #"filename\*\s*=\s*(?:[\w-]+'[\w-]*')?([^;"]+)"#, options: .caseInsensitive),
           let match = regex.firstMatch(in: header, range: headerRange),
           let range = Range(match.range(at: 1), in: header) {
            return header[range].removingPercentEncoding?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let regex = try? NSRegularExpression(pattern: #"filename\s*=\s*"([^"]+)""#, options: .caseInsensitive),
           let match = regex.firstMatch(in: header, range: headerRange),
           let range = Range(match.range(at: 1), in: header) {
            return String(header[range])
        }

        if let regex = try? NSRegularExpression(pattern: #"filename\s*=\s*([^;\s]+)"#, options: .caseInsensitive),
           let match = regex.firstMatch(in: header, range: headerRange),
           let range = Range(match.range(at: 1), in: header) {
            return String(header[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return nil
    }
}
