//
//  IWATableDecoder.swift
//  ArchiveCore
//
//  Audit R6 "IWA numeric cells": the tables of Numbers / Pages / Keynote
//  2013+ documents, cell by cell — numbers, dates, durations, booleans,
//  formula results, text and rich text — instead of only the strings of the
//  table's string list. New code next to the earlier reader (rule 14);
//  `IWorkDocumentReader` calls it from its IWA path.
//
//  Object graph (TSTArchives.proto as published by the public reverse
//  engineering — obriensp/iWorkFileFormat, the numbers-parser project,
//  SheetJS's Numbers reader):
//
//    TN.SheetArchive (2)          1 name, 2 drawable_infos → TST.TableInfoArchive
//    TST.TableInfoArchive (6000)  2 tableModel → TST.TableModelArchive
//    TST.TableModelArchive (6001) 8 table_name, 6 rows, 7 columns, 4 DataStore
//    TST.DataStore                3 TileStorage, 4 stringTable, 17 richTextPayloadTable
//    TST.TileStorage              1 tiles {1 tileid, 2 → TST.Tile}, 2 tile_size (256)
//    TST.Tile (6002)              5 rowInfos {1 tile_row_index, 3/4 storage and
//                                 offsets (pre-BNC, v0–v4), 6/7 storage and offsets
//                                 (v5), 8 has_wide_offsets}
//    TST.TableDataList (6005)     3 entries {1 key, 3 string, 4 → RichTextPayload}
//    TST.RichTextPayloadArchive (6218)  1 → TSWP.StorageArchive (2001), 3 text
//
//  Cell storage: an offsets array of 16-bit little-endian values, one per
//  column (0xFFFF = no cell; ×4 when the offsets are wide), into a buffer
//  of cell records:
//
//    v5 (Numbers 5+)  [0] version, [1] cell type, [8..<12] flags, then in flag
//                     order 0x1 decimal128, 0x2 double, 0x4 seconds since 2001,
//                     0x8 string id, 0x10 rich-text id, 0x20… 4-byte ids
//    v1–v4 (older)    [0] version, [1] cell type, [4..<8] flags; the value
//                     offset is 12 (8 for v1) + 4 × popcount(flags & 0x0D8E)
//                     (0x018E for v1), then 0x200 rich-text id, 4 × popcount
//                     (flags & 0x3000), 0x10 string id, 0x20 double, 0x40 date
//
//  Cell types: 0 empty, 2 number, 3 text, 5 date, 6 boolean, 7 duration,
//  8 formula error, 9 rich text, 10 currency (v5). A formula cell carries
//  its last calculated result in the same fields, so results read like values.
//  Number formats (decimal places, currency symbols, percentages, custom
//  formats) are not applied: numbers are the stored value, dates ISO 8601.
//

import Foundation

enum IWATableDecoder {

    static let sheetType = 2
    static let tableInfoType = 6000
    static let tableModelType = 6001
    static let tileType = 6002
    static let dataListType = 6005
    static let richTextPayloadType = 6218
    static let storageType = 2001

    struct Table: Equatable {
        var name: String
        var sheet: String?
        /// Rows in order, each the cells of its columns ("" for an empty cell).
        var rows: [[String]]
        /// Every string a cell showed (to tell which list strings were placed).
        var strings: Set<String>
        var numericCells: Int
    }

    enum CellValue: Equatable {
        case number(String), text(String), date(String), boolean(Bool), duration(String), error, empty

        var text: String {
            switch self {
            case .number(let s), .text(let s), .date(let s), .duration(let s): return s
            case .boolean(let b): return b ? "TRUE" : "FALSE"
            case .error: return "#ERROR"
            case .empty: return ""
            }
        }

        var isNumeric: Bool {
            switch self { case .number, .date, .boolean, .duration: return true; default: return false }
        }
    }

    /// All tables in an object map (identifier → object), sheets first in
    /// their own order, then tables that belong to no sheet (Pages, Keynote).
    static func tables(objects: [Int: IWAFile.Object]) -> [Table] {
        var sheetOf: [Int: String] = [:]          // table model id → sheet name
        var modelOrder: [Int] = []
        for id in objects.keys.sorted() {
            guard let sheet = objects[id], sheet.type == sheetType else { continue }
            let name = ProtobufWalker.strings(field: 1, in: sheet.payload).first ?? ""
            for infoID in references(field: 2, in: sheet.payload) {
                guard let info = objects[infoID], info.type == tableInfoType,
                      let modelID = references(field: 2, in: info.payload).first else { continue }
                sheetOf[modelID] = name
                if !modelOrder.contains(modelID) { modelOrder.append(modelID) }
            }
        }
        for id in objects.keys.sorted() where objects[id]?.type == tableModelType && !modelOrder.contains(id) {
            modelOrder.append(id)
        }
        var out: [Table] = []
        for id in modelOrder {
            guard let model = objects[id], model.type == tableModelType,
                  var table = table(model: model.payload, objects: objects) else { continue }
            table.sheet = sheetOf[id]
            out.append(table)
        }
        return out
    }

