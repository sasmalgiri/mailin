import Foundation

struct MSGParser {
    static func parse(
        fileURL: URL,
        senderEmail: String,
        onProgress: ((Double) -> Void)? = nil
    ) throws -> [MBOXParser.RawEmail] {
        let email = try parseSingleMSG(fileURL: fileURL, senderEmail: senderEmail)
        onProgress?(1.0)
        return [email]
    }

    enum MSGError: LocalizedError {
        case fileTooLarge(Int64)
        var errorDescription: String? {
            switch self {
            case .fileTooLarge(let size):
                return "MSG file is too large (\(size / 1_000_000) MB). Maximum supported size is 2 GB."
            }
        }
    }

    private static func parseSingleMSG(fileURL: URL, senderEmail: String) throws -> MBOXParser.RawEmail {
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = attrs[.size] as? Int64 ?? 0
        if fileSize > 2_000_000_000 { throw MSGError.fileTooLarge(fileSize) }

        let data = try Data(contentsOf: fileURL)
        let ole2 = try OLE2Reader(data: data)
        let properties = try ole2.readMAPIProperties()

        let senderAddr = properties.stringProperty(.senderEmailAddress)
            ?? properties.stringProperty(.senderSmtpAddress)
            ?? ""
        let senderName = properties.stringProperty(.senderName) ?? ""
        let from = !senderAddr.isEmpty ? (senderName.isEmpty ? senderAddr : "\(senderName) <\(senderAddr)>") : senderName

        let to = properties.stringProperty(.displayTo) ?? ""
        let cc = properties.stringProperty(.displayCc) ?? ""
        let bcc = properties.stringProperty(.displayBcc) ?? ""
        let subject = properties.stringProperty(.subject) ?? "(No Subject)"
        let body = properties.stringProperty(.body) ?? ""
        let htmlBodyData = properties.binaryProperty(.htmlBody)
        let htmlBody = htmlBodyData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let rtfBody = properties.binaryProperty(.rtfCompressed).flatMap { decompressRTF($0) } ?? ""

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

        let messageType = !senderEmail.isEmpty && from.lowercased().contains(senderEmail.lowercased()) ? "sent" : "received"

        let effectiveBody = !body.isEmpty ? body : (!htmlBody.isEmpty ? htmlBody : rtfBody)
        let bodyLines = effectiveBody.components(separatedBy: .newlines)
        let fullText = headers.map { "\($0): \($1)" }.joined(separator: "\n") + "\n\n" + effectiveBody
        let domains = MBOXParser.extractDomains(from: headers)

        let attachments = try ole2.readAttachments()

        return MBOXParser.RawEmail(
            id: UUID(),
            headers: headers,
            bodyLines: bodyLines,
            rawSource: fullText,
            messageType: messageType,
            attachments: attachments,
            timestamp: timestamp,
            fullText: fullText,
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

    private static func decompressRTF(_ data: Data) -> String? {
        guard data.count >= 16 else { return nil }
        let compressedSize = readUInt32LE(data, offset: 0)
        let uncompressedSize = readUInt32LE(data, offset: 4)
        let magic = readUInt32LE(data, offset: 8)

        let lzfuMagic: UInt32 = 0x75465A4C // "LZFu"
        let melalMagic: UInt32 = 0x414C454D // "MELA" (uncompressed)

        guard compressedSize + 4 <= data.count else { return nil }

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

        guard let rtf = String(data: output, encoding: .ascii) else { return nil }
        let stripped = rtf.replacingOccurrences(of: "\\\\[a-z]+[0-9]*\\s?", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "[{}]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? nil : stripped
    }

    private static func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset]) | (UInt32(data[offset+1]) << 8) |
               (UInt32(data[offset+2]) << 16) | (UInt32(data[offset+3]) << 24)
    }
}

// MARK: - OLE2 Compound Document Reader

struct OLE2Reader {
    private let data: Data
    private let sectorSize: Int
    private let miniSectorSize: Int
    private let fatSectors: [Int]
    private let miniStreamCutoff: Int
    private var fat: [Int32] = []
    private var miniFat: [Int32] = []
    private var directories: [DirectoryEntry] = []
    private var miniStreamData: Data = Data()

    private static let maxChainLength = 100_000
    private static let maxDirCount = 500_000

    struct DirectoryEntry {
        let index: Int
        let name: String
        let type: UInt8
        let startSector: Int
        let size: Int
        let childID: Int
        let leftSiblingID: Int
        let rightSiblingID: Int
    }

