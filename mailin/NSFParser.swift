import Foundation
import os

struct NSFParser {
    private static let logger = Logger(subsystem: "com.mailin", category: "NSFParser")

    static func parse(
        fileURL: URL,
        senderEmail: String,
        onProgress: ((Double) -> Void)? = nil
    ) throws -> [MBOXParser.RawEmail] {
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = attrs[.size] as? Int64 ?? 0
        if fileSize > 4_000_000_000 {
            throw NSFError.fileTooLarge(fileSize)
        }
        if fileSize < 256 {
            throw NSFError.invalidFormat("File too small for NSF format")
        }

        let data = try Data(contentsOf: fileURL)
        let reader = NSFReader(data: data)
        let notes = try reader.readNotes(onProgress: onProgress)

        var emails: [MBOXParser.RawEmail] = []
        let total = Double(notes.count)

        for (idx, note) in notes.enumerated() {
            if let email = buildEmail(from: note, senderEmail: senderEmail) {
                emails.append(email)
            }
            onProgress?(Double(idx + 1) / max(total, 1))
        }

        logger.info("Parsed \(emails.count) emails from NSF file (\(notes.count) notes total)")
        return emails
    }

    private static func buildEmail(from note: NSFNote, senderEmail: String) -> MBOXParser.RawEmail? {
        guard note.isMailNote else { return nil }

        let from = note.items["From"] ?? note.items["$From"] ?? note.items["SMTPOriginator"] ?? ""
        let to = note.items["SendTo"] ?? note.items["EnterSendTo"] ?? ""
        let cc = note.items["CopyTo"] ?? note.items["EnterCopyTo"] ?? ""
        let bcc = note.items["BlindCopyTo"] ?? ""
        let subject = note.items["Subject"] ?? "(No Subject)"
        let body = note.items["Body"] ?? ""
        let deliveredDate = note.items["DeliveredDate"] ?? note.items["PostedDate"] ?? ""
        let messageID = note.items["$MessageID"] ?? note.items["UNID"] ?? UUID().uuidString

        let isoFormatter = ISO8601DateFormatter()
        let timestamp: String
        if let parsedDate = parseNotesDate(deliveredDate) {
            timestamp = isoFormatter.string(from: parsedDate)
        } else if !deliveredDate.isEmpty {
            timestamp = deliveredDate
        } else {
            timestamp = isoFormatter.string(from: Date.distantPast)
        }

        var headers: [String: String] = [
            "From": from,
            "To": to,
            "Subject": subject,
            "Date": timestamp,
            "Message-ID": messageID
        ]
        if !cc.isEmpty { headers["Cc"] = cc }
        if !bcc.isEmpty { headers["Bcc"] = bcc }
        if let inReplyTo = note.items["$Ref"] { headers["In-Reply-To"] = inReplyTo }
        if let form = note.items["Form"] { headers["X-Notes-Form"] = form }
        headers["X-Source-Format"] = "NSF"

        let messageType: String
        if !senderEmail.isEmpty && from.lowercased().contains(senderEmail.lowercased()) {
            messageType = "sent"
        } else {
            messageType = "received"
        }

        let bodyLines = body.components(separatedBy: .newlines)
        let fullText = headers.map { "\($0.key): \($0.value)" }.joined(separator: "\n") + "\n\n" + body
        let domains = MBOXParser.extractDomains(from: headers)

        let htmlBody = note.items["$HtmlBody"] ?? note.items["Body_HTML"] ?? ""

        return MBOXParser.RawEmail(
            id: UUID(),
            headers: headers,
            bodyLines: bodyLines,
            rawSource: fullText,
            messageType: messageType,
            attachments: note.attachments,
            timestamp: timestamp,
            fullText: fullText,
            domains: domains,
            plainBody: body,
            htmlBody: htmlBody,
            mimeRoot: nil,
            mimeSummary: nil,
            mimeDiagnostics: [],
            threadID: messageID,
            inReplyTo: headers["In-Reply-To"],
            references: nil,
            tags: note.categories,
            anomalies: []
        )
    }

    private static func parseNotesDate(_ dateStr: String) -> Date? {
        if dateStr.isEmpty { return nil }

        let formatters: [String] = [
            "MM/dd/yyyy hh:mm:ss a",
            "yyyy-MM-dd'T'HH:mm:ss",
            "MM/dd/yyyy HH:mm:ss",
            "dd/MM/yyyy HH:mm:ss",
            "yyyy/MM/dd HH:mm:ss",
            "EEE, dd MMM yyyy HH:mm:ss Z"
        ]

        for format in formatters {
            let formatter = DateFormatter()
            formatter.dateFormat = format
            formatter.locale = Locale(identifier: "en_US_POSIX")
            if let date = formatter.date(from: dateStr) {
                return date
            }
        }

        let iso = ISO8601DateFormatter()
        return iso.date(from: dateStr)
    }

