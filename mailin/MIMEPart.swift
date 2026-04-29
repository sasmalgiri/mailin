import Foundation
import AppKit

public struct MIMEPart: Codable {
    public var headers: [String: String]
    public var body: String
    public var rawBody: String
    public var mimeType: String
    public var contentDisposition: String
    public var filename: String?
    public var transferEncoding: String
    public var charset: String
    public var subparts: [MIMEPart]
    public var rawData: Data? // Excluded from Codable

    // ---- CodingKeys for Codable ----
    enum CodingKeys: String, CodingKey {
        case headers
        case body
        case rawBody
        case mimeType
        case contentDisposition
        case filename
        case transferEncoding
        case charset
        case subparts
        // Exclude rawData from coding
    }

    // ---- Initializer ----
    public init(
        headers: [String: String] = [:],
        body: String = "",
        rawBody: String = "",
        mimeType: String = "text/plain",
        contentDisposition: String = "",
        filename: String? = nil,
        transferEncoding: String = "7bit",
        charset: String = "utf-8",
        subparts: [MIMEPart] = [],
        rawData: Data? = nil
    ) {
        self.headers = MIMEPart.normalizeHeaders(headers)
        self.body = body
        self.rawBody = rawBody
        self.mimeType = mimeType
        self.contentDisposition = contentDisposition
        self.filename = filename
        self.transferEncoding = transferEncoding
        self.charset = charset
        self.subparts = subparts
        self.rawData = rawData
    }

    // ---- Computed Properties ----
    public var isMultipart: Bool { mimeType.lowercased().hasPrefix("multipart/") }
    public var isText: Bool { mimeType.lowercased().hasPrefix("text/") }
    public var isMessageRFC822: Bool { mimeType.lowercased().starts(with: "message/rfc822") }
    public var isAttachment: Bool {
        let disp = contentDisposition.lowercased()
        return disp.contains("attachment") || (filename != nil && !disp.contains("inline"))
    }
    public var isInlineImage: Bool {
        mimeType.lowercased().hasPrefix("image/") &&
        (contentDisposition.lowercased().contains("inline") || contentID != nil)
    }
    public var isTextBody: Bool { isText && !isAttachment && !isInlineImage }
    public var isHTML: Bool { mimeType.lowercased().contains("html") }
    public var contentID: String? {
        headers["Content-ID"]?.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n"))
    }
    public var type: String { mimeType.components(separatedBy: "/").first?.lowercased() ?? "application" }
    public var subtype: String { mimeType.components(separatedBy: "/").last?.lowercased() ?? "octet-stream" }
    public var boundary: String? { MIMEPart.extractParameter("boundary", from: headers["Content-Type"]) }
    public var name: String? { MIMEPart.extractParameter("name", from: headers["Content-Type"]) }
    public var dispositionType: String {
        contentDisposition.components(separatedBy: ";").first?.lowercased() ?? ""
    }
    public var dispositionParams: [String: String] {
        MIMEPart.extractParameters(from: contentDisposition)
    }
    public var summary: String {
        var result = "📄 MIME Part Summary\n"
        result += "• MIME Type     : \(mimeType)\n"
        result += "• Charset       : \(charset)\n"
        result += "• Encoding      : \(transferEncoding)\n"
        result += "• Disposition   : \(contentDisposition)\n"
        result += "• Filename      : \(filename ?? "nil")\n"
        result += "• Body Length   : \(body.count) characters\n"
        result += "• RawBody Length: \(rawBody.count) characters\n"
        result += "• Subpart Count : \(subparts.count)\n"
        result += "• Multipart?    : \(isMultipart)\n"
        result += "• Attachment?   : \(isAttachment)\n"
        result += "• Inline Image? : \(isInlineImage)\n"
        result += "• HTML?         : \(isHTML)"
        return result
    }

