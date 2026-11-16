import Foundation
import os.log

/// Why a .msg (or another compound file) could not be written — the reason a
/// caller shows (review 2026-11-16 B13: the writer used to return nil and keep
/// the reason in the log only).
enum MSGWriterError: LocalizedError, Equatable {
    /// MS-CFB §2.6.1: a directory entry name is at most 31 UTF-16 code units.
    case entryNameTooLong(String)
    /// MS-CFB §2.2: sector numbers stop at MAXREGSECT (0xFFFFFFFA).
    case fileTooLarge(sectors: UInt64)
    /// Version 3 (512-byte sector) files hold streams below 2 GiB only.
    case streamTooLargeForVersion3(path: String, bytes: Int)

    var errorDescription: String? {
        switch self {
        case .entryNameTooLong(let name):
            return "The .msg file could not be written: the storage name \"\(name)\" is longer than the 31 characters a compound file allows."
        case .fileTooLarge(let sectors):
            return "The .msg file could not be written: it would need \(sectors) sectors, more than a compound file can number (4,294,967,290 sectors of 4 KB, about 16 TB)."
        case .streamTooLargeForVersion3(let path, let bytes):
            return "The compound file could not be written: the stream \(path) is \(bytes) bytes; a version 3 compound file holds streams below 2 GB."
        }
    }
}

/// Outlook .msg writer: an MS-CFB compound file (version 4, 4,096-byte
/// sectors, DIFAT for files above about 457 MB) laid out as MS-OXMSG asks —
/// a properties stream per storage whose entries match every property
/// stream and storage written, the named-property mapping storage,
/// PR_MESSAGE_CLASS, one recipient storage per To / Cc / Bcc address and one
/// attachment storage per attachment (embedded messages as embedded message
/// storages).
struct MSGWriter {

    private static let logger = Logger(subsystem: "com.mailin", category: "MSGWriter")

    // MARK: - Public API

    /// Write a single RawEmail to .msg format, returning the file data; nil on
    /// failure (the reason is logged). Prefer `data(for:)`, which throws the
    /// reason so it can be shown.
    static func write(email: MBOXParser.RawEmail) -> Data? {
        do {
            return try data(for: email)
        } catch {
            logger.error("Failed to write MSG: \(error.localizedDescription)")
            return nil
        }
    }

    /// The .msg file for `email`, or a thrown `MSGWriterError` naming why it
    /// cannot be written.
    static func data(for email: MBOXParser.RawEmail) throws -> Data {
        let streams = try messageStreams(email: email, kind: .topLevel, depth: 0)
        return try layoutOLE2(streams: streams, sectorShift: 12, rootCLSID: messageCLSID)
    }

    /// Write multiple emails as individual .msg files into a folder. Returns
    /// the count written; a message that cannot be written throws its reason.
    static func writeMultiple(emails: [MBOXParser.RawEmail], to folder: URL) throws -> Int {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var count = 0
        for email in emails {
            let data = try data(for: email)
            let safeName = sanitizeFilename(email.headers["Subject"] ?? "email_\(count + 1)")
            let fileURL = folder.appendingPathComponent("\(safeName).msg")
            try data.write(to: fileURL, options: .atomic)
            count += 1
        }
        logger.info("Wrote \(count) MSG files to \(folder.path)")
        return count
    }

    /// Any compound file from named streams ("storage/sub/stream" paths) —
    /// also how an encrypted Office package is assembled for fixtures.
    /// `sectorShift` 12 = version 4 (4,096-byte sectors), 9 = version 3 (512).
    static func compoundFile(streams: [(String, Data)], sectorShift: Int = 12) throws -> Data {
        try layoutOLE2(streams: streams, sectorShift: sectorShift, rootCLSID: nil)
    }

    /// Messages attached as messages are written as embedded messages this
    /// many levels deep (matches `MSGParser.maxEmbeddedDepth`).
    static let maxEmbeddedDepth = 3

    // MARK: - OLE2 Constants

