import Foundation

struct MSGParser {
    /// Bump when message extraction/ordering changes — invalidates mid-file
    /// resume checkpoints bound to the previous version (Part B5).
    /// 2 (§13.8 step 3): directory ids read in the spec's order, v4 sector
    /// offsets, embedded messages expanded, .oft routed here.
    static let parserVersion = 2

    static func parse(
        fileURL: URL,
        senderEmail: String,
        onProgress: ((Double) -> Void)? = nil
    ) throws -> [MBOXParser.RawEmail] {
        let email = try parseSingleMSG(fileURL: fileURL, senderEmail: senderEmail)
        onProgress?(1.0)
        return [email]
    }

    /// Messages embedded in messages are expanded at every level (plan v4
    /// §13.8 step 3). R5b (owner 2026-11-08: "there should be no limit at
    /// all"): the former fixed depth of 3 kept a deeper message only by name,
    /// with none of its bytes. A storage that contains itself (a damaged or
    /// hostile file) is the only stop: it is listed as the attachment it is.
    ///
    /// CLOSE-01: a .msg file is no longer read whole into memory, and the
    /// former 2,000,000,000-byte refusal is gone on the offset engine's path. The compound file is read
    /// through a file handle (`OLE2Reader(fileURL:)`): sectors, the FAT, the
    /// mini FAT and the mini stream are read as they are needed. A file above
    /// the offset engine's full-parse ceiling is imported by
    /// `OffsetImportEngine.importLargeSingleMessage`, which streams its bodies
    /// and attachments into a rendered RFC 5322 file in bounded memory.
    ///
    /// The in-memory reader still holds the message's bodies and attachments
    /// whole, so above `WholeMessageReadLimit.msgBytes` it refuses the file
    /// by name (the previous engine's ceiling); the offset engine never calls
    /// it for a file above its full-parse ceiling.
    private static func parseSingleMSG(fileURL: URL, senderEmail: String) throws -> MBOXParser.RawEmail {
        try WholeMessageReadRefusal.check(fileURL, kind: .msg)
        let ole2 = try OLE2Reader(fileURL: fileURL)
        return try email(from: ole2, storage: 0, propertiesHeader: 32, depth: 0, ancestors: [0], senderEmail: senderEmail)
    }

    /// One Outlook message (or .oft template) from its bytes — also the path
    /// for a .msg that arrives as an attachment of another message.
    static func parse(data: Data, senderEmail: String = "") throws -> MBOXParser.RawEmail {
        let ole2 = try OLE2Reader(data: data)
        return try email(from: ole2, storage: 0, propertiesHeader: 32, depth: 0, ancestors: [0], senderEmail: senderEmail)
    }

