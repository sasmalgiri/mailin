//
//  XLSBReader.swift
//  ArchiveCore
//
//  Plan v4 §13.8 step 4 (COMP-06): Excel Binary Workbook (.xlsb, MS-XLSB).
//  A ZIP like .xlsx, but the parts are BIFF12 record streams, not XML:
//  each record is a variable-length type, a variable-length size and the
//  payload. What is read, in the same shape as the XLSX reader so the two
//  search alike:
//
//    [Workbook]   the 1904 date system, when set
//    [Sheet: N]   one line per row, "A1: value"; a formula cell shows its
//                 cached value followed by {formula} — the parsed formula
//                 tokens are not rendered back to text; hidden sheets say so
//
//  Shared strings come from xl/sharedStrings.bin; sheet names, order and
//  visibility from xl/workbook.bin and its relationships. Nothing is
//  evaluated; a record this reader does not know is skipped by its size.
//

import Foundation

enum XLSBReader {

    static func extract(fileURL: URL) throws -> OfficeTextExtractor.Result {
        let members: [ZIPArchiveReader.Member]
        do { members = try ZIPArchiveReader.members(of: fileURL) } catch {
            throw OfficeTextExtractor.ExtractError.notAPackage(String(describing: error))
        }
        let scratch = try DocumentTextExtractor.scratchDirectory("xlsb")
        defer { try? FileManager.default.removeItem(at: scratch) }
        var parts: [String: ZIPArchiveReader.Member] = [:]
        var notText: [String] = []
        for member in members where !member.isDirectory {
            if member.name.hasPrefix("xl/media/") || member.name.hasSuffix("vbaProject.bin") { notText.append(member.name) }
            else { parts[member.name] = member }
        }
        var skipped: [String] = []
        func bytes(_ name: String) throws -> Data? {
            guard let member = parts[name] else { return nil }
            guard member.uncompressedSize <= OfficeTextExtractor.maxPartBytes else {
                skipped.append("\(name) (\(member.uncompressedSize) bytes, over the \(OfficeTextExtractor.maxPartBytes)-byte guard)")
                return nil
            }
            return try DocumentTextExtractor.memberData(member, from: fileURL, scratch: scratch)
        }

        // Shared strings.
        var shared: [String] = []
        if let sst = try bytes("xl/sharedStrings.bin") {
            for record in records(in: sst) where record.type == 0x0013 {
                var pos = 1   // flags
                if let s = wideString(record.payload, &pos) { shared.append(s) }
            }
        }
        // Workbook: sheets in order, hidden state, 1904 flag.
        struct SheetEntry { let name: String; let relID: String; let hidden: Bool }
        var sheets: [SheetEntry] = []
        var date1904 = false
        if let workbook = try bytes("xl/workbook.bin") {
            for record in records(in: workbook) {
                switch record.type {
                case 0x009C:   // BrtBundleSh
                    guard record.payload.count >= 8 else { continue }
                    let state = u32(record.payload, 0)
                    var pos = 8
                    let relID = nullableWideString(record.payload, &pos) ?? ""
                    let name = wideString(record.payload, &pos) ?? ""
                    sheets.append(SheetEntry(name: name, relID: relID, hidden: state != 0))
                case 0x0099:   // BrtWbProp
                    if record.payload.count >= 4, u32(record.payload, 0) & 0x1 != 0 { date1904 = true }
                default: break
                }
            }
        }
        var targetByID: [String: String] = [:]
        if let relsData = try bytes("xl/_rels/workbook.bin.rels") {
            let rels = OOXMLTextCollector(.raw)
            if rels.parse(relsData) {
                for rel in rels.relationships { targetByID[rel.id] = rel.target.hasPrefix("/") ? String(rel.target.dropFirst()) : "xl/" + rel.target }
            }
        }
        let sheetFiles = parts.keys.filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".bin") }
            .sorted { OfficeTextExtractor.sheetNumber($0) < OfficeTextExtractor.sheetNumber($1) }
        if sheetFiles.isEmpty && skipped.isEmpty { throw OfficeTextExtractor.ExtractError.noTextParts }

        var text = ""
        var components: [String] = []
        if date1904 {
            components.append("Workbook")
            text += "[Workbook]\n1904 date system: serial dates count from 1 January 1904\n\n"
        }
        // Sheets in workbook order when the relationships resolve, file order otherwise.
        var ordered: [(file: String, entry: SheetEntry?)] = []
        var seen = Set<String>()
        for entry in sheets { if let file = targetByID[entry.relID], parts[file] != nil { ordered.append((file, entry)); seen.insert(file) } }
        for file in sheetFiles where !seen.contains(file) { ordered.append((file, nil)) }
        for (file, entry) in ordered {
            guard let data = try bytes(file) else { continue }
            var label = "Sheet: " + (entry?.name ?? "Sheet \(OfficeTextExtractor.sheetNumber(file))")
            if entry?.hidden == true { label += " (hidden)" }
            components.append(label)
            text += "[\(label)]\n" + sheetText(data, shared: shared) + "\n"
        }
        return OfficeTextExtractor.Result(text: text, components: components, skipped: skipped, notText: notText.sorted())
    }

    // MARK: - Records

    struct Record { let type: Int; let payload: Data }

    /// BIFF12 framing: type as 1–2 bytes of 7 bits, size as 1–4 bytes of 7 bits.
    static func records(in data: Data) -> [Record] {
        var out: [Record] = []
        var pos = 0
        let n = data.count
        func byte(_ i: Int) -> Int { Int(data[data.startIndex + i]) }
        while pos < n {
            var type = 0
            var shift = 0
            var i = 0
            repeat {
                guard pos < n else { return out }
                let b = byte(pos); pos += 1
                type |= (b & 0x7F) << shift; shift += 7; i += 1
                if b & 0x80 == 0 { break }
            } while i < 2
            var size = 0
            shift = 0; i = 0
            repeat {
                guard pos < n else { return out }
                let b = byte(pos); pos += 1
                size |= (b & 0x7F) << shift; shift += 7; i += 1
                if b & 0x80 == 0 { break }
            } while i < 4
            guard size >= 0, pos + size <= n else { return out }
            out.append(Record(type: type, payload: data.subdata(in: (data.startIndex + pos)..<(data.startIndex + pos + size))))
            pos += size
        }
        return out
    }

    /// One worksheet part as "A1: value" rows.
    static func sheetText(_ data: Data, shared: [String]) -> String {
        var lines: [String] = []
        var row = 0
        var cells: [String] = []
        func flush() { if !cells.isEmpty { lines.append(cells.joined(separator: "\t")); cells = [] } }
        for record in records(in: data) {
            let p = record.payload
            switch record.type {
            case 0x0000:   // BrtRowHdr
                flush()
                if p.count >= 4 { row = Int(u32(p, 0)) }
            case 0x0001...0x000B:
                guard p.count >= 8 else { continue }
                let column = Int(u32(p, 0))
                let address = OfficeTextExtractor.columnName(column) + String(row + 1)
                var value = ""
                var formula = false
                switch record.type {
                case 0x0001: continue                                        // BrtCellBlank
                case 0x0002: if p.count >= 12 { value = rk(u32(p, 8)) }       // BrtCellRk
                case 0x0003: if p.count >= 9 { value = errorName(p[p.startIndex + 8]) }
                case 0x0004: if p.count >= 9 { value = p[p.startIndex + 8] == 0 ? "FALSE" : "TRUE" }
                case 0x0005: if p.count >= 16 { value = number(f64(p, 8)) }
                case 0x0006: var pos = 8; value = wideString(p, &pos) ?? ""   // BrtCellSt
                case 0x0007:                                                 // BrtCellIsst
                    if p.count >= 12 { let i = Int(u32(p, 8)); value = i >= 0 && i < shared.count ? shared[i] : "" }
                case 0x0008: var pos = 8; value = wideString(p, &pos) ?? ""; formula = true
                case 0x0009: if p.count >= 16 { value = number(f64(p, 8)) }; formula = true
                case 0x000A: if p.count >= 9 { value = p[p.startIndex + 8] == 0 ? "FALSE" : "TRUE" }; formula = true
                case 0x000B: if p.count >= 9 { value = errorName(p[p.startIndex + 8]) }; formula = true
                default: continue
                }
                if formula { value += " {formula}" }
                let trimmed = value.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { cells.append(address + ": " + trimmed) }
            default: break
            }
        }
        flush()
        return lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    }

    // MARK: - Values

    /// RkNumber: bit 0 = divide by 100, bit 1 = 30-bit integer, else the high 30 bits of a double.
    static func rk(_ raw: UInt32) -> String {
        let divide = raw & 0x1 != 0
        var value: Double
        if raw & 0x2 != 0 {
            value = Double(Int32(bitPattern: raw) >> 2)
        } else {
            value = Double(bitPattern: UInt64(raw & 0xFFFF_FFFC) << 32)
        }
        if divide { value /= 100 }
        return number(value)
    }

    static func number(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return String(value)
    }

    static func errorName(_ code: UInt8) -> String {
        switch code {
        case 0x00: return "#NULL!"
        case 0x07: return "#DIV/0!"
        case 0x0F: return "#VALUE!"
        case 0x17: return "#REF!"
        case 0x1D: return "#NAME?"
        case 0x24: return "#NUM!"
        case 0x2A: return "#N/A"
        default: return "#ERR"
        }
    }

    /// XLWideString: cch (u32) then UTF-16LE characters.
    static func wideString(_ data: Data, _ pos: inout Int) -> String? {
        guard pos + 4 <= data.count else { return nil }
        let count = Int(u32(data, pos)); pos += 4
        guard count >= 0, count <= 0x7FFF_FFFF, pos + count * 2 <= data.count else { return nil }
        let bytes = data.subdata(in: (data.startIndex + pos)..<(data.startIndex + pos + count * 2))
        pos += count * 2
        return String(data: bytes, encoding: .utf16LittleEndian)
    }

    /// XLNullableWideString: cch 0xFFFFFFFF means none.
    static func nullableWideString(_ data: Data, _ pos: inout Int) -> String? {
        guard pos + 4 <= data.count else { return nil }
        if u32(data, pos) == 0xFFFF_FFFF { pos += 4; return nil }
        return wideString(data, &pos)
    }

    static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        let b = data.startIndex + offset
        return UInt32(data[b]) | (UInt32(data[b + 1]) << 8) | (UInt32(data[b + 2]) << 16) | (UInt32(data[b + 3]) << 24)
    }

    static func f64(_ data: Data, _ offset: Int) -> Double {
        guard offset + 8 <= data.count else { return 0 }
        let b = data.startIndex + offset
        var bits: UInt64 = 0
        for i in 0..<8 { bits |= UInt64(data[b + i]) << (UInt64(i) * 8) }
        return Double(bitPattern: bits)
    }
}
