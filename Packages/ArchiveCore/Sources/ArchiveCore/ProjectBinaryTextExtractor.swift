//
//  ProjectBinaryTextExtractor.swift
//  ArchiveCore
//
//  Directive 2026-11-07 §6 "Other business formats": Microsoft Project
//  binary files (.mpp/.mpt, Project 2000–2019). The OLE2 file's \1CompObj
//  stream names the format ("MSProject.MPP9" = Project 2000–2003,
//  "MSProject.MPP12" = 2007, "MSProject.MPP14" = 2010 and later; MPT = the
//  template of each). The root Props9/12/14 stream carries the password
//  flag (893386752) and the encryption code (893386759): with any password
//  set, the project Props and the FixedData blocks are XORed with
//  0xFF − code; with the read-protection bit set the file is reported
//  password-protected and nothing is read. The project storage ("   19",
//  "   112", "   114") holds Props (title etc., the task and resource field
//  maps — 28-byte records: fixed offset at +4, MPP9's var-data key at +6,
//  the field type at +12 whose low 16 bits are the field index) and the
//  TBkndTask / TBkndRsc storages: FixedMeta (magic 0xFADFADBA, 47-byte task
//  / 37-byte resource items: flags at 0, data offset at 4; flag 0x02 =
//  deleted), FixedData (items sliced by consecutive offsets; the unique id
//  at the field map's offset, 0 by default), VarMeta (MPP9: 3-byte unique
//  id, 1-byte key, 4-byte offset; MPP12+: 4-byte id, offset, 2-byte key)
//  and Var2Data (4-byte size + bytes). Task names (index 14, MPP9 key 11)
//  and resource names (index 1) are UTF-16LE; notes (task 15 / MPP9 144,
//  resource 20 / MPP9 124) are RTF, read to plain text. Layout after
//  MPXJ (joniles/mpxj), verified on its test data and Apache Tika's.
//
//  Output follows the Project XML reader: "[Project: title]" with the
//  document properties (SummaryInformation / DocumentSummaryInformation
//  property sets: title, subject, author, keywords, comments, company,
//  manager, category), "[Tasks]" lines "ID<TAB>Name<TAB>Notes" and
//  "[Resources]" lines "ID<TAB>Name<TAB>Notes". Dates and assignments are
//  not read. Project 98 (MPP8: FixFix/FixDeferFix blocks) and Project 4
//  are recognised and reported as not read; the properties are still
//  given. Nothing is executed (VBA storages are listed as not text).
//

import Foundation

enum ProjectBinaryTextExtractor {

    static let component = "Project data"

    struct Issue: Error { let text: String; init(_ text: String) { self.text = text } }

    static func extract(fileURL: URL) throws -> OfficeTextExtractor.Result {
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        guard data.count >= 8, Array(data.prefix(8)) == OfficeTextExtractor.oleSignature else {
            throw OfficeTextExtractor.ExtractError.notAPackage("not an OLE2 compound file")
        }
        let limit = ExtractionLimits.effective.partBytes
        guard Int64(data.count) <= limit else {
            return OfficeTextExtractor.Result(text: "", components: [], skipped: ["\(fileURL.lastPathComponent) (\(data.count) bytes, over the \(limit)-byte guard)"], notText: [])
        }
        let ole: OLE2Reader
        do { ole = try OLE2Reader(data: data) } catch { throw OfficeTextExtractor.ExtractError.notAPackage(String(describing: error)) }
        return try extract(ole: ole, name: fileURL.lastPathComponent)
    }