    enum NSFError: LocalizedError {
        case invalidFormat(String)
        case fileTooLarge(Int64)
        case unsupportedVersion(Int)
        case corruptDatabase(String)
        case noEmailsFound

        var errorDescription: String? {
            switch self {
            case .invalidFormat(let reason):
                return "Invalid NSF format: \(reason)"
            case .fileTooLarge(let size):
                return "NSF file is too large (\(size / 1_000_000) MB). Maximum supported size is 4 GB."
            case .unsupportedVersion(let ver):
                return "Unsupported NSF version: \(ver). Only NSF versions 2-5 are supported."
            case .corruptDatabase(let detail):
                return "Corrupt NSF database: \(detail)"
            case .noEmailsFound:
                return "No email notes found in NSF file"
            }
        }
    }
}

// MARK: - NSF Note Model

struct NSFNote {
    var items: [String: String] = [:]
    var attachments: [AttachmentMetadata] = []
    var categories: [String] = []

    var isMailNote: Bool {
        let form = (items["Form"] ?? "").lowercased()
        if form == "memo" || form == "reply" || form == "notice" || form.contains("mail") {
            return true
        }
        if items["From"] != nil || items["$From"] != nil || items["SMTPOriginator"] != nil {
            if items["SendTo"] != nil || items["EnterSendTo"] != nil || items["Subject"] != nil {
                return true
            }
        }
        return false
    }
}

// MARK: - NSF Binary Reader

struct NSFReader {
    private let data: Data
    private static let logger = Logger(subsystem: "com.mailin", category: "NSFReader")

    private static let maxNotes = 500_000

    init(data: Data) {
        self.data = data
    }

    func readNotes(onProgress: ((Double) -> Void)? = nil) throws -> [NSFNote] {
        guard data.count >= 256 else {
            throw NSFParser.NSFError.invalidFormat("File too small")
        }

        let signature = readUInt16(at: 0)
        // NSF signature: 0x1A00 is most common, but some files use other variants
        let validSignatures: Set<UInt16> = [0x001A, 0x1A00, 0x0000]
        guard validSignatures.contains(signature) || isLikelyNSF() else {
            throw NSFParser.NSFError.invalidFormat("Not a valid NSF file (signature: 0x\(String(format: "%04X", signature)))")
        }

        // Try structured binary parse first, fall back to scan-based extraction
        if let notes = try? parseStructured(onProgress: onProgress), !notes.isEmpty {
            return notes
        }

        return try parseByScan(onProgress: onProgress)
    }

    private func isLikelyNSF() -> Bool {
        guard data.count > 100 else { return false }
        let headerChunk = String(data: data[0..<min(512, data.count)], encoding: .ascii) ?? ""
        return headerChunk.contains("NSF") || headerChunk.contains("Notes") || headerChunk.contains("Lotus")
    }

    // MARK: - Structured Parse (NSF Database Header)

    private func parseStructured(onProgress: ((Double) -> Void)? = nil) throws -> [NSFNote] {
        guard data.count >= 0x2C else {
            throw NSFParser.NSFError.invalidFormat("Header too small for structured parse")
        }

        // NSF database header layout (offsets are approximate — vary by version):
        // Bytes 0-1: Signature
        // Bytes 2-5: Database size or flags
        // Bytes 6-41: Title (null-terminated)
        // After header: RRV (Record Relocation Vector) bucket table → note records

        // Read database info block offset (typically at offset 0x28)
        let dbInfoOffset: Int
        if data.count > 0x30 {
            dbInfoOffset = Int(readUInt32(at: 0x28))
        } else {
            dbInfoOffset = 0
        }

        // Scan for note record headers in the database
        // Notes in NSF are identified by NOTE_CLASS flags
        // Mail notes have NOTE_CLASS = 0x0001 (DOCUMENT)
        var notes: [NSFNote] = []
        var offset = max(dbInfoOffset, 256)
        let totalBytes = Double(data.count)
        var consecutiveFailures = 0
        let maxConsecutiveFailures = 100_000

        while offset < data.count - 64 && notes.count < Self.maxNotes && consecutiveFailures < maxConsecutiveFailures {
            if let (note, nextOffset) = try? readNoteRecord(at: offset) {
                notes.append(note)
                offset = nextOffset
                consecutiveFailures = 0
            } else {
                offset += 1
                consecutiveFailures += 1
            }

            if notes.count % 100 == 0 {
                onProgress?(Double(offset) / totalBytes * 0.9)
            }
        }

        return notes
    }

