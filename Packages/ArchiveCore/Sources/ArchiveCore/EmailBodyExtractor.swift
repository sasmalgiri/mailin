import Foundation

// MARK: - AttachmentMetadata

public struct AttachmentMetadata: Codable, Sendable {
    public let filename: String
    public let mimeType: String
    public let size: Int
    public let isInline: Bool
    public let contentID: String?
    public let base64: String?
    public let fileURL: URL?

    public init(filename: String, mimeType: String, size: Int, isInline: Bool = false, contentID: String? = nil, base64: String? = nil, fileURL: URL? = nil) {
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
        self.isInline = isInline
        self.contentID = contentID
        self.base64 = base64
        self.fileURL = fileURL
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        filename = try container.decodeIfPresent(String.self, forKey: .filename) ?? "unknown"
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType) ?? "application/octet-stream"
        size = try container.decodeIfPresent(Int.self, forKey: .size) ?? 0
        isInline = try container.decodeIfPresent(Bool.self, forKey: .isInline) ?? false
        contentID = try container.decodeIfPresent(String.self, forKey: .contentID)
        base64 = try container.decodeIfPresent(String.self, forKey: .base64)
        fileURL = try container.decodeIfPresent(URL.self, forKey: .fileURL)
    }
}



// MARK: - EmailExtractionError

public enum EmailExtractionError: Error, CustomStringConvertible {
    case invalidEmail
    case parsingFailed(reason: String)
    case fileSavingFailed(reason: String)
    case decodingFailed
    case fileTooLarge(filename: String, size: Int)
    case suspiciousAttachment(filename: String, reason: String)

    public var description: String {
        switch self {
        case .invalidEmail:
            return "Invalid email format."
        case .parsingFailed(let reason):
            return "Parsing failed: \(reason)"
        case .fileSavingFailed(let reason):
            return "File saving failed: \(reason)"
        case .decodingFailed:
            return "Decoding of attachment data failed."
        case .fileTooLarge(let filename, let size):
            return "File '\(filename)' too large (\(size) bytes)."
        case .suspiciousAttachment(let filename, let reason):
            return "Attachment '\(filename)' flagged: \(reason)"
        }
    }
}

// MARK: - EmailBodyExtractor

public class EmailBodyExtractor {
    static let maxDepth = 20
    static let inlineEmbedLimit = 10_000_000  // 10MB for base64 inline attachments
    static let suspiciousSizeLimit = 250_000_000 // 250MB for attachments

    /// Main extractor: returns plain body, HTML body, and all attachments (decoded)
    public static func extractContents(from rawEmail: String) throws -> (
        plainBody: String,
        htmlBody: String,
        attachments: [AttachmentMetadata]
    ) {
        let (_, parts) = MIMEParser.parseEmail(rawEmail: rawEmail)
        return try extractContents(parts: parts)
    }