    // ---- Decoding Logic (robust, RFC-compliant) ----
    /// Decodes the part's payload like Python's get_payload(decode=True), handling base64, QP, 7bit, 8bit, binary, all charsets.
    public func getDecodedPayload() -> Data? {
        let encoding = self.transferEncoding.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let raw = self.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let charset = self.charset.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        switch encoding {
        case "base64":
            let filtered = raw.filter { "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=".contains($0) }
            let padLen = (4 - filtered.count % 4) % 4
            let padded = filtered + String(repeating: "=", count: padLen)
            if let data = Data(base64Encoded: padded, options: [.ignoreUnknownCharacters]), !data.isEmpty {
                return data
            }
            // Brute force offset for tolerance
            for offset in 1...8 where filtered.count > offset + 16 {
                let seg = String(filtered.dropFirst(offset))
                let padLen = (4 - seg.count % 4) % 4
                let test = seg + String(repeating: "=", count: padLen)
                if let data = Data(base64Encoded: test, options: [.ignoreUnknownCharacters]), data.count > 10 {
                    return data
                }
            }
            return nil
        case "quoted-printable":
            let decoded = QuotedPrintableDecoder.decode(raw, isHeader: false, charset: charset)
            let tried: [String.Encoding] = [
                stringEncoding(for: charset),
                .utf8, .isoLatin1, .windowsCP1252, .macOSRoman
            ]
            for enc in tried {
                if let d = decoded.data(using: enc), !d.isEmpty { return d }
            }
            return nil
        case "7bit", "8bit", "binary", "":
            let tried: [String.Encoding] = [
                stringEncoding(for: charset),
                .utf8, .isoLatin1, .windowsCP1252, .macOSRoman
            ]
            for enc in tried {
                if let d = raw.data(using: enc), !d.isEmpty { return d }
            }
            return nil
        default:
            if let d = raw.data(using: .utf8), !d.isEmpty { return d }
            return Data(raw.utf8)
        }
    }

    /// Decodes as String if text, else nil
    public func getDecodedText() -> String? {
        guard let data = getDecodedPayload() else { return nil }
        let charset = self.charset.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let tried: [String.Encoding] = [
            stringEncoding(for: charset),
            .utf8, .isoLatin1, .windowsCP1252, .macOSRoman
        ]
        for enc in tried {
            if let str = String(data: data, encoding: enc), !str.isEmpty { return str }
        }
        return nil
    }

