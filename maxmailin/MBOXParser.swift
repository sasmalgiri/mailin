import Foundation
import CryptoKit

struct MBOXParser {
    struct RawEmail: Identifiable, Codable, Sendable {
        let id: UUID
        var headers: [String: String]
        var rawSource: String
        var messageType: String
        var attachments: [AttachmentMetadata]
        var timestamp: String
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
        var isBodyCompacted: Bool = false
        var bodyPreview: String = ""

        var bodyLines: [String] {
            (plainBody.isEmpty ? htmlBody : plainBody).components(separatedBy: .newlines)
        }

        var fullText: String {
            let headerStr = headers.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
            return headerStr + "\n\n" + (plainBody.isEmpty ? htmlBody : plainBody)
        }

        private enum CodingKeys: String, CodingKey {
            case id, headers, rawSource, messageType, attachments, timestamp
            case domains, plainBody, htmlBody, mimeRoot, mimeSummary
            case mimeDiagnostics, threadID, inReplyTo, references, tags, anomalies
            case bodyLines, fullText, isBodyCompacted, bodyPreview
        }

        init(id: UUID = UUID(), headers: [String: String], bodyLines: [String] = [], rawSource: String, messageType: String, attachments: [AttachmentMetadata], timestamp: String, fullText: String = "", domains: [String], plainBody: String, htmlBody: String, mimeRoot: MIMEPart? = nil, mimeSummary: String? = nil, mimeDiagnostics: [String] = [], threadID: String? = nil, inReplyTo: String? = nil, references: [String]? = nil, tags: [String] = [], anomalies: [String] = []) {
            self.id = id
            self.headers = headers
            self.rawSource = rawSource
            self.messageType = messageType
            self.attachments = attachments
            self.timestamp = timestamp
            self.domains = domains
            self.plainBody = plainBody
            self.htmlBody = htmlBody
            self.mimeRoot = mimeRoot
            self.mimeSummary = mimeSummary
            self.mimeDiagnostics = mimeDiagnostics
            self.threadID = threadID
            self.inReplyTo = inReplyTo
            self.references = references
            self.tags = tags
            self.anomalies = anomalies
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
            rawSource = try container.decodeIfPresent(String.self, forKey: .rawSource) ?? ""
            messageType = try container.decodeIfPresent(String.self, forKey: .messageType) ?? "received"
            attachments = try container.decodeIfPresent([AttachmentMetadata].self, forKey: .attachments) ?? []
            timestamp = try container.decodeIfPresent(String.self, forKey: .timestamp) ?? ""
            domains = try container.decodeIfPresent([String].self, forKey: .domains) ?? []
            plainBody = try container.decodeIfPresent(String.self, forKey: .plainBody) ?? ""
            htmlBody = try container.decodeIfPresent(String.self, forKey: .htmlBody) ?? ""
            mimeRoot = try container.decodeIfPresent(MIMEPart.self, forKey: .mimeRoot)
            mimeSummary = try container.decodeIfPresent(String.self, forKey: .mimeSummary)
            mimeDiagnostics = try container.decodeIfPresent([String].self, forKey: .mimeDiagnostics) ?? []
            threadID = try container.decodeIfPresent(String.self, forKey: .threadID)
            inReplyTo = try container.decodeIfPresent(String.self, forKey: .inReplyTo)
            references = try container.decodeIfPresent([String].self, forKey: .references)
            tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
            anomalies = try container.decodeIfPresent([String].self, forKey: .anomalies) ?? []
            isBodyCompacted = try container.decodeIfPresent(Bool.self, forKey: .isBodyCompacted) ?? false
            bodyPreview = try container.decodeIfPresent(String.self, forKey: .bodyPreview) ?? ""
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(headers, forKey: .headers)
            try container.encode(rawSource, forKey: .rawSource)
            try container.encode(messageType, forKey: .messageType)
            try container.encode(attachments, forKey: .attachments)
            try container.encode(timestamp, forKey: .timestamp)
            try container.encode(domains, forKey: .domains)
            try container.encode(plainBody, forKey: .plainBody)
            try container.encode(htmlBody, forKey: .htmlBody)
            try container.encodeIfPresent(mimeRoot, forKey: .mimeRoot)
            try container.encodeIfPresent(mimeSummary, forKey: .mimeSummary)
            try container.encode(mimeDiagnostics, forKey: .mimeDiagnostics)
            try container.encodeIfPresent(threadID, forKey: .threadID)
            try container.encodeIfPresent(inReplyTo, forKey: .inReplyTo)
            try container.encodeIfPresent(references, forKey: .references)
            try container.encode(tags, forKey: .tags)
            try container.encode(anomalies, forKey: .anomalies)
            try container.encode(isBodyCompacted, forKey: .isBodyCompacted)
            try container.encode(bodyPreview, forKey: .bodyPreview)
        }

