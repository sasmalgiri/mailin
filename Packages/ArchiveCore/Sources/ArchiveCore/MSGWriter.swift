import Foundation
import os.log

/// OLE2 Compound Document writer that creates .msg files from email data.
/// Writes MAPI properties into a valid OLE2 structure with 4096-byte sectors.
struct MSGWriter {

    private static let logger = Logger(subsystem: "com.mailin", category: "MSGWriter")

    // MARK: - Public API

    /// Write a single RawEmail to .msg format, returning the file data.
    static func write(email: MBOXParser.RawEmail) -> Data? {
        do {
            return try buildMSG(email: email)
        } catch {
            logger.error("Failed to write MSG: \(error.localizedDescription)")
            return nil
        }
    }

    /// Write multiple emails as individual .msg files into a folder. Returns the count written.
    static func writeMultiple(emails: [MBOXParser.RawEmail], to folder: URL) throws -> Int {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var count = 0
        for email in emails {
            guard let data = write(email: email) else { continue }
            let safeName = sanitizeFilename(email.headers["Subject"] ?? "email_\(count + 1)")
            let fileURL = folder.appendingPathComponent("\(safeName).msg")
            try data.write(to: fileURL, options: .atomic)
            count += 1
        }
        logger.info("Wrote \(count) MSG files to \(folder.path)")
        return count
    }

    // MARK: - OLE2 Constants

    private static let sectorSize = 4096
    private static let miniSectorSize = 64
    private static let miniStreamCutoff = 4096
    private static let ole2Magic: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
    private static let endOfChain: Int32 = -2
    private static let freeSect: Int32 = -1
    private static let fatSect: Int32 = -3

    // MARK: - Directory Entry

    private struct DirEntry {
        var name: String
        var type: UInt8         // 1 = storage, 2 = stream, 5 = root
        var childID: Int32 = -1
        var leftSiblingID: Int32 = -1
        var rightSiblingID: Int32 = -1
        var startSector: Int32 = 0
        var size: Int32 = 0
    }

    // MARK: - Build MSG

    private static func buildMSG(email: MBOXParser.RawEmail) throws -> Data {
        let streams = messageStreams(email: email, propertiesHeader: 32, depth: 0)
        // Layout sectors
        return try layoutOLE2(streams: streams, attachmentCount: email.attachments.count)
    }

    /// Messages attached as messages are written as embedded messages this
    /// many levels deep (matches `MSGParser.maxEmbeddedDepth`).
    static let maxEmbeddedDepth = 3

    /// The streams of one message storage. `propertiesHeader` is 32 bytes at
    /// the root and 24 in an embedded message (MS-OXMSG §2.4.1).
    private static func messageStreams(email: MBOXParser.RawEmail, propertiesHeader: Int, depth: Int) -> [(String, Data)] {
        // Collect streams: each is (name, data)
        var streams: [(String, Data)] = []

        // Properties stream (fixed-length properties header)
        let propsData = buildPropertiesStream(email: email, header: propertiesHeader)
        streams.append(("__properties_version1.0", propsData))

        // Subject
        if let subj = email.headers["Subject"] {
            appendStringStreams(&streams, propID: 0x0037, value: subj)
        }
        // Sender email address
        if let from = email.headers["From"] {
            appendStringStreams(&streams, propID: 0x0C1F, value: extractEmailAddr(from))
            appendStringStreams(&streams, propID: 0x0C1A, value: extractDisplayName(from))
        }
        // Display To
        if let to = email.headers["To"] {
            appendStringStreams(&streams, propID: 0x0E04, value: to)
        }
        // Display Cc
        if let cc = email.headers["Cc"] {
            appendStringStreams(&streams, propID: 0x0E03, value: cc)
        }
        // Display Bcc
        if let bcc = email.headers["Bcc"] {
            appendStringStreams(&streams, propID: 0x0E02, value: bcc)
        }
        // Body (plain text)
        if !email.plainBody.isEmpty {
            appendStringStreams(&streams, propID: 0x1000, value: email.plainBody)
        }
        // HTML Body (binary)
        if !email.htmlBody.isEmpty, let htmlData = email.htmlBody.data(using: .utf8) {
            let tag = String(format: "%04X0102", 0x1013)
            streams.append(("__substg1.0_\(tag)", htmlData))
        }
        // Message-ID
        if let msgID = email.headers["Message-ID"] {
            appendStringStreams(&streams, propID: 0x1035, value: msgID)
        }
        // Transport headers
        let transportHeaders = email.headers.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n")
        if !transportHeaders.isEmpty {
            appendStringStreams(&streams, propID: 0x007D, value: transportHeaders)
        }

        // Attachments
        for (idx, att) in email.attachments.enumerated() {
            let attachStreams = buildAttachmentStreams(attachment: att, index: idx, depth: depth)
            streams.append(contentsOf: attachStreams)
        }
        return streams
    }