    /// The same extraction over an ALREADY-PARSED MIME tree. `processRawMessage`
    /// parses the message once for its headers and then called
    /// `extractContents(from:)`, which parsed the whole text a second time —
    /// two full MIME passes per message (profiled 2026-09-28). Callers that
    /// hold the parts pass them here.
    public static func extractContents(parts: [MIMEPart]) throws -> (
        plainBody: String,
        htmlBody: String,
        attachments: [AttachmentMetadata]
    ) {
        var plainBodies: [String] = []
        var htmlBodies: [String] = []
        var attachments: [AttachmentMetadata] = []

        for part in parts {
            processPart(
                part,
                into: &plainBodies,
                htmlBodies: &htmlBodies,
                attachments: &attachments,
                depth: 0
            )
        }

        return (
            plainBodies.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines),
            htmlBodies.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines),
            attachments
        )
    }

    /// Recursive MIME part walker (matches Python's .walk())
    private static func processPart(
        _ part: MIMEPart,
        into plainBodies: inout [String],
        htmlBodies: inout [String],
        attachments: inout [AttachmentMetadata],
        depth: Int
    ) {
        guard depth < maxDepth else { return }

        let lower = part.mimeType.lowercased()

        // RFC822 or nested message
        if lower.hasPrefix("message/rfc822") {
            if part.isAttachment {
                if let md = extractAttachment(from: part, forceFilename: "attached.eml") {
                    attachments.append(md)
                }
                return
            } else if !part.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let (_, nested) = MIMEParser.parseEmail(rawEmail: part.body)
                for sub in nested {
                    processPart(sub, into: &plainBodies, htmlBodies: &htmlBodies, attachments: &attachments, depth: depth + 1)
                }
                return
            }
        }

        // Multipart: recursively process subparts
        if lower.hasPrefix("multipart/") {
            for sub in part.subparts {
                processPart(sub, into: &plainBodies, htmlBodies: &htmlBodies, attachments: &attachments, depth: depth + 1)
            }
            return
        }

        // Ignore empty bodies
        if part.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }

        // Body parts (text/plain, text/html)
        if part.isTextBody {
            let decoded = decodeBodyFromPart(part)
            if part.isHTML {
                htmlBodies.append(decoded)
            } else {
                plainBodies.append(decoded)
            }
            return
        }

        // Attachments (files, images, PDFs, inline images, etc)
        if part.filename != nil || part.isAttachment || part.isInlineImage || lower.hasPrefix("image/") || lower == "application/pdf" {
            if let md = extractAttachment(from: part) {
                attachments.append(md)
            }
        }
    }

    /// Extracts an attachment, decodes, and saves as needed (no double decoding)
    private static func extractAttachment(from part: MIMEPart, forceFilename: String? = nil) -> AttachmentMetadata? {
        do {
            let dispName = parseParam("filename", in: part.headers["Content-Disposition"])
            let typeName = parseParam("name", in: part.headers["Content-Type"])
            let suggestedName = forceFilename ?? part.filename ?? dispName ?? typeName ?? "attachment"
            let contentID = part.headers["Content-ID"]?.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n"))

            // --- NEW LOGIC ---
            return try AttachmentSaver.saveAttachment(
                body: part.body,
                encoding: part.transferEncoding,
                mimeType: part.mimeType,
                suggestedFilename: suggestedName
            ).withInlineInfo(
                isInline: part.isInlineImage,
                contentID: contentID
            )
        } catch {
            return nil
        }
    }

    private static func charsetToEncoding(_ charset: String?) -> String.Encoding {
        switch (charset ?? "utf-8").lowercased() {
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
            let cfEnc = CFStringConvertIANACharSetNameToEncoding((charset ?? "utf-8") as CFString)
            if cfEnc != kCFStringEncodingInvalidId {
                return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEnc))
            }
            return .utf8
        }
    }

    /// Helper for param extraction (RFC-compliant)
    private static func parseParam(_ key: String, in header: String?) -> String? {
        guard let h = header else { return nil }
        // Try RFC2231 first
        let rfc2231 = #"(?i)\b\#(key)\*\s*=\s*(?:[\w-]+'[\w-]*')?([^";]+)"#
        if let re = try? NSRegularExpression(pattern: rfc2231), let m = re.firstMatch(in: h, range: NSRange(location: 0, length: (h as NSString).length)), m.numberOfRanges > 1, m.range(at: 1).location != NSNotFound {
            return (h as NSString).substring(with: m.range(at: 1)).removingPercentEncoding
        }
        // Try standard
        let pattern = #"(?i)\b\#(key)=["]?([^";]+)["]?"#
        if let re = try? NSRegularExpression(pattern: pattern), let m = re.firstMatch(in: h, range: NSRange(location: 0, length: (h as NSString).length)), m.numberOfRanges > 1, m.range(at: 1).location != NSNotFound {
            return (h as NSString).substring(with: m.range(at: 1))
        }
        return nil
    }

    /// Use SwiftEmailKit QP/base64 helpers if present (safe fallback)
    private static func decodeBodyFromPart(_ part: MIMEPart) -> String {
        let encoding = part.transferEncoding.lowercased()
        let charset = part.charset
        let raw = part.body

        #if canImport(SwiftEmailKit)
        if encoding == "quoted-printable" {
            if let kit = SwiftEmailKit.QuotedPrintableDecoder as AnyObject?,
               let method = kit.decode as? (String, Bool, String?) -> String {
                return method(raw, false, charset)
            }
        }
        if encoding == "base64" {
            if let kit = SwiftEmailKit.Base64Decoder as AnyObject?,
               let method = kit.decode as? (String) -> Data?,
               let data = method(raw), let str = String(data: data, encoding: .utf8) {
                return str
            }
        }
        #endif

        if encoding == "quoted-printable" {
            return QuotedPrintableDecoder.decode(raw, isHeader: false, charset: charset)
        } else if encoding == "base64" {
            // The decoder skips whitespace itself; a Character-level filter
            // here cost a grapheme walk over the whole body for nothing.
            if let data = Data(base64Encoded: raw, options: [.ignoreUnknownCharacters]) {
                let enc = charsetToEncoding(charset)
                if let str = String(data: data, encoding: enc) { return str }
                if let str = String(data: data, encoding: .utf8) { return str }
                if let str = String(data: data, encoding: .isoLatin1) { return str }
            }
            return raw
        } else {
            return raw
        }
    }
}

// MARK: - AttachmentSaver (Robust binary-safe fallback for all edge-cases)

public class AttachmentSaver {

    /// True for the 65 bytes of the base64 alphabet (A–Z a–z 0–9 + / =).
    private static let base64Alphabet: [Bool] = {
        var table = [Bool](repeating: false, count: 256)
        for byte in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=".utf8 { table[Int(byte)] = true }
        return table
    }()