        mutating func compact() {
            guard !isBodyCompacted else { return }
            let body = plainBody.isEmpty ? htmlBody : plainBody
            bodyPreview = String(body.prefix(200))
            plainBody = ""
            htmlBody = ""
            rawSource = ""
            mimeRoot = nil
            mimeSummary = nil
            mimeDiagnostics = []
            isBodyCompacted = true
        }
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

    struct ParseRecoveryReport {
        let totalMessages: Int
        let successfullyParsed: Int
        let failed: Int
        var errorCategories: [String: Int]

        var hasDamage: Bool { failed > 0 }
        var summaryText: String {
            if !hasDamage { return "All \(totalMessages) emails parsed successfully." }
            var text = "Recovered \(successfullyParsed) of \(totalMessages) emails (\(failed) damaged)."
            if !errorCategories.isEmpty {
                let cats = errorCategories.sorted { $0.value > $1.value }.map { "\($0.key): \($0.value)" }
                text += " Errors: \(cats.joined(separator: ", "))"
            }
            return text
        }
    }

    static var lastRecoveryReport: ParseRecoveryReport?

    static func parse(
        fileURL: URL,
        senderEmail: String,
        onProgress: ((Double) -> Void)? = nil
    ) throws -> [RawEmail] {
        let content = try FileUtils.readTextFile(url: fileURL)
        let rawMessages = splitMBOX(content: content)
        var parsedEmails: [RawEmail] = []
        let total = Double(rawMessages.count)

        var recoveryErrors = 0
        var errorCategories: [String: Int] = [:]
        for (idx, raw) in rawMessages.enumerated() {
            do {
                let email = try processRawMessage(raw, senderEmail: senderEmail)
                parsedEmails.append(email)
            } catch {
                recoveryErrors += 1
                let category = categorizeParseError(error, rawSnippet: String(raw.prefix(200)))
                errorCategories[category, default: 0] += 1
            }

            if let onProgress = onProgress, total > 0 {
                let progress = Double(idx + 1) / total
                onProgress(progress)
            }
        }

        lastRecoveryReport = ParseRecoveryReport(
            totalMessages: rawMessages.count,
            successfullyParsed: parsedEmails.count,
            failed: recoveryErrors,
            errorCategories: errorCategories
        )

        let summary = summarize(emails: parsedEmails)
        try saveSessionJSON(exportable: ExportableParsedMBOXFile(emails: parsedEmails.map { $0.asExportable() }, summary: summary))
        return parsedEmails
    }

    private static func categorizeParseError(_ error: Error, rawSnippet: String) -> String {
        let desc = String(describing: error).lowercased()
        if desc.contains("encoding") || desc.contains("utf") || desc.contains("ascii") { return "encoding" }
        if desc.contains("mime") || desc.contains("content-type") { return "mime" }
        let lower = rawSnippet.lowercased()
        if !lower.contains("from:") && !lower.contains("subject:") { return "missing_headers" }
        if rawSnippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "empty_message" }
        return "unknown"
    }

    // MARK: - Streaming Parser for Large Files
    private static let compactionBatchSize = 5000

    static func parseStreaming(
        fileURL: URL,
        senderEmail: String,
        onProgress: ((Double) -> Void)? = nil
    ) throws -> [RawEmail] {
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attrs[.size] as? Int64) ?? 0
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        let chunkSize = 65536
        var buffer = Data()
        var eof = false
        var currentLines: [String] = []
        var failedCount = 0
        var inMessage = false
        var parsedEmails: [RawEmail] = []
        var lastCompactionIndex = 0

