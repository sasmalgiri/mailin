import Foundation
import os.log

private let pstLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "mailin", category: "PSTParser")

struct PSTParser {
    enum PSTError: LocalizedError {
        case fileTooLarge(Int64)
        var errorDescription: String? {
            switch self {
            case .fileTooLarge(let size):
                return "PST file is too large (\(size / 1_000_000) MB). Maximum supported size is 50 GB."
            }
        }
    }

    static func parse(
        fileURL: URL,
        senderEmail: String,
        onProgress: ((Double) -> Void)? = nil
    ) throws -> [MBOXParser.RawEmail] {
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = attrs[.size] as? Int64 ?? 0
        // 50 GB cap matches Outlook's own PST size limit. Memory-mapped I/O
        // below means peak RSS is bounded by the working set the B-tree
        // traversal touches, not by the file size — so the file can be
        // many GB without paging out the user.
        if fileSize > 50_000_000_000 {
            throw PSTError.fileTooLarge(fileSize)
        }
        // `.mappedIfSafe` returns Data backed by mmap'd file pages. The OS
        // pages in only the bytes our B-tree reader actually touches, so
        // a 10 GB PST never has 10 GB resident. Random-access B-tree
        // patterns benefit massively from this vs `Data(contentsOf:)`.
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        let reader = try PSTReader(data: data)
        let messages = try reader.readAllMessages(onProgress: onProgress)

        let isoFormatter = ISO8601DateFormatter()
        return messages.compactMap { msg in
            let from = msg.senderEmail.isEmpty ? msg.senderName : "\(msg.senderName) <\(msg.senderEmail)>"
            let timestamp = isoFormatter.string(from: msg.deliveryTime ?? msg.creationTime ?? .distantPast)
            let messageType = !senderEmail.isEmpty && from.lowercased().contains(senderEmail.lowercased()) ? "sent" : "received"

            var headers: [String: String] = [
                "From": from,
                "To": msg.displayTo,
                "Subject": msg.subject,
                "Date": timestamp
            ]
            if !msg.displayCc.isEmpty { headers["Cc"] = msg.displayCc }
            if !msg.displayBcc.isEmpty { headers["Bcc"] = msg.displayBcc }
            if let msgID = msg.internetMessageId { headers["Message-ID"] = msgID }
            if let inReplyTo = msg.inReplyToId { headers["In-Reply-To"] = inReplyTo }
            if let refs = msg.references { headers["References"] = refs }
            if let replyTo = msg.replyToAddress, !replyTo.isEmpty { headers["Reply-To"] = replyTo }
            if let contentType = msg.contentType { headers["Content-Type"] = contentType }
            if !msg.transportHeaders.isEmpty { mergeTransportHeaders(msg.transportHeaders, into: &headers) }
            if let importance = msg.importance {
                headers["X-Priority"] = importance == 2 ? "1" : importance == 0 ? "5" : "3"
            }

            let domains = MBOXParser.extractDomains(from: headers)

            return MBOXParser.RawEmail(
                id: UUID(),
                headers: headers,
                rawSource: "",
                messageType: messageType,
                attachments: msg.attachments,
                timestamp: timestamp,
                domains: domains,
                plainBody: msg.bodyText,
                htmlBody: msg.bodyHTML,
                mimeRoot: nil,
                mimeSummary: nil,
                mimeDiagnostics: [],
                threadID: headers["Message-ID"] ?? MBOXParser.sha1("\(msg.subject)\(from)\(timestamp)"),
                inReplyTo: headers["In-Reply-To"],
                references: headers["References"]?.components(separatedBy: .whitespaces).filter { !$0.isEmpty },
                tags: msg.folderPath.isEmpty ? [] : [msg.folderPath],
                anomalies: MBOXParser.findAnomalies(headers: headers, body: msg.bodyText, attachments: msg.attachments)
            )
        }
    }