    /// Save decoded attachment to temp, with best-guess extension (by MIME/content/filename)
    public func saveRobustDecodedAttachmentToTemp() -> URL? {
        guard let data = self.getDecodedPayload(), !data.isEmpty else { return nil }
        let ext = fileExtension(for: self.mimeType, data: data) ?? "bin"
        let safeName = (self.filename ?? "attachment.\(ext)").replacingOccurrences(of: "/", with: "_")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "_" + safeName)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            print("❌ Failed to save attachment: \(error)")
            return nil
        }
    }

    /// Opens the saved attachment in the default macOS app
    public func openAttachmentInDefaultApp() {
        if let url = saveRobustDecodedAttachmentToTemp() {
            NSWorkspace.shared.open(url)
        }
    }

    // --- Heuristics to sniff file extension ---
    private func fileExtension(for mimeType: String, data: Data) -> String? {
        let lower = mimeType.lowercased()
        let ext: String? = {
            if lower.hasSuffix("/pdf") { return "pdf" }
            if lower.hasSuffix("/png") { return "png" }
            if lower.hasSuffix("/jpg") || lower.hasSuffix("/jpeg") { return "jpg" }
            if lower.hasSuffix("/gif") { return "gif" }
            if lower.hasSuffix("/zip") { return "zip" }
            if lower.hasSuffix("/msword") { return "doc" }
            if lower.contains("wordprocessingml.document") { return "docx" }
            if lower.contains("spreadsheetml.sheet") { return "xlsx" }
            if lower.contains("presentationml.presentation") { return "pptx" }
            if lower.hasSuffix("/plain") { return "txt" }
            if lower.hasSuffix("/rtf") { return "rtf" }
            if lower.contains("ms-excel") { return "xls" }
            if lower.contains("ms-powerpoint") { return "ppt" }
            return nil
        }()
        if let ext = ext { return ext }
        // Magic byte checks
        if data.starts(with: [0x25, 0x50, 0x44, 0x46]) { return "pdf" }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if data.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "gif" }
        if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
            // ZIP family: docx/xlsx/pptx/ods/odt
            if let str = String(data: data, encoding: .utf8),
               str.contains("[Content_Types].xml") {
                if str.contains("word/") { return "docx" }
                if str.contains("sheet") { return "xlsx" }
                if str.contains("presentation") { return "pptx" }
                if str.contains("ods") { return "ods" }
                if str.contains("odt") { return "odt" }
            }
            return "zip"
        }
        if data.starts(with: [0xD0, 0xCF, 0x11, 0xE0]) { // old Office
            if let str = String(data: data, encoding: .isoLatin1) {
                if str.contains("WordDocument") { return "doc" }
                if str.contains("Workbook") { return "xls" }
                if str.contains("PowerPoint") { return "ppt" }
            }
        }
        if data.starts(with: [0x7B, 0x5C, 0x72, 0x74, 0x66]) { return "rtf" }
        if data.starts(with: [0x25]) { return "ps" }
        if data.starts(with: [0x3C, 0x3F, 0x78, 0x6D, 0x6C]) { return "xml" }
        if data.starts(with: [0x49, 0x44, 0x33]) { return "mp3" }
        if data.starts(with: [0x42, 0x4D]) { return "bmp" }
        if data.starts(with: [0x00, 0x00, 0x01, 0x00]) { return "ico" }
        // Fallback: try filename extension
        if let s = self.filename, let ext = s.split(separator: ".").last { return String(ext) }
        return nil
    }

    // ---- Helpers ----
    public static func extractParameter(_ key: String, from header: String?) -> String? {
        guard let header = header else { return nil }
        let rfc2231Pattern = #"\b\#(key)\*\s*=\s*(?:[\w-]+'[\w-]*')?([^;\r\n"]+)"#
        if let regex = try? NSRegularExpression(pattern: rfc2231Pattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
           let range = Range(match.range(at: 2), in: header) {
            return header[range].removingPercentEncoding?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let quotedPattern = #"\b\#(key)\s*=\s*"([^"]+)""#
        if let regex = try? NSRegularExpression(pattern: quotedPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
           let range = Range(match.range(at: 2), in: header) {
            return String(header[range])
        }
        let simplePattern = #"\b\#(key)\s*=\s*([^;\s]+)"#
        if let regex = try? NSRegularExpression(pattern: simplePattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
           let range = Range(match.range(at: 2), in: header) {
            return String(header[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }
    public static func extractParameters(from header: String?) -> [String: String] {
        guard let header = header else { return [:] }
        var params: [String: String] = [:]
        let regex = try? NSRegularExpression(pattern: #"([a-zA-Z0-9\-_]+)\*?=(?:\"([^\"]*)\"|([^;]*))"#, options: [])
        let nsHeader = header as NSString
        regex?.enumerateMatches(in: header, range: NSRange(location: 0, length: nsHeader.length)) { match, _, _ in
            guard let match = match, match.numberOfRanges > 2 else { return }
            let key = nsHeader.substring(with: match.range(at: 1)).lowercased()
            let value = (match.range(at: 2).location != NSNotFound)
                ? nsHeader.substring(with: match.range(at: 2))
                : (match.range(at: 3).location != NSNotFound ? nsHeader.substring(with: match.range(at: 3)) : "")
            params[key] = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return params
    }
    public static func normalizeHeaders(_ headers: [String: String]) -> [String: String] {
        var normalized: [String: String] = [:]
        for (key, value) in headers {
            normalized[key.trimmingCharacters(in: .whitespacesAndNewlines).capitalized] = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return normalized
    }
    public func allParts(recursive: Bool = true) -> [MIMEPart] {
        var parts: [MIMEPart] = [self]
        if recursive {
            for sub in subparts {
                parts.append(contentsOf: sub.allParts(recursive: true))
            }
        }
        return parts
    }

    public func flattenedParts() -> [MIMEPart] {
        allParts(recursive: true)
    }
}

/// Helper: Maps charset string to String.Encoding
fileprivate func stringEncoding(for charset: String) -> String.Encoding {
    switch charset.lowercased() {
        case "utf-8", "utf8": return .utf8
        case "iso-8859-1", "latin1": return .isoLatin1
        case "us-ascii", "ascii": return .ascii
        case "windows-1252": return .windowsCP1252
        case "macintosh", "macosroman": return .macOSRoman
        default: return .utf8
    }
}
