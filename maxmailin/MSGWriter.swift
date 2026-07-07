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
        // Collect streams: each is (name, data)
        var streams: [(String, Data)] = []

        // Properties stream (fixed-length properties header)
        let propsData = buildPropertiesStream(email: email)
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
            let attachStreams = buildAttachmentStreams(attachment: att, index: idx)
            streams.append(contentsOf: attachStreams)
        }

        // Layout sectors
        return try layoutOLE2(streams: streams, attachmentCount: email.attachments.count)
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

    private static func buildPropertiesStream(email: MBOXParser.RawEmail) -> Data {
        // Message properties stream has an 8-byte reserved header, then 16-byte entries
        var data = Data(repeating: 0, count: 32)
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

    private static func buildAttachmentStreams(attachment: AttachmentMetadata, index: Int) -> [(String, Data)] {
        let prefix = "__attach_version1.0_#\(String(format: "%08X", index))"
        var result: [(String, Data)] = []

        // Attachment properties
        var propsData = Data(repeating: 0, count: 8)
        var entry = Data(count: 16)
        writeUInt16(&entry, offset: 0, value: 0x0003) // PT_LONG
        writeUInt16(&entry, offset: 2, value: 0x0E21) // attach method = 1 (by value)
        writeUInt32(&entry, offset: 4, value: 0x00000006)
        writeUInt64(&entry, offset: 8, value: 1)
        propsData.append(entry)
        result.append(("\(prefix)/__properties_version1.0", propsData))

        // Filename (long)
        if let nameData = attachment.filename.data(using: .utf16LittleEndian) {
            result.append(("\(prefix)/__substg1.0_3707001F", nameData))
        }
        // MIME type
        if let mimeData = attachment.mimeType.data(using: .utf16LittleEndian) {
            result.append(("\(prefix)/__substg1.0_370E001F", mimeData))
        }
        // Binary content
        if let b64 = attachment.base64, let binData = Data(base64Encoded: b64) {
            result.append(("\(prefix)/__substg1.0_37010102", binData))
        }
        return result
    }

    // MARK: - OLE2 Layout

    private static func layoutOLE2(streams: [(String, Data)], attachmentCount: Int) throws -> Data {
        // Compute sector allocation for all stream data
        var sectorData: [Data] = [] // each entry = one sector of stream content

        struct StreamInfo {
            let dirName: String
            let parentPath: String
            let startSector: Int
            let size: Int
        }

        var streamInfos: [StreamInfo] = []

        for (name, content) in streams {
            let startSector = sectorData.count
            // Split content into sectors
            var offset = 0
            while offset < content.count {
                let end = min(offset + sectorSize, content.count)
                var sector = Data(content[offset..<end])
                if sector.count < sectorSize {
                    sector.append(Data(repeating: 0, count: sectorSize - sector.count))
                }
                sectorData.append(sector)
                offset += sectorSize
            }
            if content.isEmpty {
                // Empty stream still needs a record
                streamInfos.append(StreamInfo(dirName: name, parentPath: "", startSector: -2, size: 0))
            } else {
                let parts = name.split(separator: "/", maxSplits: 1)
                let dirName = String(parts.last ?? Substring(name))
                let parentPath = parts.count > 1 ? String(parts[0]) : ""
                streamInfos.append(StreamInfo(dirName: dirName, parentPath: parentPath, startSector: startSector, size: content.count))
            }
        }

        // Build directory entries
        var dirs: [DirEntry] = []

        // 0: Root Entry
        dirs.append(DirEntry(name: "Root Entry", type: 5))

        // Collect top-level and attachment storage entries
        var topLevelIndices: [Int] = []
        var attachStorageMap: [String: Int] = [:] // path -> dir index

        // First pass: create attachment storages
        for info in streamInfos where !info.parentPath.isEmpty {
            if attachStorageMap[info.parentPath] == nil {
                let idx = dirs.count
                dirs.append(DirEntry(name: info.parentPath, type: 1))
                attachStorageMap[info.parentPath] = idx
                topLevelIndices.append(idx)
            }
        }

        // Second pass: create stream entries
        for info in streamInfos {
            let idx = dirs.count
            dirs.append(DirEntry(
                name: info.dirName,
                type: 2,
                startSector: Int32(info.startSector),
                size: Int32(info.size)
            ))
            if info.parentPath.isEmpty {
                topLevelIndices.append(idx)
            } else if let parentIdx = attachStorageMap[info.parentPath] {
                // Add as child of attachment storage
                if dirs[parentIdx].childID == -1 {
                    dirs[parentIdx].childID = Int32(idx)
                }
            }
        }

        // Build a balanced binary tree for root's children
        if !topLevelIndices.isEmpty {
            buildSiblingTree(&dirs, indices: topLevelIndices)
            dirs[0].childID = Int32(topLevelIndices[topLevelIndices.count / 2])
        }

        // Directory sector data
        let dirData = serializeDirectories(dirs)
        let dirStartSector = sectorData.count
        var dirOffset = 0
        while dirOffset < dirData.count {
            let end = min(dirOffset + sectorSize, dirData.count)
            var sector = Data(dirData[dirOffset..<end])
            if sector.count < sectorSize {
                sector.append(Data(repeating: 0, count: sectorSize - sector.count))
            }
            sectorData.append(sector)
            dirOffset += sectorSize
        }

        // Build FAT
        let totalDataSectors = sectorData.count
        let fatEntriesPerSector = sectorSize / 4
        let fatSectorCount = max(1, (totalDataSectors + 2 + fatEntriesPerSector - 1) / fatEntriesPerSector)

        var fat = [Int32](repeating: freeSect, count: (totalDataSectors + fatSectorCount) * 1)
        // Expand FAT to cover all sectors including FAT sectors themselves
        let totalSectors = totalDataSectors + fatSectorCount
        while fat.count < totalSectors {
            fat.append(freeSect)
        }

        // Chain stream sectors
        for info in streamInfos where info.startSector >= 0 {
            let sectorCount = (info.size + sectorSize - 1) / sectorSize
            for i in 0..<sectorCount {
                let sec = info.startSector + i
                guard sec < fat.count else { break }
                fat[sec] = (i < sectorCount - 1) ? Int32(sec + 1) : endOfChain
            }
        }
        // Chain directory sectors
        let dirSectorCount = (dirData.count + sectorSize - 1) / sectorSize
        for i in 0..<dirSectorCount {
            let sec = dirStartSector + i
            fat[sec] = (i < dirSectorCount - 1) ? Int32(sec + 1) : endOfChain
        }
        // Mark FAT sectors
        let fatStartSector = totalDataSectors
        for i in 0..<fatSectorCount {
            let sec = fatStartSector + i
            if sec < fat.count { fat[sec] = fatSect }
        }

        // Build the file
        var fileData = Data()

        // OLE2 Header (512 bytes, padded to sectorSize for v4)
        var header = Data(repeating: 0, count: sectorSize)
        header.replaceSubrange(0..<8, with: ole2Magic)
        // Minor version
        writeUInt16(&header, offset: 24, value: 0x003E)
        // Major version = 4 (4096-byte sectors)
        writeUInt16(&header, offset: 26, value: 0x0004)
        // Byte order (little-endian)
        writeUInt16(&header, offset: 28, value: 0xFFFE)
        // Sector size power = 12 (4096)
        writeUInt16(&header, offset: 30, value: 12)
        // Mini sector size power = 6 (64)
        writeUInt16(&header, offset: 32, value: 6)
        // Total directory sectors (v4 = 0)
        writeUInt32(&header, offset: 40, value: 0)
        // Total FAT sectors
        writeUInt32(&header, offset: 44, value: UInt32(fatSectorCount))
        // First directory sector
        writeInt32(&header, offset: 48, value: Int32(dirStartSector))
        // Mini stream cutoff
        writeUInt32(&header, offset: 56, value: UInt32(miniStreamCutoff))
        // First mini FAT sector (none)
        writeInt32(&header, offset: 60, value: endOfChain)
        // Mini FAT sector count
        writeUInt32(&header, offset: 64, value: 0)
        // First DIFAT sector (none)
        writeInt32(&header, offset: 68, value: endOfChain)
        // DIFAT sector count
        writeUInt32(&header, offset: 72, value: 0)
        // DIFAT array (109 entries starting at offset 76)
        for i in 0..<109 {
            if i < fatSectorCount {
                writeInt32(&header, offset: 76 + i * 4, value: Int32(fatStartSector + i))
            } else {
                writeInt32(&header, offset: 76 + i * 4, value: freeSect)
            }
        }
        fileData.append(header)

        // Write data sectors (streams + directories)
        for i in 0..<totalDataSectors {
            if i < sectorData.count {
                fileData.append(sectorData[i])
            } else {
                fileData.append(Data(repeating: 0, count: sectorSize))
            }
        }

        // Write FAT sectors
        for f in 0..<fatSectorCount {
            var fatSector = Data(repeating: 0xFF, count: sectorSize) // fill with 0xFF = free
            let baseEntry = f * fatEntriesPerSector
            for i in 0..<fatEntriesPerSector {
                let entryIdx = baseEntry + i
                if entryIdx < fat.count {
                    writeInt32(&fatSector, offset: i * 4, value: fat[entryIdx])
                } else {
                    writeInt32(&fatSector, offset: i * 4, value: freeSect)
                }
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

    private static func buildSiblingTree(_ dirs: inout [DirEntry], indices: [Int]) {
        guard indices.count > 1 else { return }
        let sorted = indices.sorted { dirs[$0].name < dirs[$1].name }
        let mid = sorted.count / 2
        if mid > 0 {
            dirs[sorted[mid]].leftSiblingID = Int32(sorted[mid - 1])
            // Build left subtree
            if mid > 1 {
                let leftIndices = Array(sorted[0..<mid])
                buildSiblingTree(&dirs, indices: leftIndices)
            }
        }
        if mid < sorted.count - 1 {
            dirs[sorted[mid]].rightSiblingID = Int32(sorted[mid + 1])
            if mid + 2 < sorted.count {
                let rightIndices = Array(sorted[(mid + 1)...])
                buildSiblingTree(&dirs, indices: Array(rightIndices))
            }
        }
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