    /// The base64 bytes of `body`, line by line: a line that is empty after
    /// trimming, starts with `--`, or mentions `boundary` is dropped (stray
    /// MIME framing); every other byte outside the alphabet is skipped. Same
    /// result as the old Character pipeline, in one pass over UTF-8.
    static func base64Payload(of body: String) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(body.utf8.count)
        let boundary = Array("boundary".utf8)
        var body = body
        body.withUTF8 { bytes in
            var lineStart = 0
            let count = bytes.count
            while lineStart < count {
                var lineEnd = lineStart
                while lineEnd < count, bytes[lineEnd] != 0x0A { lineEnd += 1 }
                // Trim ASCII whitespace at both ends of the line.
                var first = lineStart, last = lineEnd
                while first < last, bytes[first] == 0x20 || bytes[first] == 0x09 || bytes[first] == 0x0D { first += 1 }
                while last > first, bytes[last - 1] == 0x20 || bytes[last - 1] == 0x09 || bytes[last - 1] == 0x0D { last -= 1 }
                let line = UnsafeBufferPointer(rebasing: bytes[first..<last])
                let skip = line.isEmpty
                    || (line.count >= 2 && line[0] == UInt8(ascii: "-") && line[1] == UInt8(ascii: "-"))
                    || Self.contains(line, boundary)
                if !skip {
                    for byte in line where base64Alphabet[Int(byte)] { out.append(byte) }
                }
                lineStart = lineEnd + 1
            }
        }
        return out
    }

    private static func contains(_ haystack: UnsafeBufferPointer<UInt8>, _ needle: [UInt8]) -> Bool {
        guard haystack.count >= needle.count, !needle.isEmpty else { return false }
        var i = 0
        let limit = haystack.count - needle.count
        while i <= limit {
            if haystack[i] == needle[0] {
                var j = 1
                while j < needle.count, haystack[i + j] == needle[j] { j += 1 }
                if j == needle.count { return true }
            }
            i += 1
        }
        return false
    }

    /// Saves the decoded data from email attachment to a temp file (with fallback for raw binary/nonstandard)
    public static func saveAttachment(
        body: String,
        encoding: String?,
        mimeType: String?,
        suggestedFilename: String?
    ) throws -> AttachmentMetadata {
        // Step 1: Robust decode (base64, QP, binary fallback)
        let data: Data? = {
            let enc = encoding?.lowercased() ?? ""
            if enc == "base64" {
                // Clean body (drop stray boundary lines, keep only the base64
                // alphabet) at the BYTE level. The previous version filtered
                // Character by Character against a 65-character String, with
                // grapheme-cluster semantics on both sides — a linear scan per
                // character over megabytes per message. Profiled 2026-09-28
                // on the real mailbox: 61 % of the entire import was this one
                // line; SQLite and FTS did not appear in the profile at all.
                var filtered = Self.base64Payload(of: body)
                let padLen = (4 - filtered.count % 4) % 4
                filtered.append(contentsOf: repeatElement(UInt8(ascii: "="), count: padLen))
                if let d = Data(base64Encoded: Data(filtered)), !d.isEmpty {
                    return d
                }
                // Fallback: treat as raw binary
                return body.data(using: .isoLatin1)
            }
            else if enc == "quoted-printable" {
                // Your QP decoder, then fallback
                let decoded = QuotedPrintableDecoder.decode(body, isHeader: false)
                if let d = decoded.data(using: .utf8), !d.isEmpty { return d }
                return decoded.data(using: .isoLatin1)
            }
            else {
                // No encoding: treat as raw binary (for 7bit, 8bit, binary, or bad encodings)
                return body.data(using: .isoLatin1)
            }
        }()

        guard let finalData = data, !finalData.isEmpty else {
            throw EmailExtractionError.decodingFailed
        }

        // (helpers below)

        // Step 2: Save to temp file (raw, not re-encoded)
        let rawExt = mimeType?.components(separatedBy: "/").last ?? ""
        let ext = rawExt.isEmpty ? "bin" : rawExt
        let safeName = (suggestedFilename ?? "attachment.\(ext)")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "..", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "_" + safeName)

        try finalData.write(to: tempURL, options: .atomic)

        return AttachmentMetadata(
            filename: safeName,
            mimeType: mimeType ?? "application/octet-stream",
            size: finalData.count,
            isInline: false,      // Inline info handled by withInlineInfo
            contentID: nil,       // Inline info handled by withInlineInfo
            base64: nil,          // Only for very small (<10MB) if needed
            fileURL: tempURL
        )
    }
}

// MARK: - Helpers

private extension AttachmentMetadata {
    func withInlineInfo(isInline: Bool, contentID: String?) -> AttachmentMetadata {
        AttachmentMetadata(
            filename: self.filename,
            mimeType: self.mimeType,
            size: self.size,
            isInline: isInline,
            contentID: contentID,
            base64: self.base64,
            fileURL: self.fileURL
        )
    }
}