        func nextLine() -> String? {
            while true {
                if let nlRange = buffer.range(of: Data([0x0A])) {
                    let lineData = buffer[buffer.startIndex..<nlRange.lowerBound]
                    buffer.removeSubrange(buffer.startIndex...nlRange.lowerBound)
                    return String(data: lineData, encoding: .utf8)
                        ?? String(data: lineData, encoding: .isoLatin1)
                }
                if eof {
                    if buffer.isEmpty { return nil }
                    let rest = String(data: buffer, encoding: .utf8)
                        ?? String(data: buffer, encoding: .isoLatin1)
                    buffer.removeAll()
                    return rest
                }
                let chunk = try? handle.read(upToCount: chunkSize)
                if let chunk, !chunk.isEmpty {
                    buffer.append(chunk)
                } else {
                    eof = true
                }
            }
        }

        func compactIfNeeded() {
            let newCount = parsedEmails.count
            guard newCount - lastCompactionIndex >= compactionBatchSize else { return }
            let (_, pressure) = ContentViewModel.checkMemoryPressure()
            guard pressure != .normal else { return }

            let rangeToCompact = lastCompactionIndex..<newCount
            let batch = Array(parsedEmails[rangeToCompact])
            EmailPersistence.persistBodies(batch)
            for i in rangeToCompact {
                parsedEmails[i].compact()
            }
            lastCompactionIndex = newCount
        }

        func flushCurrentMessage() {
            guard !currentLines.isEmpty else { return }
            let raw = currentLines.joined(separator: "\n")
            do {
                let email = try processRawMessage(raw, senderEmail: senderEmail)
                parsedEmails.append(email)
            } catch {
                failedCount += 1
            }

            if fileSize > 0, let onProgress = onProgress {
                let offset = Double((try? handle.offset()) ?? 0)
                let progress = min(offset / Double(fileSize), 1.0)
                onProgress(progress)
            }

            compactIfNeeded()
        }

        while let line = nextLine() {
            let isFromLine = line.hasPrefix("From ") && line.count > 5
                && line.range(of: #"\d{4}"#, options: .regularExpression) != nil
            if isFromLine {
                if inMessage {
                    flushCurrentMessage()
                    currentLines = []
                }
                inMessage = true
            } else if inMessage {
                currentLines.append(line)
            }
        }
        flushCurrentMessage()

        let summary = summarize(emails: parsedEmails)
        try saveSessionJSON(exportable: ExportableParsedMBOXFile(emails: parsedEmails.map { $0.asExportable() }, summary: summary))
        return parsedEmails
    }

    // MARK: - Streaming Pipeline (callback per batch — no array accumulation)