    private static let miniSectorSize = 64
    private static let miniStreamCutoff = 4096
    private static let ole2Magic: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
    private static let endOfChain: UInt32 = 0xFFFF_FFFE
    private static let freeSect: UInt32 = 0xFFFF_FFFF
    private static let fatSect: UInt32 = 0xFFFF_FFFD
    private static let difSect: UInt32 = 0xFFFF_FFFC
    private static let noStream: UInt32 = 0xFFFF_FFFF
    private static let maxRegSect: UInt64 = 0xFFFF_FFFA
    /// CLSID_MailMessage {00020D0B-0000-0000-C000-000000000046}, as Outlook stamps a .msg root.
    private static let messageCLSID = Data([0x0B, 0x0D, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00,
                                            0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46])

    // MARK: - MAPI properties

    /// One property of a storage. Fixed-size values live in the properties
    /// stream; variable-size ones in a `__substg1.0_<tag>` stream (or, for an
    /// embedded message, a storage) with an entry recording their size.
    private enum Value {
        case long(UInt32)
        case bool(Bool)
        case time(UInt64)
        case unicode(String)
        case binary(Data)
        /// PT_OBJECT: the storage's content is written separately.
        case object

        var type: UInt16 {
            switch self {
            case .long: return 0x0003
            case .bool: return 0x000B
            case .time: return 0x0040
            case .unicode: return 0x001F
            case .binary: return 0x0102
            case .object: return 0x000D
            }
        }
    }

    /// MS-OXMSG §2.4.1: the properties stream header — 32 bytes for the
    /// top-level message, 24 for an embedded message, 8 for a recipient or
    /// attachment storage.
    private enum StorageKind {
        case topLevel, embedded, recipientOrAttachment
        var headerSize: Int {
            switch self { case .topLevel: return 32; case .embedded: return 24; case .recipientOrAttachment: return 8 }
        }
    }

    /// The streams of one storage: the properties stream, then one stream per
    /// variable-length property. Object properties are entries only.
    private static func propertyStreams(_ props: [(UInt16, Value)], kind: StorageKind,
                                        recipients: Int = 0, attachments: Int = 0) -> [(String, Data)] {
        var header = Data(repeating: 0, count: kind.headerSize)
        if kind != .recipientOrAttachment {
            writeUInt32(&header, offset: 8, value: UInt32(clamping: recipients))   // next recipient ID
            writeUInt32(&header, offset: 12, value: UInt32(clamping: attachments)) // next attachment ID
            writeUInt32(&header, offset: 16, value: UInt32(clamping: recipients))  // recipient count
            writeUInt32(&header, offset: 20, value: UInt32(clamping: attachments)) // attachment count
        }
        var stream = header
        var substreams: [(String, Data)] = []
        for (id, value) in props {
            var entry = Data(count: 16)
            writeUInt16(&entry, offset: 0, value: value.type)
            writeUInt16(&entry, offset: 2, value: id)
            writeUInt32(&entry, offset: 4, value: 0x0000_0006)          // PROPATTR_READABLE | PROPATTR_WRITABLE
            let tag = String(format: "%04X%04X", id, value.type)
            switch value {
            case .long(let v): writeUInt32(&entry, offset: 8, value: v)
            case .bool(let b): entry[8] = b ? 1 : 0
            case .time(let t): writeUInt64(&entry, offset: 8, value: t)
            case .unicode(let s):
                let bytes = s.data(using: .utf16LittleEndian) ?? Data()
                // Size: the stream's bytes plus the 2-byte terminating null (§2.4.2.2).
                writeUInt32(&entry, offset: 8, value: UInt32(clamping: bytes.count + 2))
                substreams.append(("__substg1.0_\(tag)", bytes))
            case .binary(let d):
                writeUInt32(&entry, offset: 8, value: UInt32(clamping: d.count))
                substreams.append(("__substg1.0_\(tag)", d))
            case .object:
                writeUInt32(&entry, offset: 8, value: 0xFFFF_FFFF)
            }
            stream.append(entry)
        }
        return [("__properties_version1.0", stream)] + substreams
    }

    // MARK: - Build MSG