    private static func mergeTransportHeaders(_ raw: String, into headers: inout [String: String]) {
        var currentKey = ""
        var currentValue = ""
        for line in raw.components(separatedBy: "\n") {
            if line.first?.isWhitespace == true {
                currentValue += " " + line.trimmingCharacters(in: .whitespaces)
            } else {
                if !currentKey.isEmpty && headers[currentKey] == nil {
                    headers[currentKey] = currentValue
                }
                if let colonIdx = line.firstIndex(of: ":") {
                    currentKey = String(line[line.startIndex..<colonIdx])
                    currentValue = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        if !currentKey.isEmpty && headers[currentKey] == nil {
            headers[currentKey] = currentValue
        }
    }
}

// MARK: - PST File Reader

struct PSTReader {
    private let data: Data
    private let isUnicode: Bool
    private let isOST: Bool
    private let encType: UInt8
    private static let maxBTreeDepth = 25
    private static let maxChainLength = 100_000

    struct PSTMessage {
        var subject: String = ""
        var senderName: String = ""
        var senderEmail: String = ""
        var displayTo: String = ""
        var displayCc: String = ""
        var displayBcc: String = ""
        var bodyText: String = ""
        var bodyHTML: String = ""
        var internetMessageId: String?
        var inReplyToId: String?
        var references: String?
        var replyToAddress: String?
        var contentType: String?
        var conversationTopic: String?
        var importance: UInt32?
        var sensitivity: UInt32?
        var transportHeaders: String = ""
        var deliveryTime: Date?
        var creationTime: Date?
        var lastModificationTime: Date?
        var folderPath: String = ""
        var attachments: [AttachmentMetadata] = []
        var hasAttachments: Bool = false
        var messageSize: Int = 0
    }

    init(data: Data) throws {
        guard data.count >= 564 else {
            throw PSTError.invalidFormat("File too small (\(data.count) bytes, need 564+)")
        }

        let magic = data[0..<4]
        guard magic == Data([0x21, 0x42, 0x44, 0x4E]) else {
            throw PSTError.invalidFormat("Not a PST/OST file (bad magic: !BDN expected)")
        }

        self.data = data

        let contentType = pstReadUInt16(data, offset: 8)
        self.isOST = contentType == 0x0024

        let version = pstReadUInt16(data, offset: 10)
        self.isUnicode = version >= 23

        self.encType = data[513]
        if isOST && encType != 0x00 && encType != 0x01 && encType != 0x02 {
            throw PSTError.invalidFormat("Unsupported OST encryption type: \(encType)")
        }
    }

    func readAllMessages(onProgress: ((Double) -> Void)? = nil) throws -> [PSTMessage] {
        let nodeEntries = try readNodeBTree()
        let blockEntries = try readBlockBTree()

        let messageNodes = nodeEntries.filter { ($0.nid & 0x1F) == 0x0C }

        var messages: [PSTMessage] = []
        let total = Double(max(messageNodes.count, 1))
        var recoveryErrors = 0

        for (idx, node) in messageNodes.enumerated() {
            do {
                var msg = try readMessage(node: node, blockEntries: blockEntries)
                msg = try extractAttachments(for: node, blockEntries: blockEntries, message: msg)
                messages.append(msg)
            } catch {
                recoveryErrors += 1
                pstLog.warning("Skipped message node NID \(node.nid, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            onProgress?(Double(idx + 1) / total)
        }

        return messages
    }

    // MARK: - NDB Layer

    struct NodeEntry {
        let nid: UInt32
        let dataBid: UInt64
        let subBid: UInt64
    }

    struct BlockEntry {
        let bid: UInt64
        let offset: UInt64
        let size: UInt16
    }

    private func readNodeBTree() throws -> [NodeEntry] {
        let rootOffset: Int
        if isUnicode {
            rootOffset = Int(pstReadUInt64(data, offset: 224))
        } else {
            rootOffset = Int(pstReadUInt32(data, offset: 188))
        }
        guard rootOffset > 0 && rootOffset < data.count else { return [] }
        return readNodeBTreePage(at: rootOffset, depth: 0)
    }

    private func readNodeBTreePage(at offset: Int, depth: Int) -> [NodeEntry] {
        guard depth < Self.maxBTreeDepth else { return [] }
        guard offset >= 0 && offset + 512 <= data.count else { return [] }

        let pageType = data[offset + 496]
        let entryCount = min(Int(data[offset + 488]), 40)

        if pageType == 0x81 {
            var entries: [NodeEntry] = []
            entries.reserveCapacity(entryCount)
            for i in 0..<entryCount {
                let base = offset + i * (isUnicode ? 32 : 16)
                guard base + (isUnicode ? 32 : 16) <= data.count else { break }
                if isUnicode {
                    let nid = pstReadUInt32(data, offset: base)
                    let dataBid = pstReadUInt64(data, offset: base + 8)
                    let subBid = pstReadUInt64(data, offset: base + 16)
                    entries.append(NodeEntry(nid: nid, dataBid: dataBid, subBid: subBid))
                } else {
                    let nid = pstReadUInt32(data, offset: base)
                    let dataBid = UInt64(pstReadUInt32(data, offset: base + 4))
                    let subBid = UInt64(pstReadUInt32(data, offset: base + 8))
                    entries.append(NodeEntry(nid: nid, dataBid: dataBid, subBid: subBid))
                }
            }
            return entries
        } else if pageType == 0x80 {
            var entries: [NodeEntry] = []
            for i in 0..<entryCount {
                let childOffset: Int
                if isUnicode {
                    let base = offset + i * 24
                    guard base + 24 <= data.count else { break }
                    childOffset = Int(pstReadUInt64(data, offset: base + 16))
                } else {
                    let base = offset + i * 12
                    guard base + 12 <= data.count else { break }
                    childOffset = Int(pstReadUInt32(data, offset: base + 8))
                }
                entries.append(contentsOf: readNodeBTreePage(at: childOffset, depth: depth + 1))
            }
            return entries
        }
        return []
    }

    private func readBlockBTree() throws -> [UInt64: BlockEntry] {
        let rootOffset: Int
        if isUnicode {
            rootOffset = Int(pstReadUInt64(data, offset: 240))
        } else {
            rootOffset = Int(pstReadUInt32(data, offset: 196))
        }
        guard rootOffset > 0 && rootOffset < data.count else { return [:] }

        var result: [UInt64: BlockEntry] = [:]
        let entries = readBlockBTreePage(at: rootOffset, depth: 0)
        for entry in entries {
            result[entry.bid] = entry
        }
        return result
    }

    private func readBlockBTreePage(at offset: Int, depth: Int) -> [BlockEntry] {
        guard depth < Self.maxBTreeDepth else { return [] }
        guard offset >= 0 && offset + 512 <= data.count else { return [] }

        let pageType = data[offset + 496]
        let entryCount = min(Int(data[offset + 488]), 40)

        if pageType == 0x82 {
            var entries: [BlockEntry] = []
            entries.reserveCapacity(entryCount)
            for i in 0..<entryCount {
                if isUnicode {
                    let base = offset + i * 24
                    guard base + 24 <= data.count else { break }
                    let bid = pstReadUInt64(data, offset: base)
                    let blockOffset = pstReadUInt64(data, offset: base + 8)
                    let size = pstReadUInt16(data, offset: base + 16)
                    entries.append(BlockEntry(bid: bid, offset: blockOffset, size: size))
                } else {
                    let base = offset + i * 12
                    guard base + 12 <= data.count else { break }
                    let bid = UInt64(pstReadUInt32(data, offset: base))
                    let blockOffset = UInt64(pstReadUInt32(data, offset: base + 4))
                    let size = pstReadUInt16(data, offset: base + 8)
                    entries.append(BlockEntry(bid: bid, offset: blockOffset, size: size))
                }
            }
            return entries
        } else if pageType == 0x83 {
            var entries: [BlockEntry] = []
            for i in 0..<entryCount {
                let childOffset: Int
                if isUnicode {
                    let base = offset + i * 24
                    guard base + 24 <= data.count else { break }
                    childOffset = Int(pstReadUInt64(data, offset: base + 16))
                } else {
                    let base = offset + i * 12
                    guard base + 12 <= data.count else { break }
                    childOffset = Int(pstReadUInt32(data, offset: base + 8))
                }
                entries.append(contentsOf: readBlockBTreePage(at: childOffset, depth: depth + 1))
            }
            return entries
        }
        return []
    }

    // MARK: - Read Message (Full MAPI property set)

    private func readMessage(node: NodeEntry, blockEntries: [UInt64: BlockEntry]) throws -> PSTMessage {
        var msg = PSTMessage()

        guard let block = blockEntries[node.dataBid] else {
            throw PSTError.blockNotFound
        }

        let blockData = readBlockData(block)
        let properties = parsePropertyContext(blockData)

        // Core addressing
        msg.subject = properties.strings[0x0037] ?? ""
        msg.senderName = properties.strings[0x0C1A] ?? properties.strings[0x0042] ?? ""
        msg.senderEmail = properties.strings[0x0C1F] ?? properties.strings[0x0065] ?? properties.strings[0x0076] ?? ""
        msg.displayTo = properties.strings[0x0E04] ?? ""
        msg.displayCc = properties.strings[0x0E03] ?? ""
        msg.displayBcc = properties.strings[0x0E02] ?? ""
        msg.replyToAddress = properties.strings[0x0050]

        // Body
        msg.bodyText = properties.strings[0x1000] ?? ""
        if let htmlData = properties.binaries[0x1013] {
            msg.bodyHTML = String(data: htmlData, encoding: .utf8) ?? String(data: htmlData, encoding: .ascii) ?? ""
        }
        if msg.bodyHTML.isEmpty, let htmlStr = properties.strings[0x1013] {
            msg.bodyHTML = htmlStr
        }

        // Threading
        msg.internetMessageId = properties.strings[0x1035]
        msg.inReplyToId = properties.strings[0x1042]
        msg.references = properties.strings[0x1039]
        msg.conversationTopic = properties.strings[0x0070]

        // Transport headers (contains full RFC822 headers)
        msg.transportHeaders = properties.strings[0x007D] ?? ""

        // Content type
        msg.contentType = properties.strings[0x001A]

        // Timestamps
        msg.deliveryTime = properties.dates[0x0E06]
        msg.creationTime = properties.dates[0x3007]
        msg.lastModificationTime = properties.dates[0x3008]

        // Flags
        msg.importance = properties.ints[0x0017]
        msg.sensitivity = properties.ints[0x0036]
        if let flags = properties.ints[0x0E07] {
            msg.hasAttachments = (flags & 0x10) != 0
        }
        if let size = properties.ints[0x0E08] {
            msg.messageSize = Int(size)
        }

        return msg
    }

    // MARK: - Attachment Extraction

    private func extractAttachments(for node: NodeEntry, blockEntries: [UInt64: BlockEntry], message: PSTMessage) throws -> PSTMessage {
        var msg = message
        let attachTableNID = (node.nid & ~UInt32(0x1F)) | 0x0D
        guard let attachNode = findSubnode(nid: attachTableNID, subBid: node.subBid, blockEntries: blockEntries) else {
            return msg
        }
        guard let attachBlock = blockEntries[attachNode.dataBid] else { return msg }
        let attachData = readBlockData(attachBlock)
        let attachProps = parsePropertyContext(attachData)

        for (propID, binData) in attachProps.binaries {
            if propID == 0x3701 {
                let filename = attachProps.strings[0x3707] ?? attachProps.strings[0x3704] ?? "attachment"
                let mimeType = attachProps.strings[0x370E] ?? "application/octet-stream"
                let b64 = binData.base64EncodedString()
                msg.attachments.append(AttachmentMetadata(
                    filename: filename, mimeType: mimeType, size: binData.count,
                    isInline: false, contentID: attachProps.strings[0x3712],
                    base64: b64, fileURL: nil
                ))
            }
        }
        return msg
    }

    private func findSubnode(nid: UInt32, subBid: UInt64, blockEntries: [UInt64: BlockEntry]) -> NodeEntry? {
        guard subBid > 0, let block = blockEntries[subBid] else { return nil }
        let subData = readBlockData(block)
        guard subData.count >= 8 else { return nil }
        let entrySize = isUnicode ? 24 : 12
        var offset = isUnicode ? 8 : 4
        while offset + entrySize <= subData.count {
            let subNid = pstReadUInt32(subData, offset: offset)
            if subNid == nid {
                let dataBid = isUnicode ? pstReadUInt64(subData, offset: offset + 8) : UInt64(pstReadUInt32(subData, offset: offset + 4))
                let subSubBid = isUnicode ? pstReadUInt64(subData, offset: offset + 16) : UInt64(pstReadUInt32(subData, offset: offset + 8))
                return NodeEntry(nid: subNid, dataBid: dataBid, subBid: subSubBid)
            }
            offset += entrySize
        }
        return nil
    }

    // MARK: - Block Data Reading

    private func readBlockData(_ block: BlockEntry) -> Data {
        let offset = Int(block.offset)
        let size = Int(block.size)
        guard offset >= 0 && size >= 0 && offset + size <= data.count else { return Data() }

        var blockData = data[offset..<(offset + size)]

        if isOST {
            if encType == 0x01 {
                blockData = Data(blockData.map { decodePermute($0) })
            } else if encType == 0x02 {
                blockData = Data(blockData.map { decodeCyclic($0) })
            }
        }

        return Data(blockData)
    }

    // MARK: - Property Context Parser

    struct MAPIPropertySet {
        var strings: [UInt16: String] = [:]
        var binaries: [UInt16: Data] = [:]
        var dates: [UInt16: Date] = [:]
        var ints: [UInt16: UInt32] = [:]
    }

    private func parsePropertyContext(_ data: Data) -> MAPIPropertySet {
        var props = MAPIPropertySet()
        guard data.count >= 8 else { return props }

        let heapType = data.count > 3 ? data[3] : 0
        guard heapType == 0xBC || heapType == 0x7C else { return props }

        var offset = 8
        let entrySize = 8
        while offset + entrySize <= data.count {
            let propID = pstReadUInt16(data, offset: offset)
            let propType = pstReadUInt16(data, offset: offset + 2)

            if propType == 0x001F || propType == 0x001E {
                let valueRef = pstReadUInt32(data, offset: offset + 4)
                let strOffset = Int(valueRef)
                if strOffset > 0 && strOffset < data.count {
                    let remaining = data[strOffset...]
                    let maxLen = min(remaining.count, 4096)
                    if propType == 0x001F {
                        if let str = String(data: Data(remaining.prefix(maxLen)), encoding: .utf16LittleEndian) {
                            props.strings[propID] = str.components(separatedBy: "\0").first ?? str
                        }
                    } else {
                        if let str = String(data: Data(remaining.prefix(maxLen)), encoding: .utf8) ??
                                     String(data: Data(remaining.prefix(maxLen)), encoding: .ascii) {
                            props.strings[propID] = str.components(separatedBy: "\0").first ?? str
                        }
                    }
                }
            } else if propType == 0x0102 {
                let valueRef = pstReadUInt32(data, offset: offset + 4)
                let binOffset = Int(valueRef)
                if binOffset > 0 && binOffset < data.count {
                    let maxSize = min(data.count - binOffset, 10_485_760)
                    props.binaries[propID] = Data(data[binOffset...].prefix(maxSize))
                }
            } else if propType == 0x0040 {
                if offset + 12 <= data.count {
                    let fileTime = pstReadUInt64(data, offset: offset + 4)
                    if fileTime > 0 {
                        let seconds = Double(fileTime) / 10_000_000.0 - 11_644_473_600.0
                        if seconds > 0 && seconds < 4_102_444_800 {
                            props.dates[propID] = Date(timeIntervalSince1970: seconds)
                        }
                    }
                }
            } else if propType == 0x0003 {
                if offset + 8 <= data.count {
                    props.ints[propID] = pstReadUInt32(data, offset: offset + 4)
                }
            }

            offset += entrySize
        }
        return props
    }

    // MARK: - OST Encryption

    private func decodePermute(_ byte: UInt8) -> UInt8 {
        let table: [UInt8] = [
            65, 54, 19, 98, 168, 33, 110, 187, 244, 22, 204, 4, 127, 100, 232, 93,
            30, 242, 203, 42, 116, 197, 94, 53, 210, 149, 71, 158, 150, 45, 154, 136,
            76, 125, 132, 63, 219, 172, 49, 182, 72, 95, 246, 196, 216, 57, 139, 231,
            35, 59, 56, 142, 200, 193, 223, 37, 177, 32, 165, 70, 96, 78, 156, 251,
            170, 211, 86, 81, 69, 124, 85, 0, 7, 201, 43, 157, 133, 155, 9, 160,
            143, 173, 179, 15, 99, 171, 137, 75, 215, 167, 21, 90, 113, 102, 66, 191,
            38, 74, 107, 152, 250, 234, 119, 83, 178, 112, 5, 44, 253, 89, 58, 134,
            126, 206, 6, 235, 130, 120, 87, 199, 141, 67, 175, 180, 28, 212, 91, 205,
            62, 128, 135, 174, 52, 79, 40, 41, 20, 13, 29, 117, 28, 51, 68, 146,
            184, 82, 88, 236, 190, 164, 138, 163, 46, 73, 248, 121, 46, 115, 189, 145,
            17, 11, 60, 145, 131, 108, 159, 24, 31, 14, 230, 12, 151, 176, 227, 213,
            174, 218, 252, 153, 106, 109, 249, 105, 195, 2, 181, 198, 148, 207, 254, 166,
            247, 103, 123, 55, 48, 129, 226, 161, 144, 255, 101, 192, 36, 239, 50, 97,
            114, 162, 64, 77, 26, 10, 169, 228, 111, 104, 183, 118, 84, 8, 47, 147,
            240, 122, 233, 16, 221, 243, 237, 208, 245, 186, 25, 238, 188, 23, 220, 34,
            229, 39, 3, 140, 1, 92, 217, 209, 80, 241, 214, 61, 222, 18, 224, 27
        ]
        return table[Int(byte)]
    }

    private func decodeCyclic(_ byte: UInt8) -> UInt8 {
        return byte ^ 0xA5
    }
}

enum PSTError: LocalizedError {
    case invalidFormat(String)
    case blockNotFound
    case unsupportedVersion
    case depthLimitExceeded

    var errorDescription: String? {
        switch self {
        case .invalidFormat(let reason): return "Invalid PST/OST format: \(reason)"
        case .blockNotFound: return "PST data block not found"
        case .unsupportedVersion: return "Unsupported PST version"
        case .depthLimitExceeded: return "PST B-tree depth limit exceeded"
        }
    }
}

// MARK: - PST Binary Read Helpers

private func pstReadUInt16(_ data: Data, offset: Int) -> UInt16 {
    guard offset >= 0 && offset + 2 <= data.count else { return 0 }
    return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
}

private func pstReadUInt32(_ data: Data, offset: Int) -> UInt32 {
    guard offset >= 0 && offset + 4 <= data.count else { return 0 }
    return UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8) |
           (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
}

private func pstReadUInt64(_ data: Data, offset: Int) -> UInt64 {
    guard offset >= 0 && offset + 8 <= data.count else { return 0 }
    return (0..<8).reduce(UInt64(0)) { result, i in
        result | (UInt64(data[offset + i]) << (i * 8))
    }
}
