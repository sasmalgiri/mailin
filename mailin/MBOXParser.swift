import Foundation
import CryptoKit

struct MBOXParser {
    struct RawEmail: Identifiable, Codable {
        let id: UUID
        var headers: [String: String]
        var bodyLines: [String]
        var rawSource: String
        var messageType: String
        var attachments: [AttachmentMetadata]
        var timestamp: String
        var fullText: String
        var domains: [String]
        var plainBody: String
        var htmlBody: String
        var mimeRoot: MIMEPart?
        var mimeSummary: String?
        var mimeDiagnostics: [String]
        var threadID: String?
        var inReplyTo: String?
        var references: [String]?
        var tags: [String] = []
        var anomalies: [String] = []
    }

    struct ExportableRawEmail: Codable {
        let id: UUID
        let headers: [String: String]
        let plainBody: String
        let htmlBody: String
        let rawSource: String
        let messageType: String
        let attachments: [AttachmentMetadataForExport]
        let timestamp: String
        let domains: [String]
        let threadID: String?
        let inReplyTo: String?
        let references: [String]?
        let tags: [String]
        let anomalies: [String]
    }

    struct AttachmentMetadataForExport: Codable {
        let filename: String
        let mimeType: String
        let contentID: String?
        let size: Int
    }

    struct SummaryMetadata: Codable {
        let start: String
        let end: String
        let subjectCount: Int
    }

    struct ExportableParsedMBOXFile: Codable {
        let emails: [ExportableRawEmail]
        let summary: SummaryMetadata
    }

    static func parse(
        fileURL: URL,
        senderEmail: String,
        onProgress: ((Double) -> Void)? = nil
    ) throws -> [RawEmail] {
        let content = try FileUtils.readTextFile(url: fileURL)
        let rawMessages = splitMBOX(content: content)
        var parsedEmails: [RawEmail] = []
        let total = Double(rawMessages.count)

        for (idx, raw) in rawMessages.enumerated() {
            let fullRaw = raw.hasPrefix("From ") ? raw : "From " + raw
            let (headers, mimeParts) = MIMEParser.parseEmail(rawEmail: fullRaw)
            let rootPart = mimeParts.first
            let extraction = try EmailBodyExtractor.extractContents(from: fullRaw)

            var mappedHeaders = headers.mapValues { decodeMIMEHeader($0) }
            if mappedHeaders["From"] == nil {
                if let fallback = fullRaw.split(separator: "\n").first(where: { $0.lowercased().starts(with: "from:") }) {
                    mappedHeaders["From"] = fallback.replacingOccurrences(of: "From:", with: "").trimmingCharacters(in: .whitespaces)
                } else { mappedHeaders["From"] = "" }
            }
            if mappedHeaders["Subject"] == nil { mappedHeaders["Subject"] = "(No Subject)" }

            ["To", "Cc", "Bcc"].forEach { key in
                if let val = mappedHeaders[key] { mappedHeaders[key] = decodeAddressList(val) }
            }

            let from = mappedHeaders["From"] ?? ""
            let type = from.lowercased().contains(senderEmail.lowercased()) ? "sent" : "received"

            let bodyLines = (extraction.plainBody.isEmpty ? extraction.htmlBody : extraction.plainBody).components(separatedBy: .newlines)
            let joinedHeaders = mappedHeaders.map { "\($0): \($1)" }.joined(separator: "\n")
            let fullText = joinedHeaders + "\n\n" + bodyLines.joined(separator: "\n")
            let timestamp = parseDate(mappedHeaders["Date"]).map { ISO8601DateFormatter().string(from: $0) } ?? "1970-01-01T00:00:00Z"
            let domains = extractDomains(from: mappedHeaders)

            let rawEmail = RawEmail(
                id: UUID(),
                headers: mappedHeaders,
                bodyLines: bodyLines,
                rawSource: fullRaw,
                messageType: type,
                attachments: extraction.attachments,
                timestamp: timestamp,
                fullText: fullText,
                domains: domains,
                plainBody: extraction.plainBody,
                htmlBody: extraction.htmlBody,
                mimeRoot: rootPart,
                mimeSummary: rootPart?.summary,
                mimeDiagnostics: generateMIMEDiagnostics(root: rootPart),
                threadID: detectThreadID(headers: mappedHeaders, plainBody: extraction.plainBody, htmlBody: extraction.htmlBody),
                inReplyTo: mappedHeaders["In-Reply-To"],
                references: mappedHeaders["References"]?.split(separator: " ").map { String($0) },
                anomalies: findAnomalies(headers: mappedHeaders, body: extraction.plainBody, attachments: extraction.attachments)
            )

            parsedEmails.append(rawEmail)

            if let onProgress = onProgress {
                let progress = Double(idx + 1) / total
                DispatchQueue.main.async { onProgress(progress) }
            }
        }

        let summary = summarize(emails: parsedEmails)
        try saveSessionJSON(exportable: ExportableParsedMBOXFile(emails: parsedEmails.map { $0.asExportable() }, summary: summary))
        return parsedEmails
    }