    /// One TableModelArchive, or nil when it has no data store.
    static func table(model: Data, objects: [Int: IWAFile.Object]) -> Table? {
        let name = ProtobufWalker.strings(field: 8, in: model).first ?? ""
        guard let store = ProtobufWalker.messages(field: 4, in: model).first,
              let tileStorage = ProtobufWalker.messages(field: 3, in: store).first else { return nil }
        let strings = listStrings(references(field: 4, in: store).first, objects: objects)
        let rich = listRichText(references(field: 17, in: store).first, objects: objects)
        let tileSize = ProtobufWalker.varints(field: 2, in: tileStorage).first ?? 256

        var grid: [Int: [Int: CellValue]] = [:]
        for entry in ProtobufWalker.messages(field: 1, in: tileStorage) {
            let tileID = ProtobufWalker.varints(field: 1, in: entry).first ?? 0
            guard let ref = references(field: 2, in: entry).first, let tile = objects[ref], tile.type == tileType else { continue }
            for rowInfo in ProtobufWalker.messages(field: 5, in: tile.payload) {
                let rowInTile = ProtobufWalker.varints(field: 1, in: rowInfo).first ?? 0
                let row = tileID * tileSize + rowInTile
                for (column, value) in cells(rowInfo: rowInfo, strings: strings, rich: rich) where value != .empty {
                    grid[row, default: [:]][column] = value
                }
            }
        }
        guard !grid.isEmpty else {
            return Table(name: name, sheet: nil, rows: [], strings: [], numericCells: 0)
        }
        // Rows in order; an empty row adds nothing to search and is left out.
        // Trailing empty cells are trimmed per row.
        let widest = grid.values.compactMap { $0.keys.max() }.max() ?? 0
        var rows: [[String]] = []
        var shown: Set<String> = []
        var numeric = 0
        for r in grid.keys.sorted() {
            let cells = grid[r] ?? [:]
            var line: [String] = []
            for c in 0...widest {
                let value = cells[c] ?? .empty
                if value.isNumeric { numeric += 1 }
                if case .text(let s) = value { shown.insert(s) }
                line.append(value.text)
            }
            while line.last == "" { line.removeLast() }
            rows.append(line)
        }
        return Table(name: name, sheet: nil, rows: rows, strings: shown, numericCells: numeric)
    }

    /// The cells of one TileRowInfo, column → value. v5 storage is preferred
    /// when present; otherwise the pre-BNC (v0–v4) buffer.
    static func cells(rowInfo: Data, strings: [Int: String], rich: [Int: String]) -> [(Int, CellValue)] {
        let wide = (ProtobufWalker.varints(field: 8, in: rowInfo).first ?? 0) != 0
        let storage: Data, offsets: Data
        if let s = ProtobufWalker.messages(field: 6, in: rowInfo).first, let o = ProtobufWalker.messages(field: 7, in: rowInfo).first, !s.isEmpty {
            storage = s; offsets = o
        } else if let s = ProtobufWalker.messages(field: 3, in: rowInfo).first, let o = ProtobufWalker.messages(field: 4, in: rowInfo).first {
            storage = s; offsets = o
        } else { return [] }
        let buffer = [UInt8](storage), offs = [UInt8](offsets)
        var starts: [(column: Int, offset: Int)] = []
        var i = 0
        while i + 1 < offs.count {
            let raw = Int(offs[i]) | (Int(offs[i + 1]) << 8)
            if raw != 0xFFFF { starts.append((i / 2, wide ? raw * 4 : raw)) }
            i += 2
        }
        var out: [(Int, CellValue)] = []
        for (n, start) in starts.enumerated() {
            let end = n + 1 < starts.count ? starts[n + 1].offset : buffer.count
            guard start.offset < end, end <= buffer.count else { continue }
            if let value = cell(Array(buffer[start.offset..<end]), strings: strings, rich: rich) {
                out.append((start.column, value))
            }
        }
        return out
    }

