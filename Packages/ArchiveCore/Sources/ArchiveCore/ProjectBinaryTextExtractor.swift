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
//  TBkndTask / TBkndRsc / TBkndAssn storages: FixedMeta (magic 0xFADFADBA,
//  47-byte task / 37-byte resource / 34-byte assignment items: flags at 0,
//  data offset at 4; flag 0x02 = deleted), FixedData (items sliced by
//  consecutive offsets; assignments: 142/110-byte items at the meta
//  offset), Fixed2Meta/Fixed2Data (MPP12/14 tasks: the field map's second
//  fixed block, item-aligned with FixedData), VarMeta (MPP9: 3-byte unique
//  id, 1-byte key, 4-byte offset; MPP12+: 4-byte id, offset, 2-byte key)
//  and Var2Data (4-byte size + bytes). The field map's fixed offsets switch
//  to the next fixed block whenever an offset goes down (MPXJ FieldMap);
//  categories 0x0B/0x64 are flag bits, not offsets. Task names (index 14,
//  MPP9 key 11) and resource names (index 1) are UTF-16LE; notes (task 15 /
//  MPP9 144, resource 20 / MPP9 124) are RTF, read to plain text.
//
//  Schedule (MPXJ MPP9/12/14Reader, FieldMap9/12/14, MPPUtility): task
//  Start 35 / Finish 36 / Duration 29 with its units in field 181
//  (MPP9/12 defaults: offsets 88, 92, 60, 64); in MPP14 35/36/29 are the
//  *scheduled* values (defaults 64, 68, 42, units 46) and Start/Finish are
//  1283/1284 (block 1, 50/54), a manually scheduled task (Fixed2Meta byte
//  8, bit 0x08 in Project 2010 files, 0x80 in 2013+) showing its manual
//  duration 1288 (units 1289) and its own Start/Finish, an auto-scheduled
//  one its scheduled values. As-late-as-possible tasks take the late start/
//  finish (39/40) when later; Start/Finish No Later Than tasks with a finish
//  before the start take the late finish. Timestamps: 2-byte tenths of a
//  minute + 2-byte days since 1983-12-31 (days ≤ 1 or 65535 = NA).
//  Durations: 4-byte tenths of a minute (−1 = none) in units 3 min, 4 emin,
//  5 hr, 6 ehr, 7 day, 8 eday, 9 wk, 10 ewk, 11 mon, 12 emon, 19 %, 20 e%,
//  21 = the project default (Props 37748757); a day/week/month is the
//  project's minutes per day (37748765) / week (37748766) and days per month
//  (37753743). Assignments (fields 0 unique id, 1 task, 2 resource, 7 units,
//  8 work; MPP9/12 offsets 0/4/8/54/62, MPP14 0/4/8/46/54): units ÷ 100 =
//  percent, work ÷ 60000 = hours; the null resource (−65535) and
//  assignments of tasks not read are left out. Layout after MPXJ
//  (joniles/mpxj), verified on its test data and Apache Tika's.
//
//  Output follows the Project XML reader: "[Project: title]" with the
//  document properties (SummaryInformation / DocumentSummaryInformation
//  property sets: title, subject, author, keywords, comments, company,
//  manager, category), "[Tasks]" lines
//  "ID<TAB>Name<TAB>Start<TAB>Finish<TAB>Duration<TAB>Notes" (dates as
//  2011-07-06T08:00:00 like the XML; durations as Project shows them:
//  "1 wk", "8.88 days", "40 hrs", "3 edays"), "[Resources]" lines
//  "ID<TAB>Name<TAB>Notes" and "[Assignments]" lines
//  "task <uid> (<name>) → resource <uid> (<name>)<TAB><units>%<TAB><work>".
//  What cannot be read from a damaged or unexpected layout is said in
//  `skipped`. Project 98 (MPP8: FixFix/FixDeferFix blocks) and Project 4
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
        let settings = Settings(props: projectProps, applicationVersion: compObjApplicationVersion(ole))
        let taskMap = FieldMap(data: projectProps.bytes(131_092) ?? projectProps.bytes(50_331_668), version: version, prefix: 0x0B40_0000,
                               defaults: TaskField.defaults(version), keepDefaults: [TaskField.name, TaskField.notes, TaskField.uniqueID, TaskField.id])
        let resourceMap = FieldMap(data: projectProps.bytes(131_093) ?? projectProps.bytes(50_331_669), version: version, prefix: 0x0C40_0000,
                                   defaults: [1: .varData(key: 1), 20: .varData(key: version == 9 ? 124 : 20), 27: .fixed(block: 0, offset: 0), 0: .fixed(block: 0, offset: 4)],
                                   keepDefaults: [1, 20, 27], ignoreFromFile: [0])
        let assignmentMap = FieldMap(data: projectProps.bytes(131_095) ?? projectProps.bytes(50_331_671), version: version, prefix: 0x0F40_0000,
                                     defaults: [0: .fixed(block: 0, offset: 0), 1: .fixed(block: 0, offset: 4), 2: .fixed(block: 0, offset: 8),
                                                7: .fixed(block: 0, offset: version == 14 ? 46 : 54), 8: .fixed(block: 0, offset: version == 14 ? 54 : 62)],
                                     keepDefaults: [0, 1, 2])

        var sections: [String] = []
        var taskNames: [Int: String] = [:]
        var resourceNames: [Int: String] = [:]
        var tasksRead = false
        do {
            let table = try records(ole: ole, path: [projectDir, "TBkndTask"], metaItemSize: 47, fixed2Sizes: version == 12 ? [86] : version == 14 ? [92, 93, 94, 95, 96] : [],
                                    map: taskMap, uniqueIDField: TaskField.uniqueID, idField: TaskField.id, version: version, decode: decoded, issues: &skipped, name: name, what: "tasks")
            tasksRead = true
            var lines: [String] = []
            var unread = 0
            for row in table.rows {
                let taskName = table.string(row, TaskField.name, map: taskMap)
                let notes = table.notes(row, TaskField.notes, map: taskMap)
                taskNames[row.uid] = taskName
                guard !taskName.isEmpty || !notes.isEmpty else { continue }
                let schedule = taskSchedule(row, map: taskMap, version: version, settings: settings)
                if !schedule.complete { unread += 1 }
                lines.append([String(row.id), taskName, schedule.start.map(formatTimestamp) ?? "", schedule.finish.map(formatTimestamp) ?? "",
                              schedule.duration ?? "", notes].joined(separator: "\t"))
            }
            if unread > 0 {
                skipped.append("\(name): start, finish or duration not read for \(unread) of \(lines.count) tasks — their fixed data is missing or shorter than the field map says")
            }
            if !lines.isEmpty {
                components.append("Tasks")
                sections.append("[Tasks]\n" + lines.joined(separator: "\n") + "\n")
            }
        } catch let issue as Issue { skipped.append("\(name): tasks — \(issue.text)") }
        do {
            let table = try records(ole: ole, path: [projectDir, "TBkndRsc"], metaItemSize: 37, fixed2Sizes: [],
                                    map: resourceMap, uniqueIDField: 27, idField: 0, version: version, decode: decoded, issues: &skipped, name: name, what: "resources")
            var lines: [String] = []
            for row in table.rows {
                let resourceName = table.string(row, 1, map: resourceMap)
                let notes = table.notes(row, 20, map: resourceMap)
                resourceNames[row.uid] = resourceName
                guard !resourceName.isEmpty || !notes.isEmpty else { continue }
                lines.append("\(row.id)\t\(resourceName)\t\(notes)")
            }
            if !lines.isEmpty {
                components.append("Resources")
                sections.append("[Resources]\n" + lines.joined(separator: "\n") + "\n")
            }
        } catch let issue as Issue { skipped.append("\(name): resources — \(issue.text)") }
        if tasksRead {
            do {
                let lines = try assignments(ole: ole, path: [projectDir, "TBkndAssn"], map: assignmentMap, version: version, decode: decoded,
                                            taskNames: taskNames, resourceNames: resourceNames, issues: &skipped, name: name)
                if !lines.isEmpty {
                    components.append("Assignments")
                    sections.append("[Assignments]\n" + lines.joined(separator: "\n") + "\n")
                }
            } catch let issue as Issue { skipped.append("\(name): assignments — \(issue.text)") }
        } else {
            skipped.append("\(name): assignments — not read because the tasks could not be read")
        }
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

    /// The writing application's major version from \1CompObj
    /// ("Microsoft Project 15.0" → 15; MPXJ CompObj), or 0.
    static func compObjApplicationVersion(_ ole: OLE2Reader) -> Int {
        guard let data = ole.streamNames.first(where: { $0.hasSuffix("CompObj") }).flatMap({ ole.streamData(named: $0) }) else { return 0 }
        var pos = 28
        guard let application = lengthPrefixed([UInt8](data), &pos), application.hasPrefix("Microsoft"), application.hasSuffix(".0") else { return 0 }
        let parts = application.dropLast(2).split(whereSeparator: { $0 == " " || $0 == "." })
        guard parts.count >= 3, parts[parts.count - 2] == "Project", let major = Int(parts[parts.count - 1]) else { return 0 }
        return major
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
        func short(_ key: UInt32) -> Int? { map[key].flatMap { $0.count >= 2 ? Int(le16($0, 0)) : nil } }
        func int(_ key: UInt32) -> Int? { map[key].flatMap { $0.count >= 4 ? Int(Int32(bitPattern: le32($0, 0))) : nil } }
    }

    /// Project-wide values durations depend on (MPXJ ProjectPropertiesReader);
    /// Project's own defaults when the Props do not carry them.
    struct Settings {
        var defaultDurationUnits = 7
        var minutesPerDay = 480
        var minutesPerWeek = 2400
        var daysPerMonth = 20
        var applicationVersion = 0

        init(props: Props, applicationVersion: Int) {
            if let units = props.short(37_748_757) { defaultDurationUnits = Settings.durationUnits(units, projectDefault: 7) }
            if let value = props.int(37_748_765), value > 0 { minutesPerDay = value }
            if let value = props.int(37_748_766), value > 0 { minutesPerWeek = value }
            if let value = props.short(37_753_743), value > 0 { daysPerMonth = value }
            self.applicationVersion = applicationVersion
        }

        /// MPPUtility.getDurationTimeUnits: the file's units code (low five
        /// bits) as one of 3…12, 19, 20; 21 = the project default; else days.
        static func durationUnits(_ type: Int, projectDefault: Int) -> Int {
            switch type & 0x1F {
            case 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 19, 20: return type & 0x1F
            case 21: return projectDefault
            default: return 7
            }
        }
    }

    // MARK: - Field map (MPXJ FieldMap)

    /// Field indexes of the task fields read (MPXJ MPPTaskField; in MPP14
    /// 29/35/36 are the scheduled duration/start/finish).
    enum TaskField {
        static let name = 14, notes = 15, uniqueID = 86, id = 23
        static let duration = 29, durationUnits = 181, start = 35, finish = 36
        static let constraintType = 17, lateStart = 39, lateFinish = 40
        static let start14 = 1283, finish14 = 1284, manualDuration14 = 1288, manualDurationUnits14 = 1289

        /// FieldMap9/12/14 default task data, used when the file has no map.
        static func defaults(_ version: Int) -> [Int: FieldMap.Location] {
            var map: [Int: FieldMap.Location] = [name: .varData(key: version == 9 ? 11 : 14), notes: .varData(key: version == 9 ? 144 : 15),
                                                  uniqueID: .fixed(block: 0, offset: 0), id: .fixed(block: 0, offset: 4), lateStart: .fixed(block: 0, offset: 12)]
            if version == 14 {
                map[duration] = .fixed(block: 0, offset: 42); map[durationUnits] = .fixed(block: 0, offset: 46)
                map[constraintType] = .fixed(block: 0, offset: 56); map[start] = .fixed(block: 0, offset: 64); map[finish] = .fixed(block: 0, offset: 68)
                map[lateFinish] = .fixed(block: 0, offset: 110)
                map[start14] = .fixed(block: 1, offset: 50); map[finish14] = .fixed(block: 1, offset: 54)
                map[manualDuration14] = .fixed(block: 1, offset: 58); map[manualDurationUnits14] = .fixed(block: 1, offset: 62)
            } else {
                map[duration] = .fixed(block: 0, offset: 60); map[durationUnits] = .fixed(block: 0, offset: 64)
                map[constraintType] = .fixed(block: 0, offset: 80); map[start] = .fixed(block: 0, offset: 88); map[finish] = .fixed(block: 0, offset: 92)
                map[lateFinish] = .fixed(block: 0, offset: 152)
            }
            return map
        }
    }

    struct FieldMap {
        enum Location: Equatable { case fixed(block: Int, offset: Int), varData(key: Int) }
        private(set) var locations: [Int: Location] = [:]
        private(set) var fromFile = false

        /// The file's map (28-byte items: fixed offset at +4, MPP9 var-data
        /// key at +6, field type at +12 — class prefix in the high 16 bits,
        /// index in the low — category at +20) when present, else the
        /// defaults. `keepDefaults` fields fall back to their default when the
        /// file's map does not place them; `ignoreFromFile` fields always use it.
        init(data: [UInt8]?, version: Int, prefix: UInt32, defaults: [Int: Location], keepDefaults: Set<Int>, ignoreFromFile: Set<Int> = []) {
            guard let data, data.count >= 28 else { locations = defaults; return }
            fromFile = true
            var index = 0
            var block = 0
            var lastOffset = 0
            while index + 28 <= data.count {
                let fixedOffset = Int(le16(data, index + 4))
                let typeValue = le32(data, index + 12)
                let category = le16(data, index + 20)
                let fieldIndex = Int(typeValue & 0xFFFF)
                let varKey = version == 9 ? Int(data[index + 6]) : fieldIndex
                var location: Location?
                if category != 0x0B, category != 0x64 {
                    if fixedOffset != 65535 {
                        if fixedOffset < lastOffset { block += 1 }
                        lastOffset = fixedOffset
                        location = .fixed(block: block, offset: fixedOffset)
                    } else if varKey != 0 {
                        location = .varData(key: varKey)
                    }
                }
                if typeValue & 0xFFFF_0000 == prefix, fieldIndex & 0x8000 == 0, !ignoreFromFile.contains(fieldIndex), let location {
                    locations[fieldIndex] = location
                }
                index += 28
            }
            for field in keepDefaults.union(ignoreFromFile) where locations[field] == nil {
                locations[field] = defaults[field]
            }
        }

        subscript(field: Int) -> Location? { locations[field] }

        func varKey(_ field: Int) -> Int? {
            if case .varData(let key)? = locations[field] { return key }
            return nil
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

    /// FixedMeta + FixedData items in block order: (meta item, data item),
    /// data sliced by consecutive meta offsets (MPXJ FixedData).
    static func fixedBlock(meta m: [UInt8], data d: [UInt8], itemSize: Int) throws -> [(meta: [UInt8], data: [UInt8])] {
        guard m.count >= 16, le32(m, 0) == 0xFADF_ADBA else { throw Issue("FixedMeta has no FADFADBA magic") }
        guard itemSize >= 8 else { throw Issue("FixedMeta item size \(itemSize) is too small") }
        let count = (m.count - 16) / itemSize
        var offsets: [Int] = []
        offsets.reserveCapacity(count)
        for i in 0..<count { offsets.append(Int(Int32(bitPattern: le32(m, 16 + i * itemSize + 4)))) }
        var items: [([UInt8], [UInt8])] = []
        items.reserveCapacity(count)
        for i in 0..<count {
            let meta = Array(m[(16 + i * itemSize)..<(16 + (i + 1) * itemSize)])
            let offset = offsets[i]
            guard offset >= 0, offset <= d.count else { items.append((meta, [])); continue }
            var size = i + 1 < count ? offsets[i + 1] - offset : d.count - offset
            if size < 0 || size > d.count - offset { size = d.count - offset }
            items.append((meta, Array(d[offset..<(offset + size)])))
        }
        return items
    }

    /// MPXJ FixedMeta(is, otherFixedBlock, sizes…): the item size that
    /// divides the block and gives the other block's item count, else the
    /// closest fit not exceeding the header's count.
    static func fixed2ItemSize(_ m: [UInt8], otherCount: Int, sizes: [Int]) -> Int? {
        guard let first = sizes.first, m.count >= 16 else { return nil }
        if sizes.count == 1 { return first }
        let available = m.count - 16
        let headerCount = Int(le32(m, 8))
        var best = first
        var distance = Int.min
        for size in sizes where available % size == 0 {
            if available / size == otherCount { return size }
            let test = headerCount * size - available
            if test <= 0, test > distance { best = size; distance = test }
        }
        return best
    }

    struct Row {
        let id: Int
        let uid: Int
        /// Fixed data blocks: [FixedData item, Fixed2Data item]; empty when the fixed blocks were unusable.
        let blocks: [[UInt8]]
        let meta2: [UInt8]
    }

    struct Table {
        let varMeta: VarMeta
        let varData: Var2Data
        var rows: [Row]

        func string(_ row: Row, _ field: Int, map: FieldMap) -> String {
            map.varKey(field).flatMap { varData.bytes(uid: row.uid, key: $0, meta: varMeta) }.map(utf16String) ?? ""
        }
        func notes(_ row: Row, _ field: Int, map: FieldMap) -> String {
            map.varKey(field).flatMap { varData.bytes(uid: row.uid, key: $0, meta: varMeta) }.map(notesText) ?? ""
        }
    }

    private static func records(ole: OLE2Reader, path: [String], metaItemSize: Int, fixed2Sizes: [Int], map: FieldMap, uniqueIDField: Int, idField: Int, version: Int,
                                decode: (Data?) -> [UInt8]?, issues: inout [String], name: String, what: String) throws -> Table {
        guard ole.entries(at: path) != nil else { throw Issue("no \(path.last ?? "") storage") }
        guard let metaBytes = ole.streamData(at: path + ["VarMeta"]).map({ [UInt8]($0) }) else { throw Issue("no VarMeta stream") }
        let varMeta = try VarMeta(metaBytes, version: version)
        let varData = Var2Data(ole.streamData(at: path + ["Var2Data"]).map { [UInt8]($0) } ?? [], meta: varMeta)
        let fixedMeta = ole.streamData(at: path + ["FixedMeta"]).map { [UInt8]($0) } ?? []
        let fixedData = decode(ole.streamData(at: path + ["FixedData"])) ?? []
        var uidOffset = 0, idOffset = 4
        if case .fixed(0, let offset)? = map[uniqueIDField] { uidOffset = offset }
        if case .fixed(0, let offset)? = map[idField] { idOffset = offset }

        // Live records: FixedData items not flagged deleted whose unique id has var data.
        var rows: [Row] = []
        var seen: Set<Int> = []
        do {
            let items = try fixedBlock(meta: fixedMeta, data: fixedData, itemSize: metaItemSize)
            // The second fixed block (MPP12/14 tasks) is item-aligned with the first and not encoded.
            var second: [(meta: [UInt8], data: [UInt8])] = []
            if !fixed2Sizes.isEmpty, let meta2 = ole.streamData(at: path + ["Fixed2Meta"]).map({ [UInt8]($0) }),
               let size = fixed2ItemSize(meta2, otherCount: items.count, sizes: fixed2Sizes) {
                second = (try? fixedBlock(meta: meta2, data: ole.streamData(at: path + ["Fixed2Data"]).map { [UInt8]($0) } ?? [], itemSize: size)) ?? []
            }
            for (index, item) in items.enumerated().reversed() {
                guard le32(item.meta, 0) & 0x02 == 0, item.data.count >= uidOffset + 4 else { continue }
                let uid = Int(le32(item.data, uidOffset))
                guard uid != 0 || index == 0, varMeta.table[uid] != nil, seen.insert(uid).inserted else { continue }
                var id = item.data.count >= idOffset + 4 ? Int(le32(item.data, idOffset)) : index
                // The project summary task (unique id 0) and some Project 2010+ rows carry a
                // placeholder ID (0xFFFF0000); the unique id is shown instead of an invented number.
                if id > 0xFFFF { id = uid }
                let two = index < second.count ? second[index] : (meta: [UInt8](), data: [UInt8]())
                rows.append(Row(id: id, uid: uid, blocks: [item.data, two.data], meta2: two.meta))
            }
            rows.sort { $0.id < $1.id }
        } catch let issue as Issue {
            // Without usable fixed blocks the names still exist: list every id that has var data.
            issues.append("\(name): \(what) — \(issue.text); listed from the variable data without order or deletion flags\(what == "tasks" ? ", dates or durations" : "")")
            rows = varMeta.table.keys.sorted().map { Row(id: $0, uid: $0, blocks: [], meta2: []) }
        }
        return Table(varMeta: varMeta, varData: varData, rows: rows)
    }

    // MARK: - Schedule (MPXJ MPPUtility / MPPxxReader.processTaskData)

    enum Fixed { case value(_ bytes: [UInt8], _ offset: Int), unreadable, absent }

    /// A field in the row's fixed blocks: `.absent` when the map does not
    /// place it in fixed data or the item is shorter than the field (MPXJ
    /// pads short items with zeros, which read as NA), `.unreadable` when the
    /// row has no item in that block at all (missing or damaged stream).
    static func fixed(_ row: Row, _ field: Int, map: FieldMap, size: Int) -> Fixed {
        guard case .fixed(let block, let offset)? = map[field] else { return .absent }
        guard block < row.blocks.count, !row.blocks[block].isEmpty else { return .unreadable }
        guard offset + size <= row.blocks[block].count else { return .absent }
        return .value(row.blocks[block], offset)
    }

    /// Seconds since 1983-12-31 00:00 (MPPUtility.getTimestamp: 2-byte
    /// tenths of a minute, 2-byte days), nil for NA.
    static func timestamp(_ b: [UInt8], _ offset: Int) -> Int? {
        guard offset >= 0, offset + 4 <= b.count else { return nil }
        let days = Int(le16(b, offset + 2))
        guard days > 1, days != 65535 else { return nil }
        var time = Int(le16(b, offset))
        if time == 65535 { time = 0 }
        let seconds = days * 86_400 + time * 6
        if days < 100, seconds % 60 != 0 { return nil }
        return seconds
    }

    /// "2011-07-06T08:00:00", as the Project XML reader shows dates.
    static func formatTimestamp(_ secondsSinceEpoch: Int) -> String {
        let total = secondsSinceEpoch + 5112 * 86_400            // 1983-12-31 is day 5112 after 1970-01-01
        let days = total / 86_400, rest = total % 86_400
        // Civil date from days since 1970-01-01 (H. Hinnant's algorithm).
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        let year = yoe + era * 400 + (month <= 2 ? 1 : 0)
        func two(_ v: Int) -> String { v < 10 ? "0\(v)" : "\(v)" }
        return "\(year)-\(two(month))-\(two(day))T\(two(rest / 3600)):\(two(rest / 60 % 60)):\(two(rest % 60))"
    }

    /// MPPUtility.getAdjustedDuration: tenths of a minute in the given units.
    static func durationValue(tenths: Int, units: Int, settings: Settings) -> Double {
        let v = Double(tenths)
        switch units {
        case 3, 4: return v / 10
        case 5, 6: return v / 600
        case 7: return v / (Double(settings.minutesPerDay) * 10)
        case 8: return v / 14_400
        case 9: return v / (Double(settings.minutesPerWeek) * 10)
        case 10: return v / 100_800
        case 11: return v / (Double(settings.minutesPerDay) * Double(settings.daysPerMonth) * 10)
        case 12: return v / 432_000
        default: return v
        }
    }

    /// A duration as Project shows it: "1 wk", "8.88 days", "40 hrs", "3 edays", "50%".
    static func formatDuration(_ value: Double, units: Int) -> String {
        guard value.isFinite else { return "" }
        let rounded = (value * 100).rounded() / 100
        var number = String(format: "%.2f", rounded)
        while number.contains("."), number.hasSuffix("0") { number.removeLast() }
        if number.hasSuffix(".") { number.removeLast() }
        if number == "-0" { number = "0" }
        let one = rounded == 1
        let label: String
        switch units {
        case 3: label = one ? "min" : "mins"
        case 4: label = one ? "emin" : "emins"
        case 5: label = one ? "hr" : "hrs"
        case 6: label = one ? "ehr" : "ehrs"
        case 8: label = one ? "eday" : "edays"
        case 9: label = one ? "wk" : "wks"
        case 10: label = one ? "ewk" : "ewks"
        case 11: label = one ? "mon" : "mons"
        case 12: label = one ? "emon" : "emons"
        case 19: return number + "%"
        case 20: return number + "e%"
        default: label = one ? "day" : "days"
        }
        return "\(number) \(label)"
    }

    struct Schedule { var start: Int?; var finish: Int?; var duration: String?; var complete = true }

    static func taskSchedule(_ row: Row, map: FieldMap, version: Int, settings: Settings) -> Schedule {
        var schedule = Schedule()
        guard !row.blocks.isEmpty else { schedule.complete = false; return schedule }
        var complete = true
        func date(_ field: Int) -> Int? {
            switch fixed(row, field, map: map, size: 4) {
            case .value(let b, let o): return timestamp(b, o)
            case .unreadable: complete = false; return nil
            case .absent: return nil
            }
        }
        func duration(_ field: Int, units unitsField: Int) -> String? {
            switch fixed(row, field, map: map, size: 4) {
            case .value(let b, let o):
                let tenths = Int(Int32(bitPattern: le32(b, o)))
                guard tenths != -1 else { return nil }
                var units = settings.defaultDurationUnits
                if case .value(let ub, let uo) = fixed(row, unitsField, map: map, size: 2) {
                    units = Settings.durationUnits(Int(le16(ub, uo)), projectDefault: settings.defaultDurationUnits)
                }
                return formatDuration(durationValue(tenths: tenths, units: units, settings: settings), units: units)
            case .unreadable: complete = false; return nil
            case .absent: return nil
            }
        }
        if version == 14 {
            // MPP14Reader: Start/Finish (1283/1284) and the manual duration for a manually
            // scheduled task; the scheduled values (35/36/29) otherwise or when absent.
            let flag: UInt8 = settings.applicationVersion <= 14 ? 0x08 : 0x80
            let manual = row.meta2.count > 8 && row.meta2[8] & flag != 0
            let scheduledStart = date(TaskField.start), scheduledFinish = date(TaskField.finish)
            schedule.start = date(TaskField.start14)
            schedule.finish = date(TaskField.finish14)
            if schedule.start == nil || (scheduledStart != nil && !manual) { schedule.start = scheduledStart }
            if schedule.finish == nil || (scheduledFinish != nil && !manual) { schedule.finish = scheduledFinish }
            schedule.duration = manual ? duration(TaskField.manualDuration14, units: TaskField.manualDurationUnits14)
                                       : duration(TaskField.duration, units: TaskField.durationUnits)
        } else {
            schedule.start = date(TaskField.start)
            schedule.finish = date(TaskField.finish)
            schedule.duration = duration(TaskField.duration, units: TaskField.durationUnits)
        }
        // Constraint adjustments (MPXJ; LocalDateTimeHelper.compare sorts nil last).
        func less(_ a: Int?, _ b: Int?) -> Bool {
            guard let a else { return false }
            guard let b else { return true }
            return a < b
        }
        if case .value(let b, let o) = fixed(row, TaskField.constraintType, map: map, size: 2) {
            switch le16(b, o) {
            case 1:      // as late as possible
                let lateStart = date(TaskField.lateStart), lateFinish = date(TaskField.lateFinish)
                if less(schedule.start, lateStart) { schedule.start = lateStart }
                if less(schedule.finish, lateFinish) { schedule.finish = lateFinish }
            case 5, 7:   // start / finish no later than
                if less(schedule.finish, schedule.start) { schedule.finish = date(TaskField.lateFinish) }
            default: break
            }
        }
        schedule.complete = complete
        return schedule
    }

    // MARK: - Assignments (MPXJ ResourceAssignmentFactory)

    private static func assignments(ole: OLE2Reader, path: [String], map: FieldMap, version: Int, decode: (Data?) -> [UInt8]?,
                                    taskNames: [Int: String], resourceNames: [Int: String], issues: inout [String], name: String) throws -> [String] {
        guard ole.entries(at: path) != nil else { throw Issue("no \(path.last ?? "") storage") }
        guard let metaBytes = ole.streamData(at: path + ["VarMeta"]).map({ [UInt8]($0) }) else { throw Issue("no VarMeta stream") }
        let varMeta = try VarMeta(metaBytes, version: version)
        let m = ole.streamData(at: path + ["FixedMeta"]).map { [UInt8]($0) } ?? []
        guard m.count >= 16, le32(m, 0) == 0xFADF_ADBA else { throw Issue("FixedMeta has no FADFADBA magic") }
        let d = decode(ole.streamData(at: path + ["FixedData"])) ?? []
        let d2 = decode(ole.streamData(at: path + ["Fixed2Data"])) ?? []
        // MPP9 writes 142-byte items, MPP14 110; MPP12 items run to the next item's offset.
        let fixedSize = version == 14 ? 110 : version == 9 ? 142 : 0
        let count = (m.count - 16) / 34
        var offsets: [Int] = []
        for i in 0..<count { offsets.append(Int(Int32(bitPattern: le32(m, 16 + i * 34 + 4)))) }
        let sortedOffsets = offsets.filter { $0 >= 0 }.sorted()
        func int(_ field: Int, _ blocks: [[UInt8]]) -> Int? {
            guard case .fixed(let block, let offset)? = map[field], block < blocks.count, offset + 4 <= blocks[block].count else { return nil }
            return Int(Int32(bitPattern: le32(blocks[block], offset)))
        }
        func double(_ field: Int, _ blocks: [[UInt8]]) -> Double? {
            guard case .fixed(let block, let offset)? = map[field], block < blocks.count, offset + 8 <= blocks[block].count else { return nil }
            return Double(bitPattern: UInt64(le32(blocks[block], offset)) | UInt64(le32(blocks[block], offset + 4)) << 32)
        }
        var lines: [String] = []
        var unreadable = 0
        var pairs: Set<[Int]> = []
        for i in 0..<count {
            guard m[16 + i * 34] == 0 else { continue }
            let offset = offsets[i]
            guard offset >= 0, offset < d.count else { unreadable += 1; continue }
            let end: Int
            let index: Int
            if fixedSize > 0 {
                end = min(d.count, offset + fixedSize); index = offset / fixedSize
            } else {
                end = min(d.count, sortedOffsets.first(where: { $0 > offset }) ?? d.count)
                index = sortedOffsets.firstIndex(of: offset) ?? i
            }
            let data = Array(d[offset..<end])
            let data2 = index * 48 + 48 <= d2.count ? Array(d2[(index * 48)..<(index * 48 + 48)]) : []
            let blocks = [data, data2]
            guard let uid = int(0, blocks), let task = int(1, blocks), let resource = int(2, blocks) else { unreadable += 1; continue }
            // As MPXJ: the assignment needs var data and a task that was read; the null resource is not shown.
            guard varMeta.table[uid] != nil, let taskName = taskNames[task] else { continue }
            guard resource != -65535, pairs.insert([task, resource]).inserted else { continue }
            var line = "task \(task) (\(taskName)) → resource \(resource)"
            if let resourceName = resourceNames[resource], !resourceName.isEmpty { line += " (\(resourceName))" }
            var fields: [String] = []
            if let units = double(7, blocks) {
                fields.append(formatDuration(abs(units) < 0.1 ? 0 : units / 100, units: 19))
            } else { fields.append("") }
            if let work = double(8, blocks) {
                fields.append(formatDuration(abs(work) < 1000 ? 0 : work / 60_000, units: 5))
            } else { fields.append("") }
            lines.append(([line] + fields).joined(separator: "\t"))
        }
        if unreadable > 0 { issues.append("\(name): \(unreadable) assignment(s) not read — their fixed data lies outside the FixedData stream") }
        return lines
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
