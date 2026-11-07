//
//  TNEFReader.swift
//  ArchiveCore
//
//  Plan v4 §13.8 step 3 (COMP-07): Transport Neutral Encapsulation Format —
//  the `winmail.dat` Outlook wraps a message's rich body and its files in
//  when it sends through a server that does not speak MAPI. Read per
//  MS-OXTNEF: a signature, a key, then attributes at message level (1) and
//  attachment level (2), each `level(1) id(4) length(4) data checksum(2)`.
//  The message's subject and bodies (plain, HTML, compressed RTF) come out as
//  text; every attachment comes out with its name, MIME type and bytes so it
//  becomes a child document of the winmail.dat attachment. An embedded
//  message inside the TNEF is listed, not expanded (stated in the registry).
//

import Foundation

enum TNEFReader {

    static let signature: UInt32 = 0x223E_9F78

    struct Attachment: Sendable, Equatable {
        var filename: String
        var mimeType: String
        var data: Data
        /// PR_ATTACH_METHOD 5: a message, which this reader does not expand.
        var isEmbeddedMessage = false
    }

    struct Content: Sendable {
        var messageClass: String?
        var subject: String?
        var body: String?
        var html: String?
        var rtfText: String?
        var attachments: [Attachment] = []
        /// What was not read whole — a checksum that did not match, an embedded message.
        var notes: [String] = []