    /// The streams of one message storage, paths relative to it.
    private static func messageStreams(email: MBOXParser.RawEmail, kind: StorageKind, depth: Int) throws -> [(String, Data)] {
        var props: [(UInt16, Value)] = []
        props.append((0x001A, .unicode("IPM.Note")))                               // PR_MESSAGE_CLASS
        var msgFlags: UInt32 = 0x01                                                // MSGFLAG_READ
        if !email.attachments.isEmpty { msgFlags |= 0x10 }                         // MSGFLAG_HASATTACH
        props.append((0x0E07, .long(msgFlags)))                                    // PR_MESSAGE_FLAGS
        props.append((0x340D, .long(0x0004_0000)))                                 // PR_STORE_SUPPORT_MASK: STORE_UNICODE_OK
        if let subj = email.headers["Subject"] { props.append((0x0037, .unicode(subj))) }
        if let from = email.headers["From"] {
            let address = extractEmailAddr(from), name = extractDisplayName(from)
            props.append((0x0C1A, .unicode(name)))                                 // PR_SENDER_NAME
            props.append((0x0C1E, .unicode("SMTP")))                               // PR_SENDER_ADDRTYPE
            props.append((0x0C1F, .unicode(address)))                              // PR_SENDER_EMAIL_ADDRESS
            props.append((0x0042, .unicode(name)))                                 // PR_SENT_REPRESENTING_NAME
            props.append((0x0064, .unicode("SMTP")))                               // PR_SENT_REPRESENTING_ADDRTYPE
            props.append((0x0065, .unicode(address)))                              // PR_SENT_REPRESENTING_EMAIL_ADDRESS
        }
        if let to = email.headers["To"] { props.append((0x0E04, .unicode(to))) }   // PR_DISPLAY_TO
        if let cc = email.headers["Cc"] { props.append((0x0E03, .unicode(cc))) }   // PR_DISPLAY_CC
        if let bcc = email.headers["Bcc"] { props.append((0x0E02, .unicode(bcc))) } // PR_DISPLAY_BCC
        if !email.plainBody.isEmpty { props.append((0x1000, .unicode(email.plainBody))) }
        if !email.htmlBody.isEmpty {
            props.append((0x1013, .binary(Data(email.htmlBody.utf8))))             // PR_HTML
            props.append((0x3FDE, .long(65001)))                                   // PR_INTERNET_CPID: UTF-8
        }
        if let msgID = email.headers["Message-ID"] { props.append((0x1035, .unicode(msgID))) }
        let transportHeaders = email.headers.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n")
        if !transportHeaders.isEmpty { props.append((0x007D, .unicode(transportHeaders))) }
        if let date = parseTimestamp(email.timestamp) {
            let ft = dateToFileTime(date)
            props.append((0x0039, .time(ft)))                                      // PR_CLIENT_SUBMIT_TIME
            props.append((0x0E06, .time(ft)))                                      // PR_MESSAGE_DELIVERY_TIME
        }

        // Recipients: one storage per address (MS-OXMSG §2.2.1).
        var recipients: [(name: String, email: String, type: UInt32)] = []
        for (header, type) in [("To", UInt32(1)), ("Cc", 2), ("Bcc", 3)] {
            for a in PSTSpecWriter.addresses(email.headers[header]) { recipients.append((a.name, a.email, type)) }
        }

        var streams = propertyStreams(props, kind: kind, recipients: recipients.count, attachments: email.attachments.count)
        if kind == .topLevel {
            // MS-OXMSG §2.2.3: the named property mapping storage. No named
            // properties are written, so its three streams are empty.
            for stream in ["__substg1.0_00020102", "__substg1.0_00030102", "__substg1.0_00040102"] {
                streams.append(("__nameid_version1.0/\(stream)", Data()))
            }
        }
        for (i, r) in recipients.enumerated() {
            let prefix = "__recip_version1.0_#\(String(format: "%08X", i))"
            let rp: [(UInt16, Value)] = [
                (0x0C15, .long(r.type)),                                           // PR_RECIPIENT_TYPE
                (0x3000, .long(UInt32(clamping: i))),                              // PR_ROWID
                (0x0FFE, .long(6)),                                                // PR_OBJECT_TYPE: MAPI_MAILUSER
                (0x3900, .long(0)),                                                // PR_DISPLAY_TYPE: DT_MAILUSER
                (0x0FFF, .binary(PSTSpecWriter.oneOffEntryID(name: r.name, email: r.email))), // PR_ENTRYID
                (0x3001, .unicode(r.name)),                                        // PR_DISPLAY_NAME
                (0x3002, .unicode("SMTP")),                                        // PR_ADDRTYPE
                (0x3003, .unicode(r.email)),                                       // PR_EMAIL_ADDRESS
                (0x39FE, .unicode(r.email)),                                       // PR_SMTP_ADDRESS
                (0x5FF6, .unicode(r.name)),                                        // PR_RECIPIENT_DISPLAY_NAME
            ]
            for (name, data) in propertyStreams(rp, kind: .recipientOrAttachment) { streams.append(("\(prefix)/\(name)", data)) }
        }

        for (idx, att) in email.attachments.enumerated() {
            streams.append(contentsOf: try buildAttachmentStreams(attachment: att, index: idx, depth: depth, email: email))
        }
        return streams
    }