    static func extract(ole: OLE2Reader, name: String) throws -> OfficeTextExtractor.Result {
        let format = compObjFormat(ole)
        let version: Int
        let projectDir: String
        switch (format, true) {
        case (let f?, _) where f.hasSuffix("9"): version = 9; projectDir = "   19"
        case (let f?, _) where f.hasSuffix("12"): version = 12; projectDir = "   112"
        case (let f?, _) where f.hasSuffix("14"): version = 14; projectDir = "   114"
        case (let f?, _) where f.hasSuffix("8"): version = 8; projectDir = "   1"
        case (let f?, _) where f.hasSuffix("4"): version = 4; projectDir = ""
        case (nil, _) where ole.entries(at: ["   19"]) != nil: version = 9; projectDir = "   19"
        case (nil, _) where ole.entries(at: ["   112"]) != nil: version = 12; projectDir = "   112"
        case (nil, _) where ole.entries(at: ["   114"]) != nil: version = 14; projectDir = "   114"
        case (nil, _) where ole.entries(at: ["   1"]) != nil: version = 8; projectDir = "   1"
        default:
            throw OfficeTextExtractor.ExtractError.notAPackage(format.map { "CompObj names \($0), not a Microsoft Project file" } ?? "no Microsoft Project storage — not a Project file")
        }

        var skipped: [String] = []
        var notText: [String] = []
        if ole.entries(at: [projectDir.isEmpty ? "_VBA_PROJECT_CUR" : "CVba"]) != nil || ole.streamNames.contains(where: { $0.lowercased().hasPrefix("_vba") }) {
            notText.append("VBA storage (not executed)")
        }
        let properties = documentProperties(ole)
        var text = "[Project: \(properties["Title"] ?? (name as NSString).deletingPathExtension)]\n"
        for key in ["Subject", "Author", "Manager", "Company", "Category", "Keywords", "Comments"] {
            if let value = properties[key], !value.isEmpty { text += "\(key): \(value)\n" }
        }
        text += "\n"
        var components = [component]

        guard version >= 9 else {
            skipped.append("\(name): Project \(version == 8 ? "98" : "4") (MSProject.MPP\(version)) tasks and resources are not read — the FixFix/FixDeferFix layout of that generation is not implemented; the document properties are")
            return OfficeTextExtractor.Result(text: text, components: components, skipped: skipped, notText: notText)
        }

        // Root Props: password flag and encryption code (never encoded themselves).
        let rootProps = Props(ole.streamData(named: version == 9 ? "Props9" : version == 12 ? "Props12" : "Props14").map { [UInt8]($0) } ?? [])
        let passwordFlag = rootProps.byte(893_386_752)
        if passwordFlag & 0x1 != 0 { throw OfficeTextExtractor.ExtractError.encrypted }
        let code = rootProps.byte(893_386_759)
        let mask: UInt8 = passwordFlag != 0 ? (code == 0 ? 0 : 0xFF &- code) : 0
        func decoded(_ data: Data?) -> [UInt8]? {
            guard let data else { return nil }
            var bytes = [UInt8](data)
            if mask != 0 { for i in bytes.indices { bytes[i] ^= mask } }
            return bytes
        }

        let projectProps = Props(decoded(ole.streamData(at: [projectDir, "Props"])) ?? [])
        let taskMap = FieldMap(data: projectProps.bytes(131_092) ?? projectProps.bytes(50_331_668), version: version,
                               defaults: version == 9 ? .init(name: 11, notes: 144, uniqueIDOffset: 0, idOffset: 4) : .init(name: 14, notes: 15, uniqueIDOffset: 0, idOffset: 4),
                               nameIndex: 14, notesIndex: 15, uniqueIDIndex: 86, idIndex: 23)
        let resourceMap = FieldMap(data: projectProps.bytes(131_093) ?? projectProps.bytes(50_331_669), version: version,
                                   defaults: version == 9 ? .init(name: 1, notes: 124, uniqueIDOffset: 0, idOffset: 4) : .init(name: 1, notes: 20, uniqueIDOffset: 0, idOffset: 4),
                                   nameIndex: 1, notesIndex: 20, uniqueIDIndex: 27, idIndex: 0)

        var sections: [String] = []
        do {
            let rows = try records(ole: ole, path: [projectDir, "TBkndTask"], metaItemSize: 47, map: taskMap, version: version, decode: decoded, issues: &skipped, name: name, what: "tasks")
            if !rows.isEmpty {
                components.append("Tasks")
                sections.append("[Tasks]\n" + rows.joined(separator: "\n") + "\n")
            }
        } catch let issue as Issue { skipped.append("\(name): tasks — \(issue.text)") }
        do {
            let rows = try records(ole: ole, path: [projectDir, "TBkndRsc"], metaItemSize: 37, map: resourceMap, version: version, decode: decoded, issues: &skipped, name: name, what: "resources")
            if !rows.isEmpty {
                components.append("Resources")
                sections.append("[Resources]\n" + rows.joined(separator: "\n") + "\n")
            }
        } catch let issue as Issue { skipped.append("\(name): resources — \(issue.text)") }
        text += sections.joined(separator: "\n")
        if passwordFlag != 0 { notText.append("write-reservation password (contents decoded, nothing bypassed)") }
        return OfficeTextExtractor.Result(text: text, components: components, skipped: skipped, notText: notText)
    }

    // MARK: - CompObj