    static func saveSessionJSON(exportable parsed: ExportableParsedMBOXFile) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(parsed)

        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = supportDir.appendingPathComponent("mailin", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let output = folder.appendingPathComponent("parsed_session.json")
        try FileUtils.writeData(data, to: output.path)
        print("✅ Session JSON saved at: \(output.path)")
    }

    static func summarize(emails: [RawEmail]) -> SummaryMetadata {
        let dates = emails.compactMap { parseDate($0.headers["Date"]) }.sorted()
        let subjects = Set(emails.compactMap { $0.headers["Subject"]?.trimmingCharacters(in: .whitespacesAndNewlines) }).filter { !$0.isEmpty }
        let isoFormatter = ISO8601DateFormatter()
        let start = dates.first.map { isoFormatter.string(from: $0) } ?? "N/A"
        let end = dates.last.map { isoFormatter.string(from: $0) } ?? "N/A"
        return SummaryMetadata(start: start, end: end, subjectCount: subjects.count)
    }

    static func splitMBOX(content: String) -> [String] {
        let delimiterPattern = #"(?m)^From .+\d{4}$"#
        guard let regex = try? NSRegularExpression(pattern: delimiterPattern) else {
            return content.components(separatedBy: "\nFrom ")
        }
        let matches = regex.matches(in: content, range: NSRange(content.startIndex..., in: content))
        var parts: [String] = []
        var lastIndex = content.startIndex
        for match in matches.dropFirst() {
            if let range = Range(match.range, in: content) {
                parts.append(String(content[lastIndex..<range.lowerBound]))
                lastIndex = range.lowerBound
            }
        }
        parts.append(String(content[lastIndex...]))
        return parts
    }

    static func generateMIMEDiagnostics(root: MIMEPart?) -> [String] {
        guard let root = root else { return ["<No MIME tree>"] }
        var diags: [String] = []
        func walk(_ part: MIMEPart, level: Int) {
            let prefix = String(repeating: "  ", count: level)
            let flags = (part.isAttachment ? "[Attachment]" : "") + (part.isInlineImage ? "[Inline]" : "")
            diags.append("\(prefix)- \(part.mimeType) \(part.filename ?? "") \(flags)")
            for sub in part.subparts {
                walk(sub, level: level + 1)
            }
        }
        walk(root, level: 0)
        return diags
    }

    static func detectThreadID(headers: [String: String], plainBody: String, htmlBody: String) -> String {
        if let refs = headers["References"], !refs.isEmpty {
            return refs.components(separatedBy: " ").first ?? refs
        }
        if let inReply = headers["In-Reply-To"], !inReply.isEmpty {
            return inReply
        }
        let subj = headers["Subject"] ?? ""
        let from = headers["From"] ?? ""
        let date = headers["Date"] ?? ""
        let snippet = (plainBody + htmlBody).prefix(80)
        return sha1("\(subj)\(from)\(date)\(snippet)")
    }