    /// Drain-as-you-go variant of `parseStreaming`. Instead of returning
    /// `[RawEmail]`, the parser flushes batches of `batchSize` messages to
    /// `onBatch` and immediately frees them, so peak memory is bounded by
    /// `batchSize`, not by the source file size. Use this for archives that
    /// would otherwise exceed available RAM (Gmail Takeout 200 GB+ mbox).
    ///
    /// Returns the total number of messages successfully parsed.
    static func parseStreamingCallback(
        fileURL: URL,
        senderEmail: String,
        batchSize: Int = 200,
        onProgress: ((Double) -> Void)? = nil,
        onBatch: ([RawEmail]) async throws -> Void
    ) async throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attrs[.size] as? Int64) ?? 0
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        let chunkSize = 65536
        var buffer = Data()
        var eof = false
        var currentLines: [String] = []
        var inMessage = false
        var totalParsed = 0
        var batch: [RawEmail] = []
        batch.reserveCapacity(batchSize)

        func nextLine() -> String? {
            while true {
                if let nlRange = buffer.range(of: Data([0x0A])) {
                    let lineData = buffer[buffer.startIndex..<nlRange.lowerBound]
                    buffer.removeSubrange(buffer.startIndex...nlRange.lowerBound)
                    return String(data: lineData, encoding: .utf8)
                        ?? String(data: lineData, encoding: .isoLatin1)
                }
                if eof {
                    if buffer.isEmpty { return nil }
                    let rest = String(data: buffer, encoding: .utf8)
                        ?? String(data: buffer, encoding: .isoLatin1)
                    buffer.removeAll()
                    return rest
                }
                let chunk = try? handle.read(upToCount: chunkSize)
                if let chunk, !chunk.isEmpty {
                    buffer.append(chunk)
                } else {
                    eof = true
                }
            }
        }

        func flushBatchIfFull() async throws {
            guard batch.count >= batchSize else { return }
            try await onBatch(batch)
            totalParsed += batch.count
            batch.removeAll(keepingCapacity: true)
        }

        func flushCurrentMessage() {
            guard !currentLines.isEmpty else { return }
            let raw = currentLines.joined(separator: "\n")
            do {
                let email = try processRawMessage(raw, senderEmail: senderEmail)
                batch.append(email)
            } catch {
                // Skipped on parse error; counted neither toward batch nor total.
            }
            if fileSize > 0, let onProgress {
                let offset = Double((try? handle.offset()) ?? 0)
                onProgress(min(offset / Double(fileSize), 1.0))
            }
        }

        while let line = nextLine() {
            try Task.checkCancellation()
            let isFromLine = line.hasPrefix("From ") && line.count > 5
                && line.range(of: #"\d{4}"#, options: .regularExpression) != nil
            if isFromLine {
                if inMessage {
                    flushCurrentMessage()
                    currentLines = []
                    try await flushBatchIfFull()
                }
                inMessage = true
            } else if inMessage {
                currentLines.append(line)
            }
        }
        flushCurrentMessage()

        if !batch.isEmpty {
            try await onBatch(batch)
            totalParsed += batch.count
            batch.removeAll(keepingCapacity: true)
        }
        return totalParsed
    }

    // MARK: - Per-Email Processing
    static func processRawMessage(_ raw: String, senderEmail: String) throws -> RawEmail {
        let fullRaw = raw.hasPrefix("From ") ? raw : "From " + raw
        let (headers, mimeParts) = MIMEParser.parseEmail(rawEmail: fullRaw)
        let rootPart = mimeParts.first
        let extraction: (plainBody: String, htmlBody: String, attachments: [AttachmentMetadata])
        do {
            extraction = try EmailBodyExtractor.extractContents(from: fullRaw)
        } catch {
            let bodyLines = fullRaw.components(separatedBy: "\n")
            let blankIdx = bodyLines.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? 0
            let rawBody = bodyLines.dropFirst(blankIdx + 1).joined(separator: "\n")
            extraction = (plainBody: rawBody, htmlBody: "", attachments: [])
        }

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
        let type = !senderEmail.isEmpty && from.lowercased().contains(senderEmail.lowercased()) ? "sent" : "received"

        let timestamp = parseDate(mappedHeaders["Date"]).map { cachedISOFormatter.string(from: $0) } ?? "1970-01-01T00:00:00Z"
        let domains = extractDomains(from: mappedHeaders)

        var tags: [String] = []
        if let gmailLabels = mappedHeaders["X-Gmail-Labels"] ?? mappedHeaders["X-gmail-labels"] {
            tags = gmailLabels.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        return RawEmail(
            id: UUID(),
            headers: mappedHeaders,
            rawSource: fullRaw,
            messageType: type,
            attachments: extraction.attachments,
            timestamp: timestamp,
            domains: domains,
            plainBody: extraction.plainBody,
            htmlBody: extraction.htmlBody,
            mimeRoot: rootPart,
            mimeSummary: rootPart?.summary,
            mimeDiagnostics: generateMIMEDiagnostics(root: rootPart),
            threadID: detectThreadID(headers: mappedHeaders, plainBody: extraction.plainBody, htmlBody: extraction.htmlBody),
            inReplyTo: mappedHeaders["In-Reply-To"],
            references: mappedHeaders["References"]?.split(separator: " ").map { String($0) },
            tags: tags,
            anomalies: findAnomalies(headers: mappedHeaders, body: extraction.plainBody, attachments: extraction.attachments)
        )
    }

    static func saveSessionJSON(exportable parsed: ExportableParsedMBOXFile) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(parsed)

        guard let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "MBOXParser", code: 1, userInfo: [NSLocalizedDescriptionKey: "Application Support directory not found"])
        }
        let folder = supportDir.appendingPathComponent("mailin", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let output = folder.appendingPathComponent("parsed_session.json")
        try FileUtils.writeData(data, to: output.path)
    }

    static func summarize(emails: [RawEmail]) -> SummaryMetadata {
        let dates = emails.compactMap { parseDate($0.headers["Date"]) }.sorted()
        let subjects = Set(emails.compactMap { $0.headers["Subject"]?.trimmingCharacters(in: .whitespacesAndNewlines) }).filter { !$0.isEmpty }
        let start = dates.first.map { cachedISOFormatter.string(from: $0) } ?? "N/A"
        let end = dates.last.map { cachedISOFormatter.string(from: $0) } ?? "N/A"
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
        return parts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
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
        if let msgID = headers["Message-ID"] ?? headers["Message-Id"], !msgID.isEmpty {
            return msgID
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
                let bytes = decodeQuotedPrintableBytes(encodedText)
                decoded = decodeWithCharset(data: bytes, charset: charset) ?? encodedText
            }
            result = (result as NSString).replacingCharacters(in: match.range, with: decoded)
        }
        return result
    }

    static func decodeQuotedPrintableBytes(_ input: String) -> Data {
        var raw = input.replacingOccurrences(of: "_", with: " ")
        raw = raw.replacingOccurrences(of: "=\r\n", with: "")
        raw = raw.replacingOccurrences(of: "=\n", with: "")
        var output = Data()
        var i = raw.startIndex
        while i < raw.endIndex {
            let ch = raw[i]
            if ch == "=",
               let h1 = raw.index(i, offsetBy: 1, limitedBy: raw.endIndex),
               let h2 = raw.index(i, offsetBy: 2, limitedBy: raw.endIndex),
               h2 < raw.endIndex {
                let hex = String(raw[h1...h2])
                if let byte = UInt8(hex, radix: 16) {
                    output.append(byte)
                    i = raw.index(i, offsetBy: 3)
                    continue
                }
            }
            if let ascii = ch.asciiValue {
                output.append(ascii)
            } else if let utf8 = String(ch).data(using: .utf8) {
                output.append(contentsOf: utf8)
            }
            i = raw.index(after: i)
        }
        return output
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
        case "iso-8859-1", "latin1", "latin-1": encoding = .isoLatin1
        case "iso-8859-2", "latin2", "latin-2": encoding = .isoLatin2
        case "us-ascii", "ascii": encoding = .ascii
        case "windows-1252", "cp1252": encoding = .windowsCP1252
        case "windows-1251", "cp1251":
            encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.windowsCyrillic.rawValue)))
        case "shift_jis", "shift-jis", "sjis": encoding = .shiftJIS
        case "euc-jp": encoding = .japaneseEUC
        case "iso-2022-jp": encoding = .iso2022JP
        default:
            let cfEnc = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            if cfEnc != kCFStringEncodingInvalidId {
                encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEnc))
            } else {
                encoding = .utf8
            }
        }
        return String(data: data, encoding: encoding)
    }

    private static let cachedISOFormatter = ISO8601DateFormatter()

    private static let dateFormats = [
        "EEE, dd MMM yyyy HH:mm:ss Z",
        "E, d MMM yyyy HH:mm:ss Z",
        "d MMM yyyy HH:mm:ss Z",
        "yyyy-MM-dd'T'HH:mm:ssZ",
        "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
        "EEE, dd MMM yyyy HH:mm:ss zzz",
        "E, d MMM yyyy HH:mm:ss zzz",
        "EEE, dd MMM yyyy HH:mm Z",
        "E, d MMM yyyy HH:mm Z",
        "EEE MMM d HH:mm:ss yyyy",
        "dd MMM yyyy HH:mm:ss",
        "yyyy-MM-dd HH:mm:ss"
    ]

    private static let dateFormatterQueue = DispatchQueue(label: "com.mailin.dateFormatter")

    private static let threadLocalFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func parseDate(_ raw: String?) -> Date? {
        guard var cleaned = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !cleaned.isEmpty else { return nil }
        if let parenRange = cleaned.range(of: #"\s*\([^)]*\)\s*$"#, options: .regularExpression) {
            cleaned = String(cleaned[cleaned.startIndex..<parenRange.lowerBound])
        }
        return dateFormatterQueue.sync {
            for format in dateFormats {
                threadLocalFormatter.dateFormat = format
                if let date = threadLocalFormatter.date(from: cleaned) {
                    return date
                }
            }
            return cachedISOFormatter.date(from: cleaned)
        }
    }

    static func extractDomains(from headers: [String: String]) -> [String] {
        var domains = Set<String>()
        let stripChars = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "<>\""))
        ["From", "To", "Cc", "Bcc"].forEach { key in
            guard let line = headers[key] else { return }
            for part in line.split(separator: ",") {
                if let at = part.firstIndex(of: "@") {
                    let domain = part[at...].dropFirst().trimmingCharacters(in: stripChars)
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