    /// The message held in one storage of the compound file: the root (header
    /// 32 bytes) or an embedded message's `__substg1.0_3701000D` storage
    /// (header 24 bytes). Each embedded message becomes an attached message in
    /// RFC 5322 form, so its own attachments are read as children downstream.
    private static func email(from ole2: OLE2Reader, storage: Int, propertiesHeader: Int, depth: Int, ancestors: Set<Int>,
                              senderEmail: String) throws -> MBOXParser.RawEmail {
        let properties = try ole2.readMAPIProperties(storage: storage, propertiesHeader: propertiesHeader)

        let parts = messageHeaders(properties)
        let headers = parts.headers, from = parts.from, subject = parts.subject, timestamp = parts.timestamp
        let references = properties.stringProperty(.references)
        let body = properties.stringProperty(.body) ?? ""
        let htmlBodyData = properties.binaryProperty(.htmlBody)
        let htmlBody = htmlBodyData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let rtfBody = properties.binaryProperty(.rtfCompressed).flatMap { decompressRTF($0) } ?? ""

        let messageType = !senderEmail.isEmpty && from.lowercased().contains(senderEmail.lowercased()) ? "sent" : "received"

        let effectiveBody = !body.isEmpty ? body : (!htmlBody.isEmpty ? htmlBody : rtfBody)
        let domains = MBOXParser.extractDomains(from: headers)

        var attachments: [AttachmentMetadata] = []
        for record in try ole2.readAttachments(storage: storage) {
            if let embeddedStorage = record.embeddedMessageStorage {
                if !ancestors.contains(embeddedStorage),
                   let inner = try? email(from: ole2, storage: embeddedStorage, propertiesHeader: 24, depth: depth + 1,
                                          ancestors: ancestors.union([embeddedStorage]), senderEmail: senderEmail) {
                    let rendered = RFC822Renderer.render(inner)
                    let name = Self.attachedMessageName(subject: inner.headers["Subject"], fallback: record.metadata.filename)
                    attachments.append(AttachmentMetadata(filename: name, mimeType: "message/rfc822", size: rendered.count,
                                                          isInline: false, contentID: nil, base64: rendered.base64EncodedString(), fileURL: nil))
                } else {
                    // A storage inside itself, or unreadable: kept as the attachment it is, under Outlook's own type.
                    let name = record.metadata.filename == "attachment" ? "embedded-message.msg" : record.metadata.filename
                    attachments.append(AttachmentMetadata(filename: name, mimeType: "application/vnd.ms-outlook", size: 0,
                                                          isInline: false, contentID: nil, base64: nil, fileURL: nil))
                }
                continue
            }
            attachments.append(record.metadata)
        }

        let email = MBOXParser.RawEmail(
            id: UUID(),
            headers: headers,
            rawSource: "",
            messageType: messageType,
            attachments: attachments,
            timestamp: timestamp,
            domains: domains,
            plainBody: body,
            htmlBody: htmlBody,
            mimeRoot: nil,
            mimeSummary: nil,
            mimeDiagnostics: [],
            threadID: headers["Message-ID"] ?? MBOXParser.sha1("\(subject)\(from)\(timestamp)"),
            inReplyTo: headers["In-Reply-To"],
            references: references?.components(separatedBy: .whitespaces).filter { !$0.isEmpty },
            tags: [],
            anomalies: MBOXParser.findAnomalies(headers: headers, body: effectiveBody, attachments: attachments)
        )
        // The top-level message keeps a rendered raw source so its attachment
        // bytes survive the import; embedded ones are rendered by their parent.
        return depth == 0 ? email.withRenderedSource("Outlook .msg") : email
    }

    /// The RFC 5322 headers of one message storage, from its MAPI properties
    /// (shared by the in-memory reader and the streamed renderer, CLOSE-01).
    static func messageHeaders(_ properties: MAPIPropertySet) -> (headers: [String: String], from: String, subject: String, timestamp: String) {
        let senderAddr = properties.stringProperty(.senderEmailAddress)
            ?? properties.stringProperty(.senderSmtpAddress)
            ?? ""
        let senderName = properties.stringProperty(.senderName) ?? ""
        let from = !senderAddr.isEmpty ? (senderName.isEmpty ? senderAddr : "\(senderName) <\(senderAddr)>") : senderName

        let to = properties.stringProperty(.displayTo) ?? ""
        let cc = properties.stringProperty(.displayCc) ?? ""
        let bcc = properties.stringProperty(.displayBcc) ?? ""
        let subject = properties.stringProperty(.subject) ?? "(No Subject)"

        let dateValue = properties.dateProperty(.messageDeliveryTime)
            ?? properties.dateProperty(.clientSubmitTime)
            ?? properties.dateProperty(.creationTime)
            ?? Date.distantPast

        let isoFormatter = ISO8601DateFormatter()
        let timestamp = isoFormatter.string(from: dateValue)

        let replyTo = properties.stringProperty(.replyToAddress)
        let references = properties.stringProperty(.references)
        let conversationTopic = properties.stringProperty(.conversationTopic)
        let transportHeaders = properties.stringProperty(.transportMessageHeaders)
        let importance = properties.intProperty(.importance)
        let sensitivity = properties.intProperty(.sensitivity)

        var headers: [String: String] = [
            "From": from,
            "To": to,
            "Subject": subject,
            "Date": timestamp
        ]
        if !cc.isEmpty { headers["Cc"] = cc }
        if !bcc.isEmpty { headers["Bcc"] = bcc }
        if let messageID = properties.stringProperty(.internetMessageId) {
            headers["Message-ID"] = messageID
        }
        if let inReplyTo = properties.stringProperty(.inReplyToId) {
            headers["In-Reply-To"] = inReplyTo
        }
        if let replyTo { headers["Reply-To"] = replyTo }
        if let references { headers["References"] = references }
        if let conversationTopic { headers["Thread-Topic"] = conversationTopic }
        if let importance {
            headers["X-Priority"] = importance == 2 ? "1" : importance == 0 ? "5" : "3"
        }
        if let sensitivity {
            let labels = ["Normal", "Personal", "Private", "Confidential"]
            if sensitivity < labels.count { headers["Sensitivity"] = labels[Int(sensitivity)] }
        }

        if let transportHeaders {
            mergeTransportHeaders(transportHeaders, into: &headers)
        }

        return (headers, from, subject, timestamp)
    }