    init(data: Data) throws {
        guard data.count >= 512 else {
            throw MSGError.invalidFormat("File too small for OLE2")
        }
        guard data[0] == 0xD0, data[1] == 0xCF, data[2] == 0x11, data[3] == 0xE0,
              data[4] == 0xA1, data[5] == 0xB1, data[6] == 0x1A, data[7] == 0xE1 else {
            throw MSGError.invalidFormat("Not a valid OLE2 compound document (bad magic bytes)")
        }

        self.data = data

        let sectorSizePower = Int(readUInt16(data, offset: 30))
        guard sectorSizePower >= 7 && sectorSizePower <= 16 else {
            throw MSGError.invalidFormat("Invalid sector size power: \(sectorSizePower)")
        }
        self.sectorSize = 1 << sectorSizePower
        let miniSectorSizePower = Int(readUInt16(data, offset: 32))
        self.miniSectorSize = 1 << miniSectorSizePower
        self.miniStreamCutoff = Int(readUInt32(data, offset: 56))

        let fatSectorCount = Int(readUInt32(data, offset: 44))
        let firstDirSector = Int(readInt32(data, offset: 48))
        let firstMiniFatSector = Int(readInt32(data, offset: 60))
        let miniFatSectorCount = Int(readUInt32(data, offset: 64))

        let difatFirstSector = Int(readInt32(data, offset: 68))
        let difatSectorCount = Int(readUInt32(data, offset: 72))

        var fatSectorList: [Int] = []
        for i in 0..<min(fatSectorCount, 109) {
            let sector = Int(readInt32(data, offset: 76 + i * 4))
            if sector >= 0 { fatSectorList.append(sector) }
        }

        if difatSectorCount > 0 && difatFirstSector >= 0 {
            var difatSector = difatFirstSector
            var difatRead = 0
            while difatSector >= 0 && difatRead < difatSectorCount && difatRead < 1000 {
                let base = 512 + difatSector * sectorSize
                let entriesPerSector = (sectorSize / 4) - 1
                for i in 0..<entriesPerSector {
                    let pos = base + i * 4
                    guard pos + 4 <= data.count else { break }
                    let s = Int(readInt32(data, offset: pos))
                    if s >= 0 { fatSectorList.append(s) }
                }
                let nextPos = base + entriesPerSector * 4
                difatSector = nextPos + 4 <= data.count ? Int(readInt32(data, offset: nextPos)) : -1
                difatRead += 1
            }
        }

        self.fatSectors = fatSectorList

        let headerSectorSize = 1 << sectorSizePower
        self.fat = Self.buildFAT(data: data, fatSectors: fatSectorList, sectorSize: headerSectorSize)

        let dirChain = Self.buildChain(startSector: firstDirSector, fat: fat)
        self.directories = Self.readDirectories(data: data, chain: dirChain, sectorSize: sectorSize)

        if firstMiniFatSector >= 0 && miniFatSectorCount > 0 {
            let miniFatChain = Self.buildChain(startSector: firstMiniFatSector, fat: fat)
            self.miniFat = Self.readFATFromChain(data: data, chain: miniFatChain, sectorSize: sectorSize)
        } else {
            self.miniFat = []
        }

        if !directories.isEmpty && directories[0].size > 0 {
            let rootChain = Self.buildChain(startSector: directories[0].startSector, fat: fat)
            self.miniStreamData = Self.readStreamData(data: data, chain: rootChain, sectorSize: sectorSize, streamSize: directories[0].size)
        }
    }

    // MARK: - Directory Tree Traversal

    private func childrenOf(directoryIndex: Int) -> [DirectoryEntry] {
        guard directoryIndex >= 0 && directoryIndex < directories.count else { return [] }
        let parent = directories[directoryIndex]
        guard parent.childID >= 0 && parent.childID < directories.count else { return [] }
        var result: [DirectoryEntry] = []
        var visited = Set<Int>()
        collectTree(parent.childID, into: &result, visited: &visited)
        return result
    }

    private func collectTree(_ nodeIndex: Int, into result: inout [DirectoryEntry], visited: inout Set<Int>) {
        guard nodeIndex >= 0 && nodeIndex < directories.count && visited.insert(nodeIndex).inserted else { return }
        guard result.count < Self.maxDirCount else { return }
        let node = directories[nodeIndex]
        collectTree(node.leftSiblingID, into: &result, visited: &visited)
        result.append(node)
        collectTree(node.rightSiblingID, into: &result, visited: &visited)
    }

    // MARK: - Read MAPI Properties

    func readMAPIProperties() throws -> MAPIPropertySet {
        var props = MAPIPropertySet()

        let rootChildren = childrenOf(directoryIndex: 0)

        for entry in rootChildren {
            if entry.name.hasPrefix("__substg1.0_") {
                parseSubstgEntry(entry, into: &props)
            } else if entry.name.lowercased() == "__properties_version1.0" {
                let streamData = readEntryData(entry)
                Self.parseFixedProperties(from: streamData, into: &props)
            }
        }
        return props
    }