    private func readNoteRecord(at offset: Int) throws -> (NSFNote, Int)? {
        guard offset + 32 <= data.count else { return nil }

        // Look for item-name patterns that indicate a note record boundary
        // Notes items start with item header: Type(2) + NameLength(2) + ValueLength(4) + ...
        let itemType = readUInt16(at: offset)

        // Valid NSF item types: TYPE_TEXT=0x0500, TYPE_NUMBER=0x0300,
        // TYPE_TIME=0x0400, TYPE_COMPOSITE=0x0100, TYPE_TEXT_LIST=0x0501
        let validItemTypes: Set<UInt16> = [
            0x0500, 0x0501, 0x0300, 0x0400, 0x0100,
            0x0005, 0x0105, 0x0003, 0x0004, 0x0001,
        ]

        guard validItemTypes.contains(itemType) || validItemTypes.contains(itemType.byteSwapped) else {
            return nil
        }

        let nameLen = Int(readUInt16(at: offset + 2))
        guard nameLen > 0 && nameLen < 256 else { return nil }

        guard offset + 8 + nameLen <= data.count else { return nil }
        let valueLenRaw = Int(readUInt32(at: offset + 4))
        let maxValueLen = data.count - (offset + 8 + nameLen)
        let valueLen = min(valueLenRaw, maxValueLen)
        guard valueLen >= 0 && valueLen < 10_000_000 else { return nil }

        let nameStart = offset + 8
        guard let name = readLMBCSString(at: nameStart, length: nameLen) else { return nil }

        let knownNames: Set<String> = [
            "Form", "Subject", "Body", "From", "$From", "SendTo", "CopyTo",
            "BlindCopyTo", "DeliveredDate", "PostedDate", "$MessageID",
            "EnterSendTo", "EnterCopyTo", "Categories", "$Ref", "UNID",
            "$HtmlBody", "Body_HTML", "SMTPOriginator", "$FILE"
        ]

        guard knownNames.contains(name) || name.hasPrefix("$") || name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
            return nil
        }

        var note = NSFNote()
        var pos = offset

        while pos < data.count - 8 && note.items.count < 200 {
            guard let (itemName, itemValue, nextPos) = readItem(at: pos) else { break }

            if itemName == "$FILE" {
                if let attachment = parseAttachmentItem(value: itemValue) {
                    note.attachments.append(attachment)
                }
            } else if itemName == "Categories" {
                note.categories = itemValue.components(separatedBy: CharacterSet(charactersIn: ",;"))
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            } else {
                note.items[itemName] = itemValue
            }

            pos = nextPos

            // If we encounter "Form" again, we've hit the next note
            if itemName == "Form" && note.items.count > 1 {
                break
            }
        }