    /// "Subject.eml" for an embedded message, safe as a file name.
    static func attachedMessageName(subject: String?, fallback: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let base = (subject ?? "").components(separatedBy: illegal).joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = base.isEmpty ? (fallback == "attachment" ? "embedded-message" : fallback) : String(base.prefix(120))
        return name.lowercased().hasSuffix(".eml") ? name : name + ".eml"
    }

    private static func mergeTransportHeaders(_ raw: String, into headers: inout [String: String]) {
        var currentKey: String?
        var currentValue = ""
        for line in raw.components(separatedBy: "\r\n") {
            if line.isEmpty { continue }
            if let first = line.first, first == " " || first == "\t" {
                currentValue += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colonIdx = line.firstIndex(of: ":") {
                if let key = currentKey {
                    if headers[key] == nil {
                        headers[key] = currentValue.trimmingCharacters(in: .whitespaces)
                    }
                }
                currentKey = String(line[line.startIndex..<colonIdx])
                currentValue = String(line[line.index(after: colonIdx)...])
            }
        }
        if let key = currentKey, headers[key] == nil {
            headers[key] = currentValue.trimmingCharacters(in: .whitespaces)
        }
    }

    // MARK: - RTF Decompression (LZFu)

    /// Compressed RTF (MS-OXRTFCP) to its text; shared with the TNEF reader.
    static func decompressRTF(_ data: Data) -> String? {
        guard data.count >= 16 else { return nil }
        let compressedSize = readUInt32LE(data, offset: 0)
        let uncompressedSize = readUInt32LE(data, offset: 4)
        let magic = readUInt32LE(data, offset: 8)

        let lzfuMagic: UInt32 = 0x75465A4C // "LZFu"
        let melalMagic: UInt32 = 0x414C454D // "MELA" (uncompressed)

        // Widen to Int before adding: `compressedSize` is UInt32, so
        // `compressedSize + 4` can overflow-trap on a hostile RTF stream.
        guard Int(compressedSize) + 4 <= data.count else { return nil }
        // R5b: no fixed 10 MB ceiling. The declared size is only trusted as far
        // as the format allows: LZFu expands at most 17 output bytes per two input
        // bytes, so a larger claim is damage, not a large body.
        guard Int(uncompressedSize) <= Int(compressedSize) * 9 + 4_096 else { return nil }

        if magic == melalMagic {
            let start = 16
            let end = min(start + Int(uncompressedSize), data.count)
            guard start < end else { return nil }
            return String(data: data[start..<end], encoding: .ascii)
        }

        guard magic == lzfuMagic else { return nil }

        let prebuf = "{\\rtf1\\ansi\\mac\\deff0\\deftab720{\\fonttbl;}{\\f0\\fnil \\froman \\fswiss \\fmodern \\fscript \\fdecor MS Sans SerifSymbolArialTimes New RomanCourier{\\colortbl\\red0\\green0\\blue0\r\n\\par \\pard\\plain\\f0\\fs20\\b\\i\\u\\tab\\tx"
        var dict = Array(prebuf.utf8)
        dict.append(contentsOf: [UInt8](repeating: 0, count: max(0, 4096 - dict.count)))
        var dictWritePos = prebuf.utf8.count

        var output = Data()
        var pos = 16
        let endPos = min(Int(compressedSize) + 4, data.count)

        while pos < endPos && output.count < Int(uncompressedSize) {
            guard pos < data.count else { break }
            let control = data[pos]; pos += 1
            for bit in 0..<8 {
                guard pos < endPos && output.count < Int(uncompressedSize) else { break }
                if control & (1 << bit) != 0 {
                    guard pos + 1 < data.count else { break }
                    let hi = Int(data[pos]); let lo = Int(data[pos + 1]); pos += 2
                    let offset = (hi << 4) | (lo >> 4)
                    let length = (lo & 0x0F) + 2
                    for j in 0..<length {
                        guard output.count < Int(uncompressedSize) else { break }
                        let byte = dict[(offset + j) % 4096]
                        output.append(byte)
                        dict[dictWritePos % 4096] = byte
                        dictWritePos += 1
                    }
                } else {
                    guard pos < data.count else { break }
                    let byte = data[pos]; pos += 1
                    output.append(byte)
                    dict[dictWritePos % 4096] = byte
                    dictWritePos += 1
                }
            }
        }

        let text = rtfPlainText(output)
        return text.isEmpty ? nil : text
    }

    /// The words of an RTF document: destination groups that carry no
    /// prose (font and colour tables, stylesheet, info, `{\\*…}`) are skipped,
    /// `\\par`/`\\line` become line breaks, `\\tab` a tab, `\\'hh` and `\\uN` their
    /// characters; every other control word is dropped. Nothing is executed.
    static func rtfPlainText(_ data: Data) -> String {
        let bytes = [UInt8](data)
        var out = ""
        var i = 0
        var skipDepth: Int? = nil        // depth at which a skipped destination group opened
        var depth = 0
        var unicodeSkip = 1               // \ucN: bytes to skip after \uN
        var pendingSkip = 0
        let skippedDestinations = ["fonttbl", "colortbl", "stylesheet", "info", "generator", "listtable", "listoverridetable", "rsidtbl", "xmlnstbl", "themedata", "colorschememapping", "latentstyles", "datastore", "pict", "object", "header", "footer", "pntext", "fldinst"]
        func peekWord(at start: Int) -> (word: String, number: Int?, next: Int) {
            var j = start
            var word = ""
            while j < bytes.count, (bytes[j] >= 97 && bytes[j] <= 122) || (bytes[j] >= 65 && bytes[j] <= 90) { word.append(Character(UnicodeScalar(bytes[j]))); j += 1 }
            var digits = ""
            if j < bytes.count, bytes[j] == 45 { digits.append("-"); j += 1 }
            while j < bytes.count, bytes[j] >= 48 && bytes[j] <= 57 { digits.append(Character(UnicodeScalar(bytes[j]))); j += 1 }
            if j < bytes.count, bytes[j] == 32 { j += 1 }   // one delimiting space belongs to the control word
            return (word, Int(digits), j)
        }
        while i < bytes.count {
            let b = bytes[i]
            if b == 123 {   // {
                depth += 1
                // `{\*` is an ignorable destination; named tables are skipped by name.
                if i + 2 < bytes.count, bytes[i + 1] == 92 {
                    if bytes[i + 2] == 42 { if skipDepth == nil { skipDepth = depth } }
                    else {
                        let (word, _, _) = peekWord(at: i + 2)
                        if skippedDestinations.contains(word), skipDepth == nil { skipDepth = depth }
                    }
                }
                i += 1
            } else if b == 125 {   // }
                if let d = skipDepth, d == depth { skipDepth = nil }
                depth = max(0, depth - 1)
                i += 1
            } else if b == 92 {   // backslash
                guard i + 1 < bytes.count else { break }
                let n = bytes[i + 1]
                if n == 39 {   // \'hh
                    if i + 3 < bytes.count, let v = UInt8(String(bytes: bytes[(i + 2)...(i + 3)], encoding: .ascii) ?? "", radix: 16) {
                        if skipDepth == nil { if pendingSkip > 0 { pendingSkip -= 1 } else if let ch = String(bytes: [v], encoding: .windowsCP1252) { out += ch } }
                        i += 4
                    } else { i += 2 }
                } else if n == 92 || n == 123 || n == 125 {   // escaped \ { }
                    if skipDepth == nil { out.append(Character(UnicodeScalar(n))) }
                    i += 2
                } else if n == 126 { if skipDepth == nil { out += "\u{00A0}" }; i += 2 }
                else if n == 45 || n == 58 { i += 2 }                 // optional hyphen, subentry
                else if n == 95 { if skipDepth == nil { out += "-" }; i += 2 }
                else if n == 10 || n == 13 { if skipDepth == nil { out += "\n" }; i += 2 }
                else {
                    let (word, number, next) = peekWord(at: i + 1)
                    if skipDepth == nil {
                        switch word {
                        case "par", "line", "sect", "page": out += "\n"
                        case "tab", "cell": out += "\t"
                        case "row": out += "\n"
                        case "uc": unicodeSkip = max(0, number ?? 1)
                        case "u":
                            if let code = number {
                                let scalar = code < 0 ? code + 65536 : code
                                if let u = UnicodeScalar(UInt32(max(0, scalar))) { out.append(Character(u)) }
                                pendingSkip = unicodeSkip
                            }
                        case "emdash": out += "—"
                        case "endash": out += "–"
                        case "lquote", "rquote": out += "'"
                        case "ldblquote", "rdblquote": out += "\""
                        case "bullet": out += "•"
                        default: break
                        }
                    }
                    i = next
                }
            } else {
                if skipDepth == nil, b != 10, b != 13 {
                    if pendingSkip > 0 { pendingSkip -= 1 } else { out.append(Character(UnicodeScalar(b))) }
                }
                i += 1
            }
        }
        return out.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " ?\\n ?", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset]) | (UInt32(data[offset+1]) << 8) |
               (UInt32(data[offset+2]) << 16) | (UInt32(data[offset+3]) << 24)
    }
}