    /// The file format string of \1CompObj ("MSProject.MPP12"), or nil.
    static func compObjFormat(_ ole: OLE2Reader) -> String? {
        guard let data = ole.streamNames.first(where: { $0.hasSuffix("CompObj") }).flatMap({ ole.streamData(named: $0) }) else { return nil }
        let b = [UInt8](data)
        var pos = 28
        guard let application = lengthPrefixed(b, &pos) else { return nil }
        if application == "Microsoft Project 4.0" { return "MSProject.MPP4" }
        return lengthPrefixed(b, &pos)
    }

    private static func lengthPrefixed(_ b: [UInt8], _ pos: inout Int) -> String? {
        guard pos + 4 <= b.count else { return nil }
        let length = Int(le32(b, pos)); pos += 4
        guard length >= 1, pos + length <= b.count else { return nil }
        defer { pos += length }
        return String(bytes: b[pos..<(pos + length - 1)], encoding: .windowsCP1252)
    }

    // MARK: - Props (MPXJ Props9/12/14)

    struct Props {
        private var map: [UInt32: [UInt8]] = [:]
        init(_ b: [UInt8]) {
            guard b.count >= 16 else { return }
            let count = Int(le16(b, 12))
            var pos = 16
            var found = 0
            while found < count, pos + 12 <= b.count {
                let size = Int(le32(b, pos)), key = le32(b, pos + 4)
                pos += 12
                guard size >= 1, size <= b.count - pos else { break }
                map[key] = Array(b[pos..<(pos + size)])
                pos += size + (size % 2)
                found += 1
            }
        }
        func bytes(_ key: UInt32) -> [UInt8]? { map[key] }
        func byte(_ key: UInt32) -> UInt8 { map[key]?.first ?? 0 }
    }

    // MARK: - Field map (MPXJ FieldMap)

    struct FieldMap {
        struct Defaults { let name: Int; let notes: Int; let uniqueIDOffset: Int; let idOffset: Int }
        var nameKey: Int
        var notesKey: Int
        var uniqueIDOffset: Int
        var idOffset: Int
        var fromFile = false

        init(data: [UInt8]?, version: Int, defaults: Defaults, nameIndex: Int, notesIndex: Int, uniqueIDIndex: Int, idIndex: Int) {
            nameKey = defaults.name; notesKey = defaults.notes; uniqueIDOffset = defaults.uniqueIDOffset; idOffset = defaults.idOffset
            guard let data, data.count >= 28 else { return }
            fromFile = true
            var index = 0
            while index + 28 <= data.count {
                let fixedOffset = Int(le16(data, index + 4))
                let typeValue = le32(data, index + 12)
                let fieldIndex = Int(typeValue & 0xFFFF)
                let varKey = version == 9 ? Int(data[index + 6]) : fieldIndex
                if fixedOffset == 65535 {
                    if fieldIndex == nameIndex, varKey != 0 { nameKey = varKey }
                    if fieldIndex == notesIndex, varKey != 0 { notesKey = varKey }
                } else {
                    if fieldIndex == uniqueIDIndex { uniqueIDOffset = fixedOffset }
                    if fieldIndex == idIndex, idIndex != 0 { idOffset = fixedOffset }
                }
                index += 28
            }
        }
    }

    // MARK: - Task / resource records

    struct VarMeta {
        /// unique id → (key → offset)
        var table: [Int: [Int: Int]] = [:]
        var offsets: [Int] = []

        init(_ b: [UInt8], version: Int) throws {
            guard b.count >= 24 else { throw Issue("VarMeta is shorter than its header") }
            let magic = le32(b, 0)
            guard magic == 0xFADF_ADBA || (version >= 12 && magic == 0) else { throw Issue("VarMeta has no FADFADBA magic") }
            let count = Int(le32(b, 8))
            var pos = 24
            let entrySize = version == 9 ? 8 : 12
            var read = 0
            while read < count, pos + entrySize <= b.count {
                let uid: Int, key: Int, offset: Int
                if version == 9 {
                    uid = Int(b[pos]) | Int(b[pos + 1]) << 8 | Int(b[pos + 2]) << 16
                    key = Int(b[pos + 3]); offset = Int(le32(b, pos + 4))
                } else {
                    uid = Int(le32(b, pos)); offset = Int(le32(b, pos + 4)); key = Int(le16(b, pos + 8))
                }
                table[uid, default: [:]][key] = offset
                offsets.append(offset)
                pos += entrySize
                read += 1
            }
            offsets.sort()
        }
    }