    // MARK: - Attachment Streams

    private static func buildAttachmentStreams(attachment: AttachmentMetadata, index: Int, depth: Int, email: MBOXParser.RawEmail) throws -> [(String, Data)] {
        let prefix = "__attach_version1.0_#\(String(format: "%08X", index))"

        // §13.8 step 3: an attached message is written as an EMBEDDED message
        // (PR_ATTACH_METHOD 5) with its own storage, so Outlook shows it as a
        // message and the reader expands it again — round trip, three levels.
        // OUT-04: a stored message keeps its attachment bytes in its raw source,
        // not inline — the hydrator re-extracts them (temp file, inline payload,
        // byte range or raw message), so an exported .msg carries every file whole.
        let bytes = AttachmentHydrator.data(for: attachment, index: index, email: email)
        let isMessage = attachment.mimeType.lowercased().contains("message/rfc822") || (attachment.filename as NSString).pathExtension.lowercased() == "eml"
        var embedded: MBOXParser.RawEmail?
        if isMessage, depth + 1 < maxEmbeddedDepth, let bytes,
           let raw = String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .isoLatin1),
           let inner = try? MBOXParser.processRawMessage(raw, senderEmail: "") {
            embedded = inner
        }
        defer {
            if let embedded { for inner in embedded.attachments { if let url = inner.fileURL { try? FileManager.default.removeItem(at: url) } } }
        }