// MARK: - MAPI Property IDs

struct MAPIPropertySet {
    var strings: [UInt16: String] = [:]
    var binaries: [UInt16: Data] = [:]
    var dates: [UInt16: Date] = [:]
    var ints: [UInt16: UInt32] = [:]
    /// CLOSE-01: string and binary streams too large to read in place, by
    /// property id — streamed by the caller (`OLE2Reader.streamEntry`).
    var deferred: [UInt16: DeferredStream] = [:]

    struct DeferredStream {
        let entry: OLE2Reader.DirectoryEntry
        let propType: UInt16
    }

    func stringProperty(_ id: MAPIPropertyID) -> String? { strings[id.rawValue] }
    func binaryProperty(_ id: MAPIPropertyID) -> Data? { binaries[id.rawValue] }
    func dateProperty(_ id: MAPIPropertyID) -> Date? { dates[id.rawValue] }
    func intProperty(_ id: MAPIPropertyID) -> UInt32? { ints[id.rawValue] }
}

enum MAPIPropertyID: UInt16 {
    case subject = 0x0037
    case body = 0x1000
    case htmlBody = 0x1013
    case rtfCompressed = 0x1009
    case senderName = 0x0C1A
    case senderEmailAddress = 0x0C1F
    case senderSmtpAddress = 0x5D01
    case displayTo = 0x0E04
    case displayCc = 0x0E03
    case displayBcc = 0x0E02
    case internetMessageId = 0x1035
    case inReplyToId = 0x1042
    case messageDeliveryTime = 0x0E06
    case clientSubmitTime = 0x0039
    case creationTime = 0x3007
    case lastModificationTime = 0x3008
    case importance = 0x0017
    case sensitivity = 0x0036
    case conversationTopic = 0x0070
    case references = 0x1039
    case replyToAddress = 0x0050
    case transportMessageHeaders = 0x007D
    case messageFlags = 0x0E07
    case messageSize = 0x0E08
    case displayName = 0x3001

    // Attachment properties
    case attachFilename = 0x3704
    case attachLongFilename = 0x3707
    case attachMimeTag = 0x370E
    case attachDataBinary = 0x3701
    case attachDataObject = 0x3703
    case attachMethod = 0x3705
    case attachContentId = 0x3712
    case attachFlags = 0x3714
    case attachSize = 0x0E20
}

enum MSGError: LocalizedError {
    case invalidFormat(String)
    case propertyNotFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidFormat(let reason): return "Invalid MSG format: \(reason)"
        case .propertyNotFound(let name): return "MSG property not found: \(name)"
        }
    }
}