    private func parseSubstgEntry(_ entry: DirectoryEntry, into props: inout MAPIPropertySet) {
        let tag = String(entry.name.dropFirst(12).prefix(8))
        guard let tagInt = UInt32(tag, radix: 16) else { return }
        let propID = UInt16(tagInt >> 16)
        let propType = UInt16(tagInt & 0xFFFF)
        let streamData = readEntryData(entry)

        switch propType {
        case 0x001F: // Unicode string
            if let str = String(data: streamData, encoding: .utf16LittleEndian) ?? String(data: streamData, encoding: .utf8) {
                props.strings[propID] = str
            }
        case 0x001E: // ANSI string
            if let str = String(data: streamData, encoding: .windowsCP1252) ?? String(data: streamData, encoding: .ascii) ?? String(data: streamData, encoding: .utf8) {
                props.strings[propID] = str
            }
        case 0x0102: // Binary
            props.binaries[propID] = streamData
        default:
            break
        }
    }

    // MARK: - Attachment Reading (Properly Scoped)

    func readAttachments() throws -> [AttachmentMetadata] {
        var attachments: [AttachmentMetadata] = []
        let rootChildren = childrenOf(directoryIndex: 0)

        for entry in rootChildren where entry.name.hasPrefix("__attach_version1.0") {
            let attachChildren = childrenOf(directoryIndex: entry.index)
            var attachProps = MAPIPropertySet()

            for child in attachChildren {
                if child.name.hasPrefix("__substg1.0_") {
                    parseSubstgEntry(child, into: &attachProps)
                } else if child.name.lowercased() == "__properties_version1.0" {
                    let streamData = readEntryData(child)
                    Self.parseFixedProperties(from: streamData, into: &attachProps)
                }
            }

            let filename = attachProps.strings[MAPIPropertyID.attachLongFilename.rawValue]
                ?? attachProps.strings[MAPIPropertyID.attachFilename.rawValue]
                ?? attachProps.strings[MAPIPropertyID.displayName.rawValue]
                ?? "attachment"
            let mimeType = attachProps.strings[MAPIPropertyID.attachMimeTag.rawValue]
                ?? "application/octet-stream"
            let contentID = attachProps.strings[MAPIPropertyID.attachContentId.rawValue]
            let attachData = attachProps.binaries[MAPIPropertyID.attachDataBinary.rawValue]
            let isInline = contentID != nil ||
                (attachProps.ints[MAPIPropertyID.attachFlags.rawValue].map { $0 & 0x04 != 0 } ?? false)

            attachments.append(AttachmentMetadata(
                filename: filename.trimmingCharacters(in: .controlCharacters),
                mimeType: mimeType.trimmingCharacters(in: .controlCharacters),
                size: attachData?.count ?? 0,
                isInline: isInline,
                contentID: contentID,
                base64: attachData?.base64EncodedString(),
                fileURL: nil
            ))

            let embeddedMsgData = attachProps.binaries[MAPIPropertyID.attachDataObject.rawValue]
            if embeddedMsgData != nil {
                // Embedded MSG (nested message) — recognized but not recursively parsed
                // to prevent stack overflow on deeply nested messages
            }
        }
        return attachments
    }

    private func readEntryData(_ entry: DirectoryEntry) -> Data {
        if entry.size < miniStreamCutoff && entry.type != 5 {
            let chain = Self.buildChain(startSector: entry.startSector, fat: miniFat)
            return Self.readMiniStreamData(miniStream: miniStreamData, chain: chain, miniSectorSize: miniSectorSize, streamSize: entry.size)
        } else {
            let chain = Self.buildChain(startSector: entry.startSector, fat: fat)
            return Self.readStreamData(data: data, chain: chain, sectorSize: sectorSize, streamSize: entry.size)
        }
    }

    // MARK: - Static Helpers

    private static func buildFAT(data: Data, fatSectors: [Int], sectorSize: Int) -> [Int32] {
        var fat: [Int32] = []
        for sector in fatSectors {
            let offset = 512 + sector * sectorSize
            let entries = sectorSize / 4
            for i in 0..<entries {
                let pos = offset + i * 4
                if pos + 4 <= data.count {
                    fat.append(readInt32(data, offset: pos))
                }
            }
        }
        return fat
    }

    private static func buildChain(startSector: Int, fat: [Int32]) -> [Int] {
        var chain: [Int] = []
        var current = startSector
        var seen = Set<Int>()
        while current >= 0 && current < fat.count && !seen.contains(current) && chain.count < maxChainLength {
            chain.append(current)
            seen.insert(current)
            let next = Int(fat[current])
            if next == -2 || next == -1 { break } // ENDOFCHAIN or FREESECT
            current = next
        }
        return chain
    }