    static func findAnomalies(headers: [String: String], body: String, attachments: [AttachmentMetadata]) -> [String] {
        var issues: [String] = []
        if (headers["From"]?.isEmpty ?? true) { issues.append("Missing From header") }
        if (headers["To"]?.isEmpty ?? true) { issues.append("Missing To header") }
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append("Empty body") }
        if let s = headers["Subject"], s.count > 200 { issues.append("Long subject") }
        if let t = headers["Date"], parseDate(t) == nil { issues.append("Invalid date") }
        if attachments.count > 10 { issues.append("Too many attachments") }
        return issues
    }

    static func decodeMIMEHeader(_ value: String) -> String {
        let pattern = "=\\?([^?]+)\\?([bBqQ])\\?([^?]+)\\?="
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        let nsValue = value as NSString
        let matches = regex.matches(in: value, range: NSRange(location: 0, length: nsValue.length))
        var result = value
        for match in matches.reversed() {
            guard match.numberOfRanges == 4,
                  let charsetRange = Range(match.range(at: 1), in: value),
                  let encodingRange = Range(match.range(at: 2), in: value),
                  let dataRange = Range(match.range(at: 3), in: value) else { continue }
            let charset = value[charsetRange].lowercased()
            let encoding = value[encodingRange].lowercased()
            let encodedText = String(value[dataRange])
            var decoded = encodedText
            if encoding == "b", let data = Data(base64Encoded: encodedText) {
                decoded = decodeWithCharset(data: data, charset: charset) ?? encodedText
            } else if encoding == "q" {
                let qpDecoded = decodeQuotedPrintable(encodedText)
                if let data = qpDecoded.data(using: .utf8) {
                    decoded = decodeWithCharset(data: data, charset: charset) ?? qpDecoded
                }
            }
            result = (result as NSString).replacingCharacters(in: match.range, with: decoded)
        }
        return result
    }

    static func decodeQuotedPrintable(_ input: String) -> String {
        var output = input.replacingOccurrences(of: "_", with: " ")
        let pattern = "=([0-9A-Fa-f]{2})"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
        let ns = output as NSString
        for match in regex.matches(in: output, range: NSRange(location: 0, length: ns.length)).reversed() {
            if let hexRange = Range(match.range(at: 1), in: output) {
                let hex = output[hexRange]
                if let byte = UInt8(hex, radix: 16) {
                    output = (output as NSString).replacingCharacters(in: match.range, with: String(UnicodeScalar(byte)))
                }
            }
        }
        return output.replacingOccurrences(of: "=\r\n", with: "")
    }

    static func decodeAddressList(_ value: String) -> String {
        value.split(separator: ",").map {
            decodeMIMEHeader($0.trimmingCharacters(in: .whitespaces))
        }.joined(separator: ", ")
    }

    static func decodeWithCharset(data: Data, charset: String) -> String? {
        let encoding: String.Encoding
        switch charset.lowercased() {
        case "utf-8", "utf8": encoding = .utf8
        case "iso-8859-1", "latin1": encoding = .isoLatin1
        case "us-ascii", "ascii": encoding = .ascii
        default:
            print("⚠️ Unknown charset: \(charset) → fallback to UTF-8")
            encoding = .utf8
        }
        return String(data: data, encoding: encoding)
    }

    static func parseDate(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "E, d MMM yyyy HH:mm:ss Z",
            "d MMM yyyy HH:mm:ss Z",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEE MMM d HH:mm:ss yyyy",
            "dd MMM yyyy HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss"
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) {
                return date
            }
        }
        return ISO8601DateFormatter().date(from: raw)
    }

    static func extractDomains(from headers: [String: String]) -> [String] {
        var domains = Set<String>()
        ["To", "Cc", "Bcc"].forEach { key in
            guard let line = headers[key] else { return }
            for part in line.split(separator: ",") {
                if let at = part.firstIndex(of: "@") {
                    let domain = part[at...].dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
                    if domain.contains(".") {
                        domains.insert(domain.lowercased())
                    }
                }
            }
        }
        return Array(domains)
    }

    static func sha1(_ input: String) -> String {
        let data = Data(input.utf8)
        let digest = Insecure.SHA1.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

extension MBOXParser.RawEmail {
    func asExportable() -> MBOXParser.ExportableRawEmail {
        MBOXParser.ExportableRawEmail(
            id: self.id,
            headers: self.headers,
            plainBody: self.plainBody,
            htmlBody: self.htmlBody,
            rawSource: self.rawSource,
            messageType: self.messageType,
            attachments: self.attachments.map {
                MBOXParser.AttachmentMetadataForExport(
                    filename: $0.filename,
                    mimeType: $0.mimeType,
                    contentID: $0.contentID,
                    size: $0.size
                )
            },
            timestamp: self.timestamp,
            domains: self.domains,
            threadID: self.threadID,
            inReplyTo: self.inReplyTo,
            references: self.references,
            tags: self.tags,
            anomalies: self.anomalies
        )
    }
}