    /// One cell record (any storage version), or nil when it cannot be read.
    static func cell(_ b: [UInt8], strings: [Int: String], rich: [Int: String]) -> CellValue? {
        guard b.count >= 8 else { return nil }
        func u32(_ o: Int) -> Int? { o + 4 <= b.count ? Int(UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24) : nil }
        func f64(_ o: Int) -> Double? {
            guard o + 8 <= b.count else { return nil }
            var bits: UInt64 = 0
            for k in 0..<8 { bits |= UInt64(b[o + k]) << (8 * UInt64(k)) }
            return Double(bitPattern: bits)
        }
        let version = b[0], type = b[1]
        var decimal: String?, double: Double?, seconds: Double?, stringID: Int?, richID: Int?
        if version == 5 {
            guard let flags = u32(8) else { return nil }
            var o = 12
            if flags & 0x1 != 0 { decimal = decimal128(b, at: o); o += 16 }
            if flags & 0x2 != 0 { double = f64(o); o += 8 }
            if flags & 0x4 != 0 { seconds = f64(o); o += 8 }
            if flags & 0x8 != 0 { stringID = u32(o); o += 4 }
            if flags & 0x10 != 0 { richID = u32(o); o += 4 }
        } else if version >= 1 && version <= 4 {
            guard let flags = u32(4) else { return nil }
            var o = (version > 1 ? 12 : 8) + 4 * (flags & (version > 1 ? 0x0D8E : 0x018E)).nonzeroBitCount
            if flags & 0x0200 != 0 { richID = u32(o); o += 4 }
            o += 4 * (flags & (version > 1 ? 0x3000 : 0x1000)).nonzeroBitCount
            if flags & 0x0010 != 0 { stringID = u32(o); o += 4 }
            if flags & 0x0020 != 0 { double = f64(o); o += 8 }
            if flags & 0x0040 != 0 { seconds = f64(o); o += 8 }
        } else {
            return nil
        }
        switch type {
        case 0: return .empty
        case 2, 10:
            if let decimal { return .number(decimal) }
            return double.map { .number(number($0)) }
        case 3:
            return stringID.flatMap { strings[$0] }.map { .text($0) }
        case 5:
            return seconds.map { .date(date($0)) }
        case 6:
            return double.map { .boolean($0 > 0) }
        case 7:
            return double.map { .duration(duration($0)) }
        case 8:
            return .error
        case 9:
            if let r = richID, let s = rich[r] { return .text(s) }
            return stringID.flatMap { strings[$0] }.map { .text($0) }
        default:
            return nil
        }
    }

    // MARK: - Values

    /// A double as written: integers without a fraction, others shortest round-trip.
    static func number(_ v: Double) -> String {
        guard v.isFinite else { return "\(v)" }
        if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        return "\(v)"
    }

    /// Seconds since 2001-01-01 (the cell's wall-clock time): the ISO date,
    /// with the time when it is not midnight.
    static func date(_ seconds: Double) -> String {
        let d = Date(timeIntervalSinceReferenceDate: seconds)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.calendar = Calendar(identifier: .gregorian)
        let wholeDay = seconds.truncatingRemainder(dividingBy: 86_400) == 0
        f.dateFormat = wholeDay ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm:ss"
        return f.string(from: d)
    }

    /// Seconds as "2d 3h 4m 5s" (zero parts left out; "0s" for zero).
    static func duration(_ seconds: Double) -> String {
        let negative = seconds < 0
        var rest = abs(seconds)
        var parts: [String] = []
        for (unit, size) in [("w", 604_800.0), ("d", 86_400.0), ("h", 3_600.0), ("m", 60.0)] {
            let n = (rest / size).rounded(.down)
            if n > 0 { parts.append("\(Int64(n))\(unit)"); rest -= n * size }
        }
        if rest > 0 || parts.isEmpty { parts.append("\(number((rest * 1000).rounded() / 1000))s") }
        return (negative ? "-" : "") + parts.joined(separator: " ")
    }