        guard !note.items.isEmpty else { return nil }
        return (note, pos)
    }

    private func readItem(at offset: Int) -> (String, String, Int)? {
        guard offset + 8 <= data.count else { return nil }

        let nameLen = Int(readUInt16(at: offset + 2))
        guard nameLen > 0 && nameLen < 256 else { return nil }

        guard offset + 8 + nameLen <= data.count else { return nil }
        let valueLenRaw = Int(readUInt32(at: offset + 4))
        let maxValueLen = data.count - (offset + 8 + nameLen)
        let valueLen = min(valueLenRaw, maxValueLen)
        guard valueLen >= 0 && valueLen < 10_000_000 else { return nil }

        let nameStart = offset + 8
        guard let name = readLMBCSString(at: nameStart, length: nameLen) else { return nil }

        let valueStart = nameStart + nameLen
        guard valueStart + valueLen <= data.count else { return nil }

        let value: String
        if valueLen > 0 {
            let valueData = data[valueStart..<(valueStart + valueLen)]
            value = String(data: valueData, encoding: .utf8)
                ?? String(data: valueData, encoding: .isoLatin1)
                ?? ""
        } else {
            value = ""
        }

        return (name, value.trimmingCharacters(in: .controlCharacters), valueStart + valueLen)
    }

    // MARK: - Scan-Based Parse (Fallback)

    private func parseByScan(onProgress: ((Double) -> Void)? = nil) throws -> [NSFNote] {
        // Scan the raw bytes for recognizable email-like text patterns
        // This is a fallback for NSF files where the structured parse fails
        var notes: [NSFNote] = []

        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? String(data: data, encoding: .windowsCP1252) else {
            throw NSFParser.NSFError.invalidFormat("Cannot decode file content")
        }

        // Split on "Form" field boundaries, which delimit notes in raw text scans
        let noteBlocks = extractNoteBlocks(from: text)
        let total = Double(noteBlocks.count)

        for (idx, block) in noteBlocks.enumerated() {
            var note = NSFNote()
            let lines = block.components(separatedBy: .newlines)

            for line in lines {
                if let (key, value) = parseFieldLine(line) {
                    if key == "Categories" {
                        note.categories = value.components(separatedBy: CharacterSet(charactersIn: ",;"))
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                    } else {
                        note.items[key] = value
                    }
                }
            }

            if note.isMailNote {
                notes.append(note)
            }

            if idx % 50 == 0 {
                onProgress?(Double(idx) / max(total, 1))
            }
        }

        if notes.isEmpty {
            // Last resort: try to find any email-like content with regex patterns
            let emailPattern = try? NSRegularExpression(
                pattern: "(?:From|Subject|To|SendTo)\\s*[:=]\\s*[^\\x00-\\x08\\x0E-\\x1F]{3,}",
                options: [.caseInsensitive]
            )
            if let matches = emailPattern?.matches(in: text, range: NSRange(text.startIndex..., in: text)),
               !matches.isEmpty {
                Self.logger.info("Found \(matches.count) potential email fields via regex scan")
            }
        }

        return notes
    }

    private func extractNoteBlocks(from text: String) -> [String] {
        var blocks: [String] = []
        var currentBlock = ""
        var foundFirstForm = false

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isFormBoundary = trimmed.hasPrefix("Form") &&
                (trimmed.contains(":") || trimmed.contains("=")) &&
                (trimmed.lowercased().contains("memo") || trimmed.lowercased().contains("reply") ||
                 trimmed.lowercased().contains("notice") || trimmed.lowercased().contains("mail"))

            if isFormBoundary {
                if foundFirstForm && !currentBlock.isEmpty {
                    blocks.append(currentBlock)
                }
                currentBlock = line + "\n"
                foundFirstForm = true
            } else if foundFirstForm {
                currentBlock += line + "\n"
            }
        }
        if !currentBlock.isEmpty {
            blocks.append(currentBlock)
        }
        return blocks
    }

    private func parseFieldLine(_ line: String) -> (String, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let separators: [Character] = [":", "="]
        for sep in separators {
            if let idx = trimmed.firstIndex(of: sep) {
                let key = String(trimmed[trimmed.startIndex..<idx]).trimmingCharacters(in: .whitespaces)
                let value = String(trimmed[trimmed.index(after: idx)...]).trimmingCharacters(in: .whitespaces)

                let knownFields: Set<String> = [
                    "Form", "Subject", "Body", "From", "$From", "SendTo", "CopyTo",
                    "BlindCopyTo", "DeliveredDate", "PostedDate", "$MessageID",
                    "EnterSendTo", "EnterCopyTo", "Categories", "$Ref",
                    "$HtmlBody", "Body_HTML", "SMTPOriginator", "UNID"
                ]

                if knownFields.contains(key) && !value.isEmpty {
                    return (key, value)
                }
            }
        }
        return nil
    }

    // MARK: - Attachment Parsing

    private func parseAttachmentItem(value: String) -> AttachmentMetadata? {
        guard !value.isEmpty else { return nil }
        let filename = value.components(separatedBy: CharacterSet(charactersIn: "/\\")).last ?? value
        guard !filename.isEmpty else { return nil }

        let ext = (filename as NSString).pathExtension.lowercased()
        let mimeType: String
        switch ext {
        case "pdf": mimeType = "application/pdf"
        case "doc", "docx": mimeType = "application/msword"
        case "xls", "xlsx": mimeType = "application/vnd.ms-excel"
        case "ppt", "pptx": mimeType = "application/vnd.ms-powerpoint"
        case "jpg", "jpeg": mimeType = "image/jpeg"
        case "png": mimeType = "image/png"
        case "gif": mimeType = "image/gif"
        case "txt": mimeType = "text/plain"
        case "html", "htm": mimeType = "text/html"
        case "zip": mimeType = "application/zip"
        default: mimeType = "application/octet-stream"
        }

        return AttachmentMetadata(
            filename: filename.trimmingCharacters(in: .controlCharacters),
            mimeType: mimeType,
            size: 0,
            isInline: false,
            contentID: nil,
            base64: nil,
            fileURL: nil
        )
    }

    // MARK: - Binary Helpers

    // LMBCS (Lotus Multi-Byte Character Set) — simplified as ASCII/Latin1 for common cases
    private func readLMBCSString(at offset: Int, length: Int) -> String? {
        guard offset + length <= data.count else { return nil }
        let slice = data[offset..<(offset + length)]
        return (String(data: slice, encoding: .utf8) ?? String(data: slice, encoding: .isoLatin1))?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
    }

    private func readUInt16(at offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private func readUInt32(at offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8) |
               (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }
}