    private static func readDirectories(data: Data, chain: [Int], sectorSize: Int) -> [DirectoryEntry] {
        var dirs: [DirectoryEntry] = []
        let entriesPerSector = sectorSize / 128
        for sector in chain {
            let base = 512 + sector * sectorSize
            for i in 0..<entriesPerSector {
                let offset = base + i * 128
                guard offset + 128 <= data.count else { continue }

                let rawNameLen = Int(readUInt16(data, offset: offset + 64))
                let nameLen = (rawNameLen / 2) * 2
                let nameData = data[offset..<(offset + min(nameLen, 64))]
                let name = String(data: nameData, encoding: .utf16LittleEndian)?
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""

                let type = data[offset + 66]
                let childID = Int(readInt32(data, offset: offset + 68))
                let leftID = Int(readInt32(data, offset: offset + 72))
                let rightID = Int(readInt32(data, offset: offset + 76))
                let startSector = Int(readInt32(data, offset: offset + 116))
                let size: Int
                if sectorSize == 4096 {
                    size = Int(readUInt64(data, offset: offset + 120))
                } else {
                    size = Int(readUInt32(data, offset: offset + 120))
                }

                if type > 0 {
                    dirs.append(DirectoryEntry(
                        index: dirs.count,
                        name: name, type: type,
                        startSector: startSector, size: max(0, size),
                        childID: childID, leftSiblingID: leftID, rightSiblingID: rightID
                    ))
                }
                if dirs.count >= maxDirCount { return dirs }
            }
        }
        return dirs
    }

    private static func readStreamData(data: Data, chain: [Int], sectorSize: Int, streamSize: Int) -> Data {
        var result = Data()
        for sector in chain {
            let offset = 512 + sector * sectorSize
            let end = min(offset + sectorSize, data.count)
            guard offset >= 0 && offset < data.count else { break }
            result.append(data[offset..<end])
        }
        return Data(result.prefix(max(0, streamSize)))
    }

    private static func readMiniStreamData(miniStream: Data, chain: [Int], miniSectorSize: Int, streamSize: Int) -> Data {
        var result = Data()
        for sector in chain {
            let offset = sector * miniSectorSize
            let end = min(offset + miniSectorSize, miniStream.count)
            guard offset >= 0 && offset < miniStream.count else { break }
            result.append(miniStream[offset..<end])
        }
        return Data(result.prefix(max(0, streamSize)))
    }

    private static func readFATFromChain(data: Data, chain: [Int], sectorSize: Int) -> [Int32] {
        var entries: [Int32] = []
        for sector in chain {
            let base = 512 + sector * sectorSize
            for i in 0..<(sectorSize / 4) {
                let pos = base + i * 4
                if pos + 4 <= data.count {
                    entries.append(readInt32(data, offset: pos))
                }
            }
        }
        return entries
    }

    private static func parseFixedProperties(from data: Data, into props: inout MAPIPropertySet) {
        var offset = data.count >= 32 ? 32 : (data.count >= 8 ? 8 : 0)
        while offset + 16 <= data.count {
            let propType = readUInt16(data, offset: offset)
            let propID = readUInt16(data, offset: offset + 2)
            switch propType {
            case 0x0040: // PT_SYSTIME
                let fileTime = readUInt64(data, offset: offset + 8)
                if fileTime > 0 {
                    let seconds = Double(fileTime) / 10_000_000.0 - 11_644_473_600.0
                    props.dates[propID] = Date(timeIntervalSince1970: seconds)
                }
            case 0x0003: // PT_LONG
                let value = readUInt32(data, offset: offset + 8)
                props.ints[propID] = value
            case 0x000B: // PT_BOOLEAN
                let value = readUInt16(data, offset: offset + 8)
                props.ints[propID] = UInt32(value)
            default:
                break
            }
            offset += 16
        }
    }
}

// MARK: - MAPI Property IDs

struct MAPIPropertySet {
    var strings: [UInt16: String] = [:]
    var binaries: [UInt16: Data] = [:]
    var dates: [UInt16: Date] = [:]
    var ints: [UInt16: UInt32] = [:]

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

// MARK: - Binary Read Helpers

private func readUInt16(_ data: Data, offset: Int) -> UInt16 {
    guard offset + 2 <= data.count else { return 0 }
    return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
}

private func readUInt32(_ data: Data, offset: Int) -> UInt32 {
    guard offset + 4 <= data.count else { return 0 }
    return UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8) |
           (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
}

private func readInt32(_ data: Data, offset: Int) -> Int32 {
    Int32(bitPattern: readUInt32(data, offset: offset))
}

private func readUInt64(_ data: Data, offset: Int) -> UInt64 {
    guard offset + 8 <= data.count else { return 0 }
    return (0..<8).reduce(UInt64(0)) { result, i in
        result | (UInt64(data[offset + i]) << (i * 8))
    }
}