        /// The best text body: plain, else HTML with tags removed, else decoded RTF.
        var bodyText: String {
            if let body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return body }
            if let html, !html.isEmpty { return html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression) }
            return rtfText ?? ""
        }
    }

    enum ReadError: Error, Equatable {
        case notTNEF
        case truncated(String)
    }

    static func isTNEF(_ data: Data) -> Bool {
        data.count >= 6 && readUInt32(data, 0) == signature
    }

    static func isTNEF(fileURL: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 6) else { return false }
        return isTNEF(head)
    }

    // Attribute IDs (low 16 bits of the attribute word).
    private enum Attr: UInt16 {
        case from = 0x8000, subject = 0x8004, dateSent = 0x8005, messageClass = 0x8008
        case body = 0x800C, attachData = 0x800F, attachTitle = 0x8010
        case attachRendData = 0x9002, mapiProps = 0x9003, attachment = 0x9005
        case tnefVersion = 0x9006, oemCodepage = 0x9007
    }

    static func read(_ data: Data) throws -> Content {
        guard isTNEF(data) else { throw ReadError.notTNEF }
        var content = Content()
        var encoding = String.Encoding.windowsCP1252
        var current: Attachment?
        var position = 6   // signature + key
        var index = 0
        while position + 9 <= data.count {
            let level = data[data.startIndex + position]
            let word = readUInt32(data, position + 1)
            let length = Int(readUInt32(data, position + 5))
            position += 9
            guard length >= 0, position + length + 2 <= data.count else {
                throw ReadError.truncated("attribute \(index) at byte \(position - 9) claims \(length) bytes beyond the end of the file")
            }
            let payload = data.subdata(in: (data.startIndex + position)..<(data.startIndex + position + length))
            let checksum = readUInt16(data, position + length)
            position += length + 2
            index += 1
            let sum = payload.reduce(UInt32(0)) { ($0 + UInt32($1)) & 0xFFFF }
            if UInt16(sum) != checksum { content.notes.append("checksum mismatch in attribute \(index)") }

            guard let attribute = Attr(rawValue: UInt16(word & 0xFFFF)) else { continue }
            switch attribute {
            case .oemCodepage:
                if payload.count >= 4 { encoding = Self.encoding(forCodepage: readUInt32(payload, 0)) ?? encoding }
            case .subject:
                content.subject = string(payload, encoding)
            case .body:
                content.body = string(payload, encoding)
            case .messageClass:
                content.messageClass = string(payload, encoding)
            case .mapiProps where level == 1:
                let props = parseMAPIProperties(payload, encoding: encoding)
                if content.subject == nil { content.subject = props.strings[0x0037] }
                if content.body == nil { content.body = props.strings[0x1000] }
                if let html = props.binaries[0x1013] { content.html = String(data: html, encoding: .utf8) ?? String(data: html, encoding: .isoLatin1) }
                if let rtf = props.binaries[0x1009] { content.rtfText = MSGParser.decompressRTF(rtf) }
            case .attachRendData:
                if let done = current { content.attachments.append(done) }
                current = Attachment(filename: "", mimeType: "application/octet-stream", data: Data())
            case .attachTitle:
                if current == nil { current = Attachment(filename: "", mimeType: "application/octet-stream", data: Data()) }
                if current?.filename.isEmpty == true { current?.filename = string(payload, encoding) ?? "" }
            case .attachData:
                if current == nil { current = Attachment(filename: "", mimeType: "application/octet-stream", data: Data()) }
                current?.data = payload
            case .attachment:
                if current == nil { current = Attachment(filename: "", mimeType: "application/octet-stream", data: Data()) }
                let props = parseMAPIProperties(payload, encoding: encoding)
                if let long = props.strings[0x3707], !long.isEmpty { current?.filename = long }
                else if let short = props.strings[0x3704], current?.filename.isEmpty == true { current?.filename = short }
                if let mime = props.strings[0x370E], !mime.isEmpty { current?.mimeType = mime }
                if current?.data.isEmpty == true, let bytes = props.binaries[0x3701] { current?.data = bytes }
                if props.ints[0x3705] == 5 {
                    current?.isEmbeddedMessage = true
                    content.notes.append("\(current?.filename ?? "an attachment"): a message embedded in the TNEF is listed, not expanded")
                }
            case .from, .dateSent, .tnefVersion, .mapiProps:
                break
            }
        }
        if let done = current { content.attachments.append(done) }
        for i in content.attachments.indices where content.attachments[i].filename.isEmpty {
            content.attachments[i].filename = "attachment-\(i + 1)"
        }
        return content
    }

    /// MAPI properties as TNEF encodes them: count, then per property the
    /// tag, an optional name (ids ≥ 0x8000), then the value(s) padded to four.
    static func parseMAPIProperties(_ data: Data, encoding: String.Encoding) -> MAPIPropertySet {
        var props = MAPIPropertySet()
        var pos = 0
        guard data.count >= 4 else { return props }
        let count = Int(readUInt32(data, 0)); pos = 4
        func pad4(_ n: Int) -> Int { (n + 3) & ~3 }
        for _ in 0..<min(count, 100_000) {
            guard pos + 4 <= data.count else { break }
            let tag = readUInt32(data, pos); pos += 4
            let type = UInt16(tag & 0xFFFF)
            let id = UInt16(tag >> 16)
            if id >= 0x8000 {
                // Named property: GUID, kind, then a numeric id or a name.
                pos += 16
                guard pos + 4 <= data.count else { break }
                let kind = readUInt32(data, pos); pos += 4
                if kind == 0 { pos += 4 } else {
                    guard pos + 4 <= data.count else { break }
                    let nameLength = Int(readUInt32(data, pos)); pos += 4 + pad4(nameLength)
                }
            }
            let multi = type & 0x1000 != 0
            let base = type & 0x0FFF
            switch base {
            case 0x0002, 0x0003, 0x0004, 0x000A, 0x000B:
                let values = multi ? Int(readUInt32(data, pos)) : 1
                if multi { pos += 4 }
                if !multi, pos + 4 <= data.count, base == 0x0003 || base == 0x000B || base == 0x0002 {
                    props.ints[id] = base == 0x0002 ? UInt32(readUInt16(data, pos)) : readUInt32(data, pos)
                }
                pos += values * 4
            case 0x0005, 0x0006, 0x0007, 0x0014, 0x0040:
                let values = multi ? Int(readUInt32(data, pos)) : 1
                if multi { pos += 4 }
                if !multi, base == 0x0040, pos + 8 <= data.count {
                    let fileTime = readUInt64(data, pos)
                    if fileTime > 0 { props.dates[id] = Date(timeIntervalSince1970: Double(fileTime) / 10_000_000.0 - 11_644_473_600.0) }
                }
                pos += values * 8
            case 0x0048:
                let values = multi ? Int(readUInt32(data, pos)) : 1
                if multi { pos += 4 }
                pos += values * 16
            case 0x001E, 0x001F, 0x0102, 0x000D:
                guard pos + 4 <= data.count else { return props }
                let values = Int(readUInt32(data, pos)); pos += 4
                for valueIndex in 0..<min(values, 10_000) {
                    guard pos + 4 <= data.count else { return props }
                    let length = Int(readUInt32(data, pos)); pos += 4
                    guard length >= 0, pos + length <= data.count else { return props }
                    let bytes = data.subdata(in: (data.startIndex + pos)..<(data.startIndex + pos + length))
                    pos += pad4(length)
                    guard valueIndex == 0 else { continue }
                    switch base {
                    case 0x001E: props.strings[id] = trimmedString(bytes, encoding)
                    case 0x001F: props.strings[id] = trimmedString(bytes, .utf16LittleEndian)
                    default: props.binaries[id] = bytes
                    }
                }
            default:
                // Unknown type: the stream cannot be walked further without its size.
                return props
            }
        }
        return props
    }

    private static func string(_ data: Data, _ encoding: String.Encoding) -> String? {
        trimmedString(data, encoding)
    }

    private static func trimmedString(_ data: Data, _ encoding: String.Encoding) -> String? {
        var bytes = data
        if encoding == .utf16LittleEndian {
            while bytes.count >= 2, bytes[bytes.endIndex - 1] == 0, bytes[bytes.endIndex - 2] == 0 { bytes = bytes.dropLast(2) }
        } else {
            while let last = bytes.last, last == 0 { bytes = bytes.dropLast() }
        }
        return String(data: bytes, encoding: encoding) ?? String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .isoLatin1)
    }

    static func encoding(forCodepage codepage: UInt32) -> String.Encoding? {
        if codepage == 65001 { return .utf8 }
        if codepage == 1200 { return .utf16LittleEndian }
        let cf = CFStringConvertWindowsCodepageToEncoding(codepage)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt32(data[base]) | (UInt32(data[base + 1]) << 8) | (UInt32(data[base + 2]) << 16) | (UInt32(data[base + 3]) << 24)
    }

    private static func readUInt64(_ data: Data, _ offset: Int) -> UInt64 {
        guard offset + 8 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return (0..<8).reduce(UInt64(0)) { $0 | (UInt64(data[base + $1]) << (UInt64($1) * 8)) }
    }
}