    struct Var2Data {
        private var items: [Int: [UInt8]] = [:]
        init(_ b: [UInt8], meta: VarMeta) {
            for offset in meta.offsets where items[offset] == nil {
                guard offset >= 0, offset + 4 <= b.count else { continue }
                let size = Int(le32(b, offset))
                guard size >= 0, size <= b.count - offset - 4 else { continue }
                items[offset] = Array(b[(offset + 4)..<(offset + 4 + size)])
            }
        }
        func bytes(uid: Int, key: Int, meta: VarMeta) -> [UInt8]? {
            guard let offset = meta.table[uid]?[key] else { return nil }
            return items[offset]
        }
    }

    /// FixedMeta + FixedData items in block order: (flags, data).
    static func fixedItems(meta m: [UInt8], data d: [UInt8], itemSize: Int) throws -> [(flags: UInt32, data: [UInt8])] {
        guard m.count >= 16, le32(m, 0) == 0xFADF_ADBA else { throw Issue("FixedMeta has no FADFADBA magic") }
        let count = (m.count - 16) / itemSize
        var offsets: [Int] = []
        offsets.reserveCapacity(count)
        for i in 0..<count { offsets.append(Int(Int32(bitPattern: le32(m, 16 + i * itemSize + 4)))) }
        var items: [(UInt32, [UInt8])] = []
        items.reserveCapacity(count)
        for i in 0..<count {
            let flags = le32(m, 16 + i * itemSize)
            let offset = offsets[i]
            guard offset >= 0, offset <= d.count else { items.append((flags, [])); continue }
            var size = i + 1 < count ? offsets[i + 1] - offset : d.count - offset
            if size < 0 || size > d.count - offset { size = d.count - offset }
            items.append((flags, Array(d[offset..<(offset + size)])))
        }
        return items
    }

    private static func records(ole: OLE2Reader, path: [String], metaItemSize: Int, map: FieldMap, version: Int,
                                decode: (Data?) -> [UInt8]?, issues: inout [String], name: String, what: String) throws -> [String] {
        guard ole.entries(at: path) != nil else { throw Issue("no \(path.last ?? "") storage") }
        guard let metaBytes = ole.streamData(at: path + ["VarMeta"]).map({ [UInt8]($0) }) else { throw Issue("no VarMeta stream") }
        let varMeta = try VarMeta(metaBytes, version: version)
        let varData = Var2Data(ole.streamData(at: path + ["Var2Data"]).map { [UInt8]($0) } ?? [], meta: varMeta)
        let fixedMeta = ole.streamData(at: path + ["FixedMeta"]).map { [UInt8]($0) } ?? []
        let fixedData = decode(ole.streamData(at: path + ["FixedData"])) ?? []

        // Live records: FixedData items not flagged deleted whose unique id has var data.
        var order: [(id: Int, uid: Int)] = []
        var seen: Set<Int> = []
        do {
            let items = try fixedItems(meta: fixedMeta, data: fixedData, itemSize: metaItemSize)
            for (index, item) in items.enumerated().reversed() {
                guard item.flags & 0x02 == 0, item.data.count >= map.uniqueIDOffset + 4 else { continue }
                let uid = Int(le32(item.data, map.uniqueIDOffset))
                guard uid != 0 || index == 0, varMeta.table[uid] != nil, seen.insert(uid).inserted else { continue }
                var id = item.data.count >= map.idOffset + 4 ? Int(le32(item.data, map.idOffset)) : index
                // The project summary task (unique id 0) and some Project 2010+ rows carry a
                // placeholder ID (0xFFFF0000); the unique id is shown instead of an invented number.
                if id > 0xFFFF { id = uid }
                order.append((id, uid))
            }
            order.sort { $0.id < $1.id }
        } catch let issue as Issue {
            // Without usable fixed blocks the names still exist: list every id that has var data.
            issues.append("\(name): \(what) — \(issue.text); listed from the variable data without order or deletion flags")
            order = varMeta.table.keys.sorted().map { ($0, $0) }
        }

        var rows: [String] = []
        for (id, uid) in order {
            let nameText = varData.bytes(uid: uid, key: map.nameKey, meta: varMeta).map(utf16String) ?? ""
            let notes = varData.bytes(uid: uid, key: map.notesKey, meta: varMeta).map(notesText) ?? ""
            guard !nameText.isEmpty || !notes.isEmpty else { continue }
            rows.append("\(id)\t\(nameText)\t\(notes)")
        }
        return rows
    }

    // MARK: - Strings