    /// IEEE 754-2008 decimal128 as Numbers writes it (binary integer
    /// significand, little-endian): exponent = bits 113–126 − 6176, the
    /// 113-bit coefficient below, bit 127 the sign. Printed exactly.
    static func decimal128(_ b: [UInt8], at o: Int) -> String? {
        guard o + 16 <= b.count else { return nil }
        let exponent = ((Int(b[o + 15]) & 0x7F) << 7 | Int(b[o + 14]) >> 1) - 0x1820
        // lo: bytes 0…7; hi: bytes 8…13, then bit 0 of byte 14 at bit 48.
        var lo: UInt64 = 0, hi: UInt64 = 0
        for k in 0..<8 { lo |= UInt64(b[o + k]) << (8 * UInt64(k)) }
        for k in 8..<14 { hi |= UInt64(b[o + k]) << (8 * UInt64(k - 8)) }
        hi |= UInt64(b[o + 14] & 1) << 48
        let negative = b[o + 15] & 0x80 != 0
        // Coefficient to decimal digits by repeated division of (hi, lo) by 10.
        var digits: [Character] = []
        var h = hi, l = lo
        repeat {
            let (qh, rh) = h.quotientAndRemainder(dividingBy: 10)
            let (ql, rl) = UInt64(10).dividingFullWidth((high: rh, low: l))
            h = qh; l = ql
            digits.append(Character(String(rl)))
        } while h != 0 || l != 0
        var coefficient = String(digits.reversed())
        var text: String
        if exponent >= 0 {
            text = coefficient == "0" ? "0" : coefficient + String(repeating: "0", count: min(exponent, 6144))
        } else {
            let places = -exponent
            if coefficient.count <= places { coefficient = String(repeating: "0", count: places - coefficient.count + 1) + coefficient }
            let split = coefficient.index(coefficient.endIndex, offsetBy: -places)
            var fraction = String(coefficient[split...])
            while fraction.last == "0" { fraction.removeLast() }
            text = String(coefficient[..<split]) + (fraction.isEmpty ? "" : "." + fraction)
        }
        if negative && text != "0" { text = "-" + text }
        return text
    }

    // MARK: - Lists and references

    /// TSP.Reference sub-messages (identifier in field 1) of a field.
    static func references(field: Int, in data: Data) -> [Int] {
        ProtobufWalker.messages(field: field, in: data).compactMap { ProtobufWalker.varints(field: 1, in: $0).first }
    }

    /// A string TableDataList: key → string.
    static func listStrings(_ id: Int?, objects: [Int: IWAFile.Object]) -> [Int: String] {
        guard let id, let list = objects[id], list.type == dataListType else { return [:] }
        var out: [Int: String] = [:]
        for entry in ProtobufWalker.messages(field: 3, in: list.payload) {
            guard let key = ProtobufWalker.varints(field: 1, in: entry).first, let s = ProtobufWalker.strings(field: 3, in: entry).first else { continue }
            out[key] = s
        }
        return out
    }

    /// A rich-text TableDataList: key → the text of the payload's storage.
    static func listRichText(_ id: Int?, objects: [Int: IWAFile.Object]) -> [Int: String] {
        guard let id, let list = objects[id], list.type == dataListType else { return [:] }
        var out: [Int: String] = [:]
        for entry in ProtobufWalker.messages(field: 3, in: list.payload) {
            guard let key = ProtobufWalker.varints(field: 1, in: entry).first,
                  let payloadID = references(field: 4, in: entry).first ?? references(field: 9, in: entry).first,
                  let payload = objects[payloadID], payload.type == richTextPayloadType,
                  let storageID = references(field: 1, in: payload.payload).first,
                  let storage = objects[storageID], storage.type == storageType else { continue }
            let text = ProtobufWalker.strings(field: 3, in: storage.payload).joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { out[key] = text }
        }
        return out
    }
}

extension IWAFile {
    /// The objects of one IWA file with their identifiers (ArchiveInfo field
    /// 1). Only the first message of an archive is the object itself.
    static func identifiedObjects(in data: Data, limit: Int) throws -> [(id: Int, object: Object)] {
        let raw = try decompress(data, limit: limit)
        var out: [(Int, Object)] = []
        var pos = 0
        while pos < raw.count {
            guard let (length, next) = ProtobufWalker.varint(raw, at: pos), next + length <= raw.count else { break }
            let info = raw.subdata(in: next..<(next + length))
            pos = next + length
            let id = ProtobufWalker.varints(field: 1, in: info).first ?? 0
            for (n, message) in ProtobufWalker.messages(field: 2, in: info).enumerated() {
                let type = ProtobufWalker.varints(field: 1, in: message).first ?? 0
                let size = ProtobufWalker.varints(field: 3, in: message).first ?? 0
                guard size >= 0, pos + size <= raw.count else { return out }
                if n == 0 { out.append((id, Object(type: type, payload: raw.subdata(in: pos..<(pos + size))))) }
                pos += size
            }
        }
        return out
    }
}