        var ap: [(UInt16, Value)] = [
            (0x0E21, .long(UInt32(clamping: index))),                              // PR_ATTACH_NUM
            (0x3705, .long(embedded == nil ? 1 : 5)),                              // PR_ATTACH_METHOD: by value / embedded message
            (0x370B, .long(0xFFFF_FFFF)),                                          // PR_RENDERING_POSITION: none
            (0x3707, .unicode(attachment.filename)),                               // PR_ATTACH_LONG_FILENAME
            (0x3001, .unicode(attachment.filename)),                               // PR_DISPLAY_NAME
            (0x370E, .unicode(attachment.mimeType)),                               // PR_ATTACH_MIME_TAG
        ]
        let ext = (attachment.filename as NSString).pathExtension
        if !ext.isEmpty { ap.append((0x3703, .unicode("." + ext))) }              // PR_ATTACH_EXTENSION
        // D-5 (owner, 2026-11-16; MS-OXCMSG 2.2.2.29 / 2.2.2.18 / PidTagAttachmentHidden):
        // the Content-ID is written for every attachment that has one, so an
        // HTML body's cid: references resolve. An inline attachment is hidden
        // from the attachment list (PR_ATTACHMENT_HIDDEN = true) and, when the
        // HTML body references it by Content-ID, flagged ATT_MHTML_REF; every
        // other attachment says hidden = false, so a Content-ID alone does not
        // make the reader take it for inline. ExportReconciliation's .msg rules
        // check both facts (they are no longer "not carried").
        let contentID = attachment.contentID?.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n")) ?? ""
        if !contentID.isEmpty { ap.append((0x3712, .unicode(contentID))) }         // PR_ATTACH_CONTENT_ID
        ap.append((0x7FFE, .bool(attachment.isInline && embedded == nil)))      // PR_ATTACHMENT_HIDDEN
        if attachment.isInline, embedded == nil, !contentID.isEmpty {
            ap.append((0x3714, .long(0x0000_0004)))                                // PR_ATTACH_FLAGS: ATT_MHTML_REF
        }
        if let bytes { ap.append((0x0E20, .long(UInt32(clamping: bytes.count)))) } // PR_ATTACH_SIZE
        if embedded != nil {
            ap.append((0x3701, .object))                                           // PR_ATTACH_DATA_OBJ
        } else if let bytes {
            ap.append((0x3701, .binary(bytes)))                                    // PR_ATTACH_DATA_BIN
        }
        var result = propertyStreams(ap, kind: .recipientOrAttachment).map { ("\(prefix)/\($0.0)", $0.1) }
        if let embedded {
            for (name, data) in try messageStreams(email: embedded, kind: .embedded, depth: depth + 1) {
                result.append(("\(prefix)/__substg1.0_3701000D/\(name)", data))
            }
        }
        return result
    }

    // MARK: - OLE2 Layout

    private struct DirEntry {
        var name: String
        var type: UInt8         // 1 = storage, 2 = stream, 5 = root
        var red = false
        var childID: UInt32 = noStream
        var leftSiblingID: UInt32 = noStream
        var rightSiblingID: UInt32 = noStream
        var clsid: Data? = nil
        var startSector: UInt32 = 0
        var size: UInt64 = 0
    }

    /// Lays the streams out as MS-CFB asks: streams under the mini-stream
    /// cutoff (4,096 bytes) live in 64-byte mini sectors inside the root
    /// entry's stream and are chained in the mini FAT; larger streams,
    /// the mini stream itself, the mini FAT and the directory live in
    /// regular sectors chained in the FAT. The FAT's sectors are listed in the
    /// header (first 109) and in DIFAT sectors after that. Storages nest to
    /// any depth ("attach/__substg1.0_3701000D/stream"), and every storage's
    /// children form a red-black sibling tree a reader can walk.
    private static func layoutOLE2(streams: [(String, Data)], sectorShift: Int, rootCLSID: Data?) throws -> Data {
        let sectorSize = 1 << sectorShift
        let version3 = sectorShift == 9
        struct StreamInfo {
            let dirName: String
            let parentPath: String
            let startSector: UInt32
            let size: Int
        }
        var body = Data()                               // the regular sectors, in order
        var chains: [(start: Int, count: Int)] = []
        func appendSectors(_ content: Data) -> Int {
            let start = body.count / sectorSize
            body.append(content)
            let padded = (content.count + sectorSize - 1) / sectorSize * sectorSize
            body.append(Data(repeating: 0, count: padded - content.count))
            chains.append((start, padded / sectorSize))
            return start
        }

        var infos: [StreamInfo] = []
        var miniStream = Data()
        var miniFat: [UInt32] = []
        for (name, content) in streams {
            let parts = name.split(separator: "/").map(String.init)
            for part in parts where part.utf16.count > 31 { throw MSGWriterError.entryNameTooLong(part) }
            if version3, content.count >= 0x8000_0000 { throw MSGWriterError.streamTooLargeForVersion3(path: name, bytes: content.count) }
            let dirName = parts.last ?? name
            let parentPath = parts.dropLast().joined(separator: "/")
            let start: UInt32
            if content.isEmpty {
                start = endOfChain
            } else if content.count < miniStreamCutoff {
                let first = miniFat.count
                let count = (content.count + miniSectorSize - 1) / miniSectorSize
                for i in 0..<count { miniFat.append(i < count - 1 ? UInt32(first + i + 1) : endOfChain) }
                miniStream.append(content)
                miniStream.append(Data(repeating: 0, count: count * miniSectorSize - content.count))
                start = UInt32(first)
            } else {
                start = UInt32(truncatingIfNeeded: appendSectors(content))
            }
            infos.append(StreamInfo(dirName: dirName, parentPath: parentPath, startSector: start, size: content.count))
        }
        let miniStreamStart: UInt32 = miniStream.isEmpty ? endOfChain : UInt32(truncatingIfNeeded: appendSectors(miniStream))
        var miniFatStart: UInt32 = endOfChain
        var miniFatSectorCount = 0
        if !miniFat.isEmpty {
            var bytes = Data(capacity: miniFat.count * 4)
            for entry in miniFat { appendLE32(&bytes, entry) }
            let padded = (bytes.count + sectorSize - 1) / sectorSize * sectorSize
            bytes.append(Data(repeating: 0xFF, count: padded - bytes.count))   // FREESECT
            miniFatStart = UInt32(truncatingIfNeeded: appendSectors(bytes))
            miniFatSectorCount = padded / sectorSize
        }

        // Directory entries: root, then storages for every path prefix, then streams.
        var dirs: [DirEntry] = []
        dirs.append(DirEntry(name: "Root Entry", type: 5, clsid: rootCLSID, startSector: miniStreamStart, size: UInt64(miniStream.count)))
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
            dirs.append(DirEntry(name: info.dirName, type: 2, startSector: info.startSector, size: UInt64(info.size)))
            childrenOf[parent, default: []].append(idx)
        }
        // Every storage's children form a balanced sibling tree, coloured as
        // a valid red-black tree (MS-CFB §2.6.4).
        for (parent, indices) in childrenOf where !indices.isEmpty {
            let sorted = indices.sorted { cfbNameLess(dirs[$0].name, dirs[$1].name) }
            let perfect = (sorted.count + 1) & sorted.count == 0
            var deepest = 0
            while (1 << (deepest + 1)) - 1 < sorted.count { deepest += 1 }
            dirs[parent].childID = linkSiblings(&dirs, sorted: sorted[...], depth: 0, redDepth: perfect ? nil : deepest)
        }
        var directory = serializeDirectories(dirs, version3: version3)
        let entriesPerDirSector = sectorSize / 128
        let unused = (entriesPerDirSector - dirs.count % entriesPerDirSector) % entriesPerDirSector
        for _ in 0..<unused { directory.append(freeDirectoryEntry()) }
        let dirSectorCount = directory.count / sectorSize
        let dirStartSector = appendSectors(directory)

        // FAT and DIFAT: F FAT sectors must cover every sector, including
        // themselves and the X DIFAT sectors that list FAT sectors 110 onward.
        let dataSectors = body.count / sectorSize
        let perSector = sectorSize / 4
        var fatSectorCount = max(1, (dataSectors + perSector - 1) / perSector)
        var difatSectorCount = 0
        while true {
            difatSectorCount = fatSectorCount <= 109 ? 0 : (fatSectorCount - 109 + perSector - 2) / (perSector - 1)
            if fatSectorCount * perSector >= dataSectors + fatSectorCount + difatSectorCount { break }
            fatSectorCount += 1
        }
        let totalSectors = dataSectors + fatSectorCount + difatSectorCount
        guard UInt64(totalSectors) <= maxRegSect else { throw MSGWriterError.fileTooLarge(sectors: UInt64(totalSectors)) }
        let fatStart = dataSectors, difatStart = dataSectors + fatSectorCount

        var fat = [UInt32](repeating: freeSect, count: fatSectorCount * perSector)
        for chain in chains {
            for i in 0..<chain.count { fat[chain.start + i] = i < chain.count - 1 ? UInt32(chain.start + i + 1) : endOfChain }
        }
        for i in 0..<fatSectorCount { fat[fatStart + i] = fatSect }
        for i in 0..<difatSectorCount { fat[difatStart + i] = difSect }

        // Header: 512 bytes (padded to one sector in version 4).
        var header = Data(repeating: 0, count: version3 ? 512 : sectorSize)
        header.replaceSubrange(0..<8, with: ole2Magic)
        writeUInt16(&header, offset: 24, value: 0x003E)                 // minor version
        writeUInt16(&header, offset: 26, value: version3 ? 3 : 4)       // major version
        writeUInt16(&header, offset: 28, value: 0xFFFE)                 // little-endian
        writeUInt16(&header, offset: 30, value: UInt16(sectorShift))    // sector size 2^shift
        writeUInt16(&header, offset: 32, value: 6)                      // mini sector size 2^6
        writeUInt32(&header, offset: 40, value: version3 ? 0 : UInt32(dirSectorCount)) // directory sectors (v4 only)
        writeUInt32(&header, offset: 44, value: UInt32(fatSectorCount))
        writeUInt32(&header, offset: 48, value: UInt32(dirStartSector))
        writeUInt32(&header, offset: 56, value: UInt32(miniStreamCutoff))
        writeUInt32(&header, offset: 60, value: miniFatStart)
        writeUInt32(&header, offset: 64, value: UInt32(miniFatSectorCount))
        writeUInt32(&header, offset: 68, value: difatSectorCount == 0 ? endOfChain : UInt32(difatStart))
        writeUInt32(&header, offset: 72, value: UInt32(difatSectorCount))
        for i in 0..<109 {
            writeUInt32(&header, offset: 76 + i * 4, value: i < fatSectorCount ? UInt32(fatStart + i) : freeSect)
        }

        var fileData = Data(capacity: header.count + totalSectors * sectorSize)
        fileData.append(header)
        fileData.append(body)
        body = Data()
        for entry in fat { appendLE32(&fileData, entry) }
        // DIFAT sectors: perSector − 1 FAT sector numbers, then the next DIFAT sector.
        var listed = 109
        for k in 0..<difatSectorCount {
            for _ in 0..<(perSector - 1) {
                appendLE32(&fileData, listed < fatSectorCount ? UInt32(fatStart + listed) : freeSect)
                listed += 1
            }
            appendLE32(&fileData, k < difatSectorCount - 1 ? UInt32(difatStart + k + 1) : endOfChain)
        }
        logger.debug("Compound file built: \(fileData.count) bytes, \(totalSectors) sectors, \(difatSectorCount) DIFAT")
        return fileData
    }

    // MARK: - Directory Serialization

    private static func serializeDirectories(_ dirs: [DirEntry], version3: Bool) -> Data {
        var data = Data(capacity: dirs.count * 128)
        for dir in dirs {
            var entry = Data(repeating: 0, count: 128)
            // Name in UTF-16LE, at most 31 code units plus the terminating null (checked in layout).
            let nameChars = Array(dir.name.utf16.prefix(31))
            for (i, ch) in nameChars.enumerated() {
                writeUInt16(&entry, offset: i * 2, value: ch)
            }
            writeUInt16(&entry, offset: 64, value: UInt16((nameChars.count + 1) * 2))
            entry[66] = dir.type
            entry[67] = dir.red ? 0x00 : 0x01
            writeUInt32(&entry, offset: 68, value: dir.leftSiblingID)
            writeUInt32(&entry, offset: 72, value: dir.rightSiblingID)
            writeUInt32(&entry, offset: 76, value: dir.childID)
            if let clsid = dir.clsid, clsid.count == 16 { entry.replaceSubrange(80..<96, with: clsid) }
            writeUInt32(&entry, offset: 116, value: dir.startSector)
            // Stream size: 64-bit in version 4; version 3 writers leave the high half zero.
            writeUInt64(&entry, offset: 120, value: version3 ? dir.size & 0xFFFF_FFFF : dir.size)
            data.append(entry)
        }
        return data
    }

    /// An unused directory entry (MS-CFB §2.6.3): no name, type 0, sibling and child links NOSTREAM.
    private static func freeDirectoryEntry() -> Data {
        var entry = Data(repeating: 0, count: 128)
        writeUInt32(&entry, offset: 68, value: noStream)
        writeUInt32(&entry, offset: 72, value: noStream)
        writeUInt32(&entry, offset: 76, value: noStream)
        return entry
    }

    // MARK: - Sibling Tree Builder

    /// A balanced binary tree over `sorted`: the middle entry is the root, its
    /// left and right links point at the ROOTS of the two halves. Every level
    /// but the last is full, so colouring the last level red (when the tree is
    /// not perfect) and everything else black gives every path the same number
    /// of black nodes. Returns the root's index, or NOSTREAM for an empty slice.
    private static func linkSiblings(_ dirs: inout [DirEntry], sorted: ArraySlice<Int>, depth: Int, redDepth: Int?) -> UInt32 {
        guard !sorted.isEmpty else { return noStream }
        let mid = sorted.startIndex + sorted.count / 2
        let node = sorted[mid]
        dirs[node].red = depth == redDepth
        dirs[node].leftSiblingID = linkSiblings(&dirs, sorted: sorted[sorted.startIndex..<mid], depth: depth + 1, redDepth: redDepth)
        dirs[node].rightSiblingID = linkSiblings(&dirs, sorted: sorted[(mid + 1)...], depth: depth + 1, redDepth: redDepth)
        return UInt32(node)
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
        if let start = from.firstIndex(of: "<"), let end = from.firstIndex(of: ">"), start < end {
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
        return seconds > 0 ? UInt64(seconds * 10_000_000.0) : 0
    }

    // MARK: - Binary Write Helpers

    private static func appendLE32(_ data: inout Data, _ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

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

    private static func writeUInt64(_ data: inout Data, offset: Int, value: UInt64) {
        while data.count < offset + 8 { data.append(0) }
        for i in 0..<8 {
            data[offset + i] = UInt8((value >> (i * 8)) & 0xFF)
        }
    }
}