    // MARK: - String Stream Helpers

    private static func appendStringStreams(_ streams: inout [(String, Data)], propID: UInt16, value: String) {
        // Write as Unicode (PT_UNICODE = 0x001F)
        let tag = String(format: "%04X001F", propID)
        if let encoded = value.data(using: .utf16LittleEndian) {
            streams.append(("__substg1.0_\(tag)", encoded))
        }
    }

    // MARK: - Properties Stream

    private static func buildPropertiesStream(email: MBOXParser.RawEmail, header: Int = 32) -> Data {
        // Message properties stream: a reserved header (32 bytes at the root,
        // 24 in an embedded message), then 16-byte entries.
        var data = Data(repeating: 0, count: header)
        // Next recipient / attachment ids and counts live at offsets 8…23 of either header.
        writeUInt32(&data, offset: 12, value: UInt32(email.attachments.count))
        writeUInt32(&data, offset: 20, value: UInt32(email.attachments.count))
        // Each entry: propType (2) + propID (2) + flags (4) + value (8) = 16 bytes

        func appendProp(id: UInt16, type: UInt16, value: UInt64 = 0) {
            var entry = Data(count: 16)
            writeUInt16(&entry, offset: 0, value: type)
            writeUInt16(&entry, offset: 2, value: id)
            writeUInt32(&entry, offset: 4, value: 0x00000006) // flags: readable+writable
            writeUInt64(&entry, offset: 8, value: value)
            data.append(entry)
        }

        // Message flags (MSGFLAG_READ, optionally HAS_ATTACH)
        var msgFlags: UInt64 = 0x01
        if !email.attachments.isEmpty {
            msgFlags |= 0x10
        }
        appendProp(id: 0x0E07, type: 0x0003, value: msgFlags)
        // Message class indicator
        appendProp(id: 0x001A, type: 0x001F, value: 0)
        // Delivery time
        if let date = parseTimestamp(email.timestamp) {
            let ft = dateToFileTime(date)
            appendProp(id: 0x0E06, type: 0x0040, value: ft)
        }
        return data
    }

    // MARK: - Attachment Streams