    static func utf16String(_ b: [UInt8]) -> String {
        var end = 0
        while end + 1 < b.count, !(b[end] == 0 && b[end + 1] == 0) { end += 2 }
        let s = String(bytes: b[0..<end], encoding: .utf16LittleEndian) ?? ""
        return s.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// Notes are RTF (8-bit, NUL-terminated); plain text through the MSG RTF reader.
    static func notesText(_ b: [UInt8]) -> String {
        let bytes = Array(b.prefix { $0 != 0 })
        guard !bytes.isEmpty else { return "" }
        let plain: String
        if bytes.starts(with: Array("{\\rtf".utf8)) {
            plain = MSGParser.rtfPlainText(Data(bytes))
        } else {
            plain = String(bytes: bytes, encoding: .windowsCP1252) ?? ""
        }
        return plain.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
            .replacingOccurrences(of: "\t", with: " ")
    }

    // MARK: - OLE property sets (MS-OLEPS) for the [Project] block

    /// Title, Subject, Author, Keywords, Comments from \5SummaryInformation;
    /// Category, Manager, Company from \5DocumentSummaryInformation.
    static func documentProperties(_ ole: OLE2Reader) -> [String: String] {
        var out: [String: String] = [:]
        if let data = ole.streamNames.first(where: { $0.lowercased().hasSuffix("summaryinformation") && !$0.lowercased().contains("document") }).flatMap({ ole.streamData(named: $0) }) {
            let props = propertySet([UInt8](data))
            for (id, key) in [(2, "Title"), (3, "Subject"), (4, "Author"), (5, "Keywords"), (6, "Comments")] {
                if let v = props[id], !v.isEmpty { out[key] = v }
            }
        }
        if let data = ole.streamNames.first(where: { $0.lowercased().hasSuffix("documentsummaryinformation") }).flatMap({ ole.streamData(named: $0) }) {
            let props = propertySet([UInt8](data))
            for (id, key) in [(2, "Category"), (14, "Manager"), (15, "Company")] {
                if let v = props[id], !v.isEmpty { out[key] = v }
            }
        }
        return out
    }

    /// The string properties of the first section of an OLE property set stream.
    static func propertySet(_ b: [UInt8]) -> [Int: String] {
        var out: [Int: String] = [:]
        guard b.count >= 48, b[0] == 0xFE, b[1] == 0xFF else { return out }
        let section = Int(le32(b, 44))
        guard section >= 0, section + 8 <= b.count else { return out }
        let count = Int(le32(b, section + 4))
        var codePage: String.Encoding = .windowsCP1252
        var entries: [(id: Int, offset: Int)] = []
        var pos = section + 8
        for _ in 0..<count {
            guard pos + 8 <= b.count else { break }
            entries.append((Int(le32(b, pos)), Int(le32(b, pos + 4))))
            pos += 8
        }
        if let cp = entries.first(where: { $0.id == 1 }), section + cp.offset + 8 <= b.count, le32(b, section + cp.offset) == 2 {
            let code = Int(Int16(bitPattern: le16(b, section + cp.offset + 4)))
            if code == 1200 { codePage = .utf16LittleEndian } else if code == 65001 { codePage = .utf8 } else if code == 1252 || code == 10000 { codePage = .windowsCP1252 }
            else if code == 1250 { codePage = .windowsCP1250 } else if code == 1251 { codePage = .windowsCP1251 } else if code == 1253 { codePage = .windowsCP1253 } else if code == 1254 { codePage = .windowsCP1254 }
            else if code == 932 { codePage = .shiftJIS } else if code == 936 { codePage = .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))) }
        }
        for entry in entries where entry.id != 1 {
            let at = section + entry.offset
            guard at >= 0, at + 8 <= b.count else { continue }
            let type = le32(b, at)
            let length = Int(le32(b, at + 4))
            guard length >= 0 else { continue }
            if type == 30, at + 8 + length <= b.count {                 // VT_LPSTR
                let bytes = b[(at + 8)..<(at + 8 + length)].prefix { $0 != 0 }
                out[entry.id] = (String(bytes: bytes, encoding: codePage) ?? String(bytes: bytes, encoding: .isoLatin1) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            } else if type == 31, at + 8 + length * 2 <= b.count {      // VT_LPWSTR
                let bytes = Array(b[(at + 8)..<(at + 8 + length * 2)])
                out[entry.id] = utf16String(bytes)
            }
        }
        return out
    }

    private static func le16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
    private static func le32(_ b: [UInt8], _ i: Int) -> UInt32 { UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24 }
}

private func le16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
private func le32(_ b: [UInt8], _ i: Int) -> UInt32 { UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24 }