    private static func buildAttachmentStreams(attachment: AttachmentMetadata, index: Int, depth: Int) -> [(String, Data)] {
        let prefix = "__attach_version1.0_#\(String(format: "%08X", index))"
        var result: [(String, Data)] = []

        // §13.8 step 3: an attached message is written as an EMBEDDED message
        // (PR_ATTACH_METHOD 5) with its own storage, so Outlook shows it as a
        // message and the reader expands it again — round trip, three levels.
        let bytes = attachment.fileURL.flatMap { try? Data(contentsOf: $0) } ?? attachment.base64.flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) }
        let isMessage = attachment.mimeType.lowercased().contains("message/rfc822") || (attachment.filename as NSString).pathExtension.lowercased() == "eml"
        var embedded: MBOXParser.RawEmail?
        if isMessage, depth + 1 < maxEmbeddedDepth, let bytes,
           let raw = String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .isoLatin1),
           let inner = try? MBOXParser.processRawMessage(raw, senderEmail: "") {
            embedded = inner
        }

        // Attachment properties (8-byte header): attach number, attach method.
        var propsData = Data(repeating: 0, count: 8)
        func fixed(_ id: UInt16, _ value: UInt64) {
            var entry = Data(count: 16)
            writeUInt16(&entry, offset: 0, value: 0x0003) // PT_LONG
            writeUInt16(&entry, offset: 2, value: id)
            writeUInt32(&entry, offset: 4, value: 0x00000006)
            writeUInt64(&entry, offset: 8, value: value)
            propsData.append(entry)
        }
        fixed(0x0E21, UInt64(index))                     // PR_ATTACH_NUM
        fixed(0x3705, embedded == nil ? 1 : 5)           // PR_ATTACH_METHOD: by value / embedded message
        result.append(("\(prefix)/__properties_version1.0", propsData))

        // Filename (long) and display name
        if let nameData = attachment.filename.data(using: .utf16LittleEndian) {
            result.append(("\(prefix)/__substg1.0_3707001F", nameData))
            result.append(("\(prefix)/__substg1.0_3001001F", nameData))
        }
        // MIME type
        if let mimeData = attachment.mimeType.data(using: .utf16LittleEndian) {
            result.append(("\(prefix)/__substg1.0_370E001F", mimeData))
        }
        if let embedded {
            for (name, data) in messageStreams(email: embedded, propertiesHeader: 24, depth: depth + 1) {
                result.append(("\(prefix)/__substg1.0_3701000D/\(name)", data))
            }
            for inner in embedded.attachments { if let url = inner.fileURL { try? FileManager.default.removeItem(at: url) } }
            return result
        }
        // Binary content
        if let bytes {
            result.append(("\(prefix)/__substg1.0_37010102", bytes))
        }
        return result
    }

    // MARK: - OLE2 Layout

    /// Lays the streams out as MS-CFB asks: streams under the mini-stream
    /// cutoff (4,096 bytes) live in 64-byte mini sectors inside the root
    /// entry's stream and are chained in the mini FAT; larger streams,
    /// the mini stream itself, the mini FAT and the directory live in
    /// 4,096-byte sectors chained in the FAT. Storages nest to any depth
    /// ("attach/__substg1.0_3701000D/stream"), and every storage's children
    /// form a sibling tree a reader can walk.
    private static func layoutOLE2(streams: [(String, Data)], attachmentCount: Int) throws -> Data {
        struct StreamInfo {
            let dirName: String
            let parentPath: String
            let startSector: Int32
            let size: Int
        }
        var sectorData: [Data] = []            // regular 4,096-byte sectors
        var chains: [(start: Int, count: Int)] = []
        func appendSectors(_ content: Data) -> Int {
            let start = sectorData.count
            var offset = 0
            while offset < content.count {
                let end = min(offset + sectorSize, content.count)
                var sector = Data(content[offset..<end])
                if sector.count < sectorSize { sector.append(Data(repeating: 0, count: sectorSize - sector.count)) }
                sectorData.append(sector)
                offset += sectorSize
            }
            chains.append((start, sectorData.count - start))
            return start
        }

        var infos: [StreamInfo] = []
        var miniStream = Data()
        var miniFat: [Int32] = []
        for (name, content) in streams {
            let parts = name.split(separator: "/").map(String.init)
            let dirName = parts.last ?? name
            let parentPath = parts.dropLast().joined(separator: "/")
            let start: Int32
            if content.isEmpty {
                start = endOfChain
            } else if content.count < miniStreamCutoff {
                let first = miniFat.count
                let count = (content.count + miniSectorSize - 1) / miniSectorSize
                for i in 0..<count { miniFat.append(i < count - 1 ? Int32(first + i + 1) : endOfChain) }
                miniStream.append(content)
                miniStream.append(Data(repeating: 0, count: count * miniSectorSize - content.count))
                start = Int32(first)
            } else {
                start = Int32(appendSectors(content))
            }
            infos.append(StreamInfo(dirName: dirName, parentPath: parentPath, startSector: start, size: content.count))
        }
        let miniStreamStart: Int32 = miniStream.isEmpty ? endOfChain : Int32(appendSectors(miniStream))
        var miniFatStart: Int32 = endOfChain
        var miniFatSectorCount = 0
        if !miniFat.isEmpty {
            var bytes = Data()
            for entry in miniFat { var e = Data(count: 4); writeInt32(&e, offset: 0, value: entry); bytes.append(e) }
            let padded = (bytes.count + sectorSize - 1) / sectorSize * sectorSize
            bytes.append(Data(repeating: 0xFF, count: padded - bytes.count))   // 0xFFFFFFFF = free
            miniFatStart = Int32(appendSectors(bytes))
            miniFatSectorCount = padded / sectorSize
        }

        // Directory entries: root, then storages for every chain prefix, then streams.
        var dirs: [DirEntry] = []
        dirs.append(DirEntry(name: "Root Entry", type: 5, startSector: miniStreamStart, size: Int32(miniStream.count)))
        var storageIndex: [String: Int] = ["": 0]
        var childrenOf: [Int: [Int]] = [:]
        func storage(for path: String) -> Int {
            if let idx = storageIndex[path] { return idx }
            let components = path.split(separator: "/").map(String.init)
            let parent = storage(for: components.dropLast().joined(separator: "/"))
            let idx = dirs.count
            dirs.append(DirEntry(name: components.last ?? path, type: 1))
            storageIndex[path] = idx
            childrenOf[parent, default: []].append(idx)
            return idx
        }
        for info in infos {
            let parent = storage(for: info.parentPath)
            let idx = dirs.count
            dirs.append(DirEntry(name: info.dirName, type: 2, startSector: info.startSector, size: Int32(info.size)))
            childrenOf[parent, default: []].append(idx)
        }
        // Every storage's children form a balanced sibling tree (a reader walks
        // left/right siblings from the storage's child — one link is not enough).
        for (parent, indices) in childrenOf where !indices.isEmpty {
            let sorted = indices.sorted { cfbNameLess(dirs[$0].name, dirs[$1].name) }
            dirs[parent].childID = linkSiblings(&dirs, sorted: sorted[...])
        }
        let dirStartSector = appendSectors(serializeDirectories(dirs))

        // FAT: one entry per regular sector, chained; FAT sectors mark themselves.
        let totalDataSectors = sectorData.count
        let fatEntriesPerSector = sectorSize / 4
        var fatSectorCount = max(1, (totalDataSectors + fatEntriesPerSector - 1) / fatEntriesPerSector)
        while (totalDataSectors + fatSectorCount + fatEntriesPerSector - 1) / fatEntriesPerSector > fatSectorCount { fatSectorCount += 1 }
        let totalSectors = totalDataSectors + fatSectorCount
        var fat = [Int32](repeating: freeSect, count: totalSectors)
        for chain in chains {
            for i in 0..<chain.count { fat[chain.start + i] = i < chain.count - 1 ? Int32(chain.start + i + 1) : endOfChain }
        }
        let fatStartSector = totalDataSectors
        for i in 0..<fatSectorCount { fat[fatStartSector + i] = fatSect }

        // Header (512 bytes, padded to one sector for version 4).
        var header = Data(repeating: 0, count: sectorSize)
        header.replaceSubrange(0..<8, with: ole2Magic)
        writeUInt16(&header, offset: 24, value: 0x003E)                 // minor version
        writeUInt16(&header, offset: 26, value: 0x0004)                 // major version 4 (4,096-byte sectors)
        writeUInt16(&header, offset: 28, value: 0xFFFE)                 // little-endian
        writeUInt16(&header, offset: 30, value: 12)                     // sector size 2^12
        writeUInt16(&header, offset: 32, value: 6)                      // mini sector size 2^6
        writeUInt32(&header, offset: 40, value: UInt32((serializeDirectories(dirs).count + sectorSize - 1) / sectorSize)) // directory sectors (v4)
        writeUInt32(&header, offset: 44, value: UInt32(fatSectorCount))
        writeInt32(&header, offset: 48, value: Int32(dirStartSector))
        writeUInt32(&header, offset: 56, value: UInt32(miniStreamCutoff))
        writeInt32(&header, offset: 60, value: miniFatStart)
        writeUInt32(&header, offset: 64, value: UInt32(miniFatSectorCount))
        writeInt32(&header, offset: 68, value: endOfChain)              // no DIFAT sectors
        writeUInt32(&header, offset: 72, value: 0)
        guard fatSectorCount <= 109 else { throw MSGError.invalidFormat("message too large for a single-DIFAT compound file") }
        for i in 0..<109 {
            writeInt32(&header, offset: 76 + i * 4, value: i < fatSectorCount ? Int32(fatStartSector + i) : freeSect)
        }

        var fileData = Data()
        fileData.append(header)
        for sector in sectorData { fileData.append(sector) }
        for f in 0..<fatSectorCount {
            var fatSector = Data(repeating: 0xFF, count: sectorSize)
            for i in 0..<fatEntriesPerSector {
                let entryIdx = f * fatEntriesPerSector + i
                writeInt32(&fatSector, offset: i * 4, value: entryIdx < fat.count ? fat[entryIdx] : freeSect)
            }
            fileData.append(fatSector)
        }
        logger.debug("MSG file built: \(fileData.count) bytes, \(totalSectors) sectors")
        return fileData
    }

    // MARK: - Directory Serialization

    private static func serializeDirectories(_ dirs: [DirEntry]) -> Data {
        var data = Data()
        for dir in dirs {
            var entry = Data(repeating: 0, count: 128)
            // Name in UTF-16LE (max 32 chars including null)
            let nameChars = Array(dir.name.utf16.prefix(30))
            for (i, ch) in nameChars.enumerated() {
                writeUInt16(&entry, offset: i * 2, value: ch)
            }
            // Name size in bytes (including null terminator)
            writeUInt16(&entry, offset: 64, value: UInt16((nameChars.count + 1) * 2))
            entry[66] = dir.type
            entry[67] = 0x01 // color: black
            writeInt32(&entry, offset: 68, value: dir.leftSiblingID)
            writeInt32(&entry, offset: 72, value: dir.rightSiblingID)
            writeInt32(&entry, offset: 76, value: dir.childID)
            // CLSID (16 bytes at 80) = zeros
            writeInt32(&entry, offset: 116, value: dir.startSector)
            writeInt32(&entry, offset: 120, value: dir.size)
            data.append(entry)
        }
        return data
    }

    // MARK: - Sibling Tree Builder

    /// A balanced binary tree over `sorted`: the middle entry is the root, its
    /// left and right links point at the ROOTS of the two halves (not at the
    /// neighbours — the earlier builder did that and left entries unreachable).
    /// Returns the root's index, or -1 for an empty slice.
    private static func linkSiblings(_ dirs: inout [DirEntry], sorted: ArraySlice<Int>) -> Int32 {
        guard !sorted.isEmpty else { return -1 }
        let mid = sorted.startIndex + sorted.count / 2
        let node = sorted[mid]
        dirs[node].leftSiblingID = linkSiblings(&dirs, sorted: sorted[sorted.startIndex..<mid])
        dirs[node].rightSiblingID = linkSiblings(&dirs, sorted: sorted[(mid + 1)...])
        return Int32(node)
    }

    /// MS-CFB §2.6.4 ordering: shorter names first, then an uppercase compare.
    private static func cfbNameLess(_ a: String, _ b: String) -> Bool {
        if a.utf16.count != b.utf16.count { return a.utf16.count < b.utf16.count }
        return a.uppercased().utf16.lexicographicallyPrecedes(b.uppercased().utf16)
    }

    // MARK: - Helpers

    private static func sanitizeFilename(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let sanitized = name.components(separatedBy: illegal).joined(separator: "_")
        let trimmed = String(sanitized.prefix(100)).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "email" : trimmed
    }

    private static func extractEmailAddr(_ from: String) -> String {
        if let start = from.firstIndex(of: "<"), let end = from.firstIndex(of: ">") {
            return String(from[from.index(after: start)..<end]).trimmingCharacters(in: .whitespaces)
        }
        return from.trimmingCharacters(in: .whitespaces)
    }

    private static func extractDisplayName(_ from: String) -> String {
        if let start = from.firstIndex(of: "<") {
            let name = String(from[from.startIndex..<start]).trimmingCharacters(in: .whitespacesAndNewlines)
            return name.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return from.trimmingCharacters(in: .whitespaces)
    }

    private static func parseTimestamp(_ ts: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: ts)
    }

    private static func dateToFileTime(_ date: Date) -> UInt64 {
        let seconds = date.timeIntervalSince1970 + 11_644_473_600.0
        return UInt64(seconds * 10_000_000.0)
    }

    // MARK: - Binary Write Helpers

    private static func writeUInt16(_ data: inout Data, offset: Int, value: UInt16) {
        while data.count < offset + 2 { data.append(0) }
        data[offset] = UInt8(value & 0xFF)
        data[offset + 1] = UInt8(value >> 8)
    }

    private static func writeUInt32(_ data: inout Data, offset: Int, value: UInt32) {
        while data.count < offset + 4 { data.append(0) }
        data[offset] = UInt8(value & 0xFF)
        data[offset + 1] = UInt8((value >> 8) & 0xFF)
        data[offset + 2] = UInt8((value >> 16) & 0xFF)
        data[offset + 3] = UInt8((value >> 24) & 0xFF)
    }

    private static func writeInt32(_ data: inout Data, offset: Int, value: Int32) {
        writeUInt32(&data, offset: offset, value: UInt32(bitPattern: value))
    }

    private static func writeUInt64(_ data: inout Data, offset: Int, value: UInt64) {
        while data.count < offset + 8 { data.append(0) }
        for i in 0..<8 {
            data[offset + i] = UInt8((value >> (i * 8)) & 0xFF)
        }
    }
}
